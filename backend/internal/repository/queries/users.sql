-- name: CreateUser :one
INSERT INTO users (organization_id, username, password_hash, full_name, role)
VALUES ($1, $2, $3, $4, $5)
RETURNING *;

-- name: GetUserByID :one
SELECT * FROM users WHERE id = $1;

-- name: GetUserByIDInOrg :one
SELECT * FROM users WHERE id = $1 AND organization_id = $2;

-- name: GetUserByUsername :one
SELECT * FROM users WHERE username = $1;

-- name: ListUsers :many
-- Silinmiş kullanıcılar normal listeden HER ZAMAN dışarıda kalır (bkz.
-- migration 0043 başlık notu) -- ayrı bir "Silinenler" görünümü için
-- ListDeletedUsersWithOrganizationRole kullanılır.
SELECT * FROM users
WHERE organization_id = $1 AND deleted_at IS NULL
ORDER BY created_at DESC
LIMIT $2 OFFSET $3;

-- name: CountUsers :one
SELECT count(*) FROM users WHERE organization_id = $1 AND deleted_at IS NULL;

-- name: CountActiveUsers :one
SELECT count(*) FROM users WHERE organization_id = $1 AND is_active = true AND deleted_at IS NULL;

-- name: UpdateUser :one
UPDATE users
SET full_name = $3, role = $4, is_active = $5
WHERE id = $1 AND organization_id = $2
RETURNING *;

-- name: UpdateUserPassword :execrows
UPDATE users SET password_hash = $3 WHERE id = $1 AND organization_id = $2;

-- name: TouchLastLogin :exec
UPDATE users SET last_login_at = now() WHERE id = $1;

-- name: DeactivateUser :execrows
UPDATE users SET is_active = false WHERE id = $1 AND organization_id = $2;

-- name: CreateUserWithOptions :one
-- Platform seviyesi kullanıcı oluşturma (Super Admin CLI: organization_id
-- NULL, role='super_admin') VE Super Admin'in yeni firma için provision
-- ettiği ilk Owner (organization_id dolu, must_change_password=true) --
-- CreateUser'ın aksine her iki alan da parametreli.
INSERT INTO users (organization_id, username, password_hash, full_name, role, must_change_password)
VALUES ($1, $2, $3, $4, $5, $6)
RETURNING *;

-- name: SetPasswordAndClearMustChange :execrows
-- İlk giriş "şifre belirle" akışı: parolayı değiştirir VE
-- must_change_password bayrağını temizler, tek sorguda. YALNIZCA bayrak
-- açıkken: bu uç mevcut şifreyi sormaz -- bayrak koşulu olmasaydı açık
-- oturumu olan herkes (ör. kilitlenmemiş bir telefon) şifreyi bilmeden
-- değiştirebilirdi. 0 satır = bayrak kapalı (ya da kullanıcı yok).
UPDATE users SET password_hash = $3, must_change_password = false
WHERE id = $1 AND organization_id = $2 AND must_change_password = true;

-- name: ListUsersWithOrganizationRole :many
-- "Kullanıcılar" ekranının RBAC/Project Membership sprint'iyle
-- genişletilmiş listesi -- her kullanıcının organizasyon rol kodu/adı da
-- AYNI sorguda (N+1 yok). super_admin bu listede HİÇ görünmez zaten
-- (organization_id filtresiyle doğal olarak dışarıda kalır). Silinmiş
-- kullanıcılar HER ZAMAN dışarıda -- bkz. ListDeletedUsersWithOrganizationRole.
--
-- Bağlı personel kaydı (varsa) da aynı satırda: "kişi = tek kayıt"
-- (bkz. queries/employees.sql) -- kullanıcı ekranı hesabın hangi
-- personele bağlı olduğunu (ya da hiç bağlı olmadığını) gösterir. Bir hesap
-- en fazla bir personele bağlanabildiği için (idx_employees_user_id) JOIN
-- satır çoğaltmaz.
SELECT u.*, orole.code AS organization_role_code, orole.name AS organization_role_name,
       emp.id AS employee_id, emp.full_name AS employee_full_name, emp.is_active AS employee_is_active
FROM users u
LEFT JOIN organization_roles orole ON orole.id = u.organization_role_id
LEFT JOIN employees emp ON emp.user_id = u.id AND emp.organization_id = u.organization_id
WHERE u.organization_id = $1 AND u.deleted_at IS NULL
-- id ikincil sıralama: aynı anda oluşturulmuş kullanıcılar (ör. toplu
-- aktarım) sayfa sınırında iki sayfada birden görünmesin / kaybolmasın.
ORDER BY u.created_at DESC, u.id
LIMIT $2 OFFSET $3;

-- name: ListDeletedUsersWithOrganizationRole :many
-- Süper Admin'in "Silinenler" (Arşiv) görünümü -- ListUsersWithOrganizationRole
-- İLE AYNI şekil, yalnızca WHERE koşulu ters (deleted_at DOLU).
SELECT u.*, orole.code AS organization_role_code, orole.name AS organization_role_name
FROM users u
LEFT JOIN organization_roles orole ON orole.id = u.organization_role_id
WHERE u.organization_id = $1 AND u.deleted_at IS NOT NULL
ORDER BY u.deleted_at DESC
LIMIT $2 OFFSET $3;

-- name: CountDeletedUsers :one
SELECT count(*) FROM users WHERE organization_id = $1 AND deleted_at IS NOT NULL;

-- name: GetUserWithOrganizationRole :one
-- Bağlı personel kaydı ListUsersWithOrganizationRole ile aynı gerekçeyle.
SELECT u.*, orole.code AS organization_role_code, orole.name AS organization_role_name,
       emp.id AS employee_id, emp.full_name AS employee_full_name, emp.is_active AS employee_is_active
FROM users u
LEFT JOIN organization_roles orole ON orole.id = u.organization_role_id
LEFT JOIN employees emp ON emp.user_id = u.id AND emp.organization_id = u.organization_id
WHERE u.id = $1 AND u.organization_id = $2;

-- name: GetOnboardingGateStatus :one
-- middleware.RequireOnboarded'ın her "business" istekte çağırdığı hafif
-- sorgu -- must_change_password (users) VE onboarding_completed
-- (organizations) TEK JOIN'le, iki ayrı PK üzerinden (hızlı). Yalnızca
-- organization_id dolu (super_admin olmayan) kullanıcılar için çağrılır --
-- super_admin bu JOIN'e hiç girmeden, rol kontrolüyle daha önce muaf
-- tutulur.
--
-- Aynı satırdan kullanıcının GÜNCEL durumu da okunur (is_active, silinme,
-- kaba rol): access token 15 dakika geçerli ve rolü içinde taşıyor --
-- pasifleştirilen ya da yetkisi düşürülen biri token'ın ömrü boyunca
-- çalışmaya devam ediyordu. Ek sorgu yok, zaten okunan satır.
SELECT u.must_change_password, o.onboarding_completed,
       u.is_active, (u.deleted_at IS NOT NULL)::boolean AS user_deleted,
       u.role, u.organization_id
FROM users u
JOIN organizations o ON o.id = u.organization_id
WHERE u.id = $1;

-- name: GetUserGateStatus :one
-- RequireActiveUser'ın hafif okuması: requireOnboarded ALMAYAN uçlarda
-- (onboarding, firma ayarları, ilk şifre, cihaz kaydı...) aynı "kullanıcı
-- hâlâ aktif mi, rolü ne" kontrolü.
SELECT u.is_active, (u.deleted_at IS NOT NULL)::boolean AS user_deleted,
       u.role, u.organization_id
FROM users u
WHERE u.id = $1;

-- name: ReactivateUser :execrows
UPDATE users SET is_active = true WHERE id = $1 AND organization_id = $2;

-- name: SetUserCoarseRole :exec
-- Organizasyon rolü değiştiğinde kaba users.role'ü (requireAdmin kapısı ve
-- web kabuğu seçimi hâlâ buna bakar) senkron tutar: owner/admin -> 'admin',
-- diğerleri -> 'kullanici'. super_admin satırına ASLA dokunmaz.
UPDATE users SET role = $3
WHERE id = $1 AND organization_id = $2 AND role <> 'super_admin';

-- name: ResetPasswordRequireChange :execrows
-- Süper Admin'in geçici şifre yeniden vermesi: parola + must_change_password
-- =true tek sorguda -- kullanıcı ilk girişte yeniden şifre belirlemek zorunda.
UPDATE users SET password_hash = $3, must_change_password = true
WHERE id = $1 AND organization_id = $2;

-- name: UpdateUserProfile :one
-- Kullanıcının kendi organizasyon-rolünden BAĞIMSIZ profil alanları
-- (ad soyad + aktiflik) -- kaba users.role BİLEREK burada DEĞİŞTİRİLMEZ:
-- o alan artık organizasyon rolünden türetilir (bkz. setUserOrganizationRole/
-- SetUserCoarseRole), bu uçtan bağımsız yazılırsa ikisi birbirinden
-- sapar (requireAdmin kapısı ve /admin vs /panel kabuk seçimi bozulur).
UPDATE users
SET full_name = $3, is_active = $4
WHERE id = $1 AND organization_id = $2
RETURNING *;

-- name: SoftDeleteUser :execrows
-- Yumuşak silme: is_active de AYNI anda false yapılır (bkz. migration
-- 0043 başlık notu -- "silinmiş kullanıcı giriş yapamaz" garantisi
-- HALİHAZIRDA var olan is_active kontrolünden bedava gelir). Zaten
-- silinmiş bir satırda 0 satır günceller (idempotent-safe: servis
-- katmanı bunu ErrAlreadyDeleted'e çevirir).
UPDATE users
SET deleted_at = now(), deleted_by = $3, is_active = false
WHERE id = $1 AND organization_id = $2 AND deleted_at IS NULL;

-- name: RestoreUser :execrows
-- Yalnızca silme durumunu geri alır -- is_active BİLİNÇLİ OLARAK
-- dokunulmadan false kalır (bkz. service/user_lifecycle.go restoreUser
-- yorumu): geri yüklenen kullanıcı "Pasif" olarak listeye döner, giriş
-- erişimi AYRI ve açık bir "Aktifleştir" eylemiyle verilir.
UPDATE users
SET deleted_at = NULL, deleted_by = NULL
WHERE id = $1 AND organization_id = $2 AND deleted_at IS NOT NULL;
