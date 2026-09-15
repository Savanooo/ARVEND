package domain

import "time"

// BusinessTypeWhitelist, organization_profile.business_type için DB CHECK
// yerine servis katmanında doğrulanan kapalı liste (bkz. migration 0032
// yorumu -- yeni bir faaliyet alanı eklemek için migration gerekmesin diye
// bilinçli olarak DB seviyesinde değil burada).
var BusinessTypeWhitelist = []string{
	"insaat_taahhut",
	"tasarim_mimarlik",
	"muhendislik_danismanlik",
	"tedarik_montaj",
	"diger",
}

func ValidBusinessType(v string) bool {
	if v == "" {
		return true
	}
	for _, t := range BusinessTypeWhitelist {
		if t == v {
			return true
		}
	}
	return false
}

// OrganizationProfile, firmanın kimlik/resmi/iletişim bilgilerini tutar
// (onboarding Adım 1 "Firma" + Adım 2 "Resmi/Fatura" + Adım 5 "İşletme").
// Satır yokluğu servis katmanında "henüz yapılandırılmadı" anlamına gelir
// (smtp_settings ile aynı desen).
type OrganizationProfile struct {
	OrganizationID   string
	AuthorizedPerson string
	Phone            string
	Email            string
	Website          string
	LogoObjectKey    string
	LegalName        string
	TaxOffice        string
	TaxNumber        string
	InvoiceAddress   string
	City             string
	District         string
	Country          string
	BusinessType     string
	CreatedAt        time.Time
	UpdatedAt        time.Time
}

// OrganizationCommercialSettings, teklif varsayılanları (Adım 3 "Teklif") ve
// finans/fatura bilgilerini (Adım 4 "Finans") tutar. IBAN, smtp_settings
// şifresiyle AYNI SecretBox/AES-GCM deseniyle şifrelenir -- IBAN alanı
// yalnızca çözülmüş (plaintext) haliyle servis içinde taşınır, hiçbir API
// yanıtına yazılmaz (bkz. IBANSet).
type OrganizationCommercialSettings struct {
	OrganizationID       string
	DefaultCurrency      string
	DefaultVATRate       float64
	OfferPrefix          string
	OfferValidityDays    int
	DefaultOfferFooter   string
	DefaultPaymentTerms  string
	DefaultDeliveryTerms string
	BankName             string
	AccountHolder        string
	IBAN                 string // çözülmüş (plaintext) IBAN -- API response'una yazılmaz
	IBANSet              bool
	PaymentDueDays       *int
	CreatedAt            time.Time
	UpdatedAt            time.Time
}
