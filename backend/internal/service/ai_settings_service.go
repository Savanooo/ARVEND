package service

// Yapay Zekâ Ayarları (migration 0081). Sahip: "bu AI'yi kim kullanacak vb.
// kural da eklensin, yönetici yapabilsin." Yönetici:
//   - firmada yapay zekâyı kapatır/açar (kapalıyken proje ve stüdyo işleri
//     403; eski uygulamalar /ai/status'ta enabled=false görüp girişleri gizler),
//   - firmanın aylık sınırını sunucu tavanının (AI_IMAGE_MONTHLY_LIMIT)
//     altına çeker, kişi başı aylık sınır koyar,
//   - kişi kişi "kullanabilir/kullanamaz" der: bu, ai.images.use'un MEVCUT
//     kişiye özel yetki ayarıdır (user_permission_overrides,
//     AuthorizationService.SetUserPermissionOverride) -- Roller & Yetkiler
//     ekranı aynı ayarı görür.
// Saatlik kişi sınırı ve "aynı anda en çok 2 iş" aynen kalır (checkLimits).

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

// AIDisabledByAdminCode: yönetici kapattığında 403'ün makine-okunur kodu
// (sunucuda anahtar yokken dönen 503 "ai_disabled"dan ayrı: uygulama
// girişi gizlemez, nedeni gösterir).
const AIDisabledByAdminCode = "ai_disabled_by_admin"

var (
	ErrAIDisabledByAdmin = errors.New("Yapay zekâ bu firmada yönetici tarafından kapatıldı")
	// ErrAIOwnerAlwaysAllowed: Sahip'in izni kişiye özel ayardan etkilenmez
	// (GetUserPermissions); kapatılmış gibi görünüp çalışmaya devam etmesin.
	ErrAIOwnerAlwaysAllowed = errors.New("Sahip her zaman yapay zekâyı kullanabilir; kapatılamaz")
)

// AISettingsValidationError: ayar gövdesindeki Türkçe hata -- handler 400.
type AISettingsValidationError struct{ msg string }

func (e *AISettingsValidationError) Error() string { return e.msg }

// aiFirmLimits: firmanın bu anki etkin kuralları.
type aiFirmLimits struct {
	Enabled bool
	// MonthlyLimit: etkin firma sınırı -- kayıtlı değer sunucu tavanına kırpılır.
	MonthlyLimit        int
	PerUserMonthlyLimit *int
	// stored*: kayıtlı ham değerler (ayar ekranı için).
	storedMonthly *int
}

func int32PtrToInt(v *int32) *int {
	if v == nil {
		return nil
	}
	n := int(*v)
	return &n
}

func intPtrToInt32(v *int) *int32 {
	if v == nil {
		return nil
	}
	n := int32(*v)
	return &n
}

// firmLimits: satır yoksa 0081 öncesi davranış (açık, sunucu sınırı, kişi
// sınırı yok). Tavan sonradan düşürüldüyse kayıtlı büyük değer kırpılır:
// sunucu sahibinin tavanı her zaman kazanır.
func (s *AIImageService) firmLimits(ctx context.Context, q *sqlc.Queries, orgID pgtype.UUID) (aiFirmLimits, error) {
	lim := aiFirmLimits{Enabled: true, MonthlyLimit: s.cfg.MonthlyLimit}
	row, err := q.GetOrganizationAISettings(ctx, orgID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return lim, nil
		}
		return lim, err
	}
	lim.Enabled = row.Enabled
	lim.storedMonthly = int32PtrToInt(row.MonthlyLimit)
	if lim.storedMonthly != nil && *lim.storedMonthly < lim.MonthlyLimit {
		lim.MonthlyLimit = *lim.storedMonthly
	}
	lim.PerUserMonthlyLimit = int32PtrToInt(row.PerUserMonthlyLimit)
	return lim, nil
}

// GetSettings: ayar ekranı -- kurallar, bu ayki kullanım ve kişi listesi.
func (s *AIImageService) GetSettings(ctx context.Context, organizationID string) (*domain.AISettings, error) {
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	lim, err := s.firmLimits(ctx, s.q, orgID)
	if err != nil {
		return nil, err
	}
	start, reset := s.monthWindow()
	since := pgtype.Timestamptz{Time: start, Valid: true}
	used, err := s.q.CountOrgAIImageJobsSince(ctx, sqlc.CountOrgAIImageJobsSinceParams{OrganizationID: orgID, Since: since})
	if err != nil {
		return nil, err
	}
	rows, err := s.q.ListAISettingsUsers(ctx, sqlc.ListAISettingsUsersParams{OrganizationID: orgID, Since: since})
	if err != nil {
		return nil, err
	}
	out := &domain.AISettings{
		Enabled: lim.Enabled, MonthlyLimit: lim.storedMonthly, EffectiveMonthlyLimit: lim.MonthlyLimit,
		ServerMax: s.cfg.MonthlyLimit, PerUserMonthlyLimit: lim.PerUserMonthlyLimit,
		UsedThisMonth: int(used), ResetsAt: reset, Users: make([]domain.AISettingsUser, len(rows)),
	}
	for i, r := range rows {
		out.Users[i] = aiSettingsUser(r)
	}
	return out, nil
}

// aiSettingsUser: etkin izin GetUserPermissions ile AYNI kural: Sahip her
// zaman; değilse kişiye özel ayar roldekini ezer.
func aiSettingsUser(r sqlc.ListAISettingsUsersRow) domain.AISettingsUser {
	u := domain.AISettingsUser{
		UserID: r.ID.String(), FullName: r.FullName, RoleCode: r.RoleCode, RoleName: r.RoleName,
		IsOwner: r.RoleCode == domain.OrgRoleOwner, UsedThisMonth: int(r.UsedThisMonth),
		CanUse: r.RoleAllows, Source: domain.AIAccessSourceRole,
	}
	switch {
	case u.IsOwner:
		u.CanUse = true
	case r.OverrideEffect == "grant":
		u.CanUse, u.Source = true, domain.AIAccessSourceOverrideAllow
	case r.OverrideEffect == "revoke":
		u.CanUse, u.Source = false, domain.AIAccessSourceOverrideDeny
	}
	return u
}

type UpdateAISettingsInput struct {
	Enabled             bool
	MonthlyLimit        *int // nil = sunucu varsayılanı
	PerUserMonthlyLimit *int // nil = kişi sınırı yok
}

// UpdateSettings: sınırlar 0..sunucu tavanı; tavanın üstü reddedilir
// (sessizce kırpmak yöneticiye "200 yazdım" sandırırdı).
func (s *AIImageService) UpdateSettings(ctx context.Context, organizationID, actorUserID string, in UpdateAISettingsInput) (*domain.AISettings, error) {
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	max := s.cfg.MonthlyLimit
	if v := in.MonthlyLimit; v != nil {
		if *v < 0 {
			return nil, &AISettingsValidationError{"Aylık firma sınırı 0 ya da daha büyük olmalı"}
		}
		if *v > max {
			return nil, &AISettingsValidationError{fmt.Sprintf("Aylık firma sınırı en fazla %d olabilir (sunucu üst sınırı)", max)}
		}
	}
	if v := in.PerUserMonthlyLimit; v != nil {
		if *v < 0 {
			return nil, &AISettingsValidationError{"Kişi başı aylık sınır 0 ya da daha büyük olmalı"}
		}
		if *v > max {
			return nil, &AISettingsValidationError{fmt.Sprintf("Kişi başı aylık sınır en fazla %d olabilir (sunucu üst sınırı)", max)}
		}
	}
	actor, _ := repository.StringToUUID(actorUserID)
	if _, err := s.q.UpsertOrganizationAISettings(ctx, sqlc.UpsertOrganizationAISettingsParams{
		OrganizationID: orgID, Enabled: in.Enabled,
		MonthlyLimit: intPtrToInt32(in.MonthlyLimit), PerUserMonthlyLimit: intPtrToInt32(in.PerUserMonthlyLimit),
		UpdatedBy: actor,
	}); err != nil {
		return nil, err
	}
	return s.GetSettings(ctx, organizationID)
}
