package auth

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"time"

	"github.com/golang-jwt/jwt/v5"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
)

var ErrInvalidAccessToken = errors.New("geçersiz access token")

// AccessClaims, kısa ömürlü access token'ın içeriği. DB'ye dokunmadan
// (imza doğrulaması yeterli) hızlı yetkilendirme için role burada taşınır --
// ama nihai yetki kararı her zaman middleware'de bu claim'e göre verilir,
// kullanıcı deaktive edilirse zaten refresh sırasında elenir (aşağıya bkz.).
type AccessClaims struct {
	UserID string      `json:"uid"`
	Role   domain.Role `json:"role"`
	jwt.RegisteredClaims
}

type JWTIssuer struct {
	secret []byte
	ttl    time.Duration
}

func NewJWTIssuer(secret string, ttl time.Duration) *JWTIssuer {
	return &JWTIssuer{secret: []byte(secret), ttl: ttl}
}

func (j *JWTIssuer) IssueAccessToken(userID string, role domain.Role) (string, error) {
	claims := AccessClaims{
		UserID: userID,
		Role:   role,
		RegisteredClaims: jwt.RegisteredClaims{
			IssuedAt:  jwt.NewNumericDate(time.Now()),
			ExpiresAt: jwt.NewNumericDate(time.Now().Add(j.ttl)),
		},
	}
	token := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	return token.SignedString(j.secret)
}

func (j *JWTIssuer) ParseAccessToken(raw string) (*AccessClaims, error) {
	claims := &AccessClaims{}
	token, err := jwt.ParseWithClaims(raw, claims, func(t *jwt.Token) (interface{}, error) {
		if _, ok := t.Method.(*jwt.SigningMethodHMAC); !ok {
			return nil, ErrInvalidAccessToken
		}
		return j.secret, nil
	})
	if err != nil || !token.Valid {
		return nil, ErrInvalidAccessToken
	}
	return claims, nil
}

// NewRefreshToken, rastgele 32 baytlık opak bir token üretir (hex ile 64
// karakter) ve DB'de saklanacak SHA-256 özetini döner. Ham token yalnızca
// kullanıcıya (cookie olarak) gider, DB'de asla açık saklanmaz -- veritabanı
// sızarsa token'lar doğrudan kullanılamasın diye.
func NewRefreshToken() (raw string, hash string, err error) {
	buf := make([]byte, 32)
	if _, err = rand.Read(buf); err != nil {
		return "", "", err
	}
	raw = hex.EncodeToString(buf)
	return raw, HashRefreshToken(raw), nil
}

func HashRefreshToken(raw string) string {
	sum := sha256.Sum256([]byte(raw))
	return hex.EncodeToString(sum[:])
}
