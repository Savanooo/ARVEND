package domain

import (
	"testing"
	"time"
)

func TestNormalizeCurrency(t *testing.T) {
	cases := []struct {
		in, want string
		ok       bool
	}{
		{"TRY", "TRY", true},
		{" usd ", "USD", true},
		{"tl", "TRY", true},
		{"₺", "TRY", true},
		{"EURO", "", false},
		{"", "", false},
		{"U$D", "", false},
	}
	for _, c := range cases {
		got, ok := NormalizeCurrency(c.in)
		if got != c.want || ok != c.ok {
			t.Errorf("NormalizeCurrency(%q) = %q,%v; istenen %q,%v", c.in, got, ok, c.want, c.ok)
		}
	}
}

func TestOfferDefaultsValidUntilFrom(t *testing.T) {
	days := 30
	d := OfferDefaults{ValidityDays: &days}
	// İstanbul'da 31 Ocak 23:30 (offerDay çağıranda İstanbul'a çevrilir):
	// takvim günü 31 Ocak, ay taşması time.Date ile doğru: 2 Mart.
	ist := time.FixedZone("TRT", 3*60*60)
	got := d.ValidUntilFrom(time.Date(2026, 1, 31, 23, 30, 0, 0, ist))
	if got == nil || got.Format("2006-01-02") != "2026-03-02" {
		t.Fatalf("31 Ocak + 30 gün = 2 Mart olmalı, gelen %v", got)
	}
	if (OfferDefaults{}).ValidUntilFrom(time.Now()) != nil {
		t.Fatal("süre yoksa tarih de olmamalı")
	}
}
