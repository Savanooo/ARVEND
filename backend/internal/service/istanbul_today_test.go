package service

import (
	"testing"
	"time"
)

// Sunucu UTC'de: İstanbul'da gece 01:30 iken UTC hâlâ önceki gün. "Bugün"
// (mesai ileri tarih kontrolü, varsayılan ay, ödeme tarihi) İstanbul
// takviminden gelmeli.
func TestIstanbulToday(t *testing.T) {
	now := time.Date(2026, 10, 31, 22, 30, 0, 0, time.UTC) // İstanbul: 1 Kasım 01:30
	got := istanbulToday(now)
	if want := time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC); !got.Equal(want) {
		t.Errorf("istanbulToday = %v, beklenen %v", got, want)
	}
}
