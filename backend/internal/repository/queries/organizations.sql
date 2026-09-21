-- name: CreateOrganization :one
INSERT INTO organizations (name, slug)
VALUES ($1, $2)
RETURNING *;

-- name: GetOrganizationByID :one
SELECT * FROM organizations WHERE id = $1;

-- name: GetOrganizationBySlug :one
SELECT * FROM organizations WHERE slug = $1;

-- name: ListOrganizations :many
SELECT * FROM organizations ORDER BY created_at DESC;

-- name: CreateOrganizationWithLifecycle :one
-- Super Admin'in yeni firma provisioning'inde kullandığı sürüm --
-- status/plan_code/trial_ends_at'i açıkça set eder (CreateOrganization'ın
-- aksine, o hâlâ mevcut kullanım noktaları için DEFAULT'lara güveniyor).
INSERT INTO organizations (name, slug, status, plan_code, trial_ends_at)
VALUES ($1, $2, $3, $4, $5)
RETURNING *;

-- name: ListOrganizationsPaged :many
-- Silinmiş firmalar normal listeden HER ZAMAN dışarıda kalır (status
-- filtresinden BAĞIMSIZ olarak -- bkz. migration 0043 başlık notu);
-- ayrı bir "Silinenler" görünümü için ListDeletedOrganizations kullanılır.
SELECT * FROM organizations
WHERE ($1::text = '' OR status = $1::text) AND deleted_at IS NULL
ORDER BY created_at DESC
LIMIT $2 OFFSET $3;

-- name: CountOrganizationsFiltered :one
SELECT count(*) FROM organizations WHERE ($1::text = '' OR status = $1::text) AND deleted_at IS NULL;

-- name: ListDeletedOrganizations :many
-- Süper Admin'in "Silinenler" (Arşiv) görünümü -- status'ten BAĞIMSIZ
-- (silinen bir firma HANGİ durumdaysa o durumda kalır, bkz. domain/
-- organization.go Organization.DeletedAt yorumu), yalnızca deleted_at
-- DOLU satırlar.
SELECT * FROM organizations
WHERE deleted_at IS NOT NULL
ORDER BY deleted_at DESC
LIMIT $1 OFFSET $2;

-- name: CountDeletedOrganizations :one
SELECT count(*) FROM organizations WHERE deleted_at IS NOT NULL;

-- name: GetOrganizationStatus :one
-- RequireAuth middleware'inin her istekte çağırdığı hafif sorgu -- askıya
-- alınmış VEYA SİLİNMİŞ bir firmanın hâlâ geçerli bir access token'ı olan
-- kullanıcısını da mid-session engelleyebilmek için (bkz. migration 0043:
-- silme, status'ten BAĞIMSIZ bir erişim engelidir -- ikisi de kontrol
-- edilir).
SELECT status, deleted_at FROM organizations WHERE id = $1;

-- name: UpdateOrganizationStatus :one
UPDATE organizations SET status = $2, is_active = $3 WHERE id = $1 RETURNING *;

-- name: SoftDeleteOrganization :execrows
-- status'e DOKUNULMAZ (bkz. Organization.DeletedAt yorumu) -- yalnızca
-- deleted_at/deleted_by yazılır. Zaten silinmiş bir satırda 0 satır
-- günceller (servis katmanı ErrAlreadyDeleted'e çevirir).
UPDATE organizations
SET deleted_at = now(), deleted_by = $2
WHERE id = $1 AND deleted_at IS NULL;

-- name: RestoreOrganization :execrows
UPDATE organizations
SET deleted_at = NULL, deleted_by = NULL
WHERE id = $1 AND deleted_at IS NOT NULL;

-- name: UpdateOrganizationPlan :one
UPDATE organizations SET plan_code = $2 WHERE id = $1 RETURNING *;

-- name: AdvanceOnboardingStep :one
UPDATE organizations SET onboarding_step = $2 WHERE id = $1 RETURNING *;

-- name: CompleteOnboarding :one
UPDATE organizations
SET onboarding_step = 'completed', onboarding_completed = true, onboarding_completed_at = now()
WHERE id = $1
RETURNING *;
