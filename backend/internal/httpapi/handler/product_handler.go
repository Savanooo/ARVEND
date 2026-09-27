package handler

import (
	"errors"
	"net/http"
	"strconv"

	"github.com/go-chi/chi/v5"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/httpapi/middleware"
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
	// Source: tedarikçi kaynağı ("ulas"), elle eklenen üründe "".
	Source string `json:"source"`
	// SourceSyncedAt: ürünün kaynak listede en son görüldüğü an (RFC3339).
	SourceSyncedAt *string `json:"source_synced_at"`
	// SourcePrice: tedarikçi (kâr oranı uygulanmamış) fiyatı -- yalnızca
	// products.manage sahibine döner, aksi halde null (bkz. canManageProducts).
	SourcePrice *float64 `json:"source_price"`
}

func toProductResponse(p domain.Product, showSourcePrice bool) productResponse {
	resp := productResponse{
		ID:             p.ID,
		Name:           p.Name,
		Unit:           p.Unit,
		UnitPrice:      p.UnitPrice,
		Description:    p.Description,
		Category:       p.Category,
		Source:         p.Source,
		SourceSyncedAt: formatTimePtr(p.SourceSyncedAt),
	}
	if showSourcePrice {
		resp.SourcePrice = p.SourcePrice
	}
	return resp
}

func (h *ProductHandler) List(w http.ResponseWriter, r *http.Request) {
	page, _ := strconv.Atoi(r.URL.Query().Get("page"))
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	result, err := h.svc.List(r.Context(), orgID, r.URL.Query().Get("q"), page, limit)
	if err != nil {
		httpjson.Error(w, http.StatusInternalServerError, "ürünler alınamadı")
		return
	}
	showSourcePrice := canManageProducts(r)
	products := make([]productResponse, len(result.Products))
	for i, p := range result.Products {
		products[i] = toProductResponse(p, showSourcePrice)
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"products": products, "total": result.Total})
}

func (h *ProductHandler) Get(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	p, err := h.svc.Get(r.Context(), chi.URLParam(r, "id"), orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toProductResponse(*p, canManageProducts(r)))
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
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	p, err := h.svc.Create(r.Context(), orgID, req.Name, req.Unit, req.UnitPrice, req.Description, req.Category)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusCreated, toProductResponse(*p, canManageProducts(r)))
}

func (h *ProductHandler) Update(w http.ResponseWriter, r *http.Request) {
	var req upsertProductRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	p, err := h.svc.Update(r.Context(), chi.URLParam(r, "id"), orgID, req.Name, req.Unit, req.UnitPrice, req.Description, req.Category)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toProductResponse(*p, canManageProducts(r)))
}

func (h *ProductHandler) Delete(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	if err := h.svc.Delete(r.Context(), chi.URLParam(r, "id"), orgID); err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, map[string]bool{"ok": true})
}

type priceHistoryResponse struct {
	OldPrice float64 `json:"old_price"`
	NewPrice float64 `json:"new_price"`
	// Note: değişikliğin kaynağı (ör. "Ulaş fiyat listesi"); elle düzenlemede "".
	Note      string `json:"note"`
	ChangedAt string `json:"changed_at"`
	// Reason: manual | supplier | markup; Source: tedarikçi kodu, elle
	// düzenlemede null.
	Reason string  `json:"reason"`
	Source *string `json:"source"`
	// Tedarikçi fiyatları: yalnızca products.manage sahibine (aksi null).
	OldSourcePrice *float64 `json:"old_source_price"`
	NewSourcePrice *float64 `json:"new_source_price"`
}

func (h *ProductHandler) PriceHistory(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	entries, err := h.svc.PriceHistory(r.Context(), chi.URLParam(r, "id"), orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	showSourcePrice := canManageProducts(r)
	out := make([]priceHistoryResponse, len(entries))
	for i, e := range entries {
		out[i] = priceHistoryResponse{
			OldPrice:  e.OldPrice,
			NewPrice:  e.NewPrice,
			Note:      e.Note,
			ChangedAt: e.ChangedAt.Format("2006-01-02T15:04:05Z07:00"),
			Reason:    e.Reason,
			Source:    nullableSource(e.Source),
		}
		if showSourcePrice {
			out[i].OldSourcePrice = e.OldSourcePrice
			out[i].NewSourcePrice = e.NewSourcePrice
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
