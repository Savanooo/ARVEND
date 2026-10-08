package service

import "strings"

// linkPreviewAgentMarkers: bağlantı önizlemesi yapan uygulama ve botların
// User-Agent'larında geçen parçalar (küçük harf). Mesajlaşma uygulamaları
// linki GÖNDERENİN cihazından ya da kendi sunucularından çeker; iMessage
// "facebookexternalhit ... Twitterbot" ile gelir. Genel "bot"/"crawler"/
// "spider"/"preview" parçaları adını bilmediğimiz tarayıcıları da yakalar.
var linkPreviewAgentMarkers = []string{
	"whatsapp", "telegrambot", "facebookexternalhit", "facebot", "twitterbot",
	"slackbot", "linkedinbot", "discordbot", "skypeuripreview", "viber",
	"applebot", "googlebot", "bingbot", "yandex", "embedly", "pinterest",
	"bot", "crawler", "spider", "preview", "headlesschrome",
}

// humanDevicesWithBotInName: User-Agent'ında model adı olarak "bot" geçen
// gerçek telefon markaları (küçük harf). Genel "bot" eşleşmesinden önce
// silinir.
var humanDevicesWithBotInName = []string{"cubot"}

// IsLinkPreviewAgent, isteğin bir insan değil, bağlantı önizlemesi yapan
// bir uygulama/bot olduğunu söyler. Yalnızca "müşteri teklifi açtı"
// bildirimini ayıklamak için kullanılır (bkz. recordCustomerView); hiçbir
// erişim kararına girmez -- başlığı uyduran biri olsa olsa kendi açılış
// bildirimini susturur. Boş User-Agent bot sayılmaz: Next.js sunucusunun
// kendi isteği (eski web sürümü başlığı iletmezken) "node" ile gelir ve
// bildirimi hiç kesmemeli.
func IsLinkPreviewAgent(userAgent string) bool {
	ua := strings.ToLower(userAgent)
	if ua == "" {
		return false
	}
	// Model adında "bot" geçen telefonlar (CUBOT) insan: genel "bot" parçası
	// onları önizleme sayıp müşterinin gerçek açılış bildirimini yutuyordu.
	for _, device := range humanDevicesWithBotInName {
		ua = strings.ReplaceAll(ua, device, "")
	}
	for _, m := range linkPreviewAgentMarkers {
		if strings.Contains(ua, m) {
			return true
		}
	}
	return false
}
