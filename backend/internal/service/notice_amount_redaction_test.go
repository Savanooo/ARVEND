package service

import (
	"testing"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
)

// Ek iş kararı bildiriminin gövdesindeki tutar (noticeAmount, işaretli),
// finans okuması sonradan kaldırılan alıcıya okuma anında düşürülebilmeli
// (domain.NotificationBodyForViewer). noticeAmount'un biçimi değişirse bu
// test kırılır -- kalıp domain/notification_money.go'da birlikte güncellenir.
func TestChangeOrderNoticeAmountIsRedactable(t *testing.T) {
	want := "EK-001 Kapı · Villa · Kaydeden: Ali"
	for _, v := range []float64{0.75, 950, 12000.5, 1250000, 999999999.99} {
		for _, cur := range []string{"TRY", "", "USD", "EUR"} {
			amount := noticeAmount(repository.Float64ToNumeric(v), cur)
			for _, sign := range []string{"+", "-"} {
				body := joinNonEmpty(" · ", "EK-001 Kapı", "Villa", sign+amount, "Kaydeden: Ali")
				if got := domain.NotificationBodyForViewer(domain.NotificationChangeOrderApproved, body, false); got != want {
					t.Errorf("%q -> %q, want %q", body, got, want)
				}
				if got := domain.NotificationBodyForViewer(domain.NotificationChangeOrderApproved, body, true); got != body {
					t.Errorf("finans izinliye gövde aynen dönmeli: %q -> %q", body, got)
				}
			}
		}
	}
}
