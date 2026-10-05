package service

import (
	"context"
	"errors"
	"strings"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

var (
	ErrTaskUpdateEmpty   = errors.New("not ya da durum değişikliği gerekli")
	ErrTaskUpdateTooLong = errors.New("not en fazla 2000 karakter olabilir")
	ErrTaskStatusInvalid = errors.New("geçersiz görev durumu")
)

const maxTaskUpdateRunes = 2000

// AddTaskUpdate, göreve not yazar; newStatus doluysa ve farklıysa görevin
// durumunu da değiştirir (sahada 2026-10: "görevi görsün, hakkında bilgi
// versin, yöneticiye bildirim gitsin"). Bildirim: görevi oluşturan ve
// atanan kişinin bağlı kullanıcısı -- notu yazan hariç (kendine bildirim
// yok). Not tamamlama içeriyorsa bildirim "Görev tamamlandı" olur.
func (s *ProjectService) AddTaskUpdate(ctx context.Context, projectID, taskID, organizationID, userID, body, newStatus string) (*domain.TaskUpdate, *domain.ProjectTask, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, nil, err
	}
	tid, err := repository.StringToUUID(taskID)
	if err != nil {
		return nil, nil, domain.ErrNotFound
	}
	body = strings.TrimSpace(body)
	newStatus = strings.TrimSpace(newStatus)
	if utf8.RuneCountInString(body) > maxTaskUpdateRunes {
		return nil, nil, ErrTaskUpdateTooLong
	}
	if newStatus != "" && !domain.ValidTaskStatus(newStatus) {
		return nil, nil, ErrTaskStatusInvalid
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	// Kilit altında oku: eşzamanlı iki "tamamlandı" notu iki kez
	// task_completed yazmasın (UpdateTask ile aynı gerekçe).
	task, err := txq.GetTaskForUpdate(ctx, sqlc.GetTaskForUpdateParams{ID: tid, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, nil, domain.ErrNotFound
		}
		return nil, nil, err
	}
	statusChanged := newStatus != "" && newStatus != task.Status
	if body == "" && !statusChanged {
		return nil, nil, ErrTaskUpdateEmpty
	}

	actor := actorUUID(userID)
	author := ""
	if actor.Valid {
		if u, err := txq.GetUserByID(ctx, actor); err == nil {
			author = u.FullName
		}
	}

	params := sqlc.CreateTaskUpdateParams{
		OrganizationID: orgID, ProjectID: pid, TaskID: tid, UserID: actor, AuthorName: author, Body: body,
	}
	updatedTask := task
	if statusChanged {
		from, to := task.Status, newStatus
		params.StatusFrom, params.StatusTo = &from, &to
		updatedTask, err = txq.SetTaskStatus(ctx, sqlc.SetTaskStatusParams{
			Status: newStatus, ID: tid, OrganizationID: orgID, ProjectID: pid,
		})
		if err != nil {
			return nil, nil, err
		}
		ev := domain.ProjectEventTaskUpdated
		if newStatus == domain.TaskStatusCompleted {
			ev = domain.ProjectEventTaskCompleted
		}
		if err := logProjectEvent(ctx, txq, orgID, pid, ev, actor,
			map[string]any{"task_id": taskID, "title": task.Title, "status": newStatus}); err != nil {
			return nil, nil, err
		}
	}
	row, err := txq.CreateTaskUpdate(ctx, params)
	if err != nil {
		return nil, nil, err
	}

	notifType, title := domain.NotificationTaskUpdated, "Görevde yeni bilgi"
	if statusChanged && newStatus == domain.TaskStatusCompleted {
		notifType, title = domain.NotificationTaskCompleted, "Görev tamamlandı"
	}
	text := task.Title
	if body != "" {
		text += ": " + truncateRunes(body, 200)
	}
	if author != "" {
		text = author + " — " + text
	}
	if err := notifyTaskParties(ctx, txq, orgID, task, actor, CreateNotificationInput{
		OrganizationID: orgID, Type: notifType, Title: title, Body: text,
		EntityType: domain.NotificationEntityTask, EntityID: tid, ProjectID: pid,
		ActionTarget: "/projeler/" + pid.String() + "/gorevler/" + taskID,
	}); err != nil {
		return nil, nil, err
	}

	if err := tx.Commit(ctx); err != nil {
		return nil, nil, err
	}
	up := toDomainTaskUpdate(row)
	t := repository.ToDomainTask(updatedTask)
	return &up, &t, nil
}

// notifyTaskParties: görevi oluşturan + atanan kişinin bağlı kullanıcısı +
// projenin yöneticileri (projects.update; görevi bir ustabaşı vermiş olsa
// da yönetici haberdar olsun -- sahada istenen buydu), işlemi yapan
// hariç, tekilleştirilmiş.
func notifyTaskParties(ctx context.Context, txq *sqlc.Queries, orgID pgtype.UUID, task sqlc.ProjectTask, actor pgtype.UUID, in CreateNotificationInput) error {
	var recipients []pgtype.UUID
	seen := map[pgtype.UUID]bool{}
	add := func(u pgtype.UUID) {
		if !u.Valid || seen[u] || (actor.Valid && u == actor) {
			return
		}
		seen[u] = true
		recipients = append(recipients, u)
	}
	add(task.CreatedBy)
	if task.AssignedEmployeeID.Valid {
		if emp, err := txq.GetEmployeeByID(ctx, sqlc.GetEmployeeByIDParams{ID: task.AssignedEmployeeID, OrganizationID: orgID}); err == nil {
			add(emp.UserID)
		}
	}
	managers, err := resolveProjectApprovers(ctx, txq, orgID, task.ProjectID, domain.PermProjectsUpdate)
	if err != nil {
		return err
	}
	for _, m := range managers {
		add(m)
	}
	return createNotificationsForUsers(ctx, txq, recipients, in)
}

// ListTaskUpdates, görevin notları (eskiden yeniye).
func (s *ProjectService) ListTaskUpdates(ctx context.Context, projectID, taskID, organizationID string) ([]domain.TaskUpdate, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	tid, err := repository.StringToUUID(taskID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	if _, err := s.q.GetTask(ctx, sqlc.GetTaskParams{ID: tid, OrganizationID: orgID, ProjectID: pid}); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	rows, err := s.q.ListTaskUpdates(ctx, sqlc.ListTaskUpdatesParams{TaskID: tid, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		return nil, err
	}
	out := make([]domain.TaskUpdate, len(rows))
	for i, r := range rows {
		out[i] = toDomainTaskUpdate(r)
	}
	return out, nil
}

func toDomainTaskUpdate(r sqlc.ProjectTaskUpdate) domain.TaskUpdate {
	u := domain.TaskUpdate{
		ID: r.ID.String(), TaskID: r.TaskID.String(), ProjectID: r.ProjectID.String(),
		AuthorName: r.AuthorName, Body: r.Body, CreatedAt: r.CreatedAt.Time,
	}
	if r.UserID.Valid {
		s := r.UserID.String()
		u.UserID = &s
	}
	if r.StatusFrom != nil {
		u.StatusFrom = *r.StatusFrom
	}
	if r.StatusTo != nil {
		u.StatusTo = *r.StatusTo
	}
	return u
}

// ListTeamTasks: Görevler sekmesinin "Ekip" görünümü (erişilebilir
// projelerdeki tüm görevler; assigneeEmployeeID doluysa o kişinin).
func (s *ProjectService) ListTeamTasks(ctx context.Context, organizationID, statusMode, restrictToUserID, assigneeEmployeeID string) ([]MyTask, error) {
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	mode := strings.TrimSpace(statusMode)
	if mode == "" {
		mode = "open"
	}
	switch mode {
	case "open", "all", domain.TaskStatusTodo, domain.TaskStatusInProgress, domain.TaskStatusCompleted, domain.TaskStatusCancelled:
	default:
		return nil, errors.New("gecersiz status filtresi")
	}
	var restrict, assignee pgtype.UUID
	if restrictToUserID != "" {
		if restrict, err = repository.StringToUUID(restrictToUserID); err != nil {
			return nil, domain.ErrNotFound
		}
	}
	if strings.TrimSpace(assigneeEmployeeID) != "" {
		if assignee, err = repository.StringToUUID(assigneeEmployeeID); err != nil {
			return nil, ErrInvalidEmployee
		}
	}
	rows, err := s.q.ListTeamTasks(ctx, sqlc.ListTeamTasksParams{
		OrganizationID: orgID, AssignedEmployeeID: assignee, StatusMode: mode, RestrictToUserID: restrict,
	})
	if err != nil {
		return nil, err
	}
	out := make([]MyTask, 0, len(rows))
	for _, r := range rows {
		task := repository.ToDomainTask(sqlc.ProjectTask{
			ID: r.ID, OrganizationID: r.OrganizationID, ProjectID: r.ProjectID, ScheduleItemID: r.ScheduleItemID,
			Title: r.Title, Description: r.Description, AssignedEmployeeID: r.AssignedEmployeeID,
			AssignedName: r.AssignedName, Priority: r.Priority, Status: r.Status, DueDate: r.DueDate,
			CompletedAt: r.CompletedAt, CreatedBy: r.CreatedBy, CreatedAt: r.CreatedAt, UpdatedAt: r.UpdatedAt,
		})
		out = append(out, MyTask{ProjectTask: task, ProjectName: r.ProjectName})
	}
	return out, nil
}

// IsEmployeeLinked: kullanıcının bir personel kaydına bağlı olup olmadığı
// ("Görevlerim" boşsa nedenini söylemek için).
func (s *ProjectService) IsEmployeeLinked(ctx context.Context, organizationID, userID string) (bool, error) {
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return false, domain.ErrNotFound
	}
	uid, err := repository.StringToUUID(userID)
	if err != nil {
		return false, domain.ErrNotFound
	}
	_, err = s.q.GetEmployeeByUserID(ctx, sqlc.GetEmployeeByUserIDParams{UserID: uid, OrganizationID: orgID})
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	return err == nil, err
}
