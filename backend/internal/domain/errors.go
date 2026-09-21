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
	// ErrInvalidOrgStatusTransition, OrgStatus.CanTransitionTo'nun izin
	// vermediği bir yaşam döngüsü geçişinde döner (ör. cancelled -> suspended,
	// ya da zaten bulunulan duruma tekrar geçiş).
	ErrInvalidOrgStatusTransition = errors.New("bu durum geçişine izin verilmiyor")
	// ErrReservedUsername, platform provisioning'inde genel "admin" gibi kişiye
	// ait olmayan bir kullanıcı adı istendiğinde döner -- ürün modeli kişiye
	// özel hesaplar + organizasyon rolü (Sahip/Yönetici/...) üzerine kuruludur.
	ErrReservedUsername = errors.New("genel 'admin' kullanıcı adı kullanılamaz; kişiye özel bir kullanıcı adı seçin")
	// ErrRoleNotAssignable, yeni atama hedefi olamayacak bir organizasyon
	// rolü (legacy_user -- yalnızca migration artığı) istendiğinde döner.
	ErrRoleNotAssignable = errors.New("bu rol yeni atama için kullanılamaz")
	// ErrAlreadyDeleted, zaten silinmiş bir kullanıcı/firma tekrar
	// silinmeye çalışıldığında döner (deleted_at IS NULL koşulu WHERE'de
	// zaten 0 satır günceller -- bu, o durumun net bir hataya çevrilmiş
	// hâlidir).
	ErrAlreadyDeleted = errors.New("kayıt zaten silinmiş")
	// ErrNotDeleted, silinmemiş bir kayıt geri yüklenmeye çalışıldığında
	// döner.
	ErrNotDeleted = errors.New("kayıt silinmemiş")
	// ErrOrganizationDeleted, silinmiş bir firma üzerinde -- geri yükleme
	// DIŞINDA -- herhangi bir platform mutasyonu (durum/plan/kullanıcı
	// yönetimi) denendiğinde döner: silinen bir firma önce geri
	// yüklenmeden değiştirilemez.
	ErrOrganizationDeleted = errors.New("firma silinmiş -- önce geri yükleyin")
	// ErrUserDeleted, silinmiş bir kullanıcı -- geri yükleme DIŞINDA --
	// aktifleştirilmeye/atanmaya çalışıldığında döner: silinmiş bir
	// kullanıcı önce restore edilmeden aktifleştirilemez.
	ErrUserDeleted = errors.New("kullanıcı silinmiş -- önce geri yükleyin")
)
