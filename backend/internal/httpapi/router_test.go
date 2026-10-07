package httpapi

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/go-chi/chi/v5"
)

// Handler'lar nil olsa da route kaydı çalışır (metot değerleri çağrılana
// kadar receiver'a dokunmaz); /healthz hiçbirine bağımlı değildir.
func TestHealthz_UnauthenticatedLiveness(t *testing.T) {
	router := NewRouter(Deps{})

	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/healthz", nil))

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	var body map[string]string
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("gövde JSON değil: %v", err)
	}
	if body["status"] != "ok" {
		t.Fatalf("status alanı = %q, want %q", body["status"], "ok")
	}
}

func TestHealthz_NotUnderAPIPrefix(t *testing.T) {
	router := NewRouter(Deps{})

	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/v1/healthz", nil))

	if rec.Code != http.StatusNotFound {
		t.Fatalf("/api/v1/healthz status = %d, want 404 (liveness ucu gateway'in /api/* kuralı dışında kalmalı)", rec.Code)
	}
}

// /offers/defaults statik bir segmenttir: /offers/{id} ile çakışmadan GET
// olarak kayıtlı olmalı (teklif formları firma varsayılanlarını buradan
// okur).
func TestOfferDefaultsRouteRegistered(t *testing.T) {
	routes, ok := NewRouter(Deps{}).(chi.Routes)
	if !ok {
		t.Fatal("router chi.Routes değil")
	}
	found := false
	if err := chi.Walk(routes, func(method, route string, _ http.Handler, _ ...func(http.Handler) http.Handler) error {
		if method == http.MethodGet && route == "/api/v1/offers/defaults" {
			found = true
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if !found {
		t.Fatal("GET /api/v1/offers/defaults kayıtlı değil")
	}
}
