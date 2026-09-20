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

// ARVEND V2 — Sprint 4: Procurement Foundation, RFQ + Tedarikçi Teklifi +
// Teklif Karşılaştırma + Award. *ProjectService üzerinde metodlar.
//
// Durum makinesi: draft -> issued (kalemler SNAPSHOT olarak kilitlenir) ->
// closed (Award İLE ya da AwardSIZ Close İLE) ; {draft,issued} -> cancelled.
// Award TEK BAŞINA actual cost oluşturmaz -- yalnızca "kazanan" kararını
// (rfqs.awarded_quotation_id, TEK doğruluk kaynağı) kalıcı/denetimli hale
// getirir. Bkz. docs/procurement.md.

var (
	ErrRFQNotEditable                   = errors.New("RFQ yalnızca taslak durumdayken düzenlenebilir")
	ErrRFQNotIssuable                   = errors.New("yalnızca taslak bir RFQ gönderilebilir")
	ErrRFQNotCloseable                  = errors.New("yalnızca gönderilmiş bir RFQ kapatılabilir")
	ErrRFQNotCancellable                = errors.New("bu durumdaki bir RFQ iptal edilemez")
	ErrRFQNotAwardable                  = errors.New("yalnızca gönderilmiş bir RFQ'ya ödül verilebilir")
	ErrRFQItemsRequired                 = errors.New("RFQ gönderilmeden önce en az bir kalem gereklidir")
	ErrRFQSuppliersRequired             = errors.New("RFQ gönderilmeden önce en az bir tedarikçi davet edilmelidir")
	ErrPurchaseRequestNotApprovedForRFQ = errors.New("yalnızca onaylı bir satın alma talebinden RFQ oluşturulabilir")
	ErrQuotationSupplierNotInvited      = errors.New("bu tedarikçi bu RFQ'ya davet edilmemiş")
	ErrQuotationRFQNotOpen              = errors.New("yalnızca gönderilmiş ve henüz ödüllendirilmemiş bir RFQ için teklif girilebilir/düzenlenebilir")
	ErrQuotationItemsRequired           = errors.New("teklif en az bir kalem içermelidir")
	ErrAwardQuotationMismatch           = errors.New("seçilen teklif bu RFQ'ya ait değil")
)

// ---------- Girdi tipleri ----------

type RFQItemInput struct {
	WBSNodeID    string
	CostCodeID   string
	BudgetLineID string
	Description  string
	Quantity     float64
	Unit         string
}

type RFQInput struct {
	Title             string
	PurchaseRequestID string // opsiyonel -- doluysa kalemler O PR'dan SNAPSHOT alınır (Items yok sayılır)
	IssueDate         time.Time
	DueDate           *time.Time
	Notes             string
	SupplierIDs       []string
	Items             []RFQItemInput // yalnızca PurchaseRequestID boşsa kullanılır
	UserID            string
}

func (s *ProjectService) generateRFQNo(ctx context.Context, q *sqlc.Queries, orgID pgtype.UUID) (string, error) {
	year := time.Now().Year()
	seq, err := q.NextRfqSeq(ctx, sqlc.NextRfqSeqParams{OrganizationID: orgID, Year: int32(year)})
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("RFQ-%d-%04d", year, seq), nil
}

// insertRFQSuppliers, DeleteRFQSuppliers + AddRFQSupplier döngüsü
// (project_change_order_items İLE AYNI "sil ve yeniden ekle" ilkesi).
// Cross-tenant tedarikçi davet edilmesi trg_rfq_suppliers_check_
// consistency tarafından DB seviyesinde de reddedilir (savunma derinliği).
func (s *ProjectService) insertRFQSuppliers(ctx context.Context, txq *sqlc.Queries, orgID, rfqID pgtype.UUID, supplierIDs []string) error {
	if err := txq.DeleteRFQSuppliers(ctx, sqlc.DeleteRFQSuppliersParams{RfqID: rfqID, OrganizationID: orgID}); err != nil {
		return err
	}
	for _, sidStr := range supplierIDs {
		sid, err := repository.StringToUUID(strings.TrimSpace(sidStr))
		if err != nil {
			continue
		}
		if _, err := txq.AddRFQSupplier(ctx, sqlc.AddRFQSupplierParams{OrganizationID: orgID, RfqID: rfqID, SupplierID: sid}); err != nil {
			return err
		}
	}
	return nil
}

// insertRFQItems, DeleteRFQItems + CreateRFQItem döngüsü. sourcePRItems
// doluysa (PR'dan snapshot), items yok sayılır -- kaynak PR kaleminin
// TÜM referans alanları (wbs/cost_code/budget_line) KOPYALANIR.
func (s *ProjectService) insertRFQItems(
	ctx context.Context, txq *sqlc.Queries, orgID, pid, rfqID pgtype.UUID,
	sourcePRItems []sqlc.PurchaseRequestItem, items []RFQItemInput,
) error {
	if err := txq.DeleteRFQItems(ctx, sqlc.DeleteRFQItemsParams{RfqID: rfqID, OrganizationID: orgID, ProjectID: pid}); err != nil {
		return err
	}
	if len(sourcePRItems) > 0 {
		for i, it := range sourcePRItems {
			srcID := it.ID
			if _, err := txq.CreateRFQItem(ctx, sqlc.CreateRFQItemParams{
				OrganizationID: orgID, ProjectID: pid, RfqID: rfqID, SourcePrItemID: srcID,
				WbsNodeID: it.WbsNodeID, CostCodeID: it.CostCodeID, BudgetLineID: it.BudgetLineID,
				Description: it.Description, Quantity: it.Quantity, Unit: it.Unit, SortOrder: int32(i),
			}); err != nil {
				return err
			}
		}
		return nil
	}
	for i, it := range items {
		wbsID, err := resolveWBSParentRef(ctx, txq, it.WBSNodeID, pid, orgID)
		if err != nil {
			return err
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
		if desc == "" || it.Quantity <= 0 {
			return ErrInvalidAmount
		}
		if _, err := txq.CreateRFQItem(ctx, sqlc.CreateRFQItemParams{
			OrganizationID: orgID, ProjectID: pid, RfqID: rfqID,
			WbsNodeID: wbsID, CostCodeID: costCodeID, BudgetLineID: budgetLineID,
			Description: desc, Quantity: repository.Float64ToNumeric(it.Quantity), Unit: it.Unit, SortOrder: int32(i),
		}); err != nil {
			return err
		}
	}
	return nil
}

func (s *ProjectService) CreateRFQ(ctx context.Context, projectID, organizationID string, in RFQInput) (*domain.RFQ, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	in.Title = strings.TrimSpace(in.Title)
	if in.Title == "" {
		return nil, ErrInvalidAmount
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

	var prID pgtype.UUID
	var sourcePRItems []sqlc.PurchaseRequestItem
	if pridStr := strings.TrimSpace(in.PurchaseRequestID); pridStr != "" {
		parsed, err := repository.StringToUUID(pridStr)
		if err != nil {
			return nil, domain.ErrNotFound
		}
		pr, err := txq.GetPurchaseRequest(ctx, sqlc.GetPurchaseRequestParams{ID: parsed, OrganizationID: orgID, ProjectID: pid})
		if err != nil {
			return nil, domain.ErrNotFound
		}
		if pr.Status != domain.PurchaseRequestStatusApproved {
			return nil, ErrPurchaseRequestNotApprovedForRFQ
		}
		prID = parsed
		sourcePRItems, err = txq.ListPurchaseRequestItems(ctx, pr.ID)
		if err != nil {
			return nil, err
		}
	}

	rfqNo, err := s.generateRFQNo(ctx, txq, orgID)
	if err != nil {
		return nil, err
	}
	row, err := txq.CreateRFQ(ctx, sqlc.CreateRFQParams{
		OrganizationID: orgID, ProjectID: pid, RfqNo: rfqNo, PurchaseRequestID: prID,
		Title: in.Title, IssueDate: repository.TimeToDate(in.IssueDate), DueDate: repository.TimePtrToDate(in.DueDate),
		Notes: in.Notes, CreatedBy: actorUUID(in.UserID),
	})
	if err != nil {
		return nil, err
	}
	if err := s.insertRFQItems(ctx, txq, orgID, pid, row.ID, sourcePRItems, in.Items); err != nil {
		return nil, err
	}
	if err := s.insertRFQSuppliers(ctx, txq, orgID, row.ID, in.SupplierIDs); err != nil {
		return nil, err
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventRFQCreated, actorUUID(in.UserID),
		map[string]any{"rfq_id": row.ID.String(), "rfq_no": row.RfqNo}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainRFQ(row)
	return &out, nil
}

func (s *ProjectService) GetRFQ(ctx context.Context, projectID, rfqID, organizationID string) (*domain.RFQ, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	id, err := repository.StringToUUID(rfqID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	row, err := s.q.GetRFQ(ctx, sqlc.GetRFQParams{ID: id, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		return nil, domain.ErrNotFound
	}
	out := repository.ToDomainRFQ(row)
	return &out, nil
}

func (s *ProjectService) ListRFQs(ctx context.Context, projectID, organizationID string) ([]domain.RFQ, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	rows, err := s.q.ListRFQs(ctx, sqlc.ListRFQsParams{ProjectID: pid, OrganizationID: orgID})
	if err != nil {
		return nil, err
	}
	out := make([]domain.RFQ, len(rows))
	for i, r := range rows {
		out[i] = repository.ToDomainRFQ(r)
	}
	return out, nil
}

func (s *ProjectService) ListRFQItems(ctx context.Context, projectID, rfqID, organizationID string) ([]domain.RFQItem, error) {
	if _, err := s.GetRFQ(ctx, projectID, rfqID, organizationID); err != nil {
		return nil, err
	}
	id, _ := repository.StringToUUID(rfqID)
	rows, err := s.q.ListRFQItems(ctx, id)
	if err != nil {
		return nil, err
	}
	out := make([]domain.RFQItem, len(rows))
	for i, r := range rows {
		out[i] = repository.ToDomainRFQItem(r)
	}
	return out, nil
}

func (s *ProjectService) ListRFQSuppliers(ctx context.Context, projectID, rfqID, organizationID string) ([]domain.RFQSupplier, error) {
	if _, err := s.GetRFQ(ctx, projectID, rfqID, organizationID); err != nil {
		return nil, err
	}
	id, _ := repository.StringToUUID(rfqID)
	rows, err := s.q.ListRFQSuppliers(ctx, id)
	if err != nil {
		return nil, err
	}
	out := make([]domain.RFQSupplier, len(rows))
	for i, r := range rows {
		out[i] = repository.ToDomainRFQSupplier(r)
	}
	return out, nil
}

func (s *ProjectService) UpdateRFQDraft(ctx context.Context, projectID, rfqID, organizationID string, in RFQInput) (*domain.RFQ, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	id, err := repository.StringToUUID(rfqID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	in.Title = strings.TrimSpace(in.Title)
	if in.Title == "" {
		return nil, ErrInvalidAmount
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	row, err := txq.UpdateRFQFields(ctx, sqlc.UpdateRFQFieldsParams{
		ID: id, OrganizationID: orgID, ProjectID: pid, Title: in.Title, DueDate: repository.TimePtrToDate(in.DueDate), Notes: in.Notes,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			if _, gerr := txq.GetRFQ(ctx, sqlc.GetRFQParams{ID: id, OrganizationID: orgID, ProjectID: pid}); gerr != nil {
				return nil, domain.ErrNotFound
			}
			return nil, ErrRFQNotEditable
		}
		return nil, err
	}

	var sourcePRItems []sqlc.PurchaseRequestItem
	if row.PurchaseRequestID.Valid {
		sourcePRItems, err = txq.ListPurchaseRequestItems(ctx, row.PurchaseRequestID)
		if err != nil {
			return nil, err
		}
	}
	if err := s.insertRFQItems(ctx, txq, orgID, pid, id, sourcePRItems, in.Items); err != nil {
		return nil, err
	}
	if err := s.insertRFQSuppliers(ctx, txq, orgID, id, in.SupplierIDs); err != nil {
		return nil, err
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventRFQUpdated, actorUUID(in.UserID),
		map[string]any{"rfq_id": rfqID}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainRFQ(row)
	return &out, nil
}

// ---------- Durum geçişleri ----------

func (s *ProjectService) transitionRFQ(
	ctx context.Context, projectID, rfqID, organizationID string,
	do func(ctx context.Context, txq *sqlc.Queries, id, orgID, pid pgtype.UUID) (sqlc.Rfq, error),
	notFoundErr error, eventType string, userID string, extraMeta map[string]any,
) (*domain.RFQ, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	id, err := repository.StringToUUID(rfqID)
	if err != nil {
		return nil, domain.ErrNotFound
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	row, err := do(ctx, txq, id, orgID, pid)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			if _, gerr := txq.GetRFQ(ctx, sqlc.GetRFQParams{ID: id, OrganizationID: orgID, ProjectID: pid}); gerr != nil {
				return nil, domain.ErrNotFound
			}
			return nil, notFoundErr
		}
		return nil, err
	}
	meta := map[string]any{"rfq_id": rfqID}
	for k, v := range extraMeta {
		meta[k] = v
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, eventType, actorUUID(userID), meta); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainRFQ(row)
	return &out, nil
}

func (s *ProjectService) IssueRFQ(ctx context.Context, projectID, rfqID, organizationID, userID string) (*domain.RFQ, error) {
	items, err := s.ListRFQItems(ctx, projectID, rfqID, organizationID)
	if err != nil {
		return nil, err
	}
	if len(items) == 0 {
		return nil, ErrRFQItemsRequired
	}
	suppliers, err := s.ListRFQSuppliers(ctx, projectID, rfqID, organizationID)
	if err != nil {
		return nil, err
	}
	if len(suppliers) == 0 {
		return nil, ErrRFQSuppliersRequired
	}
	return s.transitionRFQ(ctx, projectID, rfqID, organizationID,
		func(ctx context.Context, txq *sqlc.Queries, id, orgID, pid pgtype.UUID) (sqlc.Rfq, error) {
			return txq.IssueRFQ(ctx, sqlc.IssueRFQParams{ID: id, OrganizationID: orgID, ProjectID: pid})
		}, ErrRFQNotIssuable, domain.ProjectEventRFQIssued, userID, nil)
}

func (s *ProjectService) CloseRFQ(ctx context.Context, projectID, rfqID, organizationID, userID string) (*domain.RFQ, error) {
	return s.transitionRFQ(ctx, projectID, rfqID, organizationID,
		func(ctx context.Context, txq *sqlc.Queries, id, orgID, pid pgtype.UUID) (sqlc.Rfq, error) {
			return txq.CloseRFQ(ctx, sqlc.CloseRFQParams{ID: id, OrganizationID: orgID, ProjectID: pid})
		}, ErrRFQNotCloseable, domain.ProjectEventRFQClosed, userID, nil)
}

func (s *ProjectService) CancelRFQ(ctx context.Context, projectID, rfqID, organizationID, userID string) (*domain.RFQ, error) {
	return s.transitionRFQ(ctx, projectID, rfqID, organizationID,
		func(ctx context.Context, txq *sqlc.Queries, id, orgID, pid pgtype.UUID) (sqlc.Rfq, error) {
			return txq.CancelRFQ(ctx, sqlc.CancelRFQParams{ID: id, OrganizationID: orgID, ProjectID: pid})
		}, ErrRFQNotCancellable, domain.ProjectEventRFQCancelled, userID, nil)
}

// AwardRFQ, seçilen teklifin BU RFQ'ya ait olduğunu doğrular (çapraz-RFQ
// award İMKANSIZ olmalı), ardından status'u issued->closed yapar VE
// awarded_quotation_id/awarded_at/awarded_by/award_notes'u AYNI anda set
// eder (tek atomik UPDATE, bkz. AwardRFQ sorgusu). Award TEK BAŞINA hiçbir
// commitment/actual cost OLUŞTURMAZ -- yalnızca PO oluşturmanın önkoşulu
// olan kararı kaydeder.
func (s *ProjectService) AwardRFQ(ctx context.Context, projectID, rfqID, organizationID, userID, quotationID, notes string) (*domain.RFQ, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	id, err := repository.StringToUUID(rfqID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	qid, err := repository.StringToUUID(quotationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	quotation, err := txq.GetSupplierQuotation(ctx, sqlc.GetSupplierQuotationParams{ID: qid, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		return nil, domain.ErrNotFound
	}
	if quotation.RfqID != id {
		return nil, ErrAwardQuotationMismatch
	}

	row, err := txq.AwardRFQ(ctx, sqlc.AwardRFQParams{
		ID: id, OrganizationID: orgID, ProjectID: pid,
		AwardedQuotationID: qid, AwardedBy: actorUUID(userID), AwardNotes: notes,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			if _, gerr := txq.GetRFQ(ctx, sqlc.GetRFQParams{ID: id, OrganizationID: orgID, ProjectID: pid}); gerr != nil {
				return nil, domain.ErrNotFound
			}
			return nil, ErrRFQNotAwardable
		}
		return nil, err
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventRFQAwarded, actorUUID(userID),
		map[string]any{"rfq_id": rfqID, "quotation_id": quotationID, "supplier_id": quotation.SupplierID.String(), "notes": notes}); err != nil {
		return nil, err
	}
	if err := createNotification(ctx, txq, CreateNotificationInput{
		OrganizationID: orgID, UserID: row.CreatedBy, Type: domain.NotificationRFQAwarded,
		Title: "Teklif süreci sonuçlandı", Body: row.RfqNo,
		EntityType: domain.NotificationEntityRFQ, EntityID: id, ProjectID: pid,
		ActionTarget: "/projeler/" + pid.String() + "/satin-alma/rfqlar/" + rfqID,
	}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainRFQ(row)
	return &out, nil
}
