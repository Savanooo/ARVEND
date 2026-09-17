-- İç Taşeron Fiyatlama (Internal Subcontract Pricing) -- teklif hazırlarken
-- kalem bazında GİZLİ bir maliyet tabanı ve fiyatlama modu kaydedilir.
-- Bu, calc_snapshot'taki (Metraj) müşteri fiyatlandırma verisinden TAMAMEN
-- AYRI bir eksendir -- calc_snapshot "bu fiyata nasıl ulaşıldığı"nı donduran
-- MÜŞTERİYE AÇIK bir kayıttır, internal_subcontract_cost ise ASLA müşteriye
-- gösterilmeyen bir İÇ maliyet varsayımıdır.
--
-- KRİTİK -- GÜVENLİK SINIRI: bu üç kolon offer_revision_items'a (teklifin
-- KENDİ satırına, calc_snapshot İLE AYNI "asla mutate edilmez" ilkesiyle)
-- eklenir, AYRI bir tablo İCAT EDİLMEZ -- ama bu kolonlar HTTP serialization
-- katmanında (bkz. backend/internal/httpapi/handler/offer_handler.go)
-- BİLİNÇLİ OLARAK varsayılan olarak dışlanır: toOfferResponse/
-- toOfferRevisionResponse bunları ASLA döndürmez (public/paylaşım linki
-- ve e-posta gövdesi -- zaten hiç kalem içermiyor -- bu fonksiyonları
-- kullanır); yalnızca offers.internal_pricing.read izni olan personel için
-- ayrı bir opt-in adımda (attachInternalPricing) eklenir. Bkz.
-- docs/ (varsa) veya bu migration'ın PR açıklaması.
--
-- expected_profit/effective_markup_percent KASITLI OLARAK PERSIST EDİLMEZ
-- (redundant hesaplanmış değer yerine OTORİTER girdi saklanır ilkesi) --
-- unit_price (satış fiyatı) zaten mevcut kolon, ikisinden HER ZAMAN canlı
-- türetilir.
ALTER TABLE offer_revision_items
    ADD COLUMN internal_subcontract_cost numeric(12, 2) CHECK (internal_subcontract_cost IS NULL OR internal_subcontract_cost >= 0),
    -- 'markup': unit_price = internal_subcontract_cost * (1 + markup_percent/100), SUNUCUDA
    --   otoriter olarak hesaplanır (istemcinin gönderdiği unit_price bu modda YOK SAYILIR).
    -- 'manual': unit_price kullanıcının elle girdiği değerdir, ASLA maliyet/markup'tan
    --   otomatik ÜZERİNE YAZILMAZ -- yalnızca bilgilendirici kâr/marj türetimi için
    --   internal_subcontract_cost ile birlikte okunur.
    ADD COLUMN pricing_mode varchar(10) CHECK (pricing_mode IS NULL OR pricing_mode IN ('markup', 'manual')),
    ADD COLUMN markup_percent numeric(6, 2);

-- ---------------------------------------------------------------------------
-- İzin kayıt defteri genişletmesi -- İÇ maliyet/marj/kâr ticari açıdan
-- HASSAS bilgidir, teklifi okuyabilen HERKESE otomatik açılmaz (offers.read
-- İLE KARIŞTIRILMAMALI). Bir onay durumu/yaşam döngüsü YOKTUR (Collection/
-- SubcontractPayment İLE AYNI ilke) -- yalnızca read/manage ikilisi.
-- ---------------------------------------------------------------------------
INSERT INTO permissions (code, description, category) VALUES
    ('offers.internal_pricing.read',   'Teklif kalemlerindeki iç taşeron maliyeti/marj/beklenen kârı görüntüleme', 'Teklifler'),
    ('offers.internal_pricing.manage', 'Teklif kalemlerine iç taşeron maliyeti/fiyatlama modu girme veya düzenleme', 'Teklifler');

-- ---------------------------------------------------------------------------
-- seed_system_roles_for_org GÜNCELLENİR (CREATE OR REPLACE) -- owner/admin
-- bloğu DEĞİŞMEDİ. Rol matrisi:
--
--   finance: read+manage -- iç maliyet/kârlılık verisinin "doğal sahibi".
--   legacy_user / project_manager / field: HİÇBİRİ -- BİLİNÇLİ OLARAK
--     verilmez (spec: "Do not automatically expose... to every user who
--     can merely read an offer"). legacy_user offers.* İÇİN geniş erişime
--     sahip olsa da (migration 0004'ten kalma legacy davranış), İÇ MALİYET
--     TAMAMEN YENİ bir kavramdır -- geriye dönük uyumluluk gerekçesi
--     GEÇERLİ DEĞİLDİR, bu yüzden legacy_user'a da OTOMATİK verilmez.
--     İhtiyaç halinde bir admin, Roller & Yetkiler ekranından elle
--     ekleyebilir.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION seed_system_roles_for_org(org_id uuid) RETURNS void AS $$
DECLARE
    r_owner uuid;
    r_admin uuid;
    r_legacy uuid;
    r_pm uuid;
    r_finance uuid;
    r_field uuid;
BEGIN
    INSERT INTO organization_roles (organization_id, code, name, description, is_system)
    VALUES (org_id, 'owner', 'Sahip (Owner)', 'Firmadaki tüm izinlere sahiptir; son sahip kaldırılamaz.', true)
    RETURNING id INTO r_owner;
    INSERT INTO organization_roles (organization_id, code, name, description, is_system)
    VALUES (org_id, 'admin', 'Yönetici', 'Firmadaki tüm izinlere sahiptir.', true)
    RETURNING id INTO r_admin;
    INSERT INTO organization_roles (organization_id, code, name, description, is_system)
    VALUES (org_id, 'legacy_user', 'Kullanıcı (Eski Sistem)', 'Migration öncesi "kullanıcı" rolünün izin karşılığı -- yeni kullanıcılara atanmaz.', true)
    RETURNING id INTO r_legacy;
    INSERT INTO organization_roles (organization_id, code, name, description, is_system)
    VALUES (org_id, 'project_manager', 'Proje Yöneticisi', 'Yalnızca atandığı projelerde operasyonel yönetim yapar.', true)
    RETURNING id INTO r_pm;
    INSERT INTO organization_roles (organization_id, code, name, description, is_system)
    VALUES (org_id, 'finance', 'Finans', 'Yalnızca atandığı projelerin finansal verilerini yönetir.', true)
    RETURNING id INTO r_finance;
    INSERT INTO organization_roles (organization_id, code, name, description, is_system)
    VALUES (org_id, 'field', 'Saha', 'Yalnızca atandığı projelerde saha operasyonu (görev/dosya/fotoğraf) yapar.', true)
    RETURNING id INTO r_field;

    INSERT INTO role_permissions (organization_role_id, permission_code)
    SELECT r_owner, code FROM permissions;
    INSERT INTO role_permissions (organization_role_id, permission_code)
    SELECT r_admin, code FROM permissions;

    INSERT INTO role_permissions (organization_role_id, permission_code)
    SELECT r_legacy, code FROM permissions WHERE code IN (
        'projects.read', 'projects.create', 'projects.update',
        'projects.finance.read', 'projects.finance.manage',
        'projects.tasks.read', 'projects.tasks.create', 'projects.tasks.update',
        'projects.operations.read', 'projects.operations.manage',
        'projects.access.read',
        'offers.read', 'offers.create', 'offers.update', 'offers.approve', 'offers.delete',
        'calculations.read', 'products.read',
        'customers.read', 'customers.manage',
        'employees.read',
        'attendance.read', 'attendance.manage',
        'projects.budget.read', 'projects.budget.manage',
        'projects.cost_control.read', 'projects.cost_control.manage',
        'organization.cost_codes.read',
        'projects.contracts.read', 'projects.contracts.manage',
        'organization.suppliers.read',
        'projects.procurement.read', 'projects.procurement.manage',
        'projects.subcontracts.read', 'projects.subcontracts.manage',
        'projects.subcontract_claims.read', 'projects.subcontract_claims.manage',
        'projects.subcontract_payments.read'
    );

    INSERT INTO role_permissions (organization_role_id, permission_code)
    SELECT r_pm, code FROM permissions WHERE code IN (
        'projects.read', 'projects.update',
        'projects.tasks.read', 'projects.tasks.create', 'projects.tasks.update',
        'projects.operations.read', 'projects.operations.manage',
        'projects.access.read',
        'calculations.read', 'products.read', 'customers.read',
        'projects.budget.read', 'projects.cost_control.read',
        'organization.cost_codes.read',
        'projects.contracts.read', 'projects.contracts.manage',
        'organization.suppliers.read',
        'projects.procurement.read', 'projects.procurement.manage',
        'projects.subcontracts.read', 'projects.subcontracts.manage',
        'projects.subcontract_claims.read', 'projects.subcontract_claims.manage',
        'projects.subcontract_payments.read'
    );

    INSERT INTO role_permissions (organization_role_id, permission_code)
    SELECT r_finance, code FROM permissions WHERE code IN (
        'projects.read', 'projects.finance.read', 'projects.finance.manage',
        'projects.budget.read', 'projects.budget.manage',
        'projects.cost_control.read', 'projects.cost_control.manage',
        'organization.cost_codes.read', 'organization.cost_codes.manage',
        'projects.contracts.read', 'projects.contracts.manage', 'projects.contracts.lifecycle',
        'organization.suppliers.read', 'organization.suppliers.manage',
        'projects.procurement.read', 'projects.procurement.manage', 'projects.procurement.approve',
        'projects.subcontracts.read', 'projects.subcontracts.manage', 'projects.subcontracts.approve',
        'projects.subcontract_claims.read', 'projects.subcontract_claims.manage', 'projects.subcontract_claims.certify',
        'projects.subcontract_payments.read', 'projects.subcontract_payments.manage',
        'offers.internal_pricing.read', 'offers.internal_pricing.manage'
    );

    INSERT INTO role_permissions (organization_role_id, permission_code)
    SELECT r_field, code FROM permissions WHERE code IN (
        'projects.read',
        'projects.tasks.read', 'projects.tasks.update',
        'projects.operations.read', 'projects.operations.manage',
        'attendance.read'
    );
END;
$$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------------
-- MEVCUT organizasyonların ZATEN seed edilmiş rollerine yeni izinleri
-- BACKFILL et (migration 0035/.../0039 İLE AYNI gerekçe) -- yalnızca
-- owner/admin/finance; legacy_user/project_manager/field BİLİNÇLİ OLARAK
-- backfill edilmez (yukarıdaki rol matrisi gerekçesiyle AYNI).
-- ---------------------------------------------------------------------------
INSERT INTO role_permissions (organization_role_id, permission_code)
SELECT orole.id, p.code
FROM organization_roles orole
CROSS JOIN permissions p
WHERE orole.code IN ('owner', 'admin', 'finance')
  AND p.code IN ('offers.internal_pricing.read', 'offers.internal_pricing.manage')
ON CONFLICT (organization_role_id, permission_code) DO NOTHING;
