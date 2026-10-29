package handler

import (
	"errors"
	"net/http"

	"github.com/go-chi/chi/v5"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/httpapi/middleware"
	"github.com/Savanooo/ARVEND/backend/internal/platform/httpjson"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

// AIImageHandler: yapay zekâ görselleri (bkz. service/ai_image_service.go).
// İzin ve proje erişimi router'daki middleware'de; firma/proje/kişi kapsamı
// serviste.
type AIImageHandler struct {
	svc *service.AIImageService
}

func NewAIImageHandler(svc *service.AIImageService) *AIImageHandler {
	return &AIImageHandler{svc: svc}
}

// AIDisabledCode: 503'ün makine-okunur kodu -- uygulama girişleri gizler.
const AIDisabledCode = "ai_disabled"

type aiQuotaResponse struct {
	MonthlyLimit    int    `json:"monthly_limit"`
	UsedThisMonth   int    `json:"used_this_month"`
	Remaining       int    `json:"remaining"`
	UserHourlyLimit int    `json:"user_hourly_limit"`
	ResetsAt        string `json:"resets_at"`
}

func toAIQuotaResponse(q *domain.AIImageQuota) *aiQuotaResponse {
	if q == nil {
		return nil
	}
	return &aiQuotaResponse{
		MonthlyLimit: q.MonthlyLimit, UsedThisMonth: q.UsedThisMonth, Remaining: q.Remaining,
		UserHourlyLimit: q.UserHourlyLimit, ResetsAt: q.ResetsAt.Format(rfc3339),
	}
}

type aiUsageResponse struct {
	UserID   *string `json:"user_id"`
	FullName string  `json:"full_name"`
	Images   int     `json:"images"`
}

type aiStatusResponse struct {
	Enabled bool             `json:"enabled"`
	CanUse  bool             `json:"can_use"`
	Model   string           `json:"model,omitempty"`
	Quota   *aiQuotaResponse `json:"quota"`
	// UsageByUser yalnızca Sahip/Yönetici'ye döner.
	UsageByUser []aiUsageResponse `json:"usage_by_user,omitempty"`
}

type aiJobResponse struct {
	ID            string  `json:"id"`
	ProjectID     string  `json:"project_id"`
	Kind          string  `json:"kind"`
	Prompt        string  `json:"prompt"`
	SourcePhotoID *string `json:"source_photo_id"`
	Status        string  `json:"status"`
	Error         string  `json:"error"`
	ResultPhotoID *string `json:"result_photo_id"`
	Model         string  `json:"model"`
	CreatedAt     string  `json:"created_at"`
	StartedAt     *string `json:"started_at"`
	FinishedAt    *string `json:"finished_at"`
}

func toAIJobResponse(j domain.AIImageJob) aiJobResponse {
	return aiJobResponse{
		ID: j.ID, ProjectID: j.ProjectID, Kind: j.Kind, Prompt: j.Prompt, SourcePhotoID: j.SourcePhotoID,
		Status: j.Status, Error: j.Error, ResultPhotoID: j.ResultPhotoID, Model: j.Model,
		CreatedAt: j.CreatedAt.Format(rfc3339), StartedAt: tsStrPtr(j.StartedAt), FinishedAt: tsStrPtr(j.FinishedAt),
	}
}

// Status: GET /ai/status -- izin gerektirmez (girişleri gizlemek için her
// oturum sorar); hak yalnızca izni olana, kişi kişi kullanım yalnızca
// Sahip/Yönetici'ye.
func (h *AIImageHandler) Status(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	authz, _ := middleware.AuthzContextFromRequest(r.Context())
	canUse := authz.HasPermission(domain.PermAIImagesUse)
	seeUsage := authz != nil && (authz.RoleCode == domain.OrgRoleOwner || authz.RoleCode == domain.OrgRoleAdmin)
	st, err := h.svc.Status(r.Context(), orgID, canUse, seeUsage)
	if err != nil {
		h.writeError(w, err)
		return
	}
	resp := aiStatusResponse{Enabled: st.Enabled, CanUse: st.CanUse, Model: st.Model, Quota: toAIQuotaResponse(st.Quota)}
	if seeUsage {
		resp.UsageByUser = make([]aiUsageResponse, len(st.UsageByUser))
		for i, u := range st.UsageByUser {
			resp.UsageByUser[i] = aiUsageResponse{UserID: u.UserID, FullName: u.FullName, Images: u.Images}
		}
	}
	httpjson.Write(w, http.StatusOK, resp)
}

type createAIJobRequest struct {
	Kind          string `json:"kind"`
	Prompt        string `json:"prompt"`
	SourcePhotoID string `json:"source_photo_id"`
}

// CreateJob: POST /projects/{id}/ai-image-jobs -- 202 + iş (sırada) + kalan
// hak. Görsel arka planda üretilir; durum GET ile sorulur.
func (h *AIImageHandler) CreateJob(w http.ResponseWriter, r *http.Request) {
	if !h.svc.Enabled() {
		h.writeError(w, service.ErrAIDisabled)
		return
	}
	var req createAIJobRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	job, quota, err := h.svc.CreateJob(r.Context(), service.CreateAIImageJobInput{
		OrganizationID: orgID, ProjectID: chi.URLParam(r, "id"), UserID: userID,
		Kind: req.Kind, Prompt: req.Prompt, SourcePhotoID: req.SourcePhotoID,
	})
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusAccepted, map[string]any{"job": toAIJobResponse(*job), "quota": toAIQuotaResponse(quota)})
}

func (h *AIImageHandler) GetJob(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	job, err := h.svc.GetJob(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "jobId"), orgID, userID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toAIJobResponse(*job))
}

func (h *AIImageHandler) ListJobs(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	jobs, err := h.svc.ListJobs(r.Context(), chi.URLParam(r, "id"), orgID, userID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	out := make([]aiJobResponse, len(jobs))
	for i, j := range jobs {
		out[i] = toAIJobResponse(j)
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"jobs": out})
}

func (h *AIImageHandler) writeError(w http.ResponseWriter, err error) {
	var limit *service.AILimitError
	var notFound *service.NotFoundError
	switch {
	case errors.Is(err, service.ErrAIDisabled):
		httpjson.Write(w, http.StatusServiceUnavailable, map[string]string{"error": err.Error(), "code": AIDisabledCode})
	case errors.As(err, &limit):
		httpjson.Write(w, http.StatusTooManyRequests, map[string]any{
			"error": limit.Message, "code": limit.Code,
			"remaining": limit.Quota.Remaining, "monthly_limit": limit.Quota.MonthlyLimit,
			"quota": toAIQuotaResponse(&limit.Quota),
		})
	case errors.Is(err, service.ErrAIInvalidKind),
		errors.Is(err, service.ErrAIPromptRequired),
		errors.Is(err, service.ErrAIPromptTooLong),
		errors.Is(err, service.ErrAISourceRequired):
		httpjson.Error(w, http.StatusBadRequest, err.Error())
	case errors.Is(err, service.ErrAIJobNotFound):
		httpjson.Error(w, http.StatusNotFound, err.Error())
	case errors.As(err, &notFound):
		httpjson.Error(w, http.StatusNotFound, notFound.Error())
	case errors.Is(err, domain.ErrNotFound):
		httpjson.Error(w, http.StatusNotFound, "proje bulunamadı")
	case errors.Is(err, service.ErrProjectLocked):
		// Kapalı proje: metin nedenini ve ne yapılacağını söyler.
		httpjson.Error(w, http.StatusConflict, err.Error())
	default:
		writeInternalError(w, err)
	}
}
