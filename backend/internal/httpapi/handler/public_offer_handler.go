package handler

import (
	"errors"
	"net/http"

	"github.com/go-chi/chi/v5"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/platform/httpjson"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

// PublicOfferHandler, müşterinin auth gerektirmeden paylaşım linkiyle
// teklifi görüntüleyip kabul/red edebilmesini sağlar. Token bilmeyen kimse
// bir teklife erişemez (uuid, tahmin edilemez); bunun dışında bir yetki
// kontrolü yoktur.
type PublicOfferHandler struct {
	svc *service.OfferService
}

func NewPublicOfferHandler(svc *service.OfferService) *PublicOfferHandler {
	return &PublicOfferHandler{svc: svc}
}

func (h *PublicOfferHandler) Get(w http.ResponseWriter, r *http.Request) {
	o, err := h.svc.GetByShareToken(r.Context(), chi.URLParam(r, "token"))
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toOfferResponse(*o))
}

type respondOfferRequest struct {
	Decision string `json:"decision"`
}

func (h *PublicOfferHandler) Respond(w http.ResponseWriter, r *http.Request) {
	var req respondOfferRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	o, err := h.svc.RespondByShareToken(r.Context(), chi.URLParam(r, "token"), req.Decision)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toOfferResponse(*o))
}

func (h *PublicOfferHandler) writeError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, domain.ErrNotFound):
		httpjson.Error(w, http.StatusNotFound, "teklif bulunamadı")
	case errors.Is(err, service.ErrOfferNotRespondable):
		httpjson.Error(w, http.StatusConflict, err.Error())
	default:
		httpjson.Error(w, http.StatusBadRequest, err.Error())
	}
}
