package domain

import "testing"

func TestNotificationBodyForViewer(t *testing.T) {
	cases := []struct {
		name, typ, body string
		canSee          bool
		want            string
	}{
		{"finans izinli aynen görür", NotificationChangeOrderApproved,
			"EK-001 Kapı · Villa · +1.250.000 TL · Kaydeden: Ali", true,
			"EK-001 Kapı · Villa · +1.250.000 TL · Kaydeden: Ali"},
		{"izinsizden tutar düşer", NotificationChangeOrderApproved,
			"EK-001 Kapı · Villa · +1.250.000 TL · Kaydeden: Ali", false,
			"EK-001 Kapı · Villa · Kaydeden: Ali"},
		{"eksiltme, kuruşlu döviz", NotificationChangeOrderRejected,
			"EK-012 Eksiltme · Villa · -12.000,50 USD", false,
			"EK-012 Eksiltme · Villa"},
		{"küçük tutar", NotificationChangeOrderApproved,
			"EK-002 Boya · Villa · +950 TL", false,
			"EK-002 Boya · Villa"},
		{"başlıktaki sayı korunur", NotificationChangeOrderApproved,
			"EK-003 Kapı · +2 adet · Villa · +5.000 TL", false,
			"EK-003 Kapı · +2 adet · Villa"},
		{"işaretsiz sayılı proje adı korunur", NotificationChangeOrderApproved,
			"EK-005 Kapı · 120 EV · +5.000 TL", false,
			"EK-005 Kapı · 120 EV"},
		{"tutar yoksa aynen", NotificationChangeOrderApproved,
			"EK-004 Kapı · Villa", false,
			"EK-004 Kapı · Villa"},
		{"başka tip dokunulmaz", NotificationTaskAssigned,
			"Görev · +1.000 TL", false,
			"Görev · +1.000 TL"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := NotificationBodyForViewer(c.typ, c.body, c.canSee); got != c.want {
				t.Errorf("got %q, want %q", got, c.want)
			}
		})
	}
}
