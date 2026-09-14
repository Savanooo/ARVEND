package config

import (
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
