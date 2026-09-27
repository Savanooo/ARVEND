package service_test

// Tedarikçi fiyat listesi senkronu (migration 0045) gerçek veritabanına
// karşı: eşleştirme/oluşturma/eksik sayımı, kâr oranı matematiği, yeniden
// fiyatlama + fiyat geçmişi, elle eklenen ürünlerin ve başka firmaların
// korunması, indirme hatası, eşzamanlılık kilidi, gece işi. Fiyat listesi
// sahte bir fetcher'dan gelir -- testler ulas.com.tr'ye ASLA gitmez.

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/shopspring/decimal"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/pricesource"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

// fakeUlas, servis testlerinin sahte fiyat listesi kaynağıdır.
type fakeUlas struct {
	mu    sync.Mutex
	items []pricesource.Item
	err   error
	calls int
}

func (f *fakeUlas) set(err error, items ...pricesource.Item) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.items, f.err = items, err
}

func (f *fakeUlas) fetch(context.Context) ([]pricesource.Item, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls++
	if f.err != nil {
		return nil, f.err
	}
	return append([]pricesource.Item(nil), f.items...), nil
}

func (f *fakeUlas) callCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.calls
}

func ulasItem(name, unit, category, price string) pricesource.Item {
	return pricesource.Item{Name: name, Unit: unit, Category: category, Price: decimal.RequireFromString(price)}
}

// testProduct, doğrulama için products satırının ham hâli.
type testProduct struct {
	ID          string
	Name        string
	Unit        string
	UnitPrice   string
	SourcePrice *string
	Source      *string
	Category    string
	Description string
	SyncedAt    *time.Time
	UpdatedAt   time.Time
}

func loadTestProducts(t *testing.T, pool *pgxpool.Pool, orgID string) []testProduct {
	t.Helper()
	rows, err := pool.Query(context.Background(), `
		SELECT id::text, name, unit, unit_price::text, source_price::text, source, category, description,
		       source_synced_at, updated_at
		FROM products WHERE organization_id = $1 ORDER BY name, unit, created_at, id`, orgID)
	if err != nil {
		t.Fatalf("ürünler okunamadı: %v", err)
	}
	defer rows.Close()
	var out []testProduct
	for rows.Next() {
		var p testProduct
		if err := rows.Scan(&p.ID, &p.Name, &p.Unit, &p.UnitPrice, &p.SourcePrice, &p.Source, &p.Category,
			&p.Description, &p.SyncedAt, &p.UpdatedAt); err != nil {
			t.Fatalf("ürün satırı okunamadı: %v", err)
		}
		out = append(out, p)
	}
	return out
}

// fingerprint, satırın karşılaştırılabilir (işaretçisiz) özetidir.
func (p testProduct) fingerprint() string {
	deref := func(s *string) string {
		if s == nil {
			return "<nil>"
		}
		return *s
	}
	synced := "<nil>"
	if p.SyncedAt != nil {
		synced = p.SyncedAt.UTC().Format(time.RFC3339Nano)
	}
	return fmt.Sprintf("%s|%s|%s|%s|%s|%s|%s|%s|%s|%s", p.ID, p.Name, p.Unit, p.UnitPrice, deref(p.SourcePrice),
		deref(p.Source), p.Category, p.Description, synced, p.UpdatedAt.UTC().Format(time.RFC3339Nano))
}

func findTestProducts(ps []testProduct, name, unit string, source *string) []testProduct {
	var out []testProduct
	for _, p := range ps {
		sameSource := (p.Source == nil && source == nil) || (p.Source != nil && source != nil && *p.Source == *source)
		if p.Name == name && p.Unit == unit && sameSource {
			out = append(out, p)
		}
	}
	return out
}

func insertTestProduct(t *testing.T, pool *pgxpool.Pool, orgID, name, unit, unitPrice string, source *string, description string) string {
	t.Helper()
	var id string
	if err := pool.QueryRow(context.Background(), `
		INSERT INTO products (organization_id, name, normalized_name, unit, unit_price, description, source)
		VALUES ($1, $2, $3, $4, $5::numeric, $6, $7) RETURNING id::text`,
		orgID, name, domain.NormalizeName(name), unit, unitPrice, description, source).Scan(&id); err != nil {
		t.Fatalf("ürün eklenemedi (%s): %v", name, err)
	}
	return id
}

type historyEntry struct{ Old, New, Note string }

func loadHistory(t *testing.T, pool *pgxpool.Pool, productID string) []historyEntry {
	t.Helper()
	rows, err := pool.Query(context.Background(),
		`SELECT old_price::text, new_price::text, note FROM product_price_history WHERE product_id = $1 ORDER BY changed_at, id`, productID)
	if err != nil {
		t.Fatalf("fiyat geçmişi okunamadı: %v", err)
	}
	defer rows.Close()
	var out []historyEntry
	for rows.Next() {
		var h historyEntry
		if err := rows.Scan(&h.Old, &h.New, &h.Note); err != nil {
			t.Fatalf("fiyat geçmişi satırı okunamadı: %v", err)
		}
		out = append(out, h)
	}
	return out
}

func countHistoryForOrg(t *testing.T, pool *pgxpool.Pool, orgID string) int {
	t.Helper()
	var n int
	if err := pool.QueryRow(context.Background(), `
		SELECT count(*) FROM product_price_history h JOIN products p ON p.id = h.product_id
		WHERE p.organization_id = $1`, orgID).Scan(&n); err != nil {
		t.Fatalf("fiyat geçmişi sayılamadı: %v", err)
	}
	return n
}

func expectResult(t *testing.T, got *domain.PriceSyncResult, total, created, updated, unchanged, missing int) {
	t.Helper()
	if got.Total != total || got.Created != created || got.Updated != updated || got.Unchanged != unchanged || got.Missing != missing {
		t.Fatalf("senkron sonucu = {total %d, created %d, updated %d, unchanged %d, missing %d}, beklenen {%d %d %d %d %d}",
			got.Total, got.Created, got.Updated, got.Unchanged, got.Missing, total, created, updated, unchanged, missing)
	}
}

func onlyOverview(t *testing.T, svc *service.PriceSourceService, orgID string) domain.PriceSourceOverview {
	t.Helper()
	list, err := svc.GetPriceSources(context.Background(), orgID)
	if err != nil {
		t.Fatalf("fiyat kaynakları okunamadı: %v", err)
	}
	if len(list) != 1 || list[0].Source != domain.PriceSourceUlas {
		t.Fatalf("tek kaynak (ulas) bekleniyordu: %+v", list)
	}
	return list[0]
}

func TestApplyMarkupMath(t *testing.T) {
	cases := []struct{ source, rate, want string }{
		{"500", "15", "575.00"},
		{"333.33", "12.5", "375.00"}, // 374.99625 -> yarım yukarı
		{"4.5", "15", "5.18"},        // BYZ float round(5.175) 5.17 veriyordu
		{"100", "0", "100.00"},
		{"0.01", "1000", "0.11"},
		{"1234.56", "7.25", "1324.07"}, // 1324.0656
	}
	for _, c := range cases {
		got := domain.ApplyMarkup(decimal.RequireFromString(c.source), decimal.RequireFromString(c.rate))
		if got.StringFixed(2) != c.want {
			t.Errorf("ApplyMarkup(%s, %%%s) = %s, beklenen %s", c.source, c.rate, got.StringFixed(2), c.want)
		}
	}
}

func TestNextPriceSyncRun(t *testing.T) {
	ist, err := time.LoadLocation("Europe/Istanbul")
	if err != nil {
		t.Fatalf("Europe/Istanbul yüklenemedi (time/tzdata gömülü olmalı): %v", err)
	}
	cases := []struct {
		now  time.Time
		want time.Time
	}{
		// Gün içinde -> ertesi gün 00:05.
		{time.Date(2026, 9, 27, 10, 0, 0, 0, ist), time.Date(2026, 9, 28, 0, 5, 0, 0, ist)},
		// 00:05'ten hemen önce -> aynı gün.
		{time.Date(2026, 9, 27, 0, 4, 59, 0, ist), time.Date(2026, 9, 27, 0, 5, 0, 0, ist)},
		// Tam 00:05 -> KESİNLİKLE sonraki (ertesi gün).
		{time.Date(2026, 9, 27, 0, 5, 0, 0, ist), time.Date(2026, 9, 28, 0, 5, 0, 0, ist)},
		// UTC girdisi: 21:04Z = 00:04 İstanbul -> 21:05Z.
		{time.Date(2026, 9, 26, 21, 4, 0, 0, time.UTC), time.Date(2026, 9, 26, 21, 5, 0, 0, time.UTC)},
		// UTC'de hâlâ "dün" olan an İstanbul'da bugündür.
		{time.Date(2026, 9, 26, 22, 0, 0, 0, time.UTC), time.Date(2026, 9, 27, 21, 5, 0, 0, time.UTC)},
		// Yıl dönümü.
		{time.Date(2026, 12, 31, 23, 59, 0, 0, ist), time.Date(2027, 1, 1, 0, 5, 0, 0, ist)},
		// Avrupa yaz saati geçiş günleri: İstanbul sabit UTC+3, kayma yok.
		{time.Date(2026, 3, 29, 12, 0, 0, 0, time.UTC), time.Date(2026, 3, 29, 21, 5, 0, 0, time.UTC)},
		{time.Date(2026, 10, 25, 12, 0, 0, 0, time.UTC), time.Date(2026, 10, 25, 21, 5, 0, 0, time.UTC)},
	}
	for _, c := range cases {
		got := service.NextPriceSyncRun(c.now)
		if !got.Equal(c.want) {
			t.Errorf("NextPriceSyncRun(%s) = %s, beklenen %s", c.now.Format(time.RFC3339), got.Format(time.RFC3339), c.want.Format(time.RFC3339))
		}
		if !got.After(c.now) {
			t.Errorf("NextPriceSyncRun(%s) = %s geçmişte/şimdi", c.now, got)
		}
		if _, off := got.Zone(); off != 3*60*60 {
			t.Errorf("sonuç İstanbul saatinde (UTC+3) olmalı, offset %d", off)
		}
	}
}

func TestPriceSourceSync(t *testing.T) {
	dbURL := testDBURL(t)
	ctx := context.Background()
	pool, err := repository.NewPool(ctx, dbURL)
	if err != nil {
		t.Fatalf("veritabanına bağlanılamadı: %v", err)
	}
	t.Cleanup(func() { pool.Close() })
	q := sqlc.New(pool)
	orgSvc := service.NewOrganizationService(q)
	userSvc := service.NewUserService(q)
	fake := &fakeUlas{}
	svc := service.NewPriceSourceService(pool, q, fake.fetch)

	orgA := mustCreateOrg(t, ctx, orgSvc, pool, "Fiyat Kaynağı Test A", "fiyat-kaynagi-test-a")
	orgB := mustCreateOrg(t, ctx, orgSvc, pool, "Fiyat Kaynağı Test B", "fiyat-kaynagi-test-b")
	actor, err := userSvc.Create(ctx, orgA.ID, "fiyat_kaynagi_sahip", "GeciciSifre123!", "Fiyat Sahip", domain.RoleAdmin, "")
	if err != nil {
		t.Fatalf("kullanıcı oluşturulamadı: %v", err)
	}
	ulas := strPtr(domain.PriceSourceUlas)

	// --- BYZ'den aktarılmış gibi mevcut satırlar (kategori boş, Ulaş
	// kategorisi açıklamada, source_price NULL) ---
	sandvicID := insertTestProduct(t, pool, orgA.ID, "Sandviç Panel Sac", "m2", "575.00", ulas, "ÇATI MALZEMELERİ")
	ondulineIDs := []string{
		insertTestProduct(t, pool, orgA.ID, "Onduline", "adet", "379.50", ulas, "ÇATI MALZEMELERİ"),
		insertTestProduct(t, pool, orgA.ID, "Onduline", "adet", "379.50", ulas, "ÇATI MALZEMELERİ"),
	}
	dekorID := insertTestProduct(t, pool, orgA.ID, "Dekor  Silteks Rulo", "adet", "40.00", ulas, "") // çift boşluk (BYZ)
	eskiID := insertTestProduct(t, pool, orgA.ID, "Eski Ürün", "adet", "100.00", ulas, "")
	manualID := insertTestProduct(t, pool, orgA.ID, "Perlitli Alçı", "adet", "42.00", nil, "elle eklendi")
	otherSourceID := insertTestProduct(t, pool, orgA.ID, "OSB Levha", "adet", "10.00", strPtr("diger"), "")
	orgBProductID := insertTestProduct(t, pool, orgB.ID, "Sandviç Panel Sac", "m2", "1.00", ulas, "")

	// Metraj reçetesi Sandviç'e bağlı -- senkrondan sonra da bağlı kalmalı.
	var recipeID string
	if err := pool.QueryRow(ctx, `
		WITH g AS (
			INSERT INTO calc_groups (organization_id, slug, name) VALUES ($1, 'fiyat-test-grup', 'Fiyat Test') RETURNING id
		), c AS (
			INSERT INTO calc_categories (organization_id, group_id, slug, name)
			SELECT $1, g.id, 'fiyat-test-kategori', 'Fiyat Test Kategori' FROM g RETURNING id
		)
		INSERT INTO calc_recipe_items (organization_id, category_id, product_id, material_name, unit, calculation_type, quantity_per_m2)
		SELECT $1, c.id, $2, 'Sandviç Panel Sac', 'm2', 'area_based', 1 FROM c RETURNING id::text`,
		orgA.ID, sandvicID).Scan(&recipeID); err != nil {
		t.Fatalf("reçete kalemi oluşturulamadı: %v", err)
	}
	recipeProduct := func() *string {
		var pid *string
		if err := pool.QueryRow(ctx, `SELECT product_id::text FROM calc_recipe_items WHERE id = $1`, recipeID).Scan(&pid); err != nil {
			t.Fatalf("reçete kalemi okunamadı: %v", err)
		}
		return pid
	}

	before := loadTestProducts(t, pool, orgA.ID)
	manualBefore := findTestProducts(before, "Perlitli Alçı", "adet", nil)[0]
	orgBBefore := loadTestProducts(t, pool, orgB.ID)

	t.Run("hiç ayar yokken varsayılanlar", func(t *testing.T) {
		ov := onlyOverview(t, svc, orgA.ID)
		if !ov.MarkupPercent.Equal(decimal.NewFromInt(15)) || ov.AutoSync || ov.LastStatus != domain.PriceSyncStatusNever ||
			ov.LastSyncedAt != nil || len(ov.CategoryMarkups) != 0 {
			t.Fatalf("varsayılanlar yanlış: %+v", ov)
		}
		// BYZ'den gelen satırların kategorisi boş: henüz kategori yok; hiç
		// senkron olmadığı için "eksik" de sayılmaz.
		if ov.ProductCount != 5 || ov.MissingCount != 0 || len(ov.Categories) != 0 {
			t.Fatalf("özet yanlış: product_count=%d missing=%d categories=%v", ov.ProductCount, ov.MissingCount, ov.Categories)
		}
	})

	list1 := []pricesource.Item{
		ulasItem("Sandviç Panel Sac", "m2", "ÇATI MALZEMELERİ", "500"),
		ulasItem("Onduline", "adet", "ÇATI MALZEMELERİ", "330"),
		ulasItem("Dekor Silteks Rulo", "adet", "BOYA", "38"),
		ulasItem("Perlitli Alçı", "adet", "ALÇILAR", "333.33"),
		ulasItem("OSB Levha", "adet", "AHŞAP", "200"),
		ulasItem("Yeni Ürün", "adet", "ÇATI MALZEMELERİ", "10"),
	}

	t.Run("ilk senkron: eşleşenleri günceller, yenileri ekler, düşeni silmez", func(t *testing.T) {
		fake.set(nil, list1...)
		res, err := svc.SyncUlas(ctx, orgA.ID, actor.ID)
		if err != nil {
			t.Fatalf("senkron hatası: %v", err)
		}
		// Sandviç (kategori+kaynak fiyatı), Onduline (2 satır), Dekor (fiyat)
		// güncellendi; Perlitli/OSB/Yeni oluşturuldu; Eski Ürün eksik.
		expectResult(t, res, 6, 3, 3, 0, 1)

		after := loadTestProducts(t, pool, orgA.ID)
		s := findTestProducts(after, "Sandviç Panel Sac", "m2", ulas)
		if len(s) != 1 || s[0].ID != sandvicID || s[0].UnitPrice != "575.00" || s[0].SourcePrice == nil || *s[0].SourcePrice != "500.00" ||
			s[0].Category != "ÇATI MALZEMELERİ" || s[0].Description != "ÇATI MALZEMELERİ" || s[0].SyncedAt == nil {
			t.Fatalf("Sandviç yanlış güncellendi: %+v", s)
		}
		if pid := recipeProduct(); pid == nil || *pid != sandvicID {
			t.Fatalf("reçete kalemi ürüne bağlı kalmalı: %v", pid)
		}
		if h := loadHistory(t, pool, sandvicID); len(h) != 0 {
			t.Fatalf("fiyat değişmediyse geçmiş yazılmamalı: %+v", h)
		}

		o := findTestProducts(after, "Onduline", "adet", ulas)
		if len(o) != 2 {
			t.Fatalf("iki Onduline satırı da kalmalı: %+v", o)
		}
		for _, p := range o {
			if (p.ID != ondulineIDs[0] && p.ID != ondulineIDs[1]) || p.SourcePrice == nil || *p.SourcePrice != "330.00" || p.UnitPrice != "379.50" || p.SyncedAt == nil {
				t.Fatalf("tekrarlanan anahtarın TÜM satırları güncellenmeli: %+v", p)
			}
		}

		d := findTestProducts(after, "Dekor  Silteks Rulo", "adet", ulas)
		if len(d) != 1 || d[0].ID != dekorID || d[0].UnitPrice != "43.70" || d[0].Category != "BOYA" {
			t.Fatalf("boşluk farkıyla eşleşen satır adı korunarak güncellenmeli: %+v", d)
		}
		if h := loadHistory(t, pool, dekorID); len(h) != 1 || h[0] != (historyEntry{"40.00", "43.70", domain.PriceHistoryNoteUlasSync}) {
			t.Fatalf("Dekor fiyat geçmişi yanlış: %+v", h)
		}
		if len(findTestProducts(after, "Dekor Silteks Rulo", "adet", ulas)) != 0 {
			t.Fatal("boşluk farkı yüzünden yeni kopya oluşturulmamalı")
		}

		created := findTestProducts(after, "Perlitli Alçı", "adet", ulas)
		if len(created) != 1 || created[0].UnitPrice != "383.33" || created[0].Description != "" || created[0].Category != "ALÇILAR" {
			t.Fatalf("yeni Ulaş ürünü yanlış: %+v", created)
		}
		var norm string
		if err := pool.QueryRow(ctx, `SELECT normalized_name FROM products WHERE id = $1`, created[0].ID).Scan(&norm); err != nil || norm != domain.NormalizeName("Perlitli Alçı") {
			t.Fatalf("normalized_name yanlış: %q %v", norm, err)
		}
		if y := findTestProducts(after, "Yeni Ürün", "adet", ulas); len(y) != 1 || y[0].UnitPrice != "11.50" {
			t.Fatalf("Yeni Ürün yanlış: %+v", y)
		}

		// Elle eklenen ve başka kaynaklı aynı adlı ürünler DOKUNULMAZ.
		m := findTestProducts(after, "Perlitli Alçı", "adet", nil)
		if len(m) != 1 || m[0].ID != manualID || m[0].fingerprint() != manualBefore.fingerprint() {
			t.Fatalf("elle eklenen ürün değişti: önce %+v sonra %+v", manualBefore, m)
		}
		if other := findTestProducts(after, "OSB Levha", "adet", strPtr("diger")); len(other) != 1 || other[0].ID != otherSourceID ||
			other[0].UnitPrice != "10.00" || other[0].SyncedAt != nil {
			t.Fatalf("başka kaynaklı ürün değişti: %+v", other)
		}

		// Listeden düşen: silinmez, fiyatı değişmez, eksik sayılır.
		e := findTestProducts(after, "Eski Ürün", "adet", ulas)
		if len(e) != 1 || e[0].ID != eskiID || e[0].UnitPrice != "100.00" || e[0].SyncedAt != nil {
			t.Fatalf("listeden düşen ürün korunmalı: %+v", e)
		}

		ov := onlyOverview(t, svc, orgA.ID)
		if ov.LastStatus != domain.PriceSyncStatusSuccess || ov.LastSyncedAt == nil || ov.LastError != "" ||
			ov.ProductCount != 8 || ov.MissingCount != 1 || ov.LastResult.Total != 6 || ov.LastResult.Missing != 1 {
			t.Fatalf("özet yanlış: %+v", ov)
		}
		if !ov.LastSyncedAt.Equal(res.SyncedAt) {
			t.Fatalf("last_synced_at (%s) senkron sonucuyla (%s) aynı olmalı", ov.LastSyncedAt, res.SyncedAt)
		}
		gotCats := map[string]int{}
		for _, c := range ov.Categories {
			gotCats[c.Category] = c.ProductCount
		}
		wantCats := map[string]int{"ÇATI MALZEMELERİ": 4, "BOYA": 1, "ALÇILAR": 1, "AHŞAP": 1}
		if len(gotCats) != len(wantCats) {
			t.Fatalf("kategoriler yanlış: %v", gotCats)
		}
		for k, v := range wantCats {
			if gotCats[k] != v {
				t.Fatalf("kategoriler yanlış: %v", gotCats)
			}
		}
	})

	t.Run("aynı listeyle tekrar senkron: hepsi değişmedi", func(t *testing.T) {
		historyBefore := countHistoryForOrg(t, pool, orgA.ID)
		res, err := svc.SyncUlas(ctx, orgA.ID, actor.ID)
		if err != nil {
			t.Fatalf("senkron hatası: %v", err)
		}
		expectResult(t, res, 6, 0, 0, 6, 1)
		if n := countHistoryForOrg(t, pool, orgA.ID); n != historyBefore {
			t.Fatalf("değişiklik yokken fiyat geçmişi yazıldı: %d -> %d", historyBefore, n)
		}
	})

	t.Run("fiyat değişimi: güncellenir + fiyat geçmişi", func(t *testing.T) {
		list2 := append([]pricesource.Item(nil), list1...)
		list2[0] = ulasItem("Sandviç Panel Sac", "m2", "ÇATI MALZEMELERİ", "600")
		fake.set(nil, list2...)
		res, err := svc.SyncUlas(ctx, orgA.ID, actor.ID)
		if err != nil {
			t.Fatalf("senkron hatası: %v", err)
		}
		expectResult(t, res, 6, 0, 1, 5, 1)
		if h := loadHistory(t, pool, sandvicID); len(h) != 1 || h[0] != (historyEntry{"575.00", "690.00", domain.PriceHistoryNoteUlasSync}) {
			t.Fatalf("Sandviç fiyat geçmişi yanlış: %+v", h)
		}
		if pid := recipeProduct(); pid == nil || *pid != sandvicID {
			t.Fatalf("reçete kalemi ürüne bağlı kalmalı: %v", pid)
		}
	})

	t.Run("kâr oranı güncellemesi: kategori oranı + varsayılan, yeniden fiyatlama + geçmiş", func(t *testing.T) {
		res, err := svc.UpdatePriceSource(ctx, orgA.ID, domain.PriceSourceUlas, actor.ID, service.PriceSourceSettingsInput{
			MarkupPercent: decimal.RequireFromString("20"),
			AutoSync:      true,
			CategoryMarkups: []domain.PriceSourceCategoryMarkup{
				{Category: "  ALÇILAR ", MarkupPercent: decimal.RequireFromString("12.5")},
			},
		})
		if err != nil {
			t.Fatalf("güncelleme hatası: %v", err)
		}
		// Sandviç 600->720, Onduline x2 330->396, Dekor 38->45.60, OSB 240,
		// Yeni 12, Perlitli 333.33 @ %12.5 -> 375.00. Eski Ürün'ün kaynak
		// fiyatı yok -> dokunulmaz.
		if res.Recomputed != 7 {
			t.Fatalf("yeniden fiyatlanan = %d, beklenen 7", res.Recomputed)
		}
		ov := res.Overview
		if !ov.MarkupPercent.Equal(decimal.NewFromInt(20)) || !ov.AutoSync || len(ov.CategoryMarkups) != 1 ||
			ov.CategoryMarkups[0].Category != "ALÇILAR" || !ov.CategoryMarkups[0].MarkupPercent.Equal(decimal.RequireFromString("12.5")) {
			t.Fatalf("ayarlar yanlış: %+v", ov)
		}
		after := loadTestProducts(t, pool, orgA.ID)
		want := map[[2]string]string{
			{"Sandviç Panel Sac", "m2"}: "720.00", {"Onduline", "adet"}: "396.00", {"Dekor  Silteks Rulo", "adet"}: "45.60",
			{"OSB Levha", "adet"}: "240.00", {"Yeni Ürün", "adet"}: "12.00", {"Perlitli Alçı", "adet"}: "375.00",
			{"Eski Ürün", "adet"}: "100.00",
		}
		for k, price := range want {
			ps := findTestProducts(after, k[0], k[1], ulas)
			if len(ps) == 0 {
				t.Fatalf("%v bulunamadı", k)
			}
			for _, p := range ps {
				if p.UnitPrice != price {
					t.Errorf("%v birim fiyatı = %s, beklenen %s", k, p.UnitPrice, price)
				}
			}
		}
		perlitli := findTestProducts(after, "Perlitli Alçı", "adet", ulas)[0]
		if h := loadHistory(t, pool, perlitli.ID); len(h) != 1 || h[0] != (historyEntry{"383.33", "375.00", domain.PriceHistoryNoteUlasMarkup}) {
			t.Fatalf("Perlitli fiyat geçmişi yanlış: %+v", h)
		}
		if m := findTestProducts(after, "Perlitli Alçı", "adet", nil); len(m) != 1 || m[0].fingerprint() != manualBefore.fingerprint() {
			t.Fatalf("elle eklenen ürün yeniden fiyatlamada değişti: %+v", m)
		}
		var updatedBy *string
		if err := pool.QueryRow(ctx, `SELECT updated_by::text FROM organization_price_sources WHERE organization_id = $1 AND source = 'ulas'`, orgA.ID).Scan(&updatedBy); err != nil ||
			updatedBy == nil || *updatedBy != actor.ID {
			t.Fatalf("updated_by işlemi yapan kullanıcı olmalı: %v %v", updatedBy, err)
		}

		// Aynı oranlarla senkron, yeniden fiyatlamayla BİREBİR aynı fiyatı
		// üretmeli (iki yol da domain.ApplyMarkup) -> hepsi değişmedi.
		hist := countHistoryForOrg(t, pool, orgA.ID)
		sres, err := svc.SyncUlas(ctx, orgA.ID, actor.ID)
		if err != nil {
			t.Fatalf("senkron hatası: %v", err)
		}
		expectResult(t, sres, 6, 0, 0, 6, 1)
		if n := countHistoryForOrg(t, pool, orgA.ID); n != hist {
			t.Fatalf("senkron ile yeniden fiyatlama farklı fiyat üretti: geçmiş %d -> %d", hist, n)
		}

		// Kategori oranı kaldırılınca varsayılana döner.
		res, err = svc.UpdatePriceSource(ctx, orgA.ID, domain.PriceSourceUlas, actor.ID, service.PriceSourceSettingsInput{
			MarkupPercent: decimal.RequireFromString("20"), AutoSync: true,
		})
		if err != nil || res.Recomputed != 1 || len(res.Overview.CategoryMarkups) != 0 {
			t.Fatalf("kategori oranı kaldırılamadı: %+v %v", res, err)
		}
		if p := findTestProducts(loadTestProducts(t, pool, orgA.ID), "Perlitli Alçı", "adet", ulas)[0]; p.UnitPrice != "400.00" {
			t.Fatalf("varsayılan orana dönülmedi: %s", p.UnitPrice)
		}
	})

	t.Run("doğrulama hataları hiçbir şeyi değiştirmez", func(t *testing.T) {
		snapshot := loadTestProducts(t, pool, orgA.ID)
		ovBefore := onlyOverview(t, svc, orgA.ID)
		bad := []service.PriceSourceSettingsInput{
			{MarkupPercent: decimal.RequireFromString("-1")},
			{MarkupPercent: decimal.RequireFromString("1000.01")},
			{MarkupPercent: decimal.RequireFromString("12.345")},
			{MarkupPercent: decimal.NewFromInt(10), CategoryMarkups: []domain.PriceSourceCategoryMarkup{{Category: "  ", MarkupPercent: decimal.NewFromInt(5)}}},
			{MarkupPercent: decimal.NewFromInt(10), CategoryMarkups: []domain.PriceSourceCategoryMarkup{{Category: "A", MarkupPercent: decimal.NewFromInt(5)}, {Category: "A ", MarkupPercent: decimal.NewFromInt(6)}}},
			{MarkupPercent: decimal.NewFromInt(10), CategoryMarkups: []domain.PriceSourceCategoryMarkup{{Category: "A", MarkupPercent: decimal.NewFromInt(2000)}}},
			{MarkupPercent: decimal.NewFromInt(10), CategoryMarkups: []domain.PriceSourceCategoryMarkup{{Category: strings.Repeat("K", 101), MarkupPercent: decimal.NewFromInt(5)}}},
			// Aşırı üslü değerler (JSON'dan "1e-2000000000" gibi gelebilir):
			// karşılaştırma 10^|üs|'lük big.Int kurardı -- ANINDA reddedilmeli.
			{MarkupPercent: decimal.New(1, -2000000000)},
			{MarkupPercent: decimal.New(1, 2147483647)},
			{MarkupPercent: decimal.New(0, 2147483647)},
			{MarkupPercent: decimal.NewFromInt(10), CategoryMarkups: []domain.PriceSourceCategoryMarkup{{Category: "A", MarkupPercent: decimal.New(1, -2147483648)}}},
		}
		for i, in := range bad {
			start := time.Now()
			if _, err := svc.UpdatePriceSource(ctx, orgA.ID, domain.PriceSourceUlas, actor.ID, in); err == nil ||
				errors.Is(err, domain.ErrUnknownPriceSource) {
				t.Errorf("#%d: doğrulama hatası bekleniyordu, geldi %v", i, err)
			}
			if d := time.Since(start); d > time.Second {
				t.Errorf("#%d: doğrulama %s sürdü (aşırı üs aritmetikten önce reddedilmeli)", i, d)
			}
		}
		// Fazladan sıfırlı ama geçerli değer ("15.000") hâlâ kabul edilir.
		if _, err := svc.UpdatePriceSource(ctx, orgA.ID, domain.PriceSourceUlas, actor.ID, service.PriceSourceSettingsInput{
			MarkupPercent: decimal.RequireFromString(ovBefore.MarkupPercent.StringFixed(3)), AutoSync: ovBefore.AutoSync,
		}); err != nil {
			t.Fatalf("fazladan sıfırlı geçerli oran reddedildi: %v", err)
		}
		if _, err := svc.UpdatePriceSource(ctx, orgA.ID, "bilinmeyen", actor.ID, service.PriceSourceSettingsInput{MarkupPercent: decimal.NewFromInt(10)}); !errors.Is(err, domain.ErrUnknownPriceSource) {
			t.Fatalf("bilinmeyen kaynak ErrUnknownPriceSource dönmeli, geldi %v", err)
		}
		if after := loadTestProducts(t, pool, orgA.ID); !equalProducts(snapshot, after) {
			t.Fatal("reddedilen güncelleme ürünleri değiştirdi")
		}
		if ov := onlyOverview(t, svc, orgA.ID); !ov.MarkupPercent.Equal(ovBefore.MarkupPercent) || ov.AutoSync != ovBefore.AutoSync {
			t.Fatalf("reddedilen güncelleme ayarları değiştirdi: %+v", ov)
		}
	})

	t.Run("indirme hatası: failed kaydedilir, ürünler değişmez", func(t *testing.T) {
		snapshot := loadTestProducts(t, pool, orgA.ID)
		ovBefore := onlyOverview(t, svc, orgA.ID)

		fake.set(&pricesource.HTTPStatusError{StatusCode: 503})
		if _, err := svc.SyncUlas(ctx, orgA.ID, actor.ID); !errors.Is(err, domain.ErrPriceSourceFetch) {
			t.Fatalf("ErrPriceSourceFetch bekleniyordu, geldi %v", err)
		}
		ov := onlyOverview(t, svc, orgA.ID)
		if ov.LastStatus != domain.PriceSyncStatusFailed || ov.LastError != "Ulaş sunucusu HTTP 503 döndü" ||
			ov.LastSyncedAt == nil || !ov.LastSyncedAt.Equal(*ovBefore.LastSyncedAt) ||
			ov.LastResult.Total != ovBefore.LastResult.Total || ov.LastResult.Unchanged != ovBefore.LastResult.Unchanged {
			t.Fatalf("başarısız deneme yanlış kaydedildi: %+v", ov)
		}
		// Ağ hatasının iç ayrıntısı (çözümleyici/proxy adresi) last_error'a
		// (products.read ile herkese açık) SIZMAZ -- yalnızca sabit metin.
		fake.set(fmt.Errorf("Ulaş fiyat listesi indirilemedi: %w", &url.Error{Op: "Get", URL: pricesource.UlasURL, Err: &net.OpError{
			Op: "dial", Net: "tcp", Err: &net.DNSError{Err: "no such host", Name: "ulas.com.tr", Server: "10.0.0.2:53"},
		}}))
		if _, err := svc.SyncUlas(ctx, orgA.ID, actor.ID); !errors.Is(err, domain.ErrPriceSourceFetch) {
			t.Fatalf("ErrPriceSourceFetch bekleniyordu, geldi %v", err)
		}
		if ov := onlyOverview(t, svc, orgA.ID); ov.LastError != "Ulaş sunucusuna bağlanılamadı" || strings.Contains(ov.LastError, "10.0.0.2") {
			t.Fatalf("last_error sabit metin olmalı: %q", ov.LastError)
		}
		// Boş liste de hatadır ("her şey düştü" DEĞİL).
		fake.set(nil)
		if _, err := svc.SyncUlas(ctx, orgA.ID, actor.ID); !errors.Is(err, domain.ErrPriceSourceFetch) {
			t.Fatalf("boş liste ErrPriceSourceFetch dönmeli, geldi %v", err)
		}
		if after := loadTestProducts(t, pool, orgA.ID); !equalProducts(snapshot, after) {
			t.Fatal("başarısız senkron ürünleri değiştirdi")
		}
		// Sonraki başarılı senkron durumu temizler.
		fake.set(nil, list1...)
		if _, err := svc.SyncUlas(ctx, orgA.ID, actor.ID); err != nil {
			t.Fatalf("senkron hatası: %v", err)
		}
		if ov := onlyOverview(t, svc, orgA.ID); ov.LastStatus != domain.PriceSyncStatusSuccess || ov.LastError != "" {
			t.Fatalf("başarılı senkron hata durumunu temizlemeli: %+v", ov)
		}
	})

	t.Run("eşzamanlı senkron: kilit tutulurken ErrPriceSyncBusy", func(t *testing.T) {
		tx, err := pool.Begin(ctx)
		if err != nil {
			t.Fatalf("tx: %v", err)
		}
		defer tx.Rollback(ctx)
		class, key := service.PriceSyncAdvisoryLock(orgA.ID, domain.PriceSourceUlas)
		if _, err := tx.Exec(ctx, "SELECT pg_advisory_xact_lock($1, hashtext($2))", class, key); err != nil {
			t.Fatalf("kilit alınamadı: %v", err)
		}
		statusBefore := onlyOverview(t, svc, orgA.ID).LastStatus
		if _, err := svc.SyncUlas(ctx, orgA.ID, actor.ID); !errors.Is(err, domain.ErrPriceSyncBusy) {
			t.Fatalf("ErrPriceSyncBusy bekleniyordu, geldi %v", err)
		}
		if ov := onlyOverview(t, svc, orgA.ID); ov.LastStatus != statusBefore {
			t.Fatalf("meşgul durumu 'failed' diye kaydedilmemeli: %s", ov.LastStatus)
		}
		// Kilit başka firmayı etkilemez.
		fake.set(nil, ulasItem("B Ürünü", "adet", "X", "1"))
		if _, err := svc.SyncUlas(ctx, orgB.ID, ""); err != nil {
			t.Fatalf("başka firmanın senkronu kilitten etkilenmemeli: %v", err)
		}
		_ = tx.Rollback(ctx)
		fake.set(nil, list1...)
		if _, err := svc.SyncUlas(ctx, orgA.ID, actor.ID); err != nil {
			t.Fatalf("kilit bırakılınca senkron çalışmalı: %v", err)
		}
	})

	t.Run("firma izolasyonu: B'nin ürünleri ve ayarları etkilenmez", func(t *testing.T) {
		after := loadTestProducts(t, pool, orgB.ID)
		b := findTestProducts(after, "Sandviç Panel Sac", "m2", ulas)
		if len(b) != 1 || b[0].ID != orgBProductID || b[0].UnitPrice != "1.00" || b[0].fingerprint() != orgBBefore[0].fingerprint() {
			t.Fatalf("B'nin ürünü değişti: %+v", b)
		}
		ov := onlyOverview(t, svc, orgB.ID)
		if !ov.MarkupPercent.Equal(decimal.NewFromInt(15)) || ov.AutoSync || len(ov.CategoryMarkups) != 0 {
			t.Fatalf("A'nın ayarları B'ye sızdı: %+v", ov)
		}
		if ov.ProductCount != 2 || ov.MissingCount != 1 { // Sandviç (B'nin, listede yok) + "B Ürünü"
			t.Fatalf("B özeti yanlış: %+v", ov)
		}
	})
}

func equalProducts(a, b []testProduct) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i].fingerprint() != b[i].fingerprint() {
			return false
		}
	}
	return true
}

func TestPriceSourceNightly(t *testing.T) {
	dbURL := testDBURL(t)
	ctx := context.Background()
	pool, err := repository.NewPool(ctx, dbURL)
	if err != nil {
		t.Fatalf("veritabanına bağlanılamadı: %v", err)
	}
	t.Cleanup(func() { pool.Close() })
	q := sqlc.New(pool)
	orgSvc := service.NewOrganizationService(q)
	fake := &fakeUlas{}
	svc := service.NewPriceSourceService(pool, q, fake.fetch)

	active := mustCreateOrg(t, ctx, orgSvc, pool, "Gece Senkron Aktif", "gece-senkron-aktif")
	trial := mustCreateOrg(t, ctx, orgSvc, pool, "Gece Senkron Deneme", "gece-senkron-deneme")
	suspended := mustCreateOrg(t, ctx, orgSvc, pool, "Gece Senkron Askıda", "gece-senkron-askida")
	deleted := mustCreateOrg(t, ctx, orgSvc, pool, "Gece Senkron Silinmiş", "gece-senkron-silinmis")
	optedOut := mustCreateOrg(t, ctx, orgSvc, pool, "Gece Senkron Kapalı", "gece-senkron-kapali")
	service.SetNightlyOrgFilterForTest(svc, active.ID, trial.ID, suspended.ID, deleted.ID, optedOut.ID)

	for _, o := range []domain.Organization{active, trial, suspended, deleted, optedOut} {
		if _, err := svc.UpdatePriceSource(ctx, o.ID, domain.PriceSourceUlas, "", service.PriceSourceSettingsInput{
			MarkupPercent: decimal.NewFromInt(10), AutoSync: o.ID != optedOut.ID,
		}); err != nil {
			t.Fatalf("ayar kaydedilemedi: %v", err)
		}
	}
	for stmt, id := range map[string]string{
		"UPDATE organizations SET status = 'trial' WHERE id = $1":     trial.ID,
		"UPDATE organizations SET status = 'suspended' WHERE id = $1": suspended.ID,
		"UPDATE organizations SET deleted_at = now() WHERE id = $1":   deleted.ID,
	} {
		if _, err := pool.Exec(ctx, stmt, id); err != nil {
			t.Fatalf("firma durumu ayarlanamadı: %v", err)
		}
	}
	status := func(orgID string) string { return onlyOverview(t, svc, orgID).LastStatus }

	t.Run("başka instance kilidi tutuyorsa hiçbir şey yapılmaz", func(t *testing.T) {
		conn, err := pool.Acquire(ctx)
		if err != nil {
			t.Fatalf("bağlantı: %v", err)
		}
		defer conn.Release()
		if _, err := conn.Exec(ctx, "SELECT pg_advisory_lock(450046, 1)"); err != nil {
			t.Fatalf("kilit: %v", err)
		}
		defer conn.Exec(ctx, "SELECT pg_advisory_unlock(450046, 1)") //nolint:errcheck
		fake.set(nil, ulasItem("Gece Ürünü", "adet", "GECE", "100"))
		report, err := svc.SyncAutoOrganizations(ctx, time.Now())
		if err != nil || !report.SkippedLocked || fake.callCount() != 0 {
			t.Fatalf("kilitliyken atlanmalı: %+v %v (fetch %d)", report, err, fake.callCount())
		}
	})

	t.Run("uygun firmalar için liste BİR KEZ indirilir ve uygulanır", func(t *testing.T) {
		fake.set(nil, ulasItem("Gece Ürünü", "adet", "GECE", "100"))
		report, err := svc.SyncAutoOrganizations(ctx, time.Now())
		if err != nil {
			t.Fatalf("gece işi hatası: %v", err)
		}
		if report.SkippedLocked || report.Organizations != 2 || report.Succeeded != 2 || report.Failed != 0 || fake.callCount() != 1 {
			t.Fatalf("rapor yanlış: %+v (fetch %d)", report, fake.callCount())
		}
		for _, o := range []domain.Organization{active, trial} {
			ps := findTestProducts(loadTestProducts(t, pool, o.ID), "Gece Ürünü", "adet", strPtr(domain.PriceSourceUlas))
			if len(ps) != 1 || ps[0].UnitPrice != "110.00" || status(o.ID) != domain.PriceSyncStatusSuccess {
				t.Fatalf("%s senkronlanmalıydı: %+v", o.Slug, ps)
			}
			var actorNull bool
			if err := pool.QueryRow(ctx, `SELECT user_id IS NULL FROM organization_events
				WHERE organization_id = $1 AND event_type = $2 ORDER BY created_at DESC LIMIT 1`,
				o.ID, domain.OrgEventPriceSourceSynced).Scan(&actorNull); err != nil || !actorNull {
				t.Fatalf("gece senkronunun işlem yapanı NULL olmalı: %v %v", actorNull, err)
			}
		}
		for _, o := range []domain.Organization{suspended, deleted, optedOut} {
			if n := len(loadTestProducts(t, pool, o.ID)); n != 0 || status(o.ID) != domain.PriceSyncStatusNever {
				t.Fatalf("%s senkronlanmamalıydı (ürün %d, durum %s)", o.Slug, n, status(o.ID))
			}
		}
	})

	t.Run("aynı gece tekrar çalışırsa (ikinci instance) zaten senkronlananlar atlanır", func(t *testing.T) {
		report, err := svc.SyncAutoOrganizations(ctx, time.Now().Add(-time.Hour))
		if err != nil || report.Organizations != 0 || fake.callCount() != 1 {
			t.Fatalf("zaten senkronlanan firmalar atlanmalı, indirme yapılmamalı: %+v %v (fetch %d)", report, err, fake.callCount())
		}
	})

	t.Run("indirme hatası tüm uygun firmalara failed olarak yazılır", func(t *testing.T) {
		fake.set(fmt.Errorf("Ulaş fiyat listesi indirilemedi: %w", &url.Error{Op: "Get", URL: pricesource.UlasURL, Err: context.DeadlineExceeded}))
		report, err := svc.SyncAutoOrganizations(ctx, time.Now().Add(time.Minute))
		if err != nil || report.Failed != 2 || report.Succeeded != 0 {
			t.Fatalf("rapor yanlış: %+v %v", report, err)
		}
		for _, o := range []domain.Organization{active, trial} {
			ov := onlyOverview(t, svc, o.ID)
			if ov.LastStatus != domain.PriceSyncStatusFailed || ov.LastError != "Ulaş sunucusu zamanında yanıt vermedi (zaman aşımı)" {
				t.Fatalf("%s failed olmalı: %+v", o.Slug, ov)
			}
			if ps := findTestProducts(loadTestProducts(t, pool, o.ID), "Gece Ürünü", "adet", strPtr(domain.PriceSourceUlas)); len(ps) != 1 || ps[0].UnitPrice != "110.00" {
				t.Fatalf("başarısız gece işi ürünleri değiştirmemeli: %+v", ps)
			}
		}
	})

	t.Run("iptal edilen context ile zamanlayıcı döner", func(t *testing.T) {
		cctx, cancel := context.WithCancel(ctx)
		done := make(chan struct{})
		go func() {
			svc.RunNightly(cctx)
			close(done)
		}()
		cancel()
		select {
		case <-done:
		case <-time.After(5 * time.Second):
			t.Fatal("RunNightly iptalden sonra dönmedi")
		}
	})
}

// TestPriceSourceSyncSameNameInSeveralCategories: Ulaş aynı ad+birimi
// birden çok kategoride listeler -- çoğu aynı ürün (aynı fiyat), ama bazen
// FARKLI ürün ("Gazbeton Yapıştırıcısı" torba: FİXA 130 TL, GAZBETON
// MALZEMELERİ 120 TL). Satır kendi kategorisindeki ürüne eşleşir: fiyatı
// başkasınınkiyle ezilmez, kategori oranı doğru uygulanır, kategori
// sayıları doğrudur; kategori yeniden adlandırılınca da id korunur.
func TestPriceSourceSyncSameNameInSeveralCategories(t *testing.T) {
	dbURL := testDBURL(t)
	ctx := context.Background()
	pool, err := repository.NewPool(ctx, dbURL)
	if err != nil {
		t.Fatalf("veritabanına bağlanılamadı: %v", err)
	}
	t.Cleanup(func() { pool.Close() })
	q := sqlc.New(pool)
	fake := &fakeUlas{}
	svc := service.NewPriceSourceService(pool, q, fake.fetch)
	org := mustCreateOrg(t, ctx, service.NewOrganizationService(q), pool, "Fiyat Kaynağı Çok Kategori", "fiyat-kaynagi-cok-kategori")
	ulas := strPtr(domain.PriceSourceUlas)

	const (
		fixa     = "FİXA YAPI KİMYASALLARI"
		gazbeton = "GAZBETON MALZEMELERİ"
		fugali   = "FUGALı DıŞ CEPHE KAPLAMA"
		hazir    = "HAZIR FUGALI KAPLAMALAR"
		cati     = "ÇATI MALZEMELERİ"
		yeni     = "YENİ KATEGORİ"
	)
	// BYZ'den aktarılmış gibi: kategori boş, Ulaş kategorisi açıklamada.
	gzFixa := insertTestProduct(t, pool, org.ID, "Gazbeton Yapıştırıcısı", "torba", "149.50", ulas, fixa)
	gzGaz := insertTestProduct(t, pool, org.ID, "Gazbeton Yapıştırıcısı", "torba", "138.00", ulas, gazbeton)
	dkFug := insertTestProduct(t, pool, org.ID, "DK 110", "m2", "402.50", ulas, fugali)
	dkHaz := insertTestProduct(t, pool, org.ID, "DK 110", "m2", "402.50", ulas, hazir)
	// Listede TEK kategoride geçen ad+birim: açıklama tutmasa da eşleşir.
	ond := insertTestProduct(t, pool, org.ID, "Onduline", "adet", "379.50", ulas, "ESKİ KATEGORİ ADI")

	if _, err := svc.UpdatePriceSource(ctx, org.ID, domain.PriceSourceUlas, "", service.PriceSourceSettingsInput{
		MarkupPercent:   decimal.NewFromInt(15),
		CategoryMarkups: []domain.PriceSourceCategoryMarkup{{Category: hazir, MarkupPercent: decimal.NewFromInt(10)}},
	}); err != nil {
		t.Fatalf("ayar kaydedilemedi: %v", err)
	}

	type want struct{ unitPrice, sourcePrice, category string }
	check := func(t *testing.T, id string, w want) {
		t.Helper()
		for _, p := range loadTestProducts(t, pool, org.ID) {
			if p.ID != id {
				continue
			}
			if p.UnitPrice != w.unitPrice || p.SourcePrice == nil || *p.SourcePrice != w.sourcePrice || p.Category != w.category {
				t.Fatalf("%s %s: birim %s kaynak %v kategori %q; beklenen %+v", p.Name, id, p.UnitPrice, p.SourcePrice, p.Category, w)
			}
			return
		}
		t.Fatalf("ürün %s bulunamadı (silinmemeliydi)", id)
	}

	list := []pricesource.Item{
		ulasItem("Gazbeton Yapıştırıcısı", "torba", fixa, "130"),
		ulasItem("Gazbeton Yapıştırıcısı", "torba", gazbeton, "120"),
		ulasItem("DK 110", "m2", hazir, "350"),
		ulasItem("Onduline", "adet", cati, "330"),
		ulasItem("DK 110", "m2", fugali, "350"),
		ulasItem("Gazbeton Yapıştırıcısı", "torba", yeni, "125"),
	}

	t.Run("ilk senkron: satırlar açıklamadaki kategoriye göre eşleşir", func(t *testing.T) {
		fake.set(nil, list...)
		res, err := svc.SyncUlas(ctx, org.ID, "")
		if err != nil {
			t.Fatalf("senkron hatası: %v", err)
		}
		expectResult(t, res, 6, 1, 5, 0, 0)
		check(t, gzFixa, want{"149.50", "130.00", fixa})
		// 120 TL'lik ürün 130 TL'likle EZİLMEZ.
		check(t, gzGaz, want{"138.00", "120.00", gazbeton})
		// Kategori oranı (%10) ikinci kategorideki satıra uygulanır.
		check(t, dkHaz, want{"385.00", "350.00", hazir})
		check(t, dkFug, want{"402.50", "350.00", fugali})
		check(t, ond, want{"379.50", "330.00", cati})
		for _, id := range []string{gzFixa, gzGaz, dkFug, ond} {
			if h := loadHistory(t, pool, id); len(h) != 0 {
				t.Fatalf("%s fiyatı değişmedi, geçmiş yazılmamalı: %+v", id, h)
			}
		}
		if h := loadHistory(t, pool, dkHaz); len(h) != 1 || h[0] != (historyEntry{"402.50", "385.00", domain.PriceHistoryNoteUlasSync}) {
			t.Fatalf("DK 110 (%s) fiyat geçmişi yanlış: %+v", hazir, h)
		}
		created := findTestProducts(loadTestProducts(t, pool, org.ID), "Gazbeton Yapıştırıcısı", "torba", ulas)
		if len(created) != 3 {
			t.Fatalf("üçüncü kategorideki aynı adlı ürün ayrı satır olarak eklenmeli: %+v", created)
		}
		ov := onlyOverview(t, svc, org.ID)
		gotCats := map[string]int{}
		for _, c := range ov.Categories {
			gotCats[c.Category] = c.ProductCount
		}
		for _, c := range []string{fixa, gazbeton, fugali, hazir, cati, yeni} {
			if gotCats[c] != 1 {
				t.Fatalf("her kategoride 1 ürün olmalı: %v", gotCats)
			}
		}
	})

	t.Run("tekrar senkron: hepsi değişmedi (artık products.category ile eşleşir)", func(t *testing.T) {
		res, err := svc.SyncUlas(ctx, org.ID, "")
		if err != nil {
			t.Fatalf("senkron hatası: %v", err)
		}
		expectResult(t, res, 6, 0, 0, 6, 0)
	})

	t.Run("Ulaş kategoriyi yeniden adlandırırsa satır (id) korunur", func(t *testing.T) {
		renamed := append([]pricesource.Item(nil), list...)
		renamed[4] = ulasItem("DK 110", "m2", "FUGALI DIŞ CEPHE KAPLAMA", "350")
		fake.set(nil, renamed...)
		res, err := svc.SyncUlas(ctx, org.ID, "")
		if err != nil {
			t.Fatalf("senkron hatası: %v", err)
		}
		expectResult(t, res, 6, 0, 1, 5, 0)
		check(t, dkFug, want{"402.50", "350.00", "FUGALI DIŞ CEPHE KAPLAMA"})
		check(t, dkHaz, want{"385.00", "350.00", hazir})
		if n := len(loadTestProducts(t, pool, org.ID)); n != 6 {
			t.Fatalf("yeni kopya oluşturulmamalı: %d ürün", n)
		}
	})
}

// TestPriceSourceRowLockDoesNotBlockForeignKeys: senkronun/yeniden
// fiyatlamanın satır kilidi (ListSourceProductsForUpdate) FOR NO KEY
// UPDATE'tir -- teklif/reçete kalemi eklerken FK kontrolünün aldığı FOR KEY
// SHARE'i BEKLETMEZ (FOR UPDATE bekletir, farklı sırayla kilitleyen bir
// teklif kaydıyla da deadlock'a yol açardı). Ürünün kendisini değiştirmek
// ise yine senkronu bekler.
func TestPriceSourceRowLockDoesNotBlockForeignKeys(t *testing.T) {
	dbURL := testDBURL(t)
	ctx := context.Background()
	pool, err := repository.NewPool(ctx, dbURL)
	if err != nil {
		t.Fatalf("veritabanına bağlanılamadı: %v", err)
	}
	t.Cleanup(func() { pool.Close() })
	q := sqlc.New(pool)
	org := mustCreateOrg(t, ctx, service.NewOrganizationService(q), pool, "Fiyat Kaynağı Kilit", "fiyat-kaynagi-kilit")
	productID := insertTestProduct(t, pool, org.ID, "Kilit Ürünü", "adet", "10.00", strPtr(domain.PriceSourceUlas), "")
	orgUUID, err := repository.StringToUUID(org.ID)
	if err != nil {
		t.Fatalf("uuid: %v", err)
	}

	syncTx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatalf("tx: %v", err)
	}
	defer syncTx.Rollback(ctx) //nolint:errcheck
	rows, err := q.WithTx(syncTx).ListSourceProductsForUpdate(ctx, sqlc.ListSourceProductsForUpdateParams{OrganizationID: orgUUID, Source: domain.PriceSourceUlas})
	if err != nil || len(rows) != 1 {
		t.Fatalf("senkron kilidi alınamadı: %d %v", len(rows), err)
	}

	other, err := pool.Begin(ctx)
	if err != nil {
		t.Fatalf("tx: %v", err)
	}
	defer other.Rollback(ctx) //nolint:errcheck
	if _, err := other.Exec(ctx, "SET LOCAL lock_timeout = '2s'"); err != nil {
		t.Fatalf("lock_timeout: %v", err)
	}
	// Gerçek bir FK eklemesi (metraj reçete kalemi -> ürün).
	if _, err := other.Exec(ctx, `
		WITH g AS (
			INSERT INTO calc_groups (organization_id, slug, name) VALUES ($1, 'kilit-test-grup', 'Kilit Test') RETURNING id
		), c AS (
			INSERT INTO calc_categories (organization_id, group_id, slug, name)
			SELECT $1, g.id, 'kilit-test-kategori', 'Kilit Test Kategori' FROM g RETURNING id
		)
		INSERT INTO calc_recipe_items (organization_id, category_id, product_id, material_name, unit, calculation_type, quantity_per_m2)
		SELECT $1, c.id, $2, 'Kilit Ürünü', 'adet', 'area_based', 1 FROM c`, org.ID, productID); err != nil {
		t.Fatalf("senkron sürerken ürüne bağlı kalem eklenemedi (FOR UPDATE mi kaldı?): %v", err)
	}
	// Ürünü değiştirmek ise senkronla sıralanır.
	if _, err := other.Exec(ctx, "SAVEPOINT guncelleme"); err != nil {
		t.Fatalf("savepoint: %v", err)
	}
	if _, err := other.Exec(ctx, "SET LOCAL lock_timeout = '200ms'"); err != nil {
		t.Fatalf("lock_timeout: %v", err)
	}
	if _, err := other.Exec(ctx, "UPDATE products SET unit_price = 11 WHERE id = $1", productID); err == nil ||
		!strings.Contains(err.Error(), "55P03") {
		t.Fatalf("senkron sürerken ürün güncellemesi beklemeliydi (lock timeout), geldi %v", err)
	}
}
