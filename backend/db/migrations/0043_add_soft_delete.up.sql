-- Kullanıcılar ve firmalar için YUMUŞAK SİLME (soft-delete). Fiziksel bir
-- DELETE değildir -- tüm tarihçe (audit/proje/teklif/finans/kullanıcı
-- kayıtları) olduğu gibi kalır. Bu, MEVCUT durum eksenlerinden (users.
-- is_active, organizations.status) BİLİNÇLİ OLARAK AYRI, üçüncü bir
-- eksendir:
--   - users.is_active        : pasif/aktif (Süper Admin/organizasyon
--                               yöneticisi geri döndürebilir, bkz.
--                               ReactivateUser)
--   - organizations.status   : trial/active/suspended/cancelled (iş/
--                               abonelik yaşam döngüsü, bkz. domain/
--                               organization.go CanTransitionTo)
--   - deleted_at/deleted_by  : "normal platform operasyonundan/listesinden
--                               kaldırıldı" -- yukarıdaki İKİSİNDEN de
--                               BAĞIMSIZ. "cancelled" (iş iptali) ile
--                               "silindi" (platform yönetiminden kaldırıldı)
--                               KASITLI OLARAK aynı şey DEĞİLDİR.
--
-- Bir kullanıcı SİLİNDİĞİNDE aynı anda is_active=false de yapılır (bkz.
-- service/user_lifecycle.go deleteUser) -- böylece "silinmiş bir kullanıcı
-- giriş yapamaz" garantisi YENİ bir kod yolu GEREKTİRMEDEN, HALİHAZIRDA var
-- olan is_active kontrolünden (AuthService.Login/Refresh) bedava gelir.
-- Bir firma SİLİNDİĞİNDE status'e DOKUNULMAZ (durum korunur) -- erişim,
-- RequireAuth/AuthService'in HALİHAZIRDA var olan organizasyon durumu
-- kontrolüne deleted_at eklenerek kapatılır (bkz. migration sonrası Go
-- değişiklikleri).

ALTER TABLE users ADD COLUMN deleted_at timestamptz;
ALTER TABLE users ADD COLUMN deleted_by uuid REFERENCES users(id);

ALTER TABLE organizations ADD COLUMN deleted_at timestamptz;
ALTER TABLE organizations ADD COLUMN deleted_by uuid REFERENCES users(id);

-- Kısmi indeksler: "silinmiş kayıtları listele" (Süper Admin'in Arşiv/
-- Silinenler filtresi) sorguları için -- normal (silinmemiş) sorgular
-- zaten birincil anahtar/organization_id indekslerini kullanır, bu
-- indeksler yalnızca deleted_at DOLU satırları hedefler.
CREATE INDEX idx_users_deleted_at ON users (deleted_at) WHERE deleted_at IS NOT NULL;
CREATE INDEX idx_organizations_deleted_at ON organizations (deleted_at) WHERE deleted_at IS NOT NULL;
