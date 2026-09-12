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
	// SettingsEncryptionKey, ayarlar tablosunda (ör. SMTP şifresi) saklanan
	// hassas alanları AES-GCM ile şifrelemek için kullanılan ana anahtar
	// (base64, 32 byte). Bu anahtar .env'de kalır; asıl şifreler DB'de
	// şifreli olarak durur -- düz metin .env'de tutulmaz.
	SettingsEncryptionKey string
	FrontendURL           string
}

func Load() Config {
	// .env yoksa (ör. üretimde ortam değişkenleri doğrudan verilmişse)
	// sessizce geçilir -- bu bir hata değildir.
	_ = godotenv.Load()

	return Config{
		Port:                  getEnv("PORT", "8080"),
		DatabaseURL:           getEnv("DB_URL", ""),
		JWTSecret:             getEnv("JWT_SECRET", ""),
		AccessTTL:             15 * time.Minute,
		RefreshTTL:            30 * 24 * time.Hour,
		CookieDomain:          getEnv("COOKIE_DOMAIN", ""),
		CookieSecure:          getEnv("COOKIE_SECURE", "false") == "true",
		SeedAdminUser:         getEnv("SEED_ADMIN_USERNAME", ""),
		SeedAdminPass:         getEnv("SEED_ADMIN_PASSWORD", ""),
		SeedAdminName:         getEnv("SEED_ADMIN_FULLNAME", "Yönetici"),
		SettingsEncryptionKey: getEnv("SETTINGS_ENCRYPTION_KEY", ""),
		FrontendURL:           getEnv("FRONTEND_URL", "http://localhost:3000"),
	}
}

func getEnv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
