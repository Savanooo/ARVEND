package service

// Yapay zekâ görselleri (migration 0079): "önce/sonra" (şantiye fotoğrafı +
// açıklamadan bitmiş hali), "fotoğrafı iyileştir" ve "yeni görsel oluştur".
// Görseli firmanın kendi OpenAI anahtarıyla bu sunucu üretir; anahtar
// dosyada durur (OPENAI_API_KEY_FILE), veritabanına ve loglara girmez.
//
// Akış ASENKRON: bir görsel onlarca saniye (belgeye göre 2 dakikaya kadar)
// sürer, Cloudflare/Caddy ~100 sn'de keser. POST işi "sırada" açar ve hemen
// döner; bu süreçteki sınırlı sayıda işçi (AI_IMAGE_WORKERS) sıradaki işi
// alır, OpenAI'ye gönderir, sonucu projeye YENİ fotoğraf olarak ekler;
// uygulama GET ile durumu sorar. Kaynak fotoğrafın üzerine asla yazılmaz.
//
// Tek sunucu varsayımı: üretimde tek API süreci çalışır (systemd). Açılışta
// sırada/çalışırken kalan işler "başarısız" yapılır (RecoverInterrupted) --
// ikinci bir süreç açılırsa ötekinin çalışan işlerini de kapatırdı.

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"image"
	"image/gif"
	"image/png"
	"io"
	"log"
	"net/http"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/platform/openai"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

// ImageGenerator: OpenAI istemcisinin servisin kullandığı yüzü (testlerde
// gerçek istemci sahte sunucuya bağlanır).
type ImageGenerator interface {
	CreateImage(ctx context.Context, req openai.ImageRequest) (*openai.ImageResult, error)
}

// AIImageConfig: ortam değişkenlerinden (bkz. config.Config).
type AIImageConfig struct {
	Model           string // OPENAI_IMAGE_MODEL
	Quality         string // OPENAI_IMAGE_QUALITY
	MonthlyLimit    int    // AI_IMAGE_MONTHLY_LIMIT, firma başına
	UserHourlyLimit int    // AI_IMAGE_USER_HOURLY_LIMIT, kişi başına
	Workers         int    // AI_IMAGE_WORKERS, aynı anda çalışan iş
}

const (
	aiPromptMaxRunes = 1000
	// Kişi başına aynı anda sırada/çalışan iş: biri sırayı doldurup
	// herkesi bekletmesin.
	aiMaxActivePerUser = 2
	// Tek işin üst süresi: istemci 4 dk bekler, kayıt payı.
	aiJobTimeout = 5 * time.Minute
	// Uyandırma kaçarsa (ör. sinyal anında bütün işçiler meşguldü) sıraya
	// en geç bu aralıkla bakılır.
	aiPollInterval = 30 * time.Second
	// Firma başına sayım+ekleme kilidi (bkz. AIImageQuotaXactLock); fiyat
	// senkronunun 450045/450046 sınıflarıyla çakışmaz.
	aiQuotaLockClass int32 = 450079
)

var aiQualities = map[string]bool{"low": true, "medium": true, "high": true, "xhigh": true, "max": true, "auto": true}

var (
	// ErrAIDisabled: sunucuda anahtar yok -- handler 503 + bu metin.
	ErrAIDisabled       = errors.New("Yapay zekâ özelliği bu sunucuda ayarlı değil")
	ErrAIInvalidKind    = errors.New("Geçersiz görsel türü")
	ErrAIPromptRequired = errors.New("Ne yapılacağını kısaca yazın (ör. \"Alçıpan asma tavan, spot ışıklı\")")
	ErrAIPromptTooLong  = fmt.Errorf("Açıklama en fazla %d karakter olabilir", aiPromptMaxRunes)
	ErrAISourceRequired = errors.New("Bu işlem için bir fotoğraf seçin")
	ErrAIJobNotFound    = errors.New("görsel işi bulunamadı")
)

// AILimitError: aylık firma hakkı, kişi başı saatlik sınır ya da kişinin
// süren işleri -- handler 429, Code ve kalan hakla.
type AILimitError struct {
	Code    string // ai_monthly_limit | ai_user_rate_limit | ai_user_busy
	Message string
	Quota   domain.AIImageQuota
}

func (e *AILimitError) Error() string { return e.Message }

// aiJobError: işin kullanıcıya gösterilecek Türkçe nedeni.
type aiJobError struct{ msg string }

func (e *aiJobError) Error() string { return e.msg }

const aiInterruptedMessage = "Sunucu yeniden başlatıldığı için görsel tamamlanamadı; lütfen tekrar deneyin."

type AIImageService struct {
	pool     *pgxpool.Pool
	q        *sqlc.Queries
	projects *ProjectService
	gen      ImageGenerator
	cfg      AIImageConfig
	wake     chan struct{}
	now      func() time.Time
	// scope: doluysa işçi ve açılış kurtarması yalnızca bu firmanın işlerine
	// dokunur (bkz. ScopeToOrganization). Üretimde boş: bütün firmalar.
	scope pgtype.UUID
}

// NewAIImageService: gen nil ise özellik kapalıdır (anahtar yok); uçlar 503
// döner, durum ucu "kapalı" der.
func NewAIImageService(pool *pgxpool.Pool, q *sqlc.Queries, projects *ProjectService, gen ImageGenerator, cfg AIImageConfig) *AIImageService {
	if strings.TrimSpace(cfg.Model) == "" {
		cfg.Model = openai.DefaultImageModel
	}
	if !aiQualities[cfg.Quality] {
		cfg.Quality = "medium"
	}
	if cfg.MonthlyLimit < 0 {
		cfg.MonthlyLimit = 0
	}
	if cfg.UserHourlyLimit < 0 {
		cfg.UserHourlyLimit = 0
	}
	if cfg.Workers < 1 {
		cfg.Workers = 1
	}
	return &AIImageService{
		pool: pool, q: q, projects: projects, gen: gen, cfg: cfg,
		wake: make(chan struct{}, cfg.Workers),
		now:  time.Now,
	}
}

func (s *AIImageService) Enabled() bool { return s.gen != nil }

func (s *AIImageService) Config() AIImageConfig { return s.cfg }

// SetClock: testlerde ay/saat sınırını sabitlemek için.
func (s *AIImageService) SetClock(now func() time.Time) { s.now = now }

// ScopeToOrganization: işçiyi ve RecoverInterrupted'ı tek firmaya sınırlar.
// Aynı veritabanını paylaşan test paketleri paralel koşar; biri ötekinin
// sıradaki işini alıp kendi sahte sunucusuna göndermesin.
func (s *AIImageService) ScopeToOrganization(organizationID string) error {
	id, err := repository.StringToUUID(organizationID)
	if err != nil {
		return err
	}
	s.scope = id
	return nil
}

// monthWindow: İstanbul takvim ayının başı ve bir sonraki ayın başı.
func (s *AIImageService) monthWindow() (time.Time, time.Time) {
	n := s.now().In(IstanbulLocation())
	start := time.Date(n.Year(), n.Month(), 1, 0, 0, 0, 0, IstanbulLocation())
	return start, start.AddDate(0, 1, 0)
}

// quota: firmanın bu ayki hakkı (etkin sınırla, bkz. firmLimits) ve
// kişinin kendi aylık hakkı (Yapay Zekâ Ayarları, 0081).
func (s *AIImageService) quota(lim aiFirmLimits, used, userUsed int) domain.AIImageQuota {
	_, reset := s.monthWindow()
	remaining := lim.MonthlyLimit - used
	if remaining < 0 {
		remaining = 0
	}
	q := domain.AIImageQuota{
		MonthlyLimit: lim.MonthlyLimit, UsedThisMonth: used, Remaining: remaining,
		UserHourlyLimit: s.cfg.UserHourlyLimit, ResetsAt: reset,
		UserMonthlyLimit: lim.PerUserMonthlyLimit, UserUsedThisMonth: userUsed,
	}
	if lim.PerUserMonthlyLimit != nil {
		r := *lim.PerUserMonthlyLimit - userUsed
		if r < 0 {
			r = 0
		}
		q.UserRemaining = &r
	}
	return q
}

// Status: uygulama girişleri buna göre gösterir. canUse kişinin izni
// (ai.images.use); seeUsage Sahip/Yönetici -- firmanın bu ayki kullanımını
// kişi kişi görür. Hakkı yalnızca izni olan ya da Sahip/Yönetici görür.
// FirmEnabled ve Blocked (0081): yönetici kapattıysa ya da kişinin/firmanın
// aylık hakkı dolduysa uygulama nedeni gösterip "Oluştur"u kapatır --
// sunucu yine CreateJob'da reddeder, bu yalnızca önden bilgi.
func (s *AIImageService) Status(ctx context.Context, organizationID, userID string, canUse, seeUsage bool) (*domain.AIImageStatus, error) {
	st := &domain.AIImageStatus{ServerEnabled: s.Enabled(), FirmEnabled: true, CanUse: canUse}
	if s.Enabled() {
		st.Model = s.cfg.Model
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	lim, err := s.firmLimits(ctx, s.q, orgID)
	if err != nil {
		return nil, err
	}
	st.FirmEnabled = lim.Enabled
	// Enabled = sunucu anahtarı VE firma anahtarı: eski uygulamalar
	// (1.5.23 ve öncesi) yalnızca buna bakar; kapalı firmada girişleri
	// gizlerler, reddedilecek istek açtırmazlar.
	st.Enabled = st.ServerEnabled && st.FirmEnabled
	if !canUse && !seeUsage {
		return st, nil
	}
	start, _ := s.monthWindow()
	since := pgtype.Timestamptz{Time: start, Valid: true}
	used, err := s.q.CountOrgAIImageJobsSince(ctx, sqlc.CountOrgAIImageJobsSinceParams{
		OrganizationID: orgID, Since: since,
	})
	if err != nil {
		return nil, err
	}
	userUsed := 0
	if uid, err := repository.StringToUUID(userID); err == nil {
		n, err := s.q.CountUserMonthlyAIImageJobs(ctx, sqlc.CountUserMonthlyAIImageJobsParams{
			OrganizationID: orgID, UserID: uid, Since: since,
		})
		if err != nil {
			return nil, err
		}
		userUsed = int(n)
	}
	q := s.quota(lim, int(used), userUsed)
	st.Quota = &q
	if canUse && st.ServerEnabled {
		if err := monthlyLimitError(lim, q); err != nil {
			st.BlockedCode, st.BlockedReason = aiBlockedCode(err), err.Error()
		}
	}
	if seeUsage {
		rows, err := s.q.ListOrgAIImageUsageByUser(ctx, sqlc.ListOrgAIImageUsageByUserParams{
			OrganizationID: orgID, Since: since,
		})
		if err != nil {
			return nil, err
		}
		st.UsageByUser = make([]domain.AIImageUsage, len(rows))
		for i, r := range rows {
			u := domain.AIImageUsage{FullName: r.FullName, Images: int(r.Images)}
			if r.UserID.Valid {
				id := r.UserID.String()
				u.UserID = &id
			}
			st.UsageByUser[i] = u
		}
	}
	return st, nil
}

type CreateAIImageJobInput struct {
	OrganizationID string
	ProjectID      string
	UserID         string
	Kind           string
	Prompt         string
	// SourcePhotoID: önce/sonra, iyileştirme ve düzenlemede zorunlu, yeni
	// görselde isteğe bağlı referans. Aynı projenin silinmemiş fotoğrafı olmalı.
	SourcePhotoID string
	// Mask: yalnızca 'edit' -- kalemle boyanan alan (PNG, saydam = değişecek
	// yer, kaynak fotoğrafla aynı piksel boyutunda; bkz. ai_mask.go).
	Mask io.Reader
}

// CreateJob: işi "sırada" açar ve işçiyi uyandırır. Sınırlar firma başına
// tek sırada sayılır (danışma kilidi): aynı anda gelen istekler aylık hakkı
// birlikte aşamaz.
func (s *AIImageService) CreateJob(ctx context.Context, in CreateAIImageJobInput) (*domain.AIImageJob, *domain.AIImageQuota, error) {
	if !s.Enabled() {
		return nil, nil, ErrAIDisabled
	}
	if !domain.ValidAIImageKind(in.Kind) {
		return nil, nil, ErrAIInvalidKind
	}
	prompt := strings.TrimSpace(in.Prompt)
	if utf8.RuneCountInString(prompt) > aiPromptMaxRunes {
		return nil, nil, ErrAIPromptTooLong
	}
	if prompt == "" && in.Kind != domain.AIImageKindEnhance {
		return nil, nil, ErrAIPromptRequired
	}
	sourceID := strings.TrimSpace(in.SourcePhotoID)
	if sourceID == "" && in.Kind != domain.AIImageKindGenerate {
		return nil, nil, ErrAISourceRequired
	}
	var maskData []byte
	if in.Mask != nil {
		if in.Kind != domain.AIImageKindEdit {
			return nil, nil, ErrAIMaskOnlyEdit
		}
		var err error
		if maskData, err = readAIMask(in.Mask); err != nil {
			return nil, nil, err
		}
	}
	pid, orgID, err := s.projects.scopedIDs(in.ProjectID, in.OrganizationID)
	if err != nil {
		return nil, nil, err
	}
	uid, err := repository.StringToUUID(in.UserID)
	if err != nil {
		return nil, nil, domain.ErrNotFound
	}
	maskKey := ""
	committed := false
	defer func() {
		if !committed && maskKey != "" {
			_ = s.projects.store.Delete(context.WithoutCancel(ctx), maskKey)
		}
	}()

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	// Proje bu firmanın ve açık olmalı (kapalı projeye fotoğraf eklenmez --
	// UploadPhoto ile aynı kural ve metin).
	if _, err := s.projects.requireOpenProjectForOps(ctx, txq, pid, orgID); err != nil {
		return nil, nil, err
	}
	var source pgtype.UUID
	if sourceID != "" {
		phid, err := repository.StringToUUID(sourceID)
		if err != nil {
			return nil, nil, &NotFoundError{What: "Kaynak fotoğraf"}
		}
		// Firma + proje şartı: başka projenin (ya da firmanın) fotoğrafı
		// kimliği bilinse bile kaynak olamaz.
		photo, err := txq.GetProjectPhoto(ctx, sqlc.GetProjectPhotoParams{ID: phid, OrganizationID: orgID, ProjectID: pid})
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return nil, nil, &NotFoundError{What: "Kaynak fotoğraf"}
			}
			return nil, nil, err
		}
		source = photo.ID
		if maskData != nil {
			// Maske kaynağın piksel boyutunda olmalı: kaynağı açıp bakılır.
			if maskKey, err = s.storeAIMask(ctx, orgID, photo.ObjectKey, maskData); err != nil {
				return nil, nil, err
			}
		}
	}

	if err := txq.AIImageQuotaXactLock(ctx, sqlc.AIImageQuotaXactLockParams{
		LockClass: aiQuotaLockClass, LockKey: orgID.String(),
	}); err != nil {
		return nil, nil, err
	}
	usage, err := s.checkLimits(ctx, txq, orgID, uid)
	if err != nil {
		return nil, nil, err
	}

	row, err := txq.CreateAIImageJob(ctx, sqlc.CreateAIImageJobParams{
		OrganizationID: orgID, ProjectID: pid, UserID: uid, Kind: in.Kind,
		Prompt: prompt, SourcePhotoID: source, Model: s.cfg.Model, MaskStorageKey: maskKey,
	})
	if err != nil {
		return nil, nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, nil, err
	}
	committed = true
	s.signal()
	job := repository.ToDomainAIImageJob(row)
	after := s.after(usage)
	return &job, &after, nil
}

// aiUsage: checkLimits'in kilit altında saydığı bu ayki kullanım -- iş
// açıldıktan sonraki kalan hak bundan hesaplanır.
type aiUsage struct {
	lim            aiFirmLimits
	used, userUsed int
}

// after: yeni iş eklendikten sonraki hak.
func (s *AIImageService) after(u aiUsage) domain.AIImageQuota {
	return s.quota(u.lim, u.used+1, u.userUsed+1)
}

// monthlyLimitError: yönetici kapatması, firmanın ve kişinin aylık hakkı
// (Yapay Zekâ Ayarları, 0081). checkLimits ve Status AYNI kuralı kullanır:
// uygulamanın gösterdiği neden ile sunucunun reddi ayrışmasın.
func monthlyLimitError(lim aiFirmLimits, q domain.AIImageQuota) error {
	if !lim.Enabled {
		return ErrAIDisabledByAdmin
	}
	if q.UsedThisMonth >= lim.MonthlyLimit {
		return &AILimitError{
			Code: "ai_monthly_limit", Quota: q,
			Message: fmt.Sprintf("Bu ayın yapay zekâ görsel hakkı doldu (%d/%d). Yeni hak %s tarihinde açılır.",
				q.UsedThisMonth, lim.MonthlyLimit, q.ResetsAt.Format("02.01.2006")),
		}
	}
	if lim.PerUserMonthlyLimit != nil && q.UserUsedThisMonth >= *lim.PerUserMonthlyLimit {
		return &AILimitError{
			Code: "ai_user_monthly_limit", Quota: q,
			Message: fmt.Sprintf("Bu ay sana ayrılan yapay zekâ hakkı doldu (%d/%d)",
				q.UserUsedThisMonth, *lim.PerUserMonthlyLimit),
		}
	}
	return nil
}

func aiBlockedCode(err error) string {
	var limit *AILimitError
	if errors.As(err, &limit) {
		return limit.Code
	}
	if errors.Is(err, ErrAIDisabledByAdmin) {
		return AIDisabledByAdminCode
	}
	return ""
}

// checkLimits: yönetici kapatması, aylık firma ve kişi hakkı, kişinin
// süren işleri ve kişi başı saatlik sınır. Proje ve stüdyo işleri AYNI
// sayımdan geçer (hepsi ai_image_jobs'ta). Kesin karar firma danışma kilidi
// altında verilir (AIImageQuotaXactLock); kilitsiz çağrı yalnızca erken ret
// içindir (ör. stüdyo yüklemesini depoya yazmadan önce).
func (s *AIImageService) checkLimits(ctx context.Context, q *sqlc.Queries, orgID, uid pgtype.UUID) (aiUsage, error) {
	lim, err := s.firmLimits(ctx, q, orgID)
	if err != nil {
		return aiUsage{}, err
	}
	if !lim.Enabled {
		return aiUsage{}, ErrAIDisabledByAdmin
	}
	monthStart, _ := s.monthWindow()
	since := pgtype.Timestamptz{Time: monthStart, Valid: true}
	used, err := q.CountOrgAIImageJobsSince(ctx, sqlc.CountOrgAIImageJobsSinceParams{
		OrganizationID: orgID, Since: since,
	})
	if err != nil {
		return aiUsage{}, err
	}
	userUsed, err := q.CountUserMonthlyAIImageJobs(ctx, sqlc.CountUserMonthlyAIImageJobsParams{
		OrganizationID: orgID, UserID: uid, Since: since,
	})
	if err != nil {
		return aiUsage{}, err
	}
	quota := s.quota(lim, int(used), int(userUsed))
	if err := monthlyLimitError(lim, quota); err != nil {
		return aiUsage{}, err
	}
	active, err := q.CountUserActiveAIImageJobs(ctx, sqlc.CountUserActiveAIImageJobsParams{OrganizationID: orgID, UserID: uid})
	if err != nil {
		return aiUsage{}, err
	}
	if active >= aiMaxActivePerUser {
		return aiUsage{}, &AILimitError{
			Code: "ai_user_busy", Quota: quota,
			Message: "Önceki görselleriniz hâlâ hazırlanıyor; biri bitince yenisini isteyin.",
		}
	}
	hourly, err := q.CountUserAIImageJobsSince(ctx, sqlc.CountUserAIImageJobsSinceParams{
		OrganizationID: orgID, UserID: uid, Since: pgtype.Timestamptz{Time: s.now().Add(-time.Hour), Valid: true},
	})
	if err != nil {
		return aiUsage{}, err
	}
	if int(hourly) >= s.cfg.UserHourlyLimit {
		return aiUsage{}, &AILimitError{
			Code: "ai_user_rate_limit", Quota: quota,
			Message: fmt.Sprintf("Bir saatte en fazla %d görsel isteyebilirsiniz; biraz sonra tekrar deneyin. Bu ay kalan hak: %d.",
				s.cfg.UserHourlyLimit, quota.Remaining),
		}
	}
	return aiUsage{lim: lim, used: int(used), userUsed: int(userUsed)}, nil
}

// signal: boştaki bir işçiyi uyandırır; hepsi meşgulse bloklamaz (işini
// bitiren işçi sıraya yeniden bakar).
func (s *AIImageService) signal() {
	select {
	case s.wake <- struct{}{}:
	default:
	}
}

// GetJob: yalnızca işi açan kişi, aynı firma ve projede.
func (s *AIImageService) GetJob(ctx context.Context, projectID, jobID, organizationID, userID string) (*domain.AIImageJob, error) {
	pid, orgID, err := s.projects.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, ErrAIJobNotFound
	}
	jid, err := repository.StringToUUID(jobID)
	if err != nil {
		return nil, ErrAIJobNotFound
	}
	uid, err := repository.StringToUUID(userID)
	if err != nil {
		return nil, ErrAIJobNotFound
	}
	row, err := s.q.GetAIImageJob(ctx, sqlc.GetAIImageJobParams{ID: jid, OrganizationID: orgID, ProjectID: pid, UserID: uid})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrAIJobNotFound
		}
		return nil, err
	}
	job := repository.ToDomainAIImageJob(row)
	return &job, nil
}

// ListJobs: kişinin bu projedeki son 20 işi -- uygulama yeniden açılınca
// süren işleri tanısın.
func (s *AIImageService) ListJobs(ctx context.Context, projectID, organizationID, userID string) ([]domain.AIImageJob, error) {
	pid, orgID, err := s.projects.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	uid, err := repository.StringToUUID(userID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	rows, err := s.q.ListUserProjectAIImageJobs(ctx, sqlc.ListUserProjectAIImageJobsParams{OrganizationID: orgID, ProjectID: pid, UserID: uid})
	if err != nil {
		return nil, err
	}
	out := make([]domain.AIImageJob, len(rows))
	for i, r := range rows {
		out[i] = repository.ToDomainAIImageJob(r)
	}
	return out, nil
}

// RecoverInterrupted: açılışta, işçiler başlamadan ÖNCE çağrılır. Önceki
// süreçte yarım kalan işlerin sonucu hiçbir zaman gelmeyecek; "hazırlanıyor"
// diye sonsuza dek beklemesinler.
func (s *AIImageService) RecoverInterrupted(ctx context.Context) (int64, error) {
	return s.q.FailInterruptedAIImageJobs(ctx, sqlc.FailInterruptedAIImageJobsParams{
		Error: aiInterruptedMessage, OrganizationID: s.scope,
	})
}

// Run: işçileri başlatır, ctx iptal edilince (kapatma) döner. Kapatmada
// süren OpenAI çağrısı iptal edilir, iş "başarısız" kaydedilir.
func (s *AIImageService) Run(ctx context.Context) {
	if !s.Enabled() {
		return
	}
	var wg sync.WaitGroup
	for i := 0; i < s.cfg.Workers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			s.workerLoop(ctx)
		}()
	}
	wg.Wait()
}

func (s *AIImageService) workerLoop(ctx context.Context) {
	ticker := time.NewTicker(aiPollInterval)
	defer ticker.Stop()
	for {
		for ctx.Err() == nil {
			processed, err := s.ProcessNext(ctx)
			if err != nil {
				if ctx.Err() == nil {
					log.Printf("UYARI: yapay zekâ işi alınamadı: %v", err)
				}
				break
			}
			if !processed {
				break
			}
		}
		select {
		case <-ctx.Done():
			return
		case <-s.wake:
		case <-ticker.C:
		}
	}
}

// ProcessNext: sıradaki işi alır ve sonuna kadar çalıştırır; sırada iş
// yoksa false. Testler işçiyi beklemeden bununla ilerletir.
func (s *AIImageService) ProcessNext(ctx context.Context) (bool, error) {
	row, err := s.q.ClaimNextAIImageJob(ctx, s.scope)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return false, nil
		}
		return false, err
	}
	s.runJob(ctx, repository.ToDomainAIImageJob(row))
	return true, nil
}

func (s *AIImageService) runJob(ctx context.Context, job domain.AIImageJob) {
	// Bitiş kaydı, kapatma sinyaliyle iptal edilmiş ctx'ten bağımsız yazılır.
	finish := func() (context.Context, context.CancelFunc) {
		return context.WithTimeout(context.WithoutCancel(ctx), 15*time.Second)
	}
	fail := func(cause error) {
		msg := aiFailureMessage(cause)
		if ctx.Err() != nil {
			msg = aiInterruptedMessage
		}
		// Teknik ayrıntı yalnızca logda (anahtar istemci hatalarına hiç girmez).
		log.Printf("yapay zekâ görseli üretilemedi (iş %s, firma %s, tür %s): %v", job.ID, job.OrganizationID, job.Kind, cause)
		fctx, cancel := finish()
		defer cancel()
		jid, _ := repository.StringToUUID(job.ID)
		if err := s.q.FailAIImageJob(fctx, sqlc.FailAIImageJobParams{ID: jid, Error: truncateRunes(msg, 500)}); err != nil {
			log.Printf("UYARI: yapay zekâ işi başarısız olarak kaydedilemedi (iş %s): %v", job.ID, err)
		}
	}
	defer func() {
		if r := recover(); r != nil {
			fail(fmt.Errorf("panic: %v", r))
		}
	}()

	jobCtx, cancel := context.WithTimeout(ctx, aiJobTimeout)
	defer cancel()
	if err := s.produce(jobCtx, job); err != nil {
		fail(err)
	}
}

// produce: kaynağı okur, OpenAI'ye gönderir, sonucu fotoğraf olarak kaydeder
// ve işi aynı transaction'da "bitti" yapar.
func (s *AIImageService) produce(ctx context.Context, job domain.AIImageJob) error {
	if s.gen == nil {
		return ErrAIDisabled
	}
	var (
		images      []openai.InputImage
		sourceStage string
	)
	if job.SourceStorageKey != "" {
		// Stüdyo işi (0080): kaynak, iş açılırken depoya kopyalanmış görsel --
		// proje fotoğrafından açıldıysa da o fotoğrafa artık bakılmaz.
		img, err := s.readStudioSource(ctx, job.SourceStorageKey)
		if err != nil {
			return err
		}
		images = append(images, img)
	} else if job.SourcePhotoID != nil && !job.IsStudio() {
		photo, rc, err := s.projects.OpenPhoto(ctx, job.ProjectID, *job.SourcePhotoID, job.OrganizationID)
		if err != nil {
			if errors.Is(err, domain.ErrNotFound) {
				return &aiJobError{"Kaynak fotoğraf silinmiş; başka bir fotoğrafla tekrar deneyin."}
			}
			return err
		}
		data, err := io.ReadAll(io.LimitReader(rc, MaxUploadBytes+1))
		rc.Close()
		if err != nil {
			return err
		}
		img, err := prepareAIInputImage(data)
		if err != nil {
			return err
		}
		images = append(images, img)
		sourceStage = photo.Stage
	} else if job.Kind != domain.AIImageKindGenerate {
		// Kaynak, iş açıldıktan sonra kalıcı silinmiş (bağ boşaldı).
		return &aiJobError{"Kaynak fotoğraf silinmiş; başka bir fotoğrafla tekrar deneyin."}
	}

	prompt := buildAIImagePrompt(job.Kind, job.Prompt, len(images) > 0)
	if job.IsStudio() {
		prompt = buildAIStudioPrompt(job.Kind, job.Prompt)
	}
	var mask *openai.InputImage
	if job.MaskStorageKey != "" {
		if len(images) == 0 {
			return &aiJobError{"Kaynak fotoğraf silinmiş; başka bir fotoğrafla tekrar deneyin."}
		}
		maskData, err := s.readAIMaskObject(ctx, job.MaskStorageKey)
		if err != nil {
			return err
		}
		if images[0], mask, err = prepareMaskedEdit(images[0], maskData); err != nil {
			return err
		}
		prompt += aiMaskPromptSuffix
	}
	req := openai.ImageRequest{
		Model:   job.Model,
		Prompt:  prompt,
		Mask:    mask,
		Images:  images,
		Size:    "auto", // düzenlemede kaynağın en-boy oranına yakın boyut
		Quality: s.cfg.Quality,
		// JPEG: fotoğraf için PNG'nin onda biri boyut; galeri ve paylaşım hızlı.
		OutputFormat:     "jpeg",
		SafetyIdentifier: aiSafetyIdentifier(job),
	}
	// input_fidelity yalnızca gpt-image-1.5'te; gpt-image-2 ailesinde
	// gönderilmemeli (belge). Aynı oda/aynı açı için yüksek sadakat.
	if len(images) > 0 && strings.HasPrefix(job.Model, "gpt-image-1.5") {
		req.InputFidelity = "high"
	}
	res, err := s.gen.CreateImage(ctx, req)
	if err != nil {
		return err
	}
	mime := http.DetectContentType(res.Data)
	ext, ok := map[string]string{"image/jpeg": ".jpg", "image/png": ".png", "image/webp": ".webp"}[mime]
	if !ok {
		return fmt.Errorf("openai: beklenmeyen görsel türü %q", mime)
	}
	if job.IsStudio() {
		return s.saveStudioResult(ctx, job, res.Data, mime, ext)
	}
	return s.saveResult(ctx, job, res.Data, ext, aiResultStage(job.Kind, sourceStage))
}

// saveResult: üretilen görseli projeye YENİ fotoğraf olarak ekler (yapay
// zekâ işaretli) ve işi aynı transaction'da bitirir -- "fotoğraf eklendi
// ama iş hâlâ çalışıyor" ya da tersi oluşmaz. Proje bu arada kapandıysa
// görsel eklenmez (UploadPhoto ile aynı kural).
func (s *AIImageService) saveResult(ctx context.Context, job domain.AIImageJob, data []byte, ext, stage string) error {
	pid, orgID, err := s.projects.scopedIDs(job.ProjectID, job.OrganizationID)
	if err != nil {
		return err
	}
	jid, err := repository.StringToUUID(job.ID)
	if err != nil {
		return err
	}
	var userID string
	if job.UserID != nil {
		userID = *job.UserID
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)
	if _, err := s.projects.requireOpenProjectForOps(ctx, txq, pid, orgID); err != nil {
		return err
	}

	name := fmt.Sprintf("yapay-zeka-%s-%s%s", aiKindSlug(job.Kind), IstanbulNow(s.now()).Format("20060102-150405"), ext)
	obj, key, err := s.projects.storeUpload(ctx, "photos", orgID.String(), pid.String(), name, bytes.NewReader(data), true)
	if err != nil {
		return err
	}
	var source pgtype.UUID
	if job.SourcePhotoID != nil {
		source, _ = repository.StringToUUID(*job.SourcePhotoID)
	}
	kind := job.Kind
	row, err := txq.CreateAIProjectPhoto(ctx, sqlc.CreateAIProjectPhotoParams{
		OrganizationID: orgID, ProjectID: pid, OriginalName: name, ObjectKey: key,
		MimeType: obj.MIMEType, SizeBytes: obj.Size, Sha256: obj.SHA256, Stage: stage,
		Description: truncateRunes(aiPhotoDescription(job.Kind, job.Prompt), maxUploadDescRunes),
		UploadedBy:  actorUUID(userID), AiKind: &kind, AiPrompt: job.Prompt, AiSourcePhotoID: source,
	})
	if err != nil {
		_ = s.projects.store.Delete(ctx, key)
		if isUniqueViolation(err) {
			return &aiJobError{"Aynı görsel bu projede zaten var."}
		}
		return err
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventAIPhotoCreated, actorUUID(userID),
		map[string]any{"photo_id": row.ID.String(), "stage": stage, "ai_kind": job.Kind}); err != nil {
		_ = s.projects.store.Delete(ctx, key)
		return err
	}
	if err := txq.CompleteAIImageJob(ctx, sqlc.CompleteAIImageJobParams{ID: jid, ResultPhotoID: row.ID}); err != nil {
		_ = s.projects.store.Delete(ctx, key)
		return err
	}
	if err := tx.Commit(ctx); err != nil {
		_ = s.projects.store.Delete(ctx, key)
		return err
	}
	return nil
}

// buildAIImagePrompt: türe göre sunucu tarafı İngilizce talimat (model
// İngilizce talimatta daha tutarlı) + kullanıcının Türkçe açıklaması.
func buildAIImagePrompt(kind, userText string, hasImage bool) string {
	quoted := `"` + strings.ReplaceAll(strings.TrimSpace(userText), `"`, "'") + `"`
	switch kind {
	case domain.AIImageKindBeforeAfter:
		return "Photorealistic renovation visualization of the same room or construction site shown in the input photo. " +
			"Keep the same room, the same perspective and camera angle, the same framing, and keep walls, windows and doors in the same places. " +
			"Show the finished result after this work has been completed (the description is in Turkish): " + quoted + ". " +
			"Clean, finished, professional workmanship with realistic materials and natural lighting. No people, no text, no watermark."
	case domain.AIImageKindEdit:
		// Serbest düzenleme (0080): yalnızca istenen değişiklik, gerisi aynen.
		return "Edit the input photo as requested (the request is in Turkish): " + quoted + ". " +
			"Apply only the requested change and keep everything else the same: the same scene, perspective, camera angle, framing and lighting, with all other objects unchanged. " +
			"Keep it a realistic, natural-looking photograph. No watermark."
	case domain.AIImageKindEnhance:
		p := "Same photo, same content and same framing: improve exposure, brightness, white balance, contrast and sharpness, and reduce noise and blur. " +
			"Do not add, remove, move or change any objects, people, structures or text. Keep it a realistic, natural-looking photograph."
		if strings.TrimSpace(userText) != "" {
			p += " Additional note (in Turkish): " + quoted + "."
		}
		return p
	default:
		if hasImage {
			return "Create a photorealistic image for a construction or renovation project, using the reference photo for the space, layout and context. " +
				"Request (in Turkish): " + quoted + ". No watermark."
		}
		return "Create a photorealistic image for a construction or renovation project. Request (in Turkish): " + quoted + ". No watermark."
	}
}

// aiResultStage: bitmiş hal "İş Sonrası"nı gösterir; iyileştirme ve
// düzenleme kaynağın aşamasında kalır; yeni görsel referansın aşamasında
// (yoksa "İlerleme").
func aiResultStage(kind, sourceStage string) string {
	if kind == domain.AIImageKindBeforeAfter {
		return domain.PhotoStageAfter
	}
	if domain.ValidPhotoStage(sourceStage) {
		return sourceStage
	}
	return domain.PhotoStageProgress
}

// aiPhotoDescription: açıklama paylaşımda (WhatsApp metni) da gider -- müşteri
// görselin çizim olduğunu oradan da anlasın.
func aiPhotoDescription(kind, prompt string) string {
	prompt = strings.TrimSpace(prompt)
	switch kind {
	case domain.AIImageKindBeforeAfter:
		return "Bitmiş hali (yapay zekâ görseli): " + prompt
	case domain.AIImageKindEnhance:
		if prompt == "" {
			return "İyileştirilmiş fotoğraf (yapay zekâ)"
		}
		return "İyileştirilmiş fotoğraf (yapay zekâ): " + prompt
	case domain.AIImageKindEdit:
		return "Düzenlenmiş fotoğraf (yapay zekâ): " + prompt
	default:
		return "Yapay zekâ görseli: " + prompt
	}
}

func aiKindSlug(kind string) string {
	switch kind {
	case domain.AIImageKindBeforeAfter:
		return "bitmis-hali"
	case domain.AIImageKindEnhance:
		return "iyilestirme"
	case domain.AIImageKindEdit:
		return "duzenleme"
	default:
		return "gorsel"
	}
}

// aiSafetyIdentifier: OpenAI kötüye kullanımda kişiyi ayırt edebilsin diye
// kalıcı ama kişisel veri taşımayan özet (ad/e-posta gönderilmez).
func aiSafetyIdentifier(job domain.AIImageJob) string {
	user := ""
	if job.UserID != nil {
		user = *job.UserID
	}
	sum := sha256.Sum256([]byte("arvend:" + job.OrganizationID + ":" + user))
	return hex.EncodeToString(sum[:])
}

// prepareAIInputImage: OpenAI JPEG/PNG/WebP kabul eder (50 MB altı). Proje
// fotoğrafları zaten 25 MB sınırlı; GIF ilk karesiyle PNG'ye çevrilir, diğer
// biçimler (BMP vb.) reddedilir.
func prepareAIInputImage(data []byte) (openai.InputImage, error) {
	if len(data) == 0 {
		return openai.InputImage{}, &aiJobError{"Kaynak fotoğraf okunamadı."}
	}
	if len(data) > openai.MaxInputImageBytes {
		return openai.InputImage{}, &aiJobError{"Kaynak fotoğraf yapay zekâ için çok büyük (en çok 50 MB)."}
	}
	switch mime := http.DetectContentType(data); mime {
	case "image/jpeg":
		// EXIF yönlü telefon fotoğrafı dik hale getirilir: uygulamada nasıl
		// görünüyorsa OpenAI'ye de öyle gitsin (bkz. ai_orientation.go).
		return openai.InputImage{Data: normalizeJPEGOrientation(data), MIMEType: mime, Name: "kaynak.jpg"}, nil
	case "image/png":
		return openai.InputImage{Data: data, MIMEType: mime, Name: "kaynak.png"}, nil
	case "image/webp":
		return openai.InputImage{Data: data, MIMEType: mime, Name: "kaynak.webp"}, nil
	case "image/gif":
		img, err := gif.Decode(bytes.NewReader(data))
		if err != nil {
			return openai.InputImage{}, &aiJobError{"Kaynak fotoğraf okunamadı."}
		}
		var buf bytes.Buffer
		if err := png.Encode(&buf, image.Image(img)); err != nil {
			return openai.InputImage{}, err
		}
		return openai.InputImage{Data: buf.Bytes(), MIMEType: "image/png", Name: "kaynak.png"}, nil
	}
	return openai.InputImage{}, &aiJobError{"Bu fotoğrafın biçimi yapay zekâ için uygun değil; JPEG ya da PNG bir fotoğrafla deneyin."}
}

// aiFailureMessage: kullanıcının göreceği Türkçe neden. OpenAI'nin
// İngilizce teknik mesajı kullanıcıya gösterilmez (loga yazılır).
func aiFailureMessage(err error) string {
	var jobErr *aiJobError
	if errors.As(err, &jobErr) {
		return jobErr.msg
	}
	var closed projectClosedError
	if errors.As(err, &closed) {
		return closed.Error()
	}
	if errors.Is(err, ErrAIDisabled) {
		return ErrAIDisabled.Error()
	}
	var apiErr *openai.APIError
	if errors.As(err, &apiErr) {
		switch {
		case apiErr.IsModerationBlocked():
			return "İstek OpenAI'nin güvenlik kurallarına takıldı. Açıklamayı ya da fotoğrafı değiştirip tekrar deneyin."
		case apiErr.StatusCode == http.StatusUnauthorized:
			return "Yapay zekâ anahtarı geçersiz ya da iptal edilmiş; sunucu yöneticisine haber verin."
		case apiErr.StatusCode == http.StatusForbidden:
			return "OpenAI hesabı bu görsel modelini kullanamıyor (kuruluş doğrulaması gerekebilir); sunucu yöneticisine haber verin."
		case apiErr.IsQuota():
			return "OpenAI hesabının kredisi ya da harcama sınırı doldu; sunucu yöneticisine haber verin."
		case apiErr.StatusCode == http.StatusTooManyRequests:
			return "OpenAI şu an çok yoğun; birkaç dakika sonra tekrar deneyin."
		case apiErr.StatusCode >= 500:
			return "OpenAI şu an yanıt vermiyor; birkaç dakika sonra tekrar deneyin."
		default:
			return "OpenAI isteği kabul etmedi. Açıklamayı değiştirip ya da başka bir fotoğrafla tekrar deneyin."
		}
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return "Görsel zamanında hazırlanamadı; tekrar deneyin."
	}
	return "Görsel hazırlanamadı; tekrar deneyin."
}
