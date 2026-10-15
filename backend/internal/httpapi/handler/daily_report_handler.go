package handler

import (
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"

	"github.com/Savanooo/ARVEND/backend/internal/httpapi/middleware"
	"github.com/Savanooo/ARVEND/backend/internal/platform/httpjson"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

// Günlük şantiye raporu (migration 0071). İzin kapıları router'da: okuma ve
// PDF projects.operations.read, kaydetme ve gönderme
// projects.operations.manage (proje erişimiyle). {date} YYYY-AA-GG.

type dailyReportSubcontractorDTO struct {
	SupplierID string `json:"supplier_id"`
	Name       string `json:"name,omitempty"`
	Specialty  string `json:"specialty,omitempty"`
	Workers    int    `json:"workers"`
	WorkNote   string `json:"work_note"`
}

type dailyReportTaskDTO struct {
	ID           string `json:"id"`
	Title        string `json:"title"`
	AssignedName string `json:"assigned_name"`
}

type dailyReportPhotoDTO struct {
	ID          string `json:"id"`
	Stage       string `json:"stage"`
	Description string `json:"description"`
}

type dailyReportResponse struct {
	Exists          bool                          `json:"exists"`
	ID              string                        `json:"id,omitempty"`
	ProjectID       string                        `json:"project_id"`
	ReportDate      string                        `json:"report_date"`
	Weather         string                        `json:"weather"`
	TemperatureC    *int                          `json:"temperature_c"`
	OwnWorkers      int                           `json:"own_workers"`
	WorkDone        string                        `json:"work_done"`
	Issues          string                        `json:"issues"`
	Materials       string                        `json:"materials"`
	Notes           string                        `json:"notes"`
	Status          string                        `json:"status"`
	SubmittedAt     *string                       `json:"submitted_at"`
	SubmittedByName string                        `json:"submitted_by_name"`
	CreatedByName   string                        `json:"created_by_name"`
	UpdatedAt       *string                       `json:"updated_at"`
	Subcontractors  []dailyReportSubcontractorDTO `json:"subcontractors"`

	SuggestedOwnWorkers  int                           `json:"suggested_own_workers"`
	CompletedTasks       []dailyReportTaskDTO          `json:"completed_tasks"`
	Photos               []dailyReportPhotoDTO         `json:"photos"`
	SubcontractorOptions []dailyReportSubcontractorDTO `json:"subcontractor_options"`
}

func toDailyReportResponse(d *service.DailyReport) dailyReportResponse {
	resp := dailyReportResponse{
		Exists: d.Exists, ID: d.ID, ProjectID: d.ProjectID, ReportDate: d.ReportDate.Format(dateLayout),
		Weather: d.Weather, TemperatureC: d.TemperatureC, OwnWorkers: d.OwnWorkers, WorkDone: d.WorkDone,
		Issues: d.Issues, Materials: d.Materials, Notes: d.Notes, Status: d.Status,
		SubmittedByName: d.SubmittedByName, CreatedByName: d.CreatedByName,
		SuggestedOwnWorkers:  d.SuggestedOwnWorkers,
		Subcontractors:       make([]dailyReportSubcontractorDTO, len(d.Subcontractors)),
		CompletedTasks:       make([]dailyReportTaskDTO, len(d.CompletedTasks)),
		Photos:               make([]dailyReportPhotoDTO, len(d.Photos)),
		SubcontractorOptions: make([]dailyReportSubcontractorDTO, len(d.SubcontractorOptions)),
	}
	for i, s := range d.SubcontractorOptions {
		resp.SubcontractorOptions[i] = dailyReportSubcontractorDTO{SupplierID: s.SupplierID, Name: s.Name, Specialty: s.Specialty}
	}
	if d.SubmittedAt != nil {
		s := d.SubmittedAt.Format(time.RFC3339)
		resp.SubmittedAt = &s
	}
	if d.UpdatedAt != nil {
		s := d.UpdatedAt.Format(time.RFC3339)
		resp.UpdatedAt = &s
	}
	for i, s := range d.Subcontractors {
		resp.Subcontractors[i] = dailyReportSubcontractorDTO{
			SupplierID: s.SupplierID, Name: s.Name, Specialty: s.Specialty, Workers: s.Workers, WorkNote: s.WorkNote,
		}
	}
	for i, t := range d.CompletedTasks {
		resp.CompletedTasks[i] = dailyReportTaskDTO{ID: t.ID, Title: t.Title, AssignedName: t.AssignedName}
	}
	for i, p := range d.Photos {
		resp.Photos[i] = dailyReportPhotoDTO{ID: p.ID, Stage: p.Stage, Description: p.Description}
	}
	return resp
}

type dailyReportListItemResponse struct {
	ID                   string `json:"id"`
	ReportDate           string `json:"report_date"`
	Weather              string `json:"weather"`
	TemperatureC         *int   `json:"temperature_c"`
	OwnWorkers           int    `json:"own_workers"`
	SubcontractorWorkers int    `json:"subcontractor_workers"`
	Status               string `json:"status"`
	WorkDone             string `json:"work_done"`
	CreatedByName        string `json:"created_by_name"`
	PhotoCount           int    `json:"photo_count"`
}

type dailyReportRequest struct {
	Weather        string                        `json:"weather"`
	TemperatureC   *int                          `json:"temperature_c"`
	OwnWorkers     int                           `json:"own_workers"`
	WorkDone       string                        `json:"work_done"`
	Issues         string                        `json:"issues"`
	Materials      string                        `json:"materials"`
	Notes          string                        `json:"notes"`
	Subcontractors []dailyReportSubcontractorDTO `json:"subcontractors"`
}

// reportDateParam: {date} yolu; boş ya da geçersizse 400 yazar.
func reportDateParam(w http.ResponseWriter, r *http.Request) (time.Time, bool) {
	raw := strings.TrimSpace(chi.URLParam(r, "date"))
	t, err := time.Parse(dateLayout, raw)
	if err != nil {
		httpjson.Error(w, http.StatusBadRequest, fmt.Sprintf("geçersiz tarih %q: tarih YYYY-AA-GG biçiminde olmalıdır", raw))
		return time.Time{}, false
	}
	return t, true
}

// ListDailyReports: GET /projects/{id}/daily-reports.
func (h *ProjectHandler) ListDailyReports(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	rows, err := h.svc.ListDailyReports(r.Context(), chi.URLParam(r, "id"), orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	out := make([]dailyReportListItemResponse, len(rows))
	for i, d := range rows {
		out[i] = dailyReportListItemResponse{
			ID: d.ID, ReportDate: d.ReportDate.Format(dateLayout), Weather: d.Weather, TemperatureC: d.TemperatureC,
			OwnWorkers: d.OwnWorkers, SubcontractorWorkers: d.SubcontractorWorkers, Status: d.Status,
			WorkDone: d.WorkDone, CreatedByName: d.CreatedByName, PhotoCount: d.PhotoCount,
		}
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"reports": out, "today": service.IstanbulToday().Format(dateLayout)})
}

// GetDailyReport: GET /projects/{id}/daily-reports/{date}. Yazılmamış gün de
// 200 döner (exists=false) -- form o günün otomatik verileriyle açılır.
func (h *ProjectHandler) GetDailyReport(w http.ResponseWriter, r *http.Request) {
	date, ok := reportDateParam(w, r)
	if !ok {
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	out, err := h.svc.GetDailyReport(r.Context(), chi.URLParam(r, "id"), orgID, date)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toDailyReportResponse(out))
}

// SaveDailyReport: PUT /projects/{id}/daily-reports/{date}.
func (h *ProjectHandler) SaveDailyReport(w http.ResponseWriter, r *http.Request) {
	date, ok := reportDateParam(w, r)
	if !ok {
		return
	}
	var req dailyReportRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	in := service.DailyReportInput{
		Weather: req.Weather, TemperatureC: req.TemperatureC, OwnWorkers: req.OwnWorkers, WorkDone: req.WorkDone,
		Issues: req.Issues, Materials: req.Materials, Notes: req.Notes, UserID: userID,
	}
	for _, s := range req.Subcontractors {
		in.Subcontractors = append(in.Subcontractors, service.DailyReportSubcontractor{
			SupplierID: s.SupplierID, Workers: s.Workers, WorkNote: s.WorkNote,
		})
	}
	out, err := h.svc.SaveDailyReport(r.Context(), chi.URLParam(r, "id"), orgID, date, in)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toDailyReportResponse(out))
}

// SubmitDailyReport: POST /projects/{id}/daily-reports/{date}/submit.
func (h *ProjectHandler) SubmitDailyReport(w http.ResponseWriter, r *http.Request) {
	date, ok := reportDateParam(w, r)
	if !ok {
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	out, err := h.svc.SubmitDailyReport(r.Context(), chi.URLParam(r, "id"), orgID, userID, date)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toDailyReportResponse(out))
}

// DailyReportPDF: GET /projects/{id}/daily-reports/{date}/pdf.
func (h *ProjectHandler) DailyReportPDF(w http.ResponseWriter, r *http.Request) {
	date, ok := reportDateParam(w, r)
	if !ok {
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	doc, err := h.svc.DailyReportPDF(r.Context(), chi.URLParam(r, "id"), orgID, date)
	if err != nil {
		h.writeError(w, err)
		return
	}
	w.Header().Set("Content-Type", "application/pdf")
	w.Header().Set("Content-Length", strconv.Itoa(len(doc.Content)))
	w.Header().Set("Content-Disposition",
		fmt.Sprintf(`inline; filename="%s"; filename*=UTF-8''%s`, doc.Filename, url.PathEscape(doc.Filename)))
	w.Header().Set("Cache-Control", "private, no-store")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(doc.Content)
}
