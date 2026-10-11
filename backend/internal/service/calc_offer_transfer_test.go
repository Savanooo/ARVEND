package service_test

// Metraj -> teklif sınırı: /calculations/run sonucunun teklife dondurulan
// bağlamı (uygulanan eğim, paket/minimum kuralı). Gerçek bir PostgreSQL
// bağlantısı gerektirir.

import (
	"context"
	"testing"

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
