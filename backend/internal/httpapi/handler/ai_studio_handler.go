package handler

// Yapay Zekâ Stüdyo uçları (migration 0080; bkz. service/ai_studio_service.go).
// Hepsi /api/v1/ai/studio altında, ai.images.use izniyle (router). Proje
// ucundan farkı: URL'de proje yok -- kaynak proje fotoğrafının ve "Projeye
// ekle" hedefinin proje erişimi burada AuthorizationService ile denetlenir.

import (
	"context"
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

// studioTime: stüdyo zamanları UTC ve mikro saniyeli -- next_before imleci
// istemciden aynen geri gelir; saniyeye yuvarlansa aynı saniyedeki görseller
// atlanırdı. UTC: sorgu dizgesinde "+03:00"ın "+"sı boşluğa dönmesin.
func studioTime(t time.Time) string { return t.UTC().Format(time.RFC3339Nano) }

type aiStudioJobResponse struct {
	ID     string `json:"id"`
	Kind   string `json:"kind"`
	Status string `json:"status"`
	// Error: yalnızca başarısız işte, Türkçe neden; diğerlerinde null.
	Error         *string `json:"error"`
	Prompt        string  `json:"prompt"`
	StudioImageID *string `json:"studio_image_id"`
	CreatedAt     string  `json:"created_at"`
}

func toAIStudioJobResponse(j domain.AIImageJob) aiStudioJobResponse {
	resp := aiStudioJobResponse{
		ID: j.ID, Kind: j.Kind, Status: j.Status, Prompt: j.Prompt,
		StudioImageID: j.StudioImageID, CreatedAt: studioTime(j.CreatedAt),
	}
	if strings.TrimSpace(j.Error) != "" {
		e := j.Error
		resp.Error = &e
	}
	return resp
}

type aiStudioImageProjectResponse struct {
	ProjectID      string `json:"project_id"`
	ProjectName    string `json:"project_name"`
	ProjectPhotoID string `json:"project_photo_id"`
}

type aiStudioImageResponse struct {
	ID        string                         `json:"id"`
	Kind      string                         `json:"kind"`
	Prompt    string                         `json:"prompt"`
	CreatedAt string                         `json:"created_at"`
	UserID    *string                        `json:"user_id"`
	UserName  string                         `json:"user_name"`
	MIME      string                         `json:"mime"`
	SizeBytes int64                          `json:"size_bytes"`
	Projects  []aiStudioImageProjectResponse `json:"projects"`
}

func toAIStudioImageResponse(i domain.AIStudioImage) aiStudioImageResponse {
	resp := aiStudioImageResponse{
		ID: i.ID, Kind: i.Kind, Prompt: i.Prompt, CreatedAt: studioTime(i.CreatedAt),
		UserID: i.UserID, UserName: i.UserName, MIME: i.MIMEType, SizeBytes: i.SizeBytes,
		Projects: make([]aiStudioImageProjectResponse, len(i.Projects)),
	}
	for k, p := range i.Projects {
		resp.Projects[k] = aiStudioImageProjectResponse{ProjectID: p.ProjectID, ProjectName: p.ProjectName, ProjectPhotoID: p.ProjectPhotoID}
	}
	return resp
}

type createAIStudioJobJSON struct {
	Kind                 string `json:"kind"`
	Prompt               string `json:"prompt"`
	SourceProjectPhotoID string `json:"source_project_photo_id"`
	SourceStudioImageID  string `json:"source_studio_image_id"`
}

// CreateStudioJob: POST /ai/studio/jobs -- multipart/form-data: kind, prompt
// ve en çok bir kaynak: image (dosya), source_project_photo_id ya da
// source_studio_image_id; 'edit' için isteğe bağlı mask (PNG). Dosyasız
// istek JSON da olabilir. 202 {job, remaining, limit}.
func (h *AIImageHandler) CreateStudioJob(w http.ResponseWriter, r *http.Request) {
	if !h.svc.Enabled() {
		h.writeError(w, service.ErrAIDisabled)
		return
	}
	var (
		req         createAIStudioJobJSON
		image, mask io.Reader
	)
	if isMultipart(r) {
		form, err := parseAIMultipart(w, r)
		if err != nil {
			h.writeError(w, err)
			return
		}
		defer form.close()
		req = createAIStudioJobJSON{
			Kind: r.FormValue("kind"), Prompt: r.FormValue("prompt"),
			SourceProjectPhotoID: r.FormValue("source_project_photo_id"),
			SourceStudioImageID:  r.FormValue("source_studio_image_id"),
		}
		// "file": diğer yükleme uçlarının alan adı; yanlışlıkla onu gönderen
		// istemci de çalışsın (belgelenen ad "image").
		image = form.file("image", "file")
		mask = form.file("mask")
	} else if strings.HasPrefix(r.Header.Get("Content-Type"), "application/json") {
		if err := httpjson.Decode(r, &req); err != nil {
			httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
			return
		}
	} else {
		h.writeError(w, errAIStudioBadBody)
		return
	}

	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	authz, _ := middleware.AuthzContextFromRequest(r.Context())
	job, quota, err := h.svc.CreateStudioJob(r.Context(), service.CreateAIStudioJobInput{
		OrganizationID: orgID, UserID: userID, Kind: req.Kind, Prompt: req.Prompt,
		Image: image, Mask: mask,
		SourceProjectPhotoID: req.SourceProjectPhotoID,
		// Kaynak proje fotoğrafı: fotoğrafın projesine okuma izni + üyelik
		// (proje ucundaki projPerm(operations.read) ile aynı kural).
		CanReadProject: func(ctx context.Context, projectID string) error {
			return h.requireProjectAccess(ctx, authz, projectID, domain.PermProjectsOperationsRead)
		},
		SourceStudioImageID: req.SourceStudioImageID,
		AnyUser:             seesFirmAI(authz),
	})
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusAccepted, map[string]any{
		"job": toAIStudioJobResponse(*job), "remaining": quota.Remaining, "limit": quota.MonthlyLimit,
		// quota (0081): kişinin kendi aylık hakkıyla birlikte tam hak bilgisi.
		"quota": toAIQuotaResponse(quota),
	})
}

// requireProjectAccess: gövdeden gelen proje için RequireProjectPermission'ın
// aynısı -- izin + proje üyeliği (Sahip/Yönetici muaf).
func (h *AIImageHandler) requireProjectAccess(ctx context.Context, authz *service.AuthzContext, projectID, perm string) error {
	if !authz.HasPermission(perm) {
		return errAIPermissionDenied
	}
	ok, err := h.authz.CanAccessProject(ctx, authz, projectID)
	if err != nil {
		return err
	}
	if !ok {
		return service.ErrAISourceAccessDenied
	}
	return nil
}

// GetStudioJob: GET /ai/studio/jobs/{jobId} -- yalnızca işi açan kişi.
func (h *AIImageHandler) GetStudioJob(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	job, err := h.svc.GetStudioJob(r.Context(), chi.URLParam(r, "jobId"), orgID, userID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toAIStudioJobResponse(*job))
}

// ListStudioImages: GET /ai/studio/images?limit=30&before=<zaman>&scope=mine|firm.
// scope=firm yalnızca Sahip/Yönetici (diğerlerine 403). pending_jobs her
// zaman çağıranın KENDİ süren işleri.
func (h *AIImageHandler) ListStudioImages(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	authz, _ := middleware.AuthzContextFromRequest(r.Context())
	allUsers := false
	switch q.Get("scope") {
	case "", "mine":
	case "firm":
		if !seesFirmAI(authz) {
			h.writeError(w, errAIFirmScopeDenied)
			return
		}
		allUsers = true
	default:
		httpjson.Error(w, http.StatusBadRequest, "geçersiz scope (mine ya da firm olmalı)")
		return
	}
	limit := 0
	if v := q.Get("limit"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 {
			httpjson.Error(w, http.StatusBadRequest, "geçersiz limit")
			return
		}
		limit = n
	}
	var before *time.Time
	if v := strings.TrimSpace(q.Get("before")); v != "" {
		// Kodlanmamış "+03:00" sorgu dizgesinde "+" -> boşluk olur.
		t, err := time.Parse(time.RFC3339Nano, strings.ReplaceAll(v, " ", "+"))
		if err != nil {
			httpjson.Error(w, http.StatusBadRequest, "geçersiz before (RFC3339 zaman olmalı)")
			return
		}
		before = &t
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	page, err := h.svc.ListStudioImages(r.Context(), service.AIStudioListInput{
		OrganizationID: orgID, UserID: userID, AllUsers: allUsers,
		AllProjects: authz.BypassesProjectMembership(), Limit: limit, Before: before,
	})
	if err != nil {
		h.writeError(w, err)
		return
	}
	images := make([]aiStudioImageResponse, len(page.Images))
	for i, img := range page.Images {
		images[i] = toAIStudioImageResponse(img)
	}
	pending := make([]aiStudioJobResponse, len(page.Pending))
	for i, j := range page.Pending {
		pending[i] = toAIStudioJobResponse(j)
	}
	var next *string
	if page.NextBefore != nil {
		s := studioTime(*page.NextBefore)
		next = &s
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"images": images, "pending_jobs": pending, "next_before": next})
}

// DownloadStudioImage: GET /ai/studio/images/{imageId}/content -- sahibi ya
// da firmada Sahip/Yönetici; diğerleri 404 (varlığı da sızmasın).
func (h *AIImageHandler) DownloadStudioImage(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	authz, _ := middleware.AuthzContextFromRequest(r.Context())
	img, rc, err := h.svc.OpenStudioImage(r.Context(), chi.URLParam(r, "imageId"), orgID, userID, seesFirmAI(authz))
	if err != nil {
		h.writeError(w, err)
		return
	}
	defer rc.Close()
	// Proje fotoğrafıyla aynı: <img>/Image.network ile gösterilsin diye inline,
	// nosniff içeriğin başka türden yorumlanmasını engeller.
	w.Header().Set("Content-Type", img.MIMEType)
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Content-Length", fmt.Sprintf("%d", img.SizeBytes))
	w.Header().Set("Cache-Control", "private, max-age=300")
	_, _ = io.Copy(w, rc)
}

// DeleteStudioImage: DELETE /ai/studio/images/{imageId} -- 204. Sahibi;
// Sahip/Yönetici herkesinkini. Yumuşak silme; projeye eklenmiş kopyalar kalır.
func (h *AIImageHandler) DeleteStudioImage(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	authz, _ := middleware.AuthzContextFromRequest(r.Context())
	if err := h.svc.DeleteStudioImage(r.Context(), chi.URLParam(r, "imageId"), orgID, userID, seesFirmAI(authz)); err != nil {
		h.writeError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

type addAIStudioImageToProjectRequest struct {
	ProjectID string `json:"project_id"`
	Stage     string `json:"stage"`
}

// AddStudioImageToProject: POST /ai/studio/images/{imageId}/add-to-project
// {project_id, stage} -- 200 {project_photo_id, already_added}. Fotoğraf
// yükleme kuralı: projects.operations.manage + proje erişimi + açık proje.
// Tekrar çağrı aynı fotoğrafı döner.
func (h *AIImageHandler) AddStudioImageToProject(w http.ResponseWriter, r *http.Request) {
	var req addAIStudioImageToProjectRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	projectID := strings.TrimSpace(req.ProjectID)
	if projectID == "" {
		h.writeError(w, errAIStudioProjectNeeded)
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	authz, _ := middleware.AuthzContextFromRequest(r.Context())
	if err := h.requireProjectAccess(r.Context(), authz, projectID, domain.PermProjectsOperationsManage); err != nil {
		h.writeError(w, err)
		return
	}
	photoID, created, err := h.svc.AddStudioImageToProject(r.Context(), service.AddAIStudioImageToProjectInput{
		OrganizationID: orgID, UserID: userID, ImageID: chi.URLParam(r, "imageId"),
		ProjectID: projectID, Stage: req.Stage, AnyUser: seesFirmAI(authz),
	})
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"project_photo_id": photoID, "already_added": !created})
}
