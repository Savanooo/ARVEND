// Package httpapi, HTTP router'ı kurar.
package httpapi

import (
	"net/http"

	"github.com/go-chi/chi/v5"
	chimw "github.com/go-chi/chi/v5/middleware"
	"github.com/go-chi/cors"

	"github.com/Savanooo/ARVEND/backend/internal/auth"
	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/httpapi/handler"
	appmw "github.com/Savanooo/ARVEND/backend/internal/httpapi/middleware"
	"github.com/Savanooo/ARVEND/backend/internal/platform/httpjson"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

type Deps struct {
	JWT               *auth.JWTIssuer
	Queries           *sqlc.Queries
	Auth              *handler.AuthHandler
	Users             *handler.UserHandler
	Products          *handler.ProductHandler
	PriceSources      *handler.PriceSourceHandler
	Offers            *handler.OfferHandler
	Projects          *handler.ProjectHandler
	Customers         *handler.CustomerHandler
	Employees         *handler.EmployeeHandler
	Attendance        *handler.AttendanceHandler
	Payroll           *handler.SalaryPaymentHandler
	Settings          *handler.SettingsHandler
	PublicOffer       *handler.PublicOfferHandler
	PublicChangeOrder *handler.PublicChangeOrderHandler
	Calc              *handler.CalcHandler
	Platform          *handler.PlatformHandler
	Onboarding        *handler.OnboardingHandler
	Authorization     *handler.AuthorizationHandler
	AuthorizationSvc  *service.AuthorizationService
	CostCodes         *handler.CostCodeHandler
	Suppliers         *handler.SupplierHandler
	Notifications     *handler.NotificationHandler
	Push              *handler.PushHandler
	Feedback          *handler.FeedbackHandler
	Dashboard         *handler.DashboardHandler
	AppReleases       *handler.AppReleaseHandler
	CORSOrigins       []string
}

func NewRouter(d Deps) http.Handler {
	r := chi.NewRouter()
	r.Use(chimw.RequestID)
	r.Use(chimw.RealIP)
	r.Use(chimw.Logger)
	r.Use(chimw.Recoverer)
	r.Use(cors.Handler(cors.Options{
		AllowedOrigins:   d.CORSOrigins,
		AllowedMethods:   []string{"GET", "POST", "PUT", "PATCH", "DELETE"},
		AllowedHeaders:   []string{"Content-Type"},
		AllowCredentials: true, // httpOnly cookie'lerin cross-origin (frontend :3000 -> backend :8080) taşınabilmesi için
	}))

	requireAuth := appmw.RequireAuth(d.JWT, d.Queries)
	// Tenant (firma kapsamlı) HER rota grubunda requireAuth'un hemen
	// ardından gelir: super_admin'in (organization_id NULL) ve org
	// bağlamı boş her oturumun tenant uçlarına HİÇ girmemesini garanti
	// eder -- bir organizasyon çıkarsanmaz/uydurulmaz. /auth/me ve
	// /platform/* BİLİNÇLİ OLARAK almaz (bkz. require_tenant.go).
	requireTenant := appmw.RequireTenant()
	requireAdmin := appmw.RequireRole(domain.RoleAdmin)
	requireSuperAdmin := appmw.RequireRole(domain.RoleSuperAdmin)
	// "Business" uçlarına (offers/projects/customers/products/calculations/
	// employees/attendance/settings/kullanıcı yönetimi) eklenir -- auth/me,
	// logout, refresh, set-initial-password, onboarding/*, organization/
	// settings/* ve platform/* BİLİNÇLİ OLARAK almaz (bkz. require_onboarded.go).
	requireOnboarded := appmw.RequireOnboarded(d.Queries)
	// requireOnboarded'ın "kullanıcı hâlâ aktif mi + güncel rolü" kontrolü,
	// requireOnboarded ALMAYAN tenant rotaları için tek başına. requireAdmin
	// ondan SONRA gelmeli -- rolü token'dan değil veritabanından okusun.
	requireActiveUser := appmw.RequireActiveUser(d.Queries)
	// RBAC/Project Membership sprint'i: loadAuthorization, requireOnboarded'dan
	// SONRA -- ve HER permission/projectPermission kontrolünden ÖNCE --
	// zincirlenmeli. Rol/izin bilgisini istek başına BİR KEZ yükler; perm/
	// projPerm çağrıları onu okur, tekrar sorgu atmaz (bkz.
	// middleware/require_permission.go).
	loadAuthorization := appmw.LoadAuthorization(d.AuthorizationSvc)
	perm := func(code string) func(http.Handler) http.Handler { return appmw.RequirePermission(code) }
	projPerm := func(code string) func(http.Handler) http.Handler {
		return appmw.RequireProjectPermission(d.AuthorizationSvc, code)
	}

	// Kimlik doğrulamasız, bağımlılık kontrolü yapmayan liveness ucu
	// (systemd/gateway sağlık kontrolü). /api/v1 dışında olduğu için
	// gateway'in /api/* kuralından geçmez; yalnızca loopback'ten erişilir.
	r.Get("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		httpjson.Write(w, http.StatusOK, map[string]string{"status": "ok"})
	})

	r.Route("/api/v1", func(r chi.Router) {
		r.Route("/auth", func(r chi.Router) {
			r.Post("/login", d.Auth.Login)
			r.Post("/refresh", d.Auth.Refresh)
			r.Post("/logout", d.Auth.Logout)
			r.With(requireAuth).Get("/me", d.Auth.Me)
		})

		// Uzaktan güncelleme (Store öncesi Android) -- bkz.
		// service/app_release_service.go. Sürüm sorgusu BİLİNÇLİ OLARAK
		// public: giriş ekranından da sorulur ve yalnızca build/sürüm/özet
		// döner. APK'nın kendisi yalnızca oturum açmış bir firma
		// kullanıcısına iner (ek izin yok; requireOnboarded da yok --
		// güncelleme hiçbir firma verisine dokunmaz).
		r.Route("/mobile", func(r chi.Router) {
			r.Get("/app-version", d.AppReleases.Version)
			r.With(requireAuth, requireTenant).Get("/app-download", d.AppReleases.Download)
		})

		r.Route("/users", func(r chi.Router) {
			r.Use(requireAuth, requireTenant)
			// "Şifre belirle" (must_change_password) akışı -- Super Admin'in
			// provision ettiği bir Owner'ın ilk girişte YENİ bir şifre
			// belirlemesi. requireAdmin VE requireOnboarded YOK -- bu
			// kullanıcının onboarding gate'inden ÇIKMASINI sağlayan tek uç,
			// gate'in kendisi burayı kilitleyemez.
			r.With(requireActiveUser).Post("/me/set-initial-password", d.Users.SetInitialPassword)

			r.Group(func(r chi.Router) {
				r.Use(requireOnboarded)
				r.Patch("/me/password", d.Users.ChangeOwnPassword)

				r.Group(func(r chi.Router) {
					// requireAdmin KORUNUR (super_admin'in tenant kullanıcı
					// yönetimine bulaşmaması ve legacy davranışla tutarlılık
					// için ek bir kapı) -- YENİ katman loadAuthorization +
					// organization.users.* izni ÜSTÜNE eklenir, requireAdmin'in
					// YERİNE geçmez.
					r.Use(requireAdmin, loadAuthorization)
					r.With(perm(domain.PermOrganizationUsersRead)).Get("/", d.Users.List)
					r.With(perm(domain.PermOrganizationUsersManage)).Post("/", d.Users.Create)
					r.With(perm(domain.PermOrganizationUsersRead)).Get("/{id}", d.Users.Get)
					r.With(perm(domain.PermOrganizationUsersManage)).Put("/{id}", d.Users.Update)
					r.With(perm(domain.PermOrganizationUsersManage)).Patch("/{id}/password", d.Users.AdminResetPassword)
					r.With(perm(domain.PermOrganizationUsersManage)).Delete("/{id}", d.Users.Deactivate)
					r.With(perm(domain.PermOrganizationRolesManage)).Put("/{id}/organization-role", d.Users.SetOrganizationRole)
					// Kişiye özel yetkiler: rolün izin kümesi başlangıç, üstüne
					// o kişiye özel ekleme/çıkarma -- Roller & Yetkiler ile AYNI
					// izinler (organization.roles.read/manage).
					r.With(perm(domain.PermOrganizationRolesRead)).Get("/{id}/permissions", d.Authorization.GetUserPermissions)
					r.With(perm(domain.PermOrganizationRolesManage)).Put("/{id}/permissions", d.Authorization.SetUserPermissions)
					r.With(perm(domain.PermOrganizationUsersRead)).Get("/{id}/projects", d.Authorization.ListUserProjects)
				})
			})
		})

		r.Route("/products", func(r chi.Router) {
			r.Use(requireAuth, requireTenant, requireOnboarded, loadAuthorization)
			// Katalog herkes icin okunabilir (teklif olustururken herkes
			// urun secebilmeli); yazma products.manage iznine ozel.
			r.With(perm(domain.PermProductsRead)).Get("/", d.Products.List)
			// Tedarikçi fiyat listesi (Ulaş, Demir Profil) ayarları/senkronu
			// ve zam geçmişi. chi'de statik segment parametreden önce eşleşir
			// -- "/price-sources", "/price-changes" ve "/price-changes/summary"
			// ASLA "/{id}" (ya da "/{id}/price-history") tarafından yakalanmaz;
			// yine de okunurluk için "/{id}"den ÖNCE kaydedilir. Okuma
			// products.read (kâr oranları ve tedarikçi fiyatları yalnızca
			// products.manage'e döner, bkz. PriceSourceHandler), ayar
			// değiştirme/senkron products.manage.
			r.With(perm(domain.PermProductsRead)).Get("/price-sources", d.PriceSources.List)
			r.With(perm(domain.PermProductsRead)).Get("/price-changes", d.PriceSources.ListPriceChanges)
			r.With(perm(domain.PermProductsRead)).Get("/price-changes/summary", d.PriceSources.PriceChangeSummary)
			r.With(perm(domain.PermProductsRead)).Get("/{id}", d.Products.Get)
			r.With(perm(domain.PermProductsRead)).Get("/{id}/price-history", d.Products.PriceHistory)

			r.Group(func(r chi.Router) {
				r.Use(perm(domain.PermProductsManage))
				r.Post("/", d.Products.Create)
				r.Put("/{id}", d.Products.Update)
				r.Delete("/{id}", d.Products.Delete)
				r.Put("/price-sources/{source}", d.PriceSources.Update)
				r.Post("/price-sources/{source}/sync", d.PriceSources.Sync)
			})
		})

		r.Route("/calculations", func(r chi.Router) {
			r.Use(requireAuth, requireTenant, requireOnboarded, loadAuthorization)
			// Metraj Hesapla paneli teklif oluştururken herkese lazım
			// (Products ile aynı ilke: katalog/reçete okuma serbest,
			// reçete katsayılarını düzenlemek calculations.manage iznine özel).
			r.Group(func(r chi.Router) {
				r.Use(perm(domain.PermCalculationsRead))
				r.Get("/groups", d.Calc.ListGroups)
				r.Get("/categories", d.Calc.ListCategories)
				r.Post("/run", d.Calc.Run)
				r.Get("/recipe-items", d.Calc.ListRecipeItems)
			})

			r.Group(func(r chi.Router) {
				r.Use(perm(domain.PermCalculationsManage))
				r.Post("/groups", d.Calc.CreateGroup)
				r.Put("/groups/{id}", d.Calc.UpdateGroup)
				r.Post("/categories", d.Calc.CreateCategory)
				r.Put("/categories/{id}", d.Calc.UpdateCategory)
				r.Post("/recipe-items", d.Calc.CreateRecipeItem)
				r.Put("/recipe-items/{id}", d.Calc.UpdateRecipeItem)
				r.Delete("/recipe-items/{id}", d.Calc.DeleteRecipeItem)
			})
		})

		r.Route("/offers", func(r chi.Router) {
			r.Use(requireAuth, requireTenant, requireOnboarded, loadAuthorization)
			// Teklif oluşturma/görme gerçek işte sıradan personel işidir --
			// Users/Products'ın aksine tek bir admin şartı YOK, offers.*
			// izinleri org-wide (proje-üyeliği ekseni yok, bkz. spec §2).
			r.Group(func(r chi.Router) {
				r.Use(perm(domain.PermOffersRead))
				r.Get("/", d.Offers.List)
				r.Get("/{id}", d.Offers.Get)
				r.Get("/{id}/revisions", d.Offers.ListRevisions)
				r.Get("/{id}/revisions/{revisionId}", d.Offers.GetRevision)
				r.Get("/{id}/share-links", d.Offers.ListShareLinks)
				r.Get("/{id}/events", d.Offers.ListEvents)
				r.Get("/{id}/email-logs", d.Offers.ListEmailLogs)
				// Teklifin projeye dönüşüp dönüşmediği (dönüşmediyse 404) --
				// teklif detayındaki "Projeye Dönüştür"/"Projeyi Görüntüle"
				// ayrımı buna bakar.
				r.Get("/{id}/project", d.Projects.GetByOffer)
			})
			r.With(perm(domain.PermOffersCreate)).Post("/", d.Offers.Create)
			r.Group(func(r chi.Router) {
				r.Use(perm(domain.PermOffersUpdate))
				r.Put("/{id}", d.Offers.Update)
				r.Post("/{id}/revise", d.Offers.Revise)
				r.Post("/{id}/send-email", d.Offers.SendEmail)
				r.Post("/{id}/share-links", d.Offers.CreateShareLink)
				r.Delete("/{id}/share-links/{linkId}", d.Offers.RevokeShareLink)
			})
			r.Group(func(r chi.Router) {
				r.Use(perm(domain.PermOffersApprove))
				r.Put("/{id}/status", d.Offers.UpdateStatus)
				r.Post("/{id}/toggle-passive", d.Offers.TogglePassive)
			})
			r.With(perm(domain.PermOffersDelete)).Delete("/{id}", d.Offers.Delete)
		})

		r.Route("/projects", func(r chi.Router) {
			r.Use(requireAuth, requireTenant, requireOnboarded, loadAuthorization)
			// GET / ve POST /from-offer henüz TEK bir projeye bağlı DEĞİL --
			// listede üyelik filtresi ProjectService.List İÇİNDE
			// (restrict_to_user_id, SQL seviyesinde) uygulanır; oluşturma
			// org-wide bir izindir (proje henüz yok). Bunların ALTINDAKİ
			// TÜM /{id}/... rotaları projPerm (izin + proje üyeliği) kullanır.
			r.With(perm(domain.PermProjectsRead)).Get("/", d.Projects.List)
			r.With(perm(domain.PermProjectsCreate)).Post("/from-offer/{offerId}", d.Projects.CreateFromOffer)

			r.Group(func(r chi.Router) {
				r.Use(projPerm(domain.PermProjectsRead))
				r.Get("/{id}", d.Projects.Get)
				r.Get("/{id}/events", d.Projects.ListEvents)
			})
			r.With(projPerm(domain.PermProjectsUpdate)).Put("/{id}", d.Projects.Update)

			r.Group(func(r chi.Router) {
				r.Use(projPerm(domain.PermProjectsFinanceRead))
				r.Get("/{id}/financial-summary", d.Projects.FinancialSummary)
				r.Get("/{id}/payment-plan", d.Projects.ListPaymentPlan)
				r.Get("/{id}/collections", d.Projects.ListCollections)
				r.Get("/{id}/expenses", d.Projects.ListExpenses)
				r.Get("/{id}/invoices", d.Projects.ListInvoices)
				r.Get("/{id}/subcontractors", d.Projects.ListSubcontractors)
				r.Get("/{id}/subcontractor-payments", d.Projects.ListSubcontractorPayments)
				r.Get("/{id}/change-orders", d.Projects.ListChangeOrders)
				r.Get("/{id}/change-orders/{changeOrderId}", d.Projects.GetChangeOrder)
			})
			r.Group(func(r chi.Router) {
				r.Use(projPerm(domain.PermProjectsFinanceManage))
				r.Post("/{id}/payment-plan", d.Projects.CreatePaymentPlanItem)
				r.Put("/{id}/payment-plan/{itemId}", d.Projects.UpdatePaymentPlanItem)
				r.Delete("/{id}/payment-plan/{itemId}", d.Projects.CancelPaymentPlanItem)
				r.Post("/{id}/collections", d.Projects.CreateCollection)
				r.Post("/{id}/collections/{collectionId}/void", d.Projects.VoidCollection)
				r.Post("/{id}/expenses", d.Projects.CreateExpense)
				r.Put("/{id}/expenses/{expenseId}", d.Projects.UpdateExpense)
				r.Post("/{id}/expenses/{expenseId}/void", d.Projects.VoidExpense)
				r.Post("/{id}/invoices", d.Projects.CreateInvoice)
				r.Put("/{id}/invoices/{invoiceId}/status", d.Projects.UpdateInvoiceStatus)
				r.Post("/{id}/subcontractors", d.Projects.CreateSubcontractor)
				r.Put("/{id}/subcontractors/{subcontractorId}", d.Projects.UpdateSubcontractor)
				r.Post("/{id}/subcontractors/{subcontractorId}/payments", d.Projects.CreateSubcontractorPayment)
				r.Post("/{id}/subcontractor-payments/{paymentId}/void", d.Projects.VoidSubcontractorPayment)
				r.Post("/{id}/change-orders", d.Projects.CreateChangeOrder)
				r.Put("/{id}/change-orders/{changeOrderId}", d.Projects.UpdateChangeOrder)
				r.Post("/{id}/change-orders/{changeOrderId}/send", d.Projects.SendChangeOrder)
				r.Post("/{id}/change-orders/{changeOrderId}/send-email", d.Projects.SendChangeOrderEmail)
				r.Post("/{id}/change-orders/{changeOrderId}/revise", d.Projects.ReviseChangeOrder)
				r.Post("/{id}/change-orders/{changeOrderId}/cancel", d.Projects.CancelChangeOrder)
			})

			// --- Sprint 2: WBS + Proje Bütçesi (planlama katmanı) ---
			// budget.read/manage, WBS+bütçe+kalem+revizyon YAPISINI kapsar;
			// cost_control.read/manage (aşağıda) ise bu yapı ÜZERİNE kurulan
			// izleme/takip katmanını (taahhüt/tahmin/özet) kapsar --
			// migration 0035'te HER rol bu ikisini birlikte aldığı için
			// bugün pratik bir erişim farkı YOK, ama gelecekte (Roller &
			// Yetkiler ekranından) bağımsız özelleştirilebilir olması için
			// baştan AYRI izin kodlarıyla kurulur.
			r.Group(func(r chi.Router) {
				r.Use(projPerm(domain.PermProjectsBudgetRead))
				r.Get("/{id}/wbs", d.Projects.ListWBSNodes)
				r.Get("/{id}/budget", d.Projects.GetProjectBudget)
				r.Get("/{id}/budget/lines", d.Projects.ListBudgetLines)
				r.Get("/{id}/budget/adjustments", d.Projects.ListBudgetAdjustments)
			})
			r.Group(func(r chi.Router) {
				r.Use(projPerm(domain.PermProjectsBudgetManage))
				r.Post("/{id}/wbs", d.Projects.CreateWBSNode)
				r.Put("/{id}/wbs/{nodeId}", d.Projects.UpdateWBSNode)
				r.Delete("/{id}/wbs/{nodeId}", d.Projects.ArchiveWBSNode)
				r.Post("/{id}/budget", d.Projects.CreateProjectBudget)
				r.Post("/{id}/budget/baseline", d.Projects.BaselineProjectBudget)
				r.Post("/{id}/budget/lines", d.Projects.CreateBudgetLine)
				r.Put("/{id}/budget/lines/{lineId}", d.Projects.UpdateBudgetLine)
				r.Delete("/{id}/budget/lines/{lineId}", d.Projects.DeleteBudgetLine)
				r.Post("/{id}/budget/adjustments", d.Projects.CreateBudgetAdjustment)
				r.Post("/{id}/budget/adjustments/{adjustmentId}/approve", d.Projects.ApproveBudgetAdjustment)
				r.Post("/{id}/budget/adjustments/{adjustmentId}/reject", d.Projects.RejectBudgetAdjustment)
			})

			// --- Sprint 2: Maliyet Kontrolü (izleme katmanı: taahhüt/tahmin/
			// özet) -- bu sprintte YALNIZCA manuel taahhüt (procurement/
			// subcontract modülleri Sprint 3+ kapsamındadır).
			r.Group(func(r chi.Router) {
				r.Use(projPerm(domain.PermProjectsCostControlRead))
				r.Get("/{id}/commitments", d.Projects.ListCommitments)
				r.Get("/{id}/forecasts", d.Projects.ListForecasts)
				r.Get("/{id}/cost-control", d.Projects.CostControl)
			})
			r.Group(func(r chi.Router) {
				r.Use(projPerm(domain.PermProjectsCostControlManage))
				r.Post("/{id}/commitments", d.Projects.CreateCommitment)
				r.Post("/{id}/commitments/{commitmentId}/void", d.Projects.VoidCommitment)
				r.Put("/{id}/budget/lines/{lineId}/forecast", d.Projects.UpsertForecast)
			})

			// --- Sprint 3: Sözleşme (Contract) -- gelir (revenue) tarafı,
			// Bütçe/Bütçe Revizyonu (maliyet tarafı, yukarıda) İLE
			// KARIŞTIRILMAMALI. ÜÇ ayrı izin: read/manage/lifecycle --
			// Project Manager manage alır (taslak düzenleyebilir) ama
			// lifecycle ALMAZ (Activate/Cancel/Complete/Terminate yapamaz,
			// bkz. migration 0036 rol matrisi gerekçesi).
			r.Group(func(r chi.Router) {
				r.Use(projPerm(domain.PermProjectsContractsRead))
				r.Get("/{id}/contract", d.Projects.GetProjectContract)
			})
			r.Group(func(r chi.Router) {
				r.Use(projPerm(domain.PermProjectsContractsManage))
				r.Post("/{id}/contract", d.Projects.CreateProjectContract)
				r.Put("/{id}/contract", d.Projects.UpdateProjectContractDraft)
				r.Put("/{id}/contract/notes", d.Projects.UpdateProjectContractNotes)
			})
			r.Group(func(r chi.Router) {
				r.Use(projPerm(domain.PermProjectsContractsLifecycle))
				r.Post("/{id}/contract/activate", d.Projects.ActivateProjectContract)
				r.Post("/{id}/contract/cancel", d.Projects.CancelProjectContract)
				r.Post("/{id}/contract/complete", d.Projects.CompleteProjectContract)
				r.Post("/{id}/contract/terminate", d.Projects.TerminateProjectContract)
			})

			// --- Sprint 4: Procurement Foundation -- Purchase Request + RFQ +
			// Supplier Quotation + Purchase Order. Cost Control'ün MALİYET
			// tarafına akar (PO onayında commitment oluşur, yukarıdaki Sprint
			// 2 grubuyla AYNI project_commitments tablosu) ama Contract/Change
			// Order (gelir tarafı, yukarıda) İLE KARIŞTIRILMAMALI. ÜÇ ayrı
			// izin: read/manage/approve -- "approve", Contract'ın lifecycle
			// izniyle AYNI ilkeyi izler (sensitive karar anları: PR onay/red,
			// RFQ award, PO onay/iptal/kapatma) ama manage'den BİLİNÇLİ OLARAK
			// AYRIDIR (PM manage alır -- taslak oluşturabilir/gönderebilir --
			// ama approve ALMAZ, bkz. migration 0037 rol matrisi gerekçesi).
			r.Group(func(r chi.Router) {
				r.Use(projPerm(domain.PermProjectsProcurementRead))
				r.Get("/{id}/purchase-requests", d.Projects.ListPurchaseRequests)
				r.Get("/{id}/purchase-requests/{prId}", d.Projects.GetPurchaseRequest)
				r.Get("/{id}/rfqs", d.Projects.ListRFQs)
				r.Get("/{id}/rfqs/{rfqId}", d.Projects.GetRFQ)
				r.Get("/{id}/rfqs/{rfqId}/quotations", d.Projects.ListQuotations)
				r.Get("/{id}/rfqs/{rfqId}/quotations/{quotationId}", d.Projects.GetQuotation)
				r.Get("/{id}/rfqs/{rfqId}/comparison", d.Projects.GetBidComparison)
				r.Get("/{id}/purchase-orders", d.Projects.ListPurchaseOrders)
				r.Get("/{id}/purchase-orders/{poId}", d.Projects.GetPurchaseOrder)
			})
			r.Group(func(r chi.Router) {
				r.Use(projPerm(domain.PermProjectsProcurementManage))
				r.Post("/{id}/purchase-requests", d.Projects.CreatePurchaseRequest)
				r.Put("/{id}/purchase-requests/{prId}", d.Projects.UpdatePurchaseRequest)
				r.Post("/{id}/purchase-requests/{prId}/submit", d.Projects.SubmitPurchaseRequest)
				r.Post("/{id}/purchase-requests/{prId}/withdraw", d.Projects.WithdrawPurchaseRequest)
				r.Post("/{id}/purchase-requests/{prId}/cancel", d.Projects.CancelPurchaseRequest)
				r.Post("/{id}/rfqs", d.Projects.CreateRFQ)
				r.Put("/{id}/rfqs/{rfqId}", d.Projects.UpdateRFQ)
				r.Post("/{id}/rfqs/{rfqId}/issue", d.Projects.IssueRFQ)
				r.Post("/{id}/rfqs/{rfqId}/close", d.Projects.CloseRFQ)
				r.Post("/{id}/rfqs/{rfqId}/cancel", d.Projects.CancelRFQ)
				r.Post("/{id}/rfqs/{rfqId}/quotations", d.Projects.CreateQuotation)
				r.Put("/{id}/rfqs/{rfqId}/quotations/{quotationId}", d.Projects.UpdateQuotation)
				r.Delete("/{id}/rfqs/{rfqId}/quotations/{quotationId}", d.Projects.DeleteQuotation)
				r.Post("/{id}/purchase-orders", d.Projects.CreatePurchaseOrder)
				r.Put("/{id}/purchase-orders/{poId}", d.Projects.UpdatePurchaseOrder)
			})
			r.Group(func(r chi.Router) {
				r.Use(projPerm(domain.PermProjectsProcurementApprove))
				r.Post("/{id}/purchase-requests/{prId}/approve", d.Projects.ApprovePurchaseRequest)
				r.Post("/{id}/purchase-requests/{prId}/reject", d.Projects.RejectPurchaseRequest)
				r.Post("/{id}/rfqs/{rfqId}/award", d.Projects.AwardRFQ)
				r.Post("/{id}/purchase-orders/{poId}/approve", d.Projects.ApprovePurchaseOrder)
				r.Post("/{id}/purchase-orders/{poId}/cancel", d.Projects.CancelPurchaseOrder)
				r.Post("/{id}/purchase-orders/{poId}/close", d.Projects.ClosePurchaseOrder)
			})

			// --- Sprint 5: Taşeron Yönetimi -- Subcontract + SOV + Subcontract
			// Change Order + Progress Claim (Hakediş). Cost Control'ün MALİYET
			// tarafına akar (aktivasyon/değişiklik-onayı/fesih commitment
			// senkronize eder, YUKARIDAKİ Sprint 2 grubuyla AYNI
			// project_commitments tablosu) ama Customer Contract/Change Order
			// (gelir tarafı) İLE ve mevcut legacy /subcontractors uçlarıyla
			// (aşağıda, Faz 8'den kalma basit taşeron+ödeme defteri) KESİNLİKLE
			// KARIŞTIRILMAMALI -- bu sprint o legacy sisteme DOKUNMAZ, AYRI ve
			// paralel bir zincir kurar (bkz. docs/subcontracts.md). İKİ ayrı
			// üçlü izin (subcontracts.*, subcontract_claims.*) -- Procurement'ın
			// read/manage/approve deseniyle AYNI ilke, hakediş sertifikasyonu
			// sözleşme onayından ayrı bir karar anı olabileceği için ayrı
			// izinlerle modellendi (spec §28).
			r.Group(func(r chi.Router) {
				r.Use(projPerm(domain.PermProjectsSubcontractsRead))
				r.Get("/{id}/subcontracts", d.Projects.ListSubcontracts)
				r.Get("/{id}/subcontracts/{subcontractId}", d.Projects.GetSubcontract)
				r.Get("/{id}/subcontracts/{subcontractId}/change-orders", d.Projects.ListSubcontractChangeOrders)
				r.Get("/{id}/subcontract-change-orders/{changeOrderId}", d.Projects.GetSubcontractChangeOrder)
			})
			r.Group(func(r chi.Router) {
				r.Use(projPerm(domain.PermProjectsSubcontractsManage))
				r.Post("/{id}/subcontracts", d.Projects.CreateSubcontract)
				r.Put("/{id}/subcontracts/{subcontractId}", d.Projects.UpdateSubcontract)
				r.Post("/{id}/subcontracts/{subcontractId}/change-orders", d.Projects.CreateSubcontractChangeOrder)
				r.Put("/{id}/subcontract-change-orders/{changeOrderId}", d.Projects.UpdateSubcontractChangeOrder)
				r.Post("/{id}/subcontract-change-orders/{changeOrderId}/submit", d.Projects.SubmitSubcontractChangeOrder)
				r.Post("/{id}/subcontract-change-orders/{changeOrderId}/cancel", d.Projects.CancelSubcontractChangeOrder)
			})
			r.Group(func(r chi.Router) {
				r.Use(projPerm(domain.PermProjectsSubcontractsApprove))
				r.Post("/{id}/subcontracts/{subcontractId}/activate", d.Projects.ActivateSubcontract)
				r.Post("/{id}/subcontracts/{subcontractId}/complete", d.Projects.CompleteSubcontract)
				r.Post("/{id}/subcontracts/{subcontractId}/cancel", d.Projects.CancelSubcontract)
				r.Post("/{id}/subcontracts/{subcontractId}/terminate", d.Projects.TerminateSubcontract)
				r.Post("/{id}/subcontract-change-orders/{changeOrderId}/approve", d.Projects.ApproveSubcontractChangeOrder)
				r.Post("/{id}/subcontract-change-orders/{changeOrderId}/reject", d.Projects.RejectSubcontractChangeOrder)
			})
			r.Group(func(r chi.Router) {
				r.Use(projPerm(domain.PermProjectsSubcontractClaimsRead))
				r.Get("/{id}/subcontracts/{subcontractId}/progress-claims", d.Projects.ListSubcontractProgressClaims)
				r.Get("/{id}/subcontract-progress-claims/{claimId}", d.Projects.GetSubcontractProgressClaim)
			})
			r.Group(func(r chi.Router) {
				r.Use(projPerm(domain.PermProjectsSubcontractClaimsManage))
				r.Post("/{id}/subcontracts/{subcontractId}/progress-claims", d.Projects.CreateSubcontractProgressClaim)
				r.Put("/{id}/subcontract-progress-claims/{claimId}", d.Projects.UpdateSubcontractProgressClaim)
				r.Post("/{id}/subcontract-progress-claims/{claimId}/submit", d.Projects.SubmitSubcontractProgressClaim)
				r.Post("/{id}/subcontract-progress-claims/{claimId}/cancel", d.Projects.CancelSubcontractProgressClaim)
			})
			r.Group(func(r chi.Router) {
				r.Use(projPerm(domain.PermProjectsSubcontractClaimsCertify))
				r.Post("/{id}/subcontract-progress-claims/{claimId}/certify", d.Projects.CertifySubcontractProgressClaim)
				r.Post("/{id}/subcontract-progress-claims/{claimId}/reject", d.Projects.RejectSubcontractProgressClaim)
			})

			// Sprint 5 follow-up — Taşeron Ödemeleri (migration 0039).
			// Sertifikasyon (subcontract_claims.certify, YUKARIDA) ödeme
			// DEĞİLDİR -- bu GERÇEK nakit çıkışı AYRI bir izin çiftiyle
			// (read/manage, subcontracts.approve/subcontract_claims.certify
			// İLE AYNI "hassas karar anı" güven sınıfında ama onay durumu
			// olmadığı için ikili) korunur.
			r.Group(func(r chi.Router) {
				r.Use(projPerm(domain.PermProjectsSubcontractPaymentsRead))
				r.Get("/{id}/subcontracts/{subcontractId}/payments", d.Projects.ListSubcontractPayments)
			})
			r.Group(func(r chi.Router) {
				r.Use(projPerm(domain.PermProjectsSubcontractPaymentsManage))
				r.Post("/{id}/subcontracts/{subcontractId}/payments", d.Projects.CreateSubcontractPayment)
				r.Post("/{id}/subcontract-payments/{paymentId}/void", d.Projects.VoidSubcontractPayment)
			})

			// --- Faz 7: operasyon (ekip/planlama/dosya/fotoğraf/not) ---
			r.Group(func(r chi.Router) {
				r.Use(projPerm(domain.PermProjectsOperationsRead))
				r.Get("/{id}/operations-summary", d.Projects.OperationsSummary)
				r.Get("/{id}/members", d.Projects.ListMembers)
				r.Get("/{id}/schedule", d.Projects.ListScheduleItems)
				r.Get("/{id}/files", d.Projects.ListFiles)
				r.Get("/{id}/files/{fileId}/download", d.Projects.DownloadFile)
				r.Get("/{id}/photos", d.Projects.ListPhotos)
				r.Get("/{id}/photos/{photoId}/content", d.Projects.DownloadPhoto)
				r.Get("/{id}/notes", d.Projects.ListNotes)
			})
			r.Group(func(r chi.Router) {
				r.Use(projPerm(domain.PermProjectsOperationsManage))
				r.Post("/{id}/members", d.Projects.AssignMember)
				r.Delete("/{id}/members/{memberId}", d.Projects.EndMembership)
				r.Post("/{id}/schedule", d.Projects.CreateScheduleItem)
				r.Put("/{id}/schedule/{itemId}", d.Projects.UpdateScheduleItem)
				r.Post("/{id}/files", d.Projects.UploadFile)
				r.Delete("/{id}/files/{fileId}", d.Projects.DeleteFile)
				r.Post("/{id}/photos", d.Projects.UploadPhoto)
				r.Delete("/{id}/photos/{photoId}", d.Projects.DeletePhoto)
				r.Post("/{id}/notes", d.Projects.CreateNote)
			})

			// Görev/plan formlarının "kime" seçicisi: ücretsiz personel
			// listesi (proje yöneticisinde employees.read yok).
			r.With(projPerm(domain.PermProjectsRead)).Get("/{id}/assignees", d.Projects.ListAssignees)

			// --- Görevler ---
			r.With(projPerm(domain.PermProjectsTasksRead)).Get("/{id}/tasks", d.Projects.ListTasks)
			// Görev notları (migration 0051): okumak görevi görebilen herkes,
			// yazmak görev güncelleme izni (Saha rolünde de var).
			r.With(projPerm(domain.PermProjectsTasksRead)).Get("/{id}/tasks/{taskId}/updates", d.Projects.ListTaskUpdates)
			r.With(projPerm(domain.PermProjectsTasksUpdate)).Post("/{id}/tasks/{taskId}/updates", d.Projects.CreateTaskUpdate)
			r.With(projPerm(domain.PermProjectsTasksCreate)).Post("/{id}/tasks", d.Projects.CreateTask)
			r.Group(func(r chi.Router) {
				r.Use(projPerm(domain.PermProjectsTasksUpdate))
				r.Put("/{id}/tasks/{taskId}", d.Projects.UpdateTask)
				r.Post("/{id}/tasks/{taskId}/complete", d.Projects.CompleteTask)
			})

			// --- Proje Erişimi (project_users -- RBAC/Project Membership
			// sprint'i; mevcut /{id}/members -- İK/puantaj ekip roster'ı --
			// İLE KARIŞTIRILMAMALI, bkz. migration 0034 başlık notu) ---
			r.With(projPerm(domain.PermProjectsAccessRead)).Get("/{id}/access", d.Authorization.ListProjectUsers)
			r.Group(func(r chi.Router) {
				r.Use(projPerm(domain.PermProjectsAccessManage))
				r.Post("/{id}/access", d.Authorization.AddProjectUser)
				r.Put("/{id}/access/{userId}", d.Authorization.UpdateProjectUserRole)
				r.Delete("/{id}/access/{userId}", d.Authorization.RemoveProjectUser)
			})
		})

		// Cross-project "benim gorevlerim" -- proje dongusu yerine tek sorgu.
		// Org-seviyesinde projects.tasks.read; proje uyelik filtresi handler icinde.
		r.With(requireAuth, requireTenant, requireOnboarded, loadAuthorization, perm(domain.PermProjectsTasksRead)).
			Get("/tasks/mine", d.Projects.ListMyTasks)
		r.With(requireAuth, requireTenant, requireOnboarded, loadAuthorization, perm(domain.PermProjectsTasksRead)).
			Get("/tasks/team", d.Projects.ListTeamTasks)

		// Ana sayfa özeti -- perm() YOK: her bölüm kendi iznini serviste
		// değerlendirir, yetkisiz bölüm yanıtta hiç görünmez (bkz.
		// service.DashboardService). super_admin requireTenant'ta 403
		// tenant_context_required alır. Proje seçici GET /projects'i
		// KULLANMAZ (o uç tutar döner) -- tutar alanı içermeyen, üyelik
		// kapsamlı ayrı bir uçtur.
		r.With(requireAuth, requireTenant, requireOnboarded, loadAuthorization).
			Get("/dashboard", d.Dashboard.Get)
		r.With(requireAuth, requireTenant, requireOnboarded, loadAuthorization, perm(domain.PermProjectsRead)).
			Get("/dashboard/project-options", d.Dashboard.ProjectOptions)

		// Bildirimler -- her zaman ÇAĞIRANIN KENDİ kaydı (user_id context'ten,
		// istekten ASLA), bu yüzden proje üyeliği ekseni YOK -- notifications.
		// read TÜM sistem rollerine verilir (bkz. migration 0042). Yazma
		// (oluşturma) ucu YOK -- bildirimler yalnızca backend'in kendi iş
		// akışları tarafından üretilir, bkz. NotificationService.Create
		// çağrı noktaları.
		r.Route("/notifications", func(r chi.Router) {
			r.Use(requireAuth, requireTenant, requireOnboarded, loadAuthorization, perm(domain.PermNotificationsRead))
			r.Get("/", d.Notifications.List)
			r.Get("/unread-count", d.Notifications.UnreadCount)
			r.Post("/{id}/read", d.Notifications.MarkRead)
			r.Post("/read-all", d.Notifications.MarkAllRead)
		})

		// Telefon kaydı (migration 0053): her kullanıcı yalnızca kendi
		// telefonunu kaydeder/siler -- izin yok, kullanıcı context'ten.
		r.Route("/push/devices", func(r chi.Router) {
			r.Use(requireAuth, requireTenant)
			// Pasifleştirilmiş biri, token'ı dolana kadar telefonunu yeniden
			// kaydedip bildirim almaya devam edemesin (pasifleştirme cihaz
			// kayıtlarını siler). Çıkıştaki kayıt silme serbest kalır.
			r.With(requireActiveUser).Post("/", d.Push.RegisterDevice)
			r.Post("/unregister", d.Push.UnregisterDevice)
		})

		// Öneri / görüş: her kullanıcı platform ekibine yazabilir (izin yok).
		r.With(requireAuth, requireTenant, requireActiveUser).Post("/feedback", d.Feedback.Submit)

		// Firma yöneticisinin kendi ekibine duyurusu.
		r.With(requireAuth, requireTenant, requireOnboarded, loadAuthorization, perm(domain.PermOrganizationUsersManage)).
			Post("/announcements", d.Push.SendOrganizationAnnouncement)

		r.Route("/customers", func(r chi.Router) {
			r.Use(requireAuth, requireTenant, requireOnboarded, loadAuthorization)
			// Teklif oluşturan herkes müşteri seçebilmeli/ekleyebilmeli --
			// Ürünler'in aksine (kontrollü katalog), müşteri kartı canlı bir
			// CRM listesi gibi, tek bir admin şartı YOK.
			r.Group(func(r chi.Router) {
				r.Use(perm(domain.PermCustomersRead))
				r.Get("/", d.Customers.List)
				r.Get("/{id}", d.Customers.Get)
			})
			r.Group(func(r chi.Router) {
				r.Use(perm(domain.PermCustomersManage))
				r.Post("/", d.Customers.Create)
				r.Put("/{id}", d.Customers.Update)
				r.Delete("/{id}", d.Customers.Archive)
			})
		})

		r.Route("/employees", func(r chi.Router) {
			r.Use(requireAuth, requireTenant, requireOnboarded, loadAuthorization)
			// Personel listesi mesai girişinde herkese lazım; hassas
			// yönetim (ekleme/düzenleme/pasifleştirme) employees.manage
			// iznine özel.
			r.Group(func(r chi.Router) {
				r.Use(perm(domain.PermEmployeesRead))
				r.Get("/", d.Employees.List)
				r.Get("/{id}", d.Employees.Get)
			})

			r.Group(func(r chi.Router) {
				r.Use(perm(domain.PermEmployeesManage))
				r.Post("/", d.Employees.Create)
				r.Put("/{id}", d.Employees.Update)
				r.Delete("/{id}", d.Employees.Archive)
			})
		})

		r.Route("/attendance", func(r chi.Router) {
			r.Use(requireAuth, requireTenant, requireOnboarded, loadAuthorization)
			// Mesai girişi BYZ'de sıradan iş -- tek bir admin şartı YOK.
			r.With(perm(domain.PermAttendanceRead)).Get("/", d.Attendance.ListByMonth)
			r.Group(func(r chi.Router) {
				r.Use(perm(domain.PermAttendanceManage))
				r.Post("/", d.Attendance.Create)
				r.Put("/{id}", d.Attendance.Update)
				r.Delete("/{id}", d.Attendance.Delete)
			})
		})

		r.Route("/payroll", func(r chi.Router) {
			r.Use(requireAuth, requireTenant, requireOnboarded, loadAuthorization)
			// Maaş/mesai ödemeleri attendance.*'tan AYRI izinde: puantaj
			// girebilen herkes personelin ne aldığını görmemeli (bkz.
			// domain.PermPayrollRead, migration 0048).
			r.With(perm(domain.PermPayrollRead)).Get("/", d.Payroll.List)
			r.With(perm(domain.PermPayrollRead)).Get("/{id}/statement", d.Payroll.Statement)
			r.Group(func(r chi.Router) {
				r.Use(perm(domain.PermPayrollManage))
				r.Post("/", d.Payroll.Create)
				r.Delete("/{id}", d.Payroll.Delete)
			})
		})

		r.Route("/settings", func(r chi.Router) {
			r.Use(requireAuth, requireTenant, requireOnboarded, requireAdmin, loadAuthorization)
			r.With(perm(domain.PermOrganizationSettingsRead)).Get("/smtp", d.Settings.GetSmtp)
			r.Group(func(r chi.Router) {
				r.Use(perm(domain.PermOrganizationSettingsManage))
				r.Put("/smtp", d.Settings.UpdateSmtp)
				r.Post("/smtp/test", d.Settings.TestSmtp)
			})
		})

		// Roller & Yetkiler ekranı -- RBAC/Project Membership sprint'i.
		// requireAdmin KORUNUR (Users grubuyla AYNI ilke: ek bir kapı,
		// organization.roles.* izninin YERİNE değil ÜSTÜNE).
		r.Route("/organization/roles", func(r chi.Router) {
			r.Use(requireAuth, requireTenant, requireOnboarded, requireAdmin, loadAuthorization)
			r.With(perm(domain.PermOrganizationRolesRead)).Get("/", d.Authorization.ListOrganizationRoles)
			r.With(perm(domain.PermOrganizationRolesRead)).Get("/{id}", d.Authorization.GetOrganizationRole)
			r.With(perm(domain.PermOrganizationRolesManage)).Put("/{id}/permissions", d.Authorization.SetRolePermissions)
		})

		// Maliyet Kodları (Sprint 2) -- organizasyon-seviyeli, PAYLAŞILAN
		// katalog. requireAdmin YOK (Roller/Kullanıcılar'ın AKSİNE): finance/
		// legacy_user/project_manager (izinleri dahilinde) doğrudan
		// erişebilmeli, admin-only bir kapı olmamalı -- yetki TAMAMEN
		// organization.cost_codes.* iznine bırakılır.
		r.Route("/organization/cost-codes", func(r chi.Router) {
			r.Use(requireAuth, requireTenant, requireOnboarded, loadAuthorization)
			r.With(perm(domain.PermOrganizationCostCodesRead)).Get("/", d.CostCodes.List)
			r.With(perm(domain.PermOrganizationCostCodesRead)).Get("/{id}", d.CostCodes.Get)
			r.Group(func(r chi.Router) {
				r.Use(perm(domain.PermOrganizationCostCodesManage))
				r.Post("/", d.CostCodes.Create)
				r.Put("/{id}", d.CostCodes.Update)
				r.Delete("/{id}", d.CostCodes.Archive)
				r.Post("/{id}/reactivate", d.CostCodes.Reactivate)
			})
		})

		// Tedarikçiler (Sprint 4) -- organizasyon-seviyeli, PAYLAŞILAN katalog.
		// Maliyet Kodları İLE AYNI desen: requireAdmin YOK, yetki TAMAMEN
		// organization.suppliers.* iznine bırakılır.
		r.Route("/organization/suppliers", func(r chi.Router) {
			r.Use(requireAuth, requireTenant, requireOnboarded, loadAuthorization)
			r.With(perm(domain.PermOrganizationSuppliersRead)).Get("/", d.Suppliers.List)
			r.With(perm(domain.PermOrganizationSuppliersRead)).Get("/{id}", d.Suppliers.Get)
			r.Group(func(r chi.Router) {
				r.Use(perm(domain.PermOrganizationSuppliersManage))
				r.Post("/", d.Suppliers.Create)
				r.Put("/{id}", d.Suppliers.Update)
				r.Delete("/{id}", d.Suppliers.Archive)
				r.Post("/{id}/reactivate", d.Suppliers.Reactivate)
			})
		})

		r.Route("/organization/permissions", func(r chi.Router) {
			r.Use(requireAuth, requireTenant, requireOnboarded, requireAdmin, loadAuthorization, perm(domain.PermOrganizationRolesRead))
			r.Get("/", d.Authorization.ListPermissions)
		})

		// Firma ayarları iki yoldan yazılır -- ilk-giriş sihirbazı ve sonradan
		// "Firma Ayarları" -- AYNI handler/servis metodlarıyla (bkz.
		// OnboardingHandler yorumu). İkisi de requireAdmin'in ÜSTÜNE
		// organization.settings.read/manage ister: yalnızca kaba admin rolüne
		// bakıldığında, "Firma ayarlarını düzenleme" izni geri alınmış bir
		// Yönetici ayarları değiştirmeye devam ediyordu (sihirbaz yolu da
		// onboarding bittikten sonra açık bir arka kapıydı). Sahip HER ZAMAN
		// tüm izinlere sahiptir (GetUserPermissions) -- yeni firmanın Sahibi
		// sihirbazı yine tamamlayabilir. requireOnboarded BİLİNÇLİ OLARAK
		// yok (sihirbaz onboarding'den önce çalışır); onun yerine
		// requireActiveUser pasif kullanıcıyı keser ve requireAdmin'e
		// güncel rolü verir.
		settingsRoutes := func(r chi.Router) {
			r.Use(requireAuth, requireTenant, requireActiveUser, requireAdmin, loadAuthorization)
			r.With(perm(domain.PermOrganizationSettingsRead)).Get("/", d.Onboarding.GetState)
			r.Group(func(r chi.Router) {
				r.Use(perm(domain.PermOrganizationSettingsManage))
				r.Put("/company", d.Onboarding.SaveCompany)
				r.Put("/billing", d.Onboarding.SaveBilling)
				r.Put("/offers", d.Onboarding.SaveOffers)
				r.Put("/finance", d.Onboarding.SaveFinance)
				r.Put("/business", d.Onboarding.SaveBusiness)
			})
		}
		// İlk-giriş onboarding sihirbazı (5 adım) -- server-authoritative,
		// web/mobil AYNI state'i okur/yazar. Onboarding'i tamamlayacak olan
		// Super Admin'in provision ettiği Owner'dır.
		r.Route("/onboarding", settingsRoutes)
		// Onboarding SONRASI "Firma Ayarları" düzenleme -- farklı path.
		r.Route("/organization/settings", settingsRoutes)

		// Super Admin platform yönetimi -- organizasyon izolasyonu YOK
		// (bilinçli), YALNIZCA requireSuperAdmin arkasında. Normal
		// organizasyon kullanıcıları (admin dahil) bu route'lara HİÇBİR
		// şekilde erişemez -- requireRole eşitlik kontrolü tek bir rolü
		// (super_admin) kabul eder, admin'i değil.
		r.Route("/platform", func(r chi.Router) {
			r.Use(requireAuth, requireSuperAdmin)
			r.Get("/plans", d.Platform.ListPlans)
			// Tüm (ya da seçili) firmaların kullanıcılarına duyuru.
			r.Post("/announcements", d.Push.SendPlatformAnnouncement)
			// Firmalardan gelen öneriler.
			r.Get("/feedback", d.Feedback.List)
			r.Post("/feedback/{id}/read", d.Feedback.MarkRead)
			r.Route("/organizations", func(r chi.Router) {
				r.Get("/", d.Platform.ListOrganizations)
				r.Post("/", d.Platform.CreateOrganization)
				r.Get("/{id}", d.Platform.GetOrganization)
				r.Patch("/{id}/status", d.Platform.UpdateOrganizationStatus)
				r.Patch("/{id}/plan", d.Platform.UpdateOrganizationPlan)
				r.Get("/{id}/users", d.Platform.ListOrganizationUsers)
				// Firma kullanıcı yönetimi -- organizasyon kimliği HER ZAMAN
				// URL'den (super_admin için tenant bağlamı uydurulmaz); hiçbir
				// uç satır silmez (pasifleştir/aktifleştir/rol/geçici şifre).
				r.Post("/{id}/users", d.Platform.ProvisionOrganizationUser)
				r.Post("/{id}/users/{userId}/deactivate", d.Platform.DeactivateOrganizationUser)
				r.Post("/{id}/users/{userId}/reactivate", d.Platform.ReactivateOrganizationUser)
				r.Put("/{id}/users/{userId}/organization-role", d.Platform.SetOrganizationUserRole)
				r.Post("/{id}/users/{userId}/reset-initial-password", d.Platform.ResetOrganizationUserPassword)
				// Yumuşak silme -- users/organizations satırları ASLA
				// fiziksel DELETE ile kaldırılmaz (bkz. migration 0043,
				// PlatformService.DeleteOrganizationUser/DeleteOrganization
				// yorumları). "delete"/"restore" eylem-fiilleridir, HTTP
				// DELETE metodu KASITLI OLARAK kullanılmaz (bu router'ın
				// deactivate/reactivate ile AYNI POST-eylem sözleşmesi).
				r.Post("/{id}/users/{userId}/delete", d.Platform.DeleteOrganizationUser)
				r.Post("/{id}/users/{userId}/restore", d.Platform.RestoreOrganizationUser)
				r.Get("/{id}/roles", d.Platform.ListOrganizationRoles)
				r.Post("/{id}/reprovision-calc-catalog", d.Platform.ReprovisionCalcCatalog)
				r.Get("/{id}/audit-events", d.Platform.ListAuditEvents)
				r.Post("/{id}/delete", d.Platform.DeleteOrganization)
				r.Post("/{id}/restore", d.Platform.RestoreOrganization)
			})
		})

		// Müşterinin auth gerektirmeden erişebildiği paylaşım linki --
		// güvenlik sınırı tahmin edilemez uuid token'ın kendisidir.
		r.Route("/public/offers/{token}", func(r chi.Router) {
			r.Get("/", d.PublicOffer.Get)
			r.Post("/respond", d.PublicOffer.Respond)
		})

		// Faz 8: müşterinin ek işi (değişiklik emri) görüntüleyip kabul/
		// red edebildiği paylaşım linki -- aynı güvenlik sınırı (token).
		r.Route("/public/change-orders/{token}", func(r chi.Router) {
			r.Get("/", d.PublicChangeOrder.Get)
			r.Post("/respond", d.PublicChangeOrder.Respond)
		})
	})

	return r
}
