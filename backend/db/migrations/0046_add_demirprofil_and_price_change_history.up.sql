-- İkinci tedarikçi kaynağı (Demir Profil / Omega Çelik, demirprofil.com.tr
-- llms-full.txt) + "zam geçmişi": fiyat geçmişi satırı artık NEDEN
-- (elle / tedarikçi listesi / kâr oranı) ve HANGİ kaynaktan değiştiğini
-- ve tedarikçi fiyatının eski/yeni değerini taşır.

-- Kaynak kümesi genişler (0045'te yalnızca 'ulas' vardı). Kategori oranları
-- tablosu kaynağı FK ile buradan aldığı için ayrı bir CHECK'i yok.
ALTER TABLE organization_price_sources DROP CONSTRAINT organization_price_sources_source_check;
ALTER TABLE organization_price_sources ADD CONSTRAINT organization_price_sources_source_check
    CHECK (source IN ('ulas', 'demirprofil'));

-- Son BAŞARILI senkronun liste dönemi ("Eylül 2026"; kaynak vermiyorsa
-- ''). Demir Profil kullanım koşulu: kaynak gösterilirken ay belirtilir.
ALTER TABLE organization_price_sources ADD COLUMN last_list_label varchar(60) NOT NULL DEFAULT '';

-- reason: manual = elle ürün düzenleme, supplier = tedarikçi listesi
-- senkronu, markup = kâr oranı değişikliğiyle yeniden fiyatlama.
-- source: supplier/markup satırlarında kaynak kodu, elle düzenlemede NULL.
-- old/new_source_price: tedarikçi (kâr oranı uygulanmamış) fiyatı --
-- yalnızca products.manage'e döner. numeric(18,2): products.source_price
-- ile aynı genişlik (0026).
-- Aynı transaction'da yazılan satırlar aynı changed_at'i (now()) paylaşır:
-- tek bir senkron/yeniden fiyatlama = (changed_at, source, reason) grubu.
ALTER TABLE product_price_history
    ADD COLUMN reason varchar(20) NOT NULL DEFAULT 'manual'
        CONSTRAINT product_price_history_reason_check CHECK (reason IN ('manual', 'supplier', 'markup')),
    ADD COLUMN source varchar(30),
    ADD COLUMN old_source_price numeric(18, 2),
    ADD COLUMN new_source_price numeric(18, 2);

-- 0045'ten beri yazılan Ulaş satırları (not metinleri sabitti). Kaynak
-- fiyatları o zaman kaydedilmediği için NULL kalır.
-- Demir Profil ve "tedarikçi fiyatı aynı" satırları yalnızca bu migration
-- geri alınıp (down) yeniden uygulanırsa vardır: down reason/source'u
-- düşürür ama satırları notlarıyla bırakır; aynı notlar burada yeniden
-- sınıflandırılır (kaynak fiyatları down'da kaybolmuştur, NULL kalır).
-- Notlar domain.PriceSources() kayıt defterindeki sabit metinlerdir.
UPDATE product_price_history SET reason = 'supplier', source = 'ulas' WHERE note = 'Ulaş fiyat listesi';
UPDATE product_price_history SET reason = 'markup',   source = 'ulas' WHERE note = 'Ulaş kâr oranı güncellendi';
UPDATE product_price_history SET reason = 'markup',   source = 'ulas' WHERE note = 'Ulaş fiyat listesi: tedarikçi fiyatı aynı, kâr oranı yeniden uygulandı';
UPDATE product_price_history SET reason = 'supplier', source = 'demirprofil' WHERE note = 'Demir Profil fiyat listesi' OR note LIKE 'Demir Profil fiyat listesi (%)';
UPDATE product_price_history SET reason = 'markup',   source = 'demirprofil' WHERE note = 'Demir Profil kâr oranı güncellendi';
UPDATE product_price_history SET reason = 'markup',   source = 'demirprofil' WHERE note = 'Demir Profil fiyat listesi: tedarikçi fiyatı aynı, kâr oranı yeniden uygulandı';

-- Zam geçmişi sorguları: firma (products.organization_id üzerinden JOIN) +
-- zaman aralığı. Ürün başına (product_id, changed_at) firmanın ürünlerinden
-- geçmişe iç içe döngüyle, changed_at tek başına kısa aralıklı taramalarla
-- kullanılır. Eski tek kolonlu idx_price_history_product_id (product_id,
-- changed_at) tarafından kapsanır.
CREATE INDEX idx_price_history_product_changed ON product_price_history (product_id, changed_at);
CREATE INDEX idx_price_history_changed_at ON product_price_history (changed_at);
DROP INDEX IF EXISTS idx_price_history_product_id;
