-- name: GetSmtpSettings :one
SELECT * FROM smtp_settings WHERE organization_id = $1;

-- name: UpsertSmtpSettings :one
INSERT INTO smtp_settings (organization_id, host, port, username, password_enc, from_email, from_name, use_tls)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
ON CONFLICT (organization_id) DO UPDATE SET
    host = $2, port = $3, username = $4, password_enc = $5,
    from_email = $6, from_name = $7, use_tls = $8
RETURNING *;
