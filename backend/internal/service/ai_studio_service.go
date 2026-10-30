package service

// Yapay Zekâ Stüdyo (migration 0080): projeden bağımsız görsel oluşturma ve
// fotoğraf düzenleme. 0079'da görsel işi bir proje fotoğrafından açılıyor,
// sonuç doğrudan projeye ekleniyordu; Sahip "ayrı bir menü" istedi. Stüdyo
// işi projesizdir (project_id NULL): kaynak telefondan yüklenir ya da bir
// proje fotoğrafından KOPYALANIR, sonuç kişinin stüdyo görseli olur, kişi
// isterse "Projeye ekle" ile bir projenin fotoğraflarına kopyalar.
//
// Proje işleriyle ORTAK olanlar (bilerek): aynı izin (ai.images.use), aynı
// aylık firma hakkı ve kişi başı sınırlar (checkLimits, aynı danışma kilidi),
// aynı işçi ve açılış kurtarması (bkz. ai_image_service.go). Eski proje ucu
// 1.5.22 uygulamaları için olduğu gibi çalışır.
//
// Görünürlük: herkes kendi görsellerini görür. Sahip/Yönetici ayrıca
// firmanın bütün stüdyo görsellerini görebilir, açabilir, silebilir:
// görsellerin hepsi firmanın OpenAI hesabından ücretlenir ve firma hakkını
// tüketir; Sahip/Yönetici zaten kişi kişi kullanım sayısını görüyor (durum
// ucu), sayının arkasındaki içeriği de denetleyebilmeli (iş dışı kullanım).
// Diğer roller birbirininkini görmez: stüdyoya telefondan kişisel fotoğraf
// yüklenebilir. Bu ayrım handler'da (rol) yapılır; servis bayrak alır.

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"image"
	_ "image/jpeg" // DecodeConfig: yüklenen JPEG'in başlığı okunabiliyor mu
	"io"
	"net/http"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/platform/openai"
	"github.com/Savanooo/ARVEND/backend/internal/platform/storage"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

const (
	// aiStudioStorageKind: stüdyo nesnelerinin depo öneki ("ai-studio/<firma>/
	// sources|results/<uuid>.<uzantı>"); proje dosyalarından ayrı.
	aiStudioStorageKind = "ai-studio"
	// "Projeye ekle" görsel + proje başına tek sırada: art arda iki dokunuş
	// iki kopya açmasın (bkz. AddStudioImageToProject).
	aiStudioProjectLockClass int32 = 450080

	aiStudioDefaultPageSize = 30
	aiStudioMaxPageSize     = 100
)

var (
	ErrAIStudioImageNotFound  = errors.New("görsel bulunamadı")
	ErrAIStudioTwoSources     = errors.New("Tek bir kaynak seçin: telefondan bir fotoğraf, bir proje fotoğrafı ya da bir stüdyo görseli.")
	ErrAIStudioGenerateSource = errors.New("Yeni görsel yalnızca açıklamadan oluşturulur; fotoğraf üzerinde değişiklik için düzenleme seçeneğini kullanın.")
	ErrAIImageUnsupported     = errors.New("Bu fotoğrafın biçimi desteklenmiyor; JPEG, PNG ya da WebP bir fotoğraf seçin.")
	// HEIC'i çözecek bir kitaplık yok (Go standart kitaplığında yok, cgo'suz
	// bir çözücü de eklenmedi); uygulama fotoğrafı seçerken JPEG'e çevirir,
	// bu metin yalnızca çevrilmeden gelen dosya içindir.
	ErrAIImageHEIC          = errors.New("HEIC biçimindeki fotoğraf desteklenmiyor; fotoğrafı JPEG olarak gönderin (iPhone: Ayarlar › Kamera › Biçimler › En Uyumlu).")
	ErrAIImageUnreadable    = errors.New("Fotoğraf okunamadı (dosya bozuk olabilir); başka bir fotoğrafla deneyin.")
	ErrAIStudioInvalidStage = errors.New("Geçersiz fotoğraf aşaması (before, progress ya da after olmalı)")
	// ErrAISourceAccessDenied: kaynak proje fotoğrafının projesine okuma
	// erişimi yok (handler 403 project_access_denied).
	ErrAISourceAccessDenied = errors.New("bu projeye erişim yetkiniz yok")
)

// CreateAIStudioJobInput: stüdyo işi. Kaynak tam olarak biri: Image
// (telefondan yükleme), SourceProjectPhotoID (proje fotoğrafı) ya da
// SourceStudioImageID (önceki bir stüdyo görseli -- sonucu yeniden düzenlemek
// için); yeni görselde (generate) hiçbiri.
type CreateAIStudioJobInput struct {
	OrganizationID string
	UserID         string
	Kind           string
	Prompt         string
	Image          io.Reader
	// SourceProjectPhotoID: proje kimliği istemciden alınmaz -- fotoğraf
	// firmada hangi projedeyse o; o projeye okuma erişimini CanReadProject
	// söyler (handler: projects.operations.read + proje üyeliği). nil ise
	// proje fotoğrafı kaynak olamaz (kapalı varsayılan).
	SourceProjectPhotoID string
	CanReadProject       func(ctx context.Context, projectID string) error
	// SourceStudioImageID: kişinin görebildiği stüdyo görseli (kendisinin;
	// AnyUser ise firmadaki herhangi biri -- Sahip/Yönetici). Kaynak görsel
	// yerinde kalır, sonuç YENİ görseldir.
	SourceStudioImageID string
	AnyUser             bool
	// Mask: yalnızca 'edit' -- kalemle boyanan alan (bkz. ai_mask.go).
	Mask io.Reader
}

// resolveStudioSourcePhoto: kaynak gösterilen proje fotoğrafını firmada
// bulur. Başka firmanın ya da silinmiş fotoğraf: bulunamadı.
func (s *AIImageService) resolveStudioSourcePhoto(ctx context.Context, organizationID, photoID string) (*domain.ProjectPhoto, error) {
	notFound := &NotFoundError{What: "Kaynak fotoğraf"}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, notFound
	}
	phid, err := repository.StringToUUID(strings.TrimSpace(photoID))
	if err != nil {
		return nil, notFound
	}
	row, err := s.q.GetAIStudioSourcePhoto(ctx, sqlc.GetAIStudioSourcePhotoParams{ID: phid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, notFound
		}
		return nil, err
	}
	photo := repository.ToDomainProjectPhoto(row)
	return &photo, nil
}

// CreateStudioJob: kaynağı doğrular, depoya kopyalar ve işi "sırada" açar.
// Sınırlar proje işleriyle aynı sayımdan ve aynı firma kilidinden geçer.
func (s *AIImageService) CreateStudioJob(ctx context.Context, in CreateAIStudioJobInput) (*domain.AIImageJob, *domain.AIImageQuota, error) {
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
	in.SourceStudioImageID = strings.TrimSpace(in.SourceStudioImageID)
	in.SourceProjectPhotoID = strings.TrimSpace(in.SourceProjectPhotoID)
	sources := 0
	for _, has := range []bool{in.Image != nil, in.SourceProjectPhotoID != "", in.SourceStudioImageID != ""} {
		if has {
			sources++
		}
	}
	switch {
	case sources > 1:
		return nil, nil, ErrAIStudioTwoSources
	case in.Kind == domain.AIImageKindGenerate && sources > 0:
		return nil, nil, ErrAIStudioGenerateSource
	case in.Kind != domain.AIImageKindGenerate && sources == 0:
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
	orgID, err := repository.StringToUUID(in.OrganizationID)
	if err != nil {
		return nil, nil, domain.ErrNotFound
	}
	uid, err := repository.StringToUUID(in.UserID)
	if err != nil {
		return nil, nil, domain.ErrNotFound
	}

	// Erken ret (kilitsiz): hakkı dolmuş birinin 25 MB'lık yüklemesi depoya
	// hiç yazılmasın. Kesin karar aşağıda kilit altında.
	if _, err := s.checkLimits(ctx, s.q, orgID, uid); err != nil {
		return nil, nil, err
	}

	var (
		sourceKey, sourceMIME, maskKey string
		sourcePhoto                    pgtype.UUID
	)
	created := false
	defer func() {
		if created {
			return
		}
		for _, key := range []string{sourceKey, maskKey} {
			if key != "" {
				_ = s.projects.store.Delete(context.WithoutCancel(ctx), key)
			}
		}
	}()
	if sources > 0 {
		// Kaynak her zaman işin KENDİ nesnesine kopyalanır: proje fotoğrafı ya
		// da kaynak stüdyo görseli sonradan silinse de iş çalışır.
		img, origin, err := s.readStudioJobSource(ctx, in, orgID)
		if err != nil {
			return nil, nil, err
		}
		if maskData != nil {
			// Maske, işçinin OpenAI'ye göndereceği kaynakla aynı boyutta olmalı.
			if err := validateAIMask(maskData, img.Data); err != nil {
				return nil, nil, err
			}
		}
		sourceKey = storage.BuildKey(aiStudioStorageKind, orgID.String(), "sources", uuid.NewString(), aiImageExt(img.MIMEType))
		if _, err := s.projects.store.Put(ctx, sourceKey, bytes.NewReader(img.Data)); err != nil {
			return nil, nil, wrapStorageErr(err)
		}
		sourceMIME = img.MIMEType
		sourcePhoto = origin
		if maskData != nil {
			if maskKey, err = s.putAIMask(ctx, orgID, maskData); err != nil {
				return nil, nil, err
			}
		}
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)
	if err := txq.AIImageQuotaXactLock(ctx, sqlc.AIImageQuotaXactLockParams{
		LockClass: aiQuotaLockClass, LockKey: orgID.String(),
	}); err != nil {
		return nil, nil, err
	}
	usage, err := s.checkLimits(ctx, txq, orgID, uid)
	if err != nil {
		return nil, nil, err
	}
	row, err := txq.CreateAIStudioJob(ctx, sqlc.CreateAIStudioJobParams{
		OrganizationID: orgID, UserID: uid, Kind: in.Kind, Prompt: prompt, SourcePhotoID: sourcePhoto,
		SourceStorageKey: sourceKey, SourceMime: sourceMIME, Model: s.cfg.Model, MaskStorageKey: maskKey,
	})
	if err != nil {
		return nil, nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, nil, err
	}
	created = true
	s.signal()
	job := repository.ToDomainAIImageJob(row)
	after := s.after(usage)
	return &job, &after, nil
}

// readStudioJobSource: yüklenen dosyayı, kaynak proje fotoğrafını ya da
// kaynak stüdyo görselini okur ve doğrular (bkz. studioSourceImage). origin:
// işin köken proje fotoğrafı -- proje fotoğrafından açıldıysa o, stüdyo
// görselinden açıldıysa onun kökeni (yeniden düzenlenen görsel aynı projeye
// eklenince de galeri "kaynak: <tarih>" yazsın).
func (s *AIImageService) readStudioJobSource(ctx context.Context, in CreateAIStudioJobInput, orgID pgtype.UUID) (openai.InputImage, pgtype.UUID, error) {
	var none pgtype.UUID
	readAll := func(rc io.ReadCloser) ([]byte, error) {
		defer rc.Close()
		data, err := io.ReadAll(io.LimitReader(rc, MaxUploadBytes+1))
		if err != nil {
			return nil, wrapStorageErr(err)
		}
		return data, nil
	}
	switch {
	case in.SourceProjectPhotoID != "":
		photo, err := s.resolveStudioSourcePhoto(ctx, in.OrganizationID, in.SourceProjectPhotoID)
		if err != nil {
			return openai.InputImage{}, none, err
		}
		if in.CanReadProject == nil {
			return openai.InputImage{}, none, ErrAISourceAccessDenied
		}
		if err := in.CanReadProject(ctx, photo.ProjectID); err != nil {
			return openai.InputImage{}, none, err
		}
		_, rc, err := s.projects.OpenPhoto(ctx, photo.ProjectID, photo.ID, in.OrganizationID)
		if err != nil {
			if errors.Is(err, domain.ErrNotFound) {
				return openai.InputImage{}, none, &NotFoundError{What: "Kaynak fotoğraf"}
			}
			return openai.InputImage{}, none, err
		}
		data, err := readAll(rc)
		if err != nil {
			return openai.InputImage{}, none, err
		}
		img, err := studioSourceImage(data, true)
		origin, _ := repository.StringToUUID(photo.ID)
		return img, origin, err
	case in.SourceStudioImageID != "":
		src, err := s.studioImageFor(ctx, s.q, in.SourceStudioImageID, in.OrganizationID, in.UserID, in.AnyUser)
		if err != nil {
			if errors.Is(err, ErrAIStudioImageNotFound) {
				return openai.InputImage{}, none, &NotFoundError{What: "Kaynak görsel"}
			}
			return openai.InputImage{}, none, err
		}
		rc, err := s.projects.store.Open(ctx, src.StorageKey)
		if err != nil {
			if errors.Is(err, storage.ErrNotFound) {
				return openai.InputImage{}, none, &NotFoundError{What: "Kaynak görsel"}
			}
			return openai.InputImage{}, none, wrapStorageErr(err)
		}
		data, err := readAll(rc)
		if err != nil {
			return openai.InputImage{}, none, err
		}
		img, err := studioSourceImage(data, true)
		var origin pgtype.UUID
		if o, oerr := s.q.GetAIStudioImageOrigin(ctx, sqlc.GetAIStudioImageOriginParams{ID: src.ID, OrganizationID: orgID}); oerr == nil {
			origin = o.SourcePhotoID
		} else if !errors.Is(oerr, pgx.ErrNoRows) {
			return openai.InputImage{}, none, oerr
		}
		return img, origin, err
	}
	data, err := io.ReadAll(io.LimitReader(in.Image, MaxUploadBytes+1))
	if err != nil {
		return openai.InputImage{}, none, ErrAIImageUnreadable
	}
	img, err := studioSourceImage(data, false)
	return img, none, err
}

// studioSourceImage: kaynağın türü ve sağlamlığı, depoya yazılmadan ÖNCE.
// İstemcinin bildirdiği türe güvenilmez, baytlardan bakılır. Telefondan
// yükleme yalnızca JPEG/PNG/WebP (OpenAI'nin kabul ettikleri); sunucudaki
// kaynakta (proje fotoğrafı, stüdyo görseli) GIF de olur -- projeye her
// görsel türü yüklenebiliyor; ilk karesi PNG'ye çevrilir (prepareAIInputImage).
func studioSourceImage(data []byte, fromServer bool) (openai.InputImage, error) {
	if len(data) == 0 {
		return openai.InputImage{}, ErrEmptyFile
	}
	if len(data) > MaxUploadBytes {
		return openai.InputImage{}, ErrFileTooLarge
	}
	if isHEIF(data) {
		return openai.InputImage{}, ErrAIImageHEIC
	}
	switch http.DetectContentType(data) {
	case "image/jpeg", "image/png":
		if _, _, err := image.DecodeConfig(bytes.NewReader(data)); err != nil {
			return openai.InputImage{}, ErrAIImageUnreadable
		}
	case "image/webp":
		// Standart kitaplıkta WebP çözücü yok; RIFF/WEBP imzası yeterli,
		// bozuksa OpenAI reddeder ve iş Türkçe nedenle başarısız olur.
	case "image/gif":
		if !fromServer {
			return openai.InputImage{}, ErrAIImageUnsupported
		}
	default:
		return openai.InputImage{}, ErrAIImageUnsupported
	}
	img, err := prepareAIInputImage(data)
	if err != nil {
		var jobErr *aiJobError
		if errors.As(err, &jobErr) {
			return openai.InputImage{}, ErrAIImageUnreadable
		}
		return openai.InputImage{}, err
	}
	return img, nil
}

// isHEIF: ISO BMFF "ftyp" kutusu ve HEIC/HEIF markası (iPhone fotoğrafı).
// http.DetectContentType bunu tanımaz ("application/octet-stream" der);
// kullanıcıya genel "biçim desteklenmiyor" yerine ne yapacağı söylensin.
func isHEIF(data []byte) bool {
	if len(data) < 12 || string(data[4:8]) != "ftyp" {
		return false
	}
	switch string(data[8:12]) {
	case "heic", "heix", "hevc", "hevx", "heim", "heis", "hevm", "hevs", "mif1", "msf1":
		return true
	}
	return false
}

func aiImageExt(mime string) string {
	switch mime {
	case "image/png":
		return ".png"
	case "image/webp":
		return ".webp"
	default:
		return ".jpg"
	}
}

// GetStudioJob: yalnızca işi açan kişi, aynı firmada; proje işi bu yoldan
// görünmez (ve stüdyo işi proje yolundan görünmez).
func (s *AIImageService) GetStudioJob(ctx context.Context, jobID, organizationID, userID string) (*domain.AIImageJob, error) {
	jid, err := repository.StringToUUID(jobID)
	if err != nil {
		return nil, ErrAIJobNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, ErrAIJobNotFound
	}
	uid, err := repository.StringToUUID(userID)
	if err != nil {
		return nil, ErrAIJobNotFound
	}
	row, err := s.q.GetAIStudioJob(ctx, sqlc.GetAIStudioJobParams{ID: jid, OrganizationID: orgID, UserID: uid})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrAIJobNotFound
		}
		return nil, err
	}
	job := repository.ToDomainAIImageJob(row.AiImageJob)
	if row.StudioImageID.Valid {
		id := row.StudioImageID.String()
		job.StudioImageID = &id
	}
	return &job, nil
}

// AIStudioListInput: "Görsellerim" sayfası.
type AIStudioListInput struct {
	OrganizationID string
	UserID         string
	// AllUsers: firmanın bütün görselleri (Sahip/Yönetici; handler denetler).
	AllUsers bool
	// AllProjects: proje üyeliğinden muaf rol -- görselin eklendiği bütün
	// projeleri görür; diğerleri yalnızca üyesi olduklarını.
	AllProjects bool
	Limit       int
	// Before: önceki sayfanın NextBefore'u (nil = ilk sayfa).
	Before *time.Time
}

type AIStudioPage struct {
	Images []domain.AIStudioImage
	// Pending: kişinin KENDİ sırada/çalışan stüdyo işleri (firma görünümünde
	// de -- iş yalnızca açanına görünür).
	Pending []domain.AIImageJob
	// NextBefore: başka sayfa varsa bir sonraki isteğin before'u.
	NextBefore *time.Time
}

// ListStudioImages: en yenisi önce, created_at imleçli sayfalar.
func (s *AIImageService) ListStudioImages(ctx context.Context, in AIStudioListInput) (*AIStudioPage, error) {
	orgID, err := repository.StringToUUID(in.OrganizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	uid, err := repository.StringToUUID(in.UserID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	limit := in.Limit
	if limit <= 0 {
		limit = aiStudioDefaultPageSize
	}
	if limit > aiStudioMaxPageSize {
		limit = aiStudioMaxPageSize
	}
	var before pgtype.Timestamptz
	if in.Before != nil {
		before = pgtype.Timestamptz{Time: *in.Before, Valid: true}
	}
	rows, err := s.q.ListAIStudioImages(ctx, sqlc.ListAIStudioImagesParams{
		OrganizationID: orgID, AllUsers: in.AllUsers, UserID: uid, Before: before, PageLimit: int32(limit + 1),
	})
	if err != nil {
		return nil, err
	}
	page := &AIStudioPage{}
	if len(rows) > limit {
		last := rows[limit-1].AiStudioImage.CreatedAt
		if rows[limit].AiStudioImage.CreatedAt.Time.Equal(last.Time) {
			// İmleç yalnızca zaman taşır: sınırdaki aynı anlı görsellerin
			// hepsi bu sayfada dönmeli (sonraki sayfa "< zaman" ile başlar).
			tied, err := s.q.ListAIStudioImagesAt(ctx, sqlc.ListAIStudioImagesAtParams{
				OrganizationID: orgID, AllUsers: in.AllUsers, UserID: uid, At: last,
			})
			if err != nil {
				return nil, err
			}
			k := limit - 1
			for k > 0 && rows[k-1].AiStudioImage.CreatedAt.Time.Equal(last.Time) {
				k--
			}
			rows = rows[:k]
			for _, t := range tied {
				rows = append(rows, sqlc.ListAIStudioImagesRow{AiStudioImage: t.AiStudioImage, UserName: t.UserName})
			}
		} else {
			rows = rows[:limit]
		}
		next := last.Time
		page.NextBefore = &next
	}

	page.Images = make([]domain.AIStudioImage, len(rows))
	ids := make([]pgtype.UUID, len(rows))
	index := make(map[string]int, len(rows))
	for i, r := range rows {
		page.Images[i] = repository.ToDomainAIStudioImage(r.AiStudioImage, r.UserName)
		page.Images[i].Projects = []domain.AIStudioImageProject{}
		ids[i] = r.AiStudioImage.ID
		index[page.Images[i].ID] = i
	}
	if len(ids) > 0 {
		links, err := s.q.ListAIStudioImageProjects(ctx, sqlc.ListAIStudioImageProjectsParams{
			ImageIds: ids, OrganizationID: orgID, AllProjects: in.AllProjects, UserID: uid,
		})
		if err != nil {
			return nil, err
		}
		for _, l := range links {
			i, ok := index[l.StudioImageID.String()]
			if !ok {
				continue
			}
			page.Images[i].Projects = append(page.Images[i].Projects, domain.AIStudioImageProject{
				ProjectID: l.ProjectID.String(), ProjectName: l.ProjectName, ProjectPhotoID: l.ProjectPhotoID.String(),
			})
		}
	}

	pending, err := s.q.ListUserPendingAIStudioJobs(ctx, sqlc.ListUserPendingAIStudioJobsParams{OrganizationID: orgID, UserID: uid})
	if err != nil {
		return nil, err
	}
	page.Pending = make([]domain.AIImageJob, len(pending))
	for i, j := range pending {
		page.Pending[i] = repository.ToDomainAIImageJob(j)
	}
	return page, nil
}

// studioImageFor: görseli firmada bulur ve kişinin görüp göremeyeceğine
// bakar (kendi görseli ya da anyUser -- Sahip/Yönetici). Göremediği görsel
// "bulunamadı" döner: varlığı da sızmasın.
func (s *AIImageService) studioImageFor(ctx context.Context, q *sqlc.Queries, imageID, organizationID, userID string, anyUser bool) (sqlc.AiStudioImage, error) {
	id, err := repository.StringToUUID(imageID)
	if err != nil {
		return sqlc.AiStudioImage{}, ErrAIStudioImageNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return sqlc.AiStudioImage{}, ErrAIStudioImageNotFound
	}
	row, err := q.GetAIStudioImage(ctx, sqlc.GetAIStudioImageParams{ID: id, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return sqlc.AiStudioImage{}, ErrAIStudioImageNotFound
		}
		return sqlc.AiStudioImage{}, err
	}
	if !anyUser && (!row.UserID.Valid || row.UserID.String() != userID) {
		return sqlc.AiStudioImage{}, ErrAIStudioImageNotFound
	}
	return row, nil
}

// OpenStudioImage: görselin baytları (sahibi ya da anyUser).
func (s *AIImageService) OpenStudioImage(ctx context.Context, imageID, organizationID, userID string, anyUser bool) (*domain.AIStudioImage, io.ReadCloser, error) {
	row, err := s.studioImageFor(ctx, s.q, imageID, organizationID, userID, anyUser)
	if err != nil {
		return nil, nil, err
	}
	rc, err := s.projects.store.Open(ctx, row.StorageKey)
	if err != nil {
		if errors.Is(err, storage.ErrNotFound) {
			return nil, nil, ErrAIStudioImageNotFound
		}
		return nil, nil, wrapStorageErr(err)
	}
	img := repository.ToDomainAIStudioImage(row, "")
	return &img, rc, nil
}

// DeleteStudioImage: yumuşak silme (dosya depoda kalır). Projeye eklenmiş
// kopyalar projede durur: onlar artık projenin fotoğrafıdır.
func (s *AIImageService) DeleteStudioImage(ctx context.Context, imageID, organizationID, userID string, anyUser bool) error {
	id, err := repository.StringToUUID(imageID)
	if err != nil {
		return ErrAIStudioImageNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return ErrAIStudioImageNotFound
	}
	actor := actorUUID(userID)
	n, err := s.q.SoftDeleteAIStudioImage(ctx, sqlc.SoftDeleteAIStudioImageParams{
		ID: id, OrganizationID: orgID, DeletedBy: actor, AnyUser: anyUser, UserID: actor,
	})
	if err != nil {
		return err
	}
	if n == 0 {
		return ErrAIStudioImageNotFound
	}
	return nil
}

type AddAIStudioImageToProjectInput struct {
	OrganizationID string
	UserID         string
	ImageID        string
	ProjectID      string
	// Stage: boşsa türe göre (bitmiş hali "İş Sonrası", diğerleri "İlerleme").
	Stage string
	// AnyUser: Sahip/Yönetici başkasının görselini de ekleyebilir.
	AnyUser bool
}

// AddStudioImageToProject: stüdyo görselini projeye YENİ fotoğraf olarak
// kopyalar (yapay zekâ işaretli, 0079'daki proje görselleriyle aynı). Proje
// erişimi ve projects.operations.manage handler'da denetlenir; proje açık
// olmalı (fotoğraf yükleme kuralı). Görsel + proje başına tek kopya:
// tekrar çağrı aynı fotoğrafı döner (created=false); kopya projeden
// silinmişse yenisi açılır.
func (s *AIImageService) AddStudioImageToProject(ctx context.Context, in AddAIStudioImageToProjectInput) (string, bool, error) {
	stage := strings.TrimSpace(in.Stage)
	if stage != "" && !domain.ValidPhotoStage(stage) {
		return "", false, ErrAIStudioInvalidStage
	}
	pid, orgID, err := s.projects.scopedIDs(in.ProjectID, in.OrganizationID)
	if err != nil {
		return "", false, err
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return "", false, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	img, err := s.studioImageFor(ctx, txq, in.ImageID, in.OrganizationID, in.UserID, in.AnyUser)
	if err != nil {
		return "", false, err
	}
	if err := txq.AIImageQuotaXactLock(ctx, sqlc.AIImageQuotaXactLockParams{
		LockClass: aiStudioProjectLockClass, LockKey: img.ID.String() + ":" + pid.String(),
	}); err != nil {
		return "", false, err
	}
	if _, err := s.projects.requireOpenProjectForOps(ctx, txq, pid, orgID); err != nil {
		return "", false, err
	}
	existing, err := txq.GetAIStudioImageProjectPhoto(ctx, sqlc.GetAIStudioImageProjectPhotoParams{StudioImageID: img.ID, ProjectID: pid})
	if err == nil {
		if err := tx.Commit(ctx); err != nil {
			return "", false, err
		}
		return existing.String(), false, nil
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return "", false, err
	}

	if stage == "" {
		stage = aiResultStage(img.Kind, "")
	}
	// Kaynak bu projenin fotoğrafıysa bağ kurulur (galeri "kaynak: <tarih>").
	var source pgtype.UUID
	if origin, err := txq.GetAIStudioImageOrigin(ctx, sqlc.GetAIStudioImageOriginParams{ID: img.ID, OrganizationID: orgID}); err == nil {
		if origin.SourcePhotoID.Valid && origin.SourceProjectID == pid {
			source = origin.SourcePhotoID
		}
	} else if !errors.Is(err, pgx.ErrNoRows) {
		return "", false, err
	}

	rc, err := s.projects.store.Open(ctx, img.StorageKey)
	if err != nil {
		if errors.Is(err, storage.ErrNotFound) {
			return "", false, ErrAIStudioImageNotFound
		}
		return "", false, wrapStorageErr(err)
	}
	name := fmt.Sprintf("yapay-zeka-%s-%s%s", aiKindSlug(img.Kind), IstanbulNow(img.CreatedAt.Time).Format("20060102-150405"), aiImageExt(img.Mime))
	obj, key, err := s.projects.storeUpload(ctx, "photos", orgID.String(), pid.String(), name, rc, true)
	rc.Close()
	if err != nil {
		return "", false, err
	}
	kind := img.Kind
	actor := actorUUID(in.UserID)
	photo, err := txq.CreateAIProjectPhoto(ctx, sqlc.CreateAIProjectPhotoParams{
		OrganizationID: orgID, ProjectID: pid, OriginalName: name, ObjectKey: key,
		MimeType: obj.MIMEType, SizeBytes: obj.Size, Sha256: obj.SHA256, Stage: stage,
		Description: truncateRunes(aiPhotoDescription(img.Kind, img.Prompt), maxUploadDescRunes),
		UploadedBy:  actor, AiKind: &kind, AiPrompt: img.Prompt, AiSourcePhotoID: source,
	})
	if err != nil {
		_ = s.projects.store.Delete(ctx, key)
		if isUniqueViolation(err) {
			// Aynı baytlar projede başka bir fotoğraf olarak duruyor (ör.
			// görsel indirilip elle yüklenmiş). Kurtarma sorgusu havuzdan:
			// transaction bu noktada "aborted".
			if dup, gerr := s.q.GetProjectPhotoBySHA(ctx, sqlc.GetProjectPhotoBySHAParams{ProjectID: pid, Sha256: obj.SHA256}); gerr == nil {
				label := dup.Description
				if label == "" {
					label = dup.OriginalName
				}
				return "", false, &duplicateContentError{msg: "Bu görsel bu projede zaten var: " + label}
			}
			return "", false, ErrDuplicateContent
		}
		return "", false, err
	}
	fail := func(err error) (string, bool, error) {
		_ = s.projects.store.Delete(ctx, key)
		return "", false, err
	}
	if err := txq.UpsertAIStudioImageProject(ctx, sqlc.UpsertAIStudioImageProjectParams{
		StudioImageID: img.ID, ProjectID: pid, ProjectPhotoID: photo.ID, AddedBy: actor,
	}); err != nil {
		return fail(err)
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventAIPhotoCreated, actor, map[string]any{
		"photo_id": photo.ID.String(), "stage": stage, "ai_kind": img.Kind, "studio_image_id": img.ID.String(),
	}); err != nil {
		return fail(err)
	}
	if err := tx.Commit(ctx); err != nil {
		return fail(err)
	}
	return photo.ID.String(), true, nil
}

// readStudioSource: işçi, stüdyo işinin depodaki kaynağını okur.
func (s *AIImageService) readStudioSource(ctx context.Context, key string) (openai.InputImage, error) {
	rc, err := s.projects.store.Open(ctx, key)
	if err != nil {
		if errors.Is(err, storage.ErrNotFound) {
			return openai.InputImage{}, &aiJobError{"Kaynak fotoğraf bulunamadı; fotoğrafı yeniden yükleyip tekrar deneyin."}
		}
		return openai.InputImage{}, err
	}
	defer rc.Close()
	data, err := io.ReadAll(io.LimitReader(rc, openai.MaxInputImageBytes+1))
	if err != nil {
		return openai.InputImage{}, err
	}
	return prepareAIInputImage(data)
}

// saveStudioResult: üretilen görseli kişinin stüdyo görseli olarak kaydeder
// ve işi aynı transaction'da bitirir (proje işindeki saveResult'un
// karşılığı; projeye hiçbir şey eklenmez).
func (s *AIImageService) saveStudioResult(ctx context.Context, job domain.AIImageJob, data []byte, mime, ext string) error {
	orgID, err := repository.StringToUUID(job.OrganizationID)
	if err != nil {
		return err
	}
	jid, err := repository.StringToUUID(job.ID)
	if err != nil {
		return err
	}
	var uid pgtype.UUID
	if job.UserID != nil {
		uid, _ = repository.StringToUUID(*job.UserID)
	}
	key := storage.BuildKey(aiStudioStorageKind, orgID.String(), "results", uuid.NewString(), ext)
	obj, err := s.projects.store.Put(ctx, key, bytes.NewReader(data))
	if err != nil {
		return wrapStorageErr(err)
	}
	saved := false
	defer func() {
		if !saved {
			_ = s.projects.store.Delete(context.WithoutCancel(ctx), key)
		}
	}()

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)
	if _, err := txq.CreateAIStudioImage(ctx, sqlc.CreateAIStudioImageParams{
		OrganizationID: orgID, UserID: uid, JobID: jid, StorageKey: key, Mime: mime,
		SizeBytes: obj.Size, Kind: job.Kind, Prompt: job.Prompt,
	}); err != nil {
		return err
	}
	n, err := txq.CompleteAIStudioJob(ctx, jid)
	if err != nil {
		return err
	}
	if n == 0 {
		return errors.New("yapay zekâ işi artık çalışır durumda değil; görsel kaydedilmedi")
	}
	if err := tx.Commit(ctx); err != nil {
		return err
	}
	saved = true
	return nil
}

// buildAIStudioPrompt: stüdyo türlerinin sunucu tarafı talimatı. Bitmiş
// hali, iyileştirme ve düzenleme proje işindekiyle aynı; yeni görsel
// stüdyoda şantiyeye bağlanmaz (broşür, sosyal medya görseli de istenebilir).
func buildAIStudioPrompt(kind, userText string) string {
	if kind == domain.AIImageKindGenerate {
		quoted := `"` + strings.ReplaceAll(strings.TrimSpace(userText), `"`, "'") + `"`
		return "Create a high-quality image for this request (in Turkish): " + quoted + ". " +
			"Photorealistic unless the request asks for another style. No watermark."
	}
	return buildAIImagePrompt(kind, userText, true)
}
