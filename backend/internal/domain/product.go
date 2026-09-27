package domain

import (
	"strings"
	"time"
)

type Product struct {
	ID             string
	OrganizationID string
	Name           string
	NormalizedName string
	Unit           string
	UnitPrice      float64
	Description    string
	Category       string
	Source         string
	SourcePrice    *float64
	// SourceSyncedAt, ürünün kaynak fiyat listesinde en son görüldüğü an
	// (yalnızca senkronla gelen ürünlerde dolu, bkz. migration 0045).
	SourceSyncedAt *time.Time
	CreatedAt      time.Time
	UpdatedAt      time.Time
}

type PriceHistoryEntry struct {
	ID        string
	ProductID string
	OldPrice  float64
	NewPrice  float64
	Note      string
	ChangedAt time.Time
	// Reason: manual | supplier | markup; Source: tedarikçi kodu (elle
	// düzenlemede ""). Kaynak fiyatları yalnızca senkron/kâr oranı
	// satırlarında (0046'dan sonra) dolu olabilir.
	Reason         string
	Source         string
	OldSourcePrice *float64
	NewSourcePrice *float64
}

var trFold = strings.NewReplacer(
	"İ", "i", "I", "i", "ı", "i",
	"Ş", "s", "ş", "s",
	"Ğ", "g", "ğ", "g",
	"Ü", "u", "ü", "u",
	"Ö", "o", "ö", "o",
	"Ç", "c", "ç", "c",
)

// NormalizeName, arama ve mükerrer ürün tespiti için Türkçe karakterleri
// katlar ve küçük harfe çevirir (BYZ'deki normalized_name deseniyle aynı).
func NormalizeName(name string) string {
	return strings.ToLower(trFold.Replace(strings.TrimSpace(name)))
}
