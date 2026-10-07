package domain

import (
	"testing"
	"time"
)

func TestOrganizationTrial(t *testing.T) {
	ist, err := time.LoadLocation("Europe/Istanbul")
	if err != nil {
		t.Fatalf("İstanbul saat dilimi yüklenemedi: %v", err)
	}
	at := func(s string) *time.Time {
		v, err := time.Parse(time.RFC3339, s)
		if err != nil {
			t.Fatalf("tarih: %v", err)
		}
		return &v
	}
	// Bitiş: 15.10.2026 10:00 İstanbul (07:00Z).
	ends := at("2026-10-15T07:00:00Z")

	cases := []struct {
		name     string
		org      Organization
		now      string
		wantNil  bool
		wantDays int
		expired  bool
	}{
		{name: "aktif firma: deneme yok", org: Organization{Status: OrgStatusActive, TrialEndsAt: ends}, now: "2026-10-10T09:00:00Z", wantNil: true},
		{name: "bitiş tarihi yok", org: Organization{Status: OrgStatusTrial}, now: "2026-10-10T09:00:00Z", wantNil: true},
		{name: "7 gün kala", org: Organization{Status: OrgStatusTrial, TrialEndsAt: ends}, now: "2026-10-08T09:00:00Z", wantDays: 7},
		{name: "bitiş günü saatten sonra da sürer", org: Organization{Status: OrgStatusTrial, TrialEndsAt: ends}, now: "2026-10-15T18:00:00Z", wantDays: 0},
		{name: "ertesi gün bitti", org: Organization{Status: OrgStatusTrial, TrialEndsAt: ends}, now: "2026-10-16T09:00:00Z", wantDays: -1, expired: true},
		// 14.10 22:30Z = 15.10 01:30 İstanbul: sunucu UTC'de olsa da "bugün" 15'i.
		{name: "İstanbul gece yarısı sınırı", org: Organization{Status: OrgStatusTrial, TrialEndsAt: ends}, now: "2026-10-14T22:30:00Z", wantDays: 0},
		// Bitiş 14.10 21:30Z = 15.10 00:30 İstanbul: UTC günü 14 ama
		// kullanıcıya gösterilen (ve sayılan) gün 15.
		{name: "bitişin İstanbul günü esas", org: Organization{Status: OrgStatusTrial, TrialEndsAt: at("2026-10-14T21:30:00Z")}, now: "2026-10-14T12:00:00Z", wantDays: 1},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := tc.org.Trial(*at(tc.now), ist)
			if tc.wantNil {
				if got != nil {
					t.Fatalf("nil bekleniyordu: %+v", got)
				}
				return
			}
			if got == nil {
				t.Fatal("deneme durumu dönmeli")
			}
			if got.DaysLeft != tc.wantDays || got.Expired != tc.expired {
				t.Errorf("days=%d expired=%v, beklenen days=%d expired=%v", got.DaysLeft, got.Expired, tc.wantDays, tc.expired)
			}
			if !got.EndsAt.Equal(*tc.org.TrialEndsAt) {
				t.Errorf("EndsAt = %v", got.EndsAt)
			}
		})
	}
	if got := (Organization{Status: OrgStatusTrial, TrialEndsAt: ends}).Trial(*at("2026-10-08T09:00:00Z"), ist); got.EndsOn.Format("2006-01-02") != "2026-10-15" {
		t.Errorf("EndsOn = %s, beklenen 2026-10-15", got.EndsOn.Format("2006-01-02"))
	}
}
