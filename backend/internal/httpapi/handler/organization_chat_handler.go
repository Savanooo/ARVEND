package handler

import (
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/httpapi/middleware"
	"github.com/Savanooo/ARVEND/backend/internal/platform/httpjson"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

// OrganizationChatHandler: Firma Grubu (migration 0077) -- /organization/chat.
// Kişi ve firma her zaman oturumdan gelir; istek gövdesinden ASLA.
type OrganizationChatHandler struct {
	svc *service.OrganizationChatService
}

func NewOrganizationChatHandler(svc *service.OrganizationChatService) *OrganizationChatHandler {
	return &OrganizationChatHandler{svc: svc}
}

type chatPhotoResponse struct {
	MIMEType  string `json:"mime_type"`
	SizeBytes int64  `json:"size_bytes"`
}

type chatMessageResponse struct {
	ID         string             `json:"id"`
	Seq        int64              `json:"seq"`
	AuthorID   *string            `json:"author_id"`
	AuthorName string             `json:"author_name"`
	Text       string             `json:"text"`
	Photo      *chatPhotoResponse `json:"photo"`
	CreatedAt  string             `json:"created_at"`
	Deleted    bool               `json:"deleted"`
	// IsOwn/CanDelete çağırana göre hesaplanır: istemci kendi mesajını sağa
	// koyar, "Sil"i yalnızca CanDelete'te gösterir (asıl kural serviste).
	IsOwn     bool `json:"is_own"`
	CanDelete bool `json:"can_delete"`
}

func toChatMessageResponse(m domain.ChatMessage, viewerID string, canModerate bool) chatMessageResponse {
	own := m.AuthorID != nil && *m.AuthorID == viewerID
	resp := chatMessageResponse{
		ID: m.ID, Seq: m.Seq, AuthorID: m.AuthorID, AuthorName: m.AuthorName,
		Text: m.Body, CreatedAt: m.CreatedAt.UTC().Format(time.RFC3339),
		Deleted: m.Deleted, IsOwn: own, CanDelete: !m.Deleted && (own || canModerate),
	}
	if resp.AuthorName == "" {
		resp.AuthorName = "Silinmiş kullanıcı"
	}
	if m.Photo != nil {
		resp.Photo = &chatPhotoResponse{MIMEType: m.Photo.MIMEType, SizeBytes: m.Photo.SizeBytes}
	}
	return resp
}

func chatViewer(r *http.Request) (orgID, userID string, canModerate bool) {
	orgID, _ = middleware.OrganizationIDFromContext(r.Context())
	userID, _ = middleware.UserIDFromContext(r.Context())
	if authz, ok := middleware.AuthzContextFromRequest(r.Context()); ok {
		canModerate = domain.CanModerateChat(authz.RoleCode)
	}
	return orgID, userID, canModerate
}

// List, GET /organization/chat/messages
//
//	(parametresiz)  en yeni sayfa
//	?before=<seq>   o numaradan eski sayfa
//	?after=<seq>    yoklama: o numaradan sonrakiler (+ changed_since ile
//	                istemcinin elindeki aralıkta bu arada silinenler)
//	?limit=         varsayılan 50, en çok 100
//
// messages her zaman yeniden eskiye sıralıdır.
func (h *OrganizationChatHandler) List(w http.ResponseWriter, r *http.Request) {
	orgID, userID, _ := chatViewer(r)
	in := service.ChatListQuery{}
	qs := r.URL.Query()
	var err error
	if v := qs.Get("before"); v != "" {
		if in.Before, err = strconv.ParseInt(v, 10, 64); err != nil {
			httpjson.Error(w, http.StatusBadRequest, service.ErrChatInvalidCursor.Error())
			return
		}
	}
	if v := qs.Get("after"); v != "" {
		after, err := strconv.ParseInt(v, 10, 64)
		if err != nil {
			httpjson.Error(w, http.StatusBadRequest, service.ErrChatInvalidCursor.Error())
			return
		}
		in.After = &after
	}
	if v := qs.Get("limit"); v != "" {
		in.Limit, _ = strconv.Atoi(v)
	}
	if v := qs.Get("changed_since"); v != "" {
		t, err := time.Parse(time.RFC3339Nano, v)
		if err != nil {
			httpjson.Error(w, http.StatusBadRequest, "geçersiz tarih: changed_since RFC3339 biçiminde olmalı")
			return
		}
		in.ChangedSince = &t
	}
	res, err := h.svc.List(r.Context(), orgID, userID, in)
	if err != nil {
		h.writeError(w, err)
		return
	}
	messages := make([]chatMessageResponse, len(res.Messages))
	for i, m := range res.Messages {
		messages[i] = toChatMessageResponse(m, userID, res.CanModerate)
	}
	updated := make([]chatMessageResponse, len(res.Updated))
	for i, m := range res.Updated {
		updated[i] = toChatMessageResponse(m, userID, res.CanModerate)
	}
	httpjson.Write(w, http.StatusOK, map[string]any{
		"messages":      messages,
		"has_more":      res.HasMore,
		"updated":       updated,
		"last_read_seq": res.LastReadSeq,
		"muted":         res.Muted,
		"can_moderate":  res.CanModerate,
		"server_time":   res.ServerTime.UTC().Format(time.RFC3339Nano),
	})
}

type chatSendRequest struct {
	Text     string `json:"text"`
	ClientID string `json:"client_id"`
}

// Send, POST /organization/chat/messages {"text","client_id"}. 201 yeni
// mesaj; 200 aynı client_id ile daha önce yazılmış mesaj (tekrar deneme).
func (h *OrganizationChatHandler) Send(w http.ResponseWriter, r *http.Request) {
	var req chatSendRequest
	// 4000 karakter Türkçe metin ~16 KB; gövde bundan büyük olamaz.
	r.Body = http.MaxBytesReader(w, r.Body, 64<<10)
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, userID, canModerate := chatViewer(r)
	res, err := h.svc.Send(r.Context(), service.ChatSendInput{
		OrganizationID: orgID, UserID: userID, Text: req.Text, ClientID: req.ClientID,
	})
	h.writeSendResult(w, res, err, userID, canModerate)
}

// SendPhoto, POST /organization/chat/messages/photo (multipart: file,
// isteğe bağlı text ve client_id). Proje fotoğrafıyla aynı sınırlar: 25 MB,
// tür içerikten (JPEG/PNG/WebP/GIF).
func (h *OrganizationChatHandler) SendPhoto(w http.ResponseWriter, r *http.Request) {
	body, _, _, err := readUpload(w, r)
	if err != nil {
		h.writeError(w, err)
		return
	}
	orgID, userID, canModerate := chatViewer(r)
	res, err := h.svc.SendPhoto(r.Context(), service.ChatSendInput{
		OrganizationID: orgID, UserID: userID, Photo: body,
		Text: r.FormValue("text"), ClientID: r.FormValue("client_id"),
	})
	h.writeSendResult(w, res, err, userID, canModerate)
}

func (h *OrganizationChatHandler) writeSendResult(w http.ResponseWriter, res *service.ChatSendResult, err error, userID string, canModerate bool) {
	if err != nil {
		h.writeError(w, err)
		return
	}
	status := http.StatusCreated
	if !res.Created {
		status = http.StatusOK
	}
	httpjson.Write(w, status, toChatMessageResponse(res.Message, userID, canModerate))
}

// Photo, GET /organization/chat/messages/{id}/photo -- uygulama içinde
// gösterilir (inline). İçerik mesaj kimliğine bağlı ve değişmez; telefon
// diskte saklar.
func (h *OrganizationChatHandler) Photo(w http.ResponseWriter, r *http.Request) {
	orgID, _, _ := chatViewer(r)
	photo, rc, err := h.svc.OpenPhoto(r.Context(), orgID, chi.URLParam(r, "id"))
	if err != nil {
		h.writeError(w, err)
		return
	}
	defer rc.Close()
	w.Header().Set("Content-Type", photo.MIMEType)
	w.Header().Set("X-Content-Type-Options", "nosniff")
	if photo.SizeBytes > 0 {
		w.Header().Set("Content-Length", fmt.Sprintf("%d", photo.SizeBytes))
	}
	w.Header().Set("Cache-Control", "private, max-age=300")
	_, _ = io.Copy(w, rc)
}

// Delete, DELETE /organization/chat/messages/{id} -- yanıt mesajın silinmiş
// hali ("Mesaj silindi").
func (h *OrganizationChatHandler) Delete(w http.ResponseWriter, r *http.Request) {
	orgID, userID, canModerate := chatViewer(r)
	m, err := h.svc.Delete(r.Context(), orgID, userID, chi.URLParam(r, "id"))
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toChatMessageResponse(*m, userID, canModerate))
}

func writeChatStatus(w http.ResponseWriter, st *service.ChatStatus) {
	httpjson.Write(w, http.StatusOK, map[string]any{
		"unread_count": st.UnreadCount, "muted": st.Muted, "last_read_seq": st.LastReadSeq,
	})
}

// Status, GET /organization/chat/status -- rozet (okunmamış sayısı, en çok
// 1000) ve sessiz durumu.
func (h *OrganizationChatHandler) Status(w http.ResponseWriter, r *http.Request) {
	orgID, userID, _ := chatViewer(r)
	st, err := h.svc.Status(r.Context(), orgID, userID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	writeChatStatus(w, st)
}

type chatReadRequest struct {
	Seq int64 `json:"seq"`
}

// MarkRead, POST /organization/chat/read {"seq"} -- ekranda görülen en yeni
// mesajın numarası.
func (h *OrganizationChatHandler) MarkRead(w http.ResponseWriter, r *http.Request) {
	var req chatReadRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, userID, _ := chatViewer(r)
	st, err := h.svc.MarkRead(r.Context(), orgID, userID, req.Seq)
	if err != nil {
		h.writeError(w, err)
		return
	}
	writeChatStatus(w, st)
}

type chatMuteRequest struct {
	Muted *bool `json:"muted"`
}

// SetMuted, PUT /organization/chat/mute {"muted": true|false}.
func (h *OrganizationChatHandler) SetMuted(w http.ResponseWriter, r *http.Request) {
	var req chatMuteRequest
	if err := httpjson.Decode(r, &req); err != nil || req.Muted == nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, userID, _ := chatViewer(r)
	st, err := h.svc.SetMuted(r.Context(), orgID, userID, *req.Muted)
	if err != nil {
		h.writeError(w, err)
		return
	}
	writeChatStatus(w, st)
}

func (h *OrganizationChatHandler) writeError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, domain.ErrNotFound):
		httpjson.Error(w, http.StatusNotFound, "kayıt bulunamadı")
	case errors.Is(err, service.ErrChatRateLimited):
		w.Header().Set("Retry-After", "30")
		httpjson.Error(w, http.StatusTooManyRequests, err.Error())
	case errors.Is(err, service.ErrChatNotMember), errors.Is(err, service.ErrChatDeleteNotAllowed):
		httpjson.Error(w, http.StatusForbidden, err.Error())
	case errors.Is(err, service.ErrFileTooLarge):
		httpjson.Error(w, http.StatusRequestEntityTooLarge, err.Error())
	case errors.Is(err, service.ErrChatEmpty), errors.Is(err, service.ErrChatTooLong),
		errors.Is(err, service.ErrChatInvalidClientID), errors.Is(err, service.ErrChatInvalidCursor),
		errors.Is(err, service.ErrChatPhotoType), errors.Is(err, service.ErrEmptyFile),
		errors.Is(err, errUploadUnreadable), isUploadFieldMissing(err):
		httpjson.Error(w, http.StatusBadRequest, err.Error())
	case errors.Is(err, service.ErrStorageFailure):
		httpjson.Error(w, http.StatusInternalServerError, err.Error())
	default:
		// Kalan her şey veritabanı/bağlantı hatasıdır -- ham metin istemciye
		// gitmesin.
		writeInternalError(w, err)
	}
}

// isUploadFieldMissing: readUpload'ın "dosya alanı bulunamadı" hatası
// (sentinel değil, düz metin).
func isUploadFieldMissing(err error) bool {
	return err != nil && strings.Contains(err.Error(), "dosya alanı bulunamadı")
}
