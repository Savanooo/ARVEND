package middleware_test

// Bu dosya, ARVEND V2 -- Sprint 1 (RBAC + Project Membership + Authorization
// Foundation) spec'inin 19 maddelik Güvenlik Test Matrisi'ni GERÇEK bir
// PostgreSQL bağlantısına (DB_URL) VE GERÇEK, TAM router'a (httpapi.NewRouter
// -- main.go'daki AYNI bağımlılık kablolaması) karşı doğrular. Amaç:
// project_operations_test.go/project_finance_test.go/project_change_order_
// test.go'daki servis-katmanı testleri middleware zincirini ATLAR (doğrudan
// servis metodunu çağırırlar) -- burada GERÇEK HTTP isteği, GERÇEK
// requireAuth->requireOnboarded->loadAuthorization->requirePermission/
// requireProjectPermission zincirinden geçer, router.go'daki rota->izin
// eşlemesinin KENDİSİ de doğrulanmış olur.

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/joho/godotenv"

	"github.com/Savanooo/ARVEND/backend/internal/auth"
	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/httpapi"
	"github.com/Savanooo/ARVEND/backend/internal/httpapi/handler"
	"github.com/Savanooo/ARVEND/backend/internal/platform/crypto"
	"github.com/Savanooo/ARVEND/backend/internal/platform/storage"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

func rbacTestSecretBox(t *testing.T) *crypto.SecretBox {
	t.Helper()
	_ = godotenv.Load("../../../.env")
	key := os.Getenv("SETTINGS_ENCRYPTION_KEY")
	if key == "" {
		t.Skip("SETTINGS_ENCRYPTION_KEY ayarlanmamış, atlanıyor")
	}
	box, err := crypto.NewSecretBox(key)
	if err != nil {
		t.Fatalf("SecretBox oluşturulamadı: %v", err)
	}
	return box
}

func rbacCleanupOrg(t *testing.T, pool *pgxpool.Pool, orgID string) {
	t.Helper()
	ctx := context.Background()
	for _, stmt := range []string{
		"DELETE FROM project_users WHERE organization_id = $1",
		"DELETE FROM project_events WHERE organization_id = $1",
		"DELETE FROM project_tasks WHERE organization_id = $1",
		"DELETE FROM project_schedule_items WHERE organization_id = $1",
		"DELETE FROM project_expenses WHERE organization_id = $1",
		// change_order_counters, projects SİLİNMEDEN ÖNCE (project_id FK) temizlenmeli.
		"DELETE FROM change_order_counters WHERE project_id IN (SELECT id FROM projects WHERE organization_id = $1)",
		// Cost Control (Sprint 2, migration 0035) -- bkz. tenant_isolation_
		// test.go'daki cleanupOrganization'ın AYNI gerekçesi: forecasts/
		// commitments, budget_lines'a RESTRICT FK taşır, bu yüzden projects
		// (ve onun cascade'lediği project_budgets) silinmeden ÖNCE temizlenir.
		"DELETE FROM project_cost_forecasts WHERE organization_id = $1",
		"DELETE FROM project_commitments WHERE organization_id = $1",
		"DELETE FROM project_budget_adjustments WHERE organization_id = $1",
		"DELETE FROM project_budget_lines WHERE organization_id = $1",
		"DELETE FROM project_budgets WHERE organization_id = $1",
		"DELETE FROM project_wbs_nodes WHERE organization_id = $1",
		// project_contracts (Sprint 3), projects'e CASCADE'siz FK taşır --
		// AYNI gerekçeyle projects'ten ÖNCE temizlenmeli.
		"DELETE FROM project_contracts WHERE organization_id = $1",
		// Procurement (Sprint 4, migration 0037) -- tenant_isolation_test.go
		// cleanupOrganization İLE AYNI sıra/gerekçe (bkz. o dosyadaki yorum):
		// purchase_orders -> rfqs.awarded_quotation_id NULL'a çek ->
		// supplier_quotations -> rfqs -> purchase_requests -> suppliers.
		"DELETE FROM purchase_orders WHERE organization_id = $1",
		"UPDATE rfqs SET awarded_quotation_id = NULL WHERE organization_id = $1",
		"DELETE FROM supplier_quotations WHERE organization_id = $1",
		"DELETE FROM rfqs WHERE organization_id = $1",
		"DELETE FROM purchase_requests WHERE organization_id = $1",
		// Sprint 5 (Taşeron Yönetimi, migration 0038) -- tenant_isolation_
		// test.go'daki cleanupOrganization İLE AYNI sıra/gerekçe.
		"DELETE FROM subcontract_progress_claim_items WHERE organization_id = $1",
		"DELETE FROM subcontract_progress_claims WHERE organization_id = $1",
		"DELETE FROM subcontract_change_order_items WHERE organization_id = $1",
		"DELETE FROM subcontract_change_orders WHERE organization_id = $1",
		"DELETE FROM subcontract_items WHERE organization_id = $1",
		// subcontract_payments (migration 0039), project_subcontracts'a
		// CASCADE'siz FK taşır -- ondan ÖNCE (tenant_isolation_test.go ile aynı).
		"DELETE FROM subcontract_payments WHERE organization_id = $1",
		"DELETE FROM project_subcontracts WHERE organization_id = $1",
		"DELETE FROM suppliers WHERE organization_id = $1",
		"DELETE FROM projects WHERE organization_id = $1",
		// current_revision_id, offer_revisions'a FK taşır -- satırı
		// SİLMEDEN ÖNCE NULL'lanmalı (offers_current_revision_id_fkey).
		"UPDATE offers SET current_revision_id = NULL WHERE organization_id = $1",
		"DELETE FROM offer_revisions WHERE offer_id IN (SELECT id FROM offers WHERE organization_id = $1)",
		"DELETE FROM offer_events WHERE offer_id IN (SELECT id FROM offers WHERE organization_id = $1)",
		"DELETE FROM offer_share_links WHERE offer_id IN (SELECT id FROM offers WHERE organization_id = $1)",
		"DELETE FROM offers WHERE organization_id = $1",
		"DELETE FROM offer_counters WHERE organization_id = $1",
		"DELETE FROM project_counters WHERE organization_id = $1",
		"DELETE FROM purchase_request_counters WHERE organization_id = $1",
		"DELETE FROM rfq_counters WHERE organization_id = $1",
		"DELETE FROM purchase_order_counters WHERE organization_id = $1",
		"DELETE FROM subcontract_counters WHERE organization_id = $1",
		"DELETE FROM subcontract_change_order_counters WHERE organization_id = $1",
		"DELETE FROM subcontract_progress_claim_counters WHERE organization_id = $1",
		// employees.user_id (migration 0041) -- project_members RESTRICT
		// FK taşır (employees'ten ÖNCE temizlenmeli), attendance_logs
		// CASCADE'dir (ayrıca silmeye gerek yok). Bu harness'e Sprint 5
		// SONRASI eklenen ilk employees-oluşturan test (tasks_mine_
		// security_test.go) için gerekli -- önceki hiçbir RBAC testi
		// employees satırı ÜRETMİYORDU.
		"DELETE FROM project_members WHERE organization_id = $1",
		"DELETE FROM employees WHERE organization_id = $1",
		"DELETE FROM role_permissions WHERE organization_role_id IN (SELECT id FROM organization_roles WHERE organization_id = $1)",
		"UPDATE users SET organization_role_id = NULL WHERE organization_id = $1",
		"DELETE FROM organization_roles WHERE organization_id = $1",
		"DELETE FROM calc_recipe_items WHERE organization_id = $1",
		"DELETE FROM calc_categories WHERE organization_id = $1",
		"DELETE FROM calc_groups WHERE organization_id = $1",
		// products (fiyat kaynağı senkron testleri üretir) -- product_price_
		// history CASCADE ile gider; organization_price_sources organizations'a
		// CASCADE FK taşır, ayrıca silmeye gerek yok.
		"DELETE FROM products WHERE organization_id = $1",
		"DELETE FROM organization_profile WHERE organization_id = $1",
		"DELETE FROM organization_commercial_settings WHERE organization_id = $1",
		"DELETE FROM platform_audit_events WHERE target_organization_id = $1",
		// organization_cost_codes, projects SİLİNDİKTEN SONRA (o silme
		// expenses/subcontractors'ı CASCADE ile kaldırır) VE budget_lines/
		// commitments yukarıda AYRICA silindiği İÇİN artık serbestçe silinebilir.
		"DELETE FROM organization_cost_codes WHERE organization_id = $1",
		"DELETE FROM organization_events WHERE organization_id = $1",
		"DELETE FROM users WHERE organization_id = $1",
		"DELETE FROM organizations WHERE id = $1",
	} {
		if _, err := pool.Exec(ctx, stmt, orgID); err != nil {
			t.Logf("temizlik uyarısı (%s): %v", stmt, err)
		}
	}
}

// rbacTestDeps, main.go'nun bağımlılık kablolamasının BİREBİR aynısıdır --
// gerçek router'ı test etmek için.
type rbacTestDeps struct {
	pool        *pgxpool.Pool
	q           *sqlc.Queries
	router      http.Handler
	issuer      *auth.JWTIssuer
	userSvc     *service.UserService
	platform    *service.PlatformService
	authzSvc    *service.AuthorizationService
	offerSvc    *service.OfferService
	projectSvc  *service.ProjectService
	costCodeSvc *service.CostCodeService
	supplierSvc *service.SupplierService
	// dashboardSvc, ana sayfa özeti (GET /dashboard) -- FailSection test
	// kancası için doğrudan erişilir (bkz. dashboard_security_test.go).
	dashboardSvc *service.DashboardService

	// priceFetch/demirFetch, Ulaş ve Demir Profil senkronunun sahte
	// listeleri -- testler ulas.com.tr'ye/demirprofil.com.tr'ye ASLA gitmez
	// (bkz. price_sources_security_test.go).
	priceFetch *stubPriceFetcher
	demirFetch *stubPriceFetcher
}

func setupRBACTestRouter(t *testing.T) *rbacTestDeps {
	t.Helper()
	_ = godotenv.Load("../../../.env")
	dbURL := os.Getenv("DB_URL")
	if dbURL == "" {
		t.Skip("DB_URL ayarlanmamış -- RBAC güvenlik matrisi testi gerçek bir PostgreSQL bağlantısı gerektirir, atlanıyor")
	}
	secretBox := rbacTestSecretBox(t)

	ctx := context.Background()
	pool, err := repository.NewPool(ctx, dbURL)
	if err != nil {
		t.Fatalf("veritabanına bağlanılamadı: %v", err)
	}
	t.Cleanup(func() { pool.Close() })
	q := sqlc.New(pool)

	userSvc := service.NewUserService(q)
	productSvc := service.NewProductService(q)
	settingsSvc := service.NewSettingsService(q, secretBox)
	offerSvc := service.NewOfferService(pool, q, settingsSvc, "http://localhost:3000")
	fileStore, err := storage.NewLocalStore(t.TempDir())
	if err != nil {
		t.Fatalf("test dosya deposu açılamadı: %v", err)
	}
	projectSvc := service.NewProjectService(pool, q, fileStore, settingsSvc, "http://localhost:3000")
	customerSvc := service.NewCustomerService(q)
	employeeSvc := service.NewEmployeeService(q)
	attendanceSvc := service.NewAttendanceService(q)
	calcSvc := service.NewCalcService(q)
	platformSvc := service.NewPlatformService(pool, q, userSvc, calcSvc, productSvc)
	onboardingSvc := service.NewOnboardingService(q, secretBox)
	authzSvc := service.NewAuthorizationService(q)
	costCodeSvc := service.NewCostCodeService(pool, q)
	supplierSvc := service.NewSupplierService(pool, q, secretBox)
	priceFetch := &stubPriceFetcher{}
	demirFetch := &stubPriceFetcher{}
	priceSourceSvc := service.NewPriceSourceService(pool, q, map[string]service.PriceFetcher{
		domain.PriceSourceUlas:        priceFetch.fetch,
		domain.PriceSourceDemirProfil: demirFetch.fetch,
	})

	dashboardSvc := service.NewDashboardService(pool, q)

	issuer := auth.NewJWTIssuer("test-secret-rbac-matrix", 15*time.Minute)
	authSvc := service.NewAuthService(q, issuer, 24*time.Hour)

	router := httpapi.NewRouter(httpapi.Deps{
		JWT:               issuer,
		Queries:           q,
		Auth:              handler.NewAuthHandler(authSvc, authzSvc, 15*time.Minute, 24*time.Hour, "", false),
		Users:             handler.NewUserHandler(userSvc, authzSvc),
		Products:          handler.NewProductHandler(productSvc),
		PriceSources:      handler.NewPriceSourceHandler(priceSourceSvc),
		Offers:            handler.NewOfferHandler(offerSvc),
		Projects:          handler.NewProjectHandler(projectSvc),
		Customers:         handler.NewCustomerHandler(customerSvc),
		Employees:         handler.NewEmployeeHandler(employeeSvc),
		Attendance:        handler.NewAttendanceHandler(attendanceSvc),
		Settings:          handler.NewSettingsHandler(settingsSvc),
		PublicOffer:       handler.NewPublicOfferHandler(offerSvc),
		PublicChangeOrder: handler.NewPublicChangeOrderHandler(projectSvc),
		Calc:              handler.NewCalcHandler(calcSvc),
		Platform:          handler.NewPlatformHandler(platformSvc),
		Onboarding:        handler.NewOnboardingHandler(onboardingSvc),
		Authorization:     handler.NewAuthorizationHandler(authzSvc),
		AuthorizationSvc:  authzSvc,
		CostCodes:         handler.NewCostCodeHandler(costCodeSvc),
		Suppliers:         handler.NewSupplierHandler(supplierSvc),
		Dashboard:         handler.NewDashboardHandler(dashboardSvc),
		CORSOrigins:       []string{"*"},
	})

	return &rbacTestDeps{
		pool: pool, q: q, router: router, issuer: issuer, priceFetch: priceFetch, demirFetch: demirFetch,
		userSvc: userSvc, platform: platformSvc, authzSvc: authzSvc,
		offerSvc: offerSvc, projectSvc: projectSvc, costCodeSvc: costCodeSvc, supplierSvc: supplierSvc,
		dashboardSvc: dashboardSvc,
	}
}

// mustCreateReadyOrg, tam onboard edilmiş (must_change_password=false,
// onboarding_completed=true) bir organizasyon + Owner oluşturur --
// RequireOnboarded gate'ini atlamak için (bu dosyanın odağı o gate DEĞİL,
// bkz. require_onboarded_test.go).
func mustCreateReadyOrg(t *testing.T, ctx context.Context, d *rbacTestDeps, slug string) *service.CreateOrganizationResult {
	t.Helper()
	row := d.pool.QueryRow(ctx, "SELECT id FROM organizations WHERE slug = $1", slug)
	var existingID string
	if scanErr := row.Scan(&existingID); scanErr == nil {
		rbacCleanupOrg(t, d.pool, existingID)
	}
	result, err := d.platform.CreateOrganizationWithOwner(ctx, service.CreateOrganizationInput{
		Name: "RBAC Matrix " + slug, Slug: slug,
		OwnerUsername: "owner_" + slug, OwnerPassword: "GeciciSifre123!", OwnerFullName: "Matrix Owner",
	})
	if err != nil {
		t.Fatalf("test organizasyonu+owner oluşturulamadı: %v", err)
	}
	if err := d.userSvc.SetInitialPassword(ctx, result.Owner.ID, result.Organization.ID, "SabitSifre123!"); err != nil {
		t.Fatalf("must_change_password temizlenemedi: %v", err)
	}
	if _, err := d.pool.Exec(ctx, "UPDATE organizations SET onboarding_completed = true WHERE id = $1", result.Organization.ID); err != nil {
		t.Fatalf("onboarding_completed güncellenemedi: %v", err)
	}
	return result
}

// mustCreateProject, kabul edilmiş bir teklifi projeye dönüştürür (gerçek
// akış: oluştur -> gönder -> paylaşım linki -> kabul -> dönüştür) -- Owner
// bağlamında (org-wide projects.create izni gerektirir, üyelikten muaf).
func mustCreateProject(t *testing.T, ctx context.Context, d *rbacTestDeps, orgID, name string) *domain.Project {
	t.Helper()
	o, err := d.offerSvc.Create(ctx, service.CreateOfferInput{
		OrganizationID: orgID, CustomerName: "RBAC Test Müşteri",
		Items: []service.OfferItemInput{{ProductName: "İş", Quantity: 1, UnitPrice: 10000}},
	})
	if err != nil {
		t.Fatalf("teklif oluşturulamadı: %v", err)
	}
	if _, err := d.offerSvc.UpdateStatus(ctx, o.ID, orgID, domain.OfferStatusGonderildi, ""); err != nil {
		t.Fatalf("teklif gönderilemedi: %v", err)
	}
	link, err := d.offerSvc.CreateShareLink(ctx, o.ID, orgID, "", nil)
	if err != nil {
		t.Fatalf("paylaşım linki oluşturulamadı: %v", err)
	}
	if _, err := d.offerSvc.RespondByShareLinkToken(ctx, link.Token, domain.OfferStatusKabulEdildi, "", ""); err != nil {
		t.Fatalf("teklif kabul edilemedi: %v", err)
	}
	p, err := d.projectSvc.CreateFromOffer(ctx, o.ID, orgID, service.CreateProjectInput{Name: name})
	if err != nil {
		t.Fatalf("proje oluşturulamadı: %v", err)
	}
	return p
}

// mustCreateRoleUser, verilen incelikli organizasyon rolüne (project_manager/
// finance/field) sahip YENİ bir kullanıcı oluşturur -- kaba rol (users.role)
// bilinçli olarak 'kullanici' bırakılır: bu, /projects/* rotalarının
// requireAdmin GEREKTİRMEDEN, YALNIZCA yeni izin sistemiyle çalıştığını
// (spec'in "dağınık requireAdmin yerine merkezi izin" ilkesini) ayrıca
// kanıtlar.
func mustCreateRoleUser(t *testing.T, ctx context.Context, d *rbacTestDeps, orgID, username, orgRoleCode string) (*domain.User, string) {
	t.Helper()
	u, err := d.userSvc.Create(ctx, orgID, username, "GeciciSifre123!", username, domain.RoleKullanici, "")
	if err != nil {
		t.Fatalf("%s kullanıcısı oluşturulamadı: %v", username, err)
	}
	if err := d.userSvc.SetInitialPassword(ctx, u.ID, orgID, "SabitSifre123!"); err != nil {
		t.Fatalf("%s için must_change_password temizlenemedi: %v", username, err)
	}
	if _, err := d.authzSvc.SetUserOrganizationRole(ctx, u.ID, orgID, orgRoleCode); err != nil {
		t.Fatalf("%s için organizasyon rolü (%s) atanamadı: %v", username, orgRoleCode, err)
	}
	token, err := d.issuer.IssueAccessToken(u.ID, domain.RoleKullanici, orgID)
	if err != nil {
		t.Fatalf("%s için token üretilemedi: %v", username, err)
	}
	return u, token
}

func rbacDo(t *testing.T, router http.Handler, method, path, token, body string) (*httptest.ResponseRecorder, map[string]any) {
	t.Helper()
	var req *http.Request
	if body != "" {
		req = httptest.NewRequest(method, path, strings.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
	} else {
		req = httptest.NewRequest(method, path, nil)
	}
	if token != "" {
		req.AddCookie(&http.Cookie{Name: "access_token", Value: token})
	}
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)
	var parsed map[string]any
	_ = json.Unmarshal(rec.Body.Bytes(), &parsed)
	return rec, parsed
}

func TestRBACSecurityMatrix(t *testing.T) {
	d := setupRBACTestRouter(t)
	ctx := context.Background()

	orgA := mustCreateReadyOrg(t, ctx, d, "rbac-matrix-org-a")
	t.Cleanup(func() { rbacCleanupOrg(t, d.pool, orgA.Organization.ID) })
	orgB := mustCreateReadyOrg(t, ctx, d, "rbac-matrix-org-b")
	t.Cleanup(func() { rbacCleanupOrg(t, d.pool, orgB.Organization.ID) })

	ownerToken, err := d.issuer.IssueAccessToken(orgA.Owner.ID, domain.RoleAdmin, orgA.Organization.ID)
	if err != nil {
		t.Fatalf("owner token üretilemedi: %v", err)
	}

	pmUser, pmToken := mustCreateRoleUser(t, ctx, d, orgA.Organization.ID, "rbac_pm", domain.OrgRoleProjectManager)
	_, finToken := mustCreateRoleUser(t, ctx, d, orgA.Organization.ID, "rbac_fin", domain.OrgRoleFinance)
	_, fieldToken := mustCreateRoleUser(t, ctx, d, orgA.Organization.ID, "rbac_field", domain.OrgRoleField)

	pA := mustCreateProject(t, ctx, d, orgA.Organization.ID, "Proje A (üye)")
	pB := mustCreateProject(t, ctx, d, orgA.Organization.ID, "Proje B (üye değil)")

	// project_manager/finance/field yalnızca pA'ya üye -- pB'ye ASLA
	// eklenmedi (üyelik-farkında erişim kontrolünün asıl test yüzeyi).
	for _, tok := range []string{pmUser.ID} {
		_ = tok
	}
	if _, err := d.authzSvc.AddProjectUser(ctx, pA.ID, orgA.Organization.ID, service.ProjectUserInput{
		UserID: pmUser.ID, ProjectRole: domain.ProjectRoleManager, CreatedBy: orgA.Owner.ID,
	}); err != nil {
		t.Fatalf("pm üyeliği eklenemedi: %v", err)
	}
	finUserRow, _ := d.q.GetUserByUsername(ctx, "rbac_fin")
	if _, err := d.authzSvc.AddProjectUser(ctx, pA.ID, orgA.Organization.ID, service.ProjectUserInput{
		UserID: finUserRow.ID.String(), ProjectRole: domain.ProjectRoleMember, CreatedBy: orgA.Owner.ID,
	}); err != nil {
		t.Fatalf("finance üyeliği eklenemedi: %v", err)
	}
	fieldUserRow, _ := d.q.GetUserByUsername(ctx, "rbac_field")
	if _, err := d.authzSvc.AddProjectUser(ctx, pA.ID, orgA.Organization.ID, service.ProjectUserInput{
		UserID: fieldUserRow.ID.String(), ProjectRole: domain.ProjectRoleMember, CreatedBy: orgA.Owner.ID,
	}); err != nil {
		t.Fatalf("field üyeliği eklenemedi: %v", err)
	}

	t.Run("1_non_super_admin_hitting_platform_endpoint_denied", func(t *testing.T) {
		rec, _ := rbacDo(t, d.router, http.MethodGet, "/api/v1/platform/plans", ownerToken, "")
		if rec.Code != http.StatusForbidden {
			t.Errorf("status = %d, want 403", rec.Code)
		}
	})

	t.Run("2_project_manager_assigned_project_access_allowed", func(t *testing.T) {
		rec, _ := rbacDo(t, d.router, http.MethodGet, "/api/v1/projects/"+pA.ID+"/tasks", pmToken, "")
		if rec.Code != http.StatusOK {
			t.Errorf("status = %d, want 200 (pm, pA üyesi, tasks.read izni var)", rec.Code)
		}
	})

	t.Run("3_project_manager_unassigned_project_access_denied", func(t *testing.T) {
		rec, body := rbacDo(t, d.router, http.MethodGet, "/api/v1/projects/"+pB.ID+"/tasks", pmToken, "")
		if rec.Code != http.StatusForbidden {
			t.Errorf("status = %d, want 403 (pm, pB üyesi DEĞİL)", rec.Code)
		}
		if body["code"] != "project_access_denied" {
			t.Errorf("code = %v, want project_access_denied", body["code"])
		}
	})

	t.Run("4_project_manager_denied_finance_without_permission", func(t *testing.T) {
		rec, body := rbacDo(t, d.router, http.MethodGet, "/api/v1/projects/"+pA.ID+"/financial-summary", pmToken, "")
		if rec.Code != http.StatusForbidden {
			t.Errorf("status = %d, want 403 (pm'nin finance.read izni yok)", rec.Code)
		}
		if body["code"] != "permission_denied" {
			t.Errorf("code = %v, want permission_denied", body["code"])
		}
	})

	t.Run("5_finance_allowed_project_finance", func(t *testing.T) {
		rec, _ := rbacDo(t, d.router, http.MethodGet, "/api/v1/projects/"+pA.ID+"/financial-summary", finToken, "")
		if rec.Code != http.StatusOK {
			t.Errorf("status = %d, want 200 (finance, pA üyesi, finance.read izni var)", rec.Code)
		}
	})

	t.Run("6_finance_denied_operations_manage", func(t *testing.T) {
		rec, _ := rbacDo(t, d.router, http.MethodPost, "/api/v1/projects/"+pA.ID+"/notes", finToken, `{"content":"x"}`)
		if rec.Code != http.StatusForbidden {
			t.Errorf("status = %d, want 403 (finance'ın operations.manage izni yok)", rec.Code)
		}
	})

	t.Run("7_field_assigned_project_task_access_allowed", func(t *testing.T) {
		rec, _ := rbacDo(t, d.router, http.MethodGet, "/api/v1/projects/"+pA.ID+"/tasks", fieldToken, "")
		if rec.Code != http.StatusOK {
			t.Errorf("status = %d, want 200 (field, pA üyesi, tasks.read izni var)", rec.Code)
		}
	})

	t.Run("8_field_denied_finance", func(t *testing.T) {
		rec, _ := rbacDo(t, d.router, http.MethodGet, "/api/v1/projects/"+pA.ID+"/expenses", fieldToken, "")
		if rec.Code != http.StatusForbidden {
			t.Errorf("status = %d, want 403 (field'ın finance.read izni yok)", rec.Code)
		}
	})

	t.Run("9_admin_owner_project_visibility_bypasses_membership", func(t *testing.T) {
		// Owner, pB'ye HİÇ üye değil ama tüm projeleri görme muafiyeti var.
		rec, _ := rbacDo(t, d.router, http.MethodGet, "/api/v1/projects/"+pB.ID, ownerToken, "")
		if rec.Code != http.StatusOK {
			t.Errorf("status = %d, want 200 (owner üyelikten muaf)", rec.Code)
		}
	})

	t.Run("10_list_projects_membership_filtered_for_pm_full_for_owner", func(t *testing.T) {
		_, body := rbacDo(t, d.router, http.MethodGet, "/api/v1/projects/?limit=200", pmToken, "")
		projects, _ := body["projects"].([]any)
		for _, p := range projects {
			m := p.(map[string]any)
			if m["id"] == pB.ID {
				t.Errorf("pm'nin proje listesinde üye OLMADIĞI pB göründü")
			}
		}
		found := false
		for _, p := range projects {
			if p.(map[string]any)["id"] == pA.ID {
				found = true
			}
		}
		if !found {
			t.Errorf("pm'nin proje listesinde üye OLDUĞU pA görünmedi")
		}

		_, ownerBody := rbacDo(t, d.router, http.MethodGet, "/api/v1/projects/?limit=200", ownerToken, "")
		ownerProjects, _ := ownerBody["projects"].([]any)
		seenA, seenB := false, false
		for _, p := range ownerProjects {
			switch p.(map[string]any)["id"] {
			case pA.ID:
				seenA = true
			case pB.ID:
				seenB = true
			}
		}
		if !seenA || !seenB {
			t.Errorf("owner'ın listesi TÜM projeleri içermeli (pA=%v pB=%v)", seenA, seenB)
		}
	})

	t.Run("11_tenant_admin_self_promotion_to_super_admin_rejected", func(t *testing.T) {
		rec, _ := rbacDo(t, d.router, http.MethodPut, "/api/v1/users/"+pmUser.ID+"/organization-role", ownerToken, `{"role_code":"super_admin"}`)
		if rec.Code == http.StatusOK {
			t.Errorf("normal admin bir kullanıcıyı super_admin'e YÜKSELTEBİLDİ (status=%d) -- KRİTİK güvenlik hatası", rec.Code)
		}
		if rec.Code != http.StatusNotFound {
			t.Errorf("status = %d, want 404 (organization_roles'ta 'super_admin' kodu HİÇ yoktur)", rec.Code)
		}
	})

	t.Run("12_last_owner_cannot_be_downgraded", func(t *testing.T) {
		rec, _ := rbacDo(t, d.router, http.MethodPut, "/api/v1/users/"+orgA.Owner.ID+"/organization-role", ownerToken, `{"role_code":"admin"}`)
		if rec.Code != http.StatusConflict {
			t.Errorf("status = %d, want 409 (son owner düşürülemez)", rec.Code)
		}
	})

	t.Run("13_cross_tenant_membership_creation_rejected", func(t *testing.T) {
		rec, _ := rbacDo(t, d.router, http.MethodPost, "/api/v1/projects/"+pA.ID+"/access", ownerToken,
			`{"user_id":"`+orgB.Owner.ID+`","project_role":"member"}`)
		if rec.Code == http.StatusCreated {
			t.Errorf("Firma B'nin kullanıcısı Firma A'nın projesine EKLENEBİLDİ -- KRİTİK güvenlik hatası (status=%d)", rec.Code)
		}
		if rec.Code != http.StatusBadRequest {
			t.Errorf("status = %d, want 400 (cross-tenant membership reddedilmeli)", rec.Code)
		}
	})

	t.Run("14_duplicate_project_membership_stays_single_row", func(t *testing.T) {
		newUser, err := d.userSvc.Create(ctx, orgA.Organization.ID, "rbac_dup_test", "GeciciSifre123!", "Dup Test", domain.RoleKullanici, "")
		if err != nil {
			t.Fatalf("kullanıcı oluşturulamadı: %v", err)
		}
		body := `{"user_id":"` + newUser.ID + `","project_role":"member"}`
		for i := 0; i < 3; i++ {
			rec, _ := rbacDo(t, d.router, http.MethodPost, "/api/v1/projects/"+pA.ID+"/access", ownerToken, body)
			if rec.Code != http.StatusCreated {
				t.Fatalf("tekrar #%d: status = %d, want 201", i, rec.Code)
			}
		}
		var count int64
		row := d.pool.QueryRow(ctx, "SELECT count(*) FROM project_users WHERE project_id = $1 AND user_id = $2", pA.ID, newUser.ID)
		if err := row.Scan(&count); err != nil {
			t.Fatalf("sayım sorgusu başarısız: %v", err)
		}
		if count != 1 {
			t.Errorf("tekrarlı ekleme sonrası satır sayısı = %d, want 1", count)
		}
	})

	t.Run("15_organization_roles_list_never_shows_legacy_user", func(t *testing.T) {
		_, body := rbacDo(t, d.router, http.MethodGet, "/api/v1/organization/roles", ownerToken, "")
		roles, _ := body["roles"].([]any)
		for _, r := range roles {
			if r.(map[string]any)["code"] == domain.OrgRoleLegacyUser {
				t.Errorf("legacy_user rol listesinde göründü -- web rol seçicisinde ASLA gösterilmemeli")
			}
		}
	})

	t.Run("16_unknown_permission_code_rejected_on_role_update", func(t *testing.T) {
		var roleID string
		row := d.pool.QueryRow(ctx, "SELECT id FROM organization_roles WHERE organization_id = $1 AND code = 'finance'", orgA.Organization.ID)
		if err := row.Scan(&roleID); err != nil {
			t.Fatalf("finance rolü bulunamadı: %v", err)
		}
		rec, _ := rbacDo(t, d.router, http.MethodPut, "/api/v1/organization/roles/"+roleID+"/permissions", ownerToken,
			`{"permissions":["not.a.real.permission"]}`)
		if rec.Code != http.StatusBadRequest {
			t.Errorf("status = %d, want 400 (tanımsız izin kodu reddedilmeli)", rec.Code)
		}
	})

	t.Run("17_non_admin_coarse_role_still_blocked_from_users_admin_by_requireAdmin", func(t *testing.T) {
		// pm'nin KABA rolü (users.role) hâlâ 'kullanici' -- requireAdmin
		// katmanı YENİ izin sisteminden BAĞIMSIZ olarak burada hâlâ devrede
		// (bkz. router.go /users grubu notu: "ek bir kapı, YERİNE değil").
		rec, _ := rbacDo(t, d.router, http.MethodGet, "/api/v1/users", pmToken, "")
		if rec.Code != http.StatusForbidden {
			t.Errorf("status = %d, want 403 (requireAdmin hâlâ devrede olmalı)", rec.Code)
		}
	})

	t.Run("18_admin_user_list_shows_enriched_organization_role", func(t *testing.T) {
		rec, body := rbacDo(t, d.router, http.MethodGet, "/api/v1/users", ownerToken, "")
		if rec.Code != http.StatusOK {
			t.Fatalf("status = %d, want 200", rec.Code)
		}
		users, _ := body["users"].([]any)
		foundOwnerRole := false
		for _, u := range users {
			m := u.(map[string]any)
			if m["id"] == orgA.Owner.ID && m["organization_role_code"] == domain.OrgRoleOwner {
				foundOwnerRole = true
			}
		}
		if !foundOwnerRole {
			t.Errorf("kullanıcı listesi owner'ın organization_role_code alanını 'owner' olarak göstermedi: %+v", users)
		}
	})

	t.Run("19_me_response_carries_permissions_and_role_not_for_super_admin", func(t *testing.T) {
		_, body := rbacDo(t, d.router, http.MethodGet, "/api/v1/auth/me", ownerToken, "")
		if body["organization_role_code"] != domain.OrgRoleOwner {
			t.Errorf("/auth/me organization_role_code = %v, want owner", body["organization_role_code"])
		}
		perms, _ := body["permissions"].([]any)
		if len(perms) == 0 {
			t.Errorf("/auth/me owner için boş izin listesi döndü")
		}

		superToken, err := d.issuer.IssueAccessToken("00000000-0000-0000-0000-0000000000ff", domain.RoleSuperAdmin, "")
		if err != nil {
			t.Fatalf("super admin token üretilemedi: %v", err)
		}
		_, superBody := rbacDo(t, d.router, http.MethodGet, "/api/v1/auth/me", superToken, "")
		if superBody["organization_role_code"] != nil && superBody["organization_role_code"] != "" {
			t.Errorf("super_admin'in organization_role_code'u BOŞ olmalı, geldi: %v", superBody["organization_role_code"])
		}
	})
}
