-- Yapay Zekâ Ayarları (migration 0081; bkz. service/ai_settings_service.go).

-- name: GetOrganizationAISettings :one
SELECT * FROM organization_ai_settings WHERE organization_id = $1;

-- name: UpsertOrganizationAISettings :one
INSERT INTO organization_ai_settings (organization_id, enabled, monthly_limit, per_user_monthly_limit, updated_by, updated_at)
VALUES (sqlc.arg(organization_id), sqlc.arg(enabled), sqlc.narg(monthly_limit), sqlc.narg(per_user_monthly_limit), sqlc.narg(updated_by), now())
ON CONFLICT (organization_id) DO UPDATE SET
    enabled = EXCLUDED.enabled, monthly_limit = EXCLUDED.monthly_limit,
    per_user_monthly_limit = EXCLUDED.per_user_monthly_limit,
    updated_by = EXCLUDED.updated_by, updated_at = now()
RETURNING *;

-- name: CountUserMonthlyAIImageJobs :one
-- Kişi başı AYLIK sınır: firma hakkıyla aynı kural (başarısız iş OpenAI'de
-- ücretlenmez, sayılmaz; sıradaki/çalışan sayılır). Saatlik sınır ayrı
-- (CountUserAIImageJobsSince: bütün işler).
SELECT count(*)::int FROM ai_image_jobs
WHERE organization_id = sqlc.arg(organization_id) AND user_id = sqlc.arg(user_id)
  AND created_at >= sqlc.arg(since)::timestamptz AND status <> 'failed';

-- name: ListAISettingsUsers :many
-- "Kimler kullanabilir": firmanın aktif, silinmemiş kişileri (taşeron
-- hesabı hariç -- izni zaten alamaz), rolün ai.images.use'u verip
-- vermediği, kişiye özel ayar ve bu ayki görsel sayısı tek sorguda.
-- Rolü olmayan kayıt (deny-by-default) listeye girmez. Sahip önce.
SELECT u.id, u.full_name, orole.code AS role_code, orole.name AS role_name,
       EXISTS (
           SELECT 1 FROM role_permissions rp
           WHERE rp.organization_role_id = orole.id AND rp.permission_code = 'ai.images.use'
       ) AS role_allows,
       COALESCE((
           SELECT o.effect FROM user_permission_overrides o
           WHERE o.user_id = u.id AND o.organization_id = u.organization_id
             AND o.permission_code = 'ai.images.use'
       ), '')::text AS override_effect,
       (
           SELECT count(*) FROM ai_image_jobs j
           WHERE j.organization_id = u.organization_id AND j.user_id = u.id
             AND j.created_at >= sqlc.arg(since)::timestamptz AND j.status <> 'failed'
       )::int AS used_this_month
FROM users u
JOIN organization_roles orole ON orole.id = u.organization_role_id
WHERE u.organization_id = sqlc.arg(organization_id) AND u.deleted_at IS NULL AND u.is_active
  AND u.supplier_id IS NULL AND orole.code <> 'subcontractor'
ORDER BY (orole.code = 'owner') DESC, u.full_name, u.id;
