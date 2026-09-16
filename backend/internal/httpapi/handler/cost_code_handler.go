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

// CostCodeHandler, organizasyon-seviyeli (proje-bağımsız, PAYLAŞILAN)
// maliyet kodu kataloğunu yönetir -- Sprint 2 (WBS + Cost Codes + Project
// Budget + Cost Control).
type CostCodeHandler struct {
	svc *service.CostCodeService
}

func NewCostCodeHandler(svc *service.CostCodeService) *CostCodeHandler {
	return &CostCodeHandler{svc: svc}
}

type costCodeResponse struct {
	ID          string `json:"id"`
	Code        string `json:"code"`
	Name        string `json:"name"`
	Description string `json:"description"`
	Category    string `json:"category"`
	IsActive    bool   `json:"is_active"`
}

func toCostCodeResponse(c domain.OrganizationCostCode) costCodeResponse {
	return costCodeResponse{
		ID: c.ID, Code: c.Code, Name: c.Name,
		Description: c.Description, Category: c.Category, IsActive: c.IsActive,
	}
}

func (h *CostCodeHandler) List(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	codes, err := h.svc.List(r.Context(), orgID)
	if err != nil {
		httpjson.Error(w, http.StatusInternalServerError, "maliyet kodu listesi alınamadı")
		return
	}
	out := make([]costCodeResponse, len(codes))
	for i, c := range codes {
		out[i] = toCostCodeResponse(c)
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"cost_codes": out})
}

func (h *CostCodeHandler) Get(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	c, err := h.svc.Get(r.Context(), chi.URLParam(r, "id"), orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toCostCodeResponse(*c))
}

type upsertCostCodeRequest struct {
	Code        string `json:"code"`
	Name        string `json:"name"`
	Description string `json:"description"`
	Category    string `json:"category"`
}

func (req upsertCostCodeRequest) toInput(userID string) service.CostCodeInput {
	return service.CostCodeInput{
		Code: req.Code, Name: req.Name, Description: req.Description, Category: req.Category, UserID: userID,
	}
}

func (h *CostCodeHandler) Create(w http.ResponseWriter, r *http.Request) {
	var req upsertCostCodeRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	c, err := h.svc.Create(r.Context(), orgID, req.toInput(userID))
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusCreated, toCostCodeResponse(*c))
}

func (h *CostCodeHandler) Update(w http.ResponseWriter, r *http.Request) {
	var req upsertCostCodeRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	c, err := h.svc.Update(r.Context(), chi.URLParam(r, "id"), orgID, req.toInput(userID))
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toCostCodeResponse(*c))
}

// Archive, HARD DELETE DEĞİLDİR (bkz. CostCodeService.Archive yorumu).
func (h *CostCodeHandler) Archive(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	if err := h.svc.Archive(r.Context(), chi.URLParam(r, "id"), orgID, userID); err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, map[string]bool{"ok": true})
}

func (h *CostCodeHandler) Reactivate(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	if err := h.svc.Reactivate(r.Context(), chi.URLParam(r, "id"), orgID, userID); err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, map[string]bool{"ok": true})
}

func (h *CostCodeHandler) writeError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, domain.ErrNotFound):
		httpjson.Error(w, http.StatusNotFound, "maliyet kodu bulunamadı")
	case errors.Is(err, service.ErrDuplicateCostCode):
		httpjson.Error(w, http.StatusConflict, err.Error())
	default:
		httpjson.Error(w, http.StatusBadRequest, err.Error())
	}
}
