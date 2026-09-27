package handler

import (
	"errors"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/shopspring/decimal"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/httpapi/middleware"
	"github.com/Savanooo/ARVEND/backend/internal/platform/httpjson"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

// PriceSourceHandler, /products/price-sources uçları: tedarikçi fiyat
// listesi (Ulaş) ayarları, elle senkron.
type PriceSourceHandler struct {
	svc *service.PriceSourceService
}

func NewPriceSourceHandler(svc *service.PriceSourceService) *PriceSourceHandler {
	return &PriceSourceHandler{svc: svc}
}

// canManageProducts: kâr oranları ve kaynak (tedarikçi) fiyatı yalnızca
// products.manage sahibine döner. products.read teklif hazırlayan herkese
// verilir; satış fiyatı + oran = tedarikçi maliyeti olduğundan oranı
// görmek maliyeti görmek demektir (personel ücretleriyle aynı ilke, bkz.
// canSeeEmployeeWages).
func canManageProducts(r *http.Request) bool {
	authz, ok := middleware.AuthzContextFromRequest(r.Context())
	return ok && authz.HasPermission(domain.PermProductsManage)
}

type priceSourceCategoryMarkupJSON struct {
	Category      string  `json:"category"`
	MarkupPercent float64 `json:"markup_percent"`
}

type priceSourceCategoryJSON struct {
	Category     string `json:"category"`
	ProductCount int    `json:"product_count"`
}

type priceSyncResultJSON struct {
	Total     int `json:"total"`
	Created   int `json:"created"`
	Updated   int `json:"updated"`
	Unchanged int `json:"unchanged"`
	Missing   int `json:"missing"`
}

type priceSourceResponse struct {
	Source string `json:"source"`
	Name   string `json:"name"`
	// MarkupPercent/CategoryMarkups: products.manage yoksa null.
	MarkupPercent   *float64                        `json:"markup_percent"`
	CategoryMarkups []priceSourceCategoryMarkupJSON `json:"category_markups"`
	AutoSync        bool                            `json:"auto_sync"`
	// LastSyncedAt: son BAŞARILI senkron; LastStatus never|success|failed,
	// LastError son başarısız denemenin kısa açıklaması.
	LastSyncedAt *string             `json:"last_synced_at"`
	LastStatus   string              `json:"last_status"`
	LastError    string              `json:"last_error"`
	LastResult   priceSyncResultJSON `json:"last_result"`
	// Categories: firmanın bu kaynaktan gelen ürünlerindeki kategoriler.
	Categories   []priceSourceCategoryJSON `json:"categories"`
	ProductCount int                       `json:"product_count"`
	// MissingCount: son başarılı senkronda listede bulunmayan (silinmeyen)
	// kaynak ürünleri.
	MissingCount int     `json:"missing_count"`
	UpdatedAt    *string `json:"updated_at"`
}

func formatTimePtr(t *time.Time) *string {
	if t == nil {
		return nil
	}
	s := t.Format(time.RFC3339)
	return &s
}

func toSyncResultJSON(r domain.PriceSyncResult) priceSyncResultJSON {
	return priceSyncResultJSON{Total: r.Total, Created: r.Created, Updated: r.Updated, Unchanged: r.Unchanged, Missing: r.Missing}
}

func toPriceSourceResponse(ov domain.PriceSourceOverview, showMarkups bool) priceSourceResponse {
	resp := priceSourceResponse{
		Source:       ov.Source,
		Name:         domain.PriceSourceName(ov.Source),
		AutoSync:     ov.AutoSync,
		LastSyncedAt: formatTimePtr(ov.LastSyncedAt),
		LastStatus:   ov.LastStatus,
		LastError:    ov.LastError,
		LastResult:   toSyncResultJSON(ov.LastResult),
		Categories:   make([]priceSourceCategoryJSON, len(ov.Categories)),
		ProductCount: ov.ProductCount,
		MissingCount: ov.MissingCount,
		UpdatedAt:    formatTimePtr(ov.UpdatedAt),
	}
	for i, c := range ov.Categories {
		resp.Categories[i] = priceSourceCategoryJSON{Category: c.Category, ProductCount: c.ProductCount}
	}
	if showMarkups {
		m := ov.MarkupPercent.InexactFloat64()
		resp.MarkupPercent = &m
		resp.CategoryMarkups = make([]priceSourceCategoryMarkupJSON, len(ov.CategoryMarkups))
		for i, cm := range ov.CategoryMarkups {
			resp.CategoryMarkups[i] = priceSourceCategoryMarkupJSON{Category: cm.Category, MarkupPercent: cm.MarkupPercent.InexactFloat64()}
		}
	}
	return resp
}

func (h *PriceSourceHandler) List(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	sources, err := h.svc.GetPriceSources(r.Context(), orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	showMarkups := canManageProducts(r)
	out := make([]priceSourceResponse, len(sources))
	for i, ov := range sources {
		out[i] = toPriceSourceResponse(ov, showMarkups)
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"sources": out})
}

// updatePriceSourceRequest: PUT tam durumdur -- üç alan da zorunludur
// (kategori oranı yoksa category_markups: []). Oranlar decimal olarak
// okunur (JSON sayısı float'a düşmeden); aşırı üslü değerler ("1e-2000000000")
// servis tarafında HERHANGİ bir aritmetikten önce reddedilir (validateMarkup).
type updatePriceSourceRequest struct {
	MarkupPercent   *decimal.Decimal `json:"markup_percent"`
	AutoSync        *bool            `json:"auto_sync"`
	CategoryMarkups *[]struct {
		Category      string           `json:"category"`
		MarkupPercent *decimal.Decimal `json:"markup_percent"`
	} `json:"category_markups"`
}

// maxPriceSourceBodyBytes: en fazla 500 kategori oranı x (100 karakterlik
// ad + oran) rahatça sığar; üstü reddedilir (httpjson.Decode'un kendi
// sınırı yok -- aşırı uzun sayı/metinlerle bellek şişirilmesin).
const maxPriceSourceBodyBytes = 256 << 10

func (h *PriceSourceHandler) Update(w http.ResponseWriter, r *http.Request) {
	source := chi.URLParam(r, "source")
	if !domain.ValidPriceSource(source) {
		h.writeError(w, domain.ErrUnknownPriceSource)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxPriceSourceBodyBytes)
	var req updatePriceSourceRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	switch {
	case req.MarkupPercent == nil:
		httpjson.Error(w, http.StatusBadRequest, "markup_percent zorunludur")
		return
	case req.AutoSync == nil:
		httpjson.Error(w, http.StatusBadRequest, "auto_sync zorunludur")
		return
	case req.CategoryMarkups == nil:
		httpjson.Error(w, http.StatusBadRequest, "category_markups zorunludur (kategori oranı yoksa boş liste gönderin)")
		return
	}
	in := service.PriceSourceSettingsInput{MarkupPercent: *req.MarkupPercent, AutoSync: *req.AutoSync}
	for _, cm := range *req.CategoryMarkups {
		if cm.MarkupPercent == nil {
			httpjson.Error(w, http.StatusBadRequest, "her kategori oranı için markup_percent zorunludur")
			return
		}
		in.CategoryMarkups = append(in.CategoryMarkups, domain.PriceSourceCategoryMarkup{Category: cm.Category, MarkupPercent: *cm.MarkupPercent})
	}

	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	res, err := h.svc.UpdatePriceSource(r.Context(), orgID, source, userID, in)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, map[string]any{
		"price_source": toPriceSourceResponse(res.Overview, canManageProducts(r)),
		"recomputed":   res.Recomputed,
	})
}

type priceSyncResponse struct {
	Source string `json:"source"`
	priceSyncResultJSON
	SyncedAt string `json:"synced_at"`
}

func (h *PriceSourceHandler) Sync(w http.ResponseWriter, r *http.Request) {
	source := chi.URLParam(r, "source")
	if !domain.ValidPriceSource(source) {
		h.writeError(w, domain.ErrUnknownPriceSource)
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	res, err := h.svc.SyncUlas(r.Context(), orgID, userID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, priceSyncResponse{
		Source:              source,
		priceSyncResultJSON: toSyncResultJSON(*res),
		SyncedAt:            res.SyncedAt.Format(time.RFC3339),
	})
}

func (h *PriceSourceHandler) writeError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, domain.ErrUnknownPriceSource):
		httpjson.Error(w, http.StatusNotFound, domain.ErrUnknownPriceSource.Error())
	case errors.Is(err, domain.ErrNotFound):
		httpjson.Error(w, http.StatusNotFound, domain.ErrNotFound.Error())
	case errors.Is(err, domain.ErrPriceSyncBusy):
		httpjson.Error(w, http.StatusConflict, domain.ErrPriceSyncBusy.Error())
	case errors.Is(err, domain.ErrPriceSourceFetch):
		// Ayrıntı (HTTP kodu, zaman aşımı...) last_error'da; yanıta sabit metin.
		httpjson.Error(w, http.StatusBadGateway, domain.ErrPriceSourceFetch.Error())
	case isInternalError(err):
		writeInternalError(w, err)
	default:
		httpjson.Error(w, http.StatusBadRequest, err.Error())
	}
}
