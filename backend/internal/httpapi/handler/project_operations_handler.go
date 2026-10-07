package handler

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/httpapi/middleware"
	"github.com/Savanooo/ARVEND/backend/internal/platform/httpjson"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

// ---------- Ekip ----------

type memberResponse struct {
	ID           string  `json:"id"`
	EmployeeID   string  `json:"employee_id"`
	EmployeeName string  `json:"employee_name"`
	RoleTitle    string  `json:"role_title"`
	StartDate    *string `json:"start_date"`
	EndDate      *string `json:"end_date"`
	Notes        string  `json:"notes"`
	IsActive     bool    `json:"is_active"`
}

func toMemberResponse(m domain.ProjectMember) memberResponse {
	return memberResponse{
		ID: m.ID, EmployeeID: m.EmployeeID, EmployeeName: m.EmployeeName,
		RoleTitle: m.RoleTitle, StartDate: dateStrPtr(m.StartDate), EndDate: dateStrPtr(m.EndDate),
		Notes: m.Notes, IsActive: m.IsActive(),
	}
}

type assignMemberRequest struct {
	EmployeeID string  `json:"employee_id"`
	RoleTitle  string  `json:"role_title"`
	StartDate  *string `json:"start_date"`
	Notes      string  `json:"notes"`
}

func (h *ProjectHandler) ListMembers(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	rows, err := h.svc.ListMembers(r.Context(), chi.URLParam(r, "id"), orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	out := make([]memberResponse, len(rows))
	for i, m := range rows {
		out[i] = toMemberResponse(m)
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"members": out})
}

func (h *ProjectHandler) AssignMember(w http.ResponseWriter, r *http.Request) {
	var req assignMemberRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	m, err := h.svc.AssignMember(r.Context(), chi.URLParam(r, "id"), orgID, service.ProjectMemberInput{
		EmployeeID: req.EmployeeID, RoleTitle: req.RoleTitle,
		StartDate: parseDateParam(req.StartDate), Notes: req.Notes, UserID: userID,
	})
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusCreated, toMemberResponse(*m))
}

func (h *ProjectHandler) EndMembership(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	m, err := h.svc.EndMembership(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "memberId"), orgID, userID, nil)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toMemberResponse(*m))
}

// ---------- Planlama ----------

type scheduleItemResponse struct {
	ID                 string  `json:"id"`
	Name               string  `json:"name"`
	Description        string  `json:"description"`
	StartDate          *string `json:"start_date"`
	EndDate            *string `json:"end_date"`
	Status             string  `json:"status"`
	SortOrder          int     `json:"sort_order"`
	TaskCount          int64   `json:"task_count"`
	CompletedTaskCount int64   `json:"completed_task_count"`
	AssignedEmployeeID *string `json:"assigned_employee_id"`
	AssignedName       string  `json:"assigned_name"`
}

func toScheduleItemResponse(s domain.ScheduleItem) scheduleItemResponse {
	return scheduleItemResponse{
		ID: s.ID, Name: s.Name, Description: s.Description,
		StartDate: dateStrPtr(s.StartDate), EndDate: dateStrPtr(s.EndDate),
		Status: s.Status, SortOrder: s.SortOrder,
		TaskCount: s.TaskCount, CompletedTaskCount: s.CompletedTaskCount,
		AssignedEmployeeID: s.AssignedEmployeeID, AssignedName: s.AssignedName,
	}
}

type scheduleItemRequest struct {
	Name        string  `json:"name"`
	Description string  `json:"description"`
	StartDate   *string `json:"start_date"`
	EndDate     *string `json:"end_date"`
	Status      string  `json:"status"`
	SortOrder   int     `json:"sort_order"`
	// Ham tutulur: alan HİÇ gönderilmediyse (eski istemci) sorumlu
	// korunur; null/"" gönderildiyse kaldırılır.
	AssignedEmployeeID json.RawMessage `json:"assigned_employee_id"`
}

func (r scheduleItemRequest) toInput(userID string) (service.ScheduleItemInput, error) {
	in := service.ScheduleItemInput{
		Name: r.Name, Description: r.Description,
		StartDate: parseDateParam(r.StartDate), EndDate: parseDateParam(r.EndDate),
		Status: r.Status, SortOrder: r.SortOrder, UserID: userID,
	}
	if len(r.AssignedEmployeeID) > 0 {
		in.AssigneeSet = true
		if string(r.AssignedEmployeeID) != "null" {
			if err := json.Unmarshal(r.AssignedEmployeeID, &in.AssignedEmployeeID); err != nil {
				return in, err
			}
		}
	}
	return in, nil
}

func (h *ProjectHandler) ListScheduleItems(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	rows, err := h.svc.ListScheduleItems(r.Context(), chi.URLParam(r, "id"), orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	out := make([]scheduleItemResponse, len(rows))
	for i, s := range rows {
		out[i] = toScheduleItemResponse(s)
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"items": out})
}

func (h *ProjectHandler) CreateScheduleItem(w http.ResponseWriter, r *http.Request) {
	var req scheduleItemRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	in, err := req.toInput(userID)
	if err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz sorumlu personel")
		return
	}
	s, err := h.svc.CreateScheduleItem(r.Context(), chi.URLParam(r, "id"), orgID, in)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusCreated, toScheduleItemResponse(*s))
}

func (h *ProjectHandler) UpdateScheduleItem(w http.ResponseWriter, r *http.Request) {
	var req scheduleItemRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	in, err := req.toInput(userID)
	if err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz sorumlu personel")
		return
	}
	s, err := h.svc.UpdateScheduleItem(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "itemId"), orgID, in)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toScheduleItemResponse(*s))
}

// ListAssignees, GET /projects/{id}/assignees -- görev/plan formlarının
// "kime" seçicisi (ücretsiz, bkz. service.Assignee).
func (h *ProjectHandler) ListAssignees(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	rows, err := h.svc.ListAssignees(r.Context(), chi.URLParam(r, "id"), orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	// has_project_access: has_account true iken false ise kişi projeyi
	// göremiyor -- görev/plan atanamaz (400), seçici bunu gösterir.
	type assignee struct {
		ID               string `json:"id"`
		FullName         string `json:"full_name"`
		Position         string `json:"position"`
		HasAccount       bool   `json:"has_account"`
		HasProjectAccess bool   `json:"has_project_access"`
	}
	out := make([]assignee, len(rows))
	for i, a := range rows {
		out[i] = assignee{
			ID: a.ID, FullName: a.FullName, Position: a.Position,
			HasAccount: a.HasAccount, HasProjectAccess: a.HasProjectAccess,
		}
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"employees": out})
}

// ---------- Görevler ----------

type taskResponse struct {
	ID                 string  `json:"id"`
	ScheduleItemID     *string `json:"schedule_item_id"`
	Title              string  `json:"title"`
	Description        string  `json:"description"`
	AssignedEmployeeID *string `json:"assigned_employee_id"`
	AssignedName       string  `json:"assigned_name"`
	Priority           string  `json:"priority"`
	Status             string  `json:"status"`
	DueDate            *string `json:"due_date"`
	CompletedAt        *string `json:"completed_at"`
	IsOverdue          bool    `json:"is_overdue"`
}

func toTaskResponse(t domain.ProjectTask) taskResponse {
	return taskResponse{
		ID: t.ID, ScheduleItemID: t.ScheduleItemID, Title: t.Title, Description: t.Description,
		AssignedEmployeeID: t.AssignedEmployeeID, AssignedName: t.AssignedName,
		Priority: t.Priority, Status: t.Status, DueDate: dateStrPtr(t.DueDate),
		CompletedAt: tsStrPtr(t.CompletedAt), IsOverdue: t.IsOverdue(service.IstanbulNow(time.Now())),
	}
}

type taskRequest struct {
	Title              string  `json:"title"`
	Description        string  `json:"description"`
	ScheduleItemID     *string `json:"schedule_item_id"`
	AssignedEmployeeID *string `json:"assigned_employee_id"`
	Priority           string  `json:"priority"`
	Status             string  `json:"status"`
	DueDate            *string `json:"due_date"`
}

func (r taskRequest) toInput(userID string) service.TaskInput {
	return service.TaskInput{
		Title: r.Title, Description: r.Description, ScheduleItemID: r.ScheduleItemID,
		AssignedEmployeeID: r.AssignedEmployeeID, Priority: r.Priority, Status: r.Status,
		DueDate: parseDateParam(r.DueDate), UserID: userID,
	}
}

func (h *ProjectHandler) ListTasks(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	rows, err := h.svc.ListTasks(r.Context(), chi.URLParam(r, "id"), orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	out := make([]taskResponse, len(rows))
	for i, t := range rows {
		out[i] = toTaskResponse(t)
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"tasks": out})
}

func (h *ProjectHandler) CreateTask(w http.ResponseWriter, r *http.Request) {
	var req taskRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	t, err := h.svc.CreateTask(r.Context(), chi.URLParam(r, "id"), orgID, req.toInput(userID))
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusCreated, toTaskResponse(*t))
}

func (h *ProjectHandler) UpdateTask(w http.ResponseWriter, r *http.Request) {
	var req taskRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	t, err := h.svc.UpdateTask(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "taskId"), orgID, req.toInput(userID))
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toTaskResponse(*t))
}

func (h *ProjectHandler) CompleteTask(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	t, err := h.svc.CompleteTask(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "taskId"), orgID, userID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toTaskResponse(*t))
}

type myTaskResponse struct {
	taskResponse
	ProjectID     string `json:"project_id"`
	ProjectName   string `json:"project_name"`
	ProjectStatus string `json:"project_status"`
	// ProjectClosed: proje tamamlandı/iptal -- görev artık "gecikmiş"
	// sayılmaz (is_overdue false), istemci "proje kapalı" diye gösterir.
	ProjectClosed bool `json:"project_closed"`
}

func toMyTaskResponse(t service.MyTask) myTaskResponse {
	resp := myTaskResponse{
		taskResponse:  toTaskResponse(t.ProjectTask),
		ProjectID:     t.ProjectID,
		ProjectName:   t.ProjectName,
		ProjectStatus: t.ProjectStatus,
		ProjectClosed: t.ProjectClosed(),
	}
	if resp.ProjectClosed {
		resp.IsOverdue = false
	}
	return resp
}

// ListMyTasks, GET /api/v1/tasks/mine -- bana ATANAN görevler (bkz.
// migration 0041 + ProjectService.ListMyTasks yorumu). callerUserID
// HER ZAMAN gönderilir (rolden BAĞIMSIZ -- owner/admin DAHİL, "/mine
// hâlâ BENİM görevlerim" kuralı); restrictToUserID ise AYRI, yalnızca
// proje-erişim sınırı (ListProjects İLE AYNI, AuthzContext'ten).
func (h *ProjectHandler) ListMyTasks(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	callerUserID, _ := middleware.UserIDFromContext(r.Context())
	statusMode := r.URL.Query().Get("status")
	var restrictToUserID string
	if authz, ok := middleware.AuthzContextFromRequest(r.Context()); ok && !authz.BypassesProjectMembership() {
		restrictToUserID = authz.UserID
	}
	rows, err := h.svc.ListMyTasks(r.Context(), orgID, statusMode, callerUserID, restrictToUserID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	// Liste boşsa nedeni: hesap bir personel kaydına bağlı değil mi?
	linked, err := h.svc.IsEmployeeLinked(r.Context(), orgID, callerUserID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	out := make([]myTaskResponse, len(rows))
	for i, t := range rows {
		out[i] = toMyTaskResponse(t)
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"tasks": out, "linked_employee": linked})
}

// ListTeamTasks, GET /api/v1/tasks/team?status=open|all|...&assignee=<personel>
// -- Görevler sekmesinin "Ekip" görünümü: erişilebilir projelerdeki tüm
// görevler (ListMyTasks ile aynı üyelik kuralı).
func (h *ProjectHandler) ListTeamTasks(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	var restrictToUserID string
	if authz, ok := middleware.AuthzContextFromRequest(r.Context()); ok && !authz.BypassesProjectMembership() {
		restrictToUserID = authz.UserID
	}
	rows, total, err := h.svc.ListTeamTasks(r.Context(), orgID, r.URL.Query().Get("status"), restrictToUserID, r.URL.Query().Get("assignee"))
	if err != nil {
		if errors.Is(err, service.ErrInvalidEmployee) {
			httpjson.Error(w, http.StatusBadRequest, err.Error())
			return
		}
		h.writeError(w, err)
		return
	}
	out := make([]myTaskResponse, len(rows))
	for i, t := range rows {
		out[i] = toMyTaskResponse(t)
	}
	// total/truncated: liste service.TeamTaskLimit'te kesildiyse istemci
	// "ilk N görev gösteriliyor" diyebilsin (eskiden sessizce kırpılıyordu).
	httpjson.Write(w, http.StatusOK, map[string]any{
		"tasks": out, "total": total, "truncated": total > int64(len(out)),
	})
}

type taskUpdateResponse struct {
	ID         string  `json:"id"`
	UserID     *string `json:"user_id"`
	AuthorName string  `json:"author_name"`
	Body       string  `json:"body"`
	StatusFrom string  `json:"status_from"`
	StatusTo   string  `json:"status_to"`
	CreatedAt  string  `json:"created_at"`
}

func toTaskUpdateResponse(u domain.TaskUpdate) taskUpdateResponse {
	return taskUpdateResponse{
		ID: u.ID, UserID: u.UserID, AuthorName: u.AuthorName, Body: u.Body,
		StatusFrom: u.StatusFrom, StatusTo: u.StatusTo, CreatedAt: u.CreatedAt.Format(rfc3339),
	}
}

// ListTaskUpdates, GET /projects/{id}/tasks/{taskId}/updates.
func (h *ProjectHandler) ListTaskUpdates(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	rows, err := h.svc.ListTaskUpdates(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "taskId"), orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	out := make([]taskUpdateResponse, len(rows))
	for i, u := range rows {
		out[i] = toTaskUpdateResponse(u)
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"updates": out})
}

type createTaskUpdateRequest struct {
	Body   string `json:"body"`
	Status string `json:"status"`
}

// CreateTaskUpdate, POST /projects/{id}/tasks/{taskId}/updates -- göreve
// not (isteğe bağlı durum değişikliğiyle). Yanıt: not + görevin son hali.
func (h *ProjectHandler) CreateTaskUpdate(w http.ResponseWriter, r *http.Request) {
	var req createTaskUpdateRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	up, task, err := h.svc.AddTaskUpdate(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "taskId"), orgID, userID, req.Body, req.Status)
	if err != nil {
		switch {
		case errors.Is(err, service.ErrTaskUpdateEmpty), errors.Is(err, service.ErrTaskUpdateTooLong),
			errors.Is(err, service.ErrTaskStatusInvalid):
			httpjson.Error(w, http.StatusBadRequest, err.Error())
		default:
			h.writeError(w, err)
		}
		return
	}
	httpjson.Write(w, http.StatusCreated, map[string]any{"update": toTaskUpdateResponse(*up), "task": toTaskResponse(*task)})
}

// ---------- Dosyalar ----------

type fileResponse struct {
	ID           string `json:"id"`
	OriginalName string `json:"original_name"`
	MIMEType     string `json:"mime_type"`
	SizeBytes    int64  `json:"size_bytes"`
	SHA256       string `json:"sha256"`
	Category     string `json:"category"`
	Description  string `json:"description"`
	CreatedAt    string `json:"created_at"`
}

func toFileResponse(f domain.ProjectFile) fileResponse {
	return fileResponse{
		ID: f.ID, OriginalName: f.OriginalName, MIMEType: f.MIMEType, SizeBytes: f.SizeBytes,
		SHA256: f.SHA256, Category: f.Category, Description: f.Description,
		CreatedAt: f.CreatedAt.Format(rfc3339),
	}
}

// errUploadUnreadable: multipart gövdesi çözümlenemedi. Ham Go hatası
// ("multipart: NextPart: EOF" vb.) yalnızca sunucu loguna yazılır.
var errUploadUnreadable = errors.New("dosya okunamadı; lütfen tekrar deneyin")

// readUpload, multipart isteğinden dosyayı çıkarır. Gövde
// MaxBytesReader ile sınırlanır: sınırı aşan bir istek diske hiç
// yazılmadan kesilir. Sınır aşımı service.ErrFileTooLarge döner (413, net
// Türkçe metin) -- eskiden "dosya okunamadı: http: request body too
// large" ham metni 400 ile dönüyordu.
func readUpload(w http.ResponseWriter, r *http.Request) (io.Reader, string, map[string]string, error) {
	r.Body = http.MaxBytesReader(w, r.Body, service.MaxUploadBytes+1024)
	if err := r.ParseMultipartForm(8 << 20); err != nil {
		var tooLarge *http.MaxBytesError
		if errors.As(err, &tooLarge) {
			return nil, "", nil, service.ErrFileTooLarge
		}
		log.Printf("yükleme gövdesi çözümlenemedi: %v", err)
		return nil, "", nil, errUploadUnreadable
	}
	file, header, err := r.FormFile("file")
	if err != nil {
		return nil, "", nil, fmt.Errorf("dosya alanı bulunamadı")
	}
	fields := map[string]string{}
	for _, k := range []string{"category", "stage", "description", "taken_at"} {
		fields[k] = r.FormValue(k)
	}
	return file, header.Filename, fields, nil
}

func (h *ProjectHandler) ListFiles(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	rows, err := h.svc.ListFiles(r.Context(), chi.URLParam(r, "id"), orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	out := make([]fileResponse, len(rows))
	for i, f := range rows {
		out[i] = toFileResponse(f)
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"files": out})
}

func (h *ProjectHandler) UploadFile(w http.ResponseWriter, r *http.Request) {
	body, name, fields, err := readUpload(w, r)
	if err != nil {
		h.writeError(w, err)
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	f, err := h.svc.UploadFile(r.Context(), chi.URLParam(r, "id"), orgID, service.UploadInput{
		OriginalName: name, Reader: body, Category: fields["category"],
		Description: fields["description"], UserID: userID,
	})
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusCreated, toFileResponse(*f))
}

// DownloadFile, dosyayı servis eder. Yetki kontrolü servis katmanındaki
// organization_id'li sorgudur: başka bir firmanın dosya UUID'si bilinse
// bile buradan tek bayt okunamaz.
func (h *ProjectHandler) DownloadFile(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	f, rc, err := h.svc.OpenFile(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "fileId"), orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	defer rc.Close()
	serveAttachment(w, rc, f.MIMEType, f.OriginalName, f.SizeBytes)
}

func (h *ProjectHandler) DeleteFile(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	if err := h.svc.DeleteFile(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "fileId"), orgID, userID); err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, map[string]bool{"ok": true})
}

// serveAttachment, içeriği indirilecek şekilde yazar.
// X-Content-Type-Options: nosniff ve Content-Disposition, yüklenen bir
// dosyanın tarayıcıda aktif içerik olarak yorumlanmasını engeller
// (saklanan XSS riskine karşı).
func serveAttachment(w http.ResponseWriter, rc io.Reader, mimeType, name string, size int64) {
	w.Header().Set("Content-Type", mimeType)
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Content-Length", fmt.Sprintf("%d", size))
	// Dosya adı başlıkta tırnak/satır sonu ile başlık enjeksiyonu
	// yapamasın diye temizlenir.
	safe := strings.Map(func(r rune) rune {
		if r == '"' || r == '\\' || r == '\r' || r == '\n' {
			return '_'
		}
		return r
	}, name)
	w.Header().Set("Content-Disposition", fmt.Sprintf("attachment; filename=%q", safe))
	_, _ = io.Copy(w, rc)
}

// ---------- Fotoğraflar ----------

type photoResponse struct {
	ID           string  `json:"id"`
	OriginalName string  `json:"original_name"`
	MIMEType     string  `json:"mime_type"`
	SizeBytes    int64   `json:"size_bytes"`
	Stage        string  `json:"stage"`
	Description  string  `json:"description"`
	TakenAt      *string `json:"taken_at"`
	CreatedAt    string  `json:"created_at"`
}

func toPhotoResponse(p domain.ProjectPhoto) photoResponse {
	return photoResponse{
		ID: p.ID, OriginalName: p.OriginalName, MIMEType: p.MIMEType, SizeBytes: p.SizeBytes,
		Stage: p.Stage, Description: p.Description, TakenAt: tsStrPtr(p.TakenAt),
		CreatedAt: p.CreatedAt.Format(rfc3339),
	}
}

func (h *ProjectHandler) ListPhotos(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	rows, err := h.svc.ListPhotos(r.Context(), chi.URLParam(r, "id"), orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	out := make([]photoResponse, len(rows))
	for i, p := range rows {
		out[i] = toPhotoResponse(p)
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"photos": out})
}

func (h *ProjectHandler) UploadPhoto(w http.ResponseWriter, r *http.Request) {
	body, name, fields, err := readUpload(w, r)
	if err != nil {
		h.writeError(w, err)
		return
	}
	var takenAt *time.Time
	if fields["taken_at"] != "" {
		if t, perr := time.Parse(dateLayout, fields["taken_at"]); perr == nil {
			takenAt = &t
		}
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	p, err := h.svc.UploadPhoto(r.Context(), chi.URLParam(r, "id"), orgID, service.UploadInput{
		OriginalName: name, Reader: body, Stage: fields["stage"],
		Description: fields["description"], TakenAt: takenAt, UserID: userID,
	})
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusCreated, toPhotoResponse(*p))
}

func (h *ProjectHandler) DownloadPhoto(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	p, rc, err := h.svc.OpenPhoto(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "photoId"), orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	defer rc.Close()
	// Galeride <img> ile gösterilebilmesi için inline; nosniff yine de
	// içeriğin beyan edilen türden farklı yorumlanmasını engeller.
	w.Header().Set("Content-Type", p.MIMEType)
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Content-Length", fmt.Sprintf("%d", p.SizeBytes))
	w.Header().Set("Cache-Control", "private, max-age=300")
	_, _ = io.Copy(w, rc)
}

func (h *ProjectHandler) DeletePhoto(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	if err := h.svc.DeletePhoto(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "photoId"), orgID, userID); err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, map[string]bool{"ok": true})
}

// ---------- Notlar ----------

type noteResponse struct {
	ID            string `json:"id"`
	Content       string `json:"content"`
	CreatedByName string `json:"created_by_name"`
	CreatedAt     string `json:"created_at"`
}

func toNoteResponse(n domain.ProjectNote) noteResponse {
	return noteResponse{
		ID: n.ID, Content: n.Content, CreatedByName: n.CreatedByName,
		CreatedAt: n.CreatedAt.Format(rfc3339),
	}
}

type noteRequest struct {
	Content string `json:"content"`
}

func (h *ProjectHandler) ListNotes(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	rows, err := h.svc.ListNotes(r.Context(), chi.URLParam(r, "id"), orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	out := make([]noteResponse, len(rows))
	for i, n := range rows {
		out[i] = toNoteResponse(n)
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"notes": out})
}

func (h *ProjectHandler) CreateNote(w http.ResponseWriter, r *http.Request) {
	var req noteRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	n, err := h.svc.CreateNote(r.Context(), chi.URLParam(r, "id"), orgID, req.Content, userID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusCreated, toNoteResponse(*n))
}

// ---------- Operasyon Özeti ----------

func (h *ProjectHandler) OperationsSummary(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	s, err := h.svc.OperationsSummary(r.Context(), chi.URLParam(r, "id"), orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, map[string]any{
		"active_member_count":   s.ActiveMemberCount,
		"total_task_count":      s.TotalTaskCount,
		"open_task_count":       s.OpenTaskCount,
		"overdue_task_count":    s.OverdueTaskCount,
		"completed_task_count":  s.CompletedTaskCount,
		"task_completion_ratio": s.TaskCompletionRatio,
	})
}
