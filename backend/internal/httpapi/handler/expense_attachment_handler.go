package handler

import (
	"fmt"
	"io"
	"net/http"
	"net/url"

	"github.com/go-chi/chi/v5"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/httpapi/middleware"
	"github.com/Savanooo/ARVEND/backend/internal/platform/httpjson"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

// Masraf fişi / belgesi (migration 0076). Aynı dört uç projeli masrafta
// /projects/{id}/expenses/{expenseId}/attachments, genel masrafta
// /expenses/general/{expenseId}/attachments altında; genel uçta {id} yok,
// chi.URLParam "" döner ve servis genel masrafa bakar. Kaba izin kapıları
// router'da (okuma: finance.read | expenses.create | expenses.approve;
// yazma: finance.manage | expenses.create), masrafa göre karar serviste
// (bkz. service.ExpenseViewer).

type expenseAttachmentResponse struct {
	ID           string  `json:"id"`
	ExpenseID    string  `json:"expense_id"`
	OriginalName string  `json:"original_name"`
	MIMEType     string  `json:"mime_type"`
	SizeBytes    int64   `json:"size_bytes"`
	SHA256       string  `json:"sha256"`
	UploadedBy   *string `json:"uploaded_by"`
	CreatedAt    string  `json:"created_at"`
}

func toExpenseAttachmentResponse(a domain.ExpenseAttachment) expenseAttachmentResponse {
	return expenseAttachmentResponse{
		ID: a.ID, ExpenseID: a.ExpenseID, OriginalName: a.OriginalName, MIMEType: a.MIMEType,
		SizeBytes: a.SizeBytes, SHA256: a.SHA256, UploadedBy: a.UploadedBy, CreatedAt: a.CreatedAt.Format(rfc3339),
	}
}

// expenseViewer: çağıranın masraf yetkileri. Yetki bağlamı okunamazsa hiçbir
// izin verilmez (deny-by-default) -- yalnızca kendi masrafı kalır.
func expenseViewer(r *http.Request) service.ExpenseViewer {
	userID, _ := middleware.UserIDFromContext(r.Context())
	v := service.ExpenseViewer{UserID: userID}
	if authz, ok := middleware.AuthzContextFromRequest(r.Context()); ok {
		v.FinanceRead = authz.HasPermission(domain.PermProjectsFinanceRead)
		v.FinanceManage = authz.HasPermission(domain.PermProjectsFinanceManage)
		v.Approve = authz.HasPermission(domain.PermProjectsExpensesApprove)
	}
	return v
}

// ListExpenseAttachments: GET .../expenses/{expenseId}/attachments ->
// {attachments: [...]} (eklenme sırasıyla).
func (h *ProjectHandler) ListExpenseAttachments(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	rows, err := h.svc.ListExpenseAttachments(r.Context(), orgID, chi.URLParam(r, "id"), chi.URLParam(r, "expenseId"), expenseViewer(r))
	if err != nil {
		h.writeError(w, err)
		return
	}
	out := make([]expenseAttachmentResponse, len(rows))
	for i, a := range rows {
		out[i] = toExpenseAttachmentResponse(a)
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"attachments": out, "max": domain.ExpenseAttachmentsMax})
}

// UploadExpenseAttachment: POST .../expenses/{expenseId}/attachments
// (multipart, alan "file", en fazla 25 MB). 201 yeni belge; 200 aynı içerik
// bu masrafta zaten vardı (mevcut kayıt döner).
func (h *ProjectHandler) UploadExpenseAttachment(w http.ResponseWriter, r *http.Request) {
	body, name, _, err := readUpload(w, r)
	if err != nil {
		h.writeError(w, err)
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	a, created, err := h.svc.UploadExpenseAttachment(r.Context(), orgID, chi.URLParam(r, "id"), chi.URLParam(r, "expenseId"), expenseViewer(r), name, body)
	if err != nil {
		h.writeError(w, err)
		return
	}
	status := http.StatusCreated
	if !created {
		status = http.StatusOK
	}
	httpjson.Write(w, status, toExpenseAttachmentResponse(*a))
}

// DownloadExpenseAttachment: GET .../attachments/{attachmentId}/content.
// Fotoğraf uygulamada/galeride gösterilebilsin diye inline; nosniff içeriğin
// beyan edilen türden farklı yorumlanmasını engeller (tür yüklemede
// içerikten tespit edildi, SVG/HTML hiç kabul edilmez).
func (h *ProjectHandler) DownloadExpenseAttachment(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	a, rc, err := h.svc.OpenExpenseAttachment(r.Context(), orgID, chi.URLParam(r, "id"), chi.URLParam(r, "expenseId"),
		chi.URLParam(r, "attachmentId"), expenseViewer(r))
	if err != nil {
		h.writeError(w, err)
		return
	}
	defer rc.Close()
	w.Header().Set("Content-Type", a.MIMEType)
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Content-Length", fmt.Sprintf("%d", a.SizeBytes))
	w.Header().Set("Content-Disposition", fmt.Sprintf(`inline; filename*=UTF-8''%s`, url.PathEscape(a.OriginalName)))
	w.Header().Set("Cache-Control", "private, max-age=300")
	_, _ = io.Copy(w, rc)
}

// DeleteExpenseAttachment: DELETE .../attachments/{attachmentId} -- kalıcı.
func (h *ProjectHandler) DeleteExpenseAttachment(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	if err := h.svc.DeleteExpenseAttachment(r.Context(), orgID, chi.URLParam(r, "id"), chi.URLParam(r, "expenseId"),
		chi.URLParam(r, "attachmentId"), expenseViewer(r)); err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, map[string]bool{"ok": true})
}
