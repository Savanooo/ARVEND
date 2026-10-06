package domain

import "errors"

// MinPasswordLength, her şifre yolunun (oluşturma, kendi şifresini
// değiştirme, ilk şifre, yönetici sıfırlaması) TEK kuralı. Eskiden
// sıfırlama 8 isterken kullanıcı oluşturma hiçbir alt sınır koymuyordu.
const MinPasswordLength = 8

var (
	ErrPasswordTooShort = errors.New("şifre en az 8 karakter olmalı")

	// ErrOwnerOnlyAction: Yönetici, Sahip'i ele geçiremesin ya da devre dışı
	// bırakamasın -- Sahip'in şifresini sıfırlamak (yeni şifreyle onun
	// yerine giriş yapılabilirdi), rolünü değiştirmek, onu pasifleştirmek ve
	// birine Sahip rolü vermek yalnızca bir Sahip'in işidir.
	ErrOwnerOnlyAction = errors.New("bu işlemi yalnızca firmanın Sahibi yapabilir: Sahip hesabının şifresini sıfırlamak, rolünü değiştirmek, pasifleştirmek ya da birine Sahip rolü vermek")

	// ErrInitialPasswordAlreadySet: "ilk şifreyi belirle" ucu mevcut şifreyi
	// sormaz; yalnızca geçici şifreyle giriş yapmış (must_change_password)
	// kullanıcı içindir. Açık bir oturumu olan herkes onu kullanıp mevcut
	// şifreyi bilmeden şifreyi değiştirebiliyordu.
	ErrInitialPasswordAlreadySet = errors.New("şifreniz zaten belirlenmiş; değiştirmek için mevcut şifrenizi kullanın")
)

// ValidPasswordLength, şifrenin asgari uzunluğu karşılayıp karşılamadığını
// söyler.
func ValidPasswordLength(p string) bool { return len(p) >= MinPasswordLength }
