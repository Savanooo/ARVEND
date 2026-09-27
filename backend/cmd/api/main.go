package main

import (
	"context"
	"errors"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/Savanooo/ARVEND/backend/internal/auth"
	"github.com/Savanooo/ARVEND/backend/internal/config"
	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/httpapi"
	"github.com/Savanooo/ARVEND/backend/internal/httpapi/handler"
	"github.com/Savanooo/ARVEND/backend/internal/platform/crypto"
	"github.com/Savanooo/ARVEND/backend/internal/platform/storage"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

func main() {
	cfg := config.Load()
	if cfg.DatabaseURL == "" {
		log.Fatal("DB_URL ayarlanmamış (.env dosyasına bakın)")
	}
	if cfg.JWTSecret == "" {
		log.Fatal("JWT_SECRET ayarlanmamış (.env dosyasına bakın)")
	}
	if cfg.SettingsEncryptionKey == "" {
		log.Fatal("SETTINGS_ENCRYPTION_KEY ayarlanmamış (.env dosyasına bakın)")
	}
	secretBox, err := crypto.NewSecretBox(cfg.SettingsEncryptionKey)
	if err != nil {
		log.Fatalf("SETTINGS_ENCRYPTION_KEY geçersiz: %v", err)
	}

	ctx := context.Background()
	pool, err := repository.NewPool(ctx, cfg.DatabaseURL)
	if err != nil {
		log.Fatalf("veritabanına bağlanılamadı: %v", err)
	}
	defer pool.Close()
	if err := pool.Ping(ctx); err != nil {
		log.Fatalf("veritabanı ping başarısız: %v", err)
	}

	fileStore, err := storage.NewLocalStore(cfg.StorageRoot)
	if err != nil {
		log.Fatalf("dosya deposu açılamadı: %v", err)
	}

	q := sqlc.New(pool)
	userSvc := service.NewUserService(q)
	seedAdmin(ctx, userSvc, q, cfg)
	productSvc := service.NewProductService(q)
	settingsSvc := service.NewSettingsService(q, secretBox)
	offerSvc := service.NewOfferService(pool, q, settingsSvc, cfg.FrontendURL)
	projectSvc := service.NewProjectService(pool, q, fileStore, settingsSvc, cfg.FrontendURL)
	customerSvc := service.NewCustomerService(q)
	employeeSvc := service.NewEmployeeService(q)
	attendanceSvc := service.NewAttendanceService(q)
	calcSvc := service.NewCalcService(q)
	platformSvc := service.NewPlatformService(pool, q, userSvc, calcSvc, productSvc)
	onboardingSvc := service.NewOnboardingService(q, secretBox)
	authzSvc := service.NewAuthorizationService(q)
	costCodeSvc := service.NewCostCodeService(pool, q)
	supplierSvc := service.NewSupplierService(pool, q, secretBox)
	notificationSvc := service.NewNotificationService(q)
	priceSourceSvc := service.NewPriceSourceService(pool, q, service.HTTPPriceFetchers(nil))

	jwtIssuer := auth.NewJWTIssuer(cfg.JWTSecret, cfg.AccessTTL)
	authSvc := service.NewAuthService(q, jwtIssuer, cfg.RefreshTTL)

	router := httpapi.NewRouter(httpapi.Deps{
		JWT:               jwtIssuer,
		Queries:           q,
		Auth:              handler.NewAuthHandler(authSvc, authzSvc, cfg.AccessTTL, cfg.RefreshTTL, cfg.CookieDomain, cfg.CookieSecure),
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
		Notifications:     handler.NewNotificationHandler(notificationSvc),
		CORSOrigins:       cfg.CORSOrigins,
	})

	addr := cfg.ListenAddr
	log.Printf("ARVEND API %s adresinde dinliyor", addr)
	// Başlık okuma kısa tutulur (slowloris koruması); gövde/yanıt süreleri ise
	// 25 MiB proje dosyası/fotoğrafının yavaş mobil bağlantıda (~100 KB/s)
	// kesilmeden yüklenip indirilebilmesi için uzundur. Go'da WriteTimeout,
	// isteğin başlığı okunduğu anda başlar -- yani upload gövdesinin okunmasını
	// da kapsar; bu yüzden ReadTimeout ile aynı tutulur.
	srv := &http.Server{
		Addr:              addr,
		Handler:           router,
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       5 * time.Minute,
		WriteTimeout:      5 * time.Minute,
		IdleTimeout:       120 * time.Second,
	}

	// SIGINT/SIGTERM: yeni bağlantı kabulü durur, süren istekler (en fazla
	// 30 sn) tamamlanır, arka plan işleri (gece fiyat senkronu) ctx
	// iptaliyle durur -- yarım kalan bir senkron transaction'ı geri alınır.
	runCtx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	var background sync.WaitGroup
	if cfg.PriceSyncScheduler {
		background.Add(1)
		go func() {
			defer background.Done()
			priceSourceSvc.RunNightly(runCtx)
		}()
	} else {
		log.Println("gece fiyat senkronu zamanlayıcısı kapalı (PRICE_SYNC_SCHEDULER)")
	}

	serveErr := make(chan error, 1)
	go func() { serveErr <- srv.ListenAndServe() }()

	exitCode := 0
	select {
	case err := <-serveErr:
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			// Ör. port kullanımda: systemd yeniden denesin diye sıfırdan
			// farklı kodla çıkılır (eski log.Fatal davranışı).
			log.Printf("HTTP sunucusu durdu: %v", err)
			exitCode = 1
		}
	case <-runCtx.Done():
		log.Println("kapatma sinyali alındı, süren istekler tamamlanıyor")
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		if err := srv.Shutdown(shutdownCtx); err != nil {
			log.Printf("HTTP sunucusu düzgün kapatılamadı: %v", err)
		}
		cancel()
	}
	stop()
	background.Wait()
	log.Println("ARVEND API durdu")
	if exitCode != 0 {
		pool.Close()
		os.Exit(exitCode)
	}
}

// seedAdmin, sistemde hiç kullanıcı yoksa .env'deki SEED_ADMIN_* bilgileriyle
// ilk admin kullanıcısını oluşturur (eski Flask sistemindeki
// ensure_default_admin() deseninin Go karşılığı). Zaten kullanıcı varsa
// sessizce hiçbir şey yapmaz -- yeniden başlatmalarda tekrar tetiklenmez.
func seedAdmin(ctx context.Context, userSvc *service.UserService, q *sqlc.Queries, cfg config.Config) {
	orgID, err := repository.StringToUUID(domain.DefaultOrganizationID)
	if err != nil {
		log.Fatalf("varsayılan organizasyon UUID'si geçersiz: %v", err)
	}
	count, err := q.CountUsers(ctx, orgID)
	if err != nil {
		log.Fatalf("kullanıcı sayısı okunamadı: %v", err)
	}
	if count > 0 {
		return
	}
	if cfg.SeedAdminUser == "" || cfg.SeedAdminPass == "" {
		log.Println("UYARI: hiç kullanıcı yok ve SEED_ADMIN_USERNAME/PASSWORD ayarlanmamış -- giriş yapılamayacak")
		return
	}
	_, err = userSvc.Create(ctx, domain.DefaultOrganizationID, cfg.SeedAdminUser, cfg.SeedAdminPass, cfg.SeedAdminName, domain.RoleAdmin, "")
	if err != nil {
		log.Fatalf("seed admin oluşturulamadı: %v", err)
	}
	log.Printf("İlk admin kullanıcı oluşturuldu: %s", strings.TrimSpace(cfg.SeedAdminUser))
}
