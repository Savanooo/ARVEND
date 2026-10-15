-- Taşeronlar (migration 0069): taşeron kartı = suppliers.is_subcontractor.
-- Bir taşerona yapılan ödemeler üç yerden gelir: projedeki basit taşeron
-- ödemeleri (project_subcontractor_payments, kart bağı
-- project_subcontractors.supplier_id), sözleşmeli taşeron ödemeleri
-- (subcontract_payments, project_subcontracts.supplier_id) ve proje dışı
-- ödemeler (subcontractor_direct_payments).
--
-- restrict_to_user_id: üyelikle sınırlı rolde projeli satırlar yalnızca
-- üyesi olduğu projelerden (NULL = Sahip/Yönetici/Eski Sistem, hepsi).

-- name: ListSubcontractorCards :many
SELECT * FROM suppliers
WHERE organization_id = $1 AND is_subcontractor
ORDER BY is_active DESC, legal_name ASC;

-- name: ListSubcontractorPaidTotals :many
-- Kart başına, para birimi başına geçerli (iptal edilmemiş) ödeme toplamı
-- ve taşeronun çalıştığı proje sayısı.
WITH pay AS (
    SELECT s.supplier_id, p.project_id, p.currency, p.amount
    FROM project_subcontractor_payments p
    JOIN project_subcontractors s ON s.id = p.subcontractor_id
    WHERE p.organization_id = sqlc.arg(organization_id)::uuid AND p.voided_at IS NULL AND s.supplier_id IS NOT NULL
    UNION ALL
    SELECT ps.supplier_id, sp.project_id, sp.currency, sp.amount
    FROM subcontract_payments sp
    JOIN project_subcontracts ps ON ps.id = sp.subcontract_id
    WHERE sp.organization_id = sqlc.arg(organization_id)::uuid AND sp.voided_at IS NULL
    UNION ALL
    SELECT d.supplier_id, NULL::uuid, d.currency, d.amount
    FROM subcontractor_direct_payments d
    WHERE d.organization_id = sqlc.arg(organization_id)::uuid AND d.voided_at IS NULL
)
SELECT supplier_id, currency, COALESCE(sum(amount), 0)::numeric(18,2) AS paid_total
FROM pay
WHERE project_id IS NULL OR sqlc.narg(restrict_to_user_id)::uuid IS NULL OR EXISTS (
    SELECT 1 FROM project_users pu
    WHERE pu.project_id = pay.project_id AND pu.user_id = sqlc.narg(restrict_to_user_id)::uuid)
GROUP BY supplier_id, currency
ORDER BY supplier_id, currency;

-- name: GetSubcontractorCard :one
SELECT * FROM suppliers
WHERE id = $1 AND organization_id = $2 AND is_subcontractor;

-- name: SetSupplierIsSubcontractor :exec
UPDATE suppliers SET is_subcontractor = true WHERE id = $1 AND organization_id = $2;

-- name: FindSupplierByNormalizedName :one
-- Ad eşleşmesi göçteki kuralla aynı: büyük/küçük harf ve fazla boşluk
-- farkı yok sayılır; unvan ya da ticari ad.
SELECT * FROM suppliers
WHERE organization_id = sqlc.arg(organization_id)
  AND (lower(btrim(regexp_replace(legal_name, '\s+', ' ', 'g'))) = lower(btrim(regexp_replace(sqlc.arg(name)::text, '\s+', ' ', 'g')))
       OR lower(btrim(regexp_replace(trade_name, '\s+', ' ', 'g'))) = lower(btrim(regexp_replace(sqlc.arg(name)::text, '\s+', ' ', 'g'))))
ORDER BY is_subcontractor DESC, is_active DESC, created_at ASC
LIMIT 1;

-- name: NextSubcontractorCodeNumber :one
SELECT (COALESCE(max(substring(code FROM 5)::int), 0) + 1)::int AS next
FROM suppliers
WHERE organization_id = $1 AND code ~ '^TSR-[0-9]+$';

-- name: SetProjectSubcontractorSupplier :exec
UPDATE project_subcontractors SET supplier_id = sqlc.arg(supplier_id)
WHERE id = sqlc.arg(id) AND organization_id = sqlc.arg(organization_id);

-- name: ListSubcontractorEngagements :many
-- Taşeronun projelerdeki işleri: basit taşeron kayıtları ve sözleşmeli
-- taşeronluklar, her biri ödenen toplamla.
SELECT 'simple'::text AS kind, s.id, s.project_id, p.name AS project_name, p.project_no, p.status AS project_status,
       s.work_description AS title, s.status, s.currency, s.contract_amount,
       COALESCE((SELECT sum(x.amount) FROM project_subcontractor_payments x
                 WHERE x.subcontractor_id = s.id AND x.voided_at IS NULL), 0)::numeric(18,2) AS paid_amount,
       s.created_at
FROM project_subcontractors s
JOIN projects p ON p.id = s.project_id
WHERE s.organization_id = sqlc.arg(organization_id)::uuid AND s.supplier_id = sqlc.arg(supplier_id)::uuid
  AND (sqlc.narg(restrict_to_user_id)::uuid IS NULL OR EXISTS (
       SELECT 1 FROM project_users pu WHERE pu.project_id = s.project_id AND pu.user_id = sqlc.narg(restrict_to_user_id)::uuid))
UNION ALL
SELECT 'contract'::text, c.id, c.project_id, p.name, p.project_no, p.status,
       (c.subcontract_no || ' · ' || c.title)::varchar(500), c.status, c.currency, c.original_amount,
       COALESCE((SELECT sum(x.amount) FROM subcontract_payments x
                 WHERE x.subcontract_id = c.id AND x.voided_at IS NULL), 0)::numeric(18,2),
       c.created_at
FROM project_subcontracts c
JOIN projects p ON p.id = c.project_id
WHERE c.organization_id = sqlc.arg(organization_id)::uuid AND c.supplier_id = sqlc.arg(supplier_id)::uuid
  AND (sqlc.narg(restrict_to_user_id)::uuid IS NULL OR EXISTS (
       SELECT 1 FROM project_users pu WHERE pu.project_id = c.project_id AND pu.user_id = sqlc.narg(restrict_to_user_id)::uuid))
ORDER BY created_at DESC;

-- name: ListSubcontractorLedgerPayments :many
-- Taşerona yapılan bütün ödemeler (iptaller dahil), en yeni önce.
SELECT * FROM (
    SELECT 'simple'::text AS source, x.id, x.project_id, p.name AS project_name, p.project_no,
           x.subcontractor_id AS engagement_id, x.amount, x.currency, x.paid_date, x.description,
           x.voided_at, x.void_reason, x.created_at
    FROM project_subcontractor_payments x
    JOIN project_subcontractors s ON s.id = x.subcontractor_id
    JOIN projects p ON p.id = x.project_id
    WHERE x.organization_id = sqlc.arg(organization_id)::uuid AND s.supplier_id = sqlc.arg(supplier_id)::uuid
      AND (sqlc.narg(restrict_to_user_id)::uuid IS NULL OR EXISTS (
           SELECT 1 FROM project_users pu WHERE pu.project_id = x.project_id AND pu.user_id = sqlc.narg(restrict_to_user_id)::uuid))
    UNION ALL
    SELECT 'contract'::text, x.id, x.project_id, p.name, p.project_no,
           x.subcontract_id, x.amount, x.currency, x.paid_date, x.description,
           x.voided_at, x.void_reason, x.created_at
    FROM subcontract_payments x
    JOIN project_subcontracts c ON c.id = x.subcontract_id
    JOIN projects p ON p.id = x.project_id
    WHERE x.organization_id = sqlc.arg(organization_id)::uuid AND c.supplier_id = sqlc.arg(supplier_id)::uuid
      AND (sqlc.narg(restrict_to_user_id)::uuid IS NULL OR EXISTS (
           SELECT 1 FROM project_users pu WHERE pu.project_id = x.project_id AND pu.user_id = sqlc.narg(restrict_to_user_id)::uuid))
    UNION ALL
    SELECT 'direct'::text, x.id, NULL::uuid, ''::varchar(200), ''::varchar(30),
           NULL::uuid, x.amount, x.currency, x.paid_date, x.description,
           x.voided_at, x.void_reason, x.created_at
    FROM subcontractor_direct_payments x
    WHERE x.organization_id = sqlc.arg(organization_id)::uuid AND x.supplier_id = sqlc.arg(supplier_id)::uuid
) t
ORDER BY paid_date DESC, created_at DESC
LIMIT 500;

-- name: CreateSubcontractorDirectPayment :one
INSERT INTO subcontractor_direct_payments (
    organization_id, supplier_id, amount, currency, paid_date, description, idempotency_key, created_by
) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
RETURNING *;

-- name: GetSubcontractorDirectPaymentByIdempotencyKey :one
SELECT * FROM subcontractor_direct_payments
WHERE organization_id = $1 AND idempotency_key = $2;

-- name: VoidSubcontractorDirectPayment :one
UPDATE subcontractor_direct_payments
SET voided_at = now(), voided_by = sqlc.narg(voided_by), void_reason = sqlc.arg(void_reason)
WHERE id = sqlc.arg(id) AND organization_id = sqlc.arg(organization_id) AND supplier_id = sqlc.arg(supplier_id)
  AND voided_at IS NULL
RETURNING *;

-- name: ListSubcontractorRemainingTotals :many
-- Kart başına, para birimi başına kalan borç: projelerdeki işlerin
-- (iptal edilmemiş basit kayıtlar, yürürlükteki/tamamlanmış sözleşmeler)
-- sözleşme bedeli eksi geçerli ödemeler, işi başına sıfırın altına inmez.
WITH eng AS (
    SELECT s.supplier_id, s.project_id, s.currency, s.contract_amount AS contract,
           COALESCE((SELECT sum(x.amount) FROM project_subcontractor_payments x
                     WHERE x.subcontractor_id = s.id AND x.voided_at IS NULL), 0) AS paid
    FROM project_subcontractors s
    WHERE s.organization_id = sqlc.arg(organization_id)::uuid AND s.supplier_id IS NOT NULL
      AND s.status <> 'cancelled'
    UNION ALL
    SELECT c.supplier_id, c.project_id, c.currency, c.original_amount,
           COALESCE((SELECT sum(x.amount) FROM subcontract_payments x
                     WHERE x.subcontract_id = c.id AND x.voided_at IS NULL), 0)
    FROM project_subcontracts c
    WHERE c.organization_id = sqlc.arg(organization_id)::uuid AND c.status IN ('active', 'completed')
)
SELECT supplier_id, currency, COALESCE(sum(GREATEST(contract - paid, 0)), 0)::numeric(18,2) AS remaining_total
FROM eng
WHERE sqlc.narg(restrict_to_user_id)::uuid IS NULL OR EXISTS (
    SELECT 1 FROM project_users pu
    WHERE pu.project_id = eng.project_id AND pu.user_id = sqlc.narg(restrict_to_user_id)::uuid)
GROUP BY supplier_id, currency
ORDER BY supplier_id, currency;
