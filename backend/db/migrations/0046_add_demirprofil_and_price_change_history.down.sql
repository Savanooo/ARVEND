CREATE INDEX IF NOT EXISTS idx_price_history_product_id ON product_price_history (product_id);
DROP INDEX IF EXISTS idx_price_history_changed_at;
DROP INDEX IF EXISTS idx_price_history_product_changed;

-- reason/source bilgisi not metninde zaten var: satırlar notlarıyla kalır
-- ve up yeniden uygulanırsa aynı notlardan geri sınıflandırılır (Ulaş ve
-- Demir Profil). Kaynak (tedarikçi) fiyatları kaybolur.
ALTER TABLE product_price_history
    DROP COLUMN IF EXISTS new_source_price,
    DROP COLUMN IF EXISTS old_source_price,
    DROP COLUMN IF EXISTS source,
    DROP COLUMN IF EXISTS reason;

ALTER TABLE organization_price_sources DROP COLUMN IF EXISTS last_list_label;

-- 0045'in CHECK'i yalnızca 'ulas'a izin verir: Demir Profil ayarları (ve
-- CASCADE ile kategori oranları) silinir. Ürünler (products.source =
-- 'demirprofil') KALIR -- teklif/reçete bağlantıları kopmasın; yalnızca
-- artık senkronlanmazlar.
DELETE FROM organization_price_sources WHERE source <> 'ulas';
ALTER TABLE organization_price_sources DROP CONSTRAINT organization_price_sources_source_check;
ALTER TABLE organization_price_sources ADD CONSTRAINT organization_price_sources_source_check
    CHECK (source IN ('ulas'));
