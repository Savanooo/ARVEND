package handler

import (
	"net/http/httptest"
	"testing"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
)

// Play'deki 1.5.13 contract_amount'u zorunlu sayı okur: finans izni olmayana
// giden null'u o sürüm için 0'a çeviriyoruz. Gerçek tutar hiçbir durumda
// izinsize gitmemeli; yeni mobil ve web null almaya devam etmeli.
func TestLegacyMobileContractAmount(t *testing.T) {
	p := domain.Project{ID: "p1", ContractAmount: 1_250_000}

	cases := []struct {
		name        string
		userAgent   string
		client      string
		showFinance bool
		want        *float64
	}{
		{"old mobile without finance gets 0", "Dart/3.9 (dart:io)", "", false, f64(0)},
		{"new mobile without finance gets null", "Dart/3.9 (dart:io)", "mobile", false, nil},
		{"web without finance gets null", "node", "", false, nil},
		{"old mobile with finance gets the amount", "Dart/3.9 (dart:io)", "", true, f64(1_250_000)},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			r := httptest.NewRequest("GET", "/api/v1/projects", nil)
			r.Header.Set("User-Agent", c.userAgent)
			if c.client != "" {
				r.Header.Set(ArvendClientHeader, c.client)
			}
			got := withLegacyContractAmount(r, toProjectResponse(p, c.showFinance)).ContractAmount
			switch {
			case c.want == nil && got != nil:
				t.Fatalf("contract_amount = %v, want null", *got)
			case c.want != nil && (got == nil || *got != *c.want):
				t.Fatalf("contract_amount = %v, want %v", got, *c.want)
			}
		})
	}
}

func f64(v float64) *float64 { return &v }
