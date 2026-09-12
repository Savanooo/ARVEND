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
	"github.com/Savanooo/ARVEND/backend/internal/platform/mailer"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

type OfferHandler struct {
	svc         *service.OfferService
	settingsSvc *service.SettingsService
	frontendURL string
}

func NewOfferHandler(svc *service.OfferService, settingsSvc *service.SettingsService, frontendURL string) *OfferHandler {
	return &OfferHandler{svc: svc, settingsSvc: settingsSvc, frontendURL: frontendURL}
}

type offerItemResponse struct {
	ID          string  `json:"id"`
	ProductID   *string `json:"product_id"`
	ProductName string  `json:"product_name"`
	Quantity    float64 `json:"quantity"`
	UnitPrice   float64 `json:"unit_price"`
	LineTotal   float64 `json:"line_total"`
}

type offerResponse struct {
	ID              string              `json:"id"`
	OfferNo         string              `json:"offer_no"`
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
	ShareToken      string              `json:"share_token"`
	IsPassive       bool                `json:"is_passive"`
	Items           []offerItemResponse `json:"items,omitempty"`
}

const dateLayout = "2006-01-02"

func toOfferResponse(o domain.Offer) offerResponse {
	resp := offerResponse{
		ID:              o.ID,
		OfferNo:         o.OfferNo,
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
		ShareToken:      o.ShareToken,
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
				ID:          it.ID,
				ProductID:   it.ProductID,
				ProductName: it.ProductName,
				Quantity:    it.Quantity,
				UnitPrice:   it.UnitPrice,
				LineTotal:   it.LineTotal,
			}
		}
	}
	return resp
}

func (h *OfferHandler) List(w http.ResponseWriter, r *http.Request) {
	isPassive := r.URL.Query().Get("filter") == "pasif"
	page, _ := strconv.Atoi(r.URL.Query().Get("page"))
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	result, err := h.svc.List(r.Context(), isPassive, page, limit)
	if err != nil {
		httpjson.Error(w, http.StatusInternalServerError, "teklifler alınamadı")
		return
	}
	offers := make([]offerResponse, len(result.Offers))
	for i, o := range result.Offers {
		offers[i] = toOfferResponse(o)
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"offers": offers, "total": result.Total})
}

func (h *OfferHandler) Get(w http.ResponseWriter, r *http.Request) {
	o, err := h.svc.Get(r.Context(), chi.URLParam(r, "id"))
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toOfferResponse(*o))
}

type createOfferItemRequest struct {
	ProductID   *string `json:"product_id"`
	ProductName string  `json:"product_name"`
	Quantity    float64 `json:"quantity"`
	UnitPrice   float64 `json:"unit_price"`
}

type createOfferRequest struct {
	CustomerName    string                   `json:"customer_name"`
	CustomerPhone   string                   `json:"customer_phone"`
	CustomerEmail   string                   `json:"customer_email"`
	CustomerAddress string                   `json:"customer_address"`
	ValidUntil      *string                  `json:"valid_until"`
	Notes           string                   `json:"notes"`
	VatRate         *float64                 `json:"vat_rate"`
	Items           []createOfferItemRequest `json:"items"`
}

func (h *OfferHandler) Create(w http.ResponseWriter, r *http.Request) {
	var req createOfferRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}

	items := make([]service.OfferItemInput, len(req.Items))
	for i, it := range req.Items {
		items[i] = service.OfferItemInput{
			ProductID:   it.ProductID,
			ProductName: it.ProductName,
			Quantity:    it.Quantity,
			UnitPrice:   it.UnitPrice,
		}
	}

	var validUntil *time.Time
	if req.ValidUntil != nil && *req.ValidUntil != "" {
		if t, err := time.Parse(dateLayout, *req.ValidUntil); err == nil {
			validUntil = &t
		}
	}

	userID, _ := middleware.UserIDFromContext(r.Context())

	o, err := h.svc.Create(r.Context(), service.CreateOfferInput{
		CustomerName:    req.CustomerName,
		CustomerPhone:   req.CustomerPhone,
		CustomerEmail:   req.CustomerEmail,
		CustomerAddress: req.CustomerAddress,
		ValidUntil:      validUntil,
		Notes:           req.Notes,
		VatRate:         req.VatRate,
		Items:           items,
		UserID:          userID,
	})
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusCreated, toOfferResponse(*o))
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
	o, err := h.svc.UpdateStatus(r.Context(), chi.URLParam(r, "id"), req.Status)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toOfferResponse(*o))
}

func (h *OfferHandler) TogglePassive(w http.ResponseWriter, r *http.Request) {
	if err := h.svc.TogglePassive(r.Context(), chi.URLParam(r, "id")); err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, map[string]bool{"ok": true})
}

func (h *OfferHandler) Delete(w http.ResponseWriter, r *http.Request) {
	if err := h.svc.Delete(r.Context(), chi.URLParam(r, "id")); err != nil {
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
	o, err := h.svc.Get(r.Context(), chi.URLParam(r, "id"))
	if err != nil {
		h.writeError(w, err)
		return
	}
	to := req.To
	if to == "" {
		to = o.CustomerEmail
	}
	if to == "" {
		httpjson.Error(w, http.StatusBadRequest, "alıcı e-posta adresi belirtilmedi")
		return
	}
	subject := req.Subject
	if subject == "" {
		subject = "Teklifiniz: " + o.OfferNo
	}
	shareURL := h.frontendURL + "/paylas/" + o.ShareToken
	body := req.Message
	if body == "" {
		body = "Sayın " + o.CustomerName + ",\n\nTalebiniz üzerine hazırladığımız teklifi aşağıdaki bağlantıdan inceleyebilirsiniz:\n"
	} else {
		body += "\n\n"
	}
	body += shareURL

	settings, err := h.settingsSvc.GetSmtp(r.Context())
	if err != nil {
		httpjson.Error(w, http.StatusInternalServerError, "ayarlar alınamadı")
		return
	}
	if err := mailer.Send(*settings, mailer.Message{To: to, Subject: subject, Body: body}); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "gönderilemedi: "+err.Error())
		return
	}
	if o.Status == domain.OfferStatusTaslak {
		if _, err := h.svc.UpdateStatus(r.Context(), o.ID, domain.OfferStatusGonderildi); err != nil {
			httpjson.Error(w, http.StatusInternalServerError, "mail gönderildi ama durum güncellenemedi")
			return
		}
	}
	httpjson.Write(w, http.StatusOK, map[string]bool{"ok": true})
}

func (h *OfferHandler) writeError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, domain.ErrNotFound):
		httpjson.Error(w, http.StatusNotFound, "teklif bulunamadı")
	case errors.Is(err, service.ErrOfferAccepted):
		httpjson.Error(w, http.StatusConflict, err.Error())
	default:
		httpjson.Error(w, http.StatusBadRequest, err.Error())
	}
}
