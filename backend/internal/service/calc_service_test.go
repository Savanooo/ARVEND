package service_test

// Metraj Hesaplama modülü için otomatik testler -- gerçek bir PostgreSQL
// bağlantısı gerektirir (DB_URL, bkz. tenant_isolation_test.go:testDBURL).
// Golden (saf sayısal) testler internal/domain/calc_test.go'dadır ve DB
// GEREKTİRMEZ; burada DB entegrasyonu (kalıcılık, tenant izolasyonu,
// ürün fiyat çözümü, uyarılar) doğrulanır.

import (
	"context"
	"strconv"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/shopspring/decimal"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

func d(s string) decimal.Decimal     { return decimal.RequireFromString(s) }
func dPtr(s string) *decimal.Decimal { v := d(s); return &v }

func mustParseFloat(t *testing.T, s string) float64 {
	t.Helper()
	f, err := strconv.ParseFloat(s, 64)
	if err != nil {
		t.Fatalf("sayı ayrıştırılamadı %q: %v", s, err)
	}
	return f
}

func newCalcTestOrg(t *testing.T, ctx context.Context, pool *pgxpool.Pool, slugSuffix string) (domain.Organization, *sqlc.Queries) {
	t.Helper()
	q := sqlc.New(pool)
	orgSvc := service.NewOrganizationService(q)
	org := mustCreateOrg(t, ctx, orgSvc, pool, "Metraj Test "+slugSuffix, "metraj-test-"+slugSuffix)
	return org, q
}

func mustGroup(t *testing.T, ctx context.Context, svc *service.CalcService, orgID, slug string) *domain.CalcGroup {
	t.Helper()
	g, err := svc.CreateGroup(ctx, orgID, service.CalcGroupInput{Slug: slug, Name: "Grup " + slug, SortOrder: 1})
	if err != nil {
		t.Fatalf("grup oluşturulamadı: %v", err)
	}
	return g
}

func mustCategory(t *testing.T, ctx context.Context, svc *service.CalcService, orgID, groupID, slug string) *domain.CalcCategory {
	t.Helper()
	c, err := svc.CreateCategory(ctx, orgID, service.CalcCategoryInput{GroupID: groupID, Slug: slug, Name: "Kategori " + slug, SortOrder: 1})
	if err != nil {
		t.Fatalf("kategori oluşturulamadı: %v", err)
	}
	return c
}

func TestCalcModule_CRUDAndCalculation(t *testing.T) {
	dbURL := testDBURL(t)
	ctx := context.Background()

	pool, err := repository.NewPool(ctx, dbURL)
	if err != nil {
		t.Fatalf("veritabanına bağlanılamadı: %v", err)
	}
	t.Cleanup(func() { pool.Close() })

	orgA, qA := newCalcTestOrg(t, ctx, pool, "a")
	orgB, _ := newCalcTestOrg(t, ctx, pool, "b")
	t.Cleanup(func() { cleanupOrganization(t, pool, orgA.ID); cleanupOrganization(t, pool, orgB.ID) })

	calcSvc := service.NewCalcService(qA)
	productSvc := service.NewProductService(qA)

	t.Run("grup+kategori+reçete CRUD", func(t *testing.T) {
		g, err := calcSvc.CreateGroup(ctx, orgA.ID, service.CalcGroupInput{Slug: "petek-tavanlar", Name: "Petek Tavanlar", SortOrder: 7})
		if err != nil {
			t.Fatalf("grup oluşturulamadı: %v", err)
		}
		if g.Slug != "petek-tavanlar" || !g.IsActive {
			t.Fatalf("beklenmeyen grup: %+v", g)
		}

		// Aynı slug ikinci kez -- UNIQUE(organization_id, slug) ihlali
		// anlamlı bir hataya dönüşmeli, ham Postgres hatası sızmamalı.
		if _, err := calcSvc.CreateGroup(ctx, orgA.ID, service.CalcGroupInput{Slug: "petek-tavanlar", Name: "Tekrar"}); err == nil {
			t.Fatal("aynı slug ile ikinci grup oluşturulabildi, UNIQUE kısıtı beklenmiyordu")
		}

		cat, err := calcSvc.CreateCategory(ctx, orgA.ID, service.CalcCategoryInput{
			GroupID: g.ID, Slug: "10x10-petek-tavan", Name: "10x10 Petek Tavan", SortOrder: 1,
		})
		if err != nil {
			t.Fatalf("kategori oluşturulamadı: %v", err)
		}

		// group_id başka bir organizasyona aitse reddedilmeli.
		otherOrgGroup := mustGroup(t, ctx, service.NewCalcService(sqlc.New(pool)), orgB.ID, "yabanci-grup")
		if _, err := calcSvc.CreateCategory(ctx, orgA.ID, service.CalcCategoryInput{
			GroupID: otherOrgGroup.ID, Slug: "kacak-kategori", Name: "Kaçak",
		}); err == nil {
			t.Fatal("başka organizasyonun group_id'siyle kategori oluşturulabildi")
		}

		item, err := calcSvc.CreateRecipeItem(ctx, orgA.ID, service.CalcRecipeItemInput{
			CategoryID: cat.ID, MaterialName: "10x10 Petek Tavan", Unit: "adet",
			CalculationType: domain.CalcTypeAreaBased, QuantityPerM2: d("5"),
			ReferenceUnitPrice: d("230"), RoundingType: domain.RoundingNone, GroupName: "Ana Malzemeler",
		})
		if err != nil {
			t.Fatalf("reçete kalemi oluşturulamadı: %v", err)
		}
		if item.MaterialName != "10x10 Petek Tavan" {
			t.Fatalf("beklenmeyen kalem: %+v", item)
		}

		// Aynı kategori+ad+birim ikinci kez -- UNIQUE(category_id, material_name, unit).
		if _, err := calcSvc.CreateRecipeItem(ctx, orgA.ID, service.CalcRecipeItemInput{
			CategoryID: cat.ID, MaterialName: "10x10 Petek Tavan", Unit: "adet",
			CalculationType: domain.CalcTypeAreaBased, QuantityPerM2: d("9"),
		}); err == nil {
			t.Fatal("aynı (kategori, ad, birim) ile mükerrer kalem oluşturulabildi")
		}

		items, err := calcSvc.ListRecipeItemsAdmin(ctx, cat.ID, orgA.ID)
		if err != nil || len(items) != 1 {
			t.Fatalf("ListRecipeItemsAdmin = %v, %v; istenen 1 kalem", items, err)
		}

		updated, err := calcSvc.UpdateRecipeItem(ctx, item.ID, orgA.ID, service.CalcRecipeItemInput{
			CategoryID: cat.ID, MaterialName: "10x10 Petek Tavan", Unit: "adet",
			CalculationType: domain.CalcTypeAreaBased, QuantityPerM2: d("5"),
			ReferenceUnitPrice: d("250"), RoundingType: domain.RoundingNone,
		}, false) // is_active=false
		if err != nil {
			t.Fatalf("güncellenemedi: %v", err)
		}
		if updated.IsActive {
			t.Fatal("is_active=false ile güncellendi ama hâlâ true")
		}
		// Pasifleştirilen kalem, hesaplama sorgusunda (ListCalcRecipeItems,
		// is_active=true filtreli) artık görünmemeli.
		active, err := calcSvc.ListRecipeItemsAdmin(ctx, cat.ID, orgA.ID)
		if err != nil {
			t.Fatalf("liste hatası: %v", err)
		}
		if len(active) != 1 || active[0].IsActive {
			t.Fatalf("admin listesi pasif kalemi de göstermeli: %+v", active)
		}

		if err := calcSvc.DeleteRecipeItem(ctx, item.ID, orgA.ID); err != nil {
			t.Fatalf("silinemedi: %v", err)
		}
		if err := calcSvc.DeleteRecipeItem(ctx, item.ID, orgA.ID); err == nil {
			t.Fatal("zaten silinmiş kalem ikinci kez silinebildi (ErrNotFound bekleniyordu)")
		}
	})

	// Pasifleştirilen grup/kategori yönetim listesinde kalmalı (yeniden
	// aktifleştirilebilsin); Metraj Hesapla akışı ise yalnızca aktifleri görür.
	t.Run("pasif grup/kategori admin listesinde görünür ve yeniden aktifleşir", func(t *testing.T) {
		g := mustGroup(t, ctx, calcSvc, orgA.ID, "pasif-grup")
		cat := mustCategory(t, ctx, calcSvc, orgA.ID, g.ID, "pasif-kategori")
		if _, err := calcSvc.UpdateGroup(ctx, g.ID, orgA.ID, service.CalcGroupInput{Slug: g.Slug, Name: g.Name}, false); err != nil {
			t.Fatal(err)
		}
		if _, err := calcSvc.UpdateCategory(ctx, cat.ID, orgA.ID, service.CalcCategoryInput{GroupID: g.ID, Slug: cat.Slug, Name: cat.Name}, false); err != nil {
			t.Fatal(err)
		}
		contains := func(groups []domain.CalcGroup) (bool, bool) {
			for _, gr := range groups {
				if gr.ID == g.ID {
					return true, gr.IsActive
				}
			}
			return false, false
		}
		active, err := calcSvc.ListGroups(ctx, orgA.ID, false)
		if err != nil {
			t.Fatal(err)
		}
		if found, _ := contains(active); found {
			t.Fatal("pasif grup aktif listede görünmemeli")
		}
		all, err := calcSvc.ListGroups(ctx, orgA.ID, true)
		if err != nil {
			t.Fatal(err)
		}
		if found, isActive := contains(all); !found || isActive {
			t.Fatalf("pasif grup admin listesinde pasif olarak görünmeli (found=%v)", found)
		}
		if cats, _ := calcSvc.ListCategoriesByGroup(ctx, g.ID, orgA.ID, false); len(cats) != 0 {
			t.Fatalf("pasif kategori aktif listede görünmemeli: %+v", cats)
		}
		cats, err := calcSvc.ListCategoriesByGroup(ctx, g.ID, orgA.ID, true)
		if err != nil || len(cats) != 1 || cats[0].IsActive {
			t.Fatalf("pasif kategori admin listesinde görünmeli: %+v err=%v", cats, err)
		}
		if _, err := calcSvc.UpdateGroup(ctx, g.ID, orgA.ID, service.CalcGroupInput{Slug: g.Slug, Name: g.Name}, true); err != nil {
			t.Fatal(err)
		}
		active, _ = calcSvc.ListGroups(ctx, orgA.ID, false)
		if found, _ := contains(active); !found {
			t.Fatal("yeniden aktifleşen grup aktif listede görünmeli")
		}
	})

	t.Run("tenant izolasyonu: Firma B, Firma A'nın grubunu/kategorisini/kalemini göremez", func(t *testing.T) {
		calcSvcB := service.NewCalcService(sqlc.New(pool))
		g := mustGroup(t, ctx, calcSvc, orgA.ID, "izole-grup")
		cat := mustCategory(t, ctx, calcSvc, orgA.ID, g.ID, "izole-kategori")
		item, err := calcSvc.CreateRecipeItem(ctx, orgA.ID, service.CalcRecipeItemInput{
			CategoryID: cat.ID, MaterialName: "İzole Malzeme", Unit: "adet",
			CalculationType: domain.CalcTypeFixed, FixedQuantity: d("1"),
		})
		if err != nil {
			t.Fatalf("kalem oluşturulamadı: %v", err)
		}

		if _, err := calcSvcB.UpdateGroup(ctx, g.ID, orgB.ID, service.CalcGroupInput{Slug: g.Slug, Name: "Ele Geçirildi"}, true); err == nil {
			t.Fatal("Firma B, Firma A'nın grubunu güncelleyebildi")
		}
		for _, includeInactive := range []bool{false, true} {
			cats, err := calcSvcB.ListCategoriesByGroup(ctx, g.ID, orgB.ID, includeInactive)
			if err != nil {
				t.Fatalf("beklenmeyen hata: %v", err)
			}
			if len(cats) != 0 {
				t.Fatalf("Firma B, Firma A'nın kategorilerini görebildi (includeInactive=%v): %+v", includeInactive, cats)
			}
		}
		if groups, err := calcSvcB.ListGroups(ctx, orgB.ID, true); err != nil {
			t.Fatalf("beklenmeyen hata: %v", err)
		} else {
			for _, gr := range groups {
				if gr.ID == g.ID {
					t.Fatal("Firma B, Firma A'nın grubunu admin listesinde görebildi")
				}
			}
		}
		if _, err := calcSvcB.UpdateRecipeItem(ctx, item.ID, orgB.ID, service.CalcRecipeItemInput{
			CategoryID: cat.ID, MaterialName: "Ele Geçirildi", Unit: "adet", CalculationType: domain.CalcTypeFixed,
		}, true); err == nil {
			t.Fatal("Firma B, Firma A'nın reçete kalemini güncelleyebildi")
		}
		if err := calcSvcB.DeleteRecipeItem(ctx, item.ID, orgB.ID); err == nil {
			t.Fatal("Firma B, Firma A'nın reçete kalemini silebildi")
		}
		// Firma A'dan hâlâ erişilebilir olmalı (Firma B'nin başarısız
		// girişimleri gerçek veriye dokunmamış olmalı).
		if _, err := calcSvc.GetCategory(ctx, cat.ID, orgA.ID); err != nil {
			t.Fatalf("Firma A kendi kategorisine erişemiyor: %v", err)
		}
	})

	t.Run("product_id başka organizasyona aitse reddedilir", func(t *testing.T) {
		g := mustGroup(t, ctx, calcSvc, orgA.ID, "urun-testi-grup")
		cat := mustCategory(t, ctx, calcSvc, orgA.ID, g.ID, "urun-testi-kategori")

		productSvcB := service.NewProductService(sqlc.New(pool))
		otherOrgProduct, err := productSvcB.Create(ctx, orgB.ID, "Yabancı Ürün", "adet", 10, "", "")
		if err != nil {
			t.Fatalf("ürün oluşturulamadı: %v", err)
		}
		if _, err := calcSvc.CreateRecipeItem(ctx, orgA.ID, service.CalcRecipeItemInput{
			CategoryID: cat.ID, ProductID: &otherOrgProduct.ID, MaterialName: "Kaçak Bağlı", Unit: "adet",
			CalculationType: domain.CalcTypeFixed, FixedQuantity: d("1"),
		}); err == nil {
			t.Fatal("başka organizasyonun product_id'siyle reçete kalemi oluşturulabildi")
		}
	})

	t.Run("uyarılar: ürüne bağlı değil / ürün 0 TL / çevre eksik", func(t *testing.T) {
		g := mustGroup(t, ctx, calcSvc, orgA.ID, "uyari-grup")
		cat := mustCategory(t, ctx, calcSvc, orgA.ID, g.ID, "uyari-kategori")

		zeroProduct, err := productSvc.Create(ctx, orgA.ID, "Sıfır TL Ürün", "adet", 0, "", "")
		if err != nil {
			t.Fatalf("ürün oluşturulamadı: %v", err)
		}

		if _, err := calcSvc.CreateRecipeItem(ctx, orgA.ID, service.CalcRecipeItemInput{
			CategoryID: cat.ID, MaterialName: "Ürünsüz Kalem", Unit: "adet",
			CalculationType: domain.CalcTypeAreaBased, QuantityPerM2: d("1"),
		}); err != nil {
			t.Fatalf("kalem oluşturulamadı: %v", err)
		}
		if _, err := calcSvc.CreateRecipeItem(ctx, orgA.ID, service.CalcRecipeItemInput{
			CategoryID: cat.ID, ProductID: &zeroProduct.ID, MaterialName: "Sıfır Fiyatlı Kalem", Unit: "adet",
			CalculationType: domain.CalcTypeAreaBased, QuantityPerM2: d("1"),
		}); err != nil {
			t.Fatalf("kalem oluşturulamadı: %v", err)
		}
		if _, err := calcSvc.CreateRecipeItem(ctx, orgA.ID, service.CalcRecipeItemInput{
			CategoryID: cat.ID, MaterialName: "Çevre Bazlı Kalem", Unit: "m",
			CalculationType: domain.CalcTypePerimeterBased, QuantityPerMeter: d("1"),
		}); err != nil {
			t.Fatalf("kalem oluşturulamadı: %v", err)
		}

		result, err := calcSvc.Run(ctx, orgA.ID, service.CalcRunInput{
			CategoryID: cat.ID, CalcInput: domain.CalcInput{Area: dPtr("10")}, // yalnız alan -- çevre bilinmiyor
		})
		if err != nil {
			t.Fatalf("Run: %v", err)
		}
		if len(result.Items) != 3 {
			t.Fatalf("3 kalem bekleniyordu, geldi: %d", len(result.Items))
		}
		codes := map[string]int{}
		for _, w := range result.Warnings {
			codes[w.Code]++
		}
		if codes["product_missing"] != 2 { // ürünsüz kalem + sıfır TL ürünün KENDİSİ product_missing değil, product_zero_price olmalı
			t.Errorf("product_missing sayısı = %d, istenen en az 1 (ürünsüz kalem)", codes["product_missing"])
		}
		if codes["product_zero_price"] != 1 {
			t.Errorf("product_zero_price sayısı = %d, istenen 1", codes["product_zero_price"])
		}
		if codes["perimeter_missing"] != 1 {
			t.Errorf("perimeter_missing sayısı = %d, istenen 1", codes["perimeter_missing"])
		}
		// Hiçbir yazma tetiklenmemeli: ürünsüz kalem hâlâ ürünsüz.
		refreshed, err := calcSvc.ListRecipeItemsAdmin(ctx, cat.ID, orgA.ID)
		if err != nil {
			t.Fatalf("liste hatası: %v", err)
		}
		for _, it := range refreshed {
			if it.MaterialName == "Ürünsüz Kalem" && it.ProductID != nil {
				t.Fatal("Run() salt-okur olmalıydı ama ürünsüz kaleme bir ürün BAĞLANMIŞ")
			}
		}
	})

	t.Run("uçtan uca: 10x10 Petek Tavan 20 m² -- gerçek ürün fiyatlarıyla", func(t *testing.T) {
		g := mustGroup(t, ctx, calcSvc, orgA.ID, "e2e-petek-tavanlar")
		cat := mustCategory(t, ctx, calcSvc, orgA.ID, g.ID, "e2e-10x10-petek-tavan")

		type row struct {
			name, unit, qty, price string
		}
		rows := []row{
			{"10x10 Petek Tavan", "adet", "5", "230"},
			{"3600 mm Ana Taşıyıcı", "adet", "1", "110"},
			{"Tali Taşıyıcı 60cm", "adet", "6", "30"},
			{"Tali Taşıyıcı 120cm", "adet", "6", "60"},
			{"L Köşebent 3000 mm", "adet", "2", "70"},
			{"Çelik Dübel", "adet", "3", "4"},
			{"Askı Teli 40cm", "adet", "6", "4"},
			{"Çift Yaylı Maşa", "adet", "3", "3"},
			{"Dübel Vida", "paket", "1", "170"},
		}
		for _, rr := range rows {
			price := mustParseFloat(t, rr.price)
			p, err := productSvc.Create(ctx, orgA.ID, rr.name, rr.unit, price, "", "Hesaplama Malzemesi")
			if err != nil {
				t.Fatalf("ürün oluşturulamadı (%s): %v", rr.name, err)
			}
			if _, err := calcSvc.CreateRecipeItem(ctx, orgA.ID, service.CalcRecipeItemInput{
				CategoryID: cat.ID, ProductID: &p.ID, MaterialName: rr.name, Unit: rr.unit,
				CalculationType: domain.CalcTypeAreaBased, QuantityPerM2: d(rr.qty),
				ReferenceUnitPrice: d(rr.price), RoundingType: domain.RoundingNone,
			}); err != nil {
				t.Fatalf("kalem oluşturulamadı (%s): %v", rr.name, err)
			}
		}

		result, err := calcSvc.Run(ctx, orgA.ID, service.CalcRunInput{
			CategoryID: cat.ID, CalcInput: domain.CalcInput{Area: dPtr("20")},
		})
		if err != nil {
			t.Fatalf("Run: %v", err)
		}
		if len(result.Warnings) != 0 {
			t.Fatalf("beklenmeyen warnings: %+v", result.Warnings)
		}
		if len(result.Items) != 9 {
			t.Fatalf("9 kalem bekleniyordu, geldi: %d", len(result.Items))
		}
		wantQty := map[string]string{
			"10x10 Petek Tavan": "100", "3600 mm Ana Taşıyıcı": "20", "Tali Taşıyıcı 60cm": "120",
			"Tali Taşıyıcı 120cm": "120", "L Köşebent 3000 mm": "40", "Çelik Dübel": "60",
			"Askı Teli 40cm": "120", "Çift Yaylı Maşa": "60", "Dübel Vida": "20",
		}
		for _, it := range result.Items {
			if !it.Quantity.Equal(d(wantQty[it.MaterialName])) {
				t.Errorf("%s: miktar = %s, istenen %s", it.MaterialName, it.Quantity, wantQty[it.MaterialName])
			}
			if it.ProductID == nil {
				t.Errorf("%s: product_id çözülmedi", it.MaterialName)
			}
		}
		if !result.TotalCost.Equal(d("43100.00")) {
			t.Fatalf("toplam = %s, istenen 43100.00", result.TotalCost)
		}
	})
}
