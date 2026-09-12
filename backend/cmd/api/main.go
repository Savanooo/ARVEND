package main

import (
	"context"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/Savanooo/ARVEND/backend/internal/auth"
	"github.com/Savanooo/ARVEND/backend/internal/config"
	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/httpapi"
	"github.com/Savanooo/ARVEND/backend/internal/httpapi/handler"
	"github.com/Savanooo/ARVEND/backend/internal/platform/crypto"
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

	q := sqlc.New(pool)
	userSvc := service.NewUserService(q)
	seedAdmin(ctx, userSvc, q, cfg)
	productSvc := service.NewProductService(q)
	settingsSvc := service.NewSettingsService(q, secretBox)
	offerSvc := service.NewOfferService(pool, q, settingsSvc, cfg.FrontendURL)
	projectSvc := service.NewProjectService(pool, q)
	customerSvc := service.NewCustomerService(q)
	employeeSvc := service.NewEmployeeService(q)
	attendanceSvc := service.NewAttendanceService(q)

	jwtIssuer := auth.NewJWTIssuer(cfg.JWTSecret, cfg.AccessTTL)
	authSvc := service.NewAuthService(q, jwtIssuer, cfg.RefreshTTL)

	router := httpapi.NewRouter(httpapi.Deps{
		JWT:         jwtIssuer,
		Auth:        handler.NewAuthHandler(authSvc, cfg.AccessTTL, cfg.RefreshTTL, cfg.CookieDomain, cfg.CookieSecure),
		Users:       handler.NewUserHandler(userSvc),
		Products:    handler.NewProductHandler(productSvc),
		Offers:      handler.NewOfferHandler(offerSvc),
		Projects:    handler.NewProjectHandler(projectSvc),
		Customers:   handler.NewCustomerHandler(customerSvc),
		Employees:   handler.NewEmployeeHandler(employeeSvc),
		Attendance:  handler.NewAttendanceHandler(attendanceSvc),
		Settings:    handler.NewSettingsHandler(settingsSvc),
		PublicOffer: handler.NewPublicOfferHandler(offerSvc),
		CORSOrigins: []string{
			"http://localhost:3000",
		},
	})

	addr := ":" + cfg.Port
	log.Printf("ARVEND API %s adresinde dinliyor", addr)
	srv := &http.Server{
		Addr:         addr,
		Handler:      router,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 10 * time.Second,
	}
	log.Fatal(srv.ListenAndServe())
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
	_, err = userSvc.Create(ctx, domain.DefaultOrganizationID, cfg.SeedAdminUser, cfg.SeedAdminPass, cfg.SeedAdminName, domain.RoleAdmin)
	if err != nil {
		log.Fatalf("seed admin oluşturulamadı: %v", err)
	}
	log.Printf("İlk admin kullanıcı oluşturuldu: %s", strings.TrimSpace(cfg.SeedAdminUser))
}
