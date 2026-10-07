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

// ARVEND V2 — Sprint 4: Procurement Foundation, Purchase Request.
// *ProjectService üzerinde metodlar (Contract/CostControl İLE AYNI
// desen, YENİ bir servis tipi İCAT EDİLMEDİ). Durum makinesi:
//
//	draft -> submitted -> approved   (RFQ/PO kaynağı olabilir)
//	                   -> rejected   (gerekçe zorunlu, TERMİNAL)
//	submitted -> draft               (Withdraw -- kontrollü geri çekme)
//	{draft,submitted,approved} -> cancelled  (gerekçe zorunlu, TERMİNAL)
//
// bkz. docs/procurement.md.

var (
	ErrPurchaseRequestNotEditable     = errors.New("satın alma talebi yalnızca taslak durumdayken düzenlenebilir")
	ErrPurchaseRequestNotSubmittable  = errors.New("yalnızca taslak bir talep gönderilebilir")
	ErrPurchaseRequestNotWithdrawable = errors.New("yalnızca gönderilmiş bir talep geri çekilebilir")
	ErrPurchaseRequestNotApprovable   = errors.New("yalnızca gönderilmiş bir talep onaylanabilir")
	ErrPurchaseRequestNotRejectable   = errors.New("yalnızca gönderilmiş bir talep reddedilebilir")
	ErrPurchaseRequestNotCancellable  = errors.New("bu durumdaki bir talep iptal edilemez")
	ErrPurchaseRequestReasonRequired  = errors.New("gerekçe zorunludur")
	ErrPurchaseRequestItemsRequired   = errors.New("gönderilmeden önce en az bir kalem gereklidir")
)

type PurchaseRequestItemInput struct {
	WBSNodeID         string
	CostCodeID        string
	BudgetLineID      string
	Description       string
	Quantity          float64
	Unit              string
	EstimatedUnitCost *float64
	EstimatedTotal    float64
	Notes             string
}

type PurchaseRequestInput struct {
	Title       string
	Description string
	NeededBy    *time.Time
	Items       []PurchaseRequestItemInput
	UserID      string
}

func (s *ProjectService) generatePRNo(ctx context.Context, q *sqlc.Queries, orgID pgtype.UUID) (string, error) {
	year := IstanbulToday().Year()
	seq, err := q.NextPurchaseRequestSeq(ctx, sqlc.NextPurchaseRequestSeqParams{OrganizationID: orgID, Year: int32(year)})
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("PR-%d-%04d", year, seq), nil
}

// insertPurchaseRequestItems, mevcut kalemleri SİLER ve YENİDEN ekler
// (project_change_order_items İLE AYNI desen -- diff/patch İCAT
// EDİLMEDİ), ardından toplamı SQL'de yeniden hesaplar.
func (s *ProjectService) insertPurchaseRequestItems(
	ctx context.Context, txq *sqlc.Queries, orgID, pid, prID pgtype.UUID, items []PurchaseRequestItemInput,
) (sqlc.PurchaseRequest, error) {
	if err := txq.DeletePurchaseRequestItems(ctx, sqlc.DeletePurchaseRequestItemsParams{
		PurchaseRequestID: prID, OrganizationID: orgID, ProjectID: pid,
	}); err != nil {
		return sqlc.PurchaseRequest{}, err
	}
	for i, it := range items {
		wbsID, err := resolveWBSParentRef(ctx, txq, it.WBSNodeID, pid, orgID)
		if err != nil {
			return sqlc.PurchaseRequest{}, err
		}
		costCodeID, err := resolveCostCodeRef(ctx, txq, it.CostCodeID, orgID)
		if err != nil {
			return sqlc.PurchaseRequest{}, err
		}
		budgetLineID, err := resolveBudgetLineRef(ctx, txq, it.BudgetLineID, pid, orgID)
		if err != nil {
			return sqlc.PurchaseRequest{}, err
		}
		desc := strings.TrimSpace(it.Description)
		if desc == "" {
			return sqlc.PurchaseRequest{}, ErrItemDescriptionRequired
		}
		if it.Quantity <= 0 {
			return sqlc.PurchaseRequest{}, ErrInvalidQuantity
		}
		if _, err := txq.CreatePurchaseRequestItem(ctx, sqlc.CreatePurchaseRequestItemParams{
			OrganizationID: orgID, ProjectID: pid, PurchaseRequestID: prID,
			WbsNodeID: wbsID, CostCodeID: costCodeID, BudgetLineID: budgetLineID,
			Description: desc, Quantity: repository.Float64ToNumeric(it.Quantity), Unit: it.Unit,
			EstimatedUnitCost: repository.Float64PtrToNumeric(it.EstimatedUnitCost),
			Column11:          repository.Float64ToNumeric(it.EstimatedTotal),
			Notes:             it.Notes, SortOrder: int32(i),
		}); err != nil {
			return sqlc.PurchaseRequest{}, err
		}
	}
	return txq.RecomputePurchaseRequestTotal(ctx, sqlc.RecomputePurchaseRequestTotalParams{
		ID: prID, OrganizationID: orgID, ProjectID: pid,
	})
}

func (s *ProjectService) CreatePurchaseRequest(ctx context.Context, projectID, organizationID string, in PurchaseRequestInput) (*domain.PurchaseRequest, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	in.Title = strings.TrimSpace(in.Title)
	if in.Title == "" {
		return nil, ErrTitleRequired
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
	prNo, err := s.generatePRNo(ctx, txq, orgID)
	if err != nil {
		return nil, err
	}
	row, err := txq.CreatePurchaseRequest(ctx, sqlc.CreatePurchaseRequestParams{
		OrganizationID: orgID, ProjectID: pid, PrNo: prNo, Title: in.Title, Description: in.Description,
		NeededBy: repository.TimePtrToDate(in.NeededBy), RequestedBy: actorUUID(in.UserID),
	})
	if err != nil {
		return nil, err
	}
	if len(in.Items) > 0 {
		row, err = s.insertPurchaseRequestItems(ctx, txq, orgID, pid, row.ID, in.Items)
		if err != nil {
			return nil, err
		}
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventPurchaseRequestCreated, actorUUID(in.UserID),
		map[string]any{"purchase_request_id": row.ID.String(), "pr_no": row.PrNo}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainPurchaseRequest(row)
	return &out, nil
}

func (s *ProjectService) GetPurchaseRequest(ctx context.Context, projectID, prID, organizationID string) (*domain.PurchaseRequest, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	id, err := repository.StringToUUID(prID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	row, err := s.q.GetPurchaseRequest(ctx, sqlc.GetPurchaseRequestParams{ID: id, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		return nil, domain.ErrNotFound
	}
	out := repository.ToDomainPurchaseRequest(row)
	return &out, nil
}

func (s *ProjectService) ListPurchaseRequests(ctx context.Context, projectID, organizationID string) ([]domain.PurchaseRequest, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	rows, err := s.q.ListPurchaseRequests(ctx, sqlc.ListPurchaseRequestsParams{ProjectID: pid, OrganizationID: orgID})
	if err != nil {
		return nil, err
	}
	out := make([]domain.PurchaseRequest, len(rows))
	for i, r := range rows {
		out[i] = repository.ToDomainPurchaseRequest(r)
	}
	return out, nil
}

func (s *ProjectService) ListPurchaseRequestItems(ctx context.Context, projectID, prID, organizationID string) ([]domain.PurchaseRequestItem, error) {
	if _, err := s.GetPurchaseRequest(ctx, projectID, prID, organizationID); err != nil {
		return nil, err
	}
	id, _ := repository.StringToUUID(prID)
	rows, err := s.q.ListPurchaseRequestItems(ctx, id)
	if err != nil {
		return nil, err
	}
	out := make([]domain.PurchaseRequestItem, len(rows))
	for i, r := range rows {
		out[i] = repository.ToDomainPurchaseRequestItem(r)
	}
	return out, nil
}

func (s *ProjectService) UpdatePurchaseRequestDraft(ctx context.Context, projectID, prID, organizationID string, in PurchaseRequestInput) (*domain.PurchaseRequest, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	id, err := repository.StringToUUID(prID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	in.Title = strings.TrimSpace(in.Title)
	if in.Title == "" {
		return nil, ErrTitleRequired
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	row, err := txq.UpdatePurchaseRequestFields(ctx, sqlc.UpdatePurchaseRequestFieldsParams{
		ID: id, OrganizationID: orgID, ProjectID: pid, Title: in.Title, Description: in.Description,
		NeededBy: repository.TimePtrToDate(in.NeededBy),
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			if _, gerr := txq.GetPurchaseRequest(ctx, sqlc.GetPurchaseRequestParams{ID: id, OrganizationID: orgID, ProjectID: pid}); gerr != nil {
				return nil, domain.ErrNotFound
			}
			return nil, ErrPurchaseRequestNotEditable
		}
		return nil, err
	}
	row, err = s.insertPurchaseRequestItems(ctx, txq, orgID, pid, id, in.Items)
	if err != nil {
		return nil, err
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventPurchaseRequestUpdated, actorUUID(in.UserID),
		map[string]any{"purchase_request_id": prID}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainPurchaseRequest(row)
	return &out, nil
}

// ---------- Durum geçişleri ----------

// notify (nilable), eventType için logProjectEvent'ten HEMEN SONRA, AYNI
// transaction içinde çağrılır -- bildirim yazımı iş eylemiyle atomik olur.
// WithdrawPurchaseRequest gibi notify GEÇMEYEN çağıranlar İÇİN bildirim
// hiç üretilmez (bkz. Faz 1 araştırması: geri çekme kendi eylemini yapan
// personeli bilgilendirmenin bir anlamı yok).
func (s *ProjectService) transitionPurchaseRequest(
	ctx context.Context, projectID, prID, organizationID string,
	do func(ctx context.Context, txq *sqlc.Queries, id, orgID, pid pgtype.UUID) (sqlc.PurchaseRequest, error),
	notFoundErr error, eventType string, userID string, extraMeta map[string]any,
	notify func(ctx context.Context, txq *sqlc.Queries, orgID, pid pgtype.UUID, row sqlc.PurchaseRequest) error,
) (*domain.PurchaseRequest, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	id, err := repository.StringToUUID(prID)
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
			if _, gerr := txq.GetPurchaseRequest(ctx, sqlc.GetPurchaseRequestParams{ID: id, OrganizationID: orgID, ProjectID: pid}); gerr != nil {
				return nil, domain.ErrNotFound
			}
			return nil, notFoundErr
		}
		return nil, err
	}
	meta := map[string]any{"purchase_request_id": prID}
	for k, v := range extraMeta {
		meta[k] = v
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, eventType, actorUUID(userID), meta); err != nil {
		return nil, err
	}
	if notify != nil {
		if err := notify(ctx, txq, orgID, pid, row); err != nil {
			return nil, err
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainPurchaseRequest(row)
	return &out, nil
}

func (s *ProjectService) SubmitPurchaseRequest(ctx context.Context, projectID, prID, organizationID, userID string) (*domain.PurchaseRequest, error) {
	items, err := s.ListPurchaseRequestItems(ctx, projectID, prID, organizationID)
	if err != nil {
		return nil, err
	}
	if len(items) == 0 {
		return nil, ErrPurchaseRequestItemsRequired
	}
	return s.transitionPurchaseRequest(ctx, projectID, prID, organizationID,
		func(ctx context.Context, txq *sqlc.Queries, id, orgID, pid pgtype.UUID) (sqlc.PurchaseRequest, error) {
			return txq.SubmitPurchaseRequest(ctx, sqlc.SubmitPurchaseRequestParams{ID: id, OrganizationID: orgID, ProjectID: pid})
		}, ErrPurchaseRequestNotSubmittable, domain.ProjectEventPurchaseRequestSubmitted, userID, nil,
		func(ctx context.Context, txq *sqlc.Queries, orgID, pid pgtype.UUID, row sqlc.PurchaseRequest) error {
			approvers, err := resolveProjectApprovers(ctx, txq, orgID, pid, domain.PermProjectsProcurementApprove)
			if err != nil {
				return err
			}
			return createNotificationsForUsers(ctx, txq, approvers, CreateNotificationInput{
				OrganizationID: orgID, Type: domain.NotificationPurchaseRequestSubmitted,
				Title: "Onay bekleyen talep", Body: row.PrNo,
				EntityType: domain.NotificationEntityPurchaseRequest, EntityID: row.ID, ProjectID: pid,
				ActionTarget: "/projeler/" + pid.String() + "/satin-alma/talepler/" + prID,
			})
		})
}

func (s *ProjectService) WithdrawPurchaseRequest(ctx context.Context, projectID, prID, organizationID, userID string) (*domain.PurchaseRequest, error) {
	return s.transitionPurchaseRequest(ctx, projectID, prID, organizationID,
		func(ctx context.Context, txq *sqlc.Queries, id, orgID, pid pgtype.UUID) (sqlc.PurchaseRequest, error) {
			return txq.WithdrawPurchaseRequest(ctx, sqlc.WithdrawPurchaseRequestParams{ID: id, OrganizationID: orgID, ProjectID: pid})
		}, ErrPurchaseRequestNotWithdrawable, domain.ProjectEventPurchaseRequestWithdrawn, userID, nil, nil)
}

func (s *ProjectService) ApprovePurchaseRequest(ctx context.Context, projectID, prID, organizationID, userID string) (*domain.PurchaseRequest, error) {
	return s.transitionPurchaseRequest(ctx, projectID, prID, organizationID,
		func(ctx context.Context, txq *sqlc.Queries, id, orgID, pid pgtype.UUID) (sqlc.PurchaseRequest, error) {
			return txq.ApprovePurchaseRequest(ctx, sqlc.ApprovePurchaseRequestParams{ID: id, OrganizationID: orgID, ProjectID: pid, ApprovedBy: actorUUID(userID)})
		}, ErrPurchaseRequestNotApprovable, domain.ProjectEventPurchaseRequestApproved, userID, nil,
		func(ctx context.Context, txq *sqlc.Queries, orgID, pid pgtype.UUID, row sqlc.PurchaseRequest) error {
			return createNotification(ctx, txq, CreateNotificationInput{
				OrganizationID: orgID, UserID: row.RequestedBy, Type: domain.NotificationPurchaseRequestApproved,
				Title: "Satın alma talebi onaylandı", Body: row.PrNo,
				EntityType: domain.NotificationEntityPurchaseRequest, EntityID: row.ID, ProjectID: pid,
				ActionTarget: "/projeler/" + pid.String() + "/satin-alma/talepler/" + prID,
			})
		})
}

func (s *ProjectService) RejectPurchaseRequest(ctx context.Context, projectID, prID, organizationID, userID, reason string) (*domain.PurchaseRequest, error) {
	reason = strings.TrimSpace(reason)
	if reason == "" {
		return nil, ErrPurchaseRequestReasonRequired
	}
	return s.transitionPurchaseRequest(ctx, projectID, prID, organizationID,
		func(ctx context.Context, txq *sqlc.Queries, id, orgID, pid pgtype.UUID) (sqlc.PurchaseRequest, error) {
			return txq.RejectPurchaseRequest(ctx, sqlc.RejectPurchaseRequestParams{ID: id, OrganizationID: orgID, ProjectID: pid, RejectedBy: actorUUID(userID), RejectionReason: reason})
		}, ErrPurchaseRequestNotRejectable, domain.ProjectEventPurchaseRequestRejected, userID, map[string]any{"reason": reason},
		func(ctx context.Context, txq *sqlc.Queries, orgID, pid pgtype.UUID, row sqlc.PurchaseRequest) error {
			return createNotification(ctx, txq, CreateNotificationInput{
				OrganizationID: orgID, UserID: row.RequestedBy, Type: domain.NotificationPurchaseRequestRejected,
				Title: "Satın alma talebi reddedildi", Body: row.PrNo,
				EntityType: domain.NotificationEntityPurchaseRequest, EntityID: row.ID, ProjectID: pid,
				ActionTarget: "/projeler/" + pid.String() + "/satin-alma/talepler/" + prID,
			})
		})
}

func (s *ProjectService) CancelPurchaseRequest(ctx context.Context, projectID, prID, organizationID, userID, reason string) (*domain.PurchaseRequest, error) {
	reason = strings.TrimSpace(reason)
	if reason == "" {
		return nil, ErrPurchaseRequestReasonRequired
	}
	return s.transitionPurchaseRequest(ctx, projectID, prID, organizationID,
		func(ctx context.Context, txq *sqlc.Queries, id, orgID, pid pgtype.UUID) (sqlc.PurchaseRequest, error) {
			return txq.CancelPurchaseRequest(ctx, sqlc.CancelPurchaseRequestParams{ID: id, OrganizationID: orgID, ProjectID: pid, CancelledBy: actorUUID(userID), CancelReason: reason})
		}, ErrPurchaseRequestNotCancellable, domain.ProjectEventPurchaseRequestCancelled, userID, map[string]any{"reason": reason}, nil)
}
