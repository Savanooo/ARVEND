package service

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/shopspring/decimal"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

// Siparişten teslim alma (migration 0074, docs/procurement.md §12). Onaylı
// bir siparişin kalemleri parça parça teslim alınır; her teslim kalem başına
// kabul ve red miktarı taşır. Bekleyen = sipariş - kabul - red; kabul tavanı
// = sipariş - önceki kabuller (reddedilenin yerine gelen yeniden kabul
// edilebilir). Teslim şimdilik miktar kontrolüdür: maliyet yazmaz, malın
// maliyeti siparişe bağlanan masraftan (fatura) gelir.

var (
	ErrPurchaseOrderNotReceivable = errors.New("yalnızca onaylı (kapatılmamış, iptal edilmemiş) siparişe teslim girilebilir")
	ErrReceiptItemsRequired       = errors.New("teslimde en az bir kalemin kabul ya da red miktarı girilmelidir")
	ErrReceiptInvalidQuantity     = errors.New("kabul ve red miktarı sıfır ya da pozitif olmalıdır")
	ErrReceiptDuplicateItem       = errors.New("aynı sipariş kalemi teslimde iki kez yer alamaz")
	ErrReceiptInvalidDestination  = errors.New("teslim yeri şantiye ya da depo olmalıdır; depoda depo seçilmelidir")
	ErrReceiptWarehouseInactive   = errors.New("seçilen depo kapalı")
	ErrReceiptIdempotencyKeyInUse = errors.New("bu tekrar anahtarı başka bir teslimde kullanılmış")
	ErrReceiptNotVoidable         = errors.New("teslim yalnızca sipariş onaylıyken (kapatılmadan) iptal edilebilir")
	ErrReceiptReasonRequired      = errors.New("iptal gerekçesi zorunludur")
	ErrPurchaseOrderHasReceipts   = errors.New("teslim alınmış sipariş iptal edilemez; gelmeyecek kısmı bırakmak için siparişi kapatın")
)

// ErrReceiptExceedsOrder: kalem için kabul tavanı aşıldı.
type ErrReceiptExceedsOrder struct {
	Description string
	Max         decimal.Decimal
}

func (e *ErrReceiptExceedsOrder) Error() string {
	return fmt.Sprintf("%q için en fazla %s kabul edilebilir (sipariş miktarı - önceki kabuller)", e.Description, e.Max.StringFixed(2))
}

type PurchaseReceiptItemInput struct {
	PurchaseOrderItemID string
	AcceptedQuantity    float64
	RejectedQuantity    float64
	RejectionReason     string
}

type PurchaseReceiptInput struct {
	ReceivedDate   time.Time
	DeliveryNoteNo string
	// Destination: "site" | "warehouse" (warehouse ise WarehouseID zorunlu).
	Destination    string
	WarehouseID    string
	Notes          string
	IdempotencyKey string
	Items          []PurchaseReceiptItemInput
	UserID         string
}

func receiptQty(v float64) decimal.Decimal { return decimal.NewFromFloat(v).Round(2) }

// CreatePurchaseReceipt: siparişe bir teslim (irsaliye) girer. Proje ve
// sipariş satırı kilitlenir: aynı siparişe eşzamanlı iki teslim kabul
// tavanını birlikte aşamaz. Aynı kişinin aynı tekrar anahtarı aynı teslimi döner.
func (s *ProjectService) CreatePurchaseReceipt(ctx context.Context, projectID, poID, organizationID string, in PurchaseReceiptInput) (*domain.PurchaseReceipt, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	poUUID, err := repository.StringToUUID(poID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	dest := strings.TrimSpace(in.Destination)
	var warehouseID pgtype.UUID
	switch dest {
	case domain.ReceiptDestinationSite:
		if strings.TrimSpace(in.WarehouseID) != "" {
			return nil, ErrReceiptInvalidDestination
		}
	case domain.ReceiptDestinationWarehouse:
		if warehouseID, err = repository.StringToUUID(in.WarehouseID); err != nil {
			return nil, ErrReceiptInvalidDestination
		}
	default:
		return nil, ErrReceiptInvalidDestination
	}
	type line struct {
		itemID             pgtype.UUID
		accepted, rejected decimal.Decimal
		reason             string
	}
	var lines []line
	seen := map[string]bool{}
	for _, it := range in.Items {
		acc, rej := receiptQty(it.AcceptedQuantity), receiptQty(it.RejectedQuantity)
		if acc.IsNegative() || rej.IsNegative() {
			return nil, ErrReceiptInvalidQuantity
		}
		if acc.IsZero() && rej.IsZero() {
			continue
		}
		iid, err := repository.StringToUUID(it.PurchaseOrderItemID)
		if err != nil {
			return nil, &NotFoundError{What: "sipariş kalemi"}
		}
		if seen[iid.String()] {
			return nil, ErrReceiptDuplicateItem
		}
		seen[iid.String()] = true
		lines = append(lines, line{itemID: iid, accepted: acc, rejected: rej, reason: truncateRunes(strings.TrimSpace(it.RejectionReason), 300)})
	}
	if len(lines) == 0 {
		return nil, ErrReceiptItemsRequired
	}
	actor := actorUUID(in.UserID)

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	if _, err := s.requireOpenProject(ctx, txq, pid, orgID); err != nil {
		return nil, err
	}
	key := strings.TrimSpace(in.IdempotencyKey)
	var keyPtr *string
	if key != "" {
		keyPtr = &key
		existing, err := txq.GetPurchaseReceiptByIdempotencyKey(ctx, sqlc.GetPurchaseReceiptByIdempotencyKeyParams{OrganizationID: orgID, IdempotencyKey: &key})
		switch {
		case err == nil:
			if existing.CreatedBy != actor || existing.PurchaseOrderID != poUUID {
				return nil, ErrReceiptIdempotencyKeyInUse
			}
			return s.loadPurchaseReceipt(ctx, txq, existing, pid, orgID)
		case !errors.Is(err, pgx.ErrNoRows):
			return nil, err
		}
	}
	po, err := txq.GetPurchaseOrderForUpdate(ctx, sqlc.GetPurchaseOrderForUpdateParams{ID: poUUID, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	if po.Status != domain.PurchaseOrderStatusApproved {
		return nil, ErrPurchaseOrderNotReceivable
	}
	if dest == domain.ReceiptDestinationWarehouse {
		w, err := txq.GetInventoryWarehouse(ctx, sqlc.GetInventoryWarehouseParams{ID: warehouseID, OrganizationID: orgID})
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return nil, &NotFoundError{What: "depo"}
			}
			return nil, err
		}
		if !w.IsActive {
			return nil, ErrReceiptWarehouseInactive
		}
	}
	items, err := txq.ListPurchaseOrderItems(ctx, poUUID)
	if err != nil {
		return nil, err
	}
	byID := make(map[string]sqlc.PurchaseOrderItem, len(items))
	for _, it := range items {
		byID[it.ID.String()] = it
	}
	totals, err := txq.ListPurchaseOrderItemReceiptTotals(ctx, sqlc.ListPurchaseOrderItemReceiptTotalsParams{PurchaseOrderID: poUUID, OrganizationID: orgID})
	if err != nil {
		return nil, err
	}
	acceptedSoFar := make(map[string]decimal.Decimal, len(totals))
	for _, t := range totals {
		acceptedSoFar[t.PurchaseOrderItemID.String()] = repository.NumericToDecimal(t.AcceptedQuantity)
	}
	for _, l := range lines {
		it, ok := byID[l.itemID.String()]
		if !ok {
			return nil, &NotFoundError{What: "sipariş kalemi"}
		}
		max := repository.NumericToDecimal(it.Quantity).Sub(acceptedSoFar[l.itemID.String()])
		if l.accepted.GreaterThan(max) {
			if max.IsNegative() {
				max = decimal.Zero
			}
			return nil, &ErrReceiptExceedsOrder{Description: it.Description, Max: max}
		}
	}

	seq, err := txq.NextPurchaseReceiptSeq(ctx, poUUID)
	if err != nil {
		return nil, err
	}
	row, err := txq.CreatePurchaseReceipt(ctx, sqlc.CreatePurchaseReceiptParams{
		OrganizationID: orgID, ProjectID: pid, PurchaseOrderID: poUUID, SequenceNo: seq,
		ReceivedDate: repository.TimeToDate(in.ReceivedDate), DeliveryNoteNo: truncateRunes(strings.TrimSpace(in.DeliveryNoteNo), 60),
		Destination: dest, WarehouseID: warehouseID, Notes: strings.TrimSpace(in.Notes), IdempotencyKey: keyPtr, CreatedBy: actor,
	})
	if err != nil {
		// Eşzamanlı aynı anahtarlı istek kazandıysa onun teslimi döner.
		if key != "" && isUniqueViolation(err) {
			if existing, gerr := s.q.GetPurchaseReceiptByIdempotencyKey(ctx, sqlc.GetPurchaseReceiptByIdempotencyKeyParams{OrganizationID: orgID, IdempotencyKey: &key}); gerr == nil {
				if existing.CreatedBy != actor || existing.PurchaseOrderID != poUUID {
					return nil, ErrReceiptIdempotencyKeyInUse
				}
				return s.loadPurchaseReceipt(ctx, s.q, existing, pid, orgID)
			}
		}
		return nil, err
	}
	accepted, rejected := decimal.Zero, decimal.Zero
	for _, l := range lines {
		if _, err := txq.CreatePurchaseReceiptItem(ctx, sqlc.CreatePurchaseReceiptItemParams{
			OrganizationID: orgID, ProjectID: pid, ReceiptID: row.ID, PurchaseOrderID: poUUID, PurchaseOrderItemID: l.itemID,
			AcceptedQuantity: repository.DecimalToNumeric(l.accepted), RejectedQuantity: repository.DecimalToNumeric(l.rejected),
			RejectionReason: l.reason,
		}); err != nil {
			return nil, err
		}
		accepted, rejected = accepted.Add(l.accepted), rejected.Add(l.rejected)
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventPurchaseReceiptRecorded, actor, map[string]any{
		"purchase_order_id": poID, "po_no": po.PoNo, "receipt_id": row.ID.String(), "sequence_no": seq,
		"delivery_note_no": row.DeliveryNoteNo, "destination": dest,
		"accepted_quantity": accepted.InexactFloat64(), "rejected_quantity": rejected.InexactFloat64(),
	}); err != nil {
		return nil, err
	}
	out, err := s.loadPurchaseReceipt(ctx, txq, row, pid, orgID)
	if err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	return out, nil
}

// loadPurchaseReceipt: teslimi kalemleri ve depo/giren adıyla okur.
func (s *ProjectService) loadPurchaseReceipt(ctx context.Context, q *sqlc.Queries, r sqlc.PurchaseReceipt, pid, orgID pgtype.UUID) (*domain.PurchaseReceipt, error) {
	all, err := s.listPurchaseReceipts(ctx, q, r.PurchaseOrderID, pid, orgID)
	if err != nil {
		return nil, err
	}
	for i := range all {
		if all[i].ID == r.ID.String() {
			return &all[i], nil
		}
	}
	return nil, domain.ErrNotFound
}

func (s *ProjectService) listPurchaseReceipts(ctx context.Context, q *sqlc.Queries, poID, pid, orgID pgtype.UUID) ([]domain.PurchaseReceipt, error) {
	rows, err := q.ListPurchaseReceipts(ctx, sqlc.ListPurchaseReceiptsParams{PurchaseOrderID: poID, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		return nil, err
	}
	items, err := q.ListPurchaseReceiptItemsForOrder(ctx, sqlc.ListPurchaseReceiptItemsForOrderParams{PurchaseOrderID: poID, OrganizationID: orgID})
	if err != nil {
		return nil, err
	}
	byReceipt := map[string][]domain.PurchaseReceiptItem{}
	for _, it := range items {
		k := it.ReceiptID.String()
		byReceipt[k] = append(byReceipt[k], domain.PurchaseReceiptItem{
			PurchaseOrderItemID: it.PurchaseOrderItemID.String(),
			AcceptedQuantity:    repository.NumericToFloat64(it.AcceptedQuantity),
			RejectedQuantity:    repository.NumericToFloat64(it.RejectedQuantity),
			RejectionReason:     it.RejectionReason,
		})
	}
	out := make([]domain.PurchaseReceipt, len(rows))
	for i, r := range rows {
		rec := domain.PurchaseReceipt{
			ID: r.ID.String(), ProjectID: r.ProjectID.String(), PurchaseOrderID: r.PurchaseOrderID.String(),
			SequenceNo: int(r.SequenceNo), ReceivedDate: r.ReceivedDate.Time, DeliveryNoteNo: r.DeliveryNoteNo,
			Destination: r.Destination, WarehouseName: r.WarehouseName, Notes: r.Notes,
			CreatedByName: r.CreatedByName, CreatedAt: r.CreatedAt.Time, VoidReason: r.VoidReason,
			Items: byReceipt[r.ID.String()],
		}
		if r.WarehouseID.Valid {
			w := r.WarehouseID.String()
			rec.WarehouseID = &w
		}
		if r.CreatedBy.Valid {
			c := r.CreatedBy.String()
			rec.CreatedBy = &c
		}
		if r.VoidedAt.Valid {
			t := r.VoidedAt.Time
			rec.VoidedAt = &t
		}
		if rec.Items == nil {
			rec.Items = []domain.PurchaseReceiptItem{}
		}
		out[i] = rec
	}
	return out, nil
}

// ListPurchaseReceipts: siparişin bütün teslimleri (iptaller dahil), en yeni önce.
func (s *ProjectService) ListPurchaseReceipts(ctx context.Context, projectID, poID, organizationID string) ([]domain.PurchaseReceipt, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	id, err := repository.StringToUUID(poID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	return s.listPurchaseReceipts(ctx, s.q, id, pid, orgID)
}

// PurchaseOrderItemReceipts: sipariş kalemi başına kabul / red / bekleyen.
func (s *ProjectService) PurchaseOrderItemReceipts(ctx context.Context, projectID, poID, organizationID string) (map[string]domain.PurchaseOrderItemReceipt, error) {
	_, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	id, err := repository.StringToUUID(poID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	items, err := s.ListPurchaseOrderItems(ctx, projectID, poID, organizationID)
	if err != nil {
		return nil, err
	}
	totals, err := s.q.ListPurchaseOrderItemReceiptTotals(ctx, sqlc.ListPurchaseOrderItemReceiptTotalsParams{PurchaseOrderID: id, OrganizationID: orgID})
	if err != nil {
		return nil, err
	}
	byID := make(map[string]sqlc.ListPurchaseOrderItemReceiptTotalsRow, len(totals))
	for _, t := range totals {
		byID[t.PurchaseOrderItemID.String()] = t
	}
	out := make(map[string]domain.PurchaseOrderItemReceipt, len(items))
	for _, it := range items {
		t := byID[it.ID]
		acc, rej := repository.NumericToDecimal(t.AcceptedQuantity), repository.NumericToDecimal(t.RejectedQuantity)
		waiting := decimal.NewFromFloat(it.Quantity).Sub(acc).Sub(rej)
		if waiting.IsNegative() {
			waiting = decimal.Zero
		}
		out[it.ID] = domain.PurchaseOrderItemReceipt{
			AcceptedQuantity: acc.InexactFloat64(), RejectedQuantity: rej.InexactFloat64(), WaitingQuantity: waiting.InexactFloat64(),
		}
	}
	return out, nil
}

// PurchaseOrderReceiptSummaries: projedeki siparişlerin teslim özeti
// (poID boşsa hepsi). Kalemi olmayan sipariş listede yer almaz (teslim yok).
func (s *ProjectService) PurchaseOrderReceiptSummaries(ctx context.Context, projectID, poID, organizationID string) (map[string]domain.PurchaseOrderReceiptSummary, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	var poFilter pgtype.UUID
	if poID != "" {
		if poFilter, err = repository.StringToUUID(poID); err != nil {
			return nil, domain.ErrNotFound
		}
	}
	rows, err := s.q.ListPurchaseOrderReceiptSummaries(ctx, sqlc.ListPurchaseOrderReceiptSummariesParams{
		ProjectID: pid, OrganizationID: orgID, PurchaseOrderID: poFilter,
	})
	if err != nil {
		return nil, err
	}
	out := make(map[string]domain.PurchaseOrderReceiptSummary, len(rows))
	for _, r := range rows {
		status := domain.ReceiptStatusNone
		switch {
		case r.HasReceipts && r.FullyReceived:
			status = domain.ReceiptStatusComplete
		case r.HasReceipts:
			status = domain.ReceiptStatusPartial
		}
		gross, costed := repository.NumericToDecimal(r.AcceptedGross), repository.NumericToDecimal(r.Costed)
		notCosted := gross.Sub(costed)
		if notCosted.IsNegative() {
			notCosted = decimal.Zero
		}
		out[r.PurchaseOrderID.String()] = domain.PurchaseOrderReceiptSummary{
			Status: status, AcceptedNet: repository.NumericToFloat64(r.AcceptedNet), AcceptedGross: gross.InexactFloat64(),
			Costed: costed.InexactFloat64(), ReceivedNotCosted: notCosted.InexactFloat64(),
		}
	}
	return out, nil
}

// VoidPurchaseReceipt: teslimi gerekçeyle iptal eder (kayıt kalır, toplamlara
// girmez). Yalnızca sipariş onaylıyken: kapatılmış siparişin taahhüdü
// teslimlere göre ayarlanmıştır.
func (s *ProjectService) VoidPurchaseReceipt(ctx context.Context, projectID, receiptID, organizationID, userID, reason string) (*domain.PurchaseReceipt, error) {
	reason = strings.TrimSpace(reason)
	if reason == "" {
		return nil, ErrReceiptReasonRequired
	}
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	rid, err := repository.StringToUUID(receiptID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	if _, err := s.requireOpenProject(ctx, txq, pid, orgID); err != nil {
		return nil, err
	}
	current, err := txq.GetPurchaseReceiptForUpdate(ctx, sqlc.GetPurchaseReceiptForUpdateParams{ID: rid, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	if current.VoidedAt.Valid {
		return nil, ErrAlreadyVoided
	}
	po, err := txq.GetPurchaseOrderForUpdate(ctx, sqlc.GetPurchaseOrderForUpdateParams{ID: current.PurchaseOrderID, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		return nil, err
	}
	if po.Status != domain.PurchaseOrderStatusApproved {
		return nil, ErrReceiptNotVoidable
	}
	row, err := txq.VoidPurchaseReceipt(ctx, sqlc.VoidPurchaseReceiptParams{
		ID: rid, OrganizationID: orgID, ProjectID: pid, VoidedBy: actorUUID(userID), VoidReason: truncateRunes(reason, 500),
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrAlreadyVoided
		}
		return nil, err
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventPurchaseReceiptVoided, actorUUID(userID), map[string]any{
		"purchase_order_id": po.ID.String(), "po_no": po.PoNo, "receipt_id": receiptID, "sequence_no": row.SequenceNo, "reason": reason,
	}); err != nil {
		return nil, err
	}
	out, err := s.loadPurchaseReceipt(ctx, txq, row, pid, orgID)
	if err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	return out, nil
}

// releaseUnreceivedCommitments: teslim alınmış sipariş kapatılırken her
// kalemin taahhüdü kabul edilen değere indirilir (hiç kabul yoksa düşer):
// gelmeyecek kısım taahhütten çıkar, teslim alınan kaybolmaz. Eski taahhüt
// gerekçeyle iptal edilir, kabul edilen tutarla yenisi açılır (iz kalır).
func releaseUnreceivedCommitments(ctx context.Context, txq *sqlc.Queries, orgID, pid, poID pgtype.UUID, actor pgtype.UUID) (int, error) {
	items, err := txq.ListPurchaseOrderItems(ctx, poID)
	if err != nil {
		return 0, err
	}
	totals, err := txq.ListPurchaseOrderItemReceiptTotals(ctx, sqlc.ListPurchaseOrderItemReceiptTotalsParams{PurchaseOrderID: poID, OrganizationID: orgID})
	if err != nil {
		return 0, err
	}
	acceptedNet := make(map[string]decimal.Decimal, len(totals))
	price := make(map[string]decimal.Decimal, len(items))
	for _, it := range items {
		price[it.ID.String()] = repository.NumericToDecimal(it.UnitPrice)
	}
	for _, t := range totals {
		k := t.PurchaseOrderItemID.String()
		acceptedNet[k] = repository.NumericToDecimal(t.AcceptedQuantity).Mul(price[k]).Round(2)
	}
	commitments, err := txq.ListCommitmentsBySourcePOItems(ctx, sqlc.ListCommitmentsBySourcePOItemsParams{
		OrganizationID: orgID, ProjectID: pid, PurchaseOrderID: poID,
	})
	if err != nil {
		return 0, err
	}
	changed := 0
	for _, c := range commitments {
		if c.Status != "active" {
			continue
		}
		want := acceptedNet[c.SourceID.String()]
		if !want.LessThan(repository.NumericToDecimal(c.CommittedAmount)) {
			continue
		}
		reason := "Sipariş kapatıldı: teslim alınmayan kısım taahhütten çıktı"
		if want.IsZero() {
			reason = "Sipariş kapatıldı: kalem hiç teslim alınmadı"
		}
		if _, err := txq.VoidCommitmentByID(ctx, sqlc.VoidCommitmentByIDParams{
			ID: c.ID, OrganizationID: orgID, ProjectID: pid, VoidedBy: actor, VoidReason: reason,
		}); err != nil {
			return 0, err
		}
		changed++
		if want.IsZero() {
			continue
		}
		if _, err := txq.CreateCommitmentFromSource(ctx, sqlc.CreateCommitmentFromSourceParams{
			OrganizationID: orgID, ProjectID: pid, BudgetLineID: c.BudgetLineID, CostCodeID: c.CostCodeID,
			SourceType: c.SourceType, SourceID: c.SourceID, Description: truncateRunes(c.Description+" (teslim alınan)", 300),
			CommittedAmount: repository.DecimalToNumeric(want), Currency: c.Currency, CommittedAt: c.CommittedAt, CreatedBy: actor,
		}); err != nil {
			return 0, err
		}
	}
	return changed, nil
}
