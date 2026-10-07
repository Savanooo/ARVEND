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

// ARVEND V2 — Sprint 5: Taşeron Değişiklik Emri (Subcontract Change Order).
// Customer Change Order (Sprint 3) tablosuyla HİÇBİR İLİŞKİSİ YOKTUR --
// MALİYET tarafına özgü, bağımsız bir domaindir (spec §12). Yalnızca
// APPROVED durumu current_subcontract_value VE commitment'ları etkiler
// (bkz. ApproveSubcontractChangeOrder -> syncSubcontractCommitments).

var (
	ErrSubcontractChangeOrderNotEditable    = errors.New("taşeron değişikliği yalnızca taslak durumdayken düzenlenebilir")
	ErrSubcontractChangeOrderNotSubmittable = errors.New("taşeron değişikliği yalnızca taslak durumdan gönderilebilir")
	ErrSubcontractChangeOrderNotApprovable  = errors.New("taşeron değişikliği yalnızca gönderilmiş durumdan onaylanabilir")
	ErrSubcontractChangeOrderNotRejectable  = errors.New("taşeron değişikliği yalnızca gönderilmiş durumdan reddedilebilir")
	ErrSubcontractChangeOrderNotCancellable = errors.New("taşeron değişikliği yalnızca taslak/gönderilmiş durumdan iptal edilebilir")
	ErrSubcontractChangeOrderItemsRequired  = errors.New("taşeron değişikliğinin en az bir kalemi olmalıdır")
	ErrSubcontractNotActiveForChange        = errors.New("taşeron sözleşmesi aktif olmadan değişiklik oluşturulamaz/onaylanamaz")
	ErrSubcontractChangeOrderReasonRequired = errors.New("red gerekçesi zorunludur")
)

type SubcontractChangeOrderItemInput struct {
	WBSNodeID    string
	CostCodeID   string
	BudgetLineID string
	Description  string
	Amount       float64
}

type SubcontractChangeOrderInput struct {
	Title       string
	Description string
	ChangeType  string
	Reason      string
	Items       []SubcontractChangeOrderItemInput
	UserID      string
}

func (s *ProjectService) generateSubcontractChangeOrderNo(ctx context.Context, q *sqlc.Queries, orgID pgtype.UUID) (string, error) {
	year := time.Now().Year()
	seq, err := q.NextSubcontractChangeOrderSeq(ctx, sqlc.NextSubcontractChangeOrderSeqParams{OrganizationID: orgID, Year: int32(year)})
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("SCO-%d-%04d", year, seq), nil
}

func insertSubcontractChangeOrderItems(ctx context.Context, txq *sqlc.Queries, orgID, pid, coID pgtype.UUID, items []SubcontractChangeOrderItemInput) error {
	if err := txq.DeleteSubcontractChangeOrderItems(ctx, sqlc.DeleteSubcontractChangeOrderItemsParams{ChangeOrderID: coID, OrganizationID: orgID, ProjectID: pid}); err != nil {
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
		if it.Amount <= 0 {
			return ErrInvalidAmount
		}
		if _, err := txq.CreateSubcontractChangeOrderItem(ctx, sqlc.CreateSubcontractChangeOrderItemParams{
			OrganizationID: orgID, ProjectID: pid, ChangeOrderID: coID,
			WbsNodeID: wbsID, CostCodeID: costCodeID, BudgetLineID: budgetLineID,
			Description: desc, Amount: repository.Float64ToNumeric(it.Amount), SortOrder: int32(i),
		}); err != nil {
			return err
		}
	}
	return nil
}

func (s *ProjectService) CreateSubcontractChangeOrder(ctx context.Context, projectID, subcontractID, organizationID string, in SubcontractChangeOrderInput) (*domain.SubcontractChangeOrder, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	scID, err := repository.StringToUUID(subcontractID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	if len(in.Items) == 0 {
		return nil, ErrSubcontractChangeOrderItemsRequired
	}
	if in.ChangeType != domain.SubcontractChangeTypeAddition && in.ChangeType != domain.SubcontractChangeTypeDeduction {
		return nil, ErrInvalidChangeType
	}
	title := strings.TrimSpace(in.Title)
	if title == "" {
		return nil, ErrTitleRequired
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	sc, err := txq.GetSubcontract(ctx, sqlc.GetSubcontractParams{ID: scID, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	if sc.Status != domain.SubcontractStatusActive {
		return nil, ErrSubcontractNotActiveForChange
	}

	number, err := s.generateSubcontractChangeOrderNo(ctx, txq, orgID)
	if err != nil {
		return nil, err
	}
	row, err := txq.CreateSubcontractChangeOrder(ctx, sqlc.CreateSubcontractChangeOrderParams{
		OrganizationID: orgID, ProjectID: pid, SubcontractID: scID, Number: number,
		Title: title, Description: in.Description, ChangeType: in.ChangeType, Reason: in.Reason, CreatedBy: actorUUID(in.UserID),
	})
	if err != nil {
		return nil, err
	}
	if err := insertSubcontractChangeOrderItems(ctx, txq, orgID, pid, row.ID, in.Items); err != nil {
		return nil, err
	}
	row, err = txq.RecomputeSubcontractChangeOrderTotal(ctx, sqlc.RecomputeSubcontractChangeOrderTotalParams{ID: row.ID, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		return nil, err
	}

	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventSubcontractChangeOrderCreated, actorUUID(in.UserID),
		map[string]any{"subcontract_id": subcontractID, "change_order_id": row.ID.String()}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainSubcontractChangeOrder(row)
	return &out, nil
}

func (s *ProjectService) ListSubcontractChangeOrders(ctx context.Context, projectID, subcontractID, organizationID string) ([]domain.SubcontractChangeOrder, error) {
	if _, err := s.GetSubcontract(ctx, projectID, subcontractID, organizationID); err != nil {
		return nil, err
	}
	id, _ := repository.StringToUUID(subcontractID)
	rows, err := s.q.ListSubcontractChangeOrders(ctx, id)
	if err != nil {
		return nil, err
	}
	out := make([]domain.SubcontractChangeOrder, len(rows))
	for i, r := range rows {
		out[i] = repository.ToDomainSubcontractChangeOrder(r)
	}
	return out, nil
}

func (s *ProjectService) GetSubcontractChangeOrder(ctx context.Context, projectID, changeOrderID, organizationID string) (*domain.SubcontractChangeOrder, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	id, err := repository.StringToUUID(changeOrderID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	row, err := s.q.GetSubcontractChangeOrder(ctx, sqlc.GetSubcontractChangeOrderParams{ID: id, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	out := repository.ToDomainSubcontractChangeOrder(row)
	return &out, nil
}

func (s *ProjectService) ListSubcontractChangeOrderItems(ctx context.Context, projectID, changeOrderID, organizationID string) ([]domain.SubcontractChangeOrderItem, error) {
	if _, err := s.GetSubcontractChangeOrder(ctx, projectID, changeOrderID, organizationID); err != nil {
		return nil, err
	}
	id, _ := repository.StringToUUID(changeOrderID)
	rows, err := s.q.ListSubcontractChangeOrderItems(ctx, id)
	if err != nil {
		return nil, err
	}
	out := make([]domain.SubcontractChangeOrderItem, len(rows))
	for i, r := range rows {
		out[i] = repository.ToDomainSubcontractChangeOrderItem(r)
	}
	return out, nil
}

func (s *ProjectService) UpdateSubcontractChangeOrderDraft(ctx context.Context, projectID, changeOrderID, organizationID string, in SubcontractChangeOrderInput) (*domain.SubcontractChangeOrder, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	id, err := repository.StringToUUID(changeOrderID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	if len(in.Items) == 0 {
		return nil, ErrSubcontractChangeOrderItemsRequired
	}
	if in.ChangeType != domain.SubcontractChangeTypeAddition && in.ChangeType != domain.SubcontractChangeTypeDeduction {
		return nil, ErrInvalidChangeType
	}
	title := strings.TrimSpace(in.Title)
	if title == "" {
		return nil, ErrTitleRequired
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	row, err := txq.UpdateSubcontractChangeOrderDraft(ctx, sqlc.UpdateSubcontractChangeOrderDraftParams{
		ID: id, OrganizationID: orgID, ProjectID: pid, Title: title, Description: in.Description,
		ChangeType: in.ChangeType, Reason: in.Reason,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrSubcontractChangeOrderNotEditable
		}
		return nil, err
	}
	if err := insertSubcontractChangeOrderItems(ctx, txq, orgID, pid, id, in.Items); err != nil {
		return nil, err
	}
	row, err = txq.RecomputeSubcontractChangeOrderTotal(ctx, sqlc.RecomputeSubcontractChangeOrderTotalParams{ID: id, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		return nil, err
	}

	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventSubcontractChangeOrderUpdated, actorUUID(in.UserID),
		map[string]any{"change_order_id": changeOrderID}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainSubcontractChangeOrder(row)
	return &out, nil
}

func (s *ProjectService) SubmitSubcontractChangeOrder(ctx context.Context, projectID, changeOrderID, organizationID, userID string) (*domain.SubcontractChangeOrder, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	id, err := repository.StringToUUID(changeOrderID)
	if err != nil {
		return nil, domain.ErrNotFound
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	// Değişiklik önce URL'deki projeye göre doğrulanır (kalemleri yalnızca
	// change_order_id ile okunur).
	if _, err := txq.GetSubcontractChangeOrderForUpdate(ctx, sqlc.GetSubcontractChangeOrderForUpdateParams{ID: id, OrganizationID: orgID, ProjectID: pid}); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	items, err := txq.ListSubcontractChangeOrderItems(ctx, id)
	if err != nil {
		return nil, err
	}
	if len(items) == 0 {
		return nil, ErrSubcontractChangeOrderItemsRequired
	}

	row, err := txq.SubmitSubcontractChangeOrder(ctx, sqlc.SubmitSubcontractChangeOrderParams{ID: id, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrSubcontractChangeOrderNotSubmittable
		}
		return nil, err
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventSubcontractChangeOrderSubmitted, actorUUID(userID),
		map[string]any{"change_order_id": changeOrderID}); err != nil {
		return nil, err
	}
	approvers, err := resolveProjectApprovers(ctx, txq, orgID, pid, domain.PermProjectsSubcontractsApprove)
	if err != nil {
		return nil, err
	}
	if err := createNotificationsForUsers(ctx, txq, approvers, CreateNotificationInput{
		OrganizationID: orgID, Type: domain.NotificationSubcontractChangeOrderSubmitted,
		Title: "Onay bekleyen ek iş", Body: row.Number,
		EntityType: domain.NotificationEntitySubcontractChangeOrder, EntityID: id, ProjectID: pid,
		ActionTarget: "/projeler/" + pid.String() + "/taseronlar/" + row.SubcontractID.String() + "/degisiklik-emirleri/" + changeOrderID,
	}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainSubcontractChangeOrder(row)
	return &out, nil
}

// ApproveSubcontractChangeOrder, spec §12/§14'ün kritik noktasıdır --
// YALNIZCA bu geçiş current_subcontract_value VE commitment'ları etkiler.
// Taşeron sözleşmesi satırı da KİLİTLENİR (FOR UPDATE) -- eşzamanlı bir
// fesih/tamamlanmayla yarışı engellemek için (spec §35: "termination
// concurrent with claim certification" testinin AYNI sınıf riski).
func (s *ProjectService) ApproveSubcontractChangeOrder(ctx context.Context, projectID, changeOrderID, organizationID, userID string) (*domain.SubcontractChangeOrder, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	id, err := repository.StringToUUID(changeOrderID)
	if err != nil {
		return nil, domain.ErrNotFound
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	current, err := txq.GetSubcontractChangeOrderForUpdate(ctx, sqlc.GetSubcontractChangeOrderForUpdateParams{ID: id, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	if current.Status != domain.SubcontractChangeOrderStatusSubmitted {
		return nil, ErrSubcontractChangeOrderNotApprovable
	}

	sc, err := txq.GetSubcontractForUpdate(ctx, sqlc.GetSubcontractForUpdateParams{ID: current.SubcontractID, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	if sc.Status != domain.SubcontractStatusActive {
		return nil, ErrSubcontractNotActiveForChange
	}

	row, err := txq.ApproveSubcontractChangeOrder(ctx, sqlc.ApproveSubcontractChangeOrderParams{ID: id, OrganizationID: orgID, ProjectID: pid, ApprovedBy: actorUUID(userID)})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrSubcontractChangeOrderNotApprovable
		}
		return nil, err
	}

	// Eksiltme, sözleşmeyi (ve dokunduğu maliyet kodu grubunu) şimdiye
	// kadar sertifikalanmış ya da ödenmiş tutarın altına indiremez -- aksi
	// halde güncel bedel yapılmış/ödenmiş işin altında kalıyor, taahhüt
	// senkronu negatif grubu sessizce düşürüyordu. Kontrol, bu onay
	// UYGULANMIŞ haliyle (aynı transaction'da, sözleşme satırı kilitliyken)
	// yapılır; ihlalde transaction geri alınır.
	if row.ChangeType == domain.SubcontractChangeTypeDeduction {
		caps, err := loadSubcontractClaimCaps(ctx, txq, orgID, pid, sc)
		if err != nil {
			return nil, err
		}
		paid, err := txq.GetSubcontractPaidToDate(ctx, sqlc.GetSubcontractPaidToDateParams{SubcontractID: sc.ID, OrganizationID: orgID, ProjectID: pid})
		if err != nil {
			return nil, err
		}
		coItems, err := txq.ListSubcontractChangeOrderItems(ctx, id)
		if err != nil {
			return nil, err
		}
		touched := make(map[string]bool, len(coItems))
		for _, it := range coItems {
			touched[capGroupKey(it.CostCodeID, it.BudgetLineID)] = true
		}
		if err := caps.checkDeductionApproval(repository.NumericToDecimal(paid), touched); err != nil {
			return nil, err
		}
	}

	targets, err := s.currentSubcontractTargets(ctx, txq, orgID, pid, sc.ID)
	if err != nil {
		return nil, err
	}
	desc := fmt.Sprintf("Taşeron %s — değişiklik %s onaylandı", sc.SubcontractNo, row.Number)
	if err := s.syncSubcontractCommitments(ctx, txq, orgID, pid, sc.ID, targets, sc.Currency, desc, userID); err != nil {
		return nil, err
	}

	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventSubcontractChangeOrderApproved, actorUUID(userID),
		map[string]any{"change_order_id": changeOrderID, "subcontract_id": current.SubcontractID.String()}); err != nil {
		return nil, err
	}
	if err := createNotification(ctx, txq, CreateNotificationInput{
		OrganizationID: orgID, UserID: row.CreatedBy, Type: domain.NotificationSubcontractChangeOrderApproved,
		Title: "Ek iş onaylandı", Body: row.Number,
		EntityType: domain.NotificationEntitySubcontractChangeOrder, EntityID: id, ProjectID: pid,
		ActionTarget: "/projeler/" + pid.String() + "/taseronlar/" + current.SubcontractID.String() + "/degisiklik-emirleri/" + changeOrderID,
	}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainSubcontractChangeOrder(row)
	return &out, nil
}

func (s *ProjectService) RejectSubcontractChangeOrder(ctx context.Context, projectID, changeOrderID, organizationID, userID, reason string) (*domain.SubcontractChangeOrder, error) {
	reason = strings.TrimSpace(reason)
	if reason == "" {
		return nil, ErrSubcontractChangeOrderReasonRequired
	}
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	id, err := repository.StringToUUID(changeOrderID)
	if err != nil {
		return nil, domain.ErrNotFound
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	row, err := txq.RejectSubcontractChangeOrder(ctx, sqlc.RejectSubcontractChangeOrderParams{
		ID: id, OrganizationID: orgID, ProjectID: pid, RejectedBy: actorUUID(userID), RejectionReason: reason,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrSubcontractChangeOrderNotRejectable
		}
		return nil, err
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventSubcontractChangeOrderRejected, actorUUID(userID),
		map[string]any{"change_order_id": changeOrderID, "reason": reason}); err != nil {
		return nil, err
	}
	if err := createNotification(ctx, txq, CreateNotificationInput{
		OrganizationID: orgID, UserID: row.CreatedBy, Type: domain.NotificationSubcontractChangeOrderRejected,
		Title: "Ek iş reddedildi", Body: row.Number,
		EntityType: domain.NotificationEntitySubcontractChangeOrder, EntityID: id, ProjectID: pid,
		ActionTarget: "/projeler/" + pid.String() + "/taseronlar/" + row.SubcontractID.String() + "/degisiklik-emirleri/" + changeOrderID,
	}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainSubcontractChangeOrder(row)
	return &out, nil
}

func (s *ProjectService) CancelSubcontractChangeOrder(ctx context.Context, projectID, changeOrderID, organizationID, userID string) (*domain.SubcontractChangeOrder, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	id, err := repository.StringToUUID(changeOrderID)
	if err != nil {
		return nil, domain.ErrNotFound
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	row, err := txq.CancelSubcontractChangeOrder(ctx, sqlc.CancelSubcontractChangeOrderParams{ID: id, OrganizationID: orgID, ProjectID: pid, CancelledBy: actorUUID(userID)})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrSubcontractChangeOrderNotCancellable
		}
		return nil, err
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventSubcontractChangeOrderCancelled, actorUUID(userID),
		map[string]any{"change_order_id": changeOrderID}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainSubcontractChangeOrder(row)
	return &out, nil
}
