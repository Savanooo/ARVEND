package handler

import (
	"net/http"

	"github.com/Savanooo/ARVEND/backend/internal/httpapi/middleware"
	"github.com/Savanooo/ARVEND/backend/internal/platform/httpjson"
	"github.com/Savanooo/ARVEND/backend/internal/platform/mailer"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

type SettingsHandler struct {
	svc *service.SettingsService
}

func NewSettingsHandler(svc *service.SettingsService) *SettingsHandler {
	return &SettingsHandler{svc: svc}
}

type smtpSettingsResponse struct {
	Host        string `json:"host"`
	Port        int    `json:"port"`
	Username    string `json:"username"`
	PasswordSet bool   `json:"password_set"`
	FromEmail   string `json:"from_email"`
	FromName    string `json:"from_name"`
	UseTLS      bool   `json:"use_tls"`
	Configured  bool   `json:"configured"`
}

func (h *SettingsHandler) GetSmtp(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	s, err := h.svc.GetSmtp(r.Context(), orgID)
	if err != nil {
		httpjson.Error(w, http.StatusInternalServerError, "ayarlar alınamadı")
		return
	}
	httpjson.Write(w, http.StatusOK, smtpSettingsResponse{
		Host:        s.Host,
		Port:        s.Port,
		Username:    s.Username,
		PasswordSet: s.PasswordSet,
		FromEmail:   s.FromEmail,
		FromName:    s.FromName,
		UseTLS:      s.UseTLS,
		Configured:  s.Configured,
	})
}

type updateSmtpRequest struct {
	Host      string  `json:"host"`
	Port      int     `json:"port"`
	Username  string  `json:"username"`
	Password  *string `json:"password"`
	FromEmail string  `json:"from_email"`
	FromName  string  `json:"from_name"`
	UseTLS    bool    `json:"use_tls"`
}

func (h *SettingsHandler) UpdateSmtp(w http.ResponseWriter, r *http.Request) {
	var req updateSmtpRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	s, err := h.svc.UpdateSmtp(r.Context(), orgID, service.UpdateSmtpInput{
		Host:      req.Host,
		Port:      req.Port,
		Username:  req.Username,
		Password:  req.Password,
		FromEmail: req.FromEmail,
		FromName:  req.FromName,
		UseTLS:    req.UseTLS,
	})
	if err != nil {
		if isInternalError(err) {
			// Ham veritabanı metni kullanıcıya gitmesin.
			writeInternalError(w, err)
			return
		}
		httpjson.Error(w, http.StatusBadRequest, err.Error())
		return
	}
	httpjson.Write(w, http.StatusOK, smtpSettingsResponse{
		Host:        s.Host,
		Port:        s.Port,
		Username:    s.Username,
		PasswordSet: s.PasswordSet,
		FromEmail:   s.FromEmail,
		FromName:    s.FromName,
		UseTLS:      s.UseTLS,
		Configured:  s.Configured,
	})
}

type testSmtpRequest struct {
	To string `json:"to"`
}

func (h *SettingsHandler) TestSmtp(w http.ResponseWriter, r *http.Request) {
	var req testSmtpRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	settings, err := h.svc.GetSmtp(r.Context(), orgID)
	if err != nil {
		httpjson.Error(w, http.StatusInternalServerError, "ayarlar alınamadı")
		return
	}
	err = mailer.Send(*settings, mailer.Message{
		To:      req.To,
		Subject: "Arvend Yapı -- Test E-postası",
		Body:    "Bu bir test e-postasıdır. SMTP ayarlarınız doğru çalışıyor.",
	})
	if err != nil {
		httpjson.Error(w, http.StatusBadRequest, "gönderilemedi: "+err.Error())
		return
	}
	httpjson.Write(w, http.StatusOK, map[string]bool{"ok": true})
}
