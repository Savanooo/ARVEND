package domain

import (
	"errors"
	"time"

	"github.com/shopspring/decimal"
)

// Tedarikçi fiyat kaynakları (migration 0045). Şimdilik tek kaynak Ulaş;
// organization_price_sources.source CHECK'i ile aynı küme.
const (
	PriceSourceUlas = "ulas"

	PriceSyncStatusNever   = "never"
	PriceSyncStatusSuccess = "success"
	PriceSyncStatusFailed  = "failed"

	// Senkron/yeniden hesaplamanın product_price_history.note değerleri.
	PriceHistoryNoteUlasSync   = "Ulaş fiyat listesi"
	PriceHistoryNoteUlasMarkup = "Ulaş kâr oranı güncellendi"

	OrgEventPriceSourceUpdated = "price_source_updated"
	OrgEventPriceSourceSynced  = "price_source_synced"
)

// DefaultPriceSourceMarkup, firmanın satırı yokken geçerli kâr oranıdır
// (BYZ'deki sabit MARKUP = 1.15 ile aynı).
var (
	DefaultPriceSourceMarkup = decimal.NewFromInt(15)
	MaxPriceSourceMarkup     = decimal.NewFromInt(1000)
)

var (
	ErrUnknownPriceSource = errors.New("fiyat kaynağı bulunamadı")
	// ErrPriceSyncBusy: aynı firma+kaynak için başka bir senkron (ya da kâr
	// oranı güncellemesi) şu an çalışıyor.
	ErrPriceSyncBusy = errors.New("bu fiyat kaynağı için şu anda başka bir senkron çalışıyor, biraz sonra tekrar deneyin")
	// ErrPriceSourceFetch: tedarikçi sayfası indirilemedi/ayrıştırılamadı --
	// üründe HİÇBİR şey değişmez, hata organization_price_sources'a yazılır.
	ErrPriceSourceFetch = errors.New("tedarikçi fiyat listesi alınamadı; lütfen daha sonra tekrar deneyin")
)

func PriceSourceName(source string) string {
	if source == PriceSourceUlas {
		return "Ulaş"
	}
	return source
}

func ValidPriceSource(source string) bool {
	return source == PriceSourceUlas
}

// ApplyMarkup: birim fiyat = kaynak fiyat x (1 + oran/100), 2 ondalığa
// yarım yukarı yuvarlanır. Tamamen ondalık aritmetik (float yok): 500 @ %15
// = 575.00; 333.33 @ %12.5 = 374.99625 -> 375.00. Senkron da yeniden
// hesaplama da YALNIZCA bu fonksiyonu kullanır.
func ApplyMarkup(sourcePrice, markupPercent decimal.Decimal) decimal.Decimal {
	return sourcePrice.Mul(decimal.NewFromInt(100).Add(markupPercent)).Shift(-2).Round(2)
}

type PriceSourceCategoryMarkup struct {
	Category      string
	MarkupPercent decimal.Decimal
}

type PriceSourceCategory struct {
	Category     string
	ProductCount int
}

// PriceSourceOverview, bir firmanın bir kaynak için ayarları + son senkron
// sonucu + kataloğun o kaynaktan gelen kısmının özeti.
type PriceSourceOverview struct {
	Source          string
	MarkupPercent   decimal.Decimal
	AutoSync        bool
	LastSyncedAt    *time.Time
	LastStatus      string
	LastError       string
	LastResult      PriceSyncResult
	UpdatedAt       *time.Time
	CategoryMarkups []PriceSourceCategoryMarkup
	Categories      []PriceSourceCategory
	ProductCount    int
	MissingCount    int
}

// PriceSyncResult: Total = listedeki tekil (ad, birim, kategori) sayısı =
// Created + Updated + Unchanged. Missing = firmanın listede artık
// bulunmayan (ama SİLİNMEYEN) kaynak ürünü sayısı.
type PriceSyncResult struct {
	Total     int
	Created   int
	Updated   int
	Unchanged int
	Missing   int
	SyncedAt  time.Time
}
