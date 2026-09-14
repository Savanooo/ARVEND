package domain

import (
	"encoding/json"
	"time"
)

const (
	OfferStatusTaslak      = "taslak"
	OfferStatusGonderildi  = "gönderildi"
	OfferStatusKabulEdildi = "kabul edildi"
	OfferStatusReddedildi  = "reddedildi"
)

var validOfferStatuses = map[string]bool{
	OfferStatusTaslak:      true,
	OfferStatusGonderildi:  true,
	OfferStatusKabulEdildi: true,
	OfferStatusReddedildi:  true,
}

func ValidOfferStatus(s string) bool {
	return validOfferStatuses[s]
}

const (
	DiscountNone    = "none"
	DiscountPercent = "percent"
	DiscountFixed   = "fixed"
)

type OfferItem struct {
	ID            string
	ProductID     *string
	ProductName   string
	Quantity      float64
	UnitPrice     float64
	DiscountType  string
	DiscountValue float64
	LineTotal     float64
	SortOrder     int

	// Unit/SectionLabel/CalcCategoryID/CalcSnapshot: Metraj Hesaplama
	// entegrasyonu (Faz M2). Serbest/elle girilen kalemlerde Unit boş,
	// diğerleri nil'dir. CalcSnapshot, hesap ANINDAKİ dondurulmuş
	// görünümdür (area/perimeter/pitch_deg/factor/waste/rounding/
	// price_at_calc) -- kategori/reçete sonradan değişse/silinse bile
	// bu kalem üzerinde HİÇBİR ZAMAN güncellenmez (offer_revisions'ın
	// "geçmişi mutate etme" ilkesiyle aynı).
	Unit           string
	SectionLabel   *string
	CalcCategoryID *string
	CalcSnapshot   json.RawMessage
}

// Offer, teklifin kimliğini ve lifecycle bilgisini taşır -- gerçek içerik
// (müşteri, kalemler, toplamlar) artık CurrentRevisionID üzerinden
// offer_revisions'ta yaşar. Geriye dönük API uyumluluğu için bu struct
// hâlâ "düz" bir görünüm sunar: aşağıdaki içerik alanları servis
// katmanında mevcut revizyondan doldurulur (bkz. repository.MergeOffer).
type Offer struct {
	ID                string
	OrganizationID    string
	OfferNo           string
	OfferDate         time.Time
	CurrentRevisionID string
	Status            string
	IsPassive         bool
	CreatedBy         *string
	CreatedAt         time.Time
	UpdatedAt         time.Time

	// İçerik alanları -- mevcut revizyondan doldurulur.
	RevisionNo      int
	CustomerID      *string
	CustomerName    string
	CustomerPhone   string
	CustomerEmail   string
	CustomerAddress string
	ValidUntil      *time.Time
	Subtotal        float64
	DiscountType    string
	DiscountValue   float64
	DiscountAmount  float64
	VatRate         float64
	VatAmount       float64
	GrandTotal      float64
	Currency        string
	Notes           string
	Items           []OfferItem
}

// OfferRevision, bir teklifin belirli bir andaki değişmez anlık
// görüntüsüdür. Revizyon 0 teklif oluşturulduğunda otomatik açılır;
// sonraki her revizyon yalnızca "Revize Et" ile ve yalnızca teklif zaten
// müşteriye gönderilmiş/reddedilmişse oluşur.
type OfferRevision struct {
	ID              string
	OrganizationID  string
	OfferID         string
	RevisionNo      int
	CustomerID      *string
	CustomerName    string
	CustomerPhone   string
	CustomerEmail   string
	CustomerAddress string
	ValidUntil      *time.Time
	Subtotal        float64
	DiscountType    string
	DiscountValue   float64
	DiscountAmount  float64
	VatRate         float64
	VatAmount       float64
	GrandTotal      float64
	Currency        string
	Notes           string
	Status          string
	CreatedBy       *string
	CreatedAt       time.Time
	Items           []OfferItem
}
