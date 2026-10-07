package service

import (
	"context"
	"errors"
	"strings"

	"github.com/jackc/pgx/v5"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

var (
	// ErrBudgetNotYetBaselined, DRAFT durumundaki bir bütçe için Budget
	// Adjustment oluşturma girişiminde döner -- draft'ta değişiklik zaten
	// doğrudan bütçe kalemi düzenlemesiyle (UpdateBudgetLine) yapılır;
	// Adjustment YALNIZCA baseline SONRASI (original değerler sabitlendikten
	// sonra) anlamlıdır (bkz. ErrBudgetBaselined'ın simetriği).
	ErrBudgetNotYetBaselined = errors.New("bütçe revizyonu (adjustment) yalnızca baseline alınmış bir bütçe için oluşturulabilir")
	// ErrAdjustmentNotPending, draft DIŞINDA (zaten onaylanmış/reddedilmiş)
	// bir adjustment'ı tekrar onaylama/reddetme girişiminde döner --
	// eşzamanlı çift onay/red burada engellenir (bkz. ApproveBudgetAdjustment/
	// RejectBudgetAdjustment sorgu yorumu, RespondChangeOrder İLE AYNI ilke).
	ErrAdjustmentNotPending = errors.New("yalnızca taslak durumundaki bir bütçe revizyonu onaylanabilir veya reddedilebilir")
)

type BudgetAdjustmentInput struct {
	BudgetLineID string
	Amount       float64 // sıfır OLAMAZ (CHECK amount <> 0), negatif = bütçe azaltımı
	Reason       string
	UserID       string
}

// CreateBudgetAdjustment, YENİ bir revizyon TASLAĞI oluşturur -- amount
// henüz REVISED BUDGET'ı ETKİLEMEZ (yalnızca status='approved' olanlar
// etkiler, bkz. ListCostControlLines'ın "adjustments" CTE'si WHERE
// status='approved'). Onay AYRI bir adımdır (ApproveBudgetAdjustment).
func (s *ProjectService) CreateBudgetAdjustment(ctx context.Context, projectID, organizationID string, in BudgetAdjustmentInput) (*domain.BudgetAdjustment, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	in.Reason = strings.TrimSpace(in.Reason)
	if in.Reason == "" {
		return nil, errors.New("revizyon gerekçesi zorunludur")
	}
	if in.Amount == 0 {
		return nil, errors.New("revizyon tutarı sıfır olamaz")
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	// Tamamlanmış/iptal edilmiş projenin rakamları değişmez (bkz.
	// requireOpenProject; tamamlanan proje yeniden aktife alınarak açılır).
	if _, err := s.requireOpenProject(ctx, txq, pid, orgID); err != nil {
		return nil, err
	}

	budget, err := txq.GetProjectBudget(ctx, sqlc.GetProjectBudgetParams{ProjectID: pid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrBudgetNotFound
		}
		return nil, err
	}
	if budget.Status != domain.BudgetStatusBaselined {
		return nil, ErrBudgetNotYetBaselined
	}
	if strings.TrimSpace(in.BudgetLineID) == "" {
		return nil, ErrBudgetLineRefNotFound
	}
	lineID, err := resolveBudgetLineRef(ctx, txq, in.BudgetLineID, pid, orgID)
	if err != nil {
		return nil, err
	}
	row, err := txq.CreateBudgetAdjustment(ctx, sqlc.CreateBudgetAdjustmentParams{
		OrganizationID: orgID, ProjectID: pid, BudgetID: budget.ID, BudgetLineID: lineID,
		Amount: repository.Float64ToNumeric(in.Amount), Reason: in.Reason, CreatedBy: actorUUID(in.UserID),
	})
	if err != nil {
		return nil, err
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventAdjustmentCreated, actorUUID(in.UserID),
		map[string]any{"adjustment_id": row.ID.String(), "budget_line_id": in.BudgetLineID, "amount": in.Amount}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainBudgetAdjustment(row)
	return &out, nil
}

func (s *ProjectService) ListBudgetAdjustments(ctx context.Context, projectID, organizationID string) ([]domain.BudgetAdjustment, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	rows, err := s.q.ListBudgetAdjustments(ctx, sqlc.ListBudgetAdjustmentsParams{ProjectID: pid, OrganizationID: orgID})
	if err != nil {
		return nil, err
	}
	out := make([]domain.BudgetAdjustment, len(rows))
	for i, r := range rows {
		out[i] = repository.ToDomainBudgetAdjustment(r)
	}
	return out, nil
}

// ApproveBudgetAdjustment/RejectBudgetAdjustment, FOR UPDATE + status=
// 'draft' koşullu UPDATE ile korunur -- eşzamanlı çift onay/red imkansızdır
// (bkz. RespondChangeOrder İLE AYNI ilke, project_change_order_service.go).
func (s *ProjectService) ApproveBudgetAdjustment(ctx context.Context, projectID, adjustmentID, organizationID, userID string) (*domain.BudgetAdjustment, error) {
	return s.decideBudgetAdjustment(ctx, projectID, adjustmentID, organizationID, userID, true)
}

func (s *ProjectService) RejectBudgetAdjustment(ctx context.Context, projectID, adjustmentID, organizationID, userID string) (*domain.BudgetAdjustment, error) {
	return s.decideBudgetAdjustment(ctx, projectID, adjustmentID, organizationID, userID, false)
}

func (s *ProjectService) decideBudgetAdjustment(ctx context.Context, projectID, adjustmentID, organizationID, userID string, approve bool) (*domain.BudgetAdjustment, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	aid, err := repository.StringToUUID(adjustmentID)
	if err != nil {
		return nil, domain.ErrNotFound
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	// Onay revize bütçeyi değiştirir: kapalı projede yapılamaz. Red hiçbir
	// rakamı değiştirmez, iptal edilmiş (son durum) projede bekleyen
	// revizyonlar temizlenebilsin diye serbest.
	if approve {
		if _, err := s.requireOpenProject(ctx, txq, pid, orgID); err != nil {
			return nil, err
		}
	}

	current, err := txq.GetBudgetAdjustmentForUpdate(ctx, sqlc.GetBudgetAdjustmentForUpdateParams{ID: aid, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	if current.Status != domain.AdjustmentStatusDraft {
		return nil, ErrAdjustmentNotPending
	}

	var row sqlc.ProjectBudgetAdjustment
	var eventType string
	if approve {
		row, err = txq.ApproveBudgetAdjustment(ctx, sqlc.ApproveBudgetAdjustmentParams{ID: aid, OrganizationID: orgID, ProjectID: pid, ApprovedBy: actorUUID(userID)})
		eventType = domain.ProjectEventAdjustmentApproved
	} else {
		row, err = txq.RejectBudgetAdjustment(ctx, sqlc.RejectBudgetAdjustmentParams{ID: aid, OrganizationID: orgID, ProjectID: pid, ApprovedBy: actorUUID(userID)})
		eventType = domain.ProjectEventAdjustmentRejected
	}
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrAdjustmentNotPending
		}
		return nil, err
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, eventType, actorUUID(userID),
		map[string]any{"adjustment_id": adjustmentID}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainBudgetAdjustment(row)
	return &out, nil
}
