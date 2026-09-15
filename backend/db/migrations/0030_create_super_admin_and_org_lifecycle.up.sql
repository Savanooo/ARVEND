-- Platform seviyesinde SUPER ADMIN, organization Owner/Admin'den kesinlikle
-- farklı bir kavramdır: platform sahibidir, herhangi bir firmaya (organization)
-- bağlı DEĞİLDİR. Mevcut role modeli (users.role: 'admin'|'kullanici', tek
-- middleware.RequireRole eşitlik kontrolü) zaten "role = yetkilendirme ekseni"
-- deseninde -- bu deseni bozmadan üçüncü bir değer ekliyoruz. Ayrı bir
-- platform_admins tablosu veya "fake organization"a bağlama YOK -- spesifik
-- olarak istenmeyen bir çözümdü.
--
-- users.organization_id bu yüzden NULLABLE olur: NULL = platform seviyesinde
-- hesap, herhangi bir firma verisine erişimi yok. Mevcut TÜM organization-
-- scoped sorgular zaten "WHERE organization_id = $1" şeklinde filtreliyor
-- (bkz. GetUserByIDInOrg/ListUsers/CountUsers/...) -- NULL bir satır bu
-- eşitlik koşuluna asla uymaz, dolayısıyla mevcut hiçbir sorgu davranış
-- değiştirmeden güvenli kalır (NULL, hiçbir zaman sessizce "eşleşen" bir
-- organization_id olarak yorumlanamaz).
ALTER TABLE users ALTER COLUMN organization_id DROP NOT NULL;

ALTER TABLE users DROP CONSTRAINT users_role_check;
ALTER TABLE users ADD CONSTRAINT users_role_check
    CHECK (role IN ('admin', 'kullanici', 'super_admin'));

-- super_admin satırlarının organization_id'si HER ZAMAN NULL, diğer
-- rollerin HER ZAMAN dolu olmalı -- CHECK constraint ile veritabanı
-- seviyesinde garanti ediyoruz (yalnızca servis katmanına güvenmiyoruz).
ALTER TABLE users ADD CONSTRAINT users_super_admin_has_no_org
    CHECK (
        (role = 'super_admin' AND organization_id IS NULL) OR
        (role <> 'super_admin' AND organization_id IS NOT NULL)
    );

-- "must_change_password" bu ürün için tamamen yeni bir kavram (repo genelinde
-- grep'te sıfır önceki emsal bulundu). Super Admin'in oluşturduğu her Owner
-- hesabı bunu true ile başlar; normal kullanıcı yönetimi akışları
-- (admin reset dahil) bilinçli olarak DOKUNMUYOR -- yalnızca yeni Owner
-- provisioning akışı bunu true set eder.
ALTER TABLE users ADD COLUMN must_change_password boolean NOT NULL DEFAULT false;

-- Organization yaşam döngüsü. Mevcut is_active boolean'ı KALDIRILMIYOR
-- (hiçbir mevcut kod onu enforcement için okumuyor, ama backward-compat
-- için dokunmuyoruz) -- yeni "status" asıl enforcement ekseni olur, servis
-- katmanı is_active'i status ile birlikte günceller (bkz.
-- PlatformService.Suspend/Activate). status='trial' de "aktif" sayılır
-- (deneme süresindeki firma normal çalışır).
ALTER TABLE organizations ADD COLUMN status varchar(20) NOT NULL DEFAULT 'active'
    CHECK (status IN ('active', 'trial', 'suspended', 'cancelled'));
ALTER TABLE organizations ADD COLUMN trial_ends_at timestamptz;
ALTER TABLE organizations ADD COLUMN onboarding_completed boolean NOT NULL DEFAULT false;
ALTER TABLE organizations ADD COLUMN onboarding_completed_at timestamptz;
-- onboarding_step: kullanıcının kaldığı/sıradaki adım. Veri varlığından
-- TÜRETİLMEZ (finans adımındaki IBAN gibi alanlar bilinçli olarak opsiyonel
-- olduğu için "veri var mı" tek başına "adım tamamlandı mı" sorusuna güvenilir
-- cevap vermez) -- açık, tek yazarlı bir işaretçi: her PUT /onboarding/<step>
-- ucu bu adımı işledikten sonra sıradaki adıma ilerletir (asla geriletmez).
ALTER TABLE organizations ADD COLUMN onboarding_step varchar(20) NOT NULL DEFAULT 'company'
    CHECK (onboarding_step IN ('company', 'billing', 'offers', 'finance', 'business', 'completed'));

-- Mevcut production organizasyonu ("Arvend Yapı") halihazırda ÇALIŞAN bir
-- sistemdir -- yanlışlıkla onboarding'e zorlanmasın. Gerçek veri incelendi:
-- offers/projects/customers/calc_recipe_items dolu, günlerdir aktif
-- kullanılıyor -- bu bir "yeni firma" değil.
UPDATE organizations
SET status = 'active',
    onboarding_completed = true,
    onboarding_completed_at = now(),
    onboarding_step = 'completed'
WHERE id = '00000000-0000-0000-0000-000000000001';
