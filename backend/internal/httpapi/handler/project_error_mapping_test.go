package handler

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5/pgconn"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

// Proje/maliyet/satın alma/taşeron uçlarının hata eşlemesi (2026-10
// denetimi): istekteki geçersiz referans neyin bulunamadığını söylemeli,
// girdi hataları 400 + kendi mesajıyla dönmeli, veritabanı hataları ham
// metinle 400 değil 500 olmalı.
func TestProjectErrorMapping(t *testing.T) {
	pgErr := &pgconn.PgError{Code: "23514", Message: "new row violates check constraint \"x_check\""}
	cases := []struct {
		name     string
		write    func(w http.ResponseWriter, err error)
		err      error
		status   int
		contains string
	}{
		{"budget line ref", (&ProjectHandler{}).writeError, service.ErrBudgetLineRefNotFound, 404, "bütçe kalemi"},
		{"supplier ref wrapped", (&ProjectHandler{}).writeError, fmt.Errorf("x: %w", service.ErrSupplierRefNotFound), 404, "tedarikçi"},
		{"plain not found", (&ProjectHandler{}).writeError, domain.ErrNotFound, 404, "proje bulunamadı"},
		{"title required", (&ProjectHandler{}).writeError, service.ErrTitleRequired, 400, "başlık"},
		{"change type", (&ProjectHandler{}).writeError, service.ErrInvalidChangeType, 400, "değişiklik tipi"},
		{"retention", (&ProjectHandler{}).writeError, service.ErrInvalidRetentionPercent, 400, "0 ile 100"},
		{"project db error", (&ProjectHandler{}).writeError, pgErr, 500, "beklenmeyen"},
		{"cost code db error", (&CostCodeHandler{}).writeError, pgErr, 500, "beklenmeyen"},
		{"supplier db error", (&SupplierHandler{}).writeError, pgErr, 500, "beklenmeyen"},
		{"cost code business error", (&CostCodeHandler{}).writeError, service.ErrDuplicateCostCode, 409, ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			rec := httptest.NewRecorder()
			tc.write(rec, tc.err)
			if rec.Code != tc.status {
				t.Fatalf("durum %d olmalı, geldi %d (%s)", tc.status, rec.Code, rec.Body.String())
			}
			var body map[string]any
			_ = json.Unmarshal(rec.Body.Bytes(), &body)
			msg := fmt.Sprint(body["error"])
			if !strings.Contains(msg, tc.contains) {
				t.Fatalf("mesaj %q içermeli, geldi %q", tc.contains, msg)
			}
			if strings.Contains(msg, "check constraint") {
				t.Fatalf("ham veritabanı metni sızmamalı: %q", msg)
			}
		})
	}
}
