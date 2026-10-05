package domain

import "time"

const (
	ScheduleStatusPlanned   = "planned"
	ScheduleStatusActive    = "active"
	ScheduleStatusCompleted = "completed"
	ScheduleStatusCancelled = "cancelled"
)

var validScheduleStatuses = map[string]bool{
	ScheduleStatusPlanned: true, ScheduleStatusActive: true,
	ScheduleStatusCompleted: true, ScheduleStatusCancelled: true,
}

func ValidScheduleStatus(s string) bool { return validScheduleStatuses[s] }

const (
	TaskStatusTodo       = "todo"
	TaskStatusInProgress = "in_progress"
	TaskStatusCompleted  = "completed"
	TaskStatusCancelled  = "cancelled"
)

var validTaskStatuses = map[string]bool{
	TaskStatusTodo: true, TaskStatusInProgress: true,
	TaskStatusCompleted: true, TaskStatusCancelled: true,
}

func ValidTaskStatus(s string) bool { return validTaskStatuses[s] }

const (
	TaskPriorityLow    = "low"
	TaskPriorityNormal = "normal"
	TaskPriorityHigh   = "high"
	TaskPriorityUrgent = "urgent"
)

var validTaskPriorities = map[string]bool{
	TaskPriorityLow: true, TaskPriorityNormal: true,
	TaskPriorityHigh: true, TaskPriorityUrgent: true,
}

func ValidTaskPriority(s string) bool { return validTaskPriorities[s] }

const (
	FileCategoryContract = "contract"
	FileCategoryDrawing  = "drawing"
	FileCategoryInvoice  = "invoice"
	FileCategoryReport   = "report"
	FileCategoryOther    = "other"
)

var validFileCategories = map[string]bool{
	FileCategoryContract: true, FileCategoryDrawing: true, FileCategoryInvoice: true,
	FileCategoryReport: true, FileCategoryOther: true,
}

func ValidFileCategory(s string) bool { return validFileCategories[s] }

const (
	PhotoStageBefore   = "before"
	PhotoStageProgress = "progress"
	PhotoStageAfter    = "after"
)

var validPhotoStages = map[string]bool{
	PhotoStageBefore: true, PhotoStageProgress: true, PhotoStageAfter: true,
}

func ValidPhotoStage(s string) bool { return validPhotoStages[s] }

// Faz 7 operasyon olay tipleri (project_events'e yazılır; Faz 6'nın
// finans olaylarıyla AYNI tabloda, tek kronolojik zaman çizelgesi için).
const (
	ProjectEventMemberAssigned    = "member_assigned"
	ProjectEventMemberRemoved     = "member_removed"
	ProjectEventScheduleCreated   = "schedule_created"
	ProjectEventScheduleUpdated   = "schedule_updated"
	ProjectEventScheduleCompleted = "schedule_completed"
	ProjectEventTaskCreated       = "task_created"
	ProjectEventTaskAssigned      = "task_assigned"
	ProjectEventTaskCompleted     = "task_completed"
	ProjectEventTaskUpdated       = "task_updated"
	ProjectEventFileUploaded      = "file_uploaded"
	ProjectEventFileRemoved       = "file_removed"
	ProjectEventPhotoUploaded     = "photo_uploaded"
	ProjectEventPhotoRemoved      = "photo_removed"
	ProjectEventNoteAdded         = "note_added"
)

// ProjectMember, bir personelin projeye atanmasıdır. EmployeeName atama
// anındaki anlık görüntüdür: personel kartı sonradan değişse bile geçmiş
// ekip kaydı ne yazdığını korur.
type ProjectMember struct {
	ID             string
	OrganizationID string
	ProjectID      string
	EmployeeID     string
	EmployeeName   string
	RoleTitle      string
	StartDate      *time.Time
	EndDate        *time.Time
	Notes          string
	CreatedAt      time.Time
}

// IsActive, üyenin hâlâ ekipte olup olmadığını söyler.
func (m ProjectMember) IsActive() bool { return m.EndDate == nil }

type ScheduleItem struct {
	ID                 string
	OrganizationID     string
	ProjectID          string
	Name               string
	Description        string
	StartDate          *time.Time
	EndDate            *time.Time
	Status             string
	SortOrder          int
	CreatedAt          time.Time
	TaskCount          int64
	CompletedTaskCount int64
	// Sorumlu personel (migration 0052); ad atandığı anki kopyadır.
	AssignedEmployeeID *string
	AssignedName       string
}

type ProjectTask struct {
	ID                 string
	OrganizationID     string
	ProjectID          string
	ScheduleItemID     *string
	Title              string
	Description        string
	AssignedEmployeeID *string
	AssignedName       string
	Priority           string
	Status             string
	DueDate            *time.Time
	CompletedAt        *time.Time
	CreatedAt          time.Time
}

// TaskUpdate, göreve yazılan bir not (isteğe bağlı durum değişikliğiyle).
// AuthorName yazıldığı anki addır (bkz. migration 0051).
type TaskUpdate struct {
	ID         string
	TaskID     string
	ProjectID  string
	UserID     *string
	AuthorName string
	Body       string
	StatusFrom string
	StatusTo   string
	CreatedAt  time.Time
}

// IsOverdue, görevin vadesi geçmiş ve hâlâ açık olup olmadığını söyler.
// Karşılaştırma takvim günü bazındadır (bkz. domain.IsPastDue) -- vade
// GÜNÜNÜN kendisi henüz gecikmiş sayılmaz, ve SQL tarafındaki
// "due_date < CURRENT_DATE" kuralıyla (CountProjectTaskStats) aynı
// sonucu verir.
func (t ProjectTask) IsOverdue(now time.Time) bool {
	if t.Status != TaskStatusTodo && t.Status != TaskStatusInProgress {
		return false
	}
	return IsPastDue(t.DueDate, now)
}

type ProjectFile struct {
	ID             string
	OrganizationID string
	ProjectID      string
	OriginalName   string
	ObjectKey      string
	MIMEType       string
	SizeBytes      int64
	SHA256         string
	Category       string
	Description    string
	UploadedBy     *string
	CreatedAt      time.Time
}

type ProjectPhoto struct {
	ID             string
	OrganizationID string
	ProjectID      string
	OriginalName   string
	ObjectKey      string
	MIMEType       string
	SizeBytes      int64
	SHA256         string
	Stage          string
	Description    string
	TakenAt        *time.Time
	UploadedBy     *string
	CreatedAt      time.Time
}

type ProjectNote struct {
	ID             string
	OrganizationID string
	ProjectID      string
	Content        string
	CreatedBy      *string
	CreatedByName  string
	CreatedAt      time.Time
	UpdatedAt      time.Time
}

// ProjectOperationsSummary, proje detayının üst şeridindeki operasyon
// göstergeleridir.
type ProjectOperationsSummary struct {
	ActiveMemberCount   int64
	TotalTaskCount      int64
	OpenTaskCount       int64
	OverdueTaskCount    int64
	CompletedTaskCount  int64
	TaskCompletionRatio float64
}
