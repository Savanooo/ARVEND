package service

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/shopspring/decimal"

	"github.com/Savanooo/ARVEND/backend/internal/pricesource"
)

type memSnapshotStore struct {
	mu    sync.Mutex
	lists map[string]pricesource.List
	saves int
}

func (m *memSnapshotStore) Load(_ context.Context, source string) (pricesource.List, bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	l, ok := m.lists[source]
	if ok {
		l.Origin = pricesource.OriginSnapshot
	}
	return l, ok, nil
}

func (m *memSnapshotStore) Save(_ context.Context, source string, list pricesource.List) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.lists == nil {
		m.lists = map[string]pricesource.List{}
	}
	if prev, ok := m.lists[source]; ok && prev.AsOf.After(list.AsOf) {
		return nil // yalnızca daha yenisi (UpsertPriceSourceSnapshot ile aynı kural)
	}
	m.lists[source] = list
	m.saves++
	return nil
}

func listOf(origin string, asOf time.Time, price string) pricesource.List {
	return pricesource.List{
		Items:  []pricesource.Item{{Name: "Onduline", Unit: "adet", Category: "ÇATI", Price: decimal.RequireFromString(price)}},
		Origin: origin, AsOf: asOf,
	}
}

func TestPriceFallbackFetcher(t *testing.T) {
	ctx := context.Background()
	now := time.Date(2026, 10, 6, 9, 0, 0, 0, time.UTC)
	june := time.Date(2026, 6, 15, 5, 36, 15, 0, time.UTC)
	may := time.Date(2026, 5, 1, 0, 0, 0, 0, time.UTC)
	down := &pricesource.HTTPStatusError{Source: "Ulaş", StatusCode: 500}
	ok := func(l pricesource.List) PriceFetcher {
		return func(context.Context) (pricesource.List, error) { return l, nil }
	}
	fail := func(err error) PriceFetcher {
		return func(context.Context) (pricesource.List, error) { return pricesource.List{}, err }
	}
	clock := func() time.Time { return now }

	t.Run("canlı çalışıyorsa canlı; tarihi şimdi, saklanır", func(t *testing.T) {
		store := &memSnapshotStore{}
		got, err := priceFallbackFetcher("ulas", ok(listOf("", time.Time{}, "330")), fail(errors.New("kullanılmamalı")), store, clock)(ctx)
		if err != nil || got.IsFallback() || !got.AsOf.Equal(now) {
			t.Fatalf("canlı liste beklendi: %+v %v", got, err)
		}
		if saved, has, _ := store.Load(ctx, "ulas"); !has || !saved.AsOf.Equal(now) {
			t.Fatal("canlı liste saklanmalı")
		}
	})

	t.Run("canlı çöktüyse arşiv; canlının hatası listede", func(t *testing.T) {
		store := &memSnapshotStore{}
		got, err := priceFallbackFetcher("ulas", fail(down), ok(listOf(pricesource.OriginArchive, june, "300")), store, clock)(ctx)
		if err != nil || got.Origin != pricesource.OriginArchive || !got.AsOf.Equal(june) {
			t.Fatalf("arşiv beklendi: %+v %v", got, err)
		}
		if !errors.Is(got.LiveErr, down) {
			t.Errorf("canlının hatası taşınmalı: %v", got.LiveErr)
		}
		if saved, has, _ := store.Load(ctx, "ulas"); !has || !saved.AsOf.Equal(june) {
			t.Error("arşiv kopyası da saklanmalı (sonra arşiv de çökerse)")
		}
	})

	t.Run("arşiv de yoksa saklı liste", func(t *testing.T) {
		store := &memSnapshotStore{lists: map[string]pricesource.List{"ulas": listOf("", may, "280")}}
		got, err := priceFallbackFetcher("ulas", fail(down), fail(errors.New("arşiv kapalı")), store, clock)(ctx)
		if err != nil || got.Origin != pricesource.OriginSnapshot || !got.AsOf.Equal(may) {
			t.Fatalf("saklı liste beklendi: %+v %v", got, err)
		}
	})

	t.Run("saklı liste arşivden yeniyse saklı olan seçilir", func(t *testing.T) {
		sept := time.Date(2026, 9, 20, 0, 0, 0, 0, time.UTC)
		store := &memSnapshotStore{lists: map[string]pricesource.List{"ulas": listOf("", sept, "350")}}
		got, _ := priceFallbackFetcher("ulas", fail(down), ok(listOf(pricesource.OriginArchive, june, "300")), store, clock)(ctx)
		if !got.AsOf.Equal(sept) || got.Items[0].Price.String() != "350" {
			t.Fatalf("en yeni veri seçilmeli: %+v", got)
		}
		if saved, _, _ := store.Load(ctx, "ulas"); !saved.AsOf.Equal(sept) {
			t.Error("eski arşiv, saklı yeni listeyi ezmemeli")
		}
	})

	t.Run("hiçbiri yoksa canlının hatası (eski davranış)", func(t *testing.T) {
		_, err := priceFallbackFetcher("demirprofil", fail(down), nil, &memSnapshotStore{}, clock)(ctx)
		if !errors.Is(err, down) {
			t.Fatalf("canlının hatası beklendi: %v", err)
		}
	})
}
