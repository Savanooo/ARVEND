// Package config, .env dosyasından ve ortam değişkenlerinden uygulama
// ayarlarını okur.
package config

import (
	"os"
	"strings"
	"time"

	"github.com/joho/godotenv"
)

type Config struct {
	Port string
	// ListenAddr, HTTP sunucusunun bağlandığı adres. Üretimde gateway'in
	// arkasında yalnızca loopback (127.0.0.1:8080) olmalı; LISTEN_ADDR
	// verilmezse ":"+PORT ile tüm arayüzlerde dinler (yerel geliştirme).
	ListenAddr string
	// CORSOrigins, tarayıcıdan cross-origin çağrıya izin verilen origin'ler
	// (CORS_ORIGINS, virgülle ayrılmış). Aynı-origin gateway arkasında
	// devreye girmez; yerel geliştirmede :3000 -> :8080 için gerekir.
	CORSOrigins   []string
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
	// StorageRoot, yüklenen dosyaların saklandığı kök dizin. Nesne
	// anahtarları sunucu tarafında üretildiği için bu dizinin dışına
	// yazılması mümkün değildir (bkz. platform/storage).
	StorageRoot string
}

func Load() Config {
	// .env yoksa (ör. üretimde ortam değişkenleri doğrudan verilmişse)
	// sessizce geçilir -- bu bir hata değildir.
	_ = godotenv.Load()

	port := getEnv("PORT", "8080")
	return Config{
		Port:                  port,
		ListenAddr:            getEnv("LISTEN_ADDR", ":"+port),
		CORSOrigins:           splitCSV(getEnv("CORS_ORIGINS", "http://localhost:3000")),
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
		StorageRoot:           getEnv("STORAGE_ROOT", "./var/uploads"),
	}
}

func getEnv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func splitCSV(s string) []string {
	var out []string
	for _, part := range strings.Split(s, ",") {
		if p := strings.TrimSpace(part); p != "" {
			out = append(out, p)
		}
	}
	return out
}
