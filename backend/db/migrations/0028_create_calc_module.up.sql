-- Metraj Hesaplama (malzeme miktarı hesaplama) modülü.
--
-- BYZ (eski Flask/Mongo sistem) analizinden yeniden tasarlandı --
-- BİREBİR PORT DEĞİL. BYZ'nin taşınmayan teknik borçları (bkz.
-- docs/byz-metraj-hesaplama-analizi.md §11):
--   - Fire (waste) hiç uygulanmıyordu -> burada gerçek bir kolon ve
--     motor adımı (waste_percent).
--   - min_quantity / package_size hiç yoktu -> burada ilk sınıf kolonlar.
--   - Alan (area) verildiğinde çevre HİÇBİR ZAMAN hesaplanmıyordu (kare
--     varsayımı da yoktu) -> burada area/perimeter/pitch_deg BAĞIMSIZ
--     girdilerdir; çağıran ikisini birlikte de gönderebilir.
--   - Çatı eğimi yalnızca istemcide (JS /cos()) uygulanıyordu -> burada
--     motor SUNUCUDA hesaplar (bkz. internal/domain/calc.go).
--   - Ürün bulunamazsa hesaplama sırasında OTOMATİK ürün yaratılıyor/
--     onarılıyordu (okuma yolunda yazma) -> bu şemada YOK; motor salt
--     okur, eksik/0 TL ürün yalnızca warnings[] üretir.
--   - total_cost, YUVARLANMAMIŞ satır toplamlarının toplamıydı (satırlar
--     ayrı yuvarlandığı için ±0,01 fark oluşuyordu) -> burada toplam,
--     ZATEN yuvarlanmış satırların toplamıdır (bkz. domain.CalcEngine).
--
-- PARA/MİKTAR: Faz 6/7/8'deki ilkeyle aynı -- Go float64 aritmetiği
-- yerine PostgreSQL numeric (yazma yollarında) ve shopspring/decimal
-- (salt-okur hesap motorunda, bkz. internal/domain/calc.go) kullanılır.
--
-- TENANT İZOLASYONU: üç tablo da organization_id taşır; her sorgu bu
-- alanla filtrelenir (bkz. internal/repository/queries/calc.sql) --
-- Firma A'nın grup/kategori/reçetesi Firma B'ye asla görünmez.

CREATE TABLE calc_groups (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid NOT NULL REFERENCES organizations(id),
    slug             varchar(80) NOT NULL,
    name             varchar(120) NOT NULL,
    description      text NOT NULL DEFAULT '',
    sort_order       int NOT NULL DEFAULT 0,
    is_active        boolean NOT NULL DEFAULT true,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    UNIQUE (organization_id, slug)
);

CREATE INDEX idx_calc_groups_org ON calc_groups (organization_id, is_active, sort_order);

CREATE TRIGGER calc_groups_set_updated_at BEFORE UPDATE ON calc_groups
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE calc_categories (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid NOT NULL REFERENCES organizations(id),
    -- ON DELETE clause BİLİNÇLİ olarak yok (RESTRICT): bir grup, altında
    -- kategori varken silinemez -- referans veriyi (ve olası
    -- calc_snapshot geçmiş kayıtlarını) sessizce yetim bırakmamak için.
    -- Admin önce kategorileri pasifleştirmeli/silmelidir.
    group_id         uuid NOT NULL REFERENCES calc_groups(id),
    slug             varchar(80) NOT NULL,
    name             varchar(160) NOT NULL,
    description      text NOT NULL DEFAULT '',
    -- Genel bir organizasyon-seviyesi dosya deposu şeması henüz yok
    -- (yalnızca proje-kapsamlı project_files var); bu yüzden burada
    -- kasıtlı olarak FK YOK -- ileride eklenecek bir "files" tablosuna
    -- bağlanmak üzere ayrılmış, serbest bir referans alanı.
    image_file_id    uuid,
    sort_order       int NOT NULL DEFAULT 0,
    is_active        boolean NOT NULL DEFAULT true,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    UNIQUE (organization_id, slug)
);

CREATE INDEX idx_calc_categories_group ON calc_categories (group_id, is_active, sort_order);
CREATE INDEX idx_calc_categories_org ON calc_categories (organization_id);

CREATE TRIGGER calc_categories_set_updated_at BEFORE UPDATE ON calc_categories
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE calc_recipe_items (
    id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id        uuid NOT NULL REFERENCES organizations(id),
    -- ON DELETE clause yok (RESTRICT), calc_categories ile aynı gerekçe.
    category_id            uuid NOT NULL REFERENCES calc_categories(id),
    -- Ürün silinirse reçete kalemi YETİM KALMAZ -- product_id NULL'a
    -- düşer, bir sonraki hesaplamada 'product_missing' warning üretir
    -- (offer_revision_items.product_id ile AYNI ilke).
    product_id             uuid REFERENCES products(id) ON DELETE SET NULL,
    material_name          varchar(200) NOT NULL,
    unit                   varchar(30) NOT NULL,
    calculation_type       varchar(20) NOT NULL
                           CHECK (calculation_type IN ('area_based', 'perimeter_based', 'fixed')),
    -- 6 ondalık hane: BYZ'deki 1/3.6, 1/200 gibi kesirli kaplama
    -- katsayılarını (paket başına kapsama alanının tersini) kayıpsız
    -- taşıyabilmek için (bkz. docs/byz-metraj-hesaplama-analizi.md §10).
    quantity_per_m2        numeric(14, 6) NOT NULL DEFAULT 0 CHECK (quantity_per_m2 >= 0),
    quantity_per_meter     numeric(14, 6) NOT NULL DEFAULT 0 CHECK (quantity_per_meter >= 0),
    fixed_quantity         numeric(14, 4) NOT NULL DEFAULT 0 CHECK (fixed_quantity >= 0),
    -- Fire: BYZ'de bu alan YAZILIYOR ama motor tarafından HİÇ
    -- OKUNMUYORDU (rapor §11.1) -- burada gerçekten hesaba katılır,
    -- bkz. internal/domain/calc.go ComputeRecipeQuantity.
    waste_percent           numeric(5, 2) NOT NULL DEFAULT 0 CHECK (waste_percent >= 0),
    rounding_type           varchar(10) NOT NULL DEFAULT 'none'
                            CHECK (rounding_type IN ('none', 'ceil', 'round')),
    -- min_quantity/package_size BYZ'de hiç yoktu; BYZ bunun yerine
    -- "quantity_per_m2 = 1/paket_kapsamı + rounding_type=ceil" gibi
    -- dolaylı bir kalıp kullanıyordu (rapor §10). Burada paket kuralı
    -- ayrı, açık bir alandır: quantity_per_m2/meter/fixed HAM MALZEME
    -- ihtiyacını, package_size ise satın alma artışını temsil eder.
    min_quantity            numeric(14, 4) CHECK (min_quantity IS NULL OR min_quantity >= 0),
    package_size            numeric(14, 4) CHECK (package_size IS NULL OR package_size > 0),
    -- Fiyat hesap ANINDA HER ZAMAN products.unit_price'tan okunur
    -- (bkz. calc.sql ResolveRecipeProducts); bu yalnızca ürün silinmiş/
    -- henüz bağlanmamışsa admin ekranında referans olarak gösterilir.
    reference_unit_price    numeric(18, 2) NOT NULL DEFAULT 0 CHECK (reference_unit_price >= 0),
    group_name               varchar(60) NOT NULL DEFAULT '',
    sort_order               int NOT NULL DEFAULT 0,
    is_active                boolean NOT NULL DEFAULT true,
    notes                    text,
    created_at               timestamptz NOT NULL DEFAULT now(),
    updated_at               timestamptz NOT NULL DEFAULT now(),
    -- BYZ'de aynı (ad, birim) farklı fiyatlarla birden çok kez
    -- girilebiliyordu (rapor §6, "Çelik Dübel 4 vs 0" gibi çelişkiler).
    -- Bu kısıt, aynı kategoride aynı malzemenin kazara iki kez
    -- girilmesini DB seviyesinde engeller.
    UNIQUE (category_id, material_name, unit)
);

CREATE INDEX idx_calc_recipe_items_category ON calc_recipe_items (category_id, is_active, sort_order);
CREATE INDEX idx_calc_recipe_items_org ON calc_recipe_items (organization_id);
CREATE INDEX idx_calc_recipe_items_product ON calc_recipe_items (product_id) WHERE product_id IS NOT NULL;

CREATE TRIGGER calc_recipe_items_set_updated_at BEFORE UPDATE ON calc_recipe_items
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
