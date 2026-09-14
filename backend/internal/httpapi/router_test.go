package httpapi

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
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
