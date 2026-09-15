package service

import (
	"context"
	_ "embed"
	"encoding/json"
	"errors"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/shopspring/decimal"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

// embeddedCalcCatalogFixture, db/fixtures/byz_calc_recipes.json'un derleme
// zamanı embed edilmiş bir kopyasıdır -- cmd/import-calc-recipes (operatörün
// elle, tek seferlik çalıştırdığı araç) --fixture bayrağıyla diskteki asıl
// dosyayı okumaya devam eder; BURADAKİ kopya SADECE PlatformService'in yeni
// bir organizasyon oluştururken OTOMATİK tetiklediği provisioning için --
// production'da çalışan bir systemd servisinin rastgele bir dosya yoluna
// (cwd'ye göre) güvenmesi kırılgan olurdu, embed bunu ortadan kaldırıyor.
// scripts/extract_byz_calc_recipes.py yeniden çalıştırılırsa bu kopya da
// elle güncellenmeli (cp db/fixtures/byz_calc_recipes.json
// internal/service/fixtures/byz_calc_recipes.json) -- fixture'ın kendisi
// tarihsel bir BYZ veri göçü anlık görüntüsü olduğu için bu beklenmedik bir
// sıklıkta olmaz.
//
//go:embed fixtures/byz_calc_recipes.json
var embeddedCalcCatalogFixture []byte

type calcFixtureGroup struct {
	Slug        string `json:"slug"`
	Name        string `json:"name"`
	Description string `json:"description"`
	SortOrder   int    `json:"sort_order"`
}

type calcFixtureCategory struct {
	Slug        string  `json:"slug"`
	Name        string  `json:"name"`
	Description string  `json:"description"`
	GroupSlug   string  `json:"group_slug"`
	SortOrder   int     `json:"sort_order"`
	Image       *string `json:"image"`
}

type calcFixtureRecipeItem struct {
	CategorySlug       string  `json:"category_slug"`
	MaterialName       string  `json:"material_name"`
	Unit               string  `json:"unit"`
	QuantityPerM2      float64 `json:"quantity_per_m2"`
	ReferenceUnitPrice float64 `json:"reference_unit_price"`
	GroupName          string  `json:"group_name"`
	SortOrder          int     `json:"sort_order"`
	RoundingType       string  `json:"rounding_type"`
}

type calcFixture struct {
	Groups      []calcFixtureGroup      `json:"groups"`
	Categories  []calcFixtureCategory   `json:"categories"`
	RecipeItems []calcFixtureRecipeItem `json:"recipe_items"`
}

// CalcCatalogProvisionResult, cmd/import-calc-recipes'in konsola bastığı
// özet sayaçların programatik karşılığıdır (audit metadata'sına yazılabilir,
// PlatformHandler.ReprovisionCalcCatalog tarafından doğrudan JSON'a
// serileştirilir -- bu yüzden diğer domain tipulerinin aksine burada
// doğrudan json tag taşır, ayrı bir response struct'a ihtiyaç yok).
type CalcCatalogProvisionResult struct {
	GroupsCreated     int `json:"groups_created"`
	GroupsSkipped     int `json:"groups_skipped"`
	CategoriesCreated int `json:"categories_created"`
	CategoriesSkipped int `json:"categories_skipped"`
	CategoriesOrphan  int `json:"categories_orphan"`
	ItemsCreated      int `json:"items_created"`
	ItemsSkipped      int `json:"items_skipped"`
	ItemsOrphan       int `json:"items_orphan"`
	ItemsFailed       int `json:"items_failed"`
}

// ProvisionCalcCatalog, varsayılan Metraj Hesaplama kataloğunu (gruplar +
// kategoriler + reçete kalemleri) bir organizasyona aktarır. cmd/import-
// calc-recipes/main.go'daki mantığın BİREBİR aynısı -- (organization_id,
// slug) veya (category_id, material_name, unit) zaten varsa ATLANIR,
// üzerine yazılmaz (idempotent-güvenli, admin düzenlemeleri korunur).
// product_id, linkProducts=false ise her zaman NULL kalır (hesaplama motoru
// eksik ürünü warnings[] ile bildirir, sessiz 0 TL üretmez).
//
// fixtureOverride nil ise embed edilmiş varsayılan BYZ fixture'ı kullanılır
// (PlatformService'in yeni organizasyon akışı bunu kullanır); dolu ise (ör.
// cmd/import-calc-recipes'in --fixture bayrağıyla okuduğu özel bir dosya)
// onun yerine o kullanılır.
func ProvisionCalcCatalog(
	ctx context.Context,
	calcSvc *CalcService,
	productSvc *ProductService,
	q *sqlc.Queries,
	organizationID string,
	linkProducts bool,
	fixtureOverride []byte,
) (*CalcCatalogProvisionResult, error) {
	raw := fixtureOverride
	if raw == nil {
		raw = embeddedCalcCatalogFixture
	}
	var fx calcFixture
	if err := json.Unmarshal(raw, &fx); err != nil {
		return nil, err
	}

	orgUUID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, err
	}

	res := &CalcCatalogProvisionResult{}

	groupIDBySlug := map[string]string{}
	for _, g := range fx.Groups {
		existing, err := q.GetCalcGroupBySlug(ctx, sqlc.GetCalcGroupBySlugParams{OrganizationID: orgUUID, Slug: g.Slug})
		if err == nil {
			groupIDBySlug[g.Slug] = existing.ID.String()
			res.GroupsSkipped++
			continue
		}
		if !errors.Is(err, pgx.ErrNoRows) {
			return nil, err
		}
		created, err := calcSvc.CreateGroup(ctx, organizationID, CalcGroupInput{
			Slug: g.Slug, Name: g.Name, Description: g.Description, SortOrder: g.SortOrder,
		})
		if err != nil {
			return nil, err
		}
		groupIDBySlug[g.Slug] = created.ID
		res.GroupsCreated++
	}

	categoryIDBySlug := map[string]string{}
	for _, c := range fx.Categories {
		groupID, ok := groupIDBySlug[c.GroupSlug]
		if !ok {
			res.CategoriesOrphan++
			continue
		}
		existing, err := q.GetCalcCategoryBySlug(ctx, sqlc.GetCalcCategoryBySlugParams{OrganizationID: orgUUID, Slug: c.Slug})
		if err == nil {
			categoryIDBySlug[c.Slug] = existing.ID.String()
			res.CategoriesSkipped++
			continue
		}
		if !errors.Is(err, pgx.ErrNoRows) {
			return nil, err
		}
		created, err := calcSvc.CreateCategory(ctx, organizationID, CalcCategoryInput{
			GroupID: groupID, Slug: c.Slug, Name: c.Name, Description: c.Description, SortOrder: c.SortOrder,
		})
		if err != nil {
			return nil, err
		}
		categoryIDBySlug[c.Slug] = created.ID
		res.CategoriesCreated++
	}

	productCache := map[string]string{}
	findOrCreateProduct := func(name, unit string, refPrice float64) (*string, error) {
		key := domain.NormalizeName(name) + "|" + unit
		if id, ok := productCache[key]; ok {
			return &id, nil
		}
		list, err := productSvc.List(ctx, organizationID, name, 1, 50)
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
		created, err := productSvc.Create(ctx, organizationID, name, unit, refPrice, "", "Hesaplama Malzemesi")
		if err != nil {
			return nil, err
		}
		productCache[key] = created.ID
		return &created.ID, nil
	}

	for _, it := range fx.RecipeItems {
		categoryID, ok := categoryIDBySlug[it.CategorySlug]
		if !ok {
			res.ItemsOrphan++
			continue
		}
		existing, err := q.GetCalcRecipeItemByCategoryMaterialUnit(ctx, sqlc.GetCalcRecipeItemByCategoryMaterialUnitParams{
			CategoryID: mustUUID(categoryID), OrganizationID: orgUUID, MaterialName: it.MaterialName, Unit: it.Unit,
		})
		if err == nil {
			_ = existing
			res.ItemsSkipped++
			continue
		}
		if !errors.Is(err, pgx.ErrNoRows) {
			return nil, err
		}

		var productID *string
		if linkProducts {
			// Ürün eşleştirme/oluşturma başarısız olsa da kalem NULL
			// product_id ile eklenmeye devam eder -- CLI'daki davranışla
			// aynı (bkz. cmd/import-calc-recipes/main.go).
			productID, _ = findOrCreateProduct(it.MaterialName, it.Unit, it.ReferenceUnitPrice)
		}

		roundingType := it.RoundingType
		if roundingType == "" {
			roundingType = domain.RoundingNone
		}
		_, err = calcSvc.CreateRecipeItem(ctx, organizationID, CalcRecipeItemInput{
			CategoryID: categoryID, ProductID: productID, MaterialName: it.MaterialName, Unit: it.Unit,
			CalculationType:    domain.CalcTypeAreaBased,
			QuantityPerM2:      decimal.NewFromFloat(it.QuantityPerM2),
			ReferenceUnitPrice: decimal.NewFromFloat(it.ReferenceUnitPrice),
			RoundingType:       roundingType,
			GroupName:          it.GroupName, SortOrder: it.SortOrder,
		})
		if err != nil {
			res.ItemsFailed++
			continue
		}
		res.ItemsCreated++
	}

	return res, nil
}

func mustUUID(s string) pgtype.UUID {
	u, err := repository.StringToUUID(s)
	if err != nil {
		panic("beklenmeyen geçersiz id: " + s)
	}
	return u
}
