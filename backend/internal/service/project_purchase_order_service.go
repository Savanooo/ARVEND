package service

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

// ARVEND V2 — Sprint 4: Procurement Foundation, Purchase Order + Cost
// Control entegrasyonu. *ProjectService üzerinde metodlar. BU DOSYA,
// sprintin EN KRİTİK entegrasyon noktasını içerir (bkz. docs/
// procurement.md "Cost Control Entegrasyonu"):
//
//	PO APPROVED  = COMMITTED  (her PO kalemi TEK bir project_commitments
//	               satırına dönüşür, source_type='purchase_order',
//	               source_id=purchase_order_items.id -- İTEM seviyesinde,
//	               PO seviyesinde DEĞİL, çünkü her kalem FARKLI bir
//	               cost_code/budget_line'a bağlı olabilir)
//	PO CANCELLED (approved'tan) = BAĞLI commitment'lar VOID edilir
//	PO CLOSED    = commitment'a DOKUNULMAZ (bkz. migration §7 gerekçesi --
//	               taahhüt gerçek bir Actual/iptal ile değişene kadar
//	               committed kalmaya devam eder)
//	PO APPROVED ASLA "actual cost" OLUŞTURMAZ -- Actual, ileride Supplier
//	               Invoice/Receipt/Expense üzerinden oluşacaktır (bu
//	               sprintin kapsamı DIŞI).
//
// Mevcut Sprint 2 CreateCommitment/VoidCommitment (MANUEL taahhütler)
// akışına HİÇBİR DOKUNMA yapılmaz -- bu dosya SourceType/SourceID'yi
// AÇIKÇA yazan AYRI bir yol kullanır (CreateCommitmentFromSource/
// VoidCommitmentsBySourcePOItems, bkz. cost_control.sql).

var (
	ErrPurchaseOrderNotEditable      = errors.New("sipariş yalnızca taslak durumdayken düzenlenebilir")
	ErrPurchaseOrderNotApprovable    = errors.New("yalnızca taslak bir sipariş onaylanabilir")
	ErrPurchaseOrderNotCancellable   = errors.New("bu durumdaki bir sipariş iptal edilemez")
	ErrPurchaseOrderNotCloseable     = errors.New("yalnızca onaylı bir sipariş kapatılabilir")
	ErrPurchaseOrderItemsRequired    = errors.New("sipariş en az bir kalem içermelidir")
	ErrPurchaseOrderSupplierInactive = errors.New("arşivlenmiş bir tedarikçiye yeni sipariş açılamaz")
	ErrPurchaseOrderReasonRequired   = errors.New("gerekçe zorunludur")

	ErrPurchaseOrderQuotationNotAwarded     = errors.New("sipariş yalnızca RFQ'nun kazanan (ödül verilmiş) teklifinden oluşturulabilir")
	ErrPurchaseOrderSupplierMismatch        = errors.New("siparişin tedarikçisi, kaynak teklifi veren tedarikçiyle aynı olmalı")
	ErrPurchaseOrderQuotationAlreadyOrdered = errors.New("bu teklif için zaten bir sipariş var; yeni sipariş açmadan önce mevcut siparişi iptal edin")
)

type PurchaseOrderItemInput struct {
	WBSNodeID    string
	CostCodeID   string // ZORUNLU -- her kalem approval'da BİR commitment'a dönüşür
	BudgetLineID string
	Description  string
	Quantity     float64
	Unit         string
	UnitPrice    float64
}

type PurchaseOrderInput struct {
	SupplierID           string
	SourceRFQID          string
	SourceQuotationID    string
	IssueDate            time.Time
	ExpectedDeliveryDate *time.Time
	PaymentTerms         string
	DeliveryAddress      string
	Notes                string
	TaxRate              float64
	Items                []PurchaseOrderItemInput
	UserID               string
}

func (s *ProjectService) generatePONo(ctx context.Context, q *sqlc.Queries, orgID pgtype.UUID) (string, error) {
	year := time.Now().Year()
	seq, err := q.NextPurchaseOrderSeq(ctx, sqlc.NextPurchaseOrderSeqParams{OrganizationID: orgID, Year: int32(year)})
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("PO-%d-%04d", year, seq), nil
}

func insertPurchaseOrderItems(ctx context.Context, txq *sqlc.Queries, orgID, pid, poID pgtype.UUID, items []PurchaseOrderItemInput) error {
	if err := txq.DeletePurchaseOrderItems(ctx, sqlc.DeletePurchaseOrderItemsParams{PurchaseOrderID: poID, OrganizationID: orgID, ProjectID: pid}); err != nil {
		return err
	}
	for i, it := range items {
		wbsID, err := resolveWBSParentRef(ctx, txq, it.WBSNodeID, pid, orgID)
		if err != nil {
			return err
		}
		if strings.TrimSpace(it.CostCodeID) == "" {
			return ErrInvalidBudgetLineCostCode
		}
		costCodeID, err := resolveCostCodeRef(ctx, txq, it.CostCodeID, orgID)
		if err != nil {
			return err
		}
		budgetLineID, err := resolveBudgetLineRef(ctx, txq, it.BudgetLineID, pid, orgID)
		if err != nil {
			return err
		}
		desc := strings.TrimSpace(it.Description)
		if desc == "" {
			return ErrItemDescriptionRequired
		}
		if it.Quantity <= 0 {
			return ErrInvalidQuantity
		}
		if it.UnitPrice <= 0 {
			return ErrInvalidUnitPrice
		}
		if _, err := txq.CreatePurchaseOrderItem(ctx, sqlc.CreatePurchaseOrderItemParams{
			OrganizationID: orgID, ProjectID: pid, PurchaseOrderID: poID,
			WbsNodeID: wbsID, CostCodeID: costCodeID, BudgetLineID: budgetLineID,
			Description: desc, Quantity: repository.Float64ToNumeric(it.Quantity), Unit: it.Unit,
			UnitPrice: repository.Float64ToNumeric(it.UnitPrice), SortOrder: int32(i),
		}); err != nil {
			return err
		}
	}
	return nil
}

func (s *ProjectService) CreatePurchaseOrder(ctx context.Context, projectID, organizationID string, in PurchaseOrderInput) (*domain.PurchaseOrder, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	supplierID, err := repository.StringToUUID(strings.TrimSpace(in.SupplierID))
	if err != nil {
		return nil, ErrSupplierRefNotFound
	}
	if len(in.Items) == 0 {
		return nil, ErrPurchaseOrderItemsRequired
	}
	if err := validatePercent(in.TaxRate, ErrInvalidTaxRate); err != nil {
		return nil, err
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	project, err := s.requireOpenProject(ctx, txq, pid, orgID)
	if err != nil {
		return nil, err
	}
	supplier, err := txq.GetSupplier(ctx, sqlc.GetSupplierParams{ID: supplierID, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrSupplierRefNotFound
		}
		return nil, err
	}
	if !supplier.IsActive {
		return nil, ErrPurchaseOrderSupplierInactive
	}

	var rfqID, quotationID pgtype.UUID
	if v := strings.TrimSpace(in.SourceRFQID); v != "" {
		rfqID, err = repository.StringToUUID(v)
		if err != nil {
			return nil, ErrSourceRFQRefNotFound
		}
		if _, err := txq.GetRFQ(ctx, sqlc.GetRFQParams{ID: rfqID, OrganizationID: orgID, ProjectID: pid}); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return nil, ErrSourceRFQRefNotFound
			}
			return nil, err
		}
	}
	if v := strings.TrimSpace(in.SourceQuotationID); v != "" {
		quotationID, err = repository.StringToUUID(v)
		if err != nil {
			return nil, ErrSourceQuotationNotFound
		}
		// Teklif satırı KİLİTLENİR: aynı teklifle eşzamanlı iki sipariş
		// açma isteği serileşir, ikincisi aşağıdaki "zaten siparişe
		// dönüşmüş" kontrolünü görür.
		quotation, err := txq.GetSupplierQuotationForUpdate(ctx, sqlc.GetSupplierQuotationForUpdateParams{ID: quotationID, OrganizationID: orgID, ProjectID: pid})
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return nil, ErrSourceQuotationNotFound
			}
			return nil, err
		}
		// Kaynak RFQ VERİLMİŞSE, teklif GERÇEKTEN o RFQ'ya ait olmalı
		// (çapraz-RFQ referans İMKANSIZ olmalı -- AwardRFQ'daki AYNI
		// ErrAwardQuotationMismatch ilkesi).
		if rfqID.Valid && quotation.RfqID != rfqID {
			return nil, ErrAwardQuotationMismatch
		}
		// Teklif, RFQ'nun KAZANAN teklifi olmalı, sipariş o teklifi veren
		// tedarikçiye açılmalı ve teklif başına yalnızca bir (iptal
		// edilmemiş) sipariş olabilir. Önceden yalnızca RFQ eşleşmesi
		// kontrol ediliyordu: kaybeden bir tekliften, başka bir tedarikçiye
		// ya da aynı tekliften birden fazla sipariş (çift taahhüt)
		// açılabiliyordu.
		rfq, err := txq.GetRFQ(ctx, sqlc.GetRFQParams{ID: quotation.RfqID, OrganizationID: orgID, ProjectID: pid})
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return nil, domain.ErrNotFound
			}
			return nil, err
		}
		if !rfq.AwardedQuotationID.Valid || rfq.AwardedQuotationID != quotationID {
			return nil, ErrPurchaseOrderQuotationNotAwarded
		}
		if quotation.SupplierID != supplierID {
			return nil, ErrPurchaseOrderSupplierMismatch
		}
		existing, err := txq.CountOpenPurchaseOrdersForQuotation(ctx, sqlc.CountOpenPurchaseOrdersForQuotationParams{
			SourceQuotationID: quotationID, OrganizationID: orgID, ProjectID: pid,
		})
		if err != nil {
			return nil, err
		}
		if existing > 0 {
			return nil, ErrPurchaseOrderQuotationAlreadyOrdered
		}
		rfqID = quotation.RfqID
	}

	poNo, err := s.generatePONo(ctx, txq, orgID)
	if err != nil {
		return nil, err
	}
	row, err := txq.CreatePurchaseOrder(ctx, sqlc.CreatePurchaseOrderParams{
		OrganizationID: orgID, ProjectID: pid, PoNo: poNo, SupplierID: supplierID,
		SourceRfqID: rfqID, SourceQuotationID: quotationID, Currency: project.Currency,
		IssueDate: repository.TimeToDate(in.IssueDate), ExpectedDeliveryDate: repository.TimePtrToDate(in.ExpectedDeliveryDate),
		PaymentTerms: in.PaymentTerms, DeliveryAddress: in.DeliveryAddress, Notes: in.Notes,
		TaxRate: repository.Float64ToNumeric(in.TaxRate), CreatedBy: actorUUID(in.UserID),
	})
	if err != nil {
		return nil, err
	}
	if err := insertPurchaseOrderItems(ctx, txq, orgID, pid, row.ID, in.Items); err != nil {
		return nil, err
	}
	row, err = txq.RecomputePurchaseOrderTotals(ctx, sqlc.RecomputePurchaseOrderTotalsParams{ID: row.ID, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		return nil, err
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventPurchaseOrderCreated, actorUUID(in.UserID),
		map[string]any{"purchase_order_id": row.ID.String(), "po_no": row.PoNo, "supplier_id": in.SupplierID}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainPurchaseOrder(row)
	return &out, nil
}

func (s *ProjectService) GetPurchaseOrder(ctx context.Context, projectID, poID, organizationID string) (*domain.PurchaseOrder, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	id, err := repository.StringToUUID(poID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	row, err := s.q.GetPurchaseOrder(ctx, sqlc.GetPurchaseOrderParams{ID: id, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		return nil, domain.ErrNotFound
	}
	out := repository.ToDomainPurchaseOrder(row)
	return &out, nil
}

func (s *ProjectService) ListPurchaseOrders(ctx context.Context, projectID, organizationID string) ([]repository.PurchaseOrderDetailed, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	rows, err := s.q.ListPurchaseOrders(ctx, sqlc.ListPurchaseOrdersParams{ProjectID: pid, OrganizationID: orgID})
	if err != nil {
		return nil, err
	}
	out := make([]repository.PurchaseOrderDetailed, len(rows))
	for i, r := range rows {
		out[i] = repository.ToDomainPurchaseOrderDetailed(r)
	}
	return out, nil
}

func (s *ProjectService) ListPurchaseOrderItems(ctx context.Context, projectID, poID, organizationID string) ([]domain.PurchaseOrderItem, error) {
	if _, err := s.GetPurchaseOrder(ctx, projectID, poID, organizationID); err != nil {
		return nil, err
	}
	id, _ := repository.StringToUUID(poID)
	rows, err := s.q.ListPurchaseOrderItems(ctx, id)
	if err != nil {
		return nil, err
	}
	out := make([]domain.PurchaseOrderItem, len(rows))
	for i, r := range rows {
		out[i] = repository.ToDomainPurchaseOrderItem(r)
	}
	return out, nil
}

func (s *ProjectService) UpdatePurchaseOrderDraft(ctx context.Context, projectID, poID, organizationID string, in PurchaseOrderInput) (*domain.PurchaseOrder, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	id, err := repository.StringToUUID(poID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	if len(in.Items) == 0 {
		return nil, ErrPurchaseOrderItemsRequired
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	row, err := txq.UpdatePurchaseOrderFields(ctx, sqlc.UpdatePurchaseOrderFieldsParams{
		ID: id, OrganizationID: orgID, ProjectID: pid,
		IssueDate: repository.TimeToDate(in.IssueDate), ExpectedDeliveryDate: repository.TimePtrToDate(in.ExpectedDeliveryDate),
		PaymentTerms: in.PaymentTerms, DeliveryAddress: in.DeliveryAddress, Notes: in.Notes, TaxRate: repository.Float64ToNumeric(in.TaxRate),
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			if _, gerr := txq.GetPurchaseOrder(ctx, sqlc.GetPurchaseOrderParams{ID: id, OrganizationID: orgID, ProjectID: pid}); gerr != nil {
				return nil, domain.ErrNotFound
			}
			return nil, ErrPurchaseOrderNotEditable
		}
		return nil, err
	}
	if err := insertPurchaseOrderItems(ctx, txq, orgID, pid, id, in.Items); err != nil {
		return nil, err
	}
	row, err = txq.RecomputePurchaseOrderTotals(ctx, sqlc.RecomputePurchaseOrderTotalsParams{ID: id, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		return nil, err
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventPurchaseOrderUpdated, actorUUID(in.UserID),
		map[string]any{"purchase_order_id": poID}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainPurchaseOrder(row)
	return &out, nil
}

// ApprovePurchaseOrder, ticari tabanı KİLİTLER VE Cost Control'e HER PO
// kalemi için BİR commitment OLUŞTURUR (source_type='purchase_order',
// source_id=item.id) -- bu sprintin en kritik entegrasyon noktası.
// Approval TEK bir transaction içinde yapılır: status='draft'->'approved'
// koşullu UPDATE (FOR UPDATE + status-guard, mevcut ilke) VE tüm
// commitment INSERT'leri BİRLİKTE commit/rollback olur -- kısmi bir
// "PO onaylandı ama bazı kalemler commitment'a dönüşmedi" durumu ASLA
// oluşamaz.
func (s *ProjectService) ApprovePurchaseOrder(ctx context.Context, projectID, poID, organizationID, userID string) (*domain.PurchaseOrder, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	id, err := repository.StringToUUID(poID)
	if err != nil {
		return nil, domain.ErrNotFound
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	current, err := txq.GetPurchaseOrderForUpdate(ctx, sqlc.GetPurchaseOrderForUpdateParams{ID: id, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		return nil, domain.ErrNotFound
	}
	if current.Status != domain.PurchaseOrderStatusDraft {
		return nil, ErrPurchaseOrderNotApprovable
	}
	items, err := txq.ListPurchaseOrderItems(ctx, id)
	if err != nil {
		return nil, err
	}
	if len(items) == 0 {
		return nil, ErrPurchaseOrderItemsRequired
	}

	row, err := txq.ApprovePurchaseOrder(ctx, sqlc.ApprovePurchaseOrderParams{ID: id, OrganizationID: orgID, ProjectID: pid, ApprovedBy: actorUUID(userID)})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrPurchaseOrderNotApprovable
		}
		return nil, err
	}

	now := repository.TimeToDate(time.Now())
	for _, it := range items {
		desc := fmt.Sprintf("PO %s — %s", row.PoNo, it.Description)
		if _, err := txq.CreateCommitmentFromSource(ctx, sqlc.CreateCommitmentFromSourceParams{
			OrganizationID: orgID, ProjectID: pid, BudgetLineID: it.BudgetLineID, CostCodeID: it.CostCodeID,
			SourceType: domain.CommitmentSourcePurchaseOrder, SourceID: it.ID,
			Description: desc, CommittedAmount: it.LineTotal, Currency: row.Currency, CommittedAt: now,
			CreatedBy: actorUUID(userID),
		}); err != nil {
			return nil, err
		}
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventPurchaseOrderApproved, actorUUID(userID),
		map[string]any{"purchase_order_id": poID, "po_no": row.PoNo, "total": repository.NumericToFloat64(row.Total), "item_count": len(items)}); err != nil {
		return nil, err
	}
	if err := createNotification(ctx, txq, CreateNotificationInput{
		OrganizationID: orgID, UserID: row.CreatedBy, Type: domain.NotificationPurchaseOrderApproved,
		Title: "Satın alma siparişi onaylandı", Body: row.PoNo,
		EntityType: domain.NotificationEntityPurchaseOrder, EntityID: id, ProjectID: pid,
		ActionTarget: "/projeler/" + pid.String() + "/satin-alma/siparisler/" + poID,
	}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainPurchaseOrder(row)
	return &out, nil
}

// CancelPurchaseOrder, {draft,approved}'tan çalışır. approved'tan iptal
// edilirse, o PO'nun kalemlerinden doğan TÜM aktif commitment'lar TEK
// sorguda (VoidCommitmentsBySourcePOItems) voider -- AYNI transaction
// içinde, PO'nun kendisinin cancelled'a geçişiyle BİRLİKTE commit/
// rollback olur.
func (s *ProjectService) CancelPurchaseOrder(ctx context.Context, projectID, poID, organizationID, userID, reason string) (*domain.PurchaseOrder, error) {
	reason = strings.TrimSpace(reason)
	if reason == "" {
		return nil, ErrPurchaseOrderReasonRequired
	}
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	id, err := repository.StringToUUID(poID)
	if err != nil {
		return nil, domain.ErrNotFound
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	current, err := txq.GetPurchaseOrderForUpdate(ctx, sqlc.GetPurchaseOrderForUpdateParams{ID: id, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		return nil, domain.ErrNotFound
	}
	if current.Status != domain.PurchaseOrderStatusDraft && current.Status != domain.PurchaseOrderStatusApproved {
		return nil, ErrPurchaseOrderNotCancellable
	}
	wasApproved := current.Status == domain.PurchaseOrderStatusApproved

	row, err := txq.CancelPurchaseOrder(ctx, sqlc.CancelPurchaseOrderParams{
		ID: id, OrganizationID: orgID, ProjectID: pid, CancelledBy: actorUUID(userID), CancelReason: reason,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrPurchaseOrderNotCancellable
		}
		return nil, err
	}

	voidedCount := 0
	if wasApproved {
		voided, err := txq.VoidCommitmentsBySourcePOItems(ctx, sqlc.VoidCommitmentsBySourcePOItemsParams{
			OrganizationID: orgID, ProjectID: pid, PurchaseOrderID: id, VoidedBy: actorUUID(userID), VoidReason: "PO iptal edildi: " + reason,
		})
		if err != nil {
			return nil, err
		}
		voidedCount = len(voided)
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventPurchaseOrderCancelled, actorUUID(userID),
		map[string]any{"purchase_order_id": poID, "reason": reason, "commitments_voided": voidedCount}); err != nil {
		return nil, err
	}
	// Onaylanmışken iptal edilirse, hem PO'yu hazırlayan hem onaylayan kişi
	// bilgilendirilir (onayları geri alınıyor); yalnızca taslaktaysa tek
	// alıcı (hazırlayan) yeterlidir.
	cancelRecipients := []pgtype.UUID{row.CreatedBy}
	if wasApproved && row.ApprovedBy.Valid && row.ApprovedBy.String() != row.CreatedBy.String() {
		cancelRecipients = append(cancelRecipients, row.ApprovedBy)
	}
	if err := createNotificationsForUsers(ctx, txq, cancelRecipients, CreateNotificationInput{
		OrganizationID: orgID, Type: domain.NotificationPurchaseOrderCancelled,
		Title: "Satın alma siparişi iptal edildi", Body: row.PoNo,
		EntityType: domain.NotificationEntityPurchaseOrder, EntityID: id, ProjectID: pid,
		ActionTarget: "/projeler/" + pid.String() + "/satin-alma/siparisler/" + poID,
	}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainPurchaseOrder(row)
	return &out, nil
}

// ClosePurchaseOrder, TERMİNAL bir arşiv işaretidir -- commitment'a
// DOKUNMAZ (bkz. dosya-başı yorum ve migration §7 gerekçesi).
func (s *ProjectService) ClosePurchaseOrder(ctx context.Context, projectID, poID, organizationID, userID string) (*domain.PurchaseOrder, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	id, err := repository.StringToUUID(poID)
	if err != nil {
		return nil, domain.ErrNotFound
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	row, err := txq.ClosePurchaseOrder(ctx, sqlc.ClosePurchaseOrderParams{ID: id, OrganizationID: orgID, ProjectID: pid, ClosedBy: actorUUID(userID)})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			if _, gerr := txq.GetPurchaseOrder(ctx, sqlc.GetPurchaseOrderParams{ID: id, OrganizationID: orgID, ProjectID: pid}); gerr != nil {
				return nil, domain.ErrNotFound
			}
			return nil, ErrPurchaseOrderNotCloseable
		}
		return nil, err
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventPurchaseOrderClosed, actorUUID(userID),
		map[string]any{"purchase_order_id": poID}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainPurchaseOrder(row)
	return &out, nil
}

// ListCommitmentsForPurchaseOrder, PO detay ekranının "bağlı taahhütler"
// bölümünü besler (bkz. web ContractSection'ın "Bu Sözleşmeyi Değiştiren
// Ek İşler" listesiyle AYNI şeffaflık ilkesi -- kullanıcı Cost Control
// etkisini PO ekranından da görebilmeli).
func (s *ProjectService) ListCommitmentsForPurchaseOrder(ctx context.Context, projectID, poID, organizationID string) ([]domain.Commitment, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	id, err := repository.StringToUUID(poID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	rows, err := s.q.ListCommitmentsBySourcePOItems(ctx, sqlc.ListCommitmentsBySourcePOItemsParams{OrganizationID: orgID, ProjectID: pid, PurchaseOrderID: id})
	if err != nil {
		return nil, err
	}
	out := make([]domain.Commitment, len(rows))
	for i, r := range rows {
		out[i] = repository.ToDomainCommitment(r)
	}
	return out, nil
}
