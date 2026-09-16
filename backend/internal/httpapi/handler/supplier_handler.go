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

// ARVEND V2 — Sprint 4: Procurement Foundation, Tedarikçi (Supplier)
// uçları. CostCodeHandler İLE AYNI dosya-başına-endişe deseni -- AYRI bir
// handler tipi (organizasyon-seviyeli, ProjectHandler'a EKLENMEZ).

type SupplierHandler struct {
	svc *service.SupplierService
}

func NewSupplierHandler(svc *service.SupplierService) *SupplierHandler {
	return &SupplierHandler{svc: svc}
}

type supplierResponse struct {
	ID          string `json:"id"`
	Code        string `json:"code"`
	LegalName   string `json:"legal_name"`
	TradeName   string `json:"trade_name"`
	TaxNumber   string `json:"tax_number"`
	TaxOffice   string `json:"tax_office"`
	ContactName string `json:"contact_name"`
	Email       string `json:"email"`
	Phone       string `json:"phone"`
	Address     string `json:"address"`
	City        string `json:"city"`
	Country     string `json:"country"`
	IBANSet     bool   `json:"iban_set"`
	IsActive    bool   `json:"is_active"`
	Notes       string `json:"notes"`
	CreatedAt   string `json:"created_at"`
	UpdatedAt   string `json:"updated_at"`
}

func toSupplierResponse(s domain.Supplier) supplierResponse {
	return supplierResponse{
		ID: s.ID, Code: s.Code, LegalName: s.LegalName, TradeName: s.TradeName,
		TaxNumber: s.TaxNumber, TaxOffice: s.TaxOffice, ContactName: s.ContactName,
		Email: s.Email, Phone: s.Phone, Address: s.Address, City: s.City, Country: s.Country,
		IBANSet: s.IBANEncSet, IsActive: s.IsActive, Notes: s.Notes,
		CreatedAt: s.CreatedAt.Format(rfc3339), UpdatedAt: s.UpdatedAt.Format(rfc3339),
	}
}

type supplierRequest struct {
	Code        string `json:"code"`
	LegalName   string `json:"legal_name"`
	TradeName   string `json:"trade_name"`
	TaxNumber   string `json:"tax_number"`
	TaxOffice   string `json:"tax_office"`
	ContactName string `json:"contact_name"`
	Email       string `json:"email"`
	Phone       string `json:"phone"`
	Address     string `json:"address"`
	City        string `json:"city"`
	Country     string `json:"country"`
	// IBAN, nil ise DEĞİŞTİRİLMEZ; boş string ise TEMİZLENİR; dolu ise
	// şifrelenir (bkz. SupplierService.encryptIBAN). Plaintext hiçbir
	// yanıtta DÖNMEZ, yalnızca IBANSet boolean'ı görünür.
	IBAN  *string `json:"iban"`
	Notes string  `json:"notes"`
}

func (req supplierRequest) toInput(userID string) service.SupplierInput {
	return service.SupplierInput{
		Code: req.Code, LegalName: req.LegalName, TradeName: req.TradeName,
		TaxNumber: req.TaxNumber, TaxOffice: req.TaxOffice, ContactName: req.ContactName,
		Email: req.Email, Phone: req.Phone, Address: req.Address, City: req.City, Country: req.Country,
		IBAN: req.IBAN, Notes: req.Notes, UserID: userID,
	}
}

func (h *SupplierHandler) List(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	rows, err := h.svc.List(r.Context(), orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	out := make([]supplierResponse, len(rows))
	for i, s := range rows {
		out[i] = toSupplierResponse(s)
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"suppliers": out})
}

func (h *SupplierHandler) Get(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	s, err := h.svc.Get(r.Context(), chi.URLParam(r, "id"), orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toSupplierResponse(*s))
}

func (h *SupplierHandler) Create(w http.ResponseWriter, r *http.Request) {
	var req supplierRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	s, err := h.svc.Create(r.Context(), orgID, req.toInput(userID))
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusCreated, toSupplierResponse(*s))
}

func (h *SupplierHandler) Update(w http.ResponseWriter, r *http.Request) {
	var req supplierRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	s, err := h.svc.Update(r.Context(), chi.URLParam(r, "id"), orgID, req.toInput(userID))
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toSupplierResponse(*s))
}

// Archive, HARD DELETE DEĞİLDİR -- bkz. SupplierService.Archive yorumu.
func (h *SupplierHandler) Archive(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	if err := h.svc.Archive(r.Context(), chi.URLParam(r, "id"), orgID, userID); err != nil {
		h.writeError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (h *SupplierHandler) Reactivate(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	if err := h.svc.Reactivate(r.Context(), chi.URLParam(r, "id"), orgID, userID); err != nil {
		h.writeError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (h *SupplierHandler) writeError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, domain.ErrNotFound):
		httpjson.Error(w, http.StatusNotFound, "tedarikçi bulunamadı")
	case errors.Is(err, service.ErrDuplicateSupplierCode):
		httpjson.Error(w, http.StatusConflict, err.Error())
	case errors.Is(err, service.ErrSupplierFieldsRequired):
		httpjson.Error(w, http.StatusBadRequest, err.Error())
	default:
		httpjson.Error(w, http.StatusBadRequest, err.Error())
	}
}
