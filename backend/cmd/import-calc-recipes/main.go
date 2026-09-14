// import-calc-recipes, BYZ'den çıkarılan Metraj Hesaplama fixture'ını
// (scripts/extract_byz_calc_recipes.py çıktısı, bkz.
// db/fixtures/byz_calc_recipes.json) BİR ARVEND ORGANİZASYONUNA aktarır.
//
// TEK SEFERLİK bir araçtır -- kalıcı uygulama kodu DEĞİLDİR. Sunucu
// açılışında OTOMATİK ÇALIŞMAZ (BYZ'nin her boot'ta seed_calculation_data()
// çalıştırıp kullanıcı düzenlemelerini ezmesi -- rapor §11.1 -- BİLİNÇLİ
// OLARAK taşınmadı). Aynı zamanda "controlled provisioning" aracıdır:
// yeni bir organizasyon için varsayılan Metraj Hesaplama kataloğu
// isteniyorsa bu araç o organizasyonun id'siyle yeniden çalıştırılır.
//
// İDEMPOTENT-GÜVENLİ: (organization_id, slug) zaten varsa grup/kategori
// ATLANIR (üzerine YAZILMAZ) -- admin'in sonradan yaptığı düzenlemeler
// hiçbir zaman sessizce ezilmez (BYZ'nin en çok eleştirilen davranışının
// doğrudan tersi). Reçete kalemleri (category_id, material_name, unit)
// üçlüsüyle aynı şekilde atlanır.
//
// product_id VARSAYILAN OLARAK BAĞLANMAZ (NULL kalır) -- hesaplama motoru
// zaten eksik ürünü warnings[] ile bildirir, sessiz 0 TL üretmez (bkz.
// internal/domain/calc.go). --link-products verilirse, (normalized_name,
// unit) ile mevcut bir ürün aranır; yoksa reference_unit_price ile YENİ
// bir ürün oluşturulur. Bu, YALNIZCA bu tek seferlik, bir operatör
// tarafından BİLİNÇLİ tetiklenen import aracında yapılır -- çalışma
// zamanı hesaplama (service.CalcService.Run) HİÇBİR ZAMAN ürün yaratmaz.
//
// Kullanım:
//
//	DB_URL="postgres://.../arvend_dev" go run ./cmd/import-calc-recipes \
//	  --fixture db/fixtures/byz_calc_recipes.json \
//	  --org 00000000-0000-0000-0000-000000000001 \
//	  [--link-products]
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log"
	"os"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/shopspring/decimal"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

type fixtureGroup struct {
	Slug        string `json:"slug"`
	Name        string `json:"name"`
	Description string `json:"description"`
	SortOrder   int    `json:"sort_order"`
}

type fixtureCategory struct {
	Slug        string  `json:"slug"`
	Name        string  `json:"name"`
	Description string  `json:"description"`
	GroupSlug   string  `json:"group_slug"`
	SortOrder   int     `json:"sort_order"`
	Image       *string `json:"image"`
}

type fixtureRecipeItem struct {
	CategorySlug       string  `json:"category_slug"`
	MaterialName       string  `json:"material_name"`
	Unit               string  `json:"unit"`
	QuantityPerM2      float64 `json:"quantity_per_m2"`
	ReferenceUnitPrice float64 `json:"reference_unit_price"`
	GroupName          string  `json:"group_name"`
	SortOrder          int     `json:"sort_order"`
	RoundingType       string  `json:"rounding_type"`
}

type fixture struct {
	Groups      []fixtureGroup      `json:"groups"`
	Categories  []fixtureCategory   `json:"categories"`
	RecipeItems []fixtureRecipeItem `json:"recipe_items"`
}

func main() {
	fixturePath := flag.String("fixture", "db/fixtures/byz_calc_recipes.json", "Fixture JSON yolu")
	orgID := flag.String("org", "", "Hedef organizasyon id'si (zorunlu)")
	linkProducts := flag.Bool("link-products", false, "Reçete kalemlerini (ad+birim eşleşmesiyle) ürünlere bağla; yoksa yeni ürün oluştur")
	flag.Parse()

	if *orgID == "" {
		fmt.Fprintln(os.Stderr, "kullanım: import-calc-recipes --fixture <yol> --org <organization_id> [--link-products]")
		os.Exit(1)
	}

	raw, err := os.ReadFile(*fixturePath)
	if err != nil {
		log.Fatalf("fixture okunamadı: %v", err)
	}
	var fx fixture
	if err := json.Unmarshal(raw, &fx); err != nil {
		log.Fatalf("fixture JSON ayrıştırılamadı: %v", err)
	}

	dbURL := os.Getenv("DB_URL")
	if dbURL == "" {
		log.Fatal("DB_URL ortam değişkeni gerekli")
	}
	ctx := context.Background()
	pool, err := repository.NewPool(ctx, dbURL)
	if err != nil {
		log.Fatalf("veritabanına bağlanılamadı: %v", err)
	}
	defer pool.Close()

	q := sqlc.New(pool)
	calcSvc := service.NewCalcService(q)
	productSvc := service.NewProductService(q)

	// Organizasyon gerçekten var mı -- yoksa tüm import sessizce hiçbir
	// yere yazmadan (FK ihlaliyle) başarısız olur; burada erken ve
	// anlaşılır bir hatayla durmak daha iyi.
	orgUUID, err := repository.StringToUUID(*orgID)
	if err != nil {
		log.Fatalf("geçersiz --org: %v", err)
	}
	if _, err := q.GetOrganizationByID(ctx, orgUUID); err != nil {
		log.Fatalf("organizasyon bulunamadı (%s): %v", *orgID, err)
	}

	groupIDBySlug := map[string]string{}
	var groupsCreated, groupsSkipped int
	for _, g := range fx.Groups {
		existing, err := q.GetCalcGroupBySlug(ctx, sqlc.GetCalcGroupBySlugParams{OrganizationID: orgUUID, Slug: g.Slug})
		if err == nil {
			groupIDBySlug[g.Slug] = existing.ID.String()
			groupsSkipped++
			continue
		}
		if !errors.Is(err, pgx.ErrNoRows) {
			log.Fatalf("grup sorgulanamadı (%s): %v", g.Slug, err)
		}
		created, err := calcSvc.CreateGroup(ctx, *orgID, service.CalcGroupInput{
			Slug: g.Slug, Name: g.Name, Description: g.Description, SortOrder: g.SortOrder,
		})
		if err != nil {
			log.Fatalf("grup oluşturulamadı (%s): %v", g.Slug, err)
		}
		groupIDBySlug[g.Slug] = created.ID
		groupsCreated++
	}

	categoryIDBySlug := map[string]string{}
	var categoriesCreated, categoriesSkipped, categoriesOrphan int
	for _, c := range fx.Categories {
		groupID, ok := groupIDBySlug[c.GroupSlug]
		if !ok {
			log.Printf("UYARI: kategori %q, tanınmayan grup %q taşıyor -- atlanıyor", c.Slug, c.GroupSlug)
			categoriesOrphan++
			continue
		}
		existing, err := q.GetCalcCategoryBySlug(ctx, sqlc.GetCalcCategoryBySlugParams{OrganizationID: orgUUID, Slug: c.Slug})
		if err == nil {
			categoryIDBySlug[c.Slug] = existing.ID.String()
			categoriesSkipped++
			continue
		}
		if !errors.Is(err, pgx.ErrNoRows) {
			log.Fatalf("kategori sorgulanamadı (%s): %v", c.Slug, err)
		}
		created, err := calcSvc.CreateCategory(ctx, *orgID, service.CalcCategoryInput{
			GroupID: groupID, Slug: c.Slug, Name: c.Name, Description: c.Description, SortOrder: c.SortOrder,
		})
		if err != nil {
			log.Fatalf("kategori oluşturulamadı (%s): %v", c.Slug, err)
		}
		categoryIDBySlug[c.Slug] = created.ID
		categoriesCreated++
	}

	// (normalized_name, unit) -> product_id önbelleği -- --link-products
	// verildiğinde her kalem için ayrı bir arama sorgusu yerine.
	productCache := map[string]string{}
	findOrCreateProduct := func(name, unit string, refPrice float64) (*string, error) {
		key := domain.NormalizeName(name) + "|" + unit
		if id, ok := productCache[key]; ok {
			return &id, nil
		}
		list, err := productSvc.List(ctx, *orgID, name, 1, 50)
		if err != nil {
			return nil, err
		}
		for _, p := range list.Products {
			if p.NormalizedName == domain.NormalizeName(name) && p.Unit == unit {
				productCache[key] = p.ID
				id := p.ID
				return &id, nil
			}
		}
		created, err := productSvc.Create(ctx, *orgID, name, unit, refPrice, "", "Hesaplama Malzemesi")
		if err != nil {
			return nil, err
		}
		productCache[key] = created.ID
		return &created.ID, nil
	}

	var itemsCreated, itemsSkipped, itemsOrphan, itemsFailed int
	for _, it := range fx.RecipeItems {
		categoryID, ok := categoryIDBySlug[it.CategorySlug]
		if !ok {
			log.Printf("UYARI: kalem %q, tanınmayan kategori %q taşıyor -- atlanıyor", it.MaterialName, it.CategorySlug)
			itemsOrphan++
			continue
		}
		existing, err := q.GetCalcRecipeItemByCategoryMaterialUnit(ctx, sqlc.GetCalcRecipeItemByCategoryMaterialUnitParams{
			CategoryID: mustUUID(categoryID), OrganizationID: orgUUID, MaterialName: it.MaterialName, Unit: it.Unit,
		})
		if err == nil {
			_ = existing
			itemsSkipped++
			continue
		}
		if !errors.Is(err, pgx.ErrNoRows) {
			log.Fatalf("reçete kalemi sorgulanamadı (%s): %v", it.MaterialName, err)
		}

		var productID *string
		if *linkProducts {
			productID, err = findOrCreateProduct(it.MaterialName, it.Unit, it.ReferenceUnitPrice)
			if err != nil {
				log.Printf("HATA: ürün bağlanamadı (%s/%s): %v -- kalem product_id=NULL ile eklenecek", it.MaterialName, it.Unit, err)
			}
		}

		roundingType := it.RoundingType
		if roundingType == "" {
			roundingType = domain.RoundingNone
		}
		_, err = calcSvc.CreateRecipeItem(ctx, *orgID, service.CalcRecipeItemInput{
			CategoryID: categoryID, ProductID: productID, MaterialName: it.MaterialName, Unit: it.Unit,
			CalculationType:    domain.CalcTypeAreaBased, // BYZ seed'i her zaman area_based üretir (bkz. veri kalitesi raporu)
			QuantityPerM2:      decimalFromFloat(it.QuantityPerM2),
			ReferenceUnitPrice: decimalFromFloat(it.ReferenceUnitPrice),
			RoundingType:       roundingType,
			GroupName:          it.GroupName, SortOrder: it.SortOrder,
		})
		if err != nil {
			log.Printf("HATA: kalem oluşturulamadı (%s / %s): %v", it.CategorySlug, it.MaterialName, err)
			itemsFailed++
			continue
		}
		itemsCreated++
	}

	fmt.Printf("Gruplar: %d oluşturuldu, %d zaten vardı (atlandı)\n", groupsCreated, groupsSkipped)
	fmt.Printf("Kategoriler: %d oluşturuldu, %d zaten vardı (atlandı), %d yetim (tanınmayan grup)\n",
		categoriesCreated, categoriesSkipped, categoriesOrphan)
	fmt.Printf("Reçete kalemleri: %d oluşturuldu, %d zaten vardı (atlandı), %d yetim (tanınmayan kategori), %d başarısız\n",
		itemsCreated, itemsSkipped, itemsOrphan, itemsFailed)
	if *linkProducts {
		fmt.Printf("Ürün eşleştirme: %d benzersiz (ad, birim) çifti işlendi\n", len(productCache))
	} else {
		fmt.Println("Ürün bağlama atlandı (--link-products verilmedi) -- tüm kalemler product_id=NULL ile eklendi.")
	}
	fmt.Println("Not: veri kalitesi raporundaki (docs/byz-metraj-import-veri-kalitesi-raporu.md) hiçbir sorun burada otomatik düzeltilmedi.")
}

// mustUUID, yalnızca bu dosya içinde -- zaten repository.StringToUUID ile
// bir önceki adımda (DB'den ya da CreateX'ten) üretilmiş, bilinen-geçerli
// id'leri tekrar pgtype.UUID'e çevirmek için. Gerçek bir hata oluşursa
// (pratikte olmaz) sessizce yutmak yerine hemen durur.
func mustUUID(s string) pgtype.UUID {
	u, err := repository.StringToUUID(s)
	if err != nil {
		log.Fatalf("beklenmeyen geçersiz id %q: %v", s, err)
	}
	return u
}

// decimalFromFloat, fixture JSON'undan (encoding/json ile float64 olarak
// ayrıştırılmış) bir sayıyı decimal.Decimal'e çevirir. Fixture zaten
// scripts/extract_byz_calc_recipes.py'nin AST üzerinden okuduğu, ondalık
// hane sayısı sınırlı gerçek dünya katsayılarını taşıdığından
// (quantity_per_m2/reference_unit_price), NewFromFloat burada güvenlidir
// -- bu içe aktarma aracı sınırında TEK float64 dönüşü noktasıdır, motor
// (internal/domain/calc.go) bundan sonra hep decimal ile çalışır.
func decimalFromFloat(f float64) decimal.Decimal {
	return decimal.NewFromFloat(f)
}
