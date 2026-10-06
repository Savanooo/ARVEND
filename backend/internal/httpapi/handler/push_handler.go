package handler

import (
	"errors"
	"net/http"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/httpapi/middleware"
	"github.com/Savanooo/ARVEND/backend/internal/platform/httpjson"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

// PushHandler: telefon kaydı (FCM token) ve duyurular (migration 0053).
type PushHandler struct {
	svc *service.PushService
}

func NewPushHandler(svc *service.PushService) *PushHandler {
	return &PushHandler{svc: svc}
}

type pushDeviceRequest struct {
	Token      string `json:"token"`
	Platform   string `json:"platform"`
	AppVersion string `json:"app_version"`
}

// RegisterDevice, POST /api/v1/push/devices -- oturumdaki kullanıcının
// telefonu. Sunucuda gönderim kapalı olsa da kayıt tutulur (açılınca
// telefonlar zaten bilinsin); yanıt durumu söyler.
func (h *PushHandler) RegisterDevice(w http.ResponseWriter, r *http.Request) {
	var req pushDeviceRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	if err := h.svc.RegisterDevice(r.Context(), orgID, userID, req.Token, req.Platform, req.AppVersion); err != nil {
		switch {
		case errors.Is(err, service.ErrPushTokenInvalid), errors.Is(err, service.ErrPushPlatformInvalid):
			httpjson.Error(w, http.StatusBadRequest, err.Error())
		case errors.Is(err, domain.ErrNotFound):
			httpjson.Error(w, http.StatusNotFound, "kayıt bulunamadı")
		default:
			httpjson.Error(w, http.StatusInternalServerError, "cihaz kaydedilemedi")
		}
		return
	}
	httpjson.Write(w, http.StatusOK, map[string]bool{"ok": true, "push_enabled": h.svc.Enabled()})
}

// UnregisterDevice, POST /api/v1/push/devices/unregister -- çıkışta;
// yalnızca çağıranın kendi kaydı silinir.
func (h *PushHandler) UnregisterDevice(w http.ResponseWriter, r *http.Request) {
	var req pushDeviceRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	userID, _ := middleware.UserIDFromContext(r.Context())
	if err := h.svc.UnregisterDevice(r.Context(), userID, req.Token); err != nil && !errors.Is(err, domain.ErrNotFound) {
		httpjson.Error(w, http.StatusInternalServerError, "cihaz kaydı silinemedi")
		return
	}
	httpjson.Write(w, http.StatusOK, map[string]bool{"ok": true})
}

type announcementRequest struct {
	Title           string   `json:"title"`
	Body            string   `json:"body"`
	OrganizationIDs []string `json:"organization_ids"`
}

func (h *PushHandler) writeAnnouncementResult(w http.ResponseWriter, n int64, err error) {
	if err != nil {
		switch {
		case errors.Is(err, domain.ErrNotFound):
			httpjson.Error(w, http.StatusBadRequest, "geçersiz firma")
		case isInternalError(err):
			// Duyuru yazımı veritabanında düşerse ham hata metni gitmesin.
			writeInternalError(w, err)
		default:
			// ErrAnnouncementEmpty ve uzunluk hatası kullanıcıya olduğu gibi.
			httpjson.Error(w, http.StatusBadRequest, err.Error())
		}
		return
	}
	httpjson.Write(w, http.StatusCreated, map[string]any{"recipients": n, "push_enabled": h.svc.Enabled()})
}

// SendOrganizationAnnouncement, POST /api/v1/announcements -- firma
// yöneticisi kendi ekibine. Firma her zaman oturumdan; istekteki
// organization_ids yok sayılır.
func (h *PushHandler) SendOrganizationAnnouncement(w http.ResponseWriter, r *http.Request) {
	var req announcementRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	n, err := h.svc.SendAnnouncement(r.Context(), service.AnnouncementInput{
		Title: req.Title, Body: req.Body, OrganizationIDs: []string{orgID}, SenderID: userID,
	})
	h.writeAnnouncementResult(w, n, err)
}

// SendPlatformAnnouncement, POST /api/v1/platform/announcements -- Super
// Admin: seçili firmalara ya da (boş liste) tüm aktif/deneme firmalarına.
func (h *PushHandler) SendPlatformAnnouncement(w http.ResponseWriter, r *http.Request) {
	var req announcementRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	userID, _ := middleware.UserIDFromContext(r.Context())
	n, err := h.svc.SendAnnouncement(r.Context(), service.AnnouncementInput{
		Title: req.Title, Body: req.Body, OrganizationIDs: req.OrganizationIDs, SenderID: userID,
	})
	h.writeAnnouncementResult(w, n, err)
}
