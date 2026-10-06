package handler

import (
	"encoding/json"
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

// canSeeOfferInternalPricing/canManageOfferInternalPricing, GÜVENLİK
// SINIRININ tam da kendisidir (bkz. migration 0040 dosya başı yorumu):
//   - toOfferResponse/toOfferRevisionResponse (bu dosyanın geri kalanı, VE
//     PublicOfferHandler'ın TEK kullandığı fonksiyon) internal_pricing
//     alanını ASLA doldurmaz -- güvenli/sızdırmaz VARSAYILAN budur.
//   - attachInternalPricing, personel uçlarında (List/Get/Create/Update/
//     Revise/ListRevisions/GetRevision) toOfferResponse'un SONUCUNU mutate
//     eden AYRI, opt-in bir adımdır -- yalnızca bu iki fonksiyon true
//     dönerse çağrılır. PublicOfferHandler bu iki fonksiyonu HİÇ ÇAĞIRMAZ,
//     dolayısıyla public/paylaşım yolunda hiçbir kod yolu bu alana
//     dokunmaz (bağlama/izin durumuna bağlı bir "if" değil, tamamen AYRI
//     bir fonksiyon çağrısı).
func canSeeOfferInternalPricing(r *http.Request) bool {
	return hasOfferPermission(r, domain.PermOffersInternalPricingRead)
}

func canManageOfferInternalPricing(r *http.Request) bool {
	return hasOfferPermission(r, domain.PermOffersInternalPricingManage)
}

func hasOfferPermission(r *http.Request, code string) bool {
	authz, ok := middleware.AuthzContextFromRequest(r.Context())
	return ok && authz.HasPermission(code)
}

type OfferHandler struct {
	svc *service.OfferService
}

func NewOfferHandler(svc *service.OfferService) *OfferHandler {
	return &OfferHandler{svc: svc}
}

type offerItemResponse struct {
	ID          string  `json:"id"`
	ProductID   *string `json:"product_id"`
	ProductName string  `json:"product_name"`
	Quantity    float64 `json:"quantity"`
	UnitPrice   float64 `json:"unit_price"`
	LineTotal   float64 `json:"line_total"`

	// Unit/SectionLabel/CalcCategoryID/CalcSnapshot: Metraj Hesaplama
	// entegrasyonu (Faz M2) -- serbest kalemlerde Unit="" ve diğerleri
	// null döner. CalcSnapshot ham JSON olarak geçirilir (sunucu
	// tarafında yorumlanmaz, hesap anındaki dondurulmuş görünümdür).
	Unit           string          `json:"unit,omitempty"`
	SectionLabel   *string         `json:"section_label,omitempty"`
	CalcCategoryID *string         `json:"calc_category_id,omitempty"`
	CalcSnapshot   json.RawMessage `json:"calc_snapshot,omitempty"`

	// InternalPricing: bkz. bu dosyanın başındaki canSeeOfferInternalPricing
	// yorumu -- toOfferResponse/toOfferRevisionResponse bunu ASLA doldurmaz,
	// yalnızca attachInternalPricing (personel uçlarında, izin varsa) SONRADAN
	// ekler. omitempty: izin yoksa/public yolda alan JSON'da HİÇ GÖRÜNMEZ.
	InternalPricing *offerItemInternalPricingResponse `json:"internal_pricing,omitempty"`
}

// offerItemInternalPricingResponse, İç Taşeron Fiyatlama (migration 0040)
// için personel-only ek veridir. ExpectedProfit/EffectiveMarkupPercent
// PERSIST EDİLMEZ (bkz. domain.OfferItem.ExpectedProfit/
// EffectiveMarkupPercent), burada her yanıt için canlı hesaplanır.
type offerItemInternalPricingResponse struct {
	Cost                   float64  `json:"cost"`
	PricingMode            string   `json:"pricing_mode"`
	MarkupPercent          *float64 `json:"markup_percent,omitempty"`
	ExpectedProfit         float64  `json:"expected_profit"`
	EffectiveMarkupPercent *float64 `json:"effective_markup_percent,omitempty"`
}

// attachInternalPricing, toOfferResponse'un GÜVENLİ/sızdırmaz sonucunu
// SONRADAN, YALNIZCA çağıran bunu bilinçli olarak yaptığında (bkz. dosya
// başı yorumu) mutate eder. o.Items ile resp.Items HER ZAMAN aynı sırada
// (toOfferResponse'un ürettiği sıra) -- index eşleşmesi burada güvenlidir.
func attachInternalPricing(resp *offerResponse, o domain.Offer) {
	for i, it := range o.Items {
		if it.InternalSubcontractCost == nil || i >= len(resp.Items) {
			continue
		}
		mode := ""
		if it.PricingMode != nil {
			mode = *it.PricingMode
		}
		profit := 0.0
		if p := it.ExpectedProfit(); p != nil {
			profit = *p
		}
		resp.Items[i].InternalPricing = &offerItemInternalPricingResponse{
			Cost:                   *it.InternalSubcontractCost,
			PricingMode:            mode,
			MarkupPercent:          it.MarkupPercent,
			ExpectedProfit:         profit,
			EffectiveMarkupPercent: it.EffectiveMarkupPercent(),
		}
	}
}

type offerResponse struct {
	ID              string              `json:"id"`
	OfferNo         string              `json:"offer_no"`
	RevisionNo      int                 `json:"revision_no"`
	CustomerID      *string             `json:"customer_id"`
	CustomerName    string              `json:"customer_name"`
	CustomerPhone   string              `json:"customer_phone"`
	CustomerEmail   string              `json:"customer_email"`
	CustomerAddress string              `json:"customer_address"`
	OfferDate       string              `json:"offer_date"`
	ValidUntil      *string             `json:"valid_until"`
	Subtotal        float64             `json:"subtotal"`
	VatRate         float64             `json:"vat_rate"`
	VatAmount       float64             `json:"vat_amount"`
	GrandTotal      float64             `json:"grand_total"`
	Notes           string              `json:"notes"`
	Status          string              `json:"status"`
	IsPassive       bool                `json:"is_passive"`
	Items           []offerItemResponse `json:"items,omitempty"`
}

const dateLayout = "2006-01-02"

func toOfferResponse(o domain.Offer) offerResponse {
	resp := offerResponse{
		ID:              o.ID,
		OfferNo:         o.OfferNo,
		RevisionNo:      o.RevisionNo,
		CustomerID:      o.CustomerID,
		CustomerName:    o.CustomerName,
		CustomerPhone:   o.CustomerPhone,
		CustomerEmail:   o.CustomerEmail,
		CustomerAddress: o.CustomerAddress,
		OfferDate:       o.OfferDate.Format(dateLayout),
		Subtotal:        o.Subtotal,
		VatRate:         o.VatRate,
		VatAmount:       o.VatAmount,
		GrandTotal:      o.GrandTotal,
		Notes:           o.Notes,
		Status:          o.Status,
		IsPassive:       o.IsPassive,
	}
	if o.ValidUntil != nil {
		s := o.ValidUntil.Format(dateLayout)
		resp.ValidUntil = &s
	}
	if o.Items != nil {
		resp.Items = make([]offerItemResponse, len(o.Items))
		for i, it := range o.Items {
			resp.Items[i] = offerItemResponse{
				ID:             it.ID,
				ProductID:      it.ProductID,
				ProductName:    it.ProductName,
				Quantity:       it.Quantity,
				UnitPrice:      it.UnitPrice,
				LineTotal:      it.LineTotal,
				Unit:           it.Unit,
				SectionLabel:   it.SectionLabel,
				CalcCategoryID: it.CalcCategoryID,
				CalcSnapshot:   it.CalcSnapshot,
			}
		}
	}
	return resp
}

func (h *OfferHandler) List(w http.ResponseWriter, r *http.Request) {
	isPassive := r.URL.Query().Get("filter") == "pasif"
	page, _ := strconv.Atoi(r.URL.Query().Get("page"))
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	customerID := r.URL.Query().Get("customer_id")
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	result, err := h.svc.List(r.Context(), orgID, isPassive, page, limit, customerID)
	if err != nil {
		httpjson.Error(w, http.StatusInternalServerError, "teklifler alınamadı")
		return
	}
	seeInternal := canSeeOfferInternalPricing(r)
	offers := make([]offerResponse, len(result.Offers))
	for i, o := range result.Offers {
		resp := toOfferResponse(o)
		if seeInternal {
			attachInternalPricing(&resp, o)
		}
		offers[i] = resp
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"offers": offers, "total": result.Total})
}

func (h *OfferHandler) Get(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	o, err := h.svc.Get(r.Context(), chi.URLParam(r, "id"), orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	resp := toOfferResponse(*o)
	if canSeeOfferInternalPricing(r) {
		attachInternalPricing(&resp, *o)
	}
	httpjson.Write(w, http.StatusOK, resp)
}

type createOfferItemRequest struct {
	ProductID   *string `json:"product_id"`
	ProductName string  `json:"product_name"`
	Quantity    float64 `json:"quantity"`
	UnitPrice   float64 `json:"unit_price"`

	// Metraj Hesaplama entegrasyonu (Faz M2) -- "Teklife Ekle" bu dört
	// alanı da gönderir; serbest kalemlerde hepsi boş/nil bırakılır.
	Unit           string          `json:"unit"`
	SectionLabel   *string         `json:"section_label"`
	CalcCategoryID *string         `json:"calc_category_id"`
	CalcSnapshot   json.RawMessage `json:"calc_snapshot"`

	// İç Taşeron Fiyatlama (migration 0040) -- offers.internal_pricing.manage
	// izni olmayan bir istemci bunları gönderse bile service katmanında
	// (computeOfferTotals) SESSİZCE temizlenir, burada AYRICA kontrol
	// edilmez (tek doğrulama noktası, bkz. o fonksiyonun yorumu).
	InternalSubcontractCost *float64 `json:"internal_subcontract_cost"`
	PricingMode             string   `json:"pricing_mode"`
	MarkupPercent           *float64 `json:"markup_percent"`
}

type createOfferRequest struct {
	CustomerID      *string                  `json:"customer_id"`
	CustomerName    string                   `json:"customer_name"`
	CustomerPhone   string                   `json:"customer_phone"`
	CustomerEmail   string                   `json:"customer_email"`
	CustomerAddress string                   `json:"customer_address"`
	ValidUntil      *string                  `json:"valid_until"`
	Notes           string                   `json:"notes"`
	VatRate         *float64                 `json:"vat_rate"`
	Items           []createOfferItemRequest `json:"items"`
}

func parseValidUntil(raw *string) *time.Time {
	if raw == nil || *raw == "" {
		return nil
	}
	t, err := time.Parse(dateLayout, *raw)
	if err != nil {
		return nil
	}
	return &t
}

func toOfferItemInputs(items []createOfferItemRequest) []service.OfferItemInput {
	out := make([]service.OfferItemInput, len(items))
	for i, it := range items {
		out[i] = service.OfferItemInput{
			ProductID:               it.ProductID,
			ProductName:             it.ProductName,
			Quantity:                it.Quantity,
			UnitPrice:               it.UnitPrice,
			Unit:                    it.Unit,
			SectionLabel:            it.SectionLabel,
			CalcCategoryID:          it.CalcCategoryID,
			CalcSnapshot:            it.CalcSnapshot,
			InternalSubcontractCost: it.InternalSubcontractCost,
			PricingMode:             it.PricingMode,
			MarkupPercent:           it.MarkupPercent,
		}
	}
	return out
}

func (h *OfferHandler) Create(w http.ResponseWriter, r *http.Request) {
	var req createOfferRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}

	userID, _ := middleware.UserIDFromContext(r.Context())
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	canManageInternal := canManageOfferInternalPricing(r)

	o, err := h.svc.Create(r.Context(), service.CreateOfferInput{
		CustomerID:               req.CustomerID,
		CustomerName:             req.CustomerName,
		CustomerPhone:            req.CustomerPhone,
		CustomerEmail:            req.CustomerEmail,
		CustomerAddress:          req.CustomerAddress,
		ValidUntil:               parseValidUntil(req.ValidUntil),
		Notes:                    req.Notes,
		VatRate:                  req.VatRate,
		Items:                    toOfferItemInputs(req.Items),
		UserID:                   userID,
		OrganizationID:           orgID,
		CanManageInternalPricing: canManageInternal,
	})
	if err != nil {
		h.writeError(w, err)
		return
	}
	resp := toOfferResponse(*o)
	if canManageInternal {
		attachInternalPricing(&resp, *o)
	}
	httpjson.Write(w, http.StatusCreated, resp)
}

func (h *OfferHandler) Update(w http.ResponseWriter, r *http.Request) {
	var req createOfferRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	canManageInternal := canManageOfferInternalPricing(r)
	o, err := h.svc.Update(r.Context(), chi.URLParam(r, "id"), orgID, service.UpdateOfferInput{
		CustomerID:               req.CustomerID,
		CustomerName:             req.CustomerName,
		CustomerPhone:            req.CustomerPhone,
		CustomerEmail:            req.CustomerEmail,
		CustomerAddress:          req.CustomerAddress,
		ValidUntil:               parseValidUntil(req.ValidUntil),
		Notes:                    req.Notes,
		VatRate:                  req.VatRate,
		Items:                    toOfferItemInputs(req.Items),
		UserID:                   userID,
		CanManageInternalPricing: canManageInternal,
	})
	if err != nil {
		h.writeError(w, err)
		return
	}
	resp := toOfferResponse(*o)
	if canManageInternal {
		attachInternalPricing(&resp, *o)
	}
	httpjson.Write(w, http.StatusOK, resp)
}

func (h *OfferHandler) Revise(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	o, err := h.svc.Revise(r.Context(), chi.URLParam(r, "id"), orgID, userID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	resp := toOfferResponse(*o)
	if canSeeOfferInternalPricing(r) {
		attachInternalPricing(&resp, *o)
	}
	httpjson.Write(w, http.StatusCreated, resp)
}

type offerRevisionResponse struct {
	ID              string              `json:"id"`
	OfferID         string              `json:"offer_id"`
	RevisionNo      int                 `json:"revision_no"`
	CustomerID      *string             `json:"customer_id"`
	CustomerName    string              `json:"customer_name"`
	CustomerPhone   string              `json:"customer_phone"`
	CustomerEmail   string              `json:"customer_email"`
	CustomerAddress string              `json:"customer_address"`
	ValidUntil      *string             `json:"valid_until"`
	Subtotal        float64             `json:"subtotal"`
	VatRate         float64             `json:"vat_rate"`
	VatAmount       float64             `json:"vat_amount"`
	GrandTotal      float64             `json:"grand_total"`
	Currency        string              `json:"currency"`
	Notes           string              `json:"notes"`
	Status          string              `json:"status"`
	CreatedBy       *string             `json:"created_by"`
	CreatedAt       string              `json:"created_at"`
	Items           []offerItemResponse `json:"items,omitempty"`
}

func toOfferRevisionResponse(r domain.OfferRevision) offerRevisionResponse {
	resp := offerRevisionResponse{
		ID:              r.ID,
		OfferID:         r.OfferID,
		RevisionNo:      r.RevisionNo,
		CustomerID:      r.CustomerID,
		CustomerName:    r.CustomerName,
		CustomerPhone:   r.CustomerPhone,
		CustomerEmail:   r.CustomerEmail,
		CustomerAddress: r.CustomerAddress,
		Subtotal:        r.Subtotal,
		VatRate:         r.VatRate,
		VatAmount:       r.VatAmount,
		GrandTotal:      r.GrandTotal,
		Currency:        r.Currency,
		Notes:           r.Notes,
		Status:          r.Status,
		CreatedBy:       r.CreatedBy,
		CreatedAt:       r.CreatedAt.Format("2006-01-02T15:04:05Z07:00"),
	}
	if r.ValidUntil != nil {
		s := r.ValidUntil.Format(dateLayout)
		resp.ValidUntil = &s
	}
	if r.Items != nil {
		resp.Items = make([]offerItemResponse, len(r.Items))
		for i, it := range r.Items {
			resp.Items[i] = offerItemResponse{
				ID:             it.ID,
				ProductID:      it.ProductID,
				ProductName:    it.ProductName,
				Quantity:       it.Quantity,
				UnitPrice:      it.UnitPrice,
				LineTotal:      it.LineTotal,
				Unit:           it.Unit,
				SectionLabel:   it.SectionLabel,
				CalcCategoryID: it.CalcCategoryID,
				CalcSnapshot:   it.CalcSnapshot,
			}
		}
	}
	return resp
}

// attachRevisionInternalPricing: bkz. attachInternalPricing -- AYNI
// güvenlik ilkesi, offerRevisionResponse için (ListRevisions/GetRevision
// personel uçları, teklifin hiçbir revizyon-detay yanıtı public/paylaşım
// yolunda KULLANILMAZ, bkz. public_offer_handler.go -- yalnızca
// toOfferResponse çağrılır).
func attachRevisionInternalPricing(resp *offerRevisionResponse, rev domain.OfferRevision) {
	for i, it := range rev.Items {
		if it.InternalSubcontractCost == nil || i >= len(resp.Items) {
			continue
		}
		mode := ""
		if it.PricingMode != nil {
			mode = *it.PricingMode
		}
		profit := 0.0
		if p := it.ExpectedProfit(); p != nil {
			profit = *p
		}
		resp.Items[i].InternalPricing = &offerItemInternalPricingResponse{
			Cost:                   *it.InternalSubcontractCost,
			PricingMode:            mode,
			MarkupPercent:          it.MarkupPercent,
			ExpectedProfit:         profit,
			EffectiveMarkupPercent: it.EffectiveMarkupPercent(),
		}
	}
}

func (h *OfferHandler) ListRevisions(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	revisions, err := h.svc.ListRevisions(r.Context(), chi.URLParam(r, "id"), orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	seeInternal := canSeeOfferInternalPricing(r)
	out := make([]offerRevisionResponse, len(revisions))
	for i, rev := range revisions {
		resp := toOfferRevisionResponse(rev)
		if seeInternal {
			attachRevisionInternalPricing(&resp, rev)
		}
		out[i] = resp
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"revisions": out})
}

func (h *OfferHandler) GetRevision(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	rev, err := h.svc.GetRevision(r.Context(), chi.URLParam(r, "revisionId"), orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	resp := toOfferRevisionResponse(*rev)
	if canSeeOfferInternalPricing(r) {
		attachRevisionInternalPricing(&resp, *rev)
	}
	httpjson.Write(w, http.StatusOK, resp)
}

type updateStatusRequest struct {
	Status string `json:"status"`
}

func (h *OfferHandler) UpdateStatus(w http.ResponseWriter, r *http.Request) {
	var req updateStatusRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	o, err := h.svc.UpdateStatus(r.Context(), chi.URLParam(r, "id"), orgID, req.Status, userID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toOfferResponse(*o))
}

func (h *OfferHandler) TogglePassive(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	if err := h.svc.TogglePassive(r.Context(), chi.URLParam(r, "id"), orgID, userID); err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, map[string]bool{"ok": true})
}

func (h *OfferHandler) Delete(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	if err := h.svc.Delete(r.Context(), chi.URLParam(r, "id"), orgID); err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, map[string]bool{"ok": true})
}

type sendOfferEmailRequest struct {
	To      string `json:"to"`
	Subject string `json:"subject"`
	Message string `json:"message"`
}

func (h *OfferHandler) SendEmail(w http.ResponseWriter, r *http.Request) {
	var req sendOfferEmailRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	_, err := h.svc.SendOfferEmail(r.Context(), chi.URLParam(r, "id"), orgID, userID, service.SendOfferEmailInput{
		To: req.To, Subject: req.Subject, Message: req.Message,
	})
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, map[string]bool{"ok": true})
}

type createShareLinkRequest struct {
	// ExpiresIn: "7d" | "30d" | "" (boş = süresiz).
	ExpiresIn string `json:"expires_in"`
}

type shareLinkResponse struct {
	ID         string  `json:"id"`
	OfferID    string  `json:"offer_id"`
	RevisionID string  `json:"revision_id"`
	Token      string  `json:"token"`
	CreatedBy  *string `json:"created_by"`
	CreatedAt  string  `json:"created_at"`
	ExpiresAt  *string `json:"expires_at"`
	RevokedAt  *string `json:"revoked_at"`
	IsActive   bool    `json:"is_active"`
}

const rfc3339 = "2006-01-02T15:04:05Z07:00"

func toShareLinkResponse(l domain.OfferShareLink) shareLinkResponse {
	resp := shareLinkResponse{
		ID: l.ID, OfferID: l.OfferID, RevisionID: l.RevisionID, Token: l.Token,
		CreatedBy: l.CreatedBy, CreatedAt: l.CreatedAt.Format(rfc3339),
		IsActive: l.IsActive(time.Now()),
	}
	if l.ExpiresAt != nil {
		s := l.ExpiresAt.Format(rfc3339)
		resp.ExpiresAt = &s
	}
	if l.RevokedAt != nil {
		s := l.RevokedAt.Format(rfc3339)
		resp.RevokedAt = &s
	}
	return resp
}

func (h *OfferHandler) CreateShareLink(w http.ResponseWriter, r *http.Request) {
	var req createShareLinkRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	var expiresAt *time.Time
	switch req.ExpiresIn {
	case "", "never":
		expiresAt = nil
	case "7d":
		t := time.Now().Add(7 * 24 * time.Hour)
		expiresAt = &t
	case "30d":
		t := time.Now().Add(30 * 24 * time.Hour)
		expiresAt = &t
	default:
		httpjson.Error(w, http.StatusBadRequest, "geçersiz süre seçeneği")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	link, err := h.svc.CreateShareLink(r.Context(), chi.URLParam(r, "id"), orgID, userID, expiresAt)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusCreated, toShareLinkResponse(*link))
}

func (h *OfferHandler) ListShareLinks(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	links, err := h.svc.ListShareLinks(r.Context(), chi.URLParam(r, "id"), orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	out := make([]shareLinkResponse, len(links))
	for i, l := range links {
		out[i] = toShareLinkResponse(l)
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"share_links": out})
}

func (h *OfferHandler) RevokeShareLink(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	if err := h.svc.RevokeShareLink(r.Context(), chi.URLParam(r, "linkId"), orgID, userID); err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, map[string]bool{"ok": true})
}

type offerEventResponse struct {
	ID         string         `json:"id"`
	RevisionID *string        `json:"revision_id"`
	EventType  string         `json:"event_type"`
	UserID     *string        `json:"user_id"`
	Metadata   map[string]any `json:"metadata,omitempty"`
	CreatedAt  string         `json:"created_at"`
}

func (h *OfferHandler) ListEvents(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	events, err := h.svc.ListEvents(r.Context(), chi.URLParam(r, "id"), orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	out := make([]offerEventResponse, len(events))
	for i, e := range events {
		out[i] = offerEventResponse{
			ID: e.ID, RevisionID: e.RevisionID, EventType: e.EventType, UserID: e.UserID,
			Metadata: e.Metadata, CreatedAt: e.CreatedAt.Format(rfc3339),
		}
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"events": out})
}

type emailLogResponse struct {
	ID           string  `json:"id"`
	RevisionID   string  `json:"revision_id"`
	Recipient    string  `json:"recipient"`
	Subject      string  `json:"subject"`
	Status       string  `json:"status"`
	ErrorMessage string  `json:"error_message"`
	SentBy       *string `json:"sent_by"`
	SentAt       string  `json:"sent_at"`
}

func (h *OfferHandler) ListEmailLogs(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	logs, err := h.svc.ListEmailLogs(r.Context(), chi.URLParam(r, "id"), orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	out := make([]emailLogResponse, len(logs))
	for i, l := range logs {
		out[i] = emailLogResponse{
			ID: l.ID, RevisionID: l.RevisionID, Recipient: l.Recipient, Subject: l.Subject,
			Status: l.Status, ErrorMessage: l.ErrorMessage, SentBy: l.SentBy, SentAt: l.SentAt.Format(rfc3339),
		}
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"email_logs": out})
}

func (h *OfferHandler) writeError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, domain.ErrNotFound):
		httpjson.Error(w, http.StatusNotFound, "teklif bulunamadı")
	case errors.Is(err, service.ErrOfferAccepted),
		errors.Is(err, service.ErrOfferNotEditable),
		errors.Is(err, service.ErrOfferLocked),
		errors.Is(err, service.ErrOfferCannotReturnToDraft),
		errors.Is(err, service.ErrOfferNotRevisable):
		httpjson.Error(w, http.StatusConflict, err.Error())
	case isInternalError(err):
		writeInternalError(w, err)
	default:
		httpjson.Error(w, http.StatusBadRequest, err.Error())
	}
}
