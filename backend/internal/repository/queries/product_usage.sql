-- Ürün silme öncesi kullanım kontrolü (products.sql'deki CRUD'dan ayrı).

-- name: GetProductUsage :one
-- recipe_items: ürüne bağlı metraj reçete kalemleri (pasifler dahil) --
-- FK'leri ON DELETE SET NULL olduğu için silme onları SESSİZCE ürünsüz
-- bırakıyordu (sonraki hesaplamalar 0 TL ile "product_missing" uyarısı
-- üretir). change_order_items: ek iş kalemleri -- FK'leri kısıtlayıcıdır,
-- silme ham bir Postgres hatasıyla düşüyordu. Teklif kalemleri SAYILMAZ:
-- onlar ürün adı/fiyatının anlık görüntüsünü taşır ve bağın kopması
-- tasarım gereğidir (bkz. migration 0017).
SELECT
    (SELECT count(*) FROM calc_recipe_items cri
      WHERE cri.product_id = sqlc.arg(id) AND cri.organization_id = sqlc.arg(organization_id))::bigint AS recipe_items,
    (SELECT count(*) FROM project_change_order_items coi
      WHERE coi.product_id = sqlc.arg(id) AND coi.organization_id = sqlc.arg(organization_id))::bigint AS change_order_items;
