package handler

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestLoginLimiter(t *testing.T) {
	now := time.Date(2026, 10, 7, 10, 0, 0, 0, time.UTC)
	l := newLoginLimiter()
	l.now = func() time.Time { return now }
	ip, ip2 := loginIPKey("203.0.113.5:51234"), loginIPKey("198.51.100.7")
	user, other := loginUserKey("Ahmet"), loginUserKey("mehmet")

	for i := 0; i < loginMaxFailures-1; i++ {
		l.fail(ip, user)
	}
	if l.blockedFor(ip, user) != 0 {
		t.Fatal("9 hatada henüz engellenmemeli")
	}
	l.fail(ip, user)
	if l.blockedFor(ip, user) == 0 {
		t.Fatal("10. hatadan sonra engellenmeli")
	}
	// Aynı IP'den başka hesap da engelli (IP anahtarı).
	if l.blockedFor(ip, other) == 0 {
		t.Error("aynı IP'den başka kullanıcı adı da engellenmeli")
	}
	// Başka IP'den aynı hesap da engelli (kullanıcı anahtarı; büyük/küçük
	// harf ve boşluk aynı anahtar).
	if l.blockedFor(ip2, loginUserKey(" AHMET ")) == 0 {
		t.Error("başka IP'den aynı kullanıcı adı da engellenmeli")
	}
	if l.blockedFor(ip2, other) != 0 {
		t.Error("ilgisiz IP + kullanıcı serbest olmalı")
	}
	// Pencere bitince serbest.
	now = now.Add(loginFailureWindow)
	if l.blockedFor(ip, user) != 0 {
		t.Error("15 dakika sonra serbest kalmalı")
	}

	// Başarılı giriş kullanıcı sayacını sıfırlar, IP sayacını sıfırlamaz.
	for i := 0; i < loginMaxFailures; i++ {
		l.fail(ip2, other)
	}
	l.succeed(other)
	if l.blockedFor(loginIPKey("192.0.2.1"), other) != 0 {
		t.Error("başarılı giriş kullanıcı sayacını sıfırlamalı")
	}
	if l.blockedFor(ip2, loginUserKey("baska")) == 0 {
		t.Error("başarılı giriş IP sayacını sıfırlamamalı")
	}
}

func TestLoginRateLimitedReturns429(t *testing.T) {
	h := &AuthHandler{loginLimiter: newLoginLimiter()}
	for i := 0; i < loginMaxFailures; i++ {
		h.loginLimiter.fail(loginIPKey("203.0.113.9:4000"), loginUserKey("hedef"))
	}
	req := httptest.NewRequest(http.MethodPost, "/api/v1/auth/login", strings.NewReader(`{"username":"hedef","password":"x"}`))
	req.Header.Set("Content-Type", "application/json")
	req.RemoteAddr = "203.0.113.9:4000"
	rec := httptest.NewRecorder()
	// svc nil: engellenen istek servise hiç ulaşmamalı.
	h.Login(rec, req)
	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("429 beklendi, %d", rec.Code)
	}
	if rec.Header().Get("Retry-After") == "" || !strings.Contains(rec.Body.String(), "çok fazla başarısız giriş") {
		t.Errorf("Retry-After ve Türkçe mesaj beklendi: %v %s", rec.Header(), rec.Body.String())
	}
}
