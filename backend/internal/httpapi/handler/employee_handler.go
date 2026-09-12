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

type EmployeeHandler struct {
	svc *service.EmployeeService
}

func NewEmployeeHandler(svc *service.EmployeeService) *EmployeeHandler {
	return &EmployeeHandler{svc: svc}
}

type employeeResponse struct {
	ID          string   `json:"id"`
	FullName    string   `json:"full_name"`
	Phone       string   `json:"phone"`
	Position    string   `json:"position"`
	Salary      *float64 `json:"salary"`
	DailyWage   *float64 `json:"daily_wage"`
	StartDate   *string  `json:"start_date"`
	IsActive    bool     `json:"is_active"`
	Description string   `json:"description"`
}

func toEmployeeResponse(e domain.Employee) employeeResponse {
	resp := employeeResponse{
		ID:          e.ID,
		FullName:    e.FullName,
		Phone:       e.Phone,
		Position:    e.Position,
		Salary:      e.Salary,
		DailyWage:   e.DailyWage,
		IsActive:    e.IsActive,
		Description: e.Description,
	}
	if e.StartDate != nil {
		s := e.StartDate.Format("2006-01-02")
		resp.StartDate = &s
	}
	return resp
}

func (h *EmployeeHandler) List(w http.ResponseWriter, r *http.Request) {
	var activeOnly *bool
	switch r.URL.Query().Get("filter") {
	case "aktif":
		v := true
		activeOnly = &v
	case "pasif":
		v := false
		activeOnly = &v
	}
	employees, err := h.svc.List(r.Context(), activeOnly)
	if err != nil {
		httpjson.Error(w, http.StatusInternalServerError, "personel listesi alınamadı")
		return
	}
	out := make([]employeeResponse, len(employees))
	for i, e := range employees {
		out[i] = toEmployeeResponse(e)
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"employees": out})
}

func (h *EmployeeHandler) Get(w http.ResponseWriter, r *http.Request) {
	e, err := h.svc.Get(r.Context(), chi.URLParam(r, "id"))
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toEmployeeResponse(*e))
}

type upsertEmployeeRequest struct {
	FullName    string   `json:"full_name"`
	Phone       string   `json:"phone"`
	Position    string   `json:"position"`
	Salary      *float64 `json:"salary"`
	DailyWage   *float64 `json:"daily_wage"`
	StartDate   *string  `json:"start_date"`
	Description string   `json:"description"`
	IsActive    bool     `json:"is_active"`
}

func (req upsertEmployeeRequest) toInput() (service.EmployeeInput, error) {
	in := service.EmployeeInput{
		FullName:    req.FullName,
		Phone:       req.Phone,
		Position:    req.Position,
		Salary:      req.Salary,
		DailyWage:   req.DailyWage,
		Description: req.Description,
		IsActive:    req.IsActive,
	}
	if req.StartDate != nil && *req.StartDate != "" {
		t, err := time.Parse("2006-01-02", *req.StartDate)
		if err != nil {
			return in, errors.New("geçersiz işe başlama tarihi")
		}
		in.StartDate = &t
	}
	return in, nil
}

func (h *EmployeeHandler) Create(w http.ResponseWriter, r *http.Request) {
	var req upsertEmployeeRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	req.IsActive = true
	in, err := req.toInput()
	if err != nil {
		httpjson.Error(w, http.StatusBadRequest, err.Error())
		return
	}
	e, err := h.svc.Create(r.Context(), in)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusCreated, toEmployeeResponse(*e))
}

func (h *EmployeeHandler) Update(w http.ResponseWriter, r *http.Request) {
	var req upsertEmployeeRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	in, err := req.toInput()
	if err != nil {
		httpjson.Error(w, http.StatusBadRequest, err.Error())
		return
	}
	e, err := h.svc.Update(r.Context(), chi.URLParam(r, "id"), in)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toEmployeeResponse(*e))
}

func (h *EmployeeHandler) Archive(w http.ResponseWriter, r *http.Request) {
	if err := h.svc.Archive(r.Context(), chi.URLParam(r, "id")); err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, map[string]bool{"ok": true})
}

func (h *EmployeeHandler) writeError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, domain.ErrNotFound):
		httpjson.Error(w, http.StatusNotFound, "personel bulunamadı")
	default:
		httpjson.Error(w, http.StatusBadRequest, err.Error())
	}
}
