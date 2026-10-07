package handler

import (
	"net"
	"strings"
	"sync"
	"time"
)

// Giriş denemesi sınırı: aynı IP'den VEYA aynı kullanıcı adına
// loginMaxFailures başarısız deneme loginFailureWindow içinde dolunca
// giriş, pencere bitene kadar 429 ile reddedilir. Şifre tahmini
// (brute-force) /auth/login'de hiçbir şeyle sınırlanmıyordu.
//
// İki anahtar birlikte: IP sınırı tek kaynaktan çok hesabı tarayanı,
// kullanıcı adı sınırı çok IP'den tek hesabı deneyeni durdurur. IP,
// router'daki chi RealIP'in çözdüğü r.RemoteAddr'dır (uygulamanın geri
// kalanıyla aynı istemci IP mantığı); o başlıklardan gelen değer
// sahtelenebildiği için asıl koruma kullanıcı adı sınırıdır.
//
// Bellek içi ve süreç başınadır (tek API süreci çalışıyor); yeniden
// başlatma sayaçları sıfırlar -- bu bir hesap kilidi değil, hız sınırıdır.
const (
	loginMaxFailures   = 10
	loginFailureWindow = 15 * time.Minute
	// loginLimiterSweepAt: harita bu boyutu geçince süresi dolmuş girdiler
	// temizlenir (rastgele kullanıcı adlarıyla belleği şişirme önlenir).
	loginLimiterSweepAt = 10_000
)

type loginAttempts struct {
	failures    int
	windowStart time.Time
}

type loginLimiter struct {
	max    int
	window time.Duration
	now    func() time.Time

	mu      sync.Mutex
	entries map[string]*loginAttempts
}

func newLoginLimiter() *loginLimiter {
	return &loginLimiter{
		max: loginMaxFailures, window: loginFailureWindow, now: time.Now,
		entries: map[string]*loginAttempts{},
	}
}

func loginIPKey(remoteAddr string) string {
	host := remoteAddr
	if h, _, err := net.SplitHostPort(remoteAddr); err == nil {
		host = h
	}
	return "ip:" + host
}

func loginUserKey(username string) string {
	return "user:" + strings.ToLower(strings.TrimSpace(username))
}

// blockedFor, anahtarlardan biri sınırdaysa kalan bekleme süresini döner
// (0 = serbest).
func (l *loginLimiter) blockedFor(keys ...string) time.Duration {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.now()
	var wait time.Duration
	for _, k := range keys {
		e, ok := l.entries[k]
		if !ok {
			continue
		}
		end := e.windowStart.Add(l.window)
		if !now.Before(end) {
			delete(l.entries, k)
			continue
		}
		if e.failures >= l.max && end.Sub(now) > wait {
			wait = end.Sub(now)
		}
	}
	return wait
}

// fail, başarısız bir denemeyi her anahtara yazar.
func (l *loginLimiter) fail(keys ...string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.now()
	if len(l.entries) >= loginLimiterSweepAt {
		for k, e := range l.entries {
			if !now.Before(e.windowStart.Add(l.window)) {
				delete(l.entries, k)
			}
		}
	}
	for _, k := range keys {
		e, ok := l.entries[k]
		if !ok || !now.Before(e.windowStart.Add(l.window)) {
			l.entries[k] = &loginAttempts{failures: 1, windowStart: now}
			continue
		}
		e.failures++
	}
}

// succeed, başarılı girişte kullanıcı adının sayacını sıfırlar. IP sayacı
// sıfırlanmaz: saldırgan arada kendi geçerli hesabıyla girerek IP
// sınırını silemesin.
func (l *loginLimiter) succeed(userKey string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	delete(l.entries, userKey)
}
