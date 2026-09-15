package domain

import "errors"

var (
	ErrNotFound              = errors.New("kayıt bulunamadı")
	ErrDuplicateUsername     = errors.New("bu kullanıcı adı zaten kullanılıyor")
	ErrInvalidCredentials    = errors.New("kullanıcı adı veya şifre hatalı")
	ErrInactiveUser          = errors.New("kullanıcı pasif")
	ErrInvalidToken          = errors.New("geçersiz veya süresi dolmuş oturum")
	ErrOrganizationSuspended = errors.New("firma askıya alınmış")
	ErrForbidden             = errors.New("bu işlem için yetkiniz yok")
)
