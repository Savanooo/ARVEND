-- ============ Gruplar ============

-- name: ListCalcGroups :many
SELECT * FROM calc_groups WHERE organization_id = $1 AND is_active = true ORDER BY sort_order ASC, name ASC;

-- ListCalcGroupsAdmin, yönetim ekranı için pasifleştirilmiş gruplar DAHİL
-- tümünü döner (ListCalcRecipeItemsAdmin ile aynı ilke) -- aksi halde
-- pasife alınan bir grup listeden düşüp detay sayfası 404 veriyor, yeniden
-- aktifleştirilemiyordu. Aktifler önce gelir.
-- name: ListCalcGroupsAdmin :many
SELECT * FROM calc_groups WHERE organization_id = $1 ORDER BY is_active DESC, sort_order ASC, name ASC;

-- name: GetCalcGroupByID :one
SELECT * FROM calc_groups WHERE id = $1 AND organization_id = $2;

-- GetCalcGroupBySlug, TEK SEFERLİK içe aktarma aracının (cmd/import-calc-recipes)
-- "zaten varsa atla" (BYZ'nin her açılışta üzerine yazan seed davranışının
-- BİLİNÇLİ TERSİ) idempotent-güvenli tekrar çalıştırma deseni içindir.
-- name: GetCalcGroupBySlug :one
SELECT * FROM calc_groups WHERE organization_id = $1 AND slug = $2;

-- name: CreateCalcGroup :one
INSERT INTO calc_groups (organization_id, slug, name, description, sort_order)
VALUES ($1, $2, $3, $4, $5)
RETURNING *;

-- name: UpdateCalcGroup :one
UPDATE calc_groups
SET slug = $3, name = $4, description = $5, sort_order = $6, is_active = $7
WHERE id = $1 AND organization_id = $2
RETURNING *;

-- ============ Kategoriler ============

-- name: ListCalcCategoriesByGroup :many
SELECT * FROM calc_categories
WHERE group_id = $1 AND organization_id = $2 AND is_active = true
ORDER BY sort_order ASC, name ASC;

-- ListCalcCategoriesByGroupAdmin: ListCalcGroupsAdmin ile aynı gerekçe --
-- pasif kategoriler de listelenir ki yeniden aktifleştirilebilsin.
-- name: ListCalcCategoriesByGroupAdmin :many
SELECT * FROM calc_categories
WHERE group_id = $1 AND organization_id = $2
ORDER BY is_active DESC, sort_order ASC, name ASC;

-- ListActiveCalcCategoriesForOrg, tüm aktif grupların tüm aktif
-- kategorilerini TEK sorguda döner -- web/mobil "grup seç -> kategori
-- seç" kaskadı için (BYZ get_calculation_categories_grouped ile aynı
-- fikir, ama tek JOIN'li sorgu, N+1 yok).
-- name: ListActiveCalcCategoriesForOrg :many
SELECT c.*, g.slug AS group_slug, g.name AS group_name_label, g.sort_order AS group_sort_order
FROM calc_categories c
JOIN calc_groups g ON g.id = c.group_id AND g.organization_id = c.organization_id
WHERE c.organization_id = $1 AND c.is_active = true AND g.is_active = true
ORDER BY g.sort_order ASC, g.name ASC, c.sort_order ASC, c.name ASC;

-- name: GetCalcCategoryByID :one
SELECT * FROM calc_categories WHERE id = $1 AND organization_id = $2;

-- name: GetCalcCategoryBySlug :one
SELECT * FROM calc_categories WHERE organization_id = $1 AND slug = $2;

-- name: CreateCalcCategory :one
INSERT INTO calc_categories (organization_id, group_id, slug, name, description, image_file_id, sort_order)
VALUES ($1, $2, $3, $4, $5, $6, $7)
RETURNING *;

-- name: UpdateCalcCategory :one
UPDATE calc_categories
SET group_id = $3, slug = $4, name = $5, description = $6, image_file_id = $7,
    sort_order = $8, is_active = $9
WHERE id = $1 AND organization_id = $2
RETURNING *;

-- ============ Reçete Kalemleri ============

-- name: ListCalcRecipeItems :many
SELECT * FROM calc_recipe_items
WHERE category_id = $1 AND organization_id = $2 AND is_active = true
ORDER BY sort_order ASC, material_name ASC;

-- ListCalcRecipeItemsAdmin, admin CRUD listesi için is_active'e
-- bakılmaksızın (pasifleştirilmiş kalemler dahil) tüm kalemleri döner.
-- name: ListCalcRecipeItemsAdmin :many
SELECT * FROM calc_recipe_items
WHERE category_id = $1 AND organization_id = $2
ORDER BY sort_order ASC, material_name ASC;

-- name: GetCalcRecipeItemByID :one
SELECT * FROM calc_recipe_items WHERE id = $1 AND organization_id = $2;

-- name: GetCalcRecipeItemByCategoryMaterialUnit :one
SELECT * FROM calc_recipe_items
WHERE category_id = $1 AND organization_id = $2 AND material_name = $3 AND unit = $4;

-- name: CreateCalcRecipeItem :one
INSERT INTO calc_recipe_items (
    organization_id, category_id, product_id, material_name, unit, calculation_type,
    quantity_per_m2, quantity_per_meter, fixed_quantity, waste_percent, rounding_type,
    min_quantity, package_size, reference_unit_price, group_name, sort_order, notes
) VALUES (
    sqlc.arg(organization_id), sqlc.arg(category_id), sqlc.narg(product_id),
    sqlc.arg(material_name), sqlc.arg(unit), sqlc.arg(calculation_type),
    sqlc.arg(quantity_per_m2)::numeric, sqlc.arg(quantity_per_meter)::numeric,
    sqlc.arg(fixed_quantity)::numeric, sqlc.arg(waste_percent)::numeric, sqlc.arg(rounding_type),
    sqlc.narg(min_quantity)::numeric, sqlc.narg(package_size)::numeric,
    sqlc.arg(reference_unit_price)::numeric, sqlc.arg(group_name), sqlc.arg(sort_order),
    sqlc.narg(notes)
)
RETURNING *;

-- name: UpdateCalcRecipeItem :one
UPDATE calc_recipe_items
SET product_id = sqlc.narg(product_id), material_name = sqlc.arg(material_name),
    unit = sqlc.arg(unit), calculation_type = sqlc.arg(calculation_type),
    quantity_per_m2 = sqlc.arg(quantity_per_m2)::numeric,
    quantity_per_meter = sqlc.arg(quantity_per_meter)::numeric,
    fixed_quantity = sqlc.arg(fixed_quantity)::numeric,
    waste_percent = sqlc.arg(waste_percent)::numeric,
    rounding_type = sqlc.arg(rounding_type),
    min_quantity = sqlc.narg(min_quantity)::numeric,
    package_size = sqlc.narg(package_size)::numeric,
    reference_unit_price = sqlc.arg(reference_unit_price)::numeric,
    group_name = sqlc.arg(group_name), sort_order = sqlc.arg(sort_order),
    is_active = sqlc.arg(is_active), notes = sqlc.narg(notes)
WHERE id = sqlc.arg(id) AND organization_id = sqlc.arg(organization_id)
RETURNING *;

-- name: DeleteCalcRecipeItem :execrows
DELETE FROM calc_recipe_items WHERE id = $1 AND organization_id = $2;

-- ResolveRecipeProducts, bir kategorinin reçete kalemlerinin ürünlerini
-- TEK toplu sorguda çözer (BYZ _resolve_recipe_products ile aynı N+1
-- önleme fikri) -- ama BYZ'nin aksine burada YALNIZCA OKUMA vardır:
-- eksik/0 TL ürün onarılmaz/yaratılmaz, motor katmanı bunun yerine
-- warnings[] üretir (bkz. internal/domain/calc.go). Aynı organization'a
-- ait olmayan bir product_id (olağan dışı bir durum) bilinçli olarak
-- ANY($1) yalnızca id listesini taşır -- organization_id ayrıca WHERE'de
-- doğrulanır, böylece başka bir firmanın ürünü asla sızmaz.
-- name: ResolveRecipeProducts :many
SELECT * FROM products WHERE id = ANY(sqlc.arg(ids)::uuid[]) AND organization_id = sqlc.arg(organization_id);
