package service_test

import (
	"context"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgtype"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/pricesource"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

// TestPriceSourceFallbackFreshness: Ulaş canlı sitesi çöktüğünde arşiv/
// saklı liste (sahada 2026-10). Yedek liste firmanın fiyatlarından yeni
// değilse UYGULANMAZ -- canlıdan alınmış yeni fiyatlar eski kopyayla geri
// alınmasın; fiyatlar korunur ve neden söylenir.
func TestPriceSourceFallbackFreshness(t *testing.T) {
	dbURL := testDBURL(t)
	ctx := context.Background()
	pool, err := repository.NewPool(ctx, dbURL)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { pool.Close() })
	q := sqlc.New(pool)
	orgSvc := service.NewOrganizationService(q)

	var mu sync.Mutex
	var next pricesource.List
	setNext := func(l pricesource.List) { mu.Lock(); next = l; mu.Unlock() }
	fetcher := func(context.Context) (pricesource.List, error) {
		mu.Lock()
		defer mu.Unlock()
		return next.Clone(), nil
	}
	svc := service.NewPriceSourceService(pool, q, map[string]service.PriceFetcher{domain.PriceSourceUlas: fetcher})

	org := mustCreateOrg(t, ctx, orgSvc, pool, "Yedek Liste Test", "yedek-liste-test")
	price := func(name string) string {
		var p string
		if err := pool.QueryRow(ctx, `SELECT source_price::text FROM products WHERE organization_id = $1 AND name = $2`,
			org.ID, name).Scan(&p); err != nil {
			t.Fatalf("%s okunamadı: %v", name, err)
		}
		return p
	}
	items := func(p1, p2 string) []pricesource.Item {
		return []pricesource.Item{ulasItem("Onduline", "adet", "ÇATI", p1), ulasItem("Sandviç Panel Sac", "m2", "ÇATI", p2)}
	}
	june := time.Date(2026, 6, 15, 5, 36, 15, 0, time.UTC)
	down := &pricesource.HTTPStatusError{Source: "Ulaş", StatusCode: 500}

	// 1) Canlıdan güncel fiyatlar (veri tarihi = şimdi).
	setNext(pricesource.List{Items: items("330", "500")})
	if _, err := svc.Sync(ctx, org.ID, domain.PriceSourceUlas, ""); err != nil {
		t.Fatalf("canlı senkron: %v", err)
	}
	if price("Onduline") != "330.00" {
		t.Fatalf("canlı fiyat uygulanmalı: %s", price("Onduline"))
	}

	// 2) Canlı çöktü, elde yalnızca Haziran arşivi: UYGULANMAZ, fiyatlar korunur.
	setNext(pricesource.List{Items: items("300", "450"), Origin: pricesource.OriginArchive, AsOf: june,
		Label: pricesource.ArchiveLabel(june), LiveErr: down})
	_, err = svc.Sync(ctx, org.ID, domain.PriceSourceUlas, "")
	if !errors.Is(err, domain.ErrPriceSourceFetch) {
		t.Fatalf("eski yedek reddedilmeli, geldi %v", err)
	}
	if price("Onduline") != "330.00" {
		t.Errorf("fiyat geri alınmamalı: %s", price("Onduline"))
	}
	ov := ulasOverview(t, svc, org.ID)
	if ov.LastStatus != domain.PriceSyncStatusFailed || !strings.Contains(ov.LastError, "HTTP 500") ||
		!strings.Contains(ov.LastError, "fiyatlar korunuyor") {
		t.Errorf("neden açıkça söylenmeli: %q / %q", ov.LastStatus, ov.LastError)
	}

	// 3) Arşivde daha YENİ bir kopya çıktı: uygulanır, dönem etiketi arşivi söyler,
	// veri tarihi kopyanınki olur.
	later := time.Now().Add(time.Hour)
	setNext(pricesource.List{Items: items("360", "520"), Origin: pricesource.OriginArchive, AsOf: later,
		Label: pricesource.ArchiveLabel(later), LiveErr: down})
	if _, err := svc.Sync(ctx, org.ID, domain.PriceSourceUlas, ""); err != nil {
		t.Fatalf("yeni yedek uygulanmalı: %v", err)
	}
	if price("Onduline") != "360.00" {
		t.Errorf("yeni yedek fiyatı: %s", price("Onduline"))
	}
	if ov := ulasOverview(t, svc, org.ID); !strings.HasPrefix(ov.ListLabel, "Arşiv kopyası · ") {
		t.Errorf("dönem etiketi arşivi söylemeli: %q", ov.ListLabel)
	}
	asOf, err := q.GetPriceSourceListAsOf(ctx, sqlc.GetPriceSourceListAsOfParams{
		OrganizationID: mustUUID(t, org.ID), Source: domain.PriceSourceUlas,
	})
	if err != nil || !asOf.Time.Equal(later.Truncate(time.Microsecond)) {
		t.Errorf("veri tarihi kopyanınki olmalı: %v %v", asOf.Time, err)
	}

	// 4) Hiç senkronu olmayan firma: Haziran arşivi bile boş katalogdan iyidir.
	fresh := mustCreateOrg(t, ctx, orgSvc, pool, "Yedek Liste Yeni Firma", "yedek-liste-yeni-firma")
	setNext(pricesource.List{Items: items("300", "450"), Origin: pricesource.OriginArchive, AsOf: june,
		Label: pricesource.ArchiveLabel(june), LiveErr: down})
	res, err := svc.Sync(ctx, fresh.ID, domain.PriceSourceUlas, "")
	if err != nil || res.Created != 2 {
		t.Fatalf("boş kataloğa arşiv uygulanmalı: %+v %v", res, err)
	}
}

// TestPriceSnapshotStore: saklı liste yalnızca daha YENİ tarihli bir
// listeyle değişir; fiyat kuruşu kuruşuna geri okunur.
func TestPriceSnapshotStore(t *testing.T) {
	dbURL := testDBURL(t)
	ctx := context.Background()
	pool, err := repository.NewPool(ctx, dbURL)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { pool.Close() })
	q := sqlc.New(pool)
	store := service.NewDBPriceSnapshotStore(q)
	const src = "test_snapshot_kaynak"
	if _, err := pool.Exec(ctx, `DELETE FROM price_source_snapshots WHERE source = $1`, src); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_, _ = pool.Exec(context.Background(), `DELETE FROM price_source_snapshots WHERE source = $1`, src)
	})

	if _, ok, err := store.Load(ctx, src); ok || err != nil {
		t.Fatalf("başta saklı liste yok: %v %v", ok, err)
	}
	sept := time.Date(2026, 9, 20, 10, 0, 0, 0, time.UTC)
	june := time.Date(2026, 6, 15, 5, 36, 15, 0, time.UTC)
	if err := store.Save(ctx, src, pricesource.List{
		Items: []pricesource.Item{ulasItem("Sandviç Panel Sac", "m2", "ÇATI MALZEMELERİ", "1234.56")},
		Label: "Eylül 2026", AsOf: sept,
	}); err != nil {
		t.Fatal(err)
	}
	if err := store.Save(ctx, src, pricesource.List{
		Items:  []pricesource.Item{ulasItem("Onduline", "adet", "ÇATI", "300")},
		Origin: pricesource.OriginArchive, AsOf: june,
	}); err != nil {
		t.Fatal(err)
	}
	got, ok, err := store.Load(ctx, src)
	if err != nil || !ok {
		t.Fatalf("okunamadı: %v", err)
	}
	if !got.AsOf.Equal(sept) || len(got.Items) != 1 || got.Items[0].Name != "Sandviç Panel Sac" ||
		got.Items[0].Price.String() != "1234.56" || got.Origin != pricesource.OriginSnapshot {
		t.Errorf("eski arşiv yeni listeyi ezmemeli, fiyat kayıpsız okunmalı: %+v", got)
	}
	if !strings.HasPrefix(got.Label, "Eylül 2026 · kayıtlı kopya (") {
		t.Errorf("etiket kayıtlı kopya olduğunu söylemeli: %q", got.Label)
	}
}

func mustUUID(t *testing.T, s string) pgtype.UUID {
	t.Helper()
	u, err := repository.StringToUUID(s)
	if err != nil {
		t.Fatal(err)
	}
	return u
}
