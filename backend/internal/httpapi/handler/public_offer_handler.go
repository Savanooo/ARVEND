package handler

import (
	"errors"
	"net/http"
	"strings"

	"github.com/go-chi/chi/v5"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/platform/httpjson"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

// PublicOfferHandler, müşterinin auth gerektirmeden paylaşım linkiyle
// teklifi görüntüleyip kabul/red edebilmesini sağlar. Token bilmeyen kimse
// bir teklife erişemez (uuid, tahmin edilemez); bunun dışında bir yetki
// kontrolü yoktur. organization_id burada ASLA request'ten alınmaz --
// token, servis katmanında hangi organizasyona/tekliflere/revizyona ait
// olduğunu kendi başına çözer (bkz. OfferService.resolveActiveShareLink).
type PublicOfferHandler struct {
	svc *service.OfferService
}

func NewPublicOfferHandler(svc *service.OfferService) *PublicOfferHandler {
	return &PublicOfferHandler{svc: svc}
}

// clientIP, ters proxy arkasında da (X-Forwarded-For) makul bir istemci
// IP'si döner -- yalnızca denetim kaydı (offer_events) için kullanılır,
// hiçbir yetkilendirme kararına girmez.
//
// X-Forwarded-For birden fazla hop'ta virgülle ayrılmış bir ZİNCİR olur
// ("gerçek istemci, proxy1, proxy2"); zincirin tamamı kolayca 45 karakteri
// aşar (ör. Cloudflare + nginx arkasında bir IPv6 istemci ~52 karakter).
// Zincirin ilk girdisi asıl istemcidir; yalnızca onu alıyoruz.
func clientIP(r *http.Request) string {
	if fwd := r.Header.Get("X-Forwarded-For"); fwd != "" {
		if i := strings.IndexByte(fwd, ','); i >= 0 {
			fwd = fwd[:i]
		}
		return strings.TrimSpace(fwd)
	}
	return r.RemoteAddr
}

// viewerUserAgent, sayfayı açan TARAYICININ User-Agent'ı. Müşteri sayfası
// Next.js sunucusunda render edilir ve bu ucu kendisi çağırır; tarayıcının
// başlığını X-Viewer-User-Agent ile iletir (yoksa -- eski web sürümü ya da
// doğrudan çağrı -- isteğin kendi User-Agent'ı). Yalnızca kayıt ve
// önizleme ayıklama içindir (service.IsLinkPreviewAgent); yetki kararına
// girmez.
func viewerUserAgent(r *http.Request) string {
	if ua := strings.TrimSpace(r.Header.Get("X-Viewer-User-Agent")); ua != "" {
		return ua
	}
	return r.UserAgent()
}

// publicOfferResponse, teklifin genel görünümüne "bu bağlantı üzerinden
// şu an karar verilebilir mi?" bilgisini ekler -- müşteriye asla başarılı
// olamayacak bir Kabul Et/Reddet butonu gösterilmemesi için.
type publicOfferResponse struct {
	offerResponse
	// OrganizationName: teklifi veren firmanın adı -- public sayfa başlığı
	// bunu gösterir (eskiden her firmanın müşterisine sabit "Arvend Yapı").
	OrganizationName string `json:"organization_name"`
	CanRespond       bool   `json:"can_respond"`
	// ValidityExpired: geçerlilik tarihi (valid_until, o gün dahil) geçmiş
	// -- sayfa butonlar yerine "süresi doldu" mesajını gösterir. "Bugün"ün
	// tek tanımı sunucudadır (İstanbul takvim günü, bkz.
	// service.OfferValidityExpired); istemci saatine güvenilmez.
	ValidityExpired bool `json:"validity_expired"`
}

// toPublicOfferResponse, müşteriye giden TEK teklif şeklidir:
// toOfferResponse'un (zaten iç fiyatlamayı hiç içermeyen) çıktısından
// Metraj Hesaplama'nın dondurulmuş hesap kaydı (calc_snapshot: fire
// yüzdesi, reçete katsayısı, katalog/liste fiyatı) ve iç kategori id'si
// de çıkarılır -- bunlar firmanın maliyet yapısını müşteriye açıyordu.
// Müşteriye yalnızca kalem adı, birim, miktar, birim fiyat ve tutar gider.
func toPublicOfferResponse(o domain.Offer) offerResponse {
	resp := toOfferResponse(o)
	for i := range resp.Items {
		resp.Items[i].CalcSnapshot = nil
		resp.Items[i].CalcCategoryID = nil
	}
	return resp
}

func (h *PublicOfferHandler) Get(w http.ResponseWriter, r *http.Request) {
	v, err := h.svc.GetPublicView(r.Context(), chi.URLParam(r, "token"), clientIP(r), viewerUserAgent(r))
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, publicOfferResponse{
		offerResponse:    toPublicOfferResponse(v.Offer),
		OrganizationName: v.OrganizationName,
		CanRespond:       v.CanRespond,
		ValidityExpired:  v.ValidityExpired,
	})
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
	o, err := h.svc.RespondByShareLinkToken(r.Context(), chi.URLParam(r, "token"), req.Decision, clientIP(r), viewerUserAgent(r))
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toPublicOfferResponse(*o))
}

func (h *PublicOfferHandler) writeError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, domain.ErrNotFound):
		httpjson.Error(w, http.StatusNotFound, "teklif bulunamadı")
	case errors.Is(err, service.ErrShareLinkRevoked),
		errors.Is(err, service.ErrShareLinkExpired),
		errors.Is(err, service.ErrPublicLinkUnavailable):
		// 410 Gone: bağlantı bir zamanlar geçerliydi ama artık kalıcı
		// olarak kullanılamaz -- 404'ten kasıtlı olarak farklı, "hiç var
		// olmadı" ile "artık geçerli değil"i ayırt eder.
		httpjson.Error(w, http.StatusGone, err.Error())
	case errors.Is(err, service.ErrOfferSuperseded),
		errors.Is(err, service.ErrOfferNotRespondable),
		errors.Is(err, service.ErrOfferValidityExpired):
		httpjson.Error(w, http.StatusConflict, err.Error())
	case isInternalError(err):
		writeInternalError(w, err)
	default:
		httpjson.Error(w, http.StatusBadRequest, err.Error())
	}
}
