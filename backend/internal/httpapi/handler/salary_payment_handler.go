package handler

import (
	"errors"
	"math"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/httpapi/middleware"
	"github.com/Savanooo/ARVEND/backend/internal/platform/httpjson"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

type SalaryPaymentHandler struct {
	svc *service.SalaryPaymentService
}

func NewSalaryPaymentHandler(svc *service.SalaryPaymentService) *SalaryPaymentHandler {
	return &SalaryPaymentHandler{svc: svc}
}

type salaryPaymentResponse struct {
	ID           string  `json:"id"`
	EmployeeID   string  `json:"employee_id"`
	EmployeeName string  `json:"employee_name,omitempty"`
	Period       string  `json:"period"`
	PaymentType  string  `json:"payment_type"`
	Amount       float64 `json:"amount"`
	PaidDate     string  `json:"paid_date"`
	Description  string  `json:"description"`
}

func toSalaryPaymentResponse(p domain.SalaryPayment) salaryPaymentResponse {
	return salaryPaymentResponse{
		ID:           p.ID,
		EmployeeID:   p.EmployeeID,
		EmployeeName: p.EmployeeName,
		Period:       p.Period,
		PaymentType:  p.PaymentType,
		Amount:       p.Amount,
		PaidDate:     p.PaidDate.Format("2006-01-02"),
		Description:  p.Description,
	}
}

type payrollSummaryResponse struct {
	EmployeeID   string   `json:"employee_id"`
	FullName     string   `json:"full_name"`
	Position     string   `json:"position"`
	Salary       *float64 `json:"salary"`
	DailyWage    *float64 `json:"daily_wage"`
	IsActive     bool     `json:"is_active"`
	WorkedDays   float64  `json:"worked_days"`
	WorkHours    float64  `json:"work_hours"`
	PaidTotal    float64  `json:"paid_total"`
	PaymentCount int      `json:"payment_count"`
	// Hesap (domain.PayrollSummaryRow.Calculate). wage_basis "" ise ücret
	// tanımsız: earned/remaining anlamsızdır, istemci "ücret tanımsız" der.
	WageBasis  string  `json:"wage_basis"`
	Earned     float64 `json:"earned"`
	SalaryPaid float64 `json:"salary_paid"` // kalandan düşülen kısmı (maaş/avans/mesai)
	ExtraPaid  float64 `json:"extra_paid"`  // prim/diğer -- kalanı etkilemez
	CarryOver  float64 `json:"carry_over"`
	Remaining  float64 `json:"remaining"`
}

// payrollPeriodParam, ?month=YYYY-MM'i okur; verilmezse içinde bulunulan ay.
func payrollPeriodParam(r *http.Request) string {
	if m := r.URL.Query().Get("month"); m != "" {
		return m
	}
	return time.Now().Format("2006-01")
}

// List, bir ayın ödeme tablosunu (personel başına özet) VE o ayın tek tek
// ödemelerini tek yanıtta döner -- sayfa ikisini birlikte gösteriyor, iki
// ayrı istek aynı ayı iki kez çözmek olurdu.
func (h *SalaryPaymentHandler) List(w http.ResponseWriter, r *http.Request) {
	period := payrollPeriodParam(r)
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())

	summary, err := h.svc.Summary(r.Context(), orgID, period)
	if err != nil {
		h.writeError(w, err)
		return
	}
	payments, err := h.svc.ListByPeriod(r.Context(), orgID, period)
	if err != nil {
		h.writeError(w, err)
		return
	}

	sum := make([]payrollSummaryResponse, len(summary))
	for i, s := range summary {
		sum[i] = payrollSummaryResponse{
			EmployeeID: s.EmployeeID, FullName: s.FullName, Position: s.Position,
			Salary: s.Salary, DailyWage: s.DailyWage, IsActive: s.IsActive,
			WorkedDays: s.WorkedDays, WorkHours: s.WorkHours,
			PaidTotal: s.PaidTotal, PaymentCount: s.PaymentCount,
			WageBasis: s.WageBasis, Earned: s.Earned,
			SalaryPaid: s.SalaryPaid, ExtraPaid: math.Round((s.PaidTotal-s.SalaryPaid)*100) / 100,
			CarryOver: s.CarryOver, Remaining: s.Remaining,
		}
	}
	pay := make([]salaryPaymentResponse, len(payments))
	for i, p := range payments {
		pay[i] = toSalaryPaymentResponse(p)
	}
	httpjson.Write(w, http.StatusOK, map[string]any{
		"period":   period,
		"summary":  sum,
		"payments": pay,
	})
}

type createSalaryPaymentRequest struct {
	EmployeeID  string  `json:"employee_id"`
	Period      string  `json:"period"`
	PaymentType string  `json:"payment_type"`
	Amount      float64 `json:"amount"`
	PaidDate    string  `json:"paid_date"`
	Description string  `json:"description"`
}

func (h *SalaryPaymentHandler) Create(w http.ResponseWriter, r *http.Request) {
	var req createSalaryPaymentRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	var paidDate time.Time
	if req.PaidDate != "" {
		t, err := time.Parse("2006-01-02", req.PaidDate)
		if err != nil {
			httpjson.Error(w, http.StatusBadRequest, "geçersiz ödeme tarihi")
			return
		}
		paidDate = t
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	p, err := h.svc.Create(r.Context(), orgID, service.SalaryPaymentInput{
		EmployeeID:  req.EmployeeID,
		Period:      req.Period,
		PaymentType: req.PaymentType,
		Amount:      req.Amount,
		PaidDate:    paidDate,
		Description: req.Description,
		CreatedBy:   userID,
	})
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusCreated, toSalaryPaymentResponse(*p))
}

func (h *SalaryPaymentHandler) Delete(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	if err := h.svc.Delete(r.Context(), chi.URLParam(r, "id"), orgID); err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, map[string]bool{"ok": true})
}

func (h *SalaryPaymentHandler) writeError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, domain.ErrNotFound):
		httpjson.Error(w, http.StatusNotFound, "ödeme kaydı bulunamadı")
	case errors.Is(err, service.ErrInvalidPeriod),
		errors.Is(err, service.ErrInvalidPaymentType),
		errors.Is(err, service.ErrInvalidAmount),
		errors.Is(err, service.ErrAmountTooLarge),
		errors.Is(err, service.ErrInvalidEmployee):
		httpjson.Error(w, http.StatusBadRequest, err.Error())
	default:
		// Beklenmeyen DB hatalarının ham metni istemciye sızmasın.
		httpjson.Error(w, http.StatusInternalServerError, "ödeme işlemi tamamlanamadı")
	}
}
