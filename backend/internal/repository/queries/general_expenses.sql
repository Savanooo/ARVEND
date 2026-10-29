-- Genel (projesiz) masraf (migration 0068): project_expenses'te
-- project_id NULL satırlar. Projeli masrafın sorguları project_id = $x ile
-- süzdüğü için bunlara hiç dokunmaz; genel masrafın yazımı buradadır.

-- name: CreateGeneralExpense :one
INSERT INTO project_expenses (
    organization_id, project_id, category, description, amount, currency,
    expense_date, supplier_name, invoice_no, notes, idempotency_key, created_by,
    approval_status, vat_rate
) VALUES (
    sqlc.arg(organization_id), NULL, sqlc.arg(category), sqlc.arg(description), sqlc.arg(amount),
    sqlc.arg(currency), sqlc.arg(expense_date), sqlc.arg(supplier_name), sqlc.arg(invoice_no),
    sqlc.arg(notes), sqlc.narg(idempotency_key), sqlc.narg(created_by), sqlc.arg(approval_status),
    sqlc.narg(vat_rate)
)
RETURNING *;

-- name: GetGeneralExpenseForUpdate :one
-- Genel masrafın yazım yollarındaki satır kilidi (projeli masrafta proje
-- satırı kilitlenir; burada proje yok).
SELECT * FROM project_expenses
WHERE id = $1 AND organization_id = $2 AND project_id IS NULL
FOR UPDATE;

-- name: GetGeneralExpenseByIdempotencyKey :one
SELECT * FROM project_expenses
WHERE organization_id = $1 AND idempotency_key = $2 AND project_id IS NULL;

-- name: UpdateGeneralExpense :one
-- Projeli UpdateExpense ile aynı: satır bütünüyle yeniden yazılır ve
-- masraf yeniden onay bekler.
UPDATE project_expenses
SET category = sqlc.arg(category), description = sqlc.arg(description), amount = sqlc.arg(amount),
    currency = sqlc.arg(currency), expense_date = sqlc.arg(expense_date),
    supplier_name = sqlc.arg(supplier_name), invoice_no = sqlc.arg(invoice_no), notes = sqlc.arg(notes),
    vat_rate = sqlc.narg(vat_rate),
    approval_status = 'pending', decided_by = NULL, decided_at = NULL, decision_note = ''
WHERE id = sqlc.arg(id) AND organization_id = sqlc.arg(organization_id) AND project_id IS NULL
  AND voided_at IS NULL
RETURNING *;

-- name: DecideGeneralExpense :one
UPDATE project_expenses
SET approval_status = sqlc.arg(approval_status), decided_by = sqlc.narg(decided_by),
    decided_at = now(), decision_note = sqlc.arg(decision_note)
WHERE id = sqlc.arg(id) AND organization_id = sqlc.arg(organization_id) AND project_id IS NULL
  AND voided_at IS NULL AND approval_status = 'pending'
RETURNING *;

-- name: VoidGeneralExpense :one
UPDATE project_expenses
SET voided_at = now(), voided_by = sqlc.narg(voided_by), void_reason = sqlc.arg(void_reason)
WHERE id = sqlc.arg(id) AND organization_id = sqlc.arg(organization_id) AND project_id IS NULL
  AND voided_at IS NULL
RETURNING *;

-- name: ListExpensesFiltered :many
-- "Masraflar" ekranı (GET /expenses): projeli ve genel masraflar tek
-- listede, en yeni masraf tarihi önce.
--   kind: '' (hepsi) | 'general' | 'project'
--   status: '' (hepsi, iptaller dahil) | 'pending' | 'approved' |
--           'rejected' (bu üçü iptal edilmemişler) | 'voided'
--   created_by: doluysa yalnızca o kişinin girdikleri (finans okuma izni
--           olmayan kişi yalnızca kendi masraflarını görür).
--   decidable_since: created_by ile birlikte doluysa ONAYLAYICI kapsamı
--           (projects.expenses.approve, finans okuma izni yok): kişinin
--           kendi masraflarına ek olarak başkalarının iptal edilmemiş, onay
--           bekleyen ya da bu andan sonra karara bağlanmış masrafları --
--           onaylayıcı karar vereceği masrafı görebilmeli (bildirim onu
--           buraya getiriyor), ama finans okuması olmadan firmanın bütün
--           masraf geçmişini ve toplamları değil.
--   restrict_to_user_id: üyelikle sınırlı rolde projeli satırlar yalnızca
--           üyesi olduğu projelerden (genel masraf projeye bağlı değildir).
SELECT e.*,
       COALESCE(p.name, '')::text AS project_name,
       COALESCE(p.project_no, '')::text AS project_no,
       COALESCE(p.status, '')::text AS project_status,
       COALESCE(u.full_name, '')::text AS created_by_name
FROM project_expenses e
LEFT JOIN projects p ON p.id = e.project_id AND p.organization_id = e.organization_id
LEFT JOIN users u ON u.id = e.created_by
WHERE e.organization_id = sqlc.arg(organization_id)::uuid
  AND (sqlc.arg(kind)::text = ''
       OR (sqlc.arg(kind)::text = 'general' AND e.project_id IS NULL)
       OR (sqlc.arg(kind)::text = 'project' AND e.project_id IS NOT NULL))
  AND (sqlc.narg(project_id)::uuid IS NULL OR e.project_id = sqlc.narg(project_id)::uuid)
  AND (sqlc.arg(status)::text = ''
       OR (sqlc.arg(status)::text = 'voided' AND e.voided_at IS NOT NULL)
       OR (e.voided_at IS NULL AND e.approval_status = sqlc.arg(status)::text))
  AND (sqlc.narg(created_by)::uuid IS NULL OR e.created_by = sqlc.narg(created_by)::uuid
       OR (sqlc.narg(decidable_since)::timestamptz IS NOT NULL AND e.voided_at IS NULL
           AND (e.approval_status = 'pending' OR e.decided_at >= sqlc.narg(decidable_since)::timestamptz)))
  AND (sqlc.narg(date_from)::date IS NULL OR e.expense_date >= sqlc.narg(date_from)::date)
  AND (sqlc.narg(date_to)::date IS NULL OR e.expense_date <= sqlc.narg(date_to)::date)
  AND (e.project_id IS NULL OR sqlc.narg(restrict_to_user_id)::uuid IS NULL OR EXISTS (
       SELECT 1 FROM project_users pu
       WHERE pu.project_id = e.project_id AND pu.user_id = sqlc.narg(restrict_to_user_id)::uuid))
ORDER BY e.expense_date DESC, e.created_at DESC, e.id DESC
LIMIT sqlc.arg(row_limit)::int;

-- name: DashboardPendingGeneralExpenses :many
-- Onay bekleyen genel masraflar (ana sayfa "masraf onay bekliyor" grubu,
-- projeli olanlarla birlikte), en eskisi önce.
SELECT e.id, e.description, e.currency, e.amount,
       (e.created_at AT TIME ZONE 'Europe/Istanbul')::date AS since_date
FROM project_expenses e
WHERE e.organization_id = @org_id::uuid AND e.project_id IS NULL
  AND e.approval_status = 'pending' AND e.voided_at IS NULL
  AND (sqlc.narg('exclude_created_by')::uuid IS NULL OR e.created_by IS DISTINCT FROM sqlc.narg('exclude_created_by')::uuid)
ORDER BY e.created_at ASC, e.id;
