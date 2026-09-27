package domain

import (
	"errors"
	"slices"
	"time"

	"github.com/shopspring/decimal"
)

// Tedarikçi fiyat kaynakları (migration 0045/0046). Kod kümesi
// organization_price_sources.source CHECK'i ile aynıdır.
const (
	PriceSourceUlas        = "ulas"
	PriceSourceDemirProfil = "demirprofil"

	PriceSyncStatusNever   = "never"
	PriceSyncStatusSuccess = "success"
	PriceSyncStatusFailed  = "failed"

	// Ulaş senkronunun/yeniden hesaplamasının product_price_history.note
	// değerleri (migration 0046'daki geri doldurma bu metinlere dayanır).
	PriceHistoryNoteUlasSync    = "Ulaş fiyat listesi"
	PriceHistoryNoteUlasMarkup  = "Ulaş kâr oranı güncellendi"
	PriceHistoryNoteUlasReprice = "Ulaş fiyat listesi: tedarikçi fiyatı aynı, kâr oranı yeniden uygulandı"

	OrgEventPriceSourceUpdated = "price_source_updated"
	OrgEventPriceSourceSynced  = "price_source_synced"
)

// product_price_history.reason (migration 0046).
const (
	PriceChangeReasonManual   = "manual"   // elle ürün düzenleme
	PriceChangeReasonSupplier = "supplier" // tedarikçi listesi senkronu, tedarikçi fiyatı değişti (ya da ilk kez öğrenildi)
	PriceChangeReasonMarkup   = "markup"   // kâr oranı yeniden uygulandı: ayar değişikliği ya da tedarikçi fiyatı aynıyken senkron
)

// PriceSourceInfo, kayıt defterindeki bir tedarikçi kaynağının SABİT
// tanımıdır. Senkron, kâr oranı, eşleştirme, kilitler, gece işi ve hata
// kaydı kaynaktan bağımsızdır; kaynağa özgü olan yalnızca bu metinler ve
// indirici/ayrıştırıcıdır (service.PriceFetcher, pricesource.Fetch*).
type PriceSourceInfo struct {
	Code string
	// Name: arayüzde görünen ad; ShortName: hata/fiyat geçmişi metinlerinde.
	Name      string
	ShortName string
	SiteURL   string
	// VATNote: listedeki fiyatların KDV/kapsam esası (kullanıcıya gösterilir).
	VATNote string
	// SyncNote/MarkupNote: product_price_history.note (senkron / kâr oranı).
	// RepriceNote: senkronda tedarikçi fiyatı DEĞİŞMEDİĞİ hâlde satış fiyatı
	// değişen satırın notu (elle düzenleme geri alındı, kategori oranı
	// değişti) -- bu satırlar reason 'markup'tır, tedarikçi zammı sayılmaz.
	// Metinler sabittir: migration 0046'nın geri doldurması bunlara dayanır.
	SyncNote    string
	MarkupNote  string
	RepriceNote string
	// AttributionHost: kaynağın kullanım koşulu kaynak gösterimi istiyorsa
	// site adı (Demir Profil: "kaynak gösterirken ... ayı belirtin"); aksi "".
	AttributionHost string
}

var priceSourceRegistry = []PriceSourceInfo{
	{
		Code:        PriceSourceUlas,
		Name:        "Ulaş",
		ShortName:   "Ulaş",
		SiteURL:     "https://ulas.com.tr",
		VATNote:     "KDV durumu listede belirtilmiyor",
		SyncNote:    PriceHistoryNoteUlasSync,
		MarkupNote:  PriceHistoryNoteUlasMarkup,
		RepriceNote: PriceHistoryNoteUlasReprice,
	},
	{
		Code:            PriceSourceDemirProfil,
		Name:            "Demir Profil (Omega Çelik)",
		ShortName:       "Demir Profil",
		SiteURL:         "https://www.demirprofil.com.tr",
		VATNote:         "KDV hariç, toptan liste fiyatı; kesim ve nakliye hariç",
		SyncNote:        "Demir Profil fiyat listesi",
		MarkupNote:      "Demir Profil kâr oranı güncellendi",
		RepriceNote:     "Demir Profil fiyat listesi: tedarikçi fiyatı aynı, kâr oranı yeniden uygulandı",
		AttributionHost: "demirprofil.com.tr",
	},
}

// PriceSources, kayıtlı tüm kaynakları sabit sırayla (API'deki sıra) döner.
func PriceSources() []PriceSourceInfo {
	return slices.Clone(priceSourceRegistry)
}

func LookupPriceSource(code string) (PriceSourceInfo, bool) {
	for _, s := range priceSourceRegistry {
		if s.Code == code {
			return s, true
		}
	}
	return PriceSourceInfo{}, false
}

func ValidPriceSource(code string) bool {
	_, ok := LookupPriceSource(code)
	return ok
}

func PriceSourceName(code string) string {
	if s, ok := LookupPriceSource(code); ok {
		return s.Name
	}
	return code
}

// SyncHistoryNote: senkronun fiyat geçmişi notu; liste dönemi varsa eklenir
// ("Demir Profil fiyat listesi (Eylül 2026)"). Ulaş dönem vermez -> sabit not.
func (s PriceSourceInfo) SyncHistoryNote(listLabel string) string {
	if listLabel == "" {
		return s.SyncNote
	}
	return s.SyncNote + " (" + listLabel + ")"
}

// Attribution: kaynak gösterimi metni ("Kaynak: demirprofil.com.tr — Eylül
// 2026 listesi"); kaynak gösterim istemiyorsa "".
func (s PriceSourceInfo) Attribution(listLabel string) string {
	if s.AttributionHost == "" {
		return ""
	}
	if listLabel == "" {
		return "Kaynak: " + s.AttributionHost
	}
	return "Kaynak: " + s.AttributionHost + " — " + listLabel + " listesi"
}

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
	// ErrPriceListTooShort: liste indi ama firmanın son başarılı senkronunun
	// yarısından az ürün içeriyor (yarım/bozuk liste) -- hiçbir şey değişmez.
	ErrPriceListTooShort = errors.New("tedarikçi fiyat listesi beklenenden çok kısa geldi; fiyatlar değiştirilmedi")
)

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
	// ListLabel: son başarılı senkronun liste dönemi ("Eylül 2026"; yoksa "").
	ListLabel string
	// LastChanges: son başarılı senkronda fiyatı artan/azalan ürünler (o
	// senkronun fiyat geçmişinden); hiç başarılı senkron yoksa nil.
	LastChanges *PriceSyncChangeStats
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
	// ListLabel: indirilen listenin dönemi (Demir Profil "Eylül 2026").
	ListLabel string
}

// PriceSyncChangeStats: tek bir senkronda satış fiyatı artan/azalan ürün
// sayısı ve artanların ortalama artış yüzdesi (artış yoksa nil).
type PriceSyncChangeStats struct {
	Increased          int
	Decreased          int
	AvgIncreasePercent *decimal.Decimal
}

// PriceChange, zam geçmişinin tek satırıdır (bir ürünün bir fiyat
// değişikliği). ChangePercent eski fiyat 0 ise nil. Kaynak (tedarikçi)
// fiyatları yalnızca senkron/kâr oranı satırlarında dolu olabilir.
type PriceChange struct {
	ID             string
	ProductID      string
	ProductName    string
	Unit           string
	Category       string
	Source         string // "" = elle düzenleme
	Reason         string
	Note           string
	OldPrice       decimal.Decimal
	NewPrice       decimal.Decimal
	ChangeAmount   decimal.Decimal
	ChangePercent  *decimal.Decimal
	ChangedAt      time.Time
	OldSourcePrice *decimal.Decimal
	NewSourcePrice *decimal.Decimal
}

// PriceChangeSummary, bir zaman aralığındaki fiyat değişikliklerinin özeti.
type PriceChangeSummary struct {
	IncreasedCount     int
	DecreasedCount     int
	ProductsIncreased  int
	AvgIncreasePercent *decimal.Decimal
	MaxIncrease        *PriceChangeMaxIncrease
	Events             []PriceChangeEvent
}

type PriceChangeMaxIncrease struct {
	ProductID     string
	ProductName   string
	ChangePercent decimal.Decimal
}

// PriceChangeEvent: aynı transaction'da yazılan değişiklikler (tek bir
// senkron ya da kâr oranı güncellemesi); elle düzenlemeler gün başına.
type PriceChangeEvent struct {
	ChangedAt time.Time
	// RangeFrom/RangeTo: olayın satırlarını listede süzmek için KAPALI
	// aralık [RangeFrom, RangeTo] (liste ucunun from/to'suna aynen verilir;
	// to an DAHİL). Senkron/kâr oranı olayında ikisi de ChangedAt; elle
	// düzenleme gününde o İstanbul günü (özetin aralığıyla kırpılmış).
	RangeFrom          time.Time
	RangeTo            time.Time
	Source             string // "" = elle düzenleme
	Reason             string
	ChangeCount        int
	Increased          int
	Decreased          int
	AvgChangePercent   *decimal.Decimal
	MaxIncreasePercent *decimal.Decimal
}
