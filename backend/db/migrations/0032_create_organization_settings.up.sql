-- İki tablo, smtp_settings ile AYNI desen: organization_id doğrudan PRIMARY
-- KEY (1 firma = 1 satır, ayrı surrogate id yok), tek upsert sorgusu,
-- "satır yok" = "henüz yapılandırılmadı" (nullable-flag değil). Bilinçli
-- olarak TEK 50-kolonluk tabloya sığdırılmadı (spesifik olarak istenmeyen
-- bir tasarımdı) -- onboarding'in 5 adımına karşılık gelen iki gerçek iş
-- alanına bölündü: "bu firma kim" (profile) ve "bu firma ticari olarak
-- nasıl çalışır" (commercial settings, teklif+finans birlikte -- ikisi de
-- küçük ve aynı "varsayılan ayarlar" ekseninde).

-- organization_profile: kimlik/resmi/iletişim bilgileri (Adım 1+2+5).
-- "Firma adı" için AYRI bir kolon YOK -- organizations.name zaten bu
-- anlamda kullanılıyor, tekrar etmiyoruz.
CREATE TABLE organization_profile (
    organization_id  uuid PRIMARY KEY REFERENCES organizations(id),
    authorized_person varchar(150) NOT NULL DEFAULT '',
    phone            varchar(30)  NOT NULL DEFAULT '',
    email            varchar(150) NOT NULL DEFAULT '',
    website          varchar(200) NOT NULL DEFAULT '',
    logo_object_key  varchar(255) NOT NULL DEFAULT '',
    legal_name       varchar(200) NOT NULL DEFAULT '',
    tax_office       varchar(100) NOT NULL DEFAULT '',
    tax_number       varchar(50)  NOT NULL DEFAULT '',
    invoice_address  text         NOT NULL DEFAULT '',
    city             varchar(100) NOT NULL DEFAULT '',
    district         varchar(100) NOT NULL DEFAULT '',
    country          varchar(100) NOT NULL DEFAULT 'Türkiye',
    -- Sabit bir enum/CHECK yerine validated string (onboarding.go'da
    -- backend-side whitelist ile doğrulanır) -- yeni bir faaliyet alanı
    -- eklemek için migration gerekmesin diye.
    business_type    varchar(30)  NOT NULL DEFAULT '',
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER organization_profile_set_updated_at BEFORE UPDATE ON organization_profile
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- organization_commercial_settings: teklif varsayılanları (Adım 3) + finans/
-- fatura bilgileri (Adım 4) -- IBAN, SMTP şifresi ile birebir aynı
-- SecretBox/AES-GCM deseniyle şifrelenir (internal/platform/crypto), "iban_set"
-- (bool) API'ye dönebilir, "iban" plaintext ASLA HTTP yanıtına yazılmaz.
CREATE TABLE organization_commercial_settings (
    organization_id  uuid PRIMARY KEY REFERENCES organizations(id),
    default_currency varchar(3)   NOT NULL DEFAULT 'TRY',
    default_vat_rate numeric(5,2) NOT NULL DEFAULT 20.00,
    -- Yeni firmalar için varsayılan "TKF" -- Arvend Yapı'nın satırı aşağıda
    -- AÇIKÇA "TKF" ile seed edilir ki mevcut TKF-2026-XXXX teklif numaraları
    -- formatı hiç değişmesin (bkz. internal/service/offer_service.go
    -- generateOfferNo).
    offer_prefix         varchar(10) NOT NULL DEFAULT 'TKF',
    offer_validity_days  int NOT NULL DEFAULT 30,
    default_offer_footer    text NOT NULL DEFAULT '',
    default_payment_terms   text NOT NULL DEFAULT '',
    default_delivery_terms  text NOT NULL DEFAULT '',
    bank_name        varchar(150) NOT NULL DEFAULT '',
    account_holder   varchar(150) NOT NULL DEFAULT '',
    iban_enc         text NOT NULL DEFAULT '',
    payment_due_days int,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER organization_commercial_settings_set_updated_at
    BEFORE UPDATE ON organization_commercial_settings
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Arvend Yapı için satırı açıkça oluştur (offer_prefix='TKF' default zaten
-- doğru değeri veriyor ama satırın VAR OLMASI, generateOfferNo'nun "satır
-- yok -> TKF'ye düş" yoluna değil, gerçek satıra okuması anlamına gelir).
INSERT INTO organization_commercial_settings (organization_id, offer_prefix)
VALUES ('00000000-0000-0000-0000-000000000001', 'TKF');

INSERT INTO organization_profile (organization_id)
VALUES ('00000000-0000-0000-0000-000000000001');
