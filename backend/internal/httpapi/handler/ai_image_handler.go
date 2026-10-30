package handler

import (
	"errors"
	"io"
	"mime"
	"net/http"

	"github.com/go-chi/chi/v5"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/httpapi/middleware"
	"github.com/Savanooo/ARVEND/backend/internal/platform/httpjson"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

// AIImageHandler: yapay zekâ görselleri (bkz. service/ai_image_service.go)
// ve Yapay Zekâ Stüdyo (ai_studio_handler.go). İzin ve URL'deki projenin
// erişimi router'daki middleware'de; stüdyoda gövdeden gelen projenin
// erişimi burada (authz); firma/proje/kişi kapsamı serviste.
type AIImageHandler struct {
	svc   *service.AIImageService
	authz *service.AuthorizationService
}

func NewAIImageHandler(svc *service.AIImageService, authz *service.AuthorizationService) *AIImageHandler {
	return &AIImageHandler{svc: svc, authz: authz}
}

// AIDisabledCode: 503'ün makine-okunur kodu -- uygulama girişleri gizler.
const AIDisabledCode = "ai_disabled"

type aiQuotaResponse struct {
	MonthlyLimit    int    `json:"monthly_limit"`
	UsedThisMonth   int    `json:"used_this_month"`
	Remaining       int    `json:"remaining"`
	UserHourlyLimit int    `json:"user_hourly_limit"`
	ResetsAt        string `json:"resets_at"`
	// Kişinin kendi aylık hakkı (0081); user_monthly_limit null = sınırsız.
	UserMonthlyLimit  *int `json:"user_monthly_limit"`
	UserUsedThisMonth int  `json:"user_used_this_month"`
	UserRemaining     *int `json:"user_remaining"`
}

func toAIQuotaResponse(q *domain.AIImageQuota) *aiQuotaResponse {
	if q == nil {
		return nil
	}
	return &aiQuotaResponse{
		MonthlyLimit: q.MonthlyLimit, UsedThisMonth: q.UsedThisMonth, Remaining: q.Remaining,
		UserHourlyLimit: q.UserHourlyLimit, ResetsAt: q.ResetsAt.Format(rfc3339),
		UserMonthlyLimit: q.UserMonthlyLimit, UserUsedThisMonth: q.UserUsedThisMonth, UserRemaining: q.UserRemaining,
	}
}

type aiUsageResponse struct {
	UserID   *string `json:"user_id"`
	FullName string  `json:"full_name"`
	Images   int     `json:"images"`
}

type aiStatusResponse struct {
	// Enabled: sunucu anahtarı VE firma anahtarı (eski uygulamalar buna bakar).
	Enabled       bool `json:"enabled"`
	ServerEnabled bool `json:"server_enabled"`
	FirmEnabled   bool `json:"firm_enabled"`
	CanUse        bool `json:"can_use"`
	// CanManage: Yapay Zekâ Ayarları açılabilir mi (aynı kapı: router).
	CanManage     bool             `json:"can_manage"`
	BlockedCode   string           `json:"blocked_code"`
	BlockedReason string           `json:"blocked_reason"`
	Model         string           `json:"model,omitempty"`
	Quota         *aiQuotaResponse `json:"quota"`
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
	userID, _ := middleware.UserIDFromContext(r.Context())
	authz, _ := middleware.AuthzContextFromRequest(r.Context())
	canUse := authz.HasPermission(domain.PermAIImagesUse)
	seeUsage := seesFirmAI(authz)
	st, err := h.svc.Status(r.Context(), orgID, userID, canUse, seeUsage)
	if err != nil {
		h.writeError(w, err)
		return
	}
	resp := aiStatusResponse{
		Enabled: st.Enabled, ServerEnabled: st.ServerEnabled, FirmEnabled: st.FirmEnabled,
		CanUse: st.CanUse, CanManage: canManageAI(r), BlockedCode: st.BlockedCode, BlockedReason: st.BlockedReason,
		Model: st.Model, Quota: toAIQuotaResponse(st.Quota),
	}
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
// hak. Görsel arka planda üretilir; durum GET ile sorulur. Gövde JSON (eski
// uygulamalar, değişmedi) ya da multipart/form-data (aynı alanlar + 'edit'
// için isteğe bağlı "mask" PNG dosyası, migration 0080).
func (h *AIImageHandler) CreateJob(w http.ResponseWriter, r *http.Request) {
	if !h.svc.Enabled() {
		h.writeError(w, service.ErrAIDisabled)
		return
	}
	var (
		req  createAIJobRequest
		mask io.Reader
	)
	if isMultipart(r) {
		form, err := parseAIMultipart(w, r)
		if err != nil {
			h.writeError(w, err)
			return
		}
		defer form.close()
		req = createAIJobRequest{Kind: r.FormValue("kind"), Prompt: r.FormValue("prompt"), SourcePhotoID: r.FormValue("source_photo_id")}
		mask = form.file("mask")
	} else if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	job, quota, err := h.svc.CreateJob(r.Context(), service.CreateAIImageJobInput{
		OrganizationID: orgID, ProjectID: chi.URLParam(r, "id"), UserID: userID,
		Kind: req.Kind, Prompt: req.Prompt, SourcePhotoID: req.SourcePhotoID, Mask: mask,
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

// seesFirmAI: Sahip/Yönetici -- firmanın kişi kişi kullanımını ve bütün
// stüdyo görsellerini görür (bkz. service/ai_studio_service.go başlık notu).
func seesFirmAI(authz *service.AuthzContext) bool {
	return authz != nil && (authz.RoleCode == domain.OrgRoleOwner || authz.RoleCode == domain.OrgRoleAdmin)
}

// errAIPermissionDenied / errAIProjectAccessDenied: middleware'in 403
// gövdeleriyle aynı kodlar (istemci aynı şekilde ayırt etsin).
var (
	errAIPermissionDenied    = errors.New("bu işlem için yetkiniz yok")
	errAIFirmScopeDenied     = errors.New("Firmanın bütün görsellerini yalnızca Sahip ve Yönetici görebilir")
	errAIStudioBadBody       = errors.New("İstek multipart/form-data ya da JSON olmalı")
	errAIStudioProjectNeeded = errors.New("Görselin ekleneceği projeyi seçin")
)

// aiMultipartOverhead: dosyanın yanındaki metin alanları (açıklama en çok
// 1000 karakter) ve maske (en çok 10 MB) için pay.
const aiMultipartOverhead = 11 << 20

func isMultipart(r *http.Request) bool {
	mt, _, _ := mime.ParseMediaType(r.Header.Get("Content-Type"))
	return mt == "multipart/form-data"
}

type aiMultipartForm struct {
	r      *http.Request
	opened []io.Closer
}

// parseAIMultipart: readUpload ile aynı sınırlama -- gövde MaxBytesReader
// ile kesilir, sınır aşımı 413 (ErrFileTooLarge), ham Go hatası yalnızca logda.
func parseAIMultipart(w http.ResponseWriter, r *http.Request) (*aiMultipartForm, error) {
	r.Body = http.MaxBytesReader(w, r.Body, service.MaxUploadBytes+aiMultipartOverhead)
	if err := r.ParseMultipartForm(8 << 20); err != nil {
		var tooLarge *http.MaxBytesError
		if errors.As(err, &tooLarge) {
			return nil, service.ErrFileTooLarge
		}
		return nil, errUploadUnreadable
	}
	return &aiMultipartForm{r: r}, nil
}

// file: alandaki dosya (yoksa nil). Dönen okuyucu close'ta kapanır.
func (f *aiMultipartForm) file(names ...string) io.Reader {
	for _, name := range names {
		if fhs := f.r.MultipartForm.File[name]; len(fhs) > 0 {
			file, err := fhs[0].Open()
			if err != nil {
				return failingReader{}
			}
			f.opened = append(f.opened, file)
			return file
		}
	}
	return nil
}

func (f *aiMultipartForm) close() {
	for _, c := range f.opened {
		_ = c.Close()
	}
	if f.r.MultipartForm != nil {
		_ = f.r.MultipartForm.RemoveAll()
	}
}

// failingReader: açılamayan dosya parçası -- servis "okunamadı" der.
type failingReader struct{}

func (failingReader) Read([]byte) (int, error) { return 0, errUploadUnreadable }

func (h *AIImageHandler) writeError(w http.ResponseWriter, err error) {
	var limit *service.AILimitError
	var notFound *service.NotFoundError
	switch {
	case errors.Is(err, errAIPermissionDenied):
		httpjson.Write(w, http.StatusForbidden, map[string]string{"error": err.Error(), "code": "permission_denied"})
	case errors.Is(err, errAIFirmScopeDenied):
		httpjson.Write(w, http.StatusForbidden, map[string]string{"error": err.Error(), "code": "permission_denied"})
	case errors.Is(err, service.ErrAISourceAccessDenied):
		httpjson.Write(w, http.StatusForbidden, map[string]string{"error": err.Error(), "code": "project_access_denied"})
	case errors.Is(err, service.ErrFileTooLarge):
		httpjson.Error(w, http.StatusRequestEntityTooLarge, err.Error())
	case errors.Is(err, service.ErrEmptyFile),
		errors.Is(err, service.ErrAIImageUnsupported),
		errors.Is(err, service.ErrAIImageHEIC),
		errors.Is(err, service.ErrAIImageUnreadable),
		errors.Is(err, service.ErrAIStudioTwoSources),
		errors.Is(err, service.ErrAIStudioGenerateSource),
		errors.Is(err, service.ErrAIStudioInvalidStage),
		errors.Is(err, service.ErrAIMaskOnlyEdit),
		errors.Is(err, service.ErrAIMaskNotPNG),
		errors.Is(err, service.ErrAIMaskTooLarge),
		errors.Is(err, service.ErrAIMaskUnreadable),
		errors.Is(err, service.ErrAIMaskEmpty),
		errors.Is(err, service.ErrAIMaskSourceType),
		errors.Is(err, service.ErrAIMaskSize),
		errors.Is(err, errUploadUnreadable),
		errors.Is(err, errAIStudioBadBody),
		errors.Is(err, errAIStudioProjectNeeded):
		httpjson.Error(w, http.StatusBadRequest, err.Error())
	case errors.Is(err, service.ErrAIStudioImageNotFound):
		httpjson.Error(w, http.StatusNotFound, err.Error())
	case errors.Is(err, service.ErrDuplicateContent):
		httpjson.Error(w, http.StatusConflict, err.Error())
	case errors.Is(err, service.ErrAIDisabledByAdmin):
		httpjson.Write(w, http.StatusForbidden, map[string]string{"error": err.Error(), "code": service.AIDisabledByAdminCode})
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
