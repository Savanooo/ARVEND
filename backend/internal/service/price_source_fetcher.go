package service

import (
	"context"
	"fmt"
	"log"
	"net/http"
	"sync"
	"time"

	"github.com/Savanooo/ARVEND/backend/internal/pricesource"
)

// Ulaş indirmesi süreç genelinde paylaşılır: aynı anda gelen senkronlar
// (elle "Ulaş Güncelle", çift tıklama, bir betik, gece işi) TEK indirmeyi
// bekler; sonuç kısa bir süre yeniden kullanılır. Böylece API, ulas.com.tr'ye
// karşı bir yükselticiye dönüşmez (IP'miz engellenirse tüm firmaların
// senkronu bozulurdu). Firma başına senkron kilidi (409) indirmeden SONRA
// alınır; ağ trafiğini sınırlayan bu önbellektir.
const (
	// Başarılı liste bu süre boyunca yeniden kullanılır: Ulaş fiyatları
	// günde bir-iki kez değişir, birkaç dakikalık gecikme zararsızdır.
	ulasFetchCacheTTL = 5 * time.Minute
	// Başarısız deneme de kısa süre hatırlanır: site çökmüşken bir istemci
	// döngüsü her istekte yeniden indirme tetiklemesin.
	ulasFetchFailureTTL = 30 * time.Second
)

// UlasHTTPFetcher, gerçek ulas.com.tr sayfasını indirir (sabit URL, bkz.
// pricesource.FetchUlas). client nil ise varsayılan istemci. Dönen fetcher
// paylaşımlıdır (bkz. sharedFetcher) -- süreç başına BİR kez kurulmalıdır.
func UlasHTTPFetcher(client *http.Client) PriceFetcher {
	return newSharedFetcher(func(ctx context.Context) ([]pricesource.Item, error) {
		return pricesource.FetchUlas(ctx, client)
	}, ulasFetchCacheTTL, ulasFetchFailureTTL, time.Now)
}

// sharedFetcher: eşzamanlı çağrılar tek indirmeyi paylaşır (singleflight),
// tamamlanan sonuç okTTL (başarı) / failTTL (hata) boyunca yeniden
// kullanılır.
type sharedFetcher struct {
	fetch   PriceFetcher
	okTTL   time.Duration
	failTTL time.Duration
	now     func() time.Time

	mu       sync.Mutex
	inflight *fetchCall
	last     *fetchCall
}

type fetchCall struct {
	done  chan struct{}
	items []pricesource.Item
	err   error
	at    time.Time
}

func newSharedFetcher(fetch PriceFetcher, okTTL, failTTL time.Duration, now func() time.Time) PriceFetcher {
	f := &sharedFetcher{fetch: fetch, okTTL: okTTL, failTTL: failTTL, now: now}
	return f.Fetch
}

func (f *sharedFetcher) Fetch(ctx context.Context) ([]pricesource.Item, error) {
	f.mu.Lock()
	if c := f.last; c != nil {
		ttl := f.okTTL
		if c.err != nil {
			ttl = f.failTTL
		}
		if f.now().Sub(c.at) < ttl {
			f.mu.Unlock()
			return c.result()
		}
	}
	c := f.inflight
	if c == nil {
		c = &fetchCall{done: make(chan struct{})}
		f.inflight = c
		// İndirme ilk çağıranın ctx'inden BAĞIMSIZDIR: o istemci ayrılsa
		// bile bekleyen diğerleri sonucu alır. Süre sınırı FetchUlas'ın
		// kendi 30 sn'sidir.
		go f.run(context.WithoutCancel(ctx), c)
	}
	f.mu.Unlock()

	select {
	case <-c.done:
		return c.result()
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

func (f *sharedFetcher) run(ctx context.Context, c *fetchCall) {
	var (
		items []pricesource.Item
		err   error
	)
	func() {
		// Ayrı goroutine: bir panik süreci düşürmesin, hata olarak dönsün.
		defer func() {
			if r := recover(); r != nil {
				log.Printf("fiyat senkronu: indirme panikledi: %v", r)
				err = fmt.Errorf("fiyat listesi indirilirken beklenmeyen hata: %v", r)
			}
		}()
		items, err = f.fetch(ctx)
	}()

	f.mu.Lock()
	c.items, c.err, c.at = items, err, f.now()
	f.inflight = nil
	f.last = c
	f.mu.Unlock()
	close(c.done)
}

// result, her çağırana listenin KENDİ kopyasını verir (önbellekteki dilim
// paylaşılmaz).
func (c *fetchCall) result() ([]pricesource.Item, error) {
	if c.err != nil {
		return nil, c.err
	}
	return append([]pricesource.Item(nil), c.items...), nil
}
