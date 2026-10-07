package service

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/Savanooo/ARVEND/backend/internal/auth"
	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

// PlatformService, YALNIZCA Super Admin route'ları arkasında çağrılmalıdır
// (middleware.RequireRole(domain.RoleSuperAdmin)) -- burada organizasyon
// izolasyonu YOKTUR, bilinçli olarak: platformun tamamını yönetmek bu
// servisin işi. Normal organization-scoped servisler (UserService,
// OfferService, ...) HİÇBİR yeni izin gevşetmesi almadı.
type PlatformService struct {
	pool       *pgxpool.Pool
	q          *sqlc.Queries
	userSvc    *UserService
	calcSvc    *CalcService
	productSvc *ProductService
}

func NewPlatformService(pool *pgxpool.Pool, q *sqlc.Queries, userSvc *UserService, calcSvc *CalcService, productSvc *ProductService) *PlatformService {
	return &PlatformService{pool: pool, q: q, userSvc: userSvc, calcSvc: calcSvc, productSvc: productSvc}
}

type CreateOrganizationInput struct {
	Name          string
	Slug          string
	PlanCode      string           // boşsa "trial"
	Status        domain.OrgStatus // boşsa OrgStatusActive
	TrialDays     int              // yalnızca Status=trial iken anlamlıdır; 0 = trial_ends_at NULL kalır
	OwnerUsername string
	OwnerPassword string
	OwnerFullName string
	ActorUserID   string // audit için: bu işlemi yapan Super Admin
}

type CreateOrganizationResult struct {
	Organization domain.Organization
	Owner        domain.User
	CalcCatalog  *CalcCatalogProvisionResult // provisioning best-effort başarısız olursa nil
}

// CreateOrganizationWithOwner, yeni bir firma VE ilk Owner/Admin kullanıcısını
// TEK bir transaction'da atomik olarak oluşturur (cmd/seed-organization'daki
// hand-rolled pgx transaction deseninin aynısı). Owner, must_change_password
// =true ile başlar -- Super Admin'in belirlediği geçici şifreyle ilk girişte
// zorunlu şifre değişikliğine yönlendirilir (bkz. domain/user.go).
//
// Metraj Hesaplama kataloğunun provizyonu (ProvisionCalcCatalog) BİLİNÇLİ
// OLARAK transaction'IN DIŞINDA, commit'ten SONRA, best-effort çalışır --
// import-calc-recipes zaten idempotent (atla-varsa) olduğu için başarısız
// olursa PlatformService.ReprovisionCalcCatalog ile güvenle yeniden
// denenebilir; firma+owner oluşturmayı yüzlerce reçete kalemi INSERT'ine
// bağımlı kılmak (aynı transaction'da) gereksiz bir başarısızlık yüzeyi
// olurdu.
func (s *PlatformService) CreateOrganizationWithOwner(ctx context.Context, in CreateOrganizationInput) (*CreateOrganizationResult, error) {
	name := strings.TrimSpace(in.Name)
	slug := strings.TrimSpace(in.Slug)
	ownerUsername := strings.TrimSpace(in.OwnerUsername)
	ownerFullName := strings.TrimSpace(in.OwnerFullName)
	if name == "" || slug == "" {
		return nil, errors.New("firma adı ve slug zorunludur")
	}
	if ownerUsername == "" || in.OwnerPassword == "" || ownerFullName == "" {
		return nil, errors.New("ilk sahip (owner) için kullanıcı adı, geçici şifre ve ad soyad zorunludur")
	}
	if isReservedUsername(ownerUsername) {
		return nil, domain.ErrReservedUsername
	}
	if len(in.OwnerPassword) < 8 {
		return nil, errors.New("ilk sahip (owner) geçici şifresi en az 8 karakter olmalı")
	}
	planCode := strings.TrimSpace(in.PlanCode)
	if planCode == "" {
		planCode = "trial"
	}
	status := in.Status
	if status == "" {
		status = domain.OrgStatusActive
	}
	// Oluşturma anında YALNIZCA trial/active kabul edilir -- suspended/
	// cancelled bir YAŞAM DÖNGÜSÜ SONUCUDUR (bkz. SetStatus + audit trail),
	// doğrudan istekten geçirilebilecek bir başlangıç değeri DEĞİLDİR. Web
	// formu zaten yalnızca bu ikisini sunar; burada aynı kısıt backend'de
	// de zorunlu kılınır.
	if status != domain.OrgStatusTrial && status != domain.OrgStatusActive {
		return nil, errors.New("yeni firma yalnızca 'trial' veya 'active' durumuyla oluşturulabilir")
	}

	var trialEndsAt pgtype.Timestamptz
	if status == domain.OrgStatusTrial && in.TrialDays > 0 {
		trialEndsAt = pgTimestamptz(time.Now().AddDate(0, 0, in.TrialDays))
	}

	hash, err := auth.HashPassword(in.OwnerPassword)
	if err != nil {
		return nil, err
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	orgRow, err := txq.CreateOrganizationWithLifecycle(ctx, sqlc.CreateOrganizationWithLifecycleParams{
		Name: name, Slug: slug, Status: string(status), PlanCode: planCode, TrialEndsAt: trialEndsAt,
	})
	if err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) {
			switch pgErr.Code {
			case "23505":
				return nil, errors.New("bu slug zaten kullanılıyor")
			case "23503":
				return nil, errors.New("geçersiz plan kodu")
			}
		}
		return nil, err
	}

	userRow, err := txq.CreateUserWithOptions(ctx, sqlc.CreateUserWithOptionsParams{
		OrganizationID:     orgRow.ID,
		Username:           ownerUsername,
		PasswordHash:       hash,
		FullName:           ownerFullName,
		Role:               string(domain.RoleAdmin),
		MustChangePassword: true,
	})
	if err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" {
			return nil, domain.ErrDuplicateUsername
		}
		return nil, err
	}

	// RBAC/Project Membership sprint'i: YENİ organizasyon için AYNI 6 sistem
	// rolünü (migration 0034'ün mevcut organizasyonlar için yaptığı
	// backfill'in TEK kaynağı, seed_system_roles_for_org DB fonksiyonu ile)
	// seed eder, ardından ilk kullanıcıyı (Owner) 'owner' rolüne bağlar.
	// Bu adım ATLANIRSA yeni firmanın Owner'ı user.organization_role_id=NULL
	// kalır ve AuthorizationService.LoadAuthzContext deny-by-default boş
	// izin kümesi döner -- firma HİÇBİR business uca erişemez (bkz.
	// GetUserRoleCode: pgx.ErrNoRows -> boş yetki). Bu yüzden AYNI
	// transaction içinde, kullanıcı/organizasyon satırlarıyla ATOMIK olarak
	// yapılır.
	if err := txq.SeedSystemRolesForOrg(ctx, orgRow.ID); err != nil {
		return nil, err
	}
	ownerRole, err := txq.GetOrganizationRoleByCode(ctx, sqlc.GetOrganizationRoleByCodeParams{
		OrganizationID: orgRow.ID, Code: domain.OrgRoleOwner,
	})
	if err != nil {
		return nil, err
	}
	userRow, err = txq.UpdateUserOrganizationRole(ctx, sqlc.UpdateUserOrganizationRoleParams{
		ID: userRow.ID, OrganizationID: orgRow.ID, OrganizationRoleID: ownerRole.ID,
	})
	if err != nil {
		return nil, err
	}

	if err := s.writeAuditEvent(ctx, txq, in.ActorUserID, domain.AuditActionOrganizationCreated, &orgRow.ID, nil, map[string]any{
		"organization_name": name,
		"slug":              slug,
		"plan_code":         planCode,
		"status":            string(status),
		"owner_username":    ownerUsername,
	}); err != nil {
		return nil, err
	}

	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}

	org := repository.ToDomainOrganization(orgRow)
	owner := repository.ToDomainUser(userRow)
	result := &CreateOrganizationResult{Organization: org, Owner: owner}

	catalogRes, err := ProvisionCalcCatalog(ctx, s.calcSvc, s.productSvc, s.q, org.ID, false, nil)
	if err == nil {
		result.CalcCatalog = catalogRes
	}
	// Hata olsa da organizasyon+owner oluşturma BAŞARILI sayılır -- bkz.
	// yukarıdaki fonksiyon yorumu. Çağıran (handler), CalcCatalog nil ise
	// yanıtta "reprovision gerekebilir" notunu ekleyebilir.

	return result, nil
}

// SetStatus, bir organizasyonun yaşam döngüsü durumunu değiştirir
// (active/suspended/cancelled; trial yalnızca oluşturma anında). Geçişler
// domain.OrgStatus.CanTransitionTo ile sınırlıdır -- silme YOKTUR, cancelled
// bir durumdur ve satır/tarihçe korunur. is_active, status.AllowsAccess()
// ile eşzamanlı güncellenir (backward-compat -- bkz. migration 0030 yorumu).
// Askıya alma/iptal, YALNIZCA yeni login/refresh'i değil (AuthService),
// zaten geçerli access token'la gelen mid-session istekleri de RequireAuth
// middleware'i üzerinden hemen keser.
func (s *PlatformService) SetStatus(ctx context.Context, organizationID, actorUserID string, status domain.OrgStatus) (*domain.Organization, error) {
	if !status.Valid() {
		return nil, errors.New("geçersiz firma durumu")
	}
	current, err := s.requireLiveOrganization(ctx, organizationID)
	if err != nil {
		return nil, err
	}
	if !current.Status.CanTransitionTo(status) {
		return nil, domain.ErrInvalidOrgStatusTransition
	}
	orgID, _ := repository.StringToUUID(organizationID)
	row, err := s.q.UpdateOrganizationStatus(ctx, sqlc.UpdateOrganizationStatusParams{
		ID: orgID, Status: string(status), IsActive: status.AllowsAccess(),
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	action := domain.AuditActionOrganizationActivated
	switch status {
	case domain.OrgStatusSuspended:
		action = domain.AuditActionOrganizationSuspended
	case domain.OrgStatusCancelled:
		action = domain.AuditActionOrganizationCancelled
	}
	_ = s.writeAuditEvent(ctx, s.q, actorUserID, action, &orgID, nil, map[string]any{
		"status": string(status), "from": string(current.Status),
	})
	org := repository.ToDomainOrganization(row)
	return &org, nil
}

func (s *PlatformService) UpdatePlan(ctx context.Context, organizationID, actorUserID, planCode string) (*domain.Organization, error) {
	planCode = strings.TrimSpace(planCode)
	if planCode == "" {
		return nil, errors.New("plan kodu zorunludur")
	}
	if _, err := s.requireLiveOrganization(ctx, organizationID); err != nil {
		return nil, err
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	row, err := s.q.UpdateOrganizationPlan(ctx, sqlc.UpdateOrganizationPlanParams{ID: orgID, PlanCode: planCode})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23503" {
			return nil, errors.New("geçersiz plan kodu")
		}
		return nil, err
	}
	_ = s.writeAuditEvent(ctx, s.q, actorUserID, domain.AuditActionOrganizationPlanChanged, &orgID, nil, map[string]any{"plan_code": planCode})
	org := repository.ToDomainOrganization(row)
	return &org, nil
}

type OrganizationListResult struct {
	Organizations []domain.Organization
	Total         int64
}

func (s *PlatformService) ListOrganizations(ctx context.Context, statusFilter string, page, limit int) (*OrganizationListResult, error) {
	if limit <= 0 || limit > 100 {
		limit = 20
	}
	if page <= 0 {
		page = 1
	}
	rows, err := s.q.ListOrganizationsPaged(ctx, sqlc.ListOrganizationsPagedParams{
		Column1: statusFilter, Limit: int32(limit), Offset: int32((page - 1) * limit),
	})
	if err != nil {
		return nil, err
	}
	total, err := s.q.CountOrganizationsFiltered(ctx, statusFilter)
	if err != nil {
		return nil, err
	}
	orgs := make([]domain.Organization, len(rows))
	for i, r := range rows {
		orgs[i] = repository.ToDomainOrganization(r)
	}
	return &OrganizationListResult{Organizations: orgs, Total: total}, nil
}

// ListDeletedOrganizations, Süper Admin'in "Silinenler" (Arşiv) görünümüdür
// -- status filtresinden BAĞIMSIZDIR (bkz. domain/organization.go
// Organization.DeletedAt yorumu: silinen bir firma HANGİ durumdaysa o
// durumda kalır).
func (s *PlatformService) ListDeletedOrganizations(ctx context.Context, page, limit int) (*OrganizationListResult, error) {
	if limit <= 0 || limit > 100 {
		limit = 20
	}
	if page <= 0 {
		page = 1
	}
	rows, err := s.q.ListDeletedOrganizations(ctx, sqlc.ListDeletedOrganizationsParams{Limit: int32(limit), Offset: int32((page - 1) * limit)})
	if err != nil {
		return nil, err
	}
	total, err := s.q.CountDeletedOrganizations(ctx)
	if err != nil {
		return nil, err
	}
	orgs := make([]domain.Organization, len(rows))
	for i, r := range rows {
		orgs[i] = repository.ToDomainOrganization(r)
	}
	return &OrganizationListResult{Organizations: orgs, Total: total}, nil
}

// DeleteOrganization, firmayı YUMUŞAK siler: satır ve TÜM tarihçesi
// (kullanıcılar/projeler/teklifler/finans/denetim) OLDUĞU GİBİ kalır,
// yalnızca deleted_at/deleted_by yazılır -- status'e DOKUNULMAZ (bkz.
// domain/organization.go Organization.DeletedAt yorumu: "Askıya Al"/
// "İptal Et" ile KASITLI OLARAK aynı şey değildir). Erişim engeli status'ten
// BAĞIMSIZ olarak RequireAuth/AuthService'in mevcut organizasyon-durumu
// kontrolüne deleted_at eklenerek sağlanır (bkz. middleware/auth.go,
// AuthService.loadOrgForAccess) -- kullanıcı satırlarına TEK TEK
// dokunulmaz, mevcut oturumlar bir sonraki istekte/yenilemede otomatik
// reddedilir (askıya almanın ZATEN çalıştığı AYNI mekanizma).
func (s *PlatformService) DeleteOrganization(ctx context.Context, organizationID, actorUserID string) error {
	org, err := s.GetOrganization(ctx, organizationID)
	if err != nil {
		return err
	}
	if org.IsDeleted() {
		return domain.ErrAlreadyDeleted
	}
	orgID, _ := repository.StringToUUID(organizationID)
	var deletedBy pgtype.UUID
	if actorUserID != "" {
		if aid, aerr := repository.StringToUUID(actorUserID); aerr == nil {
			deletedBy = aid
		}
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	rows, err := txq.SoftDeleteOrganization(ctx, sqlc.SoftDeleteOrganizationParams{ID: orgID, DeletedBy: deletedBy})
	if err != nil {
		return err
	}
	if rows == 0 {
		return domain.ErrAlreadyDeleted
	}
	if err := s.writeAuditEvent(ctx, txq, actorUserID, domain.AuditActionOrganizationDeleted, &orgID, nil, map[string]any{
		"organization_name": org.Name, "status": string(org.Status),
	}); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func (s *PlatformService) RestoreOrganization(ctx context.Context, organizationID, actorUserID string) error {
	org, err := s.GetOrganization(ctx, organizationID)
	if err != nil {
		return err
	}
	orgID, _ := repository.StringToUUID(organizationID)

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	rows, err := txq.RestoreOrganization(ctx, orgID)
	if err != nil {
		return err
	}
	if rows == 0 {
		return domain.ErrNotDeleted
	}
	if err := s.writeAuditEvent(ctx, txq, actorUserID, domain.AuditActionOrganizationRestored, &orgID, nil, map[string]any{
		"organization_name": org.Name,
	}); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// ListPlans, Super Admin'in firma oluşturma/plan değiştirme formlarında
// gösterdiği plan listesidir -- bu fazda plan CRUD YOK (migration 0031'de
// seed edilen trial/starter/pro/business sabit), yalnızca aktif olanlar
// listelenir.
func (s *PlatformService) ListPlans(ctx context.Context) ([]domain.Plan, error) {
	rows, err := s.q.ListActivePlans(ctx)
	if err != nil {
		return nil, err
	}
	plans := make([]domain.Plan, len(rows))
	for i, r := range rows {
		plans[i] = repository.ToDomainPlan(r)
	}
	return plans, nil
}

// GetOrganization, silinmiş firmaları da döner (Süper Admin'in Silinenler/
// Arşiv görünümünden detaya girebilmesi VE Geri Yükle'nin hedefi bulabilmesi
// için BİLİNÇLİ OLARAK filtrelenmez) -- yalnızca LİSTELER (ListOrganizations)
// varsayılan olarak dışarıda bırakır.
func (s *PlatformService) GetOrganization(ctx context.Context, organizationID string) (*domain.Organization, error) {
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	row, err := s.q.GetOrganizationByID(ctx, orgID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	org := repository.ToDomainOrganization(row)
	return &org, nil
}

// requireLiveOrganization, GetOrganization'ın "silinmemiş" garantili
// versiyonudur -- durum/plan/kullanıcı yönetimi gibi HER mutasyonun ortak
// ön kontrolü: silinmiş bir firma önce RestoreOrganization ile geri
// yüklenmeden hiçbir şekilde değiştirilemez (yaşam döngüsü durumu dahil --
// "aktifleştir" bile anlamsızdır, firma zaten listelerden/erişimden
// tamamen dışarıdadır).
func (s *PlatformService) requireLiveOrganization(ctx context.Context, organizationID string) (*domain.Organization, error) {
	org, err := s.GetOrganization(ctx, organizationID)
	if err != nil {
		return nil, err
	}
	if org.IsDeleted() {
		return nil, domain.ErrOrganizationDeleted
	}
	return org, nil
}

// CountActiveOwners, sayfalanmış kullanıcı listesinden BAĞIMSIZ, doğru
// "bu firmanın aktif bir Sahibi var mı" cevabıdır -- ListOrganizationUsers
// 200 satırla sınırlıdır ve en eski (ilk oluşturulan) kullanıcı büyük
// firmalarda sayfanın dışına düşebilir; "Sahip yok" uyarısı bu yüzden
// TAM listeye değil, bu ayrı sayıma dayanmalıdır.
func (s *PlatformService) CountActiveOwners(ctx context.Context, organizationID string) (int64, error) {
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return 0, domain.ErrNotFound
	}
	return s.q.CountActiveOwners(ctx, orgID)
}

// ListOrganizationUsers, firmanın kullanıcılarını organizasyon rolüyle
// (Sahip/Yönetici/Proje Yöneticisi/...) zenginleştirilmiş olarak döner --
// tenant tarafındaki "Kullanıcılar" ekranının AYNI sorgusu
// (ListUsersWithOrganizationRole), farklı bir izin sınırı arkasında
// (RequireRole(super_admin) + URL'deki açık organizasyon kimliği).
func (s *PlatformService) ListOrganizationUsers(ctx context.Context, organizationID string, page, limit int) (*ListResult, error) {
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	if page <= 0 {
		page = 1
	}
	rows, err := s.q.ListUsersWithOrganizationRole(ctx, sqlc.ListUsersWithOrganizationRoleParams{
		OrganizationID: orgID, Limit: int32(limit), Offset: int32((page - 1) * limit),
	})
	if err != nil {
		return nil, err
	}
	total, err := s.q.CountUsers(ctx, orgID)
	if err != nil {
		return nil, err
	}
	users := make([]domain.User, len(rows))
	for i, r := range rows {
		users[i] = repository.ToDomainUserWithRole(r)
	}
	return &ListResult{Users: users, Total: total}, nil
}

func (s *PlatformService) ReprovisionCalcCatalog(ctx context.Context, organizationID, actorUserID string, linkProducts bool) (*CalcCatalogProvisionResult, error) {
	if _, err := s.requireLiveOrganization(ctx, organizationID); err != nil {
		return nil, err
	}
	res, err := ProvisionCalcCatalog(ctx, s.calcSvc, s.productSvc, s.q, organizationID, linkProducts, nil)
	if err != nil {
		return nil, err
	}
	orgID, _ := repository.StringToUUID(organizationID)
	_ = s.writeAuditEvent(ctx, s.q, actorUserID, domain.AuditActionCalcCatalogReprovisioned, &orgID, nil, map[string]any{
		"groups_created": res.GroupsCreated, "categories_created": res.CategoriesCreated, "items_created": res.ItemsCreated,
	})
	return res, nil
}

func (s *PlatformService) ListAuditEvents(ctx context.Context, organizationID string, page, limit int) ([]domain.AuditEvent, error) {
	if limit <= 0 || limit > 100 {
		limit = 20
	}
	if page <= 0 {
		page = 1
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	rows, err := s.q.ListAuditEventsForOrganization(ctx, sqlc.ListAuditEventsForOrganizationParams{
		TargetOrganizationID: orgID, Limit: int32(limit), Offset: int32((page - 1) * limit),
	})
	if err != nil {
		return nil, err
	}
	events := make([]domain.AuditEvent, len(rows))
	for i, r := range rows {
		events[i] = repository.ToDomainAuditEvent(r)
	}
	return events, nil
}

// CreateSuperAdmin, cmd/create-platform-admin CLI'ının tek çağıranı --
// organization_id her zaman NULL, must_change_password=false (operatör
// zaten gerçek şifreyi elle giriyor, geçici bir şifre değil).
func (s *PlatformService) CreateSuperAdmin(ctx context.Context, username, password, fullName string) (*domain.User, error) {
	username = strings.TrimSpace(username)
	fullName = strings.TrimSpace(fullName)
	if username == "" || password == "" || fullName == "" {
		return nil, errors.New("kullanıcı adı, şifre ve ad soyad zorunludur")
	}
	if len(password) < 8 {
		return nil, errors.New("şifre en az 8 karakter olmalı")
	}
	hash, err := auth.HashPassword(password)
	if err != nil {
		return nil, err
	}
	row, err := s.q.CreateUserWithOptions(ctx, sqlc.CreateUserWithOptionsParams{
		OrganizationID:     pgtype.UUID{}, // Valid=false -> NULL
		Username:           username,
		PasswordHash:       hash,
		FullName:           fullName,
		Role:               string(domain.RoleSuperAdmin),
		MustChangePassword: false,
	})
	if err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" {
			return nil, domain.ErrDuplicateUsername
		}
		return nil, err
	}
	u := repository.ToDomainUser(row)
	return &u, nil
}

// ResetSuperAdminPassword, bir Super Admin'in şifresini değiştirir --
// yalnızca sunucudaki CLI'dan (cmd/reset-platform-admin-password) çağrılır.
// Super Admin'in web'de ya da API'de kendi şifresini değiştireceği bir yer
// yok: /users/me/password firma (tenant) ister, Profilim sayfası firma
// kabuğunda. CreateSuperAdmin gibi bu da HTTP'ye açılmaz.
//
// Eski şifreyle açılmış bütün oturumlar kapanır (şifre değişimi bir sızıntı
// sebebiyle yapılıyor olabilir) ve işlem platform denetim kaydına yazılır.
func (s *PlatformService) ResetSuperAdminPassword(ctx context.Context, username, password string) error {
	username = strings.TrimSpace(username)
	if username == "" {
		return errors.New("kullanıcı adı zorunludur")
	}
	if !domain.ValidPasswordLength(password) {
		return domain.ErrPasswordTooShort
	}
	hash, err := auth.HashPassword(password)
	if err != nil {
		return err
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)
	id, err := txq.SetSuperAdminPassword(ctx, sqlc.SetSuperAdminPasswordParams{Username: username, PasswordHash: hash})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return domain.ErrNotFound
		}
		return err
	}
	if err := txq.RevokeAllUserRefreshTokens(ctx, id); err != nil {
		return err
	}
	if err := s.writeAuditEvent(ctx, txq, "", domain.AuditActionUserPasswordReset, nil, &id, map[string]any{
		"target": "super_admin", "source": "cli",
	}); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// writeAuditEvent, platform_audit_events'e değişmez bir denetim kaydı
// yazar. actorUserID boşsa (ör. CLI'dan/sistemden tetiklenen işlemler)
// actor_user_id NULL kalır -- offer_events/logOfferEvent ile aynı desen.
func (s *PlatformService) writeAuditEvent(ctx context.Context, q *sqlc.Queries, actorUserID, action string, targetOrgID, targetUserID *pgtype.UUID, metadata map[string]any) error {
	var actor pgtype.UUID
	if actorUserID != "" {
		if uid, err := repository.StringToUUID(actorUserID); err == nil {
			actor = uid
		}
	}
	var targetOrg, targetUser pgtype.UUID
	if targetOrgID != nil {
		targetOrg = *targetOrgID
	}
	if targetUserID != nil {
		targetUser = *targetUserID
	}
	metaBytes := []byte("{}")
	if len(metadata) > 0 {
		b, err := json.Marshal(metadata)
		if err != nil {
			return err
		}
		metaBytes = b
	}
	_, err := q.InsertAuditEvent(ctx, sqlc.InsertAuditEventParams{
		ActorUserID: actor, Action: action, TargetOrganizationID: targetOrg, TargetUserID: targetUser, Metadata: metaBytes,
	})
	return err
}
