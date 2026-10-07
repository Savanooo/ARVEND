package handler

import (
	"errors"
	"net/http"

	"github.com/go-chi/chi/v5"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/platform/httpjson"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

type PublicChangeOrderHandler struct {
	svc *service.ProjectService
}

func NewPublicChangeOrderHandler(svc *service.ProjectService) *PublicChangeOrderHandler {
	return &PublicChangeOrderHandler{svc: svc}
}

type publicChangeOrderItemResponse struct {
	ID          string  `json:"id"`
	Description string  `json:"description"`
	Quantity    float64 `json:"quantity"`
	Unit        string  `json:"unit"`
	UnitPrice   float64 `json:"unit_price"`
	LineTotal   float64 `json:"line_total"`
}

// publicChangeOrderResponse, MÜŞTERİYE giden TEK yanıt şeklidir.
// internal_notes, created_by, maliyet, taahhüt maliyeti, kâr, marj --
// hiçbiri BURADA YOKTUR ve asla eklenmemelidir (bkz. changeOrderResponse
// -- dahili/kimlik doğrulamalı yanıt AYRI bir tiptir, buraya asla
// serialize edilmez).
type publicChangeOrderResponse struct {
	// OrganizationName: ek işi gönderen firmanın adı (sayfa başlığı).
	OrganizationName       string                          `json:"organization_name"`
	ChangeOrderNo          string                          `json:"change_order_no"`
	ProjectNo              string                          `json:"project_no"`
	ProjectName            string                          `json:"project_name"`
	CustomerName           string                          `json:"customer_name"`
	ChangeType             string                          `json:"change_type"`
	Title                  string                          `json:"title"`
	Description            string                          `json:"description"`
	Status                 string                          `json:"status"`
	Items                  []publicChangeOrderItemResponse `json:"items"`
	Subtotal               float64                         `json:"subtotal"`
	VatRate                float64                         `json:"vat_rate"`
	VatAmount              float64                         `json:"vat_amount"`
	GrandTotal             float64                         `json:"grand_total"`
	Currency               string                          `json:"currency"`
	CustomerNotes          string                          `json:"customer_notes"`
	BaseContractAmount     float64                         `json:"base_contract_amount"`
	CurrentContractValue   float64                         `json:"current_contract_value"`
	ProjectedContractValue float64                         `json:"projected_contract_value"`
	CanRespond             bool                            `json:"can_respond"`
}

func toPublicChangeOrderResponse(v service.PublicChangeOrderView) publicChangeOrderResponse {
	items := make([]publicChangeOrderItemResponse, len(v.ChangeOrder.Items))
	for i, it := range v.ChangeOrder.Items {
		items[i] = publicChangeOrderItemResponse{
			ID: it.ID, Description: it.Description, Quantity: it.Quantity, Unit: it.Unit,
			UnitPrice: it.UnitPrice, LineTotal: it.LineTotal,
		}
	}
	return publicChangeOrderResponse{
		OrganizationName: v.OrganizationName,
		ChangeOrderNo:    v.ChangeOrder.ChangeOrderNo(), ProjectNo: v.ProjectNo, ProjectName: v.ProjectName,
		CustomerName: v.CustomerName, ChangeType: v.ChangeOrder.ChangeType, Title: v.ChangeOrder.Title,
		Description: v.ChangeOrder.Description, Status: v.ChangeOrder.Status, Items: items,
		Subtotal: v.ChangeOrder.Subtotal, VatRate: v.ChangeOrder.VatRate, VatAmount: v.ChangeOrder.VatAmount,
		GrandTotal: v.ChangeOrder.GrandTotal, Currency: v.Currency, CustomerNotes: v.ChangeOrder.CustomerNotes,
		BaseContractAmount: v.BaseContractAmount, CurrentContractValue: v.CurrentContractValue,
		ProjectedContractValue: v.ProjectedContractValue, CanRespond: v.CanRespond,
	}
}

func (h *PublicChangeOrderHandler) Get(w http.ResponseWriter, r *http.Request) {
	v, err := h.svc.GetChangeOrderByShareLinkToken(r.Context(), chi.URLParam(r, "token"), clientIP(r), r.UserAgent())
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toPublicChangeOrderResponse(*v))
}

type respondChangeOrderRequest struct {
	Decision string `json:"decision"`
}

func (h *PublicChangeOrderHandler) Respond(w http.ResponseWriter, r *http.Request) {
	var req respondChangeOrderRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	token := chi.URLParam(r, "token")
	if _, err := h.svc.RespondChangeOrderByShareLinkToken(r.Context(), token, req.Decision, clientIP(r), r.UserAgent()); err != nil {
		h.writeError(w, err)
		return
	}
	// Yanıt sonrası TEKRAR public görünüm üzerinden döneriz -- tek bir
	// public DTO oluşturma yolu (Get ile AYNI), internal alan sızma
	// riskini yapısal olarak ortadan kaldırır.
	v, err := h.svc.GetChangeOrderByShareLinkToken(r.Context(), token, clientIP(r), r.UserAgent())
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toPublicChangeOrderResponse(*v))
}

func (h *PublicChangeOrderHandler) writeError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, domain.ErrNotFound):
		httpjson.Error(w, http.StatusNotFound, "ek iş bulunamadı")
	case errors.Is(err, service.ErrChangeOrderShareLinkRevoked), errors.Is(err, service.ErrChangeOrderShareLinkExpired),
		errors.Is(err, service.ErrPublicLinkUnavailable):
		// 410: var olmuş ama artık geçersiz -- 404 "hiç var olmadı"dan
		// bilinçli olarak ayrılır (bkz. offer'ın aynı ayrımı).
		httpjson.Error(w, http.StatusGone, err.Error())
	case errors.Is(err, service.ErrChangeOrderNotRespondable), errors.Is(err, service.ErrChangeOrderWouldGoNegative):
		httpjson.Error(w, http.StatusConflict, err.Error())
	case isInternalError(err):
		writeInternalError(w, err)
	default:
		httpjson.Error(w, http.StatusBadRequest, err.Error())
	}
}
