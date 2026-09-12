// Package config, .env dosyasından ve ortam değişkenlerinden uygulama
// ayarlarını okur.
package config

import (
	"os"
	"time"

	"github.com/joho/godotenv"
)

type Config struct {
	Port          string
	DatabaseURL   string
	JWTSecret     string
	AccessTTL     time.Duration
	RefreshTTL    time.Duration
	CookieDomain  string
	CookieSecure  bool
	SeedAdminUser string
	SeedAdminPass string
	SeedAdminName string
}

func Load() Config {
	// .env yoksa (ör. üretimde ortam değişkenleri doğrudan verilmişse)
	// sessizce geçilir -- bu bir hata değildir.
	_ = godotenv.Load()

	return Config{
		Port:          getEnv("PORT", "8080"),
		DatabaseURL:   getEnv("DB_URL", ""),
		JWTSecret:     getEnv("JWT_SECRET", ""),
		AccessTTL:     15 * time.Minute,
		RefreshTTL:    30 * 24 * time.Hour,
		CookieDomain:  getEnv("COOKIE_DOMAIN", ""),
		CookieSecure:  getEnv("COOKIE_SECURE", "false") == "true",
		SeedAdminUser: getEnv("SEED_ADMIN_USERNAME", ""),
		SeedAdminPass: getEnv("SEED_ADMIN_PASSWORD", ""),
		SeedAdminName: getEnv("SEED_ADMIN_FULLNAME", "Yönetici"),
	}
}

func getEnv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
