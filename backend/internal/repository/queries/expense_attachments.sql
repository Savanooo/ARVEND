-- Masraf fişi / belgesi (migration 0076). Her sorgu organization_id ile
-- süzer; masrafın kendisine erişim kuralı serviste (expense_attachments.go).

-- name: GetExpenseAnyScope :one
-- Belge uçları projeli ve genel masrafta aynıdır: masraf önce kimliğiyle
-- okunur, URL'deki projeyle (ya da genel masrafta project_id NULL ile)
-- eşleşmesi serviste denetlenir.
SELECT * FROM project_expenses WHERE id = $1 AND organization_id = $2;

-- name: CreateExpenseAttachment :one
INSERT INTO expense_attachments (
    organization_id, expense_id, object_key, original_name, mime_type, size_bytes, sha256, uploaded_by
) VALUES (
    sqlc.arg(organization_id), sqlc.arg(expense_id), sqlc.arg(object_key), sqlc.arg(original_name),
    sqlc.arg(mime_type), sqlc.arg(size_bytes), sqlc.arg(sha256), sqlc.narg(uploaded_by)
)
RETURNING *;

-- name: ListExpenseAttachments :many
SELECT * FROM expense_attachments
WHERE organization_id = $1 AND expense_id = $2
ORDER BY created_at, id;

-- name: ListExpenseAttachmentsForExpenses :many
-- Masraf listelerinin (Finans, Masraflarım, Masraflar) satırlarına belgeler
-- tek sorguda eklenir.
SELECT * FROM expense_attachments
WHERE organization_id = sqlc.arg(organization_id)::uuid
  AND expense_id = ANY(sqlc.arg(expense_ids)::uuid[])
ORDER BY expense_id, created_at, id;

-- name: CountExpenseAttachments :one
SELECT count(*)::int FROM expense_attachments WHERE organization_id = $1 AND expense_id = $2;

-- name: GetExpenseAttachment :one
SELECT * FROM expense_attachments WHERE id = $1 AND expense_id = $2 AND organization_id = $3;

-- name: GetExpenseAttachmentBySHA :one
SELECT * FROM expense_attachments WHERE expense_id = $1 AND sha256 = $2 AND organization_id = $3;

-- name: DeleteExpenseAttachment :one
-- Kalıcı silme: dönen object_key işlem bittikten sonra depodan da silinir.
DELETE FROM expense_attachments
WHERE id = $1 AND expense_id = $2 AND organization_id = $3
RETURNING object_key;
