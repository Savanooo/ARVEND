// Package httpjson, handler'larda tekrar eden JSON yanıt/hata yazımını
// tek yerde toplar.
package httpjson

import (
	"encoding/json"
	"log"
	"net/http"
)

func Write(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	if payload == nil {
		return
	}
	if err := json.NewEncoder(w).Encode(payload); err != nil {
		log.Printf("httpjson: encode hatası: %v", err)
	}
}

func Error(w http.ResponseWriter, status int, message string) {
	Write(w, status, map[string]string{"error": message})
}

// TemporarilyUnavailableCode, 503 yanıtının makine-okunur kodu (bkz.
// TemporarilyUnavailable).
const TemporarilyUnavailableCode = "temporarily_unavailable"

// TemporarilyUnavailable, veritabanına o an ulaşılamadığında (bağlantı
// koptu, Postgres yeniden başlıyor) 503 yazar. Oturum ya da firma hakkında
// bir şey SÖYLEMEZ: istemciler bu yanıtta çerezleri silmez, oturumu
// kapatmaz, "firma askıya alınmış" ekranı açmaz -- kısa süre sonra aynı
// istek tekrar denenir. 401/403 yalnızca oturumun gerçekten bittiği
// durumlar içindir.
func TemporarilyUnavailable(w http.ResponseWriter) {
	w.Header().Set("Retry-After", "5")
	Write(w, http.StatusServiceUnavailable, map[string]string{
		"error": "sunucu şu anda yanıt veremiyor, biraz sonra tekrar deneyin",
		"code":  TemporarilyUnavailableCode,
	})
}

func Decode(r *http.Request, dst any) error {
	defer r.Body.Close()
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	return dec.Decode(dst)
}
