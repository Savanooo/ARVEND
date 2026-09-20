package service

import (
	"bytes"
	"context"
	"errors"
	"io"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/platform/storage"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

var (
	ErrDuplicateMember  = errors.New("bu personel zaten projenin aktif ekibinde")
	ErrInvalidEmployee  = errors.New("geçersiz personel")
	ErrInvalidSchedule  = errors.New("geçersiz planlama aşaması")
	ErrFileTooLarge     = errors.New("dosya boyutu sınırı aşıldı")
	ErrEmptyFile        = errors.New("boş dosya yüklenemez")
	ErrUnsupportedType  = errors.New("bu dosya türü kabul edilmiyor")
	ErrDuplicateContent = errors.New("bu dosya bu projeye zaten yüklenmiş")
	// ErrStorageFailure, depolama katmanından (dosya sistemi) gelen HAM
	// hatanın istemciye YANSITILMAMASI için kullanılan genel sentinel'dir.
	// Gerçek hata (ör. *fs.PathError -- sunucunun mutlak depolama yolunu
	// taşır) yalnızca sunucu logunda görünür (bkz. wrapStorageErr).
	ErrStorageFailure = errors.New("dosya işlemi sırasında bir hata oluştu")
)

// MaxUploadBytes, tek bir yükleme için üst sınırdır (25 MB).
const MaxUploadBytes = 25 << 20

// allowedFileTypes, belge yüklemede kabul edilen İÇERİK TÜRLERİdir.
// İstemcinin gönderdiği Content-Type'a GÜVENİLMEZ; tür dosyanın ilk
// baytlarından tespit edilir (bkz. sniffMIME).
var allowedFileTypes = map[string]bool{
	"application/pdf":    true,
	"image/jpeg":         true,
	"image/png":          true,
	"image/gif":          true,
	"image/webp":         true,
	"text/plain":         true,
	"application/zip":    true, // xlsx/docx de bu imzayla tespit edilir
	"text/csv":           true,
	"application/rtf":    true,
	"application/msword": true,
}

// sniffMIME, içeriğin ilk 512 baytından gerçek türü tespit eder ve
// okunan baytları geri "iade eden" yeni bir reader döner (akış
// kaybolmasın diye).
// wrapStorageErr, depolama katmanından gelen HAM hatayı (ör. *fs.PathError
// -- sunucunun mutlak dosya yolunu taşır) sunucu loguna yazar ve
// istemciye yalnızca genel bir sentinel döner. Handler bu sentinel'i
// 500'e eşler; ham metin ASLA HTTP yanıtına sızmaz.
func wrapStorageErr(err error) error {
	if err == nil {
		return nil
	}
	log.Printf("depolama hatası: %v", err)
	return ErrStorageFailure
}

// sniffMIME, ilk 512 bayttan MIME türünü tespit eder ve okuduğu bayt
// sayısını (n) döner -- çağıran, n == 0 ise gövdenin tamamen boş
// olduğunu anlar ve hiçbir şey depolamaya yazılmadan reddedebilir.
func sniffMIME(r io.Reader) (string, io.Reader, int, error) {
	head := make([]byte, 512)
	n, err := io.ReadFull(r, head)
	if err != nil && !errors.Is(err, io.EOF) && !errors.Is(err, io.ErrUnexpectedEOF) {
		return "", nil, 0, err
	}
	head = head[:n]
	mime := http.DetectContentType(head)
	// "text/plain; charset=utf-8" -> "text/plain"
	if i := strings.IndexByte(mime, ';'); i >= 0 {
		mime = strings.TrimSpace(mime[:i])
	}
	return mime, io.MultiReader(bytes.NewReader(head), r), n, nil
}

// ---------- Ekip ----------

type ProjectMemberInput struct {
	EmployeeID string
	RoleTitle  string
	StartDate  *time.Time
	Notes      string
	UserID     string
}

// AssignMember, mevcut bir personeli projeye atar. Personelin AYNI
// organizasyona ait olduğu doğrulanır (cross-tenant bağlama imkansız) ve
// adı atama anındaki haliyle snapshot'lanır.
func (s *ProjectService) AssignMember(ctx context.Context, projectID, organizationID string, in ProjectMemberInput) (*domain.ProjectMember, error) {
	pid, err := repository.StringToUUID(projectID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	eid, err := repository.StringToUUID(in.EmployeeID)
	if err != nil {
		return nil, ErrInvalidEmployee
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

	// Personel AYNI organizasyondan olmalı.
	emp, err := txq.GetEmployeeByID(ctx, sqlc.GetEmployeeByIDParams{ID: eid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrInvalidEmployee
		}
		return nil, err
	}

	row, err := txq.CreateProjectMember(ctx, sqlc.CreateProjectMemberParams{
		OrganizationID: orgID,
		ProjectID:      pid,
		EmployeeID:     eid,
		EmployeeName:   emp.FullName,
		RoleTitle:      strings.TrimSpace(in.RoleTitle),
		StartDate:      repository.TimePtrToDate(in.StartDate),
		Notes:          strings.TrimSpace(in.Notes),
		CreatedBy:      actorUUID(in.UserID),
	})
	if err != nil {
		// Kısmi UNIQUE indeks (aktif atama başına bir kayıt) ihlali.
		if isUniqueViolation(err) {
			return nil, ErrDuplicateMember
		}
		return nil, err
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventMemberAssigned, actorUUID(in.UserID),
		map[string]any{"member_id": row.ID.String(), "employee_name": emp.FullName, "role": in.RoleTitle}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainProjectMember(row)
	return &out, nil
}

func (s *ProjectService) ListMembers(ctx context.Context, projectID, organizationID string) ([]domain.ProjectMember, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	rows, err := s.q.ListProjectMembers(ctx, sqlc.ListProjectMembersParams{ProjectID: pid, OrganizationID: orgID})
	if err != nil {
		return nil, err
	}
	out := make([]domain.ProjectMember, len(rows))
	for i, r := range rows {
		out[i] = repository.ToDomainProjectMember(r)
	}
	return out, nil
}

// EndMembership, üyeyi ekipten çıkarır (kaydı silmez, bitiş tarihi yazar).
// projectID, URL'deki proje kimliğidir -- memberID'nin GERÇEKTEN bu
// projeye ait olduğunu sorgu seviyesinde doğrular (bkz. IDOR denetim
// bulgusu, project_operations.sql GetProjectMember notu).
func (s *ProjectService) EndMembership(ctx context.Context, projectID, memberID, organizationID, userID string, endDate *time.Time) (*domain.ProjectMember, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	mid, err := repository.StringToUUID(memberID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	end := time.Now()
	if endDate != nil {
		end = *endDate
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	row, err := txq.EndProjectMembership(ctx, sqlc.EndProjectMembershipParams{
		ID: mid, OrganizationID: orgID, EndDate: repository.TimeToDate(end), ProjectID: pid,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	if err := logProjectEvent(ctx, txq, orgID, row.ProjectID, domain.ProjectEventMemberRemoved, actorUUID(userID),
		map[string]any{"member_id": memberID, "employee_name": row.EmployeeName}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainProjectMember(row)
	return &out, nil
}

// scopedIDs, proje ve organizasyon kimliklerini ayrıştırır (okuma
// uçlarındaki tekrar eden üç satırı tek yerde toplar).
func (s *ProjectService) scopedIDs(projectID, organizationID string) (pgtype.UUID, pgtype.UUID, error) {
	pid, err := repository.StringToUUID(projectID)
	if err != nil {
		return pgtype.UUID{}, pgtype.UUID{}, domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return pgtype.UUID{}, pgtype.UUID{}, domain.ErrNotFound
	}
	return pid, orgID, nil
}

// ---------- Planlama ----------

type ScheduleItemInput struct {
	Name        string
	Description string
	StartDate   *time.Time
	EndDate     *time.Time
	Status      string
	SortOrder   int
	UserID      string
}

func (s *ProjectService) CreateScheduleItem(ctx context.Context, projectID, organizationID string, in ScheduleItemInput) (*domain.ScheduleItem, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	name := strings.TrimSpace(in.Name)
	if name == "" {
		return nil, errors.New("aşama adı zorunludur")
	}
	status := in.Status
	if status == "" {
		status = domain.ScheduleStatusPlanned
	}
	if !domain.ValidScheduleStatus(status) {
		return nil, errors.New("geçersiz aşama durumu")
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

	row, err := txq.CreateScheduleItem(ctx, sqlc.CreateScheduleItemParams{
		OrganizationID: orgID,
		ProjectID:      pid,
		Name:           name,
		Description:    strings.TrimSpace(in.Description),
		StartDate:      repository.TimePtrToDate(in.StartDate),
		EndDate:        repository.TimePtrToDate(in.EndDate),
		Status:         status,
		SortOrder:      int32(in.SortOrder),
		CreatedBy:      actorUUID(in.UserID),
	})
	if err != nil {
		return nil, err
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventScheduleCreated, actorUUID(in.UserID),
		map[string]any{"schedule_item_id": row.ID.String(), "name": name}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainScheduleItemRow(row)
	return &out, nil
}

func (s *ProjectService) ListScheduleItems(ctx context.Context, projectID, organizationID string) ([]domain.ScheduleItem, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	rows, err := s.q.ListScheduleItems(ctx, sqlc.ListScheduleItemsParams{ProjectID: pid, OrganizationID: orgID})
	if err != nil {
		return nil, err
	}
	out := make([]domain.ScheduleItem, len(rows))
	for i, r := range rows {
		out[i] = repository.ToDomainScheduleItem(r)
	}
	return out, nil
}

// projectID, URL'deki proje kimliğidir -- itemID'nin GERÇEKTEN bu projeye
// ait olduğunu sorgu seviyesinde doğrular (bkz. IDOR denetim bulgusu).
func (s *ProjectService) UpdateScheduleItem(ctx context.Context, projectID, itemID, organizationID string, in ScheduleItemInput) (*domain.ScheduleItem, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	iid, err := repository.StringToUUID(itemID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	name := strings.TrimSpace(in.Name)
	if name == "" {
		return nil, errors.New("aşama adı zorunludur")
	}
	if !domain.ValidScheduleStatus(in.Status) {
		return nil, errors.New("geçersiz aşama durumu")
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	current, err := txq.GetScheduleItem(ctx, sqlc.GetScheduleItemParams{ID: iid, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}

	row, err := txq.UpdateScheduleItem(ctx, sqlc.UpdateScheduleItemParams{
		ID:             iid,
		OrganizationID: orgID,
		Name:           name,
		Description:    strings.TrimSpace(in.Description),
		StartDate:      repository.TimePtrToDate(in.StartDate),
		EndDate:        repository.TimePtrToDate(in.EndDate),
		Status:         in.Status,
		SortOrder:      int32(in.SortOrder),
		ProjectID:      pid,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}

	eventType := domain.ProjectEventScheduleUpdated
	if in.Status == domain.ScheduleStatusCompleted && current.Status != domain.ScheduleStatusCompleted {
		eventType = domain.ProjectEventScheduleCompleted
	}
	if err := logProjectEvent(ctx, txq, orgID, row.ProjectID, eventType, actorUUID(in.UserID),
		map[string]any{"schedule_item_id": itemID, "name": name, "status": in.Status}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainScheduleItemRow(row)
	return &out, nil
}

// ---------- Görevler ----------

type TaskInput struct {
	Title              string
	Description        string
	ScheduleItemID     *string
	AssignedEmployeeID *string
	Priority           string
	Status             string
	DueDate            *time.Time
	UserID             string
}

// resolveTaskRelations, göreve bağlanan aşama ve personelin AYNI
// organizasyona ve AYNI projeye ait olduğunu doğrular -- başka bir
// firmanın/projenin kaydına görev bağlanamaz.
// employeeUserID (5. dönüş değeri): atanan personelin BAĞLI kullanıcı
// hesabı (employees.user_id, nullable -- bkz. migration 0041). "Görev
// atandı" bildirimi bunu kullanır; personelin bağlı hesabı yoksa
// pgtype.UUID{Valid:false} döner ve çağıran bunu SESSİZCE atlamalıdır
// (createNotification zaten bu şekilde davranır).
func (s *ProjectService) resolveTaskRelations(ctx context.Context, txq *sqlc.Queries, pid, orgID pgtype.UUID, in TaskInput) (pgtype.UUID, pgtype.UUID, string, pgtype.UUID, error) {
	var scheduleID, employeeID, employeeUserID pgtype.UUID
	var employeeName string

	if in.ScheduleItemID != nil && *in.ScheduleItemID != "" {
		sid, err := repository.StringToUUID(*in.ScheduleItemID)
		if err != nil {
			return scheduleID, employeeID, "", employeeUserID, ErrInvalidSchedule
		}
		if _, err := txq.GetScheduleItem(ctx, sqlc.GetScheduleItemParams{ID: sid, OrganizationID: orgID, ProjectID: pid}); err != nil {
			return scheduleID, employeeID, "", employeeUserID, ErrInvalidSchedule
		}
		scheduleID = sid
	}

	if in.AssignedEmployeeID != nil && *in.AssignedEmployeeID != "" {
		eid, err := repository.StringToUUID(*in.AssignedEmployeeID)
		if err != nil {
			return scheduleID, employeeID, "", employeeUserID, ErrInvalidEmployee
		}
		emp, err := txq.GetEmployeeByID(ctx, sqlc.GetEmployeeByIDParams{ID: eid, OrganizationID: orgID})
		if err != nil {
			return scheduleID, employeeID, "", employeeUserID, ErrInvalidEmployee
		}
		employeeID = eid
		employeeName = emp.FullName
		employeeUserID = emp.UserID
	}
	return scheduleID, employeeID, employeeName, employeeUserID, nil
}

func (s *ProjectService) CreateTask(ctx context.Context, projectID, organizationID string, in TaskInput) (*domain.ProjectTask, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	title := strings.TrimSpace(in.Title)
	if title == "" {
		return nil, errors.New("görev başlığı zorunludur")
	}
	priority := in.Priority
	if priority == "" {
		priority = domain.TaskPriorityNormal
	}
	if !domain.ValidTaskPriority(priority) {
		return nil, errors.New("geçersiz öncelik")
	}
	status := in.Status
	if status == "" {
		status = domain.TaskStatusTodo
	}
	if !domain.ValidTaskStatus(status) {
		return nil, errors.New("geçersiz görev durumu")
	}
	// Yeni görev doğrudan "tamamlandı" olarak açılamaz: completed_at ile
	// durum arasındaki tutarlılık tek bir yerden (CompleteTask) yönetilir.
	if status == domain.TaskStatusCompleted {
		return nil, errors.New("görev doğrudan tamamlanmış olarak oluşturulamaz")
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
	scheduleID, employeeID, employeeName, employeeUserID, err := s.resolveTaskRelations(ctx, txq, pid, orgID, in)
	if err != nil {
		return nil, err
	}

	row, err := txq.CreateTask(ctx, sqlc.CreateTaskParams{
		OrganizationID:     orgID,
		ProjectID:          pid,
		ScheduleItemID:     scheduleID,
		Title:              title,
		Description:        strings.TrimSpace(in.Description),
		AssignedEmployeeID: employeeID,
		AssignedName:       employeeName,
		Priority:           priority,
		Status:             status,
		DueDate:            repository.TimePtrToDate(in.DueDate),
		CreatedBy:          actorUUID(in.UserID),
	})
	if err != nil {
		return nil, err
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventTaskCreated, actorUUID(in.UserID),
		map[string]any{"task_id": row.ID.String(), "title": title}); err != nil {
		return nil, err
	}
	if employeeID.Valid {
		if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventTaskAssigned, actorUUID(in.UserID),
			map[string]any{"task_id": row.ID.String(), "title": title, "employee_name": employeeName}); err != nil {
			return nil, err
		}
		if err := createNotification(ctx, txq, CreateNotificationInput{
			OrganizationID: orgID, UserID: employeeUserID, Type: domain.NotificationTaskAssigned,
			Title: "Yeni görev atandı", Body: title,
			EntityType: domain.NotificationEntityTask, EntityID: row.ID, ProjectID: pid,
			ActionTarget: "/projeler/" + pid.String() + "/gorevler/" + row.ID.String(),
		}); err != nil {
			return nil, err
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainTask(row)
	return &out, nil
}

func (s *ProjectService) ListTasks(ctx context.Context, projectID, organizationID string) ([]domain.ProjectTask, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	rows, err := s.q.ListTasks(ctx, sqlc.ListTasksParams{ProjectID: pid, OrganizationID: orgID})
	if err != nil {
		return nil, err
	}
	out := make([]domain.ProjectTask, len(rows))
	for i, r := range rows {
		out[i] = repository.ToDomainTask(r)
	}
	return out, nil
}

// MyTask, global Gorevler listesi icin proje adini da tasiyan gorevdir.
type MyTask struct {
	domain.ProjectTask
	ProjectName string
}

// ListMyTasks, GERÇEK "bana ATANAN görevler"i TEK sorguda döner (bkz.
// migration 0041 + queries/project_operations.sql'deki ListMyTasks
// yorumu -- BUNDAN ÖNCE bu fonksiyon yanlışlıkla "erişebildiğim
// projelerdeki TÜM görevler"i dönüyordu, assigned_employee_id'ye HİÇ
// bakmadan).
//
// callerUserID: giriş yapmış kullanıcının KENDİSİ (İSTEMCİDEN GELMEZ,
// middleware.UserIDFromContext'ten) -- bağlı personel kaydını bulmak için
// KULLANILIR, rolden BAĞIMSIZ (owner/admin/legacy DAHİL -- spec: "/mine
// hâlâ BENİM görevlerim demek, owner/admin /mine üzerinden HERKESİN
// görevini görmemeli").
//
// statusMode: "open" (todo+in_progress, varsayilan), "all", veya somut bir status.
//
// restrictToUserID, ListProjects ile AYNI, AYRI bir kural -- yalnızca
// PROJE ERİŞİMİ sınırı (owner/admin/legacy icin bos = tüm projelere
// erişebilir; üyelik-kısıtlı roller için cagiranin user id'si) --
// assigned_employee_id filtresinden BAĞIMSIZDIR, callerUserID İLE
// KARIŞTIRILMAMALI (ikisi aynı kişiyi temsil eder ama FARKLI amaçlar
// için: biri "hangi projeleri görebilirim", diğeri "bana ne atanmış").
func (s *ProjectService) ListMyTasks(ctx context.Context, organizationID, statusMode, callerUserID, restrictToUserID string) ([]MyTask, error) {
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	callerUID, err := repository.StringToUUID(callerUserID)
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
	var restrict pgtype.UUID
	if restrictToUserID != "" {
		uid, err := repository.StringToUUID(restrictToUserID)
		if err != nil {
			return nil, domain.ErrNotFound
		}
		restrict = uid
	}

	// Bağlı personel yoksa (link KURULMAMIŞ), sorguyu HİÇ ÇALIŞTIRMADAN
	// boş liste dön -- ASLA "erişilebilir projelerin tüm görevleri"ne
	// GERİ DÜŞME (spec'in en kritik kuralı).
	linkedEmployee, err := s.q.GetEmployeeByUserID(ctx, sqlc.GetEmployeeByUserIDParams{UserID: callerUID, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return []MyTask{}, nil
		}
		return nil, err
	}

	rows, err := s.q.ListMyTasks(ctx, sqlc.ListMyTasksParams{
		OrganizationID:     orgID,
		AssignedEmployeeID: linkedEmployee.ID,
		StatusMode:         mode,
		RestrictToUserID:   restrict,
	})
	if err != nil {
		return nil, err
	}
	out := make([]MyTask, 0, len(rows))
	for _, r := range rows {
		task := repository.ToDomainTask(sqlc.ProjectTask{
			ID:                 r.ID,
			OrganizationID:     r.OrganizationID,
			ProjectID:          r.ProjectID,
			ScheduleItemID:     r.ScheduleItemID,
			Title:              r.Title,
			Description:        r.Description,
			AssignedEmployeeID: r.AssignedEmployeeID,
			AssignedName:       r.AssignedName,
			Priority:           r.Priority,
			Status:             r.Status,
			DueDate:            r.DueDate,
			CompletedAt:        r.CompletedAt,
			CreatedBy:          r.CreatedBy,
			CreatedAt:          r.CreatedAt,
			UpdatedAt:          r.UpdatedAt,
		})
		out = append(out, MyTask{ProjectTask: task, ProjectName: r.ProjectName})
	}
	return out, nil
}

// projectID, URL'deki proje kimligidir -- taskID'nin GERCEKTEN bu projeye
// ait oldugunu sorgu seviyesinde dogrular (bkz. IDOR denetim bulgusu).
func (s *ProjectService) UpdateTask(ctx context.Context, projectID, taskID, organizationID string, in TaskInput) (*domain.ProjectTask, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	tid, err := repository.StringToUUID(taskID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	title := strings.TrimSpace(in.Title)
	if title == "" {
		return nil, errors.New("görev başlığı zorunludur")
	}
	if !domain.ValidTaskPriority(in.Priority) {
		return nil, errors.New("geçersiz öncelik")
	}
	if !domain.ValidTaskStatus(in.Status) {
		return nil, errors.New("geçersiz görev durumu")
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	// KİLİT ALTINDA okunur: aksi halde iki eşzamanlı "durumu completed
	// yap" isteği ikisi de aynı eski (completed öncesi) satırı görüp İKİ
	// kez task_completed olayı yazabilirdi (bkz. denetim bulgusu).
	current, err := txq.GetTaskForUpdate(ctx, sqlc.GetTaskForUpdateParams{ID: tid, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	scheduleID, employeeID, employeeName, employeeUserID, err := s.resolveTaskRelations(ctx, txq, current.ProjectID, orgID, in)
	if err != nil {
		return nil, err
	}

	row, err := txq.UpdateTask(ctx, sqlc.UpdateTaskParams{
		ID:                 tid,
		OrganizationID:     orgID,
		Title:              title,
		Description:        strings.TrimSpace(in.Description),
		ScheduleItemID:     scheduleID,
		AssignedEmployeeID: employeeID,
		AssignedName:       employeeName,
		Priority:           in.Priority,
		Status:             in.Status,
		DueDate:            repository.TimePtrToDate(in.DueDate),
		ProjectID:          pid,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}

	actor := actorUUID(in.UserID)
	switch {
	case in.Status == domain.TaskStatusCompleted && current.Status != domain.TaskStatusCompleted:
		err = logProjectEvent(ctx, txq, orgID, current.ProjectID, domain.ProjectEventTaskCompleted, actor,
			map[string]any{"task_id": taskID, "title": title})
	case employeeID.Valid && employeeID.String() != current.AssignedEmployeeID.String():
		err = logProjectEvent(ctx, txq, orgID, current.ProjectID, domain.ProjectEventTaskAssigned, actor,
			map[string]any{"task_id": taskID, "title": title, "employee_name": employeeName})
		if err == nil {
			err = createNotification(ctx, txq, CreateNotificationInput{
				OrganizationID: orgID, UserID: employeeUserID, Type: domain.NotificationTaskAssigned,
				Title: "Yeni görev atandı", Body: title,
				EntityType: domain.NotificationEntityTask, EntityID: tid, ProjectID: current.ProjectID,
				ActionTarget: "/projeler/" + current.ProjectID.String() + "/gorevler/" + taskID,
			})
		}
	default:
		err = logProjectEvent(ctx, txq, orgID, current.ProjectID, domain.ProjectEventTaskUpdated, actor,
			map[string]any{"task_id": taskID, "title": title, "status": in.Status})
	}
	if err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainTask(row)
	return &out, nil
}

// CompleteTask, görevi tamamlar. Eşzamanlı iki "tamamla" isteğinde
// yalnızca biri satır döndürür (SQL'deki status <> 'completed' koşulu);
// diğeri mevcut kaydı döner, ikinci bir completed olayı YAZILMAZ.
// projectID, URL'deki proje kimliğidir -- taskID'nin GERÇEKTEN bu projeye
// ait olduğunu sorgu seviyesinde doğrular (bkz. IDOR denetim bulgusu).
func (s *ProjectService) CompleteTask(ctx context.Context, projectID, taskID, organizationID, userID string) (*domain.ProjectTask, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	tid, err := repository.StringToUUID(taskID)
	if err != nil {
		return nil, domain.ErrNotFound
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	row, err := txq.CompleteTask(ctx, sqlc.CompleteTaskParams{ID: tid, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			// Ya yok/başka firmaya ait/başka projeye ait ya da zaten
			// tamamlanmış: ikinci durumda mevcut kaydı döndürüp idempotent
			// davranıyoruz. AYNI transaction/bağlantı (txq) üzerinden
			// okunur -- s.q (havuz) kullanmak her tekrarlı "tamamla"
			// isteğinde FAZLADAN bir havuz bağlantısı tüketip yüksek
			// eşzamanlılıkta havuzu tüketebilirdi (bkz. denetim bulgusu).
			// Buradaki CompleteTask'ın kendisi bir hata DÖNDÜRMEDİĞİ
			// (yalnızca 0 satır etkilediği) için transaction "aborted"
			// durumda DEĞİLDİR; aynı tx üzerinden okumak güvenlidir.
			existing, gerr := txq.GetTask(ctx, sqlc.GetTaskParams{ID: tid, OrganizationID: orgID, ProjectID: pid})
			if gerr != nil {
				return nil, domain.ErrNotFound
			}
			out := repository.ToDomainTask(existing)
			return &out, nil
		}
		return nil, err
	}
	if err := logProjectEvent(ctx, txq, orgID, row.ProjectID, domain.ProjectEventTaskCompleted, actorUUID(userID),
		map[string]any{"task_id": taskID, "title": row.Title}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainTask(row)
	return &out, nil
}

// ---------- Dosyalar ve Fotoğraflar ----------

type UploadInput struct {
	OriginalName string
	Reader       io.Reader
	Category     string // dosya
	Stage        string // fotoğraf
	Description  string
	TakenAt      *time.Time
	UserID       string
}

// storeUpload, ortak yükleme adımlarını yürütür: boyut sınırı, içerikten
// MIME tespiti, sunucu tarafında üretilen nesne anahtarı ve depolama.
// Kullanıcının gönderdiği ad YALNIZCA görüntüleme için saklanır; anahtara
// yalnızca doğrulanmış uzantı girer.
func (s *ProjectService) storeUpload(ctx context.Context, kind, orgID, projectID, originalName string, r io.Reader, imagesOnly bool) (storage.Object, string, error) {
	mime, body, n, err := sniffMIME(io.LimitReader(r, MaxUploadBytes+1))
	if err != nil {
		return storage.Object{}, "", err
	}
	// Boş gövde HİÇBİR ŞEY diske yazılmadan reddedilir: aksi halde
	// project_files.size_bytes > 0 CHECK kısıtı ihlal edilip 500 üretirdi
	// (bkz. denetim bulgusu) -- bu doğrulama hatası olduğu için 400
	// olarak dönmelidir.
	if n == 0 {
		return storage.Object{}, "", ErrEmptyFile
	}
	if imagesOnly {
		if !strings.HasPrefix(mime, "image/") {
			return storage.Object{}, "", ErrUnsupportedType
		}
	} else if !allowedFileTypes[mime] && !strings.HasPrefix(mime, "image/") {
		return storage.Object{}, "", ErrUnsupportedType
	}

	objectID := uuid.NewString()
	key := storage.BuildKey(kind, orgID, projectID, objectID, originalName)

	obj, err := s.store.Put(ctx, key, body)
	if err != nil {
		return storage.Object{}, "", wrapStorageErr(err)
	}
	if obj.Size > MaxUploadBytes {
		_ = s.store.Delete(ctx, key)
		return storage.Object{}, "", ErrFileTooLarge
	}
	obj.MIMEType = mime
	return obj, key, nil
}

func (s *ProjectService) UploadFile(ctx context.Context, projectID, organizationID string, in UploadInput) (*domain.ProjectFile, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	category := in.Category
	if category == "" {
		category = domain.FileCategoryOther
	}
	if !domain.ValidFileCategory(category) {
		return nil, errors.New("geçersiz dosya kategorisi")
	}
	name := strings.TrimSpace(in.OriginalName)
	if name == "" {
		name = "dosya"
	}
	if len([]rune(name)) > 255 {
		name = string([]rune(name)[:255])
	}

	// Proje sahipliği ve durumu, HERHANGİ bir bayt diske yazılmadan önce
	// doğrulanır. Kayıt ve olay yazımı TEK transaction içinde yapılır --
	// aksi halde (eskiden olduğu gibi) satır oluşup olay yazılamazsa
	// veya tam tersi olursa denetim izi kaydı tutarsız kalabilirdi.
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	if _, err := s.requireOpenProject(ctx, txq, pid, orgID); err != nil {
		return nil, err
	}

	obj, key, err := s.storeUpload(ctx, "files", orgID.String(), pid.String(), name, in.Reader, false)
	if err != nil {
		return nil, err
	}

	row, err := txq.CreateProjectFile(ctx, sqlc.CreateProjectFileParams{
		OrganizationID: orgID,
		ProjectID:      pid,
		OriginalName:   name,
		ObjectKey:      key,
		MimeType:       obj.MIMEType,
		SizeBytes:      obj.Size,
		Sha256:         obj.SHA256,
		Category:       category,
		Description:    strings.TrimSpace(in.Description),
		UploadedBy:     actorUUID(in.UserID),
	})
	if err != nil {
		// Aynı içerik zaten yüklenmiş: yeni nesneyi sil, mevcut kaydı dön.
		// DİKKAT: bir INSERT hatası transaction'ı "aborted" duruma
		// düşürür -- kurtarma sorgusu aynı tx (txq) ÜZERİNDEN DEĞİL,
		// havuzdan (s.q) çalıştırılmalıdır (bkz. CreateCollection'daki
		// aynı desen).
		if isUniqueViolation(err) {
			_ = s.store.Delete(ctx, key)
			if existing, gerr := s.q.GetProjectFileBySHA(ctx, sqlc.GetProjectFileBySHAParams{
				ProjectID: pid, Sha256: obj.SHA256,
			}); gerr == nil {
				out := repository.ToDomainProjectFile(existing)
				return &out, nil
			}
		}
		_ = s.store.Delete(ctx, key)
		return nil, err
	}

	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventFileUploaded, actorUUID(in.UserID),
		map[string]any{"file_id": row.ID.String(), "name": name, "category": category}); err != nil {
		_ = s.store.Delete(ctx, key)
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		_ = s.store.Delete(ctx, key)
		return nil, err
	}
	out := repository.ToDomainProjectFile(row)
	return &out, nil
}

func (s *ProjectService) ListFiles(ctx context.Context, projectID, organizationID string) ([]domain.ProjectFile, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	rows, err := s.q.ListProjectFiles(ctx, sqlc.ListProjectFilesParams{ProjectID: pid, OrganizationID: orgID})
	if err != nil {
		return nil, err
	}
	out := make([]domain.ProjectFile, len(rows))
	for i, r := range rows {
		out[i] = repository.ToDomainProjectFile(r)
	}
	return out, nil
}

// OpenFile, indirme için dosyayı açar. Kayıt YALNIZCA organization_id VE
// project_id eşleşirse bulunur; başka bir firmanın ya da AYNI
// organizasyondaki başka bir projenin dosya UUID'si bilinse bile buradan
// tek bayt okunamaz (bkz. IDOR denetim bulgusu).
func (s *ProjectService) OpenFile(ctx context.Context, projectID, fileID, organizationID string) (*domain.ProjectFile, io.ReadCloser, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, nil, err
	}
	fid, err := repository.StringToUUID(fileID)
	if err != nil {
		return nil, nil, domain.ErrNotFound
	}
	row, err := s.q.GetProjectFile(ctx, sqlc.GetProjectFileParams{ID: fid, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, nil, domain.ErrNotFound
		}
		return nil, nil, err
	}
	rc, err := s.store.Open(ctx, row.ObjectKey)
	if err != nil {
		return nil, nil, wrapStorageErr(err)
	}
	out := repository.ToDomainProjectFile(row)
	return &out, rc, nil
}

func (s *ProjectService) DeleteFile(ctx context.Context, projectID, fileID, organizationID, userID string) error {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return err
	}
	fid, err := repository.StringToUUID(fileID)
	if err != nil {
		return domain.ErrNotFound
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	row, err := txq.SoftDeleteProjectFile(ctx, sqlc.SoftDeleteProjectFileParams{
		ID: fid, OrganizationID: orgID, DeletedBy: actorUUID(userID), ProjectID: pid,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return domain.ErrNotFound
		}
		return err
	}
	if err := logProjectEvent(ctx, txq, orgID, row.ProjectID, domain.ProjectEventFileRemoved, actorUUID(userID),
		map[string]any{"file_id": fileID, "name": row.OriginalName}); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func (s *ProjectService) UploadPhoto(ctx context.Context, projectID, organizationID string, in UploadInput) (*domain.ProjectPhoto, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	stage := in.Stage
	if stage == "" {
		stage = domain.PhotoStageProgress
	}
	if !domain.ValidPhotoStage(stage) {
		return nil, errors.New("geçersiz fotoğraf aşaması")
	}
	name := strings.TrimSpace(in.OriginalName)
	if name == "" {
		name = "foto"
	}
	if len([]rune(name)) > 255 {
		name = string([]rune(name)[:255])
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

	// imagesOnly=true: içerikten tespit edilen tür image/* değilse reddedilir.
	obj, key, err := s.storeUpload(ctx, "photos", orgID.String(), pid.String(), name, in.Reader, true)
	if err != nil {
		return nil, err
	}

	row, err := txq.CreateProjectPhoto(ctx, sqlc.CreateProjectPhotoParams{
		OrganizationID: orgID,
		ProjectID:      pid,
		OriginalName:   name,
		ObjectKey:      key,
		MimeType:       obj.MIMEType,
		SizeBytes:      obj.Size,
		Sha256:         obj.SHA256,
		Stage:          stage,
		Description:    strings.TrimSpace(in.Description),
		TakenAt:        repository.TimePtrToTimestamptz(in.TakenAt),
		UploadedBy:     actorUUID(in.UserID),
	})
	if err != nil {
		// bkz. UploadFile: kurtarma sorgusu havuzdan (s.q) çalışır --
		// bu noktada txq'nun transaction'ı "aborted" durumdadır.
		if isUniqueViolation(err) {
			_ = s.store.Delete(ctx, key)
			if existing, gerr := s.q.GetProjectPhotoBySHA(ctx, sqlc.GetProjectPhotoBySHAParams{
				ProjectID: pid, Sha256: obj.SHA256,
			}); gerr == nil {
				out := repository.ToDomainProjectPhoto(existing)
				return &out, nil
			}
		}
		_ = s.store.Delete(ctx, key)
		return nil, err
	}

	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventPhotoUploaded, actorUUID(in.UserID),
		map[string]any{"photo_id": row.ID.String(), "stage": stage}); err != nil {
		_ = s.store.Delete(ctx, key)
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		_ = s.store.Delete(ctx, key)
		return nil, err
	}
	out := repository.ToDomainProjectPhoto(row)
	return &out, nil
}

func (s *ProjectService) ListPhotos(ctx context.Context, projectID, organizationID string) ([]domain.ProjectPhoto, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	rows, err := s.q.ListProjectPhotos(ctx, sqlc.ListProjectPhotosParams{ProjectID: pid, OrganizationID: orgID})
	if err != nil {
		return nil, err
	}
	out := make([]domain.ProjectPhoto, len(rows))
	for i, r := range rows {
		out[i] = repository.ToDomainProjectPhoto(r)
	}
	return out, nil
}

// projectID, URL'deki proje kimliğidir -- photoID'nin GERÇEKTEN bu
// projeye ait olduğunu sorgu seviyesinde doğrular (bkz. OpenFile notu).
func (s *ProjectService) OpenPhoto(ctx context.Context, projectID, photoID, organizationID string) (*domain.ProjectPhoto, io.ReadCloser, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, nil, err
	}
	phid, err := repository.StringToUUID(photoID)
	if err != nil {
		return nil, nil, domain.ErrNotFound
	}
	row, err := s.q.GetProjectPhoto(ctx, sqlc.GetProjectPhotoParams{ID: phid, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, nil, domain.ErrNotFound
		}
		return nil, nil, err
	}
	rc, err := s.store.Open(ctx, row.ObjectKey)
	if err != nil {
		return nil, nil, wrapStorageErr(err)
	}
	out := repository.ToDomainProjectPhoto(row)
	return &out, rc, nil
}

func (s *ProjectService) DeletePhoto(ctx context.Context, projectID, photoID, organizationID, userID string) error {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return err
	}
	phid, err := repository.StringToUUID(photoID)
	if err != nil {
		return domain.ErrNotFound
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	row, err := txq.SoftDeleteProjectPhoto(ctx, sqlc.SoftDeleteProjectPhotoParams{
		ID: phid, OrganizationID: orgID, DeletedBy: actorUUID(userID), ProjectID: pid,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return domain.ErrNotFound
		}
		return err
	}
	if err := logProjectEvent(ctx, txq, orgID, row.ProjectID, domain.ProjectEventPhotoRemoved, actorUUID(userID),
		map[string]any{"photo_id": photoID}); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// ---------- Notlar ----------

// CreateNote, notu yazan kullanıcının adını kayıt anında snapshot'lar --
// kullanıcı sonradan yeniden adlandırılsa bile notun "kim yazdı" bilgisi
// değişmez.
func (s *ProjectService) CreateNote(ctx context.Context, projectID, organizationID, content, userID string) (*domain.ProjectNote, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	content = strings.TrimSpace(content)
	if content == "" {
		return nil, errors.New("not içeriği boş olamaz")
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	if _, err := txq.GetProjectByID(ctx, sqlc.GetProjectByIDParams{ID: pid, OrganizationID: orgID}); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}

	userName := ""
	if uid, uerr := repository.StringToUUID(userID); uerr == nil {
		// Org-scope'lu varyant: başka bir firmanın kullanıcı adı buraya
		// hiçbir koşulda yazılamaz.
		if u, uerr := txq.GetUserByIDInOrg(ctx, sqlc.GetUserByIDInOrgParams{ID: uid, OrganizationID: orgID}); uerr == nil {
			userName = u.FullName
		}
	}

	row, err := txq.CreateProjectNote(ctx, sqlc.CreateProjectNoteParams{
		OrganizationID: orgID,
		ProjectID:      pid,
		Content:        content,
		CreatedBy:      actorUUID(userID),
		CreatedByName:  userName,
	})
	if err != nil {
		return nil, err
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventNoteAdded, actorUUID(userID),
		map[string]any{"note_id": row.ID.String()}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainProjectNote(row)
	return &out, nil
}

func (s *ProjectService) ListNotes(ctx context.Context, projectID, organizationID string) ([]domain.ProjectNote, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	rows, err := s.q.ListProjectNotes(ctx, sqlc.ListProjectNotesParams{ProjectID: pid, OrganizationID: orgID})
	if err != nil {
		return nil, err
	}
	out := make([]domain.ProjectNote, len(rows))
	for i, r := range rows {
		out[i] = repository.ToDomainProjectNote(r)
	}
	return out, nil
}

// ---------- Operasyon Özeti ----------

func (s *ProjectService) OperationsSummary(ctx context.Context, projectID, organizationID string) (*domain.ProjectOperationsSummary, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	stats, err := s.q.CountProjectTaskStats(ctx, sqlc.CountProjectTaskStatsParams{ProjectID: pid, OrganizationID: orgID})
	if err != nil {
		return nil, err
	}
	members, err := s.q.CountActiveMembers(ctx, sqlc.CountActiveMembersParams{ProjectID: pid, OrganizationID: orgID})
	if err != nil {
		return nil, err
	}
	ratio := 0.0
	if stats.Total > 0 {
		ratio = float64(stats.CompletedCount) / float64(stats.Total) * 100
	}
	return &domain.ProjectOperationsSummary{
		ActiveMemberCount:   members,
		TotalTaskCount:      stats.Total,
		OpenTaskCount:       stats.OpenCount,
		OverdueTaskCount:    stats.OverdueCount,
		CompletedTaskCount:  stats.CompletedCount,
		TaskCompletionRatio: ratio,
	}, nil
}
