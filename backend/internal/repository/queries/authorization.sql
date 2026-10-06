-- name: SeedSystemRolesForOrg :exec
-- migration 0034'te tanımlanan seed_system_roles_for_org(uuid) DB
-- fonksiyonunu çağırır -- HER YENİ organizasyon için (Platform Service'in
-- CreateOrganizationWithOwner'ı) AYNI 6 sistem rolünü (owner/admin/
-- legacy_user/project_manager/finance/field) + varsayılan izin eşlemesini
-- seed eder. Migration'daki mevcut-organizasyonlar backfill'i ile AYNI TEK
-- kaynak (DRY) -- iki ayrı seed mantığı YOKTUR.
SELECT seed_system_roles_for_org($1);

-- ============ İzin Kataloğu (global, salt okunur) ============

-- name: ListPermissions :many
SELECT * FROM permissions ORDER BY category ASC, code ASC;

-- ============ Organizasyon Rolleri ============

-- name: ListOrganizationRoles :many
-- legacy_user, web rol seçicisinde ASLA gösterilmemelidir (handler/service
-- katmanında filtrelenir) -- burada TÜM sistem rolleri döner, filtreleme
-- bilinçli olarak Go tarafında yapılır (spec: super_admin'in tenant
-- dropdown'ında hiç görünmemesiyle aynı ilke, ama legacy_user farklı bir
-- sebeple -- geriye dönük uyumluluk artığı, yeni atama hedefi değil).
SELECT * FROM organization_roles WHERE organization_id = $1 ORDER BY is_system DESC, name ASC;

-- name: GetOrganizationRoleByID :one
SELECT * FROM organization_roles WHERE id = $1 AND organization_id = $2;

-- name: GetOrganizationRoleByCode :one
SELECT * FROM organization_roles WHERE organization_id = $1 AND code = $2;

-- ============ Rol -> İzin Eşlemesi ============

-- name: ListPermissionsForRole :many
SELECT permission_code FROM role_permissions WHERE organization_role_id = $1;

-- name: ClearRolePermissions :exec
-- SetRolePermissions akışının ilk adımı: rolün MEVCUT tüm izinlerini
-- temizler, ardından servis katmanı yeni listeyi tek tek ekler (offer/
-- change-order kalemlerinin "sil+yeniden yaz" deseniyle AYNI ilke) --
-- TEK transaction içinde çağrılmalıdır.
DELETE FROM role_permissions WHERE organization_role_id = $1;

-- name: AddRolePermission :exec
INSERT INTO role_permissions (organization_role_id, permission_code)
VALUES ($1, $2)
ON CONFLICT (organization_role_id, permission_code) DO NOTHING;

-- ============ Kullanıcı <-> Rol ============

-- name: UpdateUserOrganizationRole :one
-- Süper admin'e ASLA çağrılmamalıdır (users_super_admin_has_no_org_role
-- CHECK kısıtı zaten DB seviyesinde engeller) -- servis katmanı normal bir
-- admin'in bu yolla super_admin'e YÜKSELTİLEMEYECEĞİNİ ayrıca doğrular
-- (organization_role_id, organizations_roles tablosundan gelir, oradan
-- 'super_admin' kodlu bir satır zaten hiç seed edilmez).
UPDATE users SET organization_role_id = $3
WHERE id = $1 AND organization_id = $2
RETURNING *;

-- name: GetUserPermissions :many
-- AuthorizationService.HasPermission'ın (ve /auth/me izin listesinin) tek
-- gerçek kaynağı: (rolün izinleri − kişiye özel revoke) ∪ kişiye özel grant.
-- Sahip (owner) rolünde kişiye özel ayarlar YOK SAYILIR ve rol satırlarına
-- da bakılmaz: Sahip kayıt defterindeki TÜM izinlere sahiptir -- firmanın son
-- yöneticisinin kendi yetkisini kısıp kilitlenmesi mümkün olmasın (rolün
-- izin kümesi webden düzenlenebildiği dönemde bu yapılabiliyordu).
-- super_admin çağrılmamalıdır (organization_role_id her zaman NULL, JOIN
-- hiçbir satır döndürmez) -- middleware onu zaten rol kontrolüyle daha
-- önce muaf tutar (bkz. RequireOnboarded'daki AYNI desen).
SELECT rp.permission_code
FROM users u
JOIN organization_roles orole ON orole.id = u.organization_role_id
JOIN role_permissions rp ON rp.organization_role_id = orole.id
WHERE u.id = $1 AND u.organization_id = $2 AND orole.code <> 'owner'
  AND NOT EXISTS (
        SELECT 1 FROM user_permission_overrides o
        WHERE o.user_id = u.id AND o.permission_code = rp.permission_code AND o.effect = 'revoke')
UNION
SELECT p.code
FROM users u
JOIN organization_roles orole ON orole.id = u.organization_role_id
CROSS JOIN permissions p
WHERE u.id = $1 AND u.organization_id = $2 AND orole.code = 'owner'
UNION
SELECT o.permission_code
FROM users u
JOIN organization_roles orole ON orole.id = u.organization_role_id
JOIN user_permission_overrides o ON o.user_id = u.id AND o.effect = 'grant'
WHERE u.id = $1 AND u.organization_id = $2 AND orole.code <> 'owner';

-- ============ Kişiye özel yetki ayarları ============

-- name: ListUserPermissionOverrides :many
SELECT permission_code, effect
FROM user_permission_overrides
WHERE user_id = $1 AND organization_id = $2
ORDER BY permission_code;

-- name: ClearUserPermissionOverrides :exec
-- Rol değiştiğinde eski kişiye özel ayarlar sıfırlanır: ayarlar ESKİ role
-- göre verilmiş farklardı, yeni rolde anlamlarını yitirirler.
DELETE FROM user_permission_overrides WHERE user_id = $1 AND organization_id = $2;

-- name: ReplaceUserPermissionOverrides :exec
-- Kişinin kişiye özel ayarlarını TEK ifadede yeni kümeyle değiştirir
-- (atomik: yarım kalmış bir küme oluşamaz). Silinen satırlar (yeni kümede
-- olmayan kodlar) ile upsert edilen satırlar ayrık kümelerdir, bu yüzden
-- aynı ifadedeki DELETE ve INSERT birbirine çarpmaz.
WITH removed AS (
    DELETE FROM user_permission_overrides
    WHERE user_id = @user_id::uuid AND organization_id = @organization_id::uuid
      AND NOT (permission_code = ANY(@granted::text[]) OR permission_code = ANY(@revoked::text[]))
)
INSERT INTO user_permission_overrides (user_id, organization_id, permission_code, effect, created_by)
SELECT @user_id::uuid, @organization_id::uuid, g.code, 'grant', @created_by::uuid
FROM unnest(@granted::text[]) AS g(code)
UNION ALL
SELECT @user_id::uuid, @organization_id::uuid, r.code, 'revoke', @created_by::uuid
FROM unnest(@revoked::text[]) AS r(code)
ON CONFLICT (user_id, permission_code)
DO UPDATE SET effect = EXCLUDED.effect, created_by = EXCLUDED.created_by, created_at = now();

-- name: GetUserRoleCode :one
-- Middleware'in HER istekte tek satırlık, hafif okuması: rol kodu VE adı
-- (GetUserPermissions'ın aksine tüm izin listesini taşımaz) -- "bu rol
-- proje üyeliğinden muaf mı" (owner/admin/legacy_user) kararı VE /auth/me
-- yanıtındaki görünen rol adı için yeterlidir (ayrı bir sorgu açmadan).
SELECT orole.code, orole.name
FROM users u
JOIN organization_roles orole ON orole.id = u.organization_role_id
WHERE u.id = $1 AND u.organization_id = $2;

-- ============ Proje Erişimi (project_users) ============

-- name: CreateProjectUser :one
INSERT INTO project_users (organization_id, project_id, user_id, project_role, created_by)
VALUES ($1, $2, $3, $4, $5)
ON CONFLICT (project_id, user_id) DO UPDATE SET project_role = EXCLUDED.project_role
RETURNING *;

-- name: DeleteProjectUser :execrows
DELETE FROM project_users WHERE project_id = $1 AND user_id = $2 AND organization_id = $3;

-- name: GetProjectUser :one
SELECT * FROM project_users WHERE project_id = $1 AND user_id = $2 AND organization_id = $3;

-- ListProjectUsersDetailed, ekip listesini kullanıcı bilgileriyle
-- (kullanıcı adı/tam ad/organizasyon rolü) TEK sorguda döner -- web
-- "Proje Erişimi" ekranı için N+1'siz.
-- name: ListProjectUsersDetailed :many
SELECT pu.*, u.username, u.full_name, u.is_active AS user_is_active,
       orole.code AS organization_role_code, orole.name AS organization_role_name
FROM project_users pu
JOIN users u ON u.id = pu.user_id
LEFT JOIN organization_roles orole ON orole.id = u.organization_role_id
WHERE pu.project_id = $1 AND pu.organization_id = $2
ORDER BY u.full_name ASC;

-- name: ListProjectIDsForUser :many
-- Mobil "erişilebilir proje" kontrolü ve CanAccessProject'in doğrudan
-- membership tablosuna gitmeden önce kullanabileceği hafif liste.
SELECT project_id FROM project_users WHERE user_id = $1 AND organization_id = $2;

-- name: ListProjectsForUserDetailed :many
-- "Kullanıcılar" ekranının kullanıcı detayındaki "Atandığı Projeler"
-- listesi -- proje adı/no + bu projedeki project_role TEK sorguda
-- (N+1'siz).
SELECT p.id AS project_id, p.project_no, p.name AS project_name, pu.project_role
FROM project_users pu
JOIN projects p ON p.id = pu.project_id
WHERE pu.user_id = $1 AND pu.organization_id = $2
ORDER BY p.name ASC;

-- name: ProjectUserExists :one
-- CanAccessProject'in TEK satırlık varlık kontrolü -- tam satırı taşımaz.
SELECT EXISTS (
    SELECT 1 FROM project_users WHERE project_id = $1 AND user_id = $2 AND organization_id = $3
) AS is_member;

-- name: CountProjectUsersByRole :one
-- Son-owner koruması (spec: "son Owner kaldırılamaz") İÇİN DEĞİL --
-- project_role dağılımı raporlama amaçlı, gelecekte kullanılabilir.
-- Şu an aktif kullanılmıyor, "proje erişimi" ekranının özet satırı için
-- eklenmiştir.
SELECT project_role, count(*)::bigint AS user_count
FROM project_users WHERE project_id = $1 AND organization_id = $2
GROUP BY project_role;

-- ============ Son-Owner Koruması ============

-- name: CountOwnersInOrganization :one
-- Son Owner koruması: silme/rol-değiştirme/deaktivasyon işlemi öncesi bu
-- sayı kontrol edilir -- 1 ise işlem reddedilir (spec: "son Owner
-- kaldırılamaz/düşürülemez/kendini deaktive edemez").
SELECT count(*)::bigint
FROM users u
JOIN organization_roles orole ON orole.id = u.organization_role_id
WHERE u.organization_id = $1 AND orole.code = 'owner' AND u.is_active = true;

-- name: LockOrganizationForOwnerChange :exec
-- Son-Owner korumasının kilidi: "başka aktif Owner var mı" sayımı ile
-- ardından gelen pasifleştirme/rol düşürme arasında başka bir transaction
-- aynı firmada aynı şeyi yapamasın. İki Sahip AYNI ANDA birbirini
-- pasifleştirince ikisi de "diğeri hâlâ aktif" görüp firma Sahipsiz
-- kalabiliyordu. Firma satırına NO KEY UPDATE: sahiplik değişikliklerini
-- firma başına sıraya sokar ama firmaya FK ile bağlanan satırların
-- eklenmesini (KEY SHARE) BEKLETMEZ. Transaction içinde çağrılmalıdır.
SELECT id FROM organizations WHERE id = $1 FOR NO KEY UPDATE;

-- name: CountActiveOwnersExcludingUser :one
-- Son-Owner koruması (deaktivasyon/rol düşürme): HEDEF kullanıcı DIŞINDAKİ
-- aktif Owner sayısı -- 0 ise hedef son aktif Owner'dır, işlem reddedilir.
SELECT count(*)::bigint
FROM users u
JOIN organization_roles orole ON orole.id = u.organization_role_id
WHERE u.organization_id = $1 AND orole.code = 'owner' AND u.is_active = true AND u.id <> $2;

-- name: CountActiveOwners :one
-- Sayfalanmış kullanıcı listesinden BAĞIMSIZ, doğru "aktif Sahip var mı"
-- cevabı -- 200+ kullanıcılı bir organizasyonda ilk (en eski) Owner
-- sayfanın dışına düşse bile UI'nin "Sahip yok" uyarısı YANLIŞ tetiklenmez.
SELECT count(*)::bigint
FROM users u
JOIN organization_roles orole ON orole.id = u.organization_role_id
WHERE u.organization_id = $1 AND orole.code = 'owner' AND u.is_active = true;
