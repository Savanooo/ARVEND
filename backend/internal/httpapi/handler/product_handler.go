package handler

import (
	"errors"
	"net/http"
	"strconv"

	"github.com/go-chi/chi/v5"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/platform/httpjson"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

type ProductHandler struct {
	svc *service.ProductService
}

func NewProductHandler(svc *service.ProductService) *ProductHandler {
	return &ProductHandler{svc: svc}
}

type productResponse struct {
	ID          string  `json:"id"`
	Name        string  `json:"name"`
	Unit        string  `json:"unit"`
	UnitPrice   float64 `json:"unit_price"`
	Description string  `json:"description"`
	Category    string  `json:"category"`
}

func toProductResponse(p domain.Product) productResponse {
	return productResponse{
		ID:          p.ID,
		Name:        p.Name,
		Unit:        p.Unit,
		UnitPrice:   p.UnitPrice,
		Description: p.Description,
		Category:    p.Category,
	}
}

func (h *ProductHandler) List(w http.ResponseWriter, r *http.Request) {
	page, _ := strconv.Atoi(r.URL.Query().Get("page"))
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	result, err := h.svc.List(r.Context(), r.URL.Query().Get("q"), page, limit)
	if err != nil {
		httpjson.Error(w, http.StatusInternalServerError, "ürünler alınamadı")
		return
	}
	products := make([]productResponse, len(result.Products))
	for i, p := range result.Products {
		products[i] = toProductResponse(p)
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"products": products, "total": result.Total})
}

func (h *ProductHandler) Get(w http.ResponseWriter, r *http.Request) {
	p, err := h.svc.Get(r.Context(), chi.URLParam(r, "id"))
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toProductResponse(*p))
}

type upsertProductRequest struct {
	Name        string  `json:"name"`
	Unit        string  `json:"unit"`
	UnitPrice   float64 `json:"unit_price"`
	Description string  `json:"description"`
	Category    string  `json:"category"`
}

func (h *ProductHandler) Create(w http.ResponseWriter, r *http.Request) {
	var req upsertProductRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	p, err := h.svc.Create(r.Context(), req.Name, req.Unit, req.UnitPrice, req.Description, req.Category)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusCreated, toProductResponse(*p))
}

func (h *ProductHandler) Update(w http.ResponseWriter, r *http.Request) {
	var req upsertProductRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	p, err := h.svc.Update(r.Context(), chi.URLParam(r, "id"), req.Name, req.Unit, req.UnitPrice, req.Description, req.Category)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toProductResponse(*p))
}

func (h *ProductHandler) Delete(w http.ResponseWriter, r *http.Request) {
	if err := h.svc.Delete(r.Context(), chi.URLParam(r, "id")); err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, map[string]bool{"ok": true})
}

type priceHistoryResponse struct {
	OldPrice  float64 `json:"old_price"`
	NewPrice  float64 `json:"new_price"`
	ChangedAt string  `json:"changed_at"`
}

func (h *ProductHandler) PriceHistory(w http.ResponseWriter, r *http.Request) {
	entries, err := h.svc.PriceHistory(r.Context(), chi.URLParam(r, "id"))
	if err != nil {
		h.writeError(w, err)
		return
	}
	out := make([]priceHistoryResponse, len(entries))
	for i, e := range entries {
		out[i] = priceHistoryResponse{
			OldPrice:  e.OldPrice,
			NewPrice:  e.NewPrice,
			ChangedAt: e.ChangedAt.Format("2006-01-02T15:04:05Z07:00"),
		}
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"history": out})
}

func (h *ProductHandler) writeError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, domain.ErrNotFound):
		httpjson.Error(w, http.StatusNotFound, "ürün bulunamadı")
	default:
		httpjson.Error(w, http.StatusBadRequest, err.Error())
	}
}
