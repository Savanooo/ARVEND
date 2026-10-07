package domain

import (
	"fmt"
	"math"
	"time"

	"github.com/shopspring/decimal"
)

// Package-level not: Metraj Hesaplama (malzeme miktarı hesaplama) modülü.
//
// BYZ (eski Flask/Mongo sistem) analizinden yeniden tasarlandı -- BİREBİR
// PORT DEĞİL. Bu dosyadaki fonksiyonlar (ComputeGeometry,
// ComputeRecipeQuantity) hesap MOTORUDUR: saf, yan etkisiz, veritabanına
// erişmez -- bkz. service.CalcService.Run, DB okumalarını (kategori,
// reçete, ürün) yapıp bu fonksiyonları çağıran orkestrasyon katmanıdır.
//
// PARA/MİKTAR ARİTMETİĞİ: Go float64 KULLANILMAZ -- shopspring/decimal
// (ondalık tabanlı, kayıpsız) kullanılır. Bu, ARVEND'in "SQL numeric,
// asla Go float64" ilkesinin (bkz. project_change_order_service.go,
// ChangeOrderApprovalWouldGoNegative) salt-okur/DB'siz test edilebilir
// bir motor için doğal genişlemesidir -- pgtype.Numeric <-> decimal.Decimal
// dönüşümü KAYIPSIZDIR (ikisi de aynı iç temsili kullanır: katsayı
// *big.Int + üs int32, bkz. repository.NumericToDecimal). Yalnızca TEK
// bir yer gerçek float64 kullanır: çatı eğimi çarpanı (math.Cos) --
// çünkü trigonometri hiçbir sabit noktalı sistemde tam temsil edilemez;
// bu parasal bir yuvarlama kararı DEĞİL, geometrik bir ölçek faktörüdür
// ve BYZ'nin kendi (istemcideki) /cos() hesabıyla birebir aynı formüldür
// -- yalnızca artık sunucuda, istemciye güvenilmeden hesaplanır.

// --- calculation_type ---
const (
	CalcTypeAreaBased      = "area_based"
	CalcTypePerimeterBased = "perimeter_based"
	CalcTypeFixed          = "fixed"
)

func ValidCalcType(s string) bool {
	return s == CalcTypeAreaBased || s == CalcTypePerimeterBased || s == CalcTypeFixed
}

// --- rounding_type ---
const (
	RoundingNone  = "none"
	RoundingCeil  = "ceil"
	RoundingRound = "round"
)

func ValidRoundingType(s string) bool {
	return s == RoundingNone || s == RoundingCeil || s == RoundingRound
}

type CalcGroup struct {
	ID             string
	OrganizationID string
	Slug           string
	Name           string
	Description    string
	SortOrder      int
	IsActive       bool
	CreatedAt      time.Time
	UpdatedAt      time.Time
}

type CalcCategory struct {
	ID             string
	OrganizationID string
	GroupID        string
	Slug           string
	Name           string
	Description    string
	ImageFileID    *string
	SortOrder      int
	IsActive       bool
	CreatedAt      time.Time
	UpdatedAt      time.Time

	// GroupSlug/GroupLabel/GroupSortOrder, YALNIZCA gruplu liste
	// sorgusunda (ListActiveCalcCategoriesForOrg) JOIN ile doldurulur --
	// kolon DEĞİLDİR.
	GroupSlug      string
	GroupLabel     string
	GroupSortOrder int
}

type CalcRecipeItem struct {
	ID                 string
	OrganizationID     string
	CategoryID         string
	ProductID          *string
	MaterialName       string
	Unit               string
	CalculationType    string
	QuantityPerM2      decimal.Decimal
	QuantityPerMeter   decimal.Decimal
	FixedQuantity      decimal.Decimal
	WastePercent       decimal.Decimal
	RoundingType       string
	MinQuantity        *decimal.Decimal
	PackageSize        *decimal.Decimal
	ReferenceUnitPrice decimal.Decimal
	GroupName          string
	SortOrder          int
	IsActive           bool
	Notes              *string
	CreatedAt          time.Time
	UpdatedAt          time.Time
}

// --- Hesap girdisi ---

// CalcInput, /calculations/run isteğinin girdisidir. Alan (area) ve
// çevre (perimeter) BİLİNÇLİ OLARAK BAĞIMSIZDIR -- BYZ'de alan
// verildiğinde çevre HİÇBİR ZAMAN hesaplanmıyordu (bkz.
// docs/byz-metraj-hesaplama-analizi.md §11.1 madde 2); burada çağıran
// ikisini birlikte de gönderebilir (bir kategori hem area_based hem
// perimeter_based kalem taşıyabilir).
type CalcInput struct {
	Area      *decimal.Decimal
	Width     *decimal.Decimal
	Height    *decimal.Decimal
	Perimeter *decimal.Decimal
	PitchDeg  *decimal.Decimal
}

type CalcGeometry struct {
	FootprintArea decimal.Decimal
	EffectiveArea decimal.Decimal
	// Perimeter, bilinmiyorsa nil'dir (ne perimeter ne de width+height
	// verilmiş) -- perimeter_based kalemler bu durumda sessizce 0 ÜRETMEZ,
	// bkz. ComputeRecipeQuantity.
	Perimeter *decimal.Decimal
}

type CalcWarning struct {
	ItemID  string `json:"item_id,omitempty"`
	Code    string `json:"code"`
	Message string `json:"message"`
}

// --- birim fiyat kaynağı ---
//
// Yeni firmalar reçete kalemleri ürüne bağlanmadan (ya da fiyatsız ürünlerle)
// açılıyor; eskiden bu satırların hepsi 0 TL hesaplanıyor ve reçetedeki
// reference_unit_price hiç kullanılmıyordu -- metraj sonucu ve ondan
// oluşturulan teklif sessizce 0 TL kalıyordu.
const (
	CalcPriceSourceProduct   = "product"   // bağlı ürünün fiyatı (> 0)
	CalcPriceSourceReference = "reference" // ürün fiyatı yok/0: reçetenin referans fiyatı
	CalcPriceSourceNone      = "none"      // ikisi de yok: 0 kabul edildi
)

// Satırdaki kısa Türkçe uyarı -- istemciler satırın yanında gösterir.
const (
	CalcPriceWarningReference = "referans fiyat kullanıldı"
	CalcPriceWarningNone      = "fiyat yok"
)

// ResolveCalcUnitPrice, bir reçete satırının birim fiyatını seçer: bağlı
// ürünün fiyatı > 0 ise o; değilse (ürün yok, bağlı değil ya da 0 TL)
// reçetenin referans fiyatı > 0 ise o; ikisi de yoksa 0. productPrice nil =
// satırın çözülmüş bir ürünü yok. warning, ürün fiyatı kullanılmadıysa
// doludur.
func ResolveCalcUnitPrice(productPrice *decimal.Decimal, referencePrice decimal.Decimal) (price decimal.Decimal, source, warning string) {
	if productPrice != nil && productPrice.IsPositive() {
		return *productPrice, CalcPriceSourceProduct, ""
	}
	if referencePrice.IsPositive() {
		return referencePrice, CalcPriceSourceReference, CalcPriceWarningReference
	}
	return decimal.Zero, CalcPriceSourceNone, CalcPriceWarningNone
}

type CalcResultItem struct {
	RecipeItemID string
	MaterialName string
	Unit         string
	Quantity     decimal.Decimal
	ProductID    *string
	UnitPrice    decimal.Decimal
	LineTotal    decimal.Decimal
	GroupName    string

	// PriceSource: CalcPriceSource* -- UnitPrice nereden geldi.
	// PriceWarning: ürün fiyatı kullanılamadıysa kısa Türkçe sebep
	// (CalcPriceWarning*), aksi halde "".
	PriceSource  string
	PriceWarning string

	// CalculationType/Factor/WastePercent/RoundingType: bu kalemin
	// hesabında GERÇEKTEN kullanılan katsayı/kural -- Teklif entegrasyonu
	// (Faz M2) bunları calc_snapshot'a dondurur ki kategori/reçete
	// sonradan değişse bile "o an ne hesaplandı" sorusu yanıtlanabilsin.
	// Factor, calculation_type'a göre quantity_per_m2 | quantity_per_meter
	// | fixed_quantity alanlarından YALNIZCA gerçekten kullanılanıdır.
	CalculationType string
	Factor          decimal.Decimal
	WastePercent    decimal.Decimal
	RoundingType    string
}

type CalcResult struct {
	Category  CalcCategory
	Geometry  CalcGeometry
	Items     []CalcResultItem
	TotalCost decimal.Decimal
	Warnings  []CalcWarning
}

// ComputeGeometry, alan/çevre/eğim girdilerinden geometriyi SUNUCU
// TARAFINDA türetir -- istemcinin (frontend'in) /cos() hesabına
// güvenilmez, aynı formül burada tekrar uygulanır.
//
// Adversarial not: bir alan POINTER'I doluysa (nil DEĞİLSE) ama değeri
// <= 0 ise bu "verilmemiş" sayılıp sessizce bir sonraki kaynağa
// düşülmez -- açık bir doğrulama hatası döner. Aksi halde ör. "area": "-5"
// yanlışlıkla "area verilmedi, width+height'e bak" olarak yorumlanabilir
// ve kullanıcıya yanıltıcı bir hata mesajı ("alan bilgisi eksik")
// gösterirdi.
func ComputeGeometry(in CalcInput) (CalcGeometry, error) {
	if in.Area != nil && !in.Area.IsPositive() {
		return CalcGeometry{}, fmt.Errorf("'area' 0'dan büyük olmalı")
	}
	if in.Width != nil && !in.Width.IsPositive() {
		return CalcGeometry{}, fmt.Errorf("'width' 0'dan büyük olmalı")
	}
	if in.Height != nil && !in.Height.IsPositive() {
		return CalcGeometry{}, fmt.Errorf("'height' 0'dan büyük olmalı")
	}
	if in.Perimeter != nil && !in.Perimeter.IsPositive() {
		return CalcGeometry{}, fmt.Errorf("'perimeter' 0'dan büyük olmalı")
	}
	haveWH := in.Width != nil && in.Height != nil

	var footprint decimal.Decimal
	switch {
	case in.Area != nil:
		footprint = *in.Area
	case haveWH:
		footprint = in.Width.Mul(*in.Height)
	default:
		return CalcGeometry{}, fmt.Errorf("alan bilgisi eksik: 'area' ya da 'width' + 'height' girin")
	}

	var perimeter *decimal.Decimal
	switch {
	case in.Perimeter != nil:
		p := *in.Perimeter
		perimeter = &p
	case haveWH:
		p := in.Width.Add(*in.Height).Mul(decimal.NewFromInt(2))
		perimeter = &p
	}

	effective := footprint
	if in.PitchDeg != nil {
		deg, _ := in.PitchDeg.Float64()
		if deg > 0 && deg < 90 {
			factor := math.Cos(deg * math.Pi / 180)
			if factor > 0 {
				effective = footprint.Div(decimal.NewFromFloat(factor))
			}
		}
	}

	return CalcGeometry{FootprintArea: footprint, EffectiveArea: effective, Perimeter: perimeter}, nil
}

// recipeCoefficientPrecision, calc_recipe_items.quantity_per_m2/
// quantity_per_meter kolonlarının ondalık hanesiyle (numeric(14,6))
// eşleşir -- ceil/none çıktısını bu haneye yuvarlamak, ondalık bölmeden
// (ör. 1/3.6) doğan gerçek-olmayan kesirli basamakların (decimal'de
// float64 gibi ikili temsil hatası YOKTUR ama 1/3.6 taban-10'da da devirli
// bir kesirdir) bir paket fazla/eksik çıkarmasını önler -- BYZ'nin
// round(value,9) korumasının kasıtlı ve prensipli karşılığı.
const recipeCoefficientPrecision = 6

// ComputeRecipeQuantity, TEK bir reçete kaleminin nihai miktarını
// hesaplar. Sıra (kullanıcı talimatıyla birebir): taban miktar
// (calculation_type'a göre) -> fire -> minimum -> paket -> (paket yoksa)
// yuvarlama.
//
// BYZ'den KASITLI FARKLAR (docs/byz-metraj-hesaplama-analizi.md §11.1):
//   - Fire GERÇEKTEN uygulanır (BYZ'de waste_percentage yazılıyordu ama
//     motor tarafından hiç okunmuyordu).
//   - min_quantity/package_size ilk sınıf alanlardır (BYZ bunları
//     "quantity_per_m2 = 1/paket_kapsamı + rounding=ceil" gibi dolaylı,
//     paket SAYISINI miktar sanan bir kalıpla taklit ediyordu).
//   - perimeter_based bir kalemde çevre bilinmiyorsa SESSİZCE 0 üretmez
//     -- açık bir warning döner (item quantity yine de 0'dır, ama
//     çağıran bunu görür).
func ComputeRecipeQuantity(item CalcRecipeItem, geo CalcGeometry) (decimal.Decimal, *CalcWarning) {
	var base decimal.Decimal

	switch item.CalculationType {
	case CalcTypeAreaBased:
		base = geo.EffectiveArea.Mul(item.QuantityPerM2)
	case CalcTypePerimeterBased:
		if geo.Perimeter == nil {
			return decimal.Zero, &CalcWarning{
				ItemID: item.ID, Code: "perimeter_missing",
				Message: fmt.Sprintf(
					"%q çevre bazlı hesaplanıyor ama istekte çevre (perimeter) bilgisi yok; miktar 0 döndü.",
					item.MaterialName),
			}
		}
		base = geo.Perimeter.Mul(item.QuantityPerMeter)
	case CalcTypeFixed:
		base = item.FixedQuantity
	default:
		// DB CHECK kısıtı bu durumu engeller; savunma amaçlı.
		return decimal.Zero, &CalcWarning{
			ItemID: item.ID, Code: "unknown_calculation_type",
			Message: fmt.Sprintf("%q için tanınmayan calculation_type %q; miktar 0 döndü.",
				item.MaterialName, item.CalculationType),
		}
	}

	withWaste := base
	if item.WastePercent.GreaterThan(decimal.Zero) {
		withWaste = base.Mul(decimal.NewFromInt(1).Add(item.WastePercent.Div(decimal.NewFromInt(100))))
	}

	withMin := withWaste
	if item.MinQuantity != nil && item.MinQuantity.GreaterThan(withWaste) {
		withMin = *item.MinQuantity
	}

	// Paket kuralı, verildiğinde yuvarlama tipinin YERİNE geçer.
	//
	// package_size, "bir paketin kapsadığı ham miktar"dır (item.Unit
	// zaten paketin kendisidir -- paket/rulo/top/torba/teneke); çıktı
	// PAKET SAYISIDIR, ham miktarın paket katına yuvarlanmış hâli
	// DEĞİLDİR. Bu, BYZ'nin "quantity_per_m2 = 1/kapsama_alanı +
	// rounding=ceil" dolaylı kalıbının (aynı paket sayısını üreten ama
	// katsayıyı devirli bir ondalık kesir olarak saklayan) doğrudan ve
	// kesin (hiçbir yuvarlama-gürültüsü riski taşımayan) karşılığıdır:
	// ör. "3cm Taşyünü" artık quantity_per_m2=1, package_size=3.6,
	// unit=paket olarak modellenir; 10.8 m² için 10.8/3.6 = TAM 3 paket
	// (bkz. BYZ_ANALYSIS_IMPORT.md "paket dönüşümleri").
	if item.PackageSize != nil && item.PackageSize.GreaterThan(decimal.Zero) {
		return withMin.Div(*item.PackageSize).Round(recipeCoefficientPrecision).Ceil(), nil
	}

	switch item.RoundingType {
	case RoundingCeil:
		return withMin.Round(recipeCoefficientPrecision).Ceil(), nil
	case RoundingRound:
		return withMin.Round(2), nil
	default: // "none" -- yalnızca GÖRÜNTÜLEME hassasiyeti, bir iş kuralı değil.
		return withMin.Round(recipeCoefficientPrecision), nil
	}
}
