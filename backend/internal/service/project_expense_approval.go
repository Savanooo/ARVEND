package service

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

// Masraf onayı (migration 0060, ürün sahibinin kararı): her masraf -- kim
// girerse girsin -- onay bekleyerek başlar; projects.expenses.approve
// sahibi onaylar ya da gerekçeyle reddeder. Para toplamlarına yalnızca
// onaylı masraf girer (SQL toplamları approval_status = 'approved' ile
// süzülür). Onaylayan kendi masrafını onaylayabilir.

var (
	ErrExpenseNotFound error = &NotFoundError{What: "masraf bu projede"}
	// ErrExpenseNotPending: zaten onaylanmış/reddedilmiş masrafa ikinci karar
	// (eşzamanlı iki onaylayıcıdan geç kalan da bunu alır). Reddedilen masraf
	// düzenlenince yeniden onaya düşer.
	ErrExpenseNotPending = errors.New("yalnızca onay bekleyen bir masraf onaylanabilir veya reddedilebilir")
	// ErrExpenseRejectReasonRequired: masrafı giren neden reddedildiğini
	// bilmeden düzeltemez.
	ErrExpenseRejectReasonRequired = errors.New("ret gerekçesi zorunludur")
	ErrExpenseRejectReasonTooLong  = fmt.Errorf("ret gerekçesi en fazla %d karakter olabilir", domain.ExpenseDecisionNoteMaxLen)
)

// ApproveExpense: onay bekleyen masrafı onaylar -- masraf bu andan itibaren
// gerçekleşen maliyete ve kâra girer.
func (s *ProjectService) ApproveExpense(ctx context.Context, projectID, expenseID, organizationID, userID string) (*domain.Expense, error) {
	return s.decideExpense(ctx, projectID, expenseID, organizationID, userID, true, "")
}

// RejectExpense: onay bekleyen masrafı gerekçeyle reddeder -- masraf
// listede kalır ama hiçbir toplama girmez.
func (s *ProjectService) RejectExpense(ctx context.Context, projectID, expenseID, organizationID, userID, reason string) (*domain.Expense, error) {
	return s.decideExpense(ctx, projectID, expenseID, organizationID, userID, false, reason)
}

func (s *ProjectService) decideExpense(ctx context.Context, projectID, expenseID, organizationID, userID string, approve bool, reason string) (*domain.Expense, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	eid, err := repository.StringToUUID(expenseID)
	if err != nil {
		return nil, ErrExpenseNotFound
	}
	reason = strings.TrimSpace(reason)
	status, eventType := domain.ExpenseApprovalApproved, domain.ProjectEventExpenseApproved
	if !approve {
		status, eventType = domain.ExpenseApprovalRejected, domain.ProjectEventExpenseRejected
		if reason == "" {
			return nil, ErrExpenseRejectReasonRequired
		}
		if utf8.RuneCountInString(reason) > domain.ExpenseDecisionNoteMaxLen {
			return nil, ErrExpenseRejectReasonTooLong
		}
	} else {
		reason = ""
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	// Diğer finans yazımlarıyla aynı kilit: tamamlanmış/iptal edilmiş
	// projenin rakamları değişmez (onay gerçekleşen maliyeti değiştirir).
	project, err := s.requireOpenProject(ctx, txq, pid, orgID)
	if err != nil {
		return nil, err
	}

	actor := actorUUID(userID)
	row, err := txq.DecideExpense(ctx, sqlc.DecideExpenseParams{
		ApprovalStatus: status, DecidedBy: actor, DecisionNote: reason,
		ID: eid, OrganizationID: orgID, ProjectID: pid,
	})
	if err != nil {
		if !errors.Is(err, pgx.ErrNoRows) {
			return nil, err
		}
		existing, gerr := txq.GetExpense(ctx, sqlc.GetExpenseParams{ID: eid, OrganizationID: orgID, ProjectID: pid})
		switch {
		case errors.Is(gerr, pgx.ErrNoRows):
			return nil, ErrExpenseNotFound
		case gerr != nil:
			return nil, gerr
		case existing.VoidedAt.Valid:
			return nil, ErrAlreadyVoided
		default:
			return nil, ErrExpenseNotPending
		}
	}

	meta := map[string]any{"expense_id": expenseID, "amount": repository.NumericToFloat64(row.Amount)}
	if !approve {
		meta["reason"] = reason
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, eventType, actor, meta); err != nil {
		return nil, err
	}
	if err := notifyExpenseDecision(ctx, txq, project, row, actor); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainExpense(row)
	return &out, nil
}

// expenseFinanceTarget: bildirimin açtığı yer -- projenin Finans > Masraf &
// Tahsilat görünümü (mobil yolu; web webHrefForActionTarget ile Finans
// sekmesine çevirir).
func expenseFinanceTarget(projectID pgtype.UUID) string {
	return "/projeler/" + projectID.String() + "?grup=finans&alt=finans"
}

func expensePendingTitle(n int) string {
	if n <= 1 {
		return "Onay bekleyen masraf"
	}
	return fmt.Sprintf("%d masraf onay bekliyor", n)
}

// notifyExpensePendingApproval: yeni ya da düzenlenip yeniden onaya düşen
// masraf için projenin onaylayıcılarına (projects.expenses.approve + proje
// erişimi, bkz. resolveProjectApprovers) gruplu bildirim -- masrafı giren
// hariç (kendi girdiğini zaten biliyor; listede "Onay bekliyor" görür).
// Tutar ve tedarikçi bildirime yazılmaz (bkz. domain.Notification notu).
func notifyExpensePendingApproval(ctx context.Context, txq *sqlc.Queries, project sqlc.Project, row sqlc.ProjectExpense, actor pgtype.UUID) error {
	approvers, err := resolveProjectApprovers(ctx, txq, project.OrganizationID, project.ID, domain.PermProjectsExpensesApprove)
	if err != nil || len(approvers) == 0 {
		return err
	}
	who := ""
	if actor.Valid {
		if u, err := txq.GetUserByID(ctx, actor); err == nil {
			who = u.FullName
		}
	}
	return notifyUsersGrouped(ctx, txq, project.OrganizationID, project.ID, approvers, actor, groupedNotice{
		Type: domain.NotificationExpensePendingApproval, EntityType: domain.NotificationEntityProjectExpense,
		EntityID: row.ID, Title: expensePendingTitle,
		Body:   joinNonEmpty(" · ", project.Name, who),
		Target: expenseFinanceTarget(project.ID),
	})
}

// notifyExpenseDecision: kararı masrafı girene bildirir (ret gerekçesiyle).
// Kendi masrafını onaylayan kendine bildirim almaz; giren kişinin hesabı
// silinmişse (created_by NULL) createNotification sessizce atlar.
func notifyExpenseDecision(ctx context.Context, txq *sqlc.Queries, project sqlc.Project, row sqlc.ProjectExpense, actor pgtype.UUID) error {
	if !row.CreatedBy.Valid || (actor.Valid && row.CreatedBy == actor) {
		return nil
	}
	notifType, title := domain.NotificationExpenseApproved, "Masraf onaylandı"
	body := joinNonEmpty(" · ", project.Name, truncateRunes(row.Description, 80))
	if row.ApprovalStatus == domain.ExpenseApprovalRejected {
		notifType, title = domain.NotificationExpenseRejected, "Masraf reddedildi"
		body = joinNonEmpty(" · ", body, "Gerekçe: "+row.DecisionNote)
	}
	return createNotification(ctx, txq, CreateNotificationInput{
		OrganizationID: project.OrganizationID, UserID: row.CreatedBy, Type: notifType,
		Title: title, Body: truncateRunes(body, 500),
		EntityType: domain.NotificationEntityProjectExpense, EntityID: row.ID, ProjectID: project.ID,
		ActionTarget: expenseFinanceTarget(project.ID),
	})
}
