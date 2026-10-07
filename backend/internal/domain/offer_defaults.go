package domain

import (
	"strings"
	"time"
)

// Firma teklif ayarı hiç kaydedilmemişse (organization_commercial_settings
// satırı yok) kullanılan varsayılanlar -- migration 0032'nin kolon
// varsayılanlarıyla aynı.
const (
	DefaultOfferVATRate  = 20.0
	DefaultOfferCurrency = "TRY"
)

// OfferDefaults, yeni bir teklifin firma ayarlarından (onboarding "Teklif"
// adımı) gelen başlangıç değerleridir. Teklif formları bunları önceden
// doldurur; istekte gönderilmeyen KDV/para birimi/geçerlilik de sunucuda
// bunlardan tamamlanır. IBAN gibi finans bilgileri BİLİNÇLİ OLARAK yoktur --
// bu değerler teklif oluşturabilen her personele açılır.
type OfferDefaults struct {
	VATRate  float64
	Currency string
	// ValidityDays: nil = firma ayar kaydetmemiş, teklif süresiz kalır
	// (eski davranış). Doluysa her zaman > 0.
	ValidityDays  *int
	PaymentTerms  string
	DeliveryTerms string
	Footer        string
}

// ValidUntilFrom, verilen teklif gününden geçerlilik süresi sonrasını
// takvim günü olarak (UTC gece yarısı, date kolonuyla aynı) döner.
// offerDay çağıran tarafından İstanbul gününe çevrilmiş olmalıdır.
// Süre yoksa nil.
func (d OfferDefaults) ValidUntilFrom(offerDay time.Time) *time.Time {
	if d.ValidityDays == nil || *d.ValidityDays <= 0 {
		return nil
	}
	y, m, day := offerDay.Date()
	t := time.Date(y, m, day+*d.ValidityDays, 0, 0, 0, 0, time.UTC)
	return &t
}

// NormalizeCurrency, para birimini 3 harfli büyük harf koda çevirir; "TL"
// ve "₺" TRY sayılır (onboarding'de para birimi serbest metin -- Türk
// kullanıcı çoğunlukla "TL" yazar ve aynı para iki ayrı kod olarak
// raporlara bölünmesin). Kod değilse ok=false.
func NormalizeCurrency(s string) (string, bool) {
	c := strings.ToUpper(strings.TrimSpace(s))
	if c == "TL" || c == "₺" {
		return DefaultOfferCurrency, true
	}
	if len(c) != 3 {
		return "", false
	}
	for _, r := range c {
		if r < 'A' || r > 'Z' {
			return "", false
		}
	}
	return c, true
}
