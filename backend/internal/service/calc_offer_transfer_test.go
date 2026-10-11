package service_test

// Metraj -> teklif sınırı: /calculations/run sonucunun teklife dondurulan
// bağlamı (uygulanan eğim, paket/minimum kuralı) ve metraj toplamının
// teklif ara toplamını tutması. Gerçek bir PostgreSQL bağlantısı
// gerektirir.

import (
	"context"
	"strings"
	"testing"

	"github.com/shopspring/decimal"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

func TestCalcRun_ReportsSnapshotContext(t *testing.T) {
	dbURL := testDBURL(t)
	ctx := context.Background()

	pool, err := repository.NewPool(ctx, dbURL)
	if err != nil {
		t.Fatalf("veritabanına bağlanılamadı: %v", err)
	}
	t.Cleanup(func() { pool.Close() })

	org, q := newCalcTestOrg(t, ctx, pool, "snapshot-baglam")
	t.Cleanup(func() { cleanupOrganization(t, pool, org.ID) })
	calcSvc := service.NewCalcService(q)

	g := mustGroup(t, ctx, calcSvc, org.ID, "cati-hesaplamalari")
	cat := mustCategory(t, ctx, calcSvc, org.ID, g.ID, "onduline-cati")
	if _, err := calcSvc.CreateRecipeItem(ctx, org.ID, service.CalcRecipeItemInput{
		CategoryID: cat.ID, MaterialName: "Taşyünü", Unit: "paket", CalculationType: domain.CalcTypeAreaBased,
		QuantityPerM2: d("1"), MinQuantity: dPtr("2"), PackageSize: dPtr("3.6"), RoundingType: domain.RoundingCeil,
		ReferenceUnitPrice: d("100"),
	}); err != nil {
		t.Fatalf("kalem oluşturulamadı: %v", err)
	}

	result, err := calcSvc.Run(ctx, org.ID, service.CalcRunInput{
		CategoryID: cat.ID, CalcInput: domain.CalcInput{Area: dPtr("10"), PitchDeg: dPtr("30")},
	})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if result.Geometry.PitchDeg == nil || !result.Geometry.PitchDeg.Equal(d("30")) {
		t.Errorf("uygulanan eğim = %v, istenen 30", result.Geometry.PitchDeg)
	}
	it := result.Items[0]
	if it.PackageSize == nil || !it.PackageSize.Equal(d("3.6")) || it.MinQuantity == nil || !it.MinQuantity.Equal(d("2")) {
		t.Errorf("paket/minimum = %v/%v, istenen 3.6/2", it.PackageSize, it.MinQuantity)
	}

	flat, err := calcSvc.Run(ctx, org.ID, service.CalcRunInput{CategoryID: cat.ID, CalcInput: domain.CalcInput{Area: dPtr("10")}})
	if err != nil {
		t.Fatalf("Run (eğimsiz): %v", err)
	}
	if flat.Geometry.PitchDeg != nil {
		t.Errorf("eğim verilmediğinde PitchDeg nil olmalı, geldi %s", flat.Geometry.PitchDeg)
	}
}

// TestCalcToOffer_TotalsMatch: metrajdan teklife aktarılan kalemlerin
// teklif ara toplamı, metraj ekranındaki toplamla kuruşu kuruşuna aynıdır.
// Eskiden "none" kalemler 6 ondalık dönüyordu (64,8375 kg × 37,45 =
// 2.428,16) ama teklif miktarı 2 haneye yuvarlayıp 2.428,26 yazıyordu.
func TestCalcToOffer_TotalsMatch(t *testing.T) {
	dbURL := testDBURL(t)
	ctx := context.Background()

	pool, err := repository.NewPool(ctx, dbURL)
	if err != nil {
		t.Fatalf("veritabanına bağlanılamadı: %v", err)
	}
	t.Cleanup(func() { pool.Close() })

	org, q := newCalcTestOrg(t, ctx, pool, "teklif-aktarim")
	t.Cleanup(func() { cleanupOrganization(t, pool, org.ID) })
	calcSvc := service.NewCalcService(q)
	productSvc := service.NewProductService(q)
	offerSvc := service.NewOfferService(pool, q, service.NewSettingsService(q, testSecretBox(t)), "http://localhost:3000")

	g := mustGroup(t, ctx, calcSvc, org.ID, "mantolama")
	cat := mustCategory(t, ctx, calcSvc, org.ID, g.ID, "eps-mantolama")
	glue, err := productSvc.Create(ctx, org.ID, "Yapıştırıcı", "kg", 37.45, "", "")
	if err != nil {
		t.Fatalf("ürün oluşturulamadı: %v", err)
	}
	for _, in := range []service.CalcRecipeItemInput{
		{
			ProductID: &glue.ID, MaterialName: "Yapıştırıcı", Unit: "kg", CalculationType: domain.CalcTypeAreaBased,
			QuantityPerM2: d("5"), WastePercent: d("5"), RoundingType: domain.RoundingNone, SortOrder: 1,
		},
		{
			MaterialName: "Dübel", Unit: "adet", CalculationType: domain.CalcTypeAreaBased,
			QuantityPerM2: d("6.333333"), RoundingType: domain.RoundingRound, ReferenceUnitPrice: d("1.17"), SortOrder: 2,
		},
		{
			MaterialName: "EPS Levha", Unit: "paket", CalculationType: domain.CalcTypeAreaBased,
			QuantityPerM2: d("1"), PackageSize: dPtr("3.6"), RoundingType: domain.RoundingCeil, ReferenceUnitPrice: d("410.5"), SortOrder: 3,
		},
		{
			MaterialName: "Katkı", Unit: "kg", CalculationType: domain.CalcTypeAreaBased,
			QuantityPerM2: d("0.0003"), RoundingType: domain.RoundingNone, ReferenceUnitPrice: d("900"), SortOrder: 4,
		},
	} {
		in.CategoryID = cat.ID
		if _, err := calcSvc.CreateRecipeItem(ctx, org.ID, in); err != nil {
			t.Fatalf("kalem oluşturulamadı (%s): %v", in.MaterialName, err)
		}
	}

	result, err := calcSvc.Run(ctx, org.ID, service.CalcRunInput{CategoryID: cat.ID, CalcInput: domain.CalcInput{Area: dPtr("12.35")}})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	byName := map[string]domain.CalcResultItem{}
	for _, it := range result.Items {
		byName[it.MaterialName] = it
	}
	if it := byName["Yapıştırıcı"]; !it.Quantity.Equal(d("64.84")) || !it.LineTotal.Equal(d("2428.26")) {
		t.Errorf("Yapıştırıcı = %s kg / %s TL, istenen 64.84 / 2428.26", it.Quantity, it.LineTotal)
	}
	if it := byName["Katkı"]; !it.Quantity.IsZero() {
		t.Errorf("Katkı miktarı = %s, istenen 0 (0,0037 kg)", it.Quantity)
	}
	var tinyWarned bool
	for _, w := range result.Warnings {
		if w.Code == "quantity_below_precision" && w.ItemID == byName["Katkı"].RecipeItemID {
			tinyWarned = true
		}
	}
	if !tinyWarned {
		t.Errorf("0,01'in altındaki miktar için uyarı bekleniyordu: %+v", result.Warnings)
	}

	// İstemcilerin yaptığı gibi: miktarı 0'dan büyük satırlar, string ->
	// sayı çevrilerek teklife eklenir.
	var items []service.OfferItemInput
	for _, it := range result.Items {
		if !it.Quantity.IsPositive() {
			continue
		}
		items = append(items, service.OfferItemInput{
			ProductID: it.ProductID, ProductName: it.MaterialName, Unit: it.Unit,
			Quantity: mustParseFloat(t, it.Quantity.String()), UnitPrice: mustParseFloat(t, it.UnitPrice.StringFixed(2)),
			CalcCategoryID: &cat.ID,
		})
	}
	o, err := offerSvc.Create(ctx, service.CreateOfferInput{OrganizationID: org.ID, CustomerName: "Metraj Aktarım", Items: items})
	if err != nil {
		t.Fatalf("teklif oluşturulamadı: %v", err)
	}
	if len(o.Items) != 3 {
		t.Fatalf("3 kalem bekleniyordu, geldi %d", len(o.Items))
	}
	if !d(result.TotalCost.StringFixed(2)).Equal(decimalFromFloat(o.Subtotal)) {
		t.Fatalf("teklif ara toplamı %.2f, metraj toplamı %s ile aynı olmalı", o.Subtotal, result.TotalCost.StringFixed(2))
	}
	for _, it := range o.Items {
		calc := byName[it.ProductName]
		if !decimalFromFloat(it.LineTotal).Equal(calc.LineTotal) {
			t.Errorf("%s: teklif satırı %.2f, metraj satırı %s", it.ProductName, it.LineTotal, calc.LineTotal)
		}
	}

	t.Run("2 haneye yuvarlanınca 0 olan miktar sessizce düşmez, reddedilir", func(t *testing.T) {
		_, err := offerSvc.Create(ctx, service.CreateOfferInput{
			OrganizationID: org.ID, CustomerName: "Küçük Miktar",
			Items: []service.OfferItemInput{
				{ProductName: "Yapıştırıcı", Quantity: 10, UnitPrice: 37.45},
				{ProductName: "Katkı", Quantity: 0.004, UnitPrice: 900},
			},
		})
		if err == nil || !strings.Contains(err.Error(), "en az 0,01") {
			t.Fatalf("hata = %v, \"en az 0,01\" bekleniyordu", err)
		}
	})

	t.Run("miktarı 0 olan boş satır eskisi gibi atlanır", func(t *testing.T) {
		o, err := offerSvc.Create(ctx, service.CreateOfferInput{
			OrganizationID: org.ID, CustomerName: "Boş Satır",
			Items: []service.OfferItemInput{
				{ProductName: "Yapıştırıcı", Quantity: 10, UnitPrice: 37.45},
				{ProductName: "Katkı", Quantity: 0, UnitPrice: 900},
			},
		})
		if err != nil {
			t.Fatalf("teklif oluşturulamadı: %v", err)
		}
		if len(o.Items) != 1 {
			t.Fatalf("1 kalem bekleniyordu, geldi %d", len(o.Items))
		}
	})
}

func decimalFromFloat(f float64) decimal.Decimal { return decimal.NewFromFloat(f).Round(2) }
