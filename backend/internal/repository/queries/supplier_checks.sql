-- Tedarikçi kartı doğrulamaları (procurement.sql'deki CRUD sorgularından
-- ayrı tutuldu -- o dosya satın alma akışının tamamını taşıyor).

-- name: FindSupplierByTaxKey :one
-- Aynı firmada aynı vergi numarasına sahip ilk tedarikçi (arşivdekiler
-- dahil -- arşivdeki kaydı yeniden açmak, yenisini yaratmaktan doğrudur).
-- tax_key: yalnızca harf/rakam, büyük harf (service.customerTaxKey ile
-- AYNI kural); "123 456 78-90" ile "1234567890" aynı numaradır.
SELECT * FROM suppliers
WHERE organization_id = sqlc.arg(organization_id)
  AND (sqlc.narg('exclude_id')::uuid IS NULL OR id <> sqlc.narg('exclude_id')::uuid)
  AND upper(regexp_replace(tax_number, '[^0-9A-Za-z]', '', 'g')) = sqlc.arg(tax_key)::text
ORDER BY is_active DESC, code ASC
LIMIT 1;
