package handler

import (
	"fmt"
	"net/http"
	"net/url"
	"strconv"

	"github.com/go-chi/chi/v5"

	"github.com/Savanooo/ARVEND/backend/internal/httpapi/middleware"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

// OfferPDFHandler, teklif PDF'inin iki indirme ucu: personel (offers.read)
// ve müşterinin paylaşım linki (token).
type OfferPDFHandler struct {
	svc *service.OfferPDFService
}

func NewOfferPDFHandler(svc *service.OfferPDFService) *OfferPDFHandler {
	return &OfferPDFHandler{svc: svc}
}

// Download: GET /offers/{id}/pdf
func (h *OfferPDFHandler) Download(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	doc, err := h.svc.Render(r.Context(), chi.URLParam(r, "id"), orgID)
	if err != nil {
		// Teklif detayıyla AYNI hata eşlemesi.
		(&OfferHandler{}).writeError(w, err)
		return
	}
	writePDF(w, doc)
}

// PublicDownload: GET /public/offers/{token}/pdf
func (h *OfferPDFHandler) PublicDownload(w http.ResponseWriter, r *http.Request) {
	doc, err := h.svc.RenderShared(r.Context(), chi.URLParam(r, "token"), clientIP(r), r.UserAgent())
	if err != nil {
		// Paylaşım sayfasıyla AYNI kurallar (iptal/süresi dolmuş link 410).
		(&PublicOfferHandler{}).writeError(w, err)
		return
	}
	writePDF(w, doc)
}

func writePDF(w http.ResponseWriter, doc *service.OfferPDF) {
	w.Header().Set("Content-Type", "application/pdf")
	w.Header().Set("Content-Length", strconv.Itoa(len(doc.Content)))
	// Tarayıcı kendi görüntüleyicisinde açabilsin (inline); "Farklı kaydet"
	// dosya adını kullanır.
	w.Header().Set("Content-Disposition",
		fmt.Sprintf(`inline; filename="%s"; filename*=UTF-8''%s`, doc.Filename, url.PathEscape(doc.Filename)))
	w.Header().Set("Cache-Control", "private, no-store")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(doc.Content)
}
