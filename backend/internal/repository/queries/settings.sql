-- name: GetSmtpSettings :one
SELECT * FROM smtp_settings WHERE id = 1;

-- name: UpsertSmtpSettings :one
INSERT INTO smtp_settings (id, host, port, username, password_enc, from_email, from_name, use_tls)
VALUES (1, $1, $2, $3, $4, $5, $6, $7)
ON CONFLICT (id) DO UPDATE SET
    host = $1, port = $2, username = $3, password_enc = $4,
    from_email = $5, from_name = $6, use_tls = $7
RETURNING *;
