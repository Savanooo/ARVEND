-- name: CreateRefreshToken :one
INSERT INTO refresh_tokens (user_id, token_hash, expires_at)
VALUES ($1, $2, $3)
RETURNING *;

-- name: RotateRefreshToken :one
-- Yenilemenin TEK adımı: geçerli token'ı atomik olarak iptal eder ve
-- "yenileme ile iptal edildi" (rotated_at) işaretler. Aynı token'la gelen
-- iki eşzamanlı istekten yalnızca biri satır alır -- diğeri tolerans
-- yoluna (GetRecentlyRotatedRefreshToken) düşer.
UPDATE refresh_tokens SET revoked_at = now(), rotated_at = now()
WHERE token_hash = $1
  AND revoked_at IS NULL
  AND expires_at > now()
RETURNING *;

-- name: GetRecentlyRotatedRefreshToken :one
-- Tolerans: az önce (rotated_after'dan sonra) YENİLEME ile iptal edilmiş
-- token. Çıkış/şifre değişikliği/pasifleştirme rotated_at'i temizlediği
-- için onlardan sonra burada satır çıkmaz.
SELECT * FROM refresh_tokens
WHERE token_hash = $1
  AND rotated_at IS NOT NULL
  AND rotated_at > sqlc.arg(rotated_after)::timestamptz
  AND expires_at > now();

-- name: RevokeRefreshTokenForLogout :exec
-- Çıkış: bu token iptal edilir VE kullanıcının yenileme toleransındaki
-- (rotated_at dolu) token'larının toleransı kalkar -- çıkıştan hemen sonra
-- bir önceki token'la oturum geri açılamaz.
UPDATE refresh_tokens SET revoked_at = COALESCE(revoked_at, now()), rotated_at = NULL
WHERE user_id = (SELECT rt.user_id FROM refresh_tokens rt WHERE rt.token_hash = $1 LIMIT 1)
  AND (token_hash = $1 OR rotated_at IS NOT NULL);

-- name: RevokeAllUserRefreshTokens :exec
-- Açık oturumlar iptal edilir ve yenileme toleransı da kalkar
-- (rotated_at = NULL): pasifleştirme/şifre sıfırlamadan sonra az önce
-- yenilenmiş bir token'la oturum geri açılamaz.
UPDATE refresh_tokens SET revoked_at = COALESCE(revoked_at, now()), rotated_at = NULL
WHERE user_id = $1 AND (revoked_at IS NULL OR rotated_at IS NOT NULL);

-- name: RevokeUserRefreshTokensExcept :exec
-- Şifre değişince kullanıcının DİĞER oturumları kapanır (toleransları da);
-- şifreyi değiştiren cihazın kendi oturumu (token_hash) açık kalır.
UPDATE refresh_tokens SET revoked_at = COALESCE(revoked_at, now()), rotated_at = NULL
WHERE user_id = $1 AND token_hash <> $2 AND (revoked_at IS NULL OR rotated_at IS NOT NULL);
