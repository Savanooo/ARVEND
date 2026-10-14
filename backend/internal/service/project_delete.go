package service

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

// Proje silme (migration 0070, ürün sahibinin kararı 2026-10): teklifteki
// gibi -- projects.delete (Sahip/Yönetici) direkt siler; projeyi
// düzenleyebilen diğerleri silme talebi açar, yetkili onaylar ya da
// reddeder. İçinde para hareketi (masraf, tahsilat, taşeron ödemesi, fatura)
// ya da satın alma / taşeron sözleşmesi kaydı olan proje SİLİNMEZ; İptal
// durumuna alınır. Silinen projenin görevleri, notları, dosya/fotoğrafları,
// ödeme planı, ek işleri, bütçe/WBS'si, sözleşmesi, ekibi ve hareketleri de
// gider; kaynak teklif yeniden projeye dönüştürülebilir.

var (
	ErrProjectHasRecords             = errors.New("bu projede para hareketi var; proje silinemez")
	ErrProjectDeleteAlreadyRequested = errors.New("bu proje için zaten bekleyen bir silme talebi var")
	ErrProjectDeleteRequestNotFound  = errors.New("bu proje için bekleyen bir silme talebi yok")
	ErrProjectDeleteRequestNotOwn    = errors.New("silme talebini yalnızca açan kişi geri çekebilir")
)

// ProjectHasRecordsError: neyin silmeyi engellediğini sayılarla söyler
// ("3 masraf, 1 tahsilat"); errors.Is(ErrProjectHasRecords).
type ProjectHasRecordsError struct{ Parts []string }

func (e *ProjectHasRecordsError) Error() string {
	return "Bu projede " + strings.Join(e.Parts, ", ") + " var; proje silinemez. " +
		"Kayıtlar kaybolmasın diye projeyi İptal durumuna alabilirsin."
}

func (e *ProjectHasRecordsError) Is(target error) bool { return target == ErrProjectHasRecords }

// checkProjectDeletable: iptal edilmiş kayıtlar da sayılır (denetim izi).
func checkProjectDeletable(ctx context.Context, txq *sqlc.Queries, projectID pgtype.UUID) error {
	c, err := txq.CountProjectDeleteBlockers(ctx, projectID)
	if err != nil {
		return err
	}
	var parts []string
	add := func(n int32, label string) {
		if n > 0 {
			parts = append(parts, fmt.Sprintf("%d %s", n, label))
		}
	}
	add(c.Expenses, "masraf")
	add(c.Collections, "tahsilat")
	add(c.SubcontractorPayments+c.SubcontractPayments, "taşeron ödemesi")
	add(c.Invoices, "fatura")
	add(c.PurchaseRequests+c.Rfqs+c.PurchaseOrders, "satın alma kaydı")
	add(c.Subcontracts, "taşeron sözleşmesi")
	if len(parts) > 0 {
		return &ProjectHasRecordsError{Parts: parts}
	}
	return nil
}

// deleteProjectTx: kilitli projeyi siler; depodan silinecek nesne
// anahtarlarını döner (işlem bittikten sonra silinir).
func deleteProjectTx(ctx context.Context, txq *sqlc.Queries, p sqlc.Project, actor pgtype.UUID) ([]string, error) {
	if err := checkProjectDeletable(ctx, txq, p.ID); err != nil {
		return nil, err
	}
	keys, err := txq.ListProjectObjectKeys(ctx, p.ID)
	if err != nil {
		return nil, err
	}
	for _, del := range []func(context.Context, pgtype.UUID, pgtype.UUID) error{
		func(ctx context.Context, pid, org pgtype.UUID) error {
			return txq.DeleteProjectCostForecasts(ctx, sqlc.DeleteProjectCostForecastsParams{ProjectID: pid, OrganizationID: org})
		},
		func(ctx context.Context, pid, org pgtype.UUID) error {
			return txq.DeleteProjectCommitments(ctx, sqlc.DeleteProjectCommitmentsParams{ProjectID: pid, OrganizationID: org})
		},
		func(ctx context.Context, pid, org pgtype.UUID) error {
			return txq.DeleteProjectBudgetAdjustments(ctx, sqlc.DeleteProjectBudgetAdjustmentsParams{ProjectID: pid, OrganizationID: org})
		},
		func(ctx context.Context, pid, org pgtype.UUID) error {
			return txq.DeleteProjectBudgetLines(ctx, sqlc.DeleteProjectBudgetLinesParams{ProjectID: pid, OrganizationID: org})
		},
		func(ctx context.Context, pid, org pgtype.UUID) error {
			return txq.DeleteProjectBudgets(ctx, sqlc.DeleteProjectBudgetsParams{ProjectID: pid, OrganizationID: org})
		},
		func(ctx context.Context, pid, org pgtype.UUID) error {
			return txq.DeleteProjectWBSNodes(ctx, sqlc.DeleteProjectWBSNodesParams{ProjectID: pid, OrganizationID: org})
		},
		func(ctx context.Context, pid, org pgtype.UUID) error {
			return txq.DeleteProjectContracts(ctx, sqlc.DeleteProjectContractsParams{ProjectID: pid, OrganizationID: org})
		},
	} {
		if err := del(ctx, p.ID, p.OrganizationID); err != nil {
			return nil, err
		}
	}
	meta := map[string]any{"project_id": p.ID.String(), "project_no": p.ProjectNo, "name": p.Name}
	if p.SourceOfferID.Valid {
		if err := logOfferEvent(ctx, txq, p.OrganizationID, p.SourceOfferID, pgtype.UUID{}, domain.EventProjectDeleted,
			actor, meta, "", ""); err != nil {
			return nil, err
		}
	}
	if err := logOrgEvent(ctx, txq, p.OrganizationID, domain.OrgEventProjectDeleted, actor, meta); err != nil {
		return nil, err
	}
	n, err := txq.DeleteProjectRow(ctx, sqlc.DeleteProjectRowParams{ID: p.ID, OrganizationID: p.OrganizationID})
	if err != nil {
		return nil, err
	}
	if n == 0 {
		return nil, domain.ErrNotFound
	}
	return keys, nil
}

func (s *ProjectService) removeObjects(ctx context.Context, keys []string) {
	for _, k := range keys {
		if k != "" {
			_ = s.store.Delete(ctx, k)
		}
	}
}

// DeleteProject: projects.delete sahibinin direkt silmesi.
func (s *ProjectService) DeleteProject(ctx context.Context, projectID, organizationID, userID string) error {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return err
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	p, err := lockProjectRow(ctx, txq, pid, orgID)
	if err != nil {
		return err
	}
	keys, err := deleteProjectTx(ctx, txq, p, actorUUID(userID))
	if err != nil {
		return err
	}
	if err := tx.Commit(ctx); err != nil {
		return err
	}
	s.removeObjects(ctx, keys)
	return nil
}

// RequestProjectDelete: silme izni olmayanın talebi. Silinemeyecek
// projeye (para hareketi var) talep açılmaz -- aynı hata hemen söylenir.
func (s *ProjectService) RequestProjectDelete(ctx context.Context, projectID, organizationID, userID, reason string) (*domain.ProjectDeleteRequest, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	actor := actorUUID(userID)
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	p, err := lockProjectRow(ctx, txq, pid, orgID)
	if err != nil {
		return nil, err
	}
	if err := checkProjectDeletable(ctx, txq, pid); err != nil {
		return nil, err
	}
	reason = truncateRunes(strings.TrimSpace(reason), 500)
	row, err := txq.CreateProjectDeleteRequest(ctx, sqlc.CreateProjectDeleteRequestParams{
		OrganizationID: orgID, ProjectID: pid, RequestedBy: actor, Reason: reason,
	})
	if err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" {
			return nil, ErrProjectDeleteAlreadyRequested
		}
		return nil, err
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventDeleteRequested, actor,
		nonEmptyMeta("reason", reason)); err != nil {
		return nil, err
	}
	if err := notifyProjectDeleteRequested(ctx, txq, p, actor); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := &domain.ProjectDeleteRequest{
		ID: row.ID.String(), ProjectID: row.ProjectID.String(), Reason: row.Reason, CreatedAt: row.CreatedAt.Time,
	}
	if actor.Valid {
		id := actor.String()
		out.RequestedBy = &id
		if u, err := s.q.GetUserByID(ctx, actor); err == nil {
			out.RequestedByName = u.FullName
		}
	}
	return out, nil
}

// ApproveProjectDeleteRequest: projeyi siler ve talep edene bildirir.
// Talep açıldıktan sonra projeye para hareketi girdiyse silinmez
// (ProjectHasRecordsError); talep reddedilmeli.
func (s *ProjectService) ApproveProjectDeleteRequest(ctx context.Context, projectID, organizationID, userID string) error {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return err
	}
	actor := actorUUID(userID)
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	p, err := lockProjectRow(ctx, txq, pid, orgID)
	if err != nil {
		return err
	}
	req, err := lockPendingProjectDeleteRequest(ctx, txq, pid, orgID)
	if err != nil {
		return err
	}
	// Bildirim proje silinmeden önce, projeye bağlanmadan yazılır (proje
	// bağlı bildirimler projeyle birlikte silinir).
	if err := notifyProjectDeleteDecision(ctx, txq, p, req, actor, true, ""); err != nil {
		return err
	}
	keys, err := deleteProjectTx(ctx, txq, p, actor)
	if err != nil {
		return err
	}
	if err := tx.Commit(ctx); err != nil {
		return err
	}
	s.removeObjects(ctx, keys)
	return nil
}

func (s *ProjectService) RejectProjectDeleteRequest(ctx context.Context, projectID, organizationID, userID, note string) error {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return err
	}
	actor := actorUUID(userID)
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	p, err := lockProjectRow(ctx, txq, pid, orgID)
	if err != nil {
		return err
	}
	req, err := lockPendingProjectDeleteRequest(ctx, txq, pid, orgID)
	if err != nil {
		return err
	}
	note = truncateRunes(strings.TrimSpace(note), 500)
	if _, err := txq.DecideProjectDeleteRequest(ctx, sqlc.DecideProjectDeleteRequestParams{
		Status: "rejected", DecidedBy: actor, DecisionNote: note, ID: req.ID, OrganizationID: orgID,
	}); err != nil {
		return err
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventDeleteRejected, actor, nonEmptyMeta("note", note)); err != nil {
		return err
	}
	if err := notifyProjectDeleteDecision(ctx, txq, p, req, actor, false, note); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func (s *ProjectService) WithdrawProjectDeleteRequest(ctx context.Context, projectID, organizationID, userID string) error {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return err
	}
	actor := actorUUID(userID)
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	req, err := lockPendingProjectDeleteRequest(ctx, txq, pid, orgID)
	if err != nil {
		return err
	}
	if !actor.Valid || req.RequestedBy != actor {
		return ErrProjectDeleteRequestNotOwn
	}
	if _, err := txq.DecideProjectDeleteRequest(ctx, sqlc.DecideProjectDeleteRequestParams{
		Status: "withdrawn", DecidedBy: actor, ID: req.ID, OrganizationID: orgID,
	}); err != nil {
		return err
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventDeleteWithdrawn, actor, nil); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// PendingProjectDeleteRequest: projenin bekleyen talebi (yoksa nil).
func (s *ProjectService) PendingProjectDeleteRequest(ctx context.Context, projectID, organizationID string) (*domain.ProjectDeleteRequest, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	r, err := s.q.GetPendingProjectDeleteRequest(ctx, sqlc.GetPendingProjectDeleteRequestParams{ProjectID: pid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, nil
		}
		return nil, err
	}
	out := &domain.ProjectDeleteRequest{
		ID: r.ID.String(), ProjectID: r.ProjectID.String(), Reason: r.Reason,
		RequestedByName: r.RequestedByName, CreatedAt: r.CreatedAt.Time,
	}
	if r.RequestedBy.Valid {
		id := r.RequestedBy.String()
		out.RequestedBy = &id
	}
	return out, nil
}

// ListPendingProjectDeleteRequests: firmanın bekleyen proje silme
// talepleri, en eskisi önce.
func (s *ProjectService) ListPendingProjectDeleteRequests(ctx context.Context, organizationID string) ([]domain.ProjectDeleteRequest, error) {
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	rows, err := s.q.ListPendingProjectDeleteRequests(ctx, orgID)
	if err != nil {
		return nil, err
	}
	out := make([]domain.ProjectDeleteRequest, len(rows))
	for i, r := range rows {
		out[i] = domain.ProjectDeleteRequest{
			ID: r.ID.String(), ProjectID: r.ProjectID.String(), Reason: r.Reason,
			RequestedByName: r.RequestedByName, CreatedAt: r.CreatedAt.Time,
			ProjectNo: r.ProjectNo, ProjectName: r.ProjectName, CustomerName: r.CustomerName,
		}
		if r.RequestedBy.Valid {
			id := r.RequestedBy.String()
			out[i].RequestedBy = &id
		}
	}
	return out, nil
}

func lockProjectRow(ctx context.Context, txq *sqlc.Queries, pid, orgID pgtype.UUID) (sqlc.Project, error) {
	p, err := txq.GetProjectByIDForUpdate(ctx, sqlc.GetProjectByIDForUpdateParams{ID: pid, OrganizationID: orgID})
	if errors.Is(err, pgx.ErrNoRows) {
		return p, domain.ErrNotFound
	}
	return p, err
}

func lockPendingProjectDeleteRequest(ctx context.Context, txq *sqlc.Queries, pid, orgID pgtype.UUID) (sqlc.ProjectDeleteRequest, error) {
	req, err := txq.GetPendingProjectDeleteRequestForUpdate(ctx, sqlc.GetPendingProjectDeleteRequestForUpdateParams{ProjectID: pid, OrganizationID: orgID})
	if errors.Is(err, pgx.ErrNoRows) {
		return req, ErrProjectDeleteRequestNotFound
	}
	return req, err
}

func projectNoticeLabel(p sqlc.Project) string {
	return joinNonEmpty(" · ", p.ProjectNo, truncateRunes(p.Name, 80))
}

// notifyProjectDeleteRequested: projenin silme yetkililerine (projects.delete
// + proje erişimi), talep eden hariç.
func notifyProjectDeleteRequested(ctx context.Context, txq *sqlc.Queries, p sqlc.Project, actor pgtype.UUID) error {
	all, err := resolveProjectApprovers(ctx, txq, p.OrganizationID, p.ID, domain.PermProjectsDelete)
	if err != nil {
		return err
	}
	r := newRecipientList(actor)
	for _, id := range all {
		r.add(id)
	}
	if len(r.ids) == 0 {
		return nil
	}
	body := projectNoticeLabel(p)
	if u, err := txq.GetUserByID(ctx, actor); err == nil && strings.TrimSpace(u.FullName) != "" {
		body = joinNonEmpty(" · ", body, "Talep eden: "+u.FullName)
	}
	return createNotificationsForUsers(ctx, txq, r.ids, CreateNotificationInput{
		OrganizationID: p.OrganizationID, Type: domain.NotificationProjectDeleteRequested,
		Title: "Proje silme onayı bekliyor", Body: truncateRunes(body, 500),
		EntityType: domain.NotificationEntityProject, EntityID: p.ID, ProjectID: p.ID,
		ActionTarget: "/projeler/" + p.ID.String(),
	})
}

// notifyProjectDeleteDecision: kararı talep edene bildirir. Onayda proje
// silineceği için bildirim projeye bağlanmaz ve proje listesini açar.
func notifyProjectDeleteDecision(ctx context.Context, txq *sqlc.Queries, p sqlc.Project, req sqlc.ProjectDeleteRequest, actor pgtype.UUID, approved bool, note string) error {
	if !req.RequestedBy.Valid || (actor.Valid && req.RequestedBy == actor) {
		return nil
	}
	in := CreateNotificationInput{
		OrganizationID: p.OrganizationID, UserID: req.RequestedBy,
		Type: domain.NotificationProjectDeleteRejected, Title: "Proje silme talebin reddedildi",
		EntityType: domain.NotificationEntityProject, EntityID: p.ID, ProjectID: p.ID,
		ActionTarget: "/projeler/" + p.ID.String(),
	}
	body := projectNoticeLabel(p)
	if approved {
		in.Type, in.Title, in.ProjectID, in.ActionTarget = domain.NotificationProjectDeleteApproved, "Proje silindi", pgtype.UUID{}, "/projeler"
		body = joinNonEmpty(" · ", body, "Silme talebin onaylandı")
	} else if note != "" {
		body = joinNonEmpty(" · ", body, "Gerekçe: "+note)
	}
	in.Body = truncateRunes(body, 500)
	return createNotification(ctx, txq, in)
}
