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
SELECT * FROM organizations
WHERE ($1::text = '' OR status = $1::text)
ORDER BY created_at DESC
LIMIT $2 OFFSET $3;

-- name: CountOrganizationsFiltered :one
SELECT count(*) FROM organizations WHERE ($1::text = '' OR status = $1::text);

-- name: GetOrganizationStatus :one
-- RequireAuth middleware'inin her istekte çağırdığı hafif sorgu -- askıya
-- alınmış bir firmanın hâlâ geçerli bir access token'ı olan kullanıcısını
-- da mid-session engelleyebilmek için.
SELECT status FROM organizations WHERE id = $1;

-- name: UpdateOrganizationStatus :one
UPDATE organizations SET status = $2, is_active = $3 WHERE id = $1 RETURNING *;

-- name: UpdateOrganizationPlan :one
UPDATE organizations SET plan_code = $2 WHERE id = $1 RETURNING *;

-- name: AdvanceOnboardingStep :one
UPDATE organizations SET onboarding_step = $2 WHERE id = $1 RETURNING *;

-- name: CompleteOnboarding :one
UPDATE organizations
SET onboarding_step = 'completed', onboarding_completed = true, onboarding_completed_at = now()
WHERE id = $1
RETURNING *;
