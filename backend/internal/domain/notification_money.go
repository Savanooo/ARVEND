package domain

import (
	"regexp"
	"strings"
)

// Bildirim gövdesindeki proje tutarı. Ek iş kararı bildirimi (bkz.
// service.notifyChangeOrderDecision) gövdesine işaretli tutar yazar
// ("EK-001 Başlık · Proje · +1.250.000 TL · Kaydeden: Ad") ve YALNIZCA
// projects.finance.read sahiplerine gider. Gövde oluşturulduğu anda
// saklanır: alıcının finans okuması SONRADAN kaldırılırsa eski bildirim
// tutarı göstermeye devam ederdi. Okuma uçları (GET /notifications, ana
// sayfa bildirim bölümü) bu yüzden tutarı okuyanın GÜNCEL iznine göre
// düşürür (bkz. NotificationBodyForViewer).

// noticeBodySeparator: service.joinNonEmpty'nin bildirim gövdesinde
// kullandığı ayraç.
const noticeBodySeparator = " · "

// noticeAmountPart: service.noticeAmount çıktısı, ek işte işaretli --
// "+1.250.000 TL", "-12.000,50 USD". İşaret ZORUNLU: ek iş tutarı her zaman
// işaretli yazılır, işaretsiz "120 EV" gibi bir proje adı tutar sanılıp
// düşürülmez. Başlık parçası ("EK-001 ...") ve kişi adı bu kalıba uymaz;
// küçük harfli birim ("+2 adet") de uymaz.
var noticeAmountPart = regexp.MustCompile(`^[+-]\d{1,3}(\.\d{3})*(,\d{1,2})? [A-Z]{2,4}$`)

// NotificationCarriesProjectMoney: gövdesine proje tutarı yazan bildirim
// tipleri.
func NotificationCarriesProjectMoney(notificationType string) bool {
	switch notificationType {
	case NotificationChangeOrderApproved, NotificationChangeOrderRejected:
		return true
	}
	return false
}

// NotificationBodyForViewer: okuyan projects.finance.read taşımıyorsa
// tutar taşıyan bildirim tipinin gövdesinden tutar parçasını düşürür;
// diğer her durumda gövde aynen döner.
func NotificationBodyForViewer(notificationType, body string, canSeeProjectFinance bool) string {
	if canSeeProjectFinance || !NotificationCarriesProjectMoney(notificationType) {
		return body
	}
	parts := strings.Split(body, noticeBodySeparator)
	kept := parts[:0:0]
	for _, p := range parts {
		if noticeAmountPart.MatchString(strings.TrimSpace(p)) {
			continue
		}
		kept = append(kept, p)
	}
	return strings.Join(kept, noticeBodySeparator)
}
