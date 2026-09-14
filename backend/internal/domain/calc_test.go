package domain_test

// Golden testler: BYZ Metraj Hesaplama analiz raporundaki (bkz.
// docs/byz-metraj-hesaplama-analizi.md §10) GERÇEK reçete verisiyle
// yeniden üretilmiş, elle doğrulanmış sayısal senaryolar. DB gerektirmez
// -- motor (domain.ComputeGeometry / domain.ComputeRecipeQuantity) saf
// fonksiyonlardır.

import (
	"testing"

	"github.com/shopspring/decimal"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
)

func d(s string) decimal.Decimal { return decimal.RequireFromString(s) }

func dPtr(s string) *decimal.Decimal { v := d(s); return &v }

// petekTavanRecipe, BYZ material_calculation_service.py:1388-1398'deki
// "10x10-petek-tavan" reçetesinin BİREBİR (qty/price/unit) karşılığıdır
// -- yalnızca ARVEND alanlarına taşınmıştır (calculation_type=area_based,
// waste_percent=0, rounding_type=none: BYZ seed'inde hiçbiri yoktu).
func petekTavanRecipe() []domain.CalcRecipeItem {
	mk := func(name, unit, qty, price string) domain.CalcRecipeItem {
		return domain.CalcRecipeItem{
			MaterialName: name, Unit: unit, CalculationType: domain.CalcTypeAreaBased,
			QuantityPerM2: d(qty), WastePercent: decimal.Zero, RoundingType: domain.RoundingNone,
			ReferenceUnitPrice: d(price),
		}
	}
	return []domain.CalcRecipeItem{
		mk("10x10 Petek Tavan", "adet", "5", "230"),
		mk("3600 mm Ana Taşıyıcı", "adet", "1", "110"),
		mk("Tali Taşıyıcı 60cm", "adet", "6", "30"),
		mk("Tali Taşıyıcı 120cm", "adet", "6", "60"),
		mk("L Köşebent 3000 mm", "adet", "2", "70"),
		mk("Çelik Dübel", "adet", "3", "4"),
		mk("Askı Teli 40cm", "adet", "6", "4"),
		mk("Çift Yaylı Maşa", "adet", "3", "3"),
		mk("Dübel Vida", "paket", "1", "170"),
	}
}

// TestGolden_PetekTavan20m2, rapordaki §10 örneğinin doğrulayıcı tarafından
// bağımsızca yeniden hesaplanmış hâlidir: 20 m² için beklenen miktarlar
// 100/20/120/120/40/60/120/60/20, referans fiyatlarla toplam 43.100,00 TL.
func TestGolden_PetekTavan20m2(t *testing.T) {
	geo, err := domain.ComputeGeometry(domain.CalcInput{Area: dPtr("20")})
	if err != nil {
		t.Fatalf("ComputeGeometry: %v", err)
	}
	if !geo.EffectiveArea.Equal(d("20")) {
		t.Fatalf("effective area = %s, istenen 20", geo.EffectiveArea)
	}
	if geo.Perimeter != nil {
		t.Fatalf("yalnız area verildiğinde perimeter nil olmalı, geldi: %s", geo.Perimeter)
	}

	wantQty := []string{"100", "20", "120", "120", "40", "60", "120", "60", "20"}
	total := decimal.Zero
	for i, item := range petekTavanRecipe() {
		qty, warn := domain.ComputeRecipeQuantity(item, geo)
		if warn != nil {
			t.Fatalf("kalem %d (%s): beklenmeyen warning: %+v", i, item.MaterialName, warn)
		}
		if !qty.Equal(d(wantQty[i])) {
			t.Errorf("kalem %d (%s): miktar = %s, istenen %s", i, item.MaterialName, qty, wantQty[i])
		}
		lineTotal := qty.Mul(item.ReferenceUnitPrice).Round(2)
		total = total.Add(lineTotal) // ZATEN yuvarlanmış satırların toplamı -- bkz. domain.go yorumu
	}
	total = total.Round(2)
	if !total.Equal(d("43100.00")) {
		t.Fatalf("toplam = %s, istenen 43100.00 (43.100,00 TL)", total)
	}
}

// TestGolden_WidthHeightDerivesAreaAndPerimeter: width=5, height=4 ->
// area=20, perimeter=18 (2*(5+4)).
func TestGolden_WidthHeightDerivesAreaAndPerimeter(t *testing.T) {
	geo, err := domain.ComputeGeometry(domain.CalcInput{Width: dPtr("5"), Height: dPtr("4")})
	if err != nil {
		t.Fatalf("ComputeGeometry: %v", err)
	}
	if !geo.FootprintArea.Equal(d("20")) {
		t.Errorf("footprint area = %s, istenen 20", geo.FootprintArea)
	}
	if !geo.EffectiveArea.Equal(d("20")) {
		t.Errorf("effective area = %s, istenen 20", geo.EffectiveArea)
	}
	if geo.Perimeter == nil || !geo.Perimeter.Equal(d("18")) {
		t.Errorf("perimeter = %v, istenen 18", geo.Perimeter)
	}
}

// TestGolden_AreaAndWidthHeightTogether: BYZ'nin aksine (rapor §11.1
// madde 2: "alan verildiğinde çevre asla hesaplanmıyordu"), area VE
// width+height birlikte verilirse artık her ikisi de kullanılır: alan
// doğrudan alınır, çevre yine width+height'ten türetilir.
func TestGolden_AreaAndWidthHeightTogether(t *testing.T) {
	geo, err := domain.ComputeGeometry(domain.CalcInput{Area: dPtr("25"), Width: dPtr("5"), Height: dPtr("4")})
	if err != nil {
		t.Fatalf("ComputeGeometry: %v", err)
	}
	if !geo.EffectiveArea.Equal(d("25")) {
		t.Errorf("effective area = %s, istenen 25 (area önceliklidir)", geo.EffectiveArea)
	}
	if geo.Perimeter == nil || !geo.Perimeter.Equal(d("18")) {
		t.Errorf("perimeter = %v, istenen 18 (width+height'ten türetilir, area varlığından etkilenmez)", geo.Perimeter)
	}
}

// TestGolden_PitchAppliedServerSide: pitch_deg backend'de uygulanır.
// 100 m² taban, 45° eğim -> effective_area = 100 / cos(45°) ≈ 141.42.
func TestGolden_PitchAppliedServerSide(t *testing.T) {
	geo, err := domain.ComputeGeometry(domain.CalcInput{Area: dPtr("100"), PitchDeg: dPtr("45")})
	if err != nil {
		t.Fatalf("ComputeGeometry: %v", err)
	}
	if geo.EffectiveArea.LessThanOrEqual(geo.FootprintArea) {
		t.Fatalf("eğimli effective area, footprint'ten büyük olmalı: %s vs %s", geo.EffectiveArea, geo.FootprintArea)
	}
	got, _ := geo.EffectiveArea.Round(2).Float64()
	if want := 141.42; got < want-0.01 || got > want+0.01 {
		t.Errorf("effective area = %.4f, istenen ~%.2f (100/cos(45°))", got, want)
	}
	// pitch=0 veya nil ise hiç çarpan uygulanmamalı.
	geoFlat, err := domain.ComputeGeometry(domain.CalcInput{Area: dPtr("100"), PitchDeg: dPtr("0")})
	if err != nil {
		t.Fatalf("ComputeGeometry (pitch=0): %v", err)
	}
	if !geoFlat.EffectiveArea.Equal(d("100")) {
		t.Errorf("pitch=0 iken effective area = %s, istenen 100 (çarpan uygulanmamalı)", geoFlat.EffectiveArea)
	}
}

// TestGolden_PackageRounding_TasyunuTarzi: BYZ'nin "3cm Taşyünü" kalemi
// (rulo/paket kapsama alanı 3.6 m², rounding=ceil) burada quantity_per_m2=1
// + package_size=3.6 olarak modellenir -- çıktı PAKET SAYISIDIR.
// 10.8 m² için 10.8/3.6 = TAM 3 (BYZ'nin kendi örneği, material_calculation_service.py
// yorumu: "10.8 m² * (1/3.6) = 3.0000000000000004 -> ceil 4 olurdu (doğru: 3)").
func TestGolden_PackageRounding_TasyunuTarzi(t *testing.T) {
	item := domain.CalcRecipeItem{
		MaterialName: "3cm Taşyünü", Unit: "paket", CalculationType: domain.CalcTypeAreaBased,
		QuantityPerM2: d("1"), PackageSize: dPtr("3.6"), RoundingType: domain.RoundingCeil, // rounding_type paket varken yok sayılır
	}
	geo, err := domain.ComputeGeometry(domain.CalcInput{Area: dPtr("10.8")})
	if err != nil {
		t.Fatalf("ComputeGeometry: %v", err)
	}
	qty, warn := domain.ComputeRecipeQuantity(item, geo)
	if warn != nil {
		t.Fatalf("beklenmeyen warning: %+v", warn)
	}
	if !qty.Equal(d("3")) {
		t.Fatalf("paket sayısı = %s, istenen 3 (BYZ float64 gürültüsüyle yanlışlıkla 4 üretiyordu)", qty)
	}
}

// TestGolden_PerimeterBased: perimeter*quantity_per_meter formülü.
func TestGolden_PerimeterBased(t *testing.T) {
	item := domain.CalcRecipeItem{
		MaterialName: "Kenar Profili", Unit: "m", CalculationType: domain.CalcTypePerimeterBased,
		QuantityPerMeter: d("1"), RoundingType: domain.RoundingNone,
	}
	geo, err := domain.ComputeGeometry(domain.CalcInput{Width: dPtr("5"), Height: dPtr("4")})
	if err != nil {
		t.Fatalf("ComputeGeometry: %v", err)
	}
	qty, warn := domain.ComputeRecipeQuantity(item, geo)
	if warn != nil {
		t.Fatalf("beklenmeyen warning: %+v", warn)
	}
	if !qty.Equal(d("18")) {
		t.Fatalf("miktar = %s, istenen 18 (perimeter=18 × 1)", qty)
	}
}

// TestGolden_PerimeterMissing_NoSilentZero: BYZ'de alan verildiğinde
// perimeter_based kalemler HİÇBİR uyarı olmadan sessizce 0 üretiyordu
// (rapor §11.1 madde 2, §5.7). Burada quantity yine 0'dır AMA açık bir
// warning döner -- çağıran bunu görmeden geçemez.
func TestGolden_PerimeterMissing_NoSilentZero(t *testing.T) {
	item := domain.CalcRecipeItem{
		ID: "item-1", MaterialName: "Kenar Profili", Unit: "m",
		CalculationType: domain.CalcTypePerimeterBased, QuantityPerMeter: d("1"),
	}
	geo, err := domain.ComputeGeometry(domain.CalcInput{Area: dPtr("20")}) // yalnız alan, çevre bilinmiyor
	if err != nil {
		t.Fatalf("ComputeGeometry: %v", err)
	}
	if geo.Perimeter != nil {
		t.Fatalf("yalnız area verildiğinde perimeter nil olmalı")
	}
	qty, warn := domain.ComputeRecipeQuantity(item, geo)
	if !qty.IsZero() {
		t.Errorf("miktar = %s, istenen 0", qty)
	}
	if warn == nil {
		t.Fatal("çevre eksikken warning BEKLENIYORDU (sessiz 0 kabul edilemez)")
	}
	if warn.Code != "perimeter_missing" || warn.ItemID != "item-1" {
		t.Errorf("warning = %+v, istenen code=perimeter_missing item_id=item-1", warn)
	}
}

// TestComputeGeometry_MissingInput: ne area ne width+height verilirse
// açık bir hata döner (validation error) -- sessiz sıfır/panik yok.
func TestComputeGeometry_MissingInput(t *testing.T) {
	if _, err := domain.ComputeGeometry(domain.CalcInput{}); err == nil {
		t.Fatal("hiçbir ölçü verilmediğinde hata bekleniyordu")
	}
}

// TestComputeGeometry_NegativeOrZeroRejectedExplicitly: dolu ama <=0
// bir alan/ölçü, sessizce "verilmemiş" sayılıp bir sonraki kaynağa
// (width+height) düşülmemeli -- açık ve isabetli bir hata dönmeli.
func TestComputeGeometry_NegativeOrZeroRejectedExplicitly(t *testing.T) {
	cases := []domain.CalcInput{
		{Area: dPtr("-5")},
		{Area: dPtr("0")},
		{Width: dPtr("-1"), Height: dPtr("4")},
		{Width: dPtr("5"), Height: dPtr("0")},
		{Area: dPtr("20"), Perimeter: dPtr("-1")},
	}
	for i, in := range cases {
		if _, err := domain.ComputeGeometry(in); err == nil {
			t.Errorf("senaryo %d: negatif/sıfır girdi sessizce kabul edildi", i)
		}
	}
	// Negatif width ile birlikte area verilirse (area geçerli olduğu
	// sürece) hâlâ reddedilmeli -- width'in kendisi geçersiz.
	if _, err := domain.ComputeGeometry(domain.CalcInput{Area: dPtr("20"), Width: dPtr("-3")}); err == nil {
		t.Error("area geçerliyken bile negatif width reddedilmeliydi")
	}
}

// TestComputeRecipeQuantity_Waste: fire GERÇEKTEN uygulanır (BYZ'de
// waste_percentage yazılıyordu ama motor tarafından hiç okunmuyordu).
func TestComputeRecipeQuantity_Waste(t *testing.T) {
	item := domain.CalcRecipeItem{
		MaterialName: "Alçı Levha", Unit: "m2", CalculationType: domain.CalcTypeAreaBased,
		QuantityPerM2: d("1"), WastePercent: d("5"), RoundingType: domain.RoundingRound,
	}
	geo, _ := domain.ComputeGeometry(domain.CalcInput{Area: dPtr("100")})
	qty, warn := domain.ComputeRecipeQuantity(item, geo)
	if warn != nil {
		t.Fatalf("beklenmeyen warning: %+v", warn)
	}
	if !qty.Equal(d("105.00")) {
		t.Fatalf("miktar = %s, istenen 105.00 (100 × 1.05)", qty)
	}
}

// TestComputeRecipeQuantity_MinQuantity: minimum, ham miktarın altına
// düşmez (BYZ'de bu alan hiç yoktu).
func TestComputeRecipeQuantity_MinQuantity(t *testing.T) {
	item := domain.CalcRecipeItem{
		MaterialName: "Silikon Tüpü", Unit: "adet", CalculationType: domain.CalcTypeAreaBased,
		QuantityPerM2: d("0.01"), MinQuantity: dPtr("2"), RoundingType: domain.RoundingRound,
	}
	geo, _ := domain.ComputeGeometry(domain.CalcInput{Area: dPtr("5")}) // ham = 0.05, min=2 devreye girmeli
	qty, warn := domain.ComputeRecipeQuantity(item, geo)
	if warn != nil {
		t.Fatalf("beklenmeyen warning: %+v", warn)
	}
	if !qty.Equal(d("2.00")) {
		t.Fatalf("miktar = %s, istenen 2.00 (minimum devreye girmeli)", qty)
	}
}

// TestComputeRecipeQuantity_FixedIgnoresArea: fixed tipte alan/çevre
// miktarı etkilemez.
func TestComputeRecipeQuantity_FixedIgnoresArea(t *testing.T) {
	item := domain.CalcRecipeItem{
		MaterialName: "Kapı Kolu", Unit: "adet", CalculationType: domain.CalcTypeFixed,
		FixedQuantity: d("2"), RoundingType: domain.RoundingNone,
	}
	for _, area := range []string{"1", "1000"} {
		geo, _ := domain.ComputeGeometry(domain.CalcInput{Area: dPtr(area)})
		qty, warn := domain.ComputeRecipeQuantity(item, geo)
		if warn != nil {
			t.Fatalf("beklenmeyen warning: %+v", warn)
		}
		if !qty.Equal(d("2")) {
			t.Fatalf("alan=%s için miktar = %s, istenen 2 (fixed alanı yok saymalı)", area, qty)
		}
	}
}
