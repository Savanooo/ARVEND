package domain

import "time"

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

type OfferItem struct {
	ID          string
	ProductID   *string
	ProductName string
	Quantity    float64
	UnitPrice   float64
	LineTotal   float64
	SortOrder   int
}

type Offer struct {
	ID              string
	OfferNo         string
	CustomerName    string
	CustomerPhone   string
	CustomerEmail   string
	CustomerAddress string
	OfferDate       time.Time
	ValidUntil      *time.Time
	Subtotal        float64
	VatRate         float64
	VatAmount       float64
	GrandTotal      float64
	Notes           string
	Status          string
	IsPassive       bool
	CreatedBy       *string
	CreatedAt       time.Time
	UpdatedAt       time.Time
	Items           []OfferItem
}
