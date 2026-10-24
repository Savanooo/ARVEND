-- Taşeron Paneli (migration 0075, docs/taseron-paneli.md). Taşeron hesabı
-- yalnızca kendi kartının (supplier_id) ve firmanın izin verdiği projelerin
-- (subcontractor_project_access) kayıtlarını görür. Müşteri, fiyat, kâr,
-- diğer taşeronlar ve proje finansı burada HİÇ sorgulanmaz.

-- ============ Firma tarafı: taşeron girişleri ============

-- name: CreatePortalUser :one
-- Geçici şifreyle açılır: taşeron ilk girişte kendi şifresini belirler.
INSERT INTO users (organization_id, username, password_hash, full_name, role, must_change_password,
                   supplier_id, organization_role_id)
VALUES (sqlc.arg(organization_id), sqlc.arg(username), sqlc.arg(password_hash), sqlc.arg(full_name),
        'kullanici', true, sqlc.arg(supplier_id), sqlc.arg(organization_role_id))
RETURNING *;

-- name: ListSupplierPortalUsers :many
SELECT * FROM users
WHERE organization_id = $1 AND supplier_id = $2 AND deleted_at IS NULL
ORDER BY created_at;

-- name: GetSupplierPortalUser :one
SELECT * FROM users
WHERE id = $1 AND organization_id = $2 AND supplier_id = $3 AND deleted_at IS NULL;

-- name: ResetPortalUserPassword :one
UPDATE users SET password_hash = sqlc.arg(password_hash), must_change_password = true
WHERE id = sqlc.arg(id) AND organization_id = sqlc.arg(organization_id) AND supplier_id = sqlc.arg(supplier_id)
  AND deleted_at IS NULL
RETURNING *;

-- name: SetPortalUserActive :one
UPDATE users SET is_active = sqlc.arg(is_active)
WHERE id = sqlc.arg(id) AND organization_id = sqlc.arg(organization_id) AND supplier_id = sqlc.arg(supplier_id)
  AND deleted_at IS NULL
RETURNING *;

-- name: IsPortalUser :one
-- Kişiye özel yetki ve rol değiştirme yollarının taşeron hesabını reddetmesi için.
SELECT (supplier_id IS NOT NULL)::boolean FROM users WHERE id = $1 AND organization_id = $2;

-- ============ Firma tarafı: proje izinleri ============

-- name: ListPortalProjectChoices :many
-- İzin ekranı: iptal edilmemiş projeler + (iptal edilmiş olsa da) izinli
-- ya da taşeronun işi olan projeler. İzinli ve işi olan önce.
SELECT * FROM (
    SELECT p.id, p.project_no, p.name, p.status, p.created_at,
           EXISTS (SELECT 1 FROM subcontractor_project_access a
                   WHERE a.project_id = p.id AND a.supplier_id = sqlc.arg(supplier_id)::uuid)::boolean AS granted,
           (EXISTS (SELECT 1 FROM project_subcontractors s
                    WHERE s.project_id = p.id AND s.supplier_id = sqlc.arg(supplier_id)::uuid)
            OR EXISTS (SELECT 1 FROM project_subcontracts c
                       WHERE c.project_id = p.id AND c.supplier_id = sqlc.arg(supplier_id)::uuid))::boolean AS has_engagement
    FROM projects p
    WHERE p.organization_id = sqlc.arg(organization_id)::uuid
) t
WHERE t.status <> 'cancelled' OR t.granted OR t.has_engagement
ORDER BY t.granted DESC, t.has_engagement DESC, t.created_at DESC;

-- name: DeleteSupplierProjectAccess :exec
DELETE FROM subcontractor_project_access WHERE organization_id = $1 AND supplier_id = $2;

-- name: InsertSupplierProjectAccess :exec
INSERT INTO subcontractor_project_access (organization_id, supplier_id, project_id, granted_by)
VALUES ($1, $2, $3, $4)
ON CONFLICT (supplier_id, project_id) DO NOTHING;

-- name: CountProjectsInOrg :one
SELECT count(*)::int FROM projects WHERE organization_id = $1 AND id = ANY(sqlc.arg(ids)::uuid[]);

-- ============ Taşeron tarafı ============

-- name: ListPortalProjects :many
SELECT p.id, p.project_no, p.name, p.status
FROM subcontractor_project_access a
JOIN projects p ON p.id = a.project_id
WHERE a.organization_id = $1 AND a.supplier_id = $2
ORDER BY p.name;

-- name: ListPortalEngagements :many
-- İzinli projelerdeki işler. Basit taşeron: bedel ve ödenen. Sözleşmeli
-- taşeron (taslak hariç): güncel bedel (onaylı ek/eksiltmeler dahil),
-- onaylı hakediş, ödenen, ödenecek, teminat, açık avans, onaya sunulan
-- (subcontract_cost_basis, migration 0073).
SELECT 'simple'::text AS kind, s.id, s.project_id, p.name AS project_name, p.project_no, p.status AS project_status,
       s.work_description::text AS title, s.status, s.currency,
       s.contract_amount::numeric(18,2) AS contract_amount,
       NULL::numeric(18,2) AS certified,
       COALESCE((SELECT sum(x.amount) FROM project_subcontractor_payments x
                 WHERE x.subcontractor_id = s.id AND x.voided_at IS NULL), 0)::numeric(18,2) AS paid,
       0::numeric(18,2) AS payable,
       0::numeric(18,2) AS retention,
       COALESCE((SELECT sum(x.amount) FROM project_subcontractor_payments x
                 WHERE x.subcontractor_id = s.id AND x.voided_at IS NULL AND x.payment_kind = 'advance'), 0)::numeric(18,2)
           AS advance_open,
       0::numeric(18,2) AS pending_claims,
       s.created_at
FROM project_subcontractors s
JOIN projects p ON p.id = s.project_id
WHERE s.organization_id = sqlc.arg(organization_id)::uuid AND s.supplier_id = sqlc.arg(supplier_id)::uuid
  AND EXISTS (SELECT 1 FROM subcontractor_project_access a
              WHERE a.supplier_id = s.supplier_id AND a.project_id = s.project_id)
UNION ALL
SELECT 'contract'::text, c.id, c.project_id, p.name, p.project_no, p.status,
       (c.subcontract_no || ' · ' || c.title)::text, c.status, c.currency,
       (c.original_amount + COALESCE((
            SELECT sum(CASE WHEN co.change_type = 'addition' THEN co.amount ELSE -co.amount END)
            FROM subcontract_change_orders co
            WHERE co.subcontract_id = c.id AND co.status = 'approved'), 0))::numeric(18,2),
       b.certified, b.paid, b.payable, b.retention, b.advance_open, b.pending_claims,
       c.created_at
FROM project_subcontracts c
JOIN projects p ON p.id = c.project_id
JOIN subcontract_cost_basis b ON b.subcontract_id = c.id
WHERE c.organization_id = sqlc.arg(organization_id)::uuid AND c.supplier_id = sqlc.arg(supplier_id)::uuid
  AND c.status <> 'draft'
  AND EXISTS (SELECT 1 FROM subcontractor_project_access a
              WHERE a.supplier_id = c.supplier_id AND a.project_id = c.project_id)
ORDER BY project_name, created_at;

-- name: ListPortalPayments :many
-- İzinli projelerdeki ödemeler ve proje dışı (karta) ödemeler; iptal
-- edilenler gösterilmez. En yeni önce.
SELECT * FROM (
    SELECT 'simple'::text AS source, x.id, x.project_id, p.name::text AS project_name, p.project_no::text AS project_no,
           x.amount, x.currency, x.paid_date, x.description::text AS description, x.payment_kind::text AS kind,
           x.created_at
    FROM project_subcontractor_payments x
    JOIN project_subcontractors s ON s.id = x.subcontractor_id
    JOIN projects p ON p.id = x.project_id
    WHERE x.organization_id = sqlc.arg(organization_id)::uuid AND s.supplier_id = sqlc.arg(supplier_id)::uuid
      AND x.voided_at IS NULL
      AND EXISTS (SELECT 1 FROM subcontractor_project_access a
                  WHERE a.supplier_id = s.supplier_id AND a.project_id = x.project_id)
    UNION ALL
    SELECT 'contract'::text, x.id, x.project_id, p.name::text, p.project_no::text,
           x.amount, x.currency, x.paid_date, x.description::text,
           CASE WHEN x.progress_claim_id IS NULL AND COALESCE(c.advance_amount, 0) > 0 THEN 'advance' ELSE 'work' END,
           x.created_at
    FROM subcontract_payments x
    JOIN project_subcontracts c ON c.id = x.subcontract_id
    JOIN projects p ON p.id = x.project_id
    WHERE x.organization_id = sqlc.arg(organization_id)::uuid AND c.supplier_id = sqlc.arg(supplier_id)::uuid
      AND x.voided_at IS NULL
      AND EXISTS (SELECT 1 FROM subcontractor_project_access a
                  WHERE a.supplier_id = c.supplier_id AND a.project_id = x.project_id)
    UNION ALL
    SELECT 'direct'::text, x.id, NULL::uuid, ''::text, ''::text,
           x.amount, x.currency, x.paid_date, x.description::text, x.payment_kind::text,
           x.created_at
    FROM subcontractor_direct_payments x
    WHERE x.organization_id = sqlc.arg(organization_id)::uuid AND x.supplier_id = sqlc.arg(supplier_id)::uuid
      AND x.voided_at IS NULL
) t
ORDER BY paid_date DESC, created_at DESC
LIMIT 500;

-- name: GetSupplierIsActive :one
-- Giriş ve oturum yenileme: kartı arşive alınmış taşeronun hesabı kapanır.
SELECT is_active FROM suppliers WHERE id = $1;
