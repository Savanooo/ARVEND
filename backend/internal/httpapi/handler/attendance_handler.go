package handler

import (
	"errors"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/platform/httpjson"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

type AttendanceHandler struct {
	svc *service.AttendanceService
}

func NewAttendanceHandler(svc *service.AttendanceService) *AttendanceHandler {
	return &AttendanceHandler{svc: svc}
}

type attendanceResponse struct {
	ID           string  `json:"id"`
	EmployeeID   string  `json:"employee_id"`
	EmployeeName string  `json:"employee_name,omitempty"`
	Date         string  `json:"date"`
	CheckIn      string  `json:"check_in"`
	CheckOut     string  `json:"check_out"`
	WorkHours    float64 `json:"work_hours"`
	Status       string  `json:"status"`
	Note         string  `json:"note"`
}

func toAttendanceResponse(a domain.AttendanceLog) attendanceResponse {
	return attendanceResponse{
		ID:           a.ID,
		EmployeeID:   a.EmployeeID,
		EmployeeName: a.EmployeeName,
		Date:         a.Date.Format("2006-01-02"),
		CheckIn:      a.CheckIn,
		CheckOut:     a.CheckOut,
		WorkHours:    a.WorkHours,
		Status:       a.Status,
		Note:         a.Note,
	}
}

func (h *AttendanceHandler) ListByMonth(w http.ResponseWriter, r *http.Request) {
	monthParam := r.URL.Query().Get("month")
	month := time.Now()
	if monthParam != "" {
		t, err := time.Parse("2006-01", monthParam)
		if err != nil {
			httpjson.Error(w, http.StatusBadRequest, "geçersiz ay (YYYY-MM bekleniyor)")
			return
		}
		month = t
	}
	logs, err := h.svc.ListByMonth(r.Context(), month)
	if err != nil {
		httpjson.Error(w, http.StatusInternalServerError, "mesai kayıtları alınamadı")
		return
	}
	out := make([]attendanceResponse, len(logs))
	for i, l := range logs {
		out[i] = toAttendanceResponse(l)
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"attendance": out})
}

type upsertAttendanceRequest struct {
	EmployeeID string  `json:"employee_id"`
	Date       string  `json:"date"`
	CheckIn    string  `json:"check_in"`
	CheckOut   string  `json:"check_out"`
	WorkHours  float64 `json:"work_hours"`
	Status     string  `json:"status"`
	Note       string  `json:"note"`
}

func (h *AttendanceHandler) Create(w http.ResponseWriter, r *http.Request) {
	var req upsertAttendanceRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	date, err := time.Parse("2006-01-02", req.Date)
	if err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz tarih")
		return
	}
	a, err := h.svc.Create(r.Context(), service.AttendanceInput{
		EmployeeID: req.EmployeeID,
		Date:       date,
		CheckIn:    req.CheckIn,
		CheckOut:   req.CheckOut,
		WorkHours:  req.WorkHours,
		Status:     req.Status,
		Note:       req.Note,
	})
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusCreated, toAttendanceResponse(*a))
}

func (h *AttendanceHandler) Update(w http.ResponseWriter, r *http.Request) {
	var req upsertAttendanceRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	a, err := h.svc.Update(r.Context(), chi.URLParam(r, "id"), service.AttendanceInput{
		CheckIn:   req.CheckIn,
		CheckOut:  req.CheckOut,
		WorkHours: req.WorkHours,
		Status:    req.Status,
		Note:      req.Note,
	})
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toAttendanceResponse(*a))
}

func (h *AttendanceHandler) Delete(w http.ResponseWriter, r *http.Request) {
	if err := h.svc.Delete(r.Context(), chi.URLParam(r, "id")); err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, map[string]bool{"ok": true})
}

func (h *AttendanceHandler) writeError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, domain.ErrNotFound):
		httpjson.Error(w, http.StatusNotFound, "mesai kaydı bulunamadı")
	case errors.Is(err, service.ErrAttendanceExists):
		httpjson.Error(w, http.StatusConflict, err.Error())
	default:
		httpjson.Error(w, http.StatusBadRequest, err.Error())
	}
}
