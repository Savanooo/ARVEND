package handler

import (
	"errors"
	"net/http"
	"strings"

	"github.com/go-chi/chi/v5"
	"github.com/shopspring/decimal"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/httpapi/middleware"
	"github.com/Savanooo/ARVEND/backend/internal/platform/httpjson"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

// CalcHandler, Metraj Hesaplama modülünün HTTP katmanıdır.
//
// Miktar/tutar alanları burada BİLİNÇLİ olarak JSON STRING olarak
// taşınır (ör. "quantity": "100", "total_cost": "43100.00") -- diğer
// ARVEND uçlarının aksine (ör. products.unit_price bir JSON number'dır).
// Bu, tarayıcı/istemci tarafında JS'in float64 temsilinin ondalık
// hassasiyeti bozmasını (ör. büyük/kesirli miktarlarda) engellemek
// içindir; sunucu tarafında zaten decimal.Decimal ile kayıpsız hesaplanan
// bir sonucun, son adımda tekrar float64'e sıkıştırılmasını önler.
type CalcHandler struct {
	svc *service.CalcService
}

func NewCalcHandler(svc *service.CalcService) *CalcHandler {
	return &CalcHandler{svc: svc}
}

// ---------- Gruplar ----------

type calcGroupResponse struct {
	ID          string `json:"id"`
	Slug        string `json:"slug"`
	Name        string `json:"name"`
	Description string `json:"description"`
	SortOrder   int    `json:"sort_order"`
	IsActive    bool   `json:"is_active"`
}

func toCalcGroupResponse(g domain.CalcGroup) calcGroupResponse {
	return calcGroupResponse{ID: g.ID, Slug: g.Slug, Name: g.Name, Description: g.Description, SortOrder: g.SortOrder, IsActive: g.IsActive}
}

// includeInactiveParam: ?include_inactive=1|true -- yönetim ekranları
// (web/mobil Metraj Reçeteleri) pasif grup/kategorileri de görür. Parametresiz
// istek eskisi gibi yalnızca aktifleri döner (eski istemciler etkilenmez).
func includeInactiveParam(r *http.Request) bool {
	v := r.URL.Query().Get("include_inactive")
	return v == "1" || v == "true"
}

func (h *CalcHandler) ListGroups(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	groups, err := h.svc.ListGroups(r.Context(), orgID, includeInactiveParam(r))
	if err != nil {
		httpjson.Error(w, http.StatusInternalServerError, "gruplar alınamadı")
		return
	}
	out := make([]calcGroupResponse, len(groups))
	for i, g := range groups {
		out[i] = toCalcGroupResponse(g)
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"groups": out})
}

type upsertCalcGroupRequest struct {
	Slug        string `json:"slug"`
	Name        string `json:"name"`
	Description string `json:"description"`
	SortOrder   int    `json:"sort_order"`
	IsActive    *bool  `json:"is_active"`
}

func (h *CalcHandler) CreateGroup(w http.ResponseWriter, r *http.Request) {
	var req upsertCalcGroupRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	g, err := h.svc.CreateGroup(r.Context(), orgID, service.CalcGroupInput{
		Slug: req.Slug, Name: req.Name, Description: req.Description, SortOrder: req.SortOrder,
	})
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusCreated, toCalcGroupResponse(*g))
}

func (h *CalcHandler) UpdateGroup(w http.ResponseWriter, r *http.Request) {
	var req upsertCalcGroupRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	isActive := true
	if req.IsActive != nil {
		isActive = *req.IsActive
	}
	g, err := h.svc.UpdateGroup(r.Context(), chi.URLParam(r, "id"), orgID, service.CalcGroupInput{
		Slug: req.Slug, Name: req.Name, Description: req.Description, SortOrder: req.SortOrder,
	}, isActive)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toCalcGroupResponse(*g))
}

// ---------- Kategoriler ----------

type calcCategoryResponse struct {
	ID          string  `json:"id"`
	GroupID     string  `json:"group_id"`
	GroupSlug   string  `json:"group_slug,omitempty"`
	GroupName   string  `json:"group_name,omitempty"`
	Slug        string  `json:"slug"`
	Name        string  `json:"name"`
	Description string  `json:"description"`
	ImageFileID *string `json:"image_file_id,omitempty"`
	SortOrder   int     `json:"sort_order"`
	IsActive    bool    `json:"is_active"`
}

func toCalcCategoryResponse(c domain.CalcCategory) calcCategoryResponse {
	return calcCategoryResponse{
		ID: c.ID, GroupID: c.GroupID, GroupSlug: c.GroupSlug, GroupName: c.GroupLabel,
		Slug: c.Slug, Name: c.Name, Description: c.Description, ImageFileID: c.ImageFileID,
		SortOrder: c.SortOrder, IsActive: c.IsActive,
	}
}

// calcGroupWithCategoriesResponse, web/mobil "grup seç -> kategori seç"
// kaskadı için gruplanmış görünümdür (BYZ get_calculation_categories_grouped
// ile aynı şekil).
type calcGroupWithCategoriesResponse struct {
	ID         string                 `json:"id"`
	Slug       string                 `json:"slug"`
	Name       string                 `json:"name"`
	Categories []calcCategoryResponse `json:"categories"`
}

// ListCategories, ?group_id= verilmişse yalnızca o gruptaki kategorileri
// (admin düzenleme ekranı için), verilmemişse TÜM aktif grupları
// kategorileriyle birlikte gruplanmış döner (Metraj Hesapla paneli için).
func (h *CalcHandler) ListCategories(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	if groupID := r.URL.Query().Get("group_id"); groupID != "" {
		cats, err := h.svc.ListCategoriesByGroup(r.Context(), groupID, orgID, includeInactiveParam(r))
		if err != nil {
			h.writeError(w, err)
			return
		}
		out := make([]calcCategoryResponse, len(cats))
		for i, c := range cats {
			out[i] = toCalcCategoryResponse(c)
		}
		httpjson.Write(w, http.StatusOK, map[string]any{"categories": out})
		return
	}

	cats, err := h.svc.ListCategoriesForOrg(r.Context(), orgID)
	if err != nil {
		httpjson.Error(w, http.StatusInternalServerError, "kategoriler alınamadı")
		return
	}
	groupOrder := make([]string, 0)
	groups := map[string]*calcGroupWithCategoriesResponse{}
	for _, c := range cats {
		g, ok := groups[c.GroupID]
		if !ok {
			g = &calcGroupWithCategoriesResponse{ID: c.GroupID, Slug: c.GroupSlug, Name: c.GroupLabel}
			groups[c.GroupID] = g
			groupOrder = append(groupOrder, c.GroupID)
		}
		g.Categories = append(g.Categories, toCalcCategoryResponse(c))
	}
	out := make([]calcGroupWithCategoriesResponse, len(groupOrder))
	for i, gid := range groupOrder {
		out[i] = *groups[gid]
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"groups": out})
}

type upsertCalcCategoryRequest struct {
	GroupID     string  `json:"group_id"`
	Slug        string  `json:"slug"`
	Name        string  `json:"name"`
	Description string  `json:"description"`
	ImageFileID *string `json:"image_file_id"`
	SortOrder   int     `json:"sort_order"`
	IsActive    *bool   `json:"is_active"`
}

func (h *CalcHandler) CreateCategory(w http.ResponseWriter, r *http.Request) {
	var req upsertCalcCategoryRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	c, err := h.svc.CreateCategory(r.Context(), orgID, service.CalcCategoryInput{
		GroupID: req.GroupID, Slug: req.Slug, Name: req.Name, Description: req.Description,
		ImageFileID: req.ImageFileID, SortOrder: req.SortOrder,
	})
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusCreated, toCalcCategoryResponse(*c))
}

func (h *CalcHandler) UpdateCategory(w http.ResponseWriter, r *http.Request) {
	var req upsertCalcCategoryRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	isActive := true
	if req.IsActive != nil {
		isActive = *req.IsActive
	}
	c, err := h.svc.UpdateCategory(r.Context(), chi.URLParam(r, "id"), orgID, service.CalcCategoryInput{
		GroupID: req.GroupID, Slug: req.Slug, Name: req.Name, Description: req.Description,
		ImageFileID: req.ImageFileID, SortOrder: req.SortOrder,
	}, isActive)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toCalcCategoryResponse(*c))
}

// ---------- Reçete Kalemleri (admin) ----------

type calcRecipeItemResponse struct {
	ID                 string  `json:"id"`
	CategoryID         string  `json:"category_id"`
	ProductID          *string `json:"product_id,omitempty"`
	MaterialName       string  `json:"material_name"`
	Unit               string  `json:"unit"`
	CalculationType    string  `json:"calculation_type"`
	QuantityPerM2      string  `json:"quantity_per_m2"`
	QuantityPerMeter   string  `json:"quantity_per_meter"`
	FixedQuantity      string  `json:"fixed_quantity"`
	WastePercent       string  `json:"waste_percent"`
	RoundingType       string  `json:"rounding_type"`
	MinQuantity        *string `json:"min_quantity,omitempty"`
	PackageSize        *string `json:"package_size,omitempty"`
	ReferenceUnitPrice string  `json:"reference_unit_price"`
	GroupName          string  `json:"group_name"`
	SortOrder          int     `json:"sort_order"`
	IsActive           bool    `json:"is_active"`
	Notes              *string `json:"notes,omitempty"`
}

func decimalPtrToStringPtr(d *decimal.Decimal) *string {
	if d == nil {
		return nil
	}
	s := d.String()
	return &s
}

func toCalcRecipeItemResponse(i domain.CalcRecipeItem) calcRecipeItemResponse {
	return calcRecipeItemResponse{
		ID: i.ID, CategoryID: i.CategoryID, ProductID: i.ProductID, MaterialName: i.MaterialName, Unit: i.Unit,
		CalculationType: i.CalculationType, QuantityPerM2: i.QuantityPerM2.String(), QuantityPerMeter: i.QuantityPerMeter.String(),
		FixedQuantity: i.FixedQuantity.String(), WastePercent: i.WastePercent.String(), RoundingType: i.RoundingType,
		MinQuantity: decimalPtrToStringPtr(i.MinQuantity), PackageSize: decimalPtrToStringPtr(i.PackageSize),
		ReferenceUnitPrice: i.ReferenceUnitPrice.String(), GroupName: i.GroupName, SortOrder: i.SortOrder,
		IsActive: i.IsActive, Notes: i.Notes,
	}
}

func (h *CalcHandler) ListRecipeItems(w http.ResponseWriter, r *http.Request) {
	categoryID := r.URL.Query().Get("category_id")
	if categoryID == "" {
		httpjson.Error(w, http.StatusBadRequest, "category_id zorunludur")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	items, err := h.svc.ListRecipeItemsAdmin(r.Context(), categoryID, orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	out := make([]calcRecipeItemResponse, len(items))
	for i, it := range items {
		out[i] = toCalcRecipeItemResponse(it)
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"items": out})
}

type upsertCalcRecipeItemRequest struct {
	CategoryID         string  `json:"category_id"`
	ProductID          *string `json:"product_id"`
	MaterialName       string  `json:"material_name"`
	Unit               string  `json:"unit"`
	CalculationType    string  `json:"calculation_type"`
	QuantityPerM2      string  `json:"quantity_per_m2"`
	QuantityPerMeter   string  `json:"quantity_per_meter"`
	FixedQuantity      string  `json:"fixed_quantity"`
	WastePercent       string  `json:"waste_percent"`
	RoundingType       string  `json:"rounding_type"`
	MinQuantity        *string `json:"min_quantity"`
	PackageSize        *string `json:"package_size"`
	ReferenceUnitPrice string  `json:"reference_unit_price"`
	GroupName          string  `json:"group_name"`
	SortOrder          int     `json:"sort_order"`
	IsActive           *bool   `json:"is_active"`
	Notes              *string `json:"notes"`
}

func (req upsertCalcRecipeItemRequest) toInput() (service.CalcRecipeItemInput, error) {
	qm2, err := parseOptionalDecimal(&req.QuantityPerM2, "quantity_per_m2")
	if err != nil {
		return service.CalcRecipeItemInput{}, err
	}
	qm, err := parseOptionalDecimal(&req.QuantityPerMeter, "quantity_per_meter")
	if err != nil {
		return service.CalcRecipeItemInput{}, err
	}
	fq, err := parseOptionalDecimal(&req.FixedQuantity, "fixed_quantity")
	if err != nil {
		return service.CalcRecipeItemInput{}, err
	}
	wp, err := parseOptionalDecimal(&req.WastePercent, "waste_percent")
	if err != nil {
		return service.CalcRecipeItemInput{}, err
	}
	rp, err := parseOptionalDecimal(&req.ReferenceUnitPrice, "reference_unit_price")
	if err != nil {
		return service.CalcRecipeItemInput{}, err
	}
	minQ, err := parseNullableDecimal(req.MinQuantity, "min_quantity")
	if err != nil {
		return service.CalcRecipeItemInput{}, err
	}
	pkg, err := parseNullableDecimal(req.PackageSize, "package_size")
	if err != nil {
		return service.CalcRecipeItemInput{}, err
	}
	return service.CalcRecipeItemInput{
		CategoryID: req.CategoryID, ProductID: req.ProductID, MaterialName: req.MaterialName, Unit: req.Unit,
		CalculationType: req.CalculationType, QuantityPerM2: qm2, QuantityPerMeter: qm, FixedQuantity: fq,
		WastePercent: wp, RoundingType: req.RoundingType, MinQuantity: minQ, PackageSize: pkg,
		ReferenceUnitPrice: rp, GroupName: req.GroupName, SortOrder: req.SortOrder, Notes: req.Notes,
	}, nil
}

func (h *CalcHandler) CreateRecipeItem(w http.ResponseWriter, r *http.Request) {
	var req upsertCalcRecipeItemRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	in, err := req.toInput()
	if err != nil {
		httpjson.Error(w, http.StatusBadRequest, err.Error())
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	item, err := h.svc.CreateRecipeItem(r.Context(), orgID, in)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusCreated, toCalcRecipeItemResponse(*item))
}

func (h *CalcHandler) UpdateRecipeItem(w http.ResponseWriter, r *http.Request) {
	var req upsertCalcRecipeItemRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	in, err := req.toInput()
	if err != nil {
		httpjson.Error(w, http.StatusBadRequest, err.Error())
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	isActive := true
	if req.IsActive != nil {
		isActive = *req.IsActive
	}
	item, err := h.svc.UpdateRecipeItem(r.Context(), chi.URLParam(r, "id"), orgID, in, isActive)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toCalcRecipeItemResponse(*item))
}

func (h *CalcHandler) DeleteRecipeItem(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	if err := h.svc.DeleteRecipeItem(r.Context(), chi.URLParam(r, "id"), orgID); err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, map[string]bool{"ok": true})
}

// ---------- Hesaplama ----------

type calcRunRequest struct {
	CategoryID string  `json:"category_id"`
	Area       *string `json:"area"`
	Width      *string `json:"width"`
	Height     *string `json:"height"`
	Perimeter  *string `json:"perimeter"`
	PitchDeg   *string `json:"pitch_deg"`
}

type calcCategoryRefResponse struct {
	ID   string `json:"id"`
	Slug string `json:"slug"`
	Name string `json:"name"`
}

type calcInputResponse struct {
	FootprintArea string  `json:"footprint_area"`
	EffectiveArea string  `json:"effective_area"`
	Perimeter     *string `json:"perimeter"`
}

type calcResultItemResponse struct {
	RecipeItemID string  `json:"recipe_item_id"`
	MaterialName string  `json:"material_name"`
	Unit         string  `json:"unit"`
	Quantity     string  `json:"quantity"`
	ProductID    *string `json:"product_id,omitempty"`
	UnitPrice    string  `json:"unit_price"`
	LineTotal    string  `json:"line_total"`
	GroupName    string  `json:"group_name,omitempty"`

	// CalculationType/Factor/WastePercent/RoundingType: bu kalemde
	// GERÇEKTEN kullanılan katsayı/kural -- frontend, teklife eklerken
	// bunları calc_snapshot içine (offer_revision_items.calc_snapshot)
	// dondurur.
	CalculationType string `json:"calculation_type"`
	Factor          string `json:"factor"`
	WastePercent    string `json:"waste_percent"`
	RoundingType    string `json:"rounding_type"`
}

type calcWarningResponse struct {
	ItemID  string `json:"item_id,omitempty"`
	Code    string `json:"code"`
	Message string `json:"message"`
}

type calcRunResponse struct {
	Category  calcCategoryRefResponse  `json:"category"`
	Input     calcInputResponse        `json:"input"`
	Items     []calcResultItemResponse `json:"items"`
	TotalCost string                   `json:"total_cost"`
	Warnings  []calcWarningResponse    `json:"warnings"`
}

func (h *CalcHandler) Run(w http.ResponseWriter, r *http.Request) {
	var req calcRunRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	if strings.TrimSpace(req.CategoryID) == "" {
		httpjson.Error(w, http.StatusBadRequest, "category_id zorunludur")
		return
	}
	area, err := parseNullableDecimal(req.Area, "area")
	if err != nil {
		httpjson.Error(w, http.StatusBadRequest, err.Error())
		return
	}
	width, err := parseNullableDecimal(req.Width, "width")
	if err != nil {
		httpjson.Error(w, http.StatusBadRequest, err.Error())
		return
	}
	height, err := parseNullableDecimal(req.Height, "height")
	if err != nil {
		httpjson.Error(w, http.StatusBadRequest, err.Error())
		return
	}
	perimeter, err := parseNullableDecimal(req.Perimeter, "perimeter")
	if err != nil {
		httpjson.Error(w, http.StatusBadRequest, err.Error())
		return
	}
	pitch, err := parseNullableDecimal(req.PitchDeg, "pitch_deg")
	if err != nil {
		httpjson.Error(w, http.StatusBadRequest, err.Error())
		return
	}

	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	result, err := h.svc.Run(r.Context(), orgID, service.CalcRunInput{
		CategoryID: req.CategoryID,
		CalcInput: domain.CalcInput{
			Area: area, Width: width, Height: height, Perimeter: perimeter, PitchDeg: pitch,
		},
	})
	if err != nil {
		h.writeError(w, err)
		return
	}

	items := make([]calcResultItemResponse, len(result.Items))
	for i, it := range result.Items {
		items[i] = calcResultItemResponse{
			RecipeItemID: it.RecipeItemID, MaterialName: it.MaterialName, Unit: it.Unit,
			Quantity: it.Quantity.String(), ProductID: it.ProductID, UnitPrice: it.UnitPrice.StringFixed(2),
			LineTotal: it.LineTotal.StringFixed(2), GroupName: it.GroupName,
			CalculationType: it.CalculationType, Factor: it.Factor.String(),
			WastePercent: it.WastePercent.String(), RoundingType: it.RoundingType,
		}
	}
	warnings := make([]calcWarningResponse, len(result.Warnings))
	for i, wr := range result.Warnings {
		warnings[i] = calcWarningResponse{ItemID: wr.ItemID, Code: wr.Code, Message: wr.Message}
	}
	var perimeterStr *string
	if result.Geometry.Perimeter != nil {
		s := result.Geometry.Perimeter.String()
		perimeterStr = &s
	}

	httpjson.Write(w, http.StatusOK, calcRunResponse{
		Category: calcCategoryRefResponse{ID: result.Category.ID, Slug: result.Category.Slug, Name: result.Category.Name},
		Input: calcInputResponse{
			FootprintArea: result.Geometry.FootprintArea.String(),
			EffectiveArea: result.Geometry.EffectiveArea.String(),
			Perimeter:     perimeterStr,
		},
		Items: items, TotalCost: result.TotalCost.StringFixed(2), Warnings: warnings,
	})
}

// ---------- Yardımcılar ----------

func parseNullableDecimal(s *string, field string) (*decimal.Decimal, error) {
	if s == nil || strings.TrimSpace(*s) == "" {
		return nil, nil
	}
	v, err := decimal.NewFromString(strings.TrimSpace(*s))
	if err != nil {
		return nil, errors.New(field + " geçerli bir sayı olmalı")
	}
	return &v, nil
}

// parseOptionalDecimal, boş/nil girildiğinde 0 kabul eder (zorunlu-ama-
// varsayılanlı sayısal alanlar için -- quantity_per_m2 gibi).
func parseOptionalDecimal(s *string, field string) (decimal.Decimal, error) {
	v, err := parseNullableDecimal(s, field)
	if err != nil {
		return decimal.Zero, err
	}
	if v == nil {
		return decimal.Zero, nil
	}
	return *v, nil
}

func (h *CalcHandler) writeError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, domain.ErrNotFound):
		httpjson.Error(w, http.StatusNotFound, "kayıt bulunamadı")
	case isInternalError(err):
		// Ham veritabanı metni istemciye sızmasın (UNIQUE ihlalleri
		// mapCalcWriteError'da zaten anlamlı mesaja çevrilir).
		writeInternalError(w, err)
	default:
		httpjson.Error(w, http.StatusBadRequest, err.Error())
	}
}
