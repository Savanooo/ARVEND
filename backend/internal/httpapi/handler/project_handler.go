package handler

import (
	"errors"
	"net/http"
	"strconv"
	"time"

	"github.com/go-chi/chi/v5"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/httpapi/middleware"
	"github.com/Savanooo/ARVEND/backend/internal/platform/httpjson"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

type ProjectHandler struct {
	svc *service.ProjectService
}

func NewProjectHandler(svc *service.ProjectService) *ProjectHandler {
	return &ProjectHandler{svc: svc}
}

type projectResponse struct {
	ID               string  `json:"id"`
	ProjectNo        string  `json:"project_no"`
	Name             string  `json:"name"`
	ProjectType      string  `json:"project_type"`
	SourceOfferID    string  `json:"source_offer_id"`
	SourceOfferNo    string  `json:"source_offer_no"`
	SourceRevisionID string  `json:"source_revision_id"`
	SourceRevisionNo int     `json:"source_revision_no"`
	CustomerID       *string `json:"customer_id"`
	CustomerName     string  `json:"customer_name"`
	CustomerPhone    string  `json:"customer_phone"`
	CustomerEmail    string  `json:"customer_email"`
	CustomerAddress  string  `json:"customer_address"`
	ContractAmount   float64 `json:"contract_amount"`
	Currency         string  `json:"currency"`
	Status           string  `json:"status"`
	StartDate        *string `json:"start_date"`
	EndDate          *string `json:"end_date"`
	Description      string  `json:"description"`
	InternalNotes    string  `json:"internal_notes"`
	CreatedBy        *string `json:"created_by"`
	CreatedAt        string  `json:"created_at"`
	UpdatedAt        string  `json:"updated_at"`

	// Liste ekranı için aggregate finans alanları (yalnızca List'te dolu).
	CollectedAmount        float64 `json:"collected_amount"`
	TotalExpenses          float64 `json:"total_expenses"`
	SubcontractorPaid      float64 `json:"subcontractor_paid"`
	SubcontractorRemaining float64 `json:"subcontractor_remaining"`
	RemainingReceivable    float64 `json:"remaining_receivable"`
	RealizedCost           float64 `json:"realized_cost"`
	RealizedGrossProfit    float64 `json:"realized_gross_profit"`
	InvoiceCount           int64   `json:"invoice_count"`
	PaidInvoiceCount       int64   `json:"paid_invoice_count"`
}

func toProjectResponse(p domain.Project) projectResponse {
	resp := projectResponse{
		ID:               p.ID,
		ProjectNo:        p.ProjectNo,
		Name:             p.Name,
		ProjectType:      p.ProjectType,
		SourceOfferID:    p.SourceOfferID,
		SourceOfferNo:    p.SourceOfferNo,
		SourceRevisionID: p.SourceRevisionID,
		SourceRevisionNo: p.SourceRevisionNo,
		CustomerID:       p.CustomerID,
		CustomerName:     p.CustomerName,
		CustomerPhone:    p.CustomerPhone,
		CustomerEmail:    p.CustomerEmail,
		CustomerAddress:  p.CustomerAddress,
		ContractAmount:   p.ContractAmount,
		Currency:         p.Currency,
		Status:           p.Status,
		Description:      p.Description,
		InternalNotes:    p.InternalNotes,
		CreatedBy:        p.CreatedBy,
		CreatedAt:        p.CreatedAt.Format(rfc3339),
		UpdatedAt:        p.UpdatedAt.Format(rfc3339),

		CollectedAmount:        p.CollectedAmount,
		TotalExpenses:          p.TotalExpenses,
		SubcontractorPaid:      p.SubcontractorPaid,
		SubcontractorRemaining: p.SubcontractorRemaining,
		RemainingReceivable:    p.RemainingReceivable(),
		RealizedCost:           p.RealizedCost(),
		RealizedGrossProfit:    p.RealizedGrossProfit(),
		InvoiceCount:           p.InvoiceCount,
		PaidInvoiceCount:       p.PaidInvoiceCount,
	}
	if p.StartDate != nil {
		s := p.StartDate.Format(dateLayout)
		resp.StartDate = &s
	}
	if p.EndDate != nil {
		s := p.EndDate.Format(dateLayout)
		resp.EndDate = &s
	}
	return resp
}

func parseDateParam(raw *string) *time.Time {
	if raw == nil || *raw == "" {
		return nil
	}
	t, err := time.Parse(dateLayout, *raw)
	if err != nil {
		return nil
	}
	return &t
}

type createProjectRequest struct {
	Name        string  `json:"name"`
	ProjectType string  `json:"project_type"`
	StartDate   *string `json:"start_date"`
	EndDate     *string `json:"end_date"`
	Description string  `json:"description"`
}

func (h *ProjectHandler) CreateFromOffer(w http.ResponseWriter, r *http.Request) {
	var req createProjectRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	p, err := h.svc.CreateFromOffer(r.Context(), chi.URLParam(r, "offerId"), orgID, service.CreateProjectInput{
		Name:        req.Name,
		ProjectType: req.ProjectType,
		StartDate:   parseDateParam(req.StartDate),
		EndDate:     parseDateParam(req.EndDate),
		Description: req.Description,
		UserID:      userID,
	})
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusCreated, toProjectResponse(*p))
}

func (h *ProjectHandler) List(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	page, _ := strconv.Atoi(q.Get("page"))
	limit, _ := strconv.Atoi(q.Get("limit"))
	startFrom := q.Get("start_from")

	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	result, err := h.svc.List(r.Context(), orgID, service.ProjectListFilter{
		Status:      q.Get("status"),
		CustomerID:  q.Get("customer_id"),
		ProjectType: q.Get("project_type"),
		Currency:    q.Get("currency"),
		StartFrom:   parseDateParam(&startFrom),
		Search:      q.Get("q"),
		Page:        page,
		Limit:       limit,
	})
	if err != nil {
		h.writeError(w, err)
		return
	}
	projects := make([]projectResponse, len(result.Projects))
	for i, p := range result.Projects {
		projects[i] = toProjectResponse(p)
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"projects": projects, "total": result.Total})
}

func (h *ProjectHandler) Get(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	p, err := h.svc.Get(r.Context(), chi.URLParam(r, "id"), orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toProjectResponse(*p))
}

// GetByOffer, teklifin projeye dönüştürülüp dönüştürülmediğini söyler.
// Dönüştürülmemişse 404 döner -- frontend bunu "Projeye Dönüştür"
// butonunu göstermek için kullanır.
func (h *ProjectHandler) GetByOffer(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	p, err := h.svc.GetByOfferID(r.Context(), chi.URLParam(r, "id"), orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toProjectResponse(*p))
}

type updateProjectRequest struct {
	Name          string  `json:"name"`
	ProjectType   string  `json:"project_type"`
	Status        string  `json:"status"`
	StartDate     *string `json:"start_date"`
	EndDate       *string `json:"end_date"`
	Description   string  `json:"description"`
	InternalNotes string  `json:"internal_notes"`
}

func (h *ProjectHandler) Update(w http.ResponseWriter, r *http.Request) {
	var req updateProjectRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	p, err := h.svc.Update(r.Context(), chi.URLParam(r, "id"), orgID, service.UpdateProjectInput{
		Name:          req.Name,
		ProjectType:   req.ProjectType,
		Status:        req.Status,
		StartDate:     parseDateParam(req.StartDate),
		EndDate:       parseDateParam(req.EndDate),
		Description:   req.Description,
		InternalNotes: req.InternalNotes,
	})
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toProjectResponse(*p))
}

func (h *ProjectHandler) writeError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, domain.ErrNotFound):
		httpjson.Error(w, http.StatusNotFound, "proje bulunamadı")
	case errors.Is(err, service.ErrOfferNotAccepted),
		errors.Is(err, service.ErrInvalidProjectState),
		errors.Is(err, service.ErrProjectLocked),
		errors.Is(err, service.ErrCurrencyMismatch),
		errors.Is(err, service.ErrAlreadyVoided):
		httpjson.Error(w, http.StatusConflict, err.Error())
	case isInternalError(err):
		writeInternalError(w, err)
	default:
		httpjson.Error(w, http.StatusBadRequest, err.Error())
	}
}
