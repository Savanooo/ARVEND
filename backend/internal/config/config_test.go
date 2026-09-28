package config

import (
	"path/filepath"
	"reflect"
	"testing"
)

func TestLoad_ListenAddrFallsBackToPort(t *testing.T) {
	t.Setenv("PORT", "9090")
	t.Setenv("LISTEN_ADDR", "")

	cfg := Load()
	if cfg.ListenAddr != ":9090" {
		t.Fatalf("ListenAddr = %q, want %q (tüm arayüzler, yerel geliştirme)", cfg.ListenAddr, ":9090")
	}
	if cfg.Port != "9090" {
		t.Fatalf("Port = %q, want %q", cfg.Port, "9090")
	}
}

func TestLoad_ListenAddrOverridesPort(t *testing.T) {
	t.Setenv("PORT", "8080")
	t.Setenv("LISTEN_ADDR", "127.0.0.1:8080")

	cfg := Load()
	if cfg.ListenAddr != "127.0.0.1:8080" {
		t.Fatalf("ListenAddr = %q, want loopback-only %q", cfg.ListenAddr, "127.0.0.1:8080")
	}
}

func TestLoad_CORSOriginsDefault(t *testing.T) {
	t.Setenv("CORS_ORIGINS", "")

	cfg := Load()
	want := []string{"http://localhost:3000"}
	if !reflect.DeepEqual(cfg.CORSOrigins, want) {
		t.Fatalf("CORSOrigins = %v, want %v", cfg.CORSOrigins, want)
	}
}

func TestLoad_CORSOriginsParsesCSV(t *testing.T) {
	t.Setenv("CORS_ORIGINS", " https://app.example.com, http://localhost:3000 ,, ")

	cfg := Load()
	want := []string{"https://app.example.com", "http://localhost:3000"}
	if !reflect.DeepEqual(cfg.CORSOrigins, want) {
		t.Fatalf("CORSOrigins = %v, want %v (boşluklar kırpılır, boş parçalar atılır)", cfg.CORSOrigins, want)
	}
}

func TestLoad_PriceSyncScheduler(t *testing.T) {
	cases := map[string]bool{"": true, "on": true, "true": true, "1": true, "off": false, "OFF": false, "false": false, "0": false, "no": false, "disabled": false}
	for v, want := range cases {
		t.Setenv("PRICE_SYNC_SCHEDULER", v)
		if got := Load().PriceSyncScheduler; got != want {
			t.Errorf("PRICE_SYNC_SCHEDULER=%q -> %v, want %v", v, got, want)
		}
	}
}

func TestLoad_AppReleasesDirDefaultsNextToStorageRoot(t *testing.T) {
	t.Setenv("APP_RELEASES_DIR", "")
	cases := map[string]string{
		// Üretim: STORAGE_ROOT=/var/lib/arvend/uploads.
		"/var/lib/arvend/uploads":  "/var/lib/arvend/app-releases",
		"/var/lib/arvend/uploads/": "/var/lib/arvend/app-releases",
		// Yerel: STORAGE_ROOT verilmezse ./var/uploads.
		"":              filepath.Clean("./var/app-releases"),
		"./var/uploads": filepath.Clean("./var/app-releases"),
	}
	for storageRoot, want := range cases {
		t.Setenv("STORAGE_ROOT", storageRoot)
		if got := Load().AppReleasesDir; got != want {
			t.Errorf("STORAGE_ROOT=%q -> AppReleasesDir = %q, want %q (uploads'ın içi değil, kardeşi)", storageRoot, got, want)
		}
	}
}

func TestLoad_AppReleasesDirOverride(t *testing.T) {
	t.Setenv("STORAGE_ROOT", "/var/lib/arvend/uploads")
	t.Setenv("APP_RELEASES_DIR", "/srv/arvend-releases")

	if got := Load().AppReleasesDir; got != "/srv/arvend-releases" {
		t.Fatalf("AppReleasesDir = %q, want APP_RELEASES_DIR aynen", got)
	}
}
