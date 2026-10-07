package handler

import (
	"errors"
	"net/http"

	"github.com/go-chi/chi/v5"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/httpapi/middleware"
	"github.com/Savanooo/ARVEND/backend/internal/platform/httpjson"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

type CustomerHandler struct {
	svc *service.CustomerService
}

func NewCustomerHandler(svc *service.CustomerService) *CustomerHandler {
	return &CustomerHandler{svc: svc}
}

type customerResponse struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	Phone     string `json:"phone"`
	Email     string `json:"email"`
	Address   string `json:"address"`
	TaxOffice string `json:"tax_office"`
	TaxNumber string `json:"tax_number"`
	Notes     string `json:"notes"`
	IsActive  bool   `json:"is_active"`
}

func toCustomerResponse(c domain.Customer) customerResponse {
	return customerResponse{
		ID:        c.ID,
		Name:      c.Name,
		Phone:     c.Phone,
		Email:     c.Email,
		Address:   c.Address,
		TaxOffice: c.TaxOffice,
		TaxNumber: c.TaxNumber,
		Notes:     c.Notes,
		IsActive:  c.IsActive,
	}
}

func (h *CustomerHandler) List(w http.ResponseWriter, r *http.Request) {
	var activeOnly *bool
	switch r.URL.Query().Get("filter") {
	case "aktif":
		v := true
		activeOnly = &v
	case "pasif":
		v := false
		activeOnly = &v
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	customers, err := h.svc.List(r.Context(), orgID, r.URL.Query().Get("q"), activeOnly)
	if err != nil {
		httpjson.Error(w, http.StatusInternalServerError, "müşteri listesi alınamadı")
		return
	}
	out := make([]customerResponse, len(customers))
	for i, c := range customers {
		out[i] = toCustomerResponse(c)
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"customers": out})
}

func (h *CustomerHandler) Get(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	c, err := h.svc.Get(r.Context(), chi.URLParam(r, "id"), orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toCustomerResponse(*c))
}

type upsertCustomerRequest struct {
	Name      string `json:"name"`
	Phone     string `json:"phone"`
	Email     string `json:"email"`
	Address   string `json:"address"`
	TaxOffice string `json:"tax_office"`
	TaxNumber string `json:"tax_number"`
	Notes     string `json:"notes"`
	IsActive  bool   `json:"is_active"`
	// AllowDuplicate: 409 duplicate_customer uyarısından sonra kullanıcı
	// "yine de kaydet" dediğinde true gönderilir.
	AllowDuplicate bool `json:"allow_duplicate"`
}

func (req upsertCustomerRequest) toInput() service.CustomerInput {
	return service.CustomerInput{
		Name:      req.Name,
		Phone:     req.Phone,
		Email:     req.Email,
		Address:   req.Address,
		TaxOffice: req.TaxOffice,
		TaxNumber: req.TaxNumber,
		Notes:     req.Notes,
		IsActive:  req.IsActive,

		AllowDuplicate: req.AllowDuplicate,
	}
}

func (h *CustomerHandler) Create(w http.ResponseWriter, r *http.Request) {
	var req upsertCustomerRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	req.IsActive = true
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	c, err := h.svc.Create(r.Context(), orgID, req.toInput())
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusCreated, toCustomerResponse(*c))
}

func (h *CustomerHandler) Update(w http.ResponseWriter, r *http.Request) {
	var req upsertCustomerRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	c, err := h.svc.Update(r.Context(), chi.URLParam(r, "id"), orgID, req.toInput())
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toCustomerResponse(*c))
}

func (h *CustomerHandler) Archive(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	if err := h.svc.Archive(r.Context(), chi.URLParam(r, "id"), orgID); err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, map[string]bool{"ok": true})
}

func (h *CustomerHandler) writeError(w http.ResponseWriter, err error) {
	var dup *service.DuplicateCustomerError
	switch {
	case errors.Is(err, domain.ErrNotFound):
		httpjson.Error(w, http.StatusNotFound, "müşteri bulunamadı")
	case errors.As(err, &dup):
		// 409 + mevcut müşterinin kimliği: istemci adı gösterip ona
		// yönlendirebilir ya da allow_duplicate=true ile yine de kaydedebilir.
		httpjson.Write(w, http.StatusConflict, map[string]any{
			"error": dup.Error(),
			"code":  "duplicate_customer",
			"field": dup.Field,
			"existing_customer": map[string]any{
				"id": dup.Existing.ID, "name": dup.Existing.Name, "is_active": dup.Existing.IsActive,
			},
		})
	case isInternalError(err):
		writeInternalError(w, err)
	default:
		httpjson.Error(w, http.StatusBadRequest, err.Error())
	}
}
