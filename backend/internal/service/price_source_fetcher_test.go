package service_test

// Paylaşımlı fetcher (HTTPPriceFetchers'ın her kaynak için sarmalayıcısı):
// eşzamanlı senkronlar TEK indirmeyi paylaşır, sonuç kısa süre yeniden
// kullanılır -- elle senkron butonu/betik döngüsü tedarikçi sitesine istek
// yağdıramaz. Ağa çıkılmaz: alttaki fetcher sahtedir.

import (
	"context"
	"errors"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/Savanooo/ARVEND/backend/internal/pricesource"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

type fakeClock struct {
	mu  sync.Mutex
	now time.Time
}

func (c *fakeClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *fakeClock) Advance(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.now = c.now.Add(d)
}

func waitFor(t *testing.T, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatal("koşul 5 sn içinde sağlanmadı")
		}
		time.Sleep(time.Millisecond)
	}
}

func TestSharedPriceFetcher(t *testing.T) {
	ctx := context.Background()
	const okTTL, failTTL = 5 * time.Minute, 30 * time.Second

	t.Run("eşzamanlı çağrılar tek indirmeyi paylaşır, sonuç TTL boyunca yeniden kullanılır", func(t *testing.T) {
		clock := &fakeClock{now: time.Date(2026, 9, 27, 12, 0, 0, 0, time.UTC)}
		var calls atomic.Int32
		var fail atomic.Bool
		release := make(chan struct{})
		fetch := service.NewSharedFetcherForTest(func(context.Context) (pricesource.List, error) {
			calls.Add(1)
			<-release
			if fail.Load() {
				return pricesource.List{}, &pricesource.HTTPStatusError{StatusCode: 503}
			}
			return pricesource.List{Items: []pricesource.Item{ulasItem("A", "adet", "K", "10")}, Label: "Eylül 2026", Warnings: []string{"uyarı"}}, nil
		}, okTTL, failTTL, clock.Now)

		const n = 50
		var wg sync.WaitGroup
		errs := make([]error, n)
		got := make([]pricesource.List, n)
		for i := range n {
			wg.Add(1)
			go func() {
				defer wg.Done()
				got[i], errs[i] = fetch(ctx)
			}()
		}
		waitFor(t, func() bool { return calls.Load() == 1 })
		close(release)
		wg.Wait()
		if c := calls.Load(); c != 1 {
			t.Fatalf("%d eşzamanlı çağrı %d indirme yaptı, beklenen 1", n, c)
		}
		for i := range n {
			if errs[i] != nil || len(got[i].Items) != 1 || got[i].Items[0].Name != "A" || got[i].Label != "Eylül 2026" {
				t.Fatalf("#%d: %+v %v", i, got[i], errs[i])
			}
		}
		// Her çağıran kendi kopyasını alır (ürünler ve uyarılar).
		got[0].Items[0].Name = "değiştirildi"
		got[0].Warnings[0] = "değiştirildi"
		if again, _ := fetch(ctx); again.Items[0].Name != "A" || again.Warnings[0] != "uyarı" {
			t.Fatalf("önbellekteki liste çağıranlar arasında paylaşılmamalı: %+v", again)
		}

		clock.Advance(okTTL - time.Second)
		if _, err := fetch(ctx); err != nil || calls.Load() != 1 {
			t.Fatalf("TTL dolmadan yeniden indirilmemeli: %v (indirme %d)", err, calls.Load())
		}
		clock.Advance(2 * time.Second)
		if _, err := fetch(ctx); err != nil || calls.Load() != 2 {
			t.Fatalf("TTL dolunca yeniden indirilmeli: %v (indirme %d)", err, calls.Load())
		}

		// Hata kısa süre hatırlanır (site çökmüşken döngü her istekte indirmesin).
		fail.Store(true)
		clock.Advance(okTTL)
		var statusErr *pricesource.HTTPStatusError
		for range 5 {
			if _, err := fetch(ctx); !errors.As(err, &statusErr) {
				t.Fatalf("503 bekleniyordu, geldi %v", err)
			}
		}
		if calls.Load() != 3 {
			t.Fatalf("hata failTTL boyunca yeniden kullanılmalı (indirme %d, beklenen 3)", calls.Load())
		}
		fail.Store(false)
		clock.Advance(failTTL)
		if list, err := fetch(ctx); err != nil || len(list.Items) != 1 || calls.Load() != 4 {
			t.Fatalf("failTTL dolunca yeniden denenmeli: %v (indirme %d)", err, calls.Load())
		}
	})

	t.Run("bekleyen çağıranın ctx'i iptal edilirse yalnız o döner, indirme diğerleri için sürer", func(t *testing.T) {
		clock := &fakeClock{now: time.Now()}
		var calls atomic.Int32
		release := make(chan struct{})
		fetch := service.NewSharedFetcherForTest(func(ctx context.Context) (pricesource.List, error) {
			calls.Add(1)
			<-release
			if err := ctx.Err(); err != nil {
				return pricesource.List{}, err // ilk çağıranın iptali indirmeyi iptal ETMEMELİ
			}
			return pricesource.List{Items: []pricesource.Item{ulasItem("B", "adet", "K", "5")}}, nil
		}, okTTL, failTTL, clock.Now)

		cctx, cancel := context.WithCancel(ctx)
		done := make(chan error, 1)
		go func() {
			_, err := fetch(cctx)
			done <- err
		}()
		waitFor(t, func() bool { return calls.Load() == 1 })
		cancel()
		if err := <-done; !errors.Is(err, context.Canceled) {
			t.Fatalf("iptal edilen çağıran context.Canceled almalı, geldi %v", err)
		}
		close(release)
		waitFor(t, func() bool {
			list, err := fetch(ctx)
			return err == nil && len(list.Items) == 1 && list.Items[0].Name == "B"
		})
		if c := calls.Load(); c != 1 {
			t.Fatalf("iptal sonrası sonuç önbellekten gelmeli (indirme %d, beklenen 1)", c)
		}
	})

	t.Run("indirmedeki panik süreci düşürmez, hata olarak döner", func(t *testing.T) {
		clock := &fakeClock{now: time.Now()}
		fetch := service.NewSharedFetcherForTest(func(context.Context) (pricesource.List, error) {
			panic("beklenmeyen")
		}, okTTL, failTTL, clock.Now)
		if _, err := fetch(ctx); err == nil {
			t.Fatal("panik hata olarak dönmeliydi")
		}
	})
}
