package service

import (
	"context"
	"errors"
	"fmt"
	"io"
	"sort"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/Savanooo/ARVEND/backend/internal/platform/storage"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

// Stok fişleri: giriş, çıkış, depolar arası aktarım, fire, sayım ve iptal.
// Her fiş tek transaction'dır: kartlar (id sırasıyla) FOR UPDATE kilitlenir
// -- aynı malzemenin bütün hareketleri sıraya girer, ortalama maliyet ve
// bakiye tutarlı kalır.

const (
	InventoryDocReceipt  = "receipt"
	InventoryDocIssue    = "issue"
	InventoryDocTransfer = "transfer"
	InventoryDocWaste    = "waste"
	InventoryDocCount    = "count"
	InventoryDocReversal = "reversal"
)

var inventoryWasteReasons = map[string]bool{
	"damaged": true, "expired": true, "cutting": true, "lost": true, "other": true,
}

type InventoryLineInput struct {
	ItemID string
	// Giriş/çıkış/aktarım/fire miktarı.
	Quantity float64
	// Sayımda sayılan miktar.
	CountedQuantity *float64
	// Girişte birim maliyet (KDV hariç); boşsa ortalama değişmez.
	UnitCost *float64
	// Çıkış/aktarım/fire/sayımda belirli parti; boşsa önce bozulacak önce.
	LotID string
	// Girişte (sayımda yeni parti için) parti no ve tarihler.
	LotNo          string
	ExpiryDate     *time.Time
	ProductionDate *time.Time
}

type InventoryDocumentInput struct {
	Type              string
	Date              *time.Time
	WarehouseID       string
	TargetWarehouseID string
	ProjectID         string
	SupplierID        string
	Counterparty      string
	ReferenceNo       string
	Reason            string
	Note              string
	IdempotencyKey    string
	UserID            string
	Lines             []InventoryLineInput
}

type InventoryDocumentSummary struct {
	ID                  string
	DocNo               string
	DocType             string
	DocDate             time.Time
	Status              string
	Counterparty        string
	ReferenceNo         string
	Reason              string
	WarehouseName       string
	TargetWarehouseName string
	ProjectName         string
	CreatedByName       string
	CreatedAt           time.Time
	ItemCount           int
	FirstItemName       string
	IsReversal          bool
}

type InventoryLine struct {
	LineNo        int
	ItemID        string
	ItemCode      string
	ItemName      string
	Unit          string
	WarehouseID   string
	WarehouseName string
	LotID         string
	LotNo         string
	ExpiryDate    *time.Time
	Quantity      float64
	UnitCost      float64
}

type InventoryDocument struct {
	InventoryDocumentSummary
	WarehouseID       string
	TargetWarehouseID string
	ProjectID         string
	ProjectNo         string
	SupplierID        string
	SupplierName      string
	Note              string
	AttachmentName    string
	AttachmentMime    string
	ReversalOfID      string
	ReversalOfNo      string
	ReversedByDocID   string
	ReversedByDocNo   string
	ReversedAt        *time.Time
	ReversedByName    string
	ReverseReason     string
	Lines             []InventoryLine
	// Warnings: kaydı engellemeyen notlar (ör. SKT'si geçmiş parti
	// kullanıldı). Saklanmaz; yalnızca kaydın yanıtında döner.
	Warnings []string
}

type InventoryDocumentFilter struct {
	Type        string
	WarehouseID string
	ItemID      string
	ProjectID   string
	Limit       int
	Offset      int
}

func isCheckViolation(err error) bool {
	var pgErr interface{ SQLState() string }
	return errors.As(err, &pgErr) && pgErr.SQLState() == "23514"
}

func fmtQty(f float64, unit string) string {
	s := strings.TrimRight(strings.TrimRight(fmt.Sprintf("%.3f", f), "0"), ".")
	return strings.TrimSpace(s + " " + unit)
}

// PostDocument: giriş, çıkış, aktarım, fire ya da sayım fişini kaydeder.
// Aynı idempotency anahtarıyla gelen ikinci istek ilk fişi döner.
func (s *InventoryService) PostDocument(ctx context.Context, organizationID string, in InventoryDocumentInput) (*InventoryDocument, error) {
	orgID, err := s.org(organizationID)
	if err != nil {
		return nil, err
	}
	switch in.Type {
	case InventoryDocReceipt, InventoryDocIssue, InventoryDocTransfer, InventoryDocWaste, InventoryDocCount:
	default:
		return nil, fmt.Errorf("%w: fiş türü", ErrInventoryInvalid)
	}
	today := IstanbulToday()
	date := today
	if in.Date != nil {
		date = time.Date(in.Date.Year(), in.Date.Month(), in.Date.Day(), 0, 0, 0, 0, time.UTC)
		if date.After(today) {
			return nil, fmt.Errorf("%w: ileri tarihli fiş kaydedilemez", ErrInventoryInvalid)
		}
	}
	if in.Counterparty, err = trimLen("Kimden/kime", in.Counterparty, 200); err != nil {
		return nil, err
	}
	if in.ReferenceNo, err = trimLen("İrsaliye no", in.ReferenceNo, 60); err != nil {
		return nil, err
	}
	if in.Note, err = trimLen("Not", in.Note, 1000); err != nil {
		return nil, err
	}
	if in.Type == InventoryDocWaste {
		if !inventoryWasteReasons[in.Reason] {
			return nil, fmt.Errorf("%w: fire nedeni seçin", ErrInventoryInvalid)
		}
	} else {
		in.Reason = ""
	}
	if len(in.Lines) == 0 || len(in.Lines) > inventoryMaxLines {
		return nil, fmt.Errorf("%w: fişte 1-%d satır olmalı", ErrInventoryInvalid, inventoryMaxLines)
	}
	key := strings.TrimSpace(in.IdempotencyKey)
	if len(key) > 100 {
		return nil, fmt.Errorf("%w: idempotency anahtarı", ErrInventoryInvalid)
	}
	if key != "" {
		if existing, err := s.q.GetInventoryDocumentByIdempotencyKey(ctx, sqlc.GetInventoryDocumentByIdempotencyKeyParams{
			OrganizationID: orgID, IdempotencyKey: &key,
		}); err == nil {
			return s.GetDocument(ctx, organizationID, existing.ID.String())
		} else if !errors.Is(err, pgx.ErrNoRows) {
			return nil, err
		}
	}
	whID, err := repository.StringToUUID(in.WarehouseID)
	if err != nil {
		return nil, ErrInventoryWarehouseNotFound
	}
	var targetID pgtype.UUID
	if in.Type == InventoryDocTransfer {
		if targetID, err = repository.StringToUUID(in.TargetWarehouseID); err != nil {
			return nil, fmt.Errorf("%w: hedef depoyu seçin", ErrInventoryInvalid)
		}
		if targetID == whID {
			return nil, fmt.Errorf("%w: hedef depo kaynak depodan farklı olmalı", ErrInventoryInvalid)
		}
	}
	var projectID, supplierID pgtype.UUID
	if in.Type == InventoryDocIssue {
		if projectID, err = optUUID(in.ProjectID); err != nil {
			return nil, &NotFoundError{What: "proje"}
		}
	}
	if in.Type == InventoryDocReceipt {
		if supplierID, err = optUUID(in.SupplierID); err != nil {
			return nil, &NotFoundError{What: "tedarikçi"}
		}
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	wh, err := activeWarehouse(ctx, txq, orgID, whID)
	if err != nil {
		return nil, err
	}
	var target sqlc.InventoryWarehouse
	if targetID.Valid {
		if target, err = activeWarehouse(ctx, txq, orgID, targetID); err != nil {
			return nil, err
		}
	}
	if projectID.Valid {
		if _, err := txq.GetProjectByID(ctx, sqlc.GetProjectByIDParams{ID: projectID, OrganizationID: orgID}); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return nil, &NotFoundError{What: "proje"}
			}
			return nil, err
		}
	}
	if supplierID.Valid {
		if _, err := txq.GetSupplier(ctx, sqlc.GetSupplierParams{ID: supplierID, OrganizationID: orgID}); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return nil, &NotFoundError{What: "tedarikçi"}
			}
			return nil, err
		}
	}
	items, err := lockInventoryItems(ctx, txq, orgID, lineItemIDs(in.Lines))
	if err != nil {
		return nil, err
	}

	docNo, err := nextInventoryDocNo(ctx, txq, orgID, date)
	if err != nil {
		return nil, err
	}
	var keyPtr *string
	if key != "" {
		keyPtr = &key
	}
	doc, err := txq.CreateInventoryDocument(ctx, sqlc.CreateInventoryDocumentParams{
		OrganizationID: orgID, DocNo: docNo, DocType: in.Type, DocDate: repository.TimeToDate(date),
		WarehouseID: whID, TargetWarehouseID: targetID, ProjectID: projectID, SupplierID: supplierID,
		Counterparty: in.Counterparty, ReferenceNo: in.ReferenceNo, Reason: in.Reason, Note: in.Note,
		IdempotencyKey: keyPtr, CreatedBy: actorUUID(in.UserID),
	})
	if err != nil {
		if isUniqueViolation(err) && key != "" {
			_ = tx.Rollback(ctx)
			if existing, gerr := s.q.GetInventoryDocumentByIdempotencyKey(ctx, sqlc.GetInventoryDocumentByIdempotencyKeyParams{
				OrganizationID: orgID, IdempotencyKey: &key,
			}); gerr == nil {
				return s.GetDocument(ctx, organizationID, existing.ID.String())
			}
		}
		return nil, err
	}

	p := &inventoryPoster{txq: txq, orgID: orgID, doc: doc, today: today}
	for n, ln := range in.Lines {
		item := items[ln.ItemID]
		label := fmt.Sprintf("satır %d (%s)", n+1, item.Name)
		switch in.Type {
		case InventoryDocReceipt:
			err = p.receive(ctx, wh, item, ln, label)
		case InventoryDocIssue, InventoryDocTransfer, InventoryDocWaste:
			err = p.takeOut(ctx, wh, target, item, ln, label, in.Type)
		case InventoryDocCount:
			err = p.count(ctx, wh, item, ln, label)
		}
		if err != nil {
			return nil, err
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out, err := s.GetDocument(ctx, organizationID, doc.ID.String())
	if err != nil {
		return nil, err
	}
	out.Warnings = p.warnings
	return out, nil
}

func activeWarehouse(ctx context.Context, txq *sqlc.Queries, orgID, id pgtype.UUID) (sqlc.InventoryWarehouse, error) {
	w, err := txq.GetInventoryWarehouse(ctx, sqlc.GetInventoryWarehouseParams{ID: id, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return w, ErrInventoryWarehouseNotFound
		}
		return w, err
	}
	if !w.IsActive {
		return w, &inventoryRuleError{kind: ErrInventoryInactive, msg: fmt.Sprintf("%s arşivde; işlem yapılamaz", w.Name)}
	}
	return w, nil
}

func lineItemIDs(lines []InventoryLineInput) []string {
	seen := map[string]bool{}
	var ids []string
	for _, l := range lines {
		if !seen[l.ItemID] {
			seen[l.ItemID] = true
			ids = append(ids, l.ItemID)
		}
	}
	sort.Strings(ids)
	return ids
}

// lockInventoryItems: kartları id sırasıyla kilitler (kilitlenme olmasın).
func lockInventoryItems(ctx context.Context, txq *sqlc.Queries, orgID pgtype.UUID, ids []string) (map[string]sqlc.InventoryItem, error) {
	out := make(map[string]sqlc.InventoryItem, len(ids))
	for _, id := range ids {
		iid, err := repository.StringToUUID(id)
		if err != nil {
			return nil, ErrInventoryItemNotFound
		}
		item, err := txq.GetInventoryItemForUpdate(ctx, sqlc.GetInventoryItemForUpdateParams{ID: iid, OrganizationID: orgID})
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return nil, ErrInventoryItemNotFound
			}
			return nil, err
		}
		if !item.IsActive {
			return nil, &inventoryRuleError{kind: ErrInventoryInactive, msg: fmt.Sprintf("%s arşivde; işlem yapılamaz", item.Name)}
		}
		out[id] = item
	}
	return out, nil
}

func nextInventoryDocNo(ctx context.Context, txq *sqlc.Queries, orgID pgtype.UUID, date time.Time) (string, error) {
	seq, err := txq.NextInventoryDocumentSeq(ctx, sqlc.NextInventoryDocumentSeqParams{OrganizationID: orgID, Year: int32(date.Year())})
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("STK-%d-%05d", date.Year(), seq), nil
}

// inventoryPoster: bir fişin satırlarını yazar.
type inventoryPoster struct {
	txq      *sqlc.Queries
	orgID    pgtype.UUID
	doc      sqlc.InventoryDocument
	today    time.Time
	lineNo   int32
	avg      map[pgtype.UUID]float64
	warnings []string
}

func (p *inventoryPoster) avgCost(item sqlc.InventoryItem) float64 {
	if v, ok := p.avg[item.ID]; ok {
		return v
	}
	return numF(item.AvgUnitCost)
}

func (p *inventoryPoster) move(ctx context.Context, warehouseID pgtype.UUID, item sqlc.InventoryItem, lotID pgtype.UUID, qty, cost float64, label string) error {
	var err error
	if qty > 0 {
		_, err = p.txq.AddInventoryBalance(ctx, sqlc.AddInventoryBalanceParams{
			OrganizationID: p.orgID, WarehouseID: warehouseID, ItemID: item.ID, LotID: lotID, Quantity: qtyNumeric(qty),
		})
	} else {
		_, err = p.txq.SubtractInventoryBalance(ctx, sqlc.SubtractInventoryBalanceParams{
			Quantity: qtyNumeric(-qty), WarehouseID: warehouseID, ItemID: item.ID, LotID: lotID,
		})
	}
	if err != nil {
		if isCheckViolation(err) || errors.Is(err, pgx.ErrNoRows) {
			return &inventoryRuleError{kind: ErrInventoryInsufficient, msg: fmt.Sprintf("%s: yeterli stok yok", label)}
		}
		return err
	}
	return p.txq.CreateInventoryMovement(ctx, sqlc.CreateInventoryMovementParams{
		OrganizationID: p.orgID, DocumentID: p.doc.ID, LineNo: p.lineNo, WarehouseID: warehouseID,
		ItemID: item.ID, LotID: lotID, Quantity: qtyNumeric(qty), UnitCost: costNumeric(cost),
	})
}

func validQty(q float64, label string) (float64, error) {
	q = roundQty(q)
	if q <= 0 || q > inventoryMaxQuantity {
		return 0, fmt.Errorf("%w: %s: miktar sıfırdan büyük olmalı", ErrInventoryInvalid, label)
	}
	return q, nil
}

func (p *inventoryPoster) receive(ctx context.Context, wh sqlc.InventoryWarehouse, item sqlc.InventoryItem, ln InventoryLineInput, label string) error {
	p.lineNo++
	qty, err := validQty(ln.Quantity, label)
	if err != nil {
		return err
	}
	lotID, err := p.receiptLot(ctx, item, ln, label)
	if err != nil {
		return err
	}
	cost := p.avgCost(item)
	if ln.UnitCost != nil {
		c := *ln.UnitCost
		if c < 0 || c > 1e12 {
			return fmt.Errorf("%w: %s: birim fiyat", ErrInventoryInvalid, label)
		}
		newAvg, err := p.txq.ApplyInventoryCost(ctx, sqlc.ApplyInventoryCostParams{
			Quantity: qtyNumeric(qty), UnitCost: costNumeric(c), ItemID: item.ID,
		})
		if err != nil {
			return err
		}
		if p.avg == nil {
			p.avg = map[pgtype.UUID]float64{}
		}
		p.avg[item.ID] = numF(newAvg)
		cost = c
	}
	return p.move(ctx, wh.ID, item, lotID, qty, cost, label)
}

// receiptLot: girişin partisi. SKT takipli malzemede SKT zorunludur (ya da
// üretim tarihi + kartın raf ömrü). Takipsiz malzemede yalnızca parti no
// girilirse parti açılır.
func (p *inventoryPoster) receiptLot(ctx context.Context, item sqlc.InventoryItem, ln InventoryLineInput, label string) (pgtype.UUID, error) {
	lotNo, err := trimLen("Parti no", ln.LotNo, 60)
	if err != nil {
		return pgtype.UUID{}, err
	}
	expiry := ln.ExpiryDate
	prod := ln.ProductionDate
	if prod != nil && prod.After(p.today) {
		return pgtype.UUID{}, fmt.Errorf("%w: %s: üretim tarihi ileri olamaz", ErrInventoryInvalid, label)
	}
	if expiry == nil && prod != nil && item.ShelfLifeMonths != nil {
		e := prod.AddDate(0, int(*item.ShelfLifeMonths), 0)
		expiry = &e
	}
	if item.TrackExpiry && expiry == nil {
		return pgtype.UUID{}, fmt.Errorf("%w: %s: son kullanma tarihini girin (ya da kartta raf ömrü varsa üretim tarihini)", ErrInventoryInvalid, label)
	}
	if !item.TrackExpiry && lotNo == "" && expiry == nil {
		return pgtype.UUID{}, nil
	}
	if expiry != nil && expiry.Before(p.today) {
		p.warnings = append(p.warnings, fmt.Sprintf("%s: SKT'si geçmiş parti girildi (%s)", item.Name, expiry.Format("02.01.2006")))
	}
	var exp, pr pgtype.Date
	if expiry != nil {
		exp = repository.TimeToDate(*expiry)
	}
	if prod != nil {
		pr = repository.TimeToDate(*prod)
	}
	lot, err := p.txq.UpsertInventoryLot(ctx, sqlc.UpsertInventoryLotParams{
		OrganizationID: p.orgID, ItemID: item.ID, LotNo: lotNo, ExpiryDate: exp, ProductionDate: pr,
	})
	if err != nil {
		return pgtype.UUID{}, err
	}
	return lot.ID, nil
}

type inventoryAllocation struct {
	lotID   pgtype.UUID
	qty     float64
	expired bool
	lotText string
}

// takeOut: çıkış, aktarım ve fire. Parti verilmezse önce bozulacak önce
// (FEFO) dağıtılır. SKT'si geçmiş parti: 'block' kartta yalnızca fire
// olarak çıkar; 'warn' kartta çıkar ama yanıtta uyarı döner.
func (p *inventoryPoster) takeOut(ctx context.Context, wh, target sqlc.InventoryWarehouse, item sqlc.InventoryItem, ln InventoryLineInput, label, docType string) error {
	p.lineNo++
	qty, err := validQty(ln.Quantity, label)
	if err != nil {
		return err
	}
	rows, err := p.txq.LockInventoryBalances(ctx, sqlc.LockInventoryBalancesParams{WarehouseID: wh.ID, ItemID: item.ID})
	if err != nil {
		return err
	}
	allowExpired := docType == InventoryDocWaste || item.ExpiryPolicy == InventoryPolicyWarn
	var wantLot pgtype.UUID
	if strings.TrimSpace(ln.LotID) != "" {
		if wantLot, err = repository.StringToUUID(ln.LotID); err != nil {
			return ErrInventoryLotNotFound
		}
	}
	var allocs []inventoryAllocation
	remaining := qty
	usable, blocked := 0.0, 0.0
	for _, r := range rows {
		if wantLot.Valid && r.LotID != wantLot {
			continue
		}
		have := numF(r.Quantity)
		expired := r.ExpiryDate.Valid && r.ExpiryDate.Time.Before(p.today)
		if expired && !allowExpired {
			blocked += have
			continue
		}
		usable += have
		if remaining <= 0 {
			continue
		}
		take := have
		if take > remaining {
			take = remaining
		}
		lotText := ""
		if r.ExpiryDate.Valid {
			lotText = "SKT " + r.ExpiryDate.Time.Format("02.01.2006")
		}
		if r.LotNo != nil && *r.LotNo != "" {
			lotText = strings.TrimSpace("parti " + *r.LotNo + " " + lotText)
		}
		allocs = append(allocs, inventoryAllocation{lotID: r.LotID, qty: roundQty(take), expired: expired, lotText: lotText})
		remaining = roundQty(remaining - take)
	}
	if remaining > 0 {
		if blocked > 0 {
			return &inventoryRuleError{kind: ErrInventoryExpiredBlocked, msg: fmt.Sprintf(
				"%s: %s deposunda kullanılabilir %s var, %s SKT'si geçtiği için çıkamaz (fire olarak kaydedin)",
				label, wh.Name, fmtQty(usable, item.Unit), fmtQty(blocked, item.Unit))}
		}
		return &inventoryRuleError{kind: ErrInventoryInsufficient, msg: fmt.Sprintf(
			"%s: %s deposunda %s var, %s istendi", label, wh.Name, fmtQty(usable, item.Unit), fmtQty(qty, item.Unit))}
	}
	cost := p.avgCost(item)
	for _, a := range allocs {
		if a.expired && docType != InventoryDocWaste {
			p.warnings = append(p.warnings, fmt.Sprintf("%s: SKT'si geçmiş parti kullanıldı (%s)", item.Name, a.lotText))
		}
		if err := p.move(ctx, wh.ID, item, a.lotID, -a.qty, cost, label); err != nil {
			return err
		}
		if docType == InventoryDocTransfer {
			if err := p.move(ctx, target.ID, item, a.lotID, a.qty, cost, label); err != nil {
				return err
			}
		}
	}
	return nil
}

// count: sayılan miktarı yazar, farkı düzeltme hareketi olarak kaydeder.
func (p *inventoryPoster) count(ctx context.Context, wh sqlc.InventoryWarehouse, item sqlc.InventoryItem, ln InventoryLineInput, label string) error {
	p.lineNo++
	if ln.CountedQuantity == nil {
		return fmt.Errorf("%w: %s: sayılan miktarı girin", ErrInventoryInvalid, label)
	}
	counted := roundQty(*ln.CountedQuantity)
	if counted < 0 || counted > inventoryMaxQuantity {
		return fmt.Errorf("%w: %s: sayılan miktar", ErrInventoryInvalid, label)
	}
	var lotID pgtype.UUID
	switch {
	case strings.TrimSpace(ln.LotID) != "":
		id, err := repository.StringToUUID(ln.LotID)
		if err != nil {
			return ErrInventoryLotNotFound
		}
		lot, err := p.txq.GetInventoryLot(ctx, sqlc.GetInventoryLotParams{ID: id, OrganizationID: p.orgID})
		if err != nil || lot.ItemID != item.ID {
			return ErrInventoryLotNotFound
		}
		lotID = lot.ID
	case strings.TrimSpace(ln.LotNo) != "" || ln.ExpiryDate != nil:
		id, err := p.receiptLot(ctx, item, ln, label)
		if err != nil {
			return err
		}
		lotID = id
	}
	current, err := p.txq.GetInventoryBalanceQuantity(ctx, sqlc.GetInventoryBalanceQuantityParams{
		WarehouseID: wh.ID, ItemID: item.ID, LotID: lotID,
	})
	if err != nil {
		return err
	}
	diff := roundQty(counted - numF(current))
	if diff == 0 {
		return nil
	}
	return p.move(ctx, wh.ID, item, lotID, diff, p.avgCost(item), label)
}

// ReverseDocument: fişi iptal eder -- satırların tersini yazan bir iptal
// fişi açar. Girişin iptali ortalama maliyeti geri alır; çıkmış stoğun
// girişi iptal edilemez (bakiye eksiye düşerdi).
func (s *InventoryService) ReverseDocument(ctx context.Context, organizationID, documentID, userID, reason string) (*InventoryDocument, error) {
	orgID, err := s.org(organizationID)
	if err != nil {
		return nil, err
	}
	did, err := repository.StringToUUID(documentID)
	if err != nil {
		return nil, ErrInventoryDocumentNotFound
	}
	if reason, err = trimLen("Gerekçe", reason, 500); err != nil {
		return nil, err
	}
	if reason == "" {
		return nil, fmt.Errorf("%w: iptal gerekçesi zorunlu", ErrInventoryInvalid)
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	doc, err := txq.GetInventoryDocumentForUpdate(ctx, sqlc.GetInventoryDocumentForUpdateParams{ID: did, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrInventoryDocumentNotFound
		}
		return nil, err
	}
	if doc.DocType == InventoryDocReversal {
		return nil, ErrInventoryNotReversible
	}
	if doc.Status != "posted" {
		return nil, ErrInventoryAlreadyReversed
	}
	moves, err := txq.ListInventoryDocumentMovements(ctx, sqlc.ListInventoryDocumentMovementsParams{DocumentID: did, OrganizationID: orgID})
	if err != nil {
		return nil, err
	}
	ids := make([]string, 0, len(moves))
	for _, m := range moves {
		ids = append(ids, m.ItemID.String())
	}
	sort.Strings(ids)
	items := map[pgtype.UUID]sqlc.InventoryItem{}
	for _, id := range ids {
		iid, _ := repository.StringToUUID(id)
		if _, ok := items[iid]; ok {
			continue
		}
		item, err := txq.GetInventoryItemForUpdate(ctx, sqlc.GetInventoryItemForUpdateParams{ID: iid, OrganizationID: orgID})
		if err != nil {
			return nil, err
		}
		items[iid] = item
	}
	today := IstanbulToday()
	docNo, err := nextInventoryDocNo(ctx, txq, orgID, today)
	if err != nil {
		return nil, err
	}
	rev, err := txq.CreateInventoryDocument(ctx, sqlc.CreateInventoryDocumentParams{
		OrganizationID: orgID, DocNo: docNo, DocType: InventoryDocReversal, DocDate: repository.TimeToDate(today),
		WarehouseID: doc.WarehouseID, TargetWarehouseID: doc.TargetWarehouseID, ProjectID: doc.ProjectID,
		SupplierID: doc.SupplierID, Counterparty: doc.Counterparty, ReferenceNo: doc.ReferenceNo,
		Note: reason, ReversalOfID: doc.ID, CreatedBy: actorUUID(userID),
	})
	if err != nil {
		return nil, err
	}
	p := &inventoryPoster{txq: txq, orgID: orgID, doc: rev, today: today}
	for _, m := range moves {
		item := items[m.ItemID]
		p.lineNo = m.LineNo
		qty := -numF(m.Quantity)
		cost := numF(m.UnitCost)
		if doc.DocType == InventoryDocReceipt && qty < 0 {
			if _, err := txq.ApplyInventoryCost(ctx, sqlc.ApplyInventoryCostParams{
				Quantity: qtyNumeric(qty), UnitCost: costNumeric(cost), ItemID: item.ID,
			}); err != nil {
				return nil, err
			}
		}
		if err := p.move(ctx, m.WarehouseID, item, m.LotID, qty, cost, item.Name); err != nil {
			if errors.Is(err, ErrInventoryInsufficient) {
				return nil, &inventoryRuleError{kind: ErrInventoryInsufficient, msg: fmt.Sprintf(
					"%s: fiş iptal edilemez, %s deposundaki stok zaten kullanılmış", item.Name, m.WarehouseName)}
			}
			return nil, err
		}
	}
	if err := txq.MarkInventoryDocumentReversed(ctx, sqlc.MarkInventoryDocumentReversedParams{
		ReversedBy: actorUUID(userID), ReverseReason: reason, ID: doc.ID, OrganizationID: orgID,
	}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	return s.GetDocument(ctx, organizationID, rev.ID.String())
}

// ---------- Okuma ----------

func (s *InventoryService) ListDocuments(ctx context.Context, organizationID string, f InventoryDocumentFilter) ([]InventoryDocumentSummary, error) {
	orgID, err := s.org(organizationID)
	if err != nil {
		return nil, err
	}
	params := sqlc.ListInventoryDocumentsParams{OrganizationID: orgID, RowLimit: int32(f.Limit), RowOffset: int32(f.Offset)}
	if params.RowLimit <= 0 || params.RowLimit > 200 {
		params.RowLimit = 100
	}
	if params.RowOffset < 0 {
		params.RowOffset = 0
	}
	if f.Type != "" {
		t := f.Type
		params.DocType = &t
	}
	if params.WarehouseID, err = optUUID(f.WarehouseID); err != nil {
		return nil, ErrInventoryWarehouseNotFound
	}
	if params.ItemID, err = optUUID(f.ItemID); err != nil {
		return nil, ErrInventoryItemNotFound
	}
	if params.ProjectID, err = optUUID(f.ProjectID); err != nil {
		return nil, &NotFoundError{What: "proje"}
	}
	rows, err := s.q.ListInventoryDocuments(ctx, params)
	if err != nil {
		return nil, err
	}
	out := make([]InventoryDocumentSummary, len(rows))
	for i, r := range rows {
		out[i] = InventoryDocumentSummary{
			ID: r.ID.String(), DocNo: r.DocNo, DocType: r.DocType, DocDate: r.DocDate.Time, Status: r.Status,
			Counterparty: r.Counterparty, ReferenceNo: r.ReferenceNo, Reason: r.Reason,
			WarehouseName: r.WarehouseName, TargetWarehouseName: r.TargetWarehouseName,
			ProjectName: r.ProjectName, CreatedByName: r.CreatedByName, CreatedAt: r.CreatedAt.Time,
			ItemCount: int(r.ItemCount), FirstItemName: r.FirstItemName, IsReversal: r.ReversalOfID.Valid,
		}
	}
	return out, nil
}

func (s *InventoryService) GetDocument(ctx context.Context, organizationID, documentID string) (*InventoryDocument, error) {
	orgID, err := s.org(organizationID)
	if err != nil {
		return nil, err
	}
	did, err := repository.StringToUUID(documentID)
	if err != nil {
		return nil, ErrInventoryDocumentNotFound
	}
	d, err := s.q.GetInventoryDocument(ctx, sqlc.GetInventoryDocumentParams{ID: did, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrInventoryDocumentNotFound
		}
		return nil, err
	}
	out := &InventoryDocument{
		InventoryDocumentSummary: InventoryDocumentSummary{
			ID: d.ID.String(), DocNo: d.DocNo, DocType: d.DocType, DocDate: d.DocDate.Time, Status: d.Status,
			Counterparty: d.Counterparty, ReferenceNo: d.ReferenceNo, Reason: d.Reason,
			WarehouseName: d.WarehouseName, TargetWarehouseName: d.TargetWarehouseName, ProjectName: d.ProjectName,
			CreatedByName: d.CreatedByName, CreatedAt: d.CreatedAt.Time, IsReversal: d.ReversalOfID.Valid,
		},
		WarehouseID: d.WarehouseID.String(), ProjectNo: d.ProjectNo, SupplierName: d.SupplierName, Note: d.Note,
		AttachmentName: d.AttachmentName, AttachmentMime: d.AttachmentMime, ReversalOfNo: d.ReversalOfNo,
		ReversedByDocID: d.ReversedByDocID, ReversedByDocNo: d.ReversedByDocNo, ReversedByName: d.ReversedByName,
		ReverseReason: d.ReverseReason,
	}
	if d.TargetWarehouseID.Valid {
		out.TargetWarehouseID = d.TargetWarehouseID.String()
	}
	if d.ProjectID.Valid {
		out.ProjectID = d.ProjectID.String()
	}
	if d.SupplierID.Valid {
		out.SupplierID = d.SupplierID.String()
	}
	if d.ReversalOfID.Valid {
		out.ReversalOfID = d.ReversalOfID.String()
	}
	if d.ReversedAt.Valid {
		t := d.ReversedAt.Time
		out.ReversedAt = &t
	}
	moves, err := s.q.ListInventoryDocumentMovements(ctx, sqlc.ListInventoryDocumentMovementsParams{DocumentID: did, OrganizationID: orgID})
	if err != nil {
		return nil, err
	}
	items := map[string]bool{}
	for _, m := range moves {
		line := InventoryLine{
			LineNo: int(m.LineNo), ItemID: m.ItemID.String(), ItemCode: m.ItemCode, ItemName: m.ItemName, Unit: m.Unit,
			WarehouseID: m.WarehouseID.String(), WarehouseName: m.WarehouseName, LotNo: m.LotNo,
			ExpiryDate: datePtr(m.ExpiryDate), Quantity: numF(m.Quantity), UnitCost: numF(m.UnitCost),
		}
		if m.LotID.Valid {
			line.LotID = m.LotID.String()
		}
		items[line.ItemID] = true
		out.Lines = append(out.Lines, line)
	}
	out.ItemCount = len(items)
	if len(out.Lines) > 0 {
		out.FirstItemName = out.Lines[0].ItemName
	}
	return out, nil
}

// ---------- İrsaliye / belge fotoğrafı ----------

// SetAttachment: fişe irsaliye fotoğrafı ya da PDF ekler (öncekinin
// yerine). Tür içerikten tespit edilir.
func (s *InventoryService) SetAttachment(ctx context.Context, organizationID, documentID, name string, r io.Reader) (*InventoryDocument, error) {
	orgID, err := s.org(organizationID)
	if err != nil {
		return nil, err
	}
	did, err := repository.StringToUUID(documentID)
	if err != nil {
		return nil, ErrInventoryDocumentNotFound
	}
	current, err := s.q.GetInventoryDocument(ctx, sqlc.GetInventoryDocumentParams{ID: did, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrInventoryDocumentNotFound
		}
		return nil, err
	}
	mime, body, n, err := sniffMIME(io.LimitReader(r, MaxUploadBytes+1))
	if err != nil {
		return nil, err
	}
	if n == 0 {
		return nil, ErrEmptyFile
	}
	if !strings.HasPrefix(mime, "image/") && mime != "application/pdf" {
		return nil, ErrUnsupportedType
	}
	name = strings.TrimSpace(name)
	if name == "" {
		name = "irsaliye"
	}
	name = truncateRunes(name, 255)
	key := storage.BuildKey("inventory", orgID.String(), "documents", uuid.NewString(), name)
	obj, err := s.store.Put(ctx, key, body)
	if err != nil {
		return nil, wrapStorageErr(err)
	}
	if obj.Size > MaxUploadBytes {
		_ = s.store.Delete(ctx, key)
		return nil, ErrFileTooLarge
	}
	if err := s.q.SetInventoryDocumentAttachment(ctx, sqlc.SetInventoryDocumentAttachmentParams{
		AttachmentKey: key, AttachmentMime: mime, AttachmentName: name, ID: did, OrganizationID: orgID,
	}); err != nil {
		_ = s.store.Delete(ctx, key)
		return nil, err
	}
	if current.AttachmentKey != "" {
		_ = s.store.Delete(ctx, current.AttachmentKey)
	}
	return s.GetDocument(ctx, organizationID, documentID)
}

// OpenAttachment: fişin eki (tür, ad, içerik).
func (s *InventoryService) OpenAttachment(ctx context.Context, organizationID, documentID string) (string, string, io.ReadCloser, error) {
	orgID, err := s.org(organizationID)
	if err != nil {
		return "", "", nil, err
	}
	did, err := repository.StringToUUID(documentID)
	if err != nil {
		return "", "", nil, ErrInventoryDocumentNotFound
	}
	d, err := s.q.GetInventoryDocument(ctx, sqlc.GetInventoryDocumentParams{ID: did, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return "", "", nil, ErrInventoryDocumentNotFound
		}
		return "", "", nil, err
	}
	if d.AttachmentKey == "" {
		return "", "", nil, &NotFoundError{What: "ek"}
	}
	rc, err := s.store.Open(ctx, d.AttachmentKey)
	if err != nil {
		return "", "", nil, wrapStorageErr(err)
	}
	return d.AttachmentMime, d.AttachmentName, rc, nil
}
