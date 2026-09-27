package service_test

// İkinci kaynak (Demir Profil) ve kaynaklar arası ortak kurallar gerçek
// veritabanına karşı: oluşturma/güncelleme/değişmeyen/eksik, liste dönemi,
// yeni ürün açıklaması, kaynaklar arası izolasyon (aynı ad Ulaş'ta ve
// Demir Profil'de ASLA eşleşmez), fiyat geçmişinin reason/source/kaynak
// fiyatları, kısa liste eşiği, iki kaynaklı gece işi. Listeler sahte
// fetcher'lardan gelir -- testler tedarikçi sitelerine ASLA gitmez.

import (
	"context"
	"errors"
	"fmt"
	"strings"
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

func sourceItem(name, unit, category, price, desc string) pricesource.Item {
	return pricesource.Item{Name: name, Unit: unit, Category: category, Price: decimal.RequireFromString(price), Description: desc}
}

// historyRow, fiyat geçmişinin 0046 kolonlarıyla ham hâli.
type historyRow struct {
	Old, New, Note, Reason string
	Source                 *string
	OldSource, NewSource   *string
	ChangedAt              time.Time
}

func loadHistoryRows(t *testing.T, pool *pgxpool.Pool, productID string) []historyRow {
	t.Helper()
	rows, err := pool.Query(context.Background(), `
		SELECT old_price::text, new_price::text, note, reason, source, old_source_price::text, new_source_price::text, changed_at
		FROM product_price_history WHERE product_id = $1 ORDER BY changed_at, id`, productID)
	if err != nil {
		t.Fatalf("fiyat geçmişi okunamadı: %v", err)
	}
	defer rows.Close()
	var out []historyRow
	for rows.Next() {
		var h historyRow
		if err := rows.Scan(&h.Old, &h.New, &h.Note, &h.Reason, &h.Source, &h.OldSource, &h.NewSource, &h.ChangedAt); err != nil {
			t.Fatalf("fiyat geçmişi satırı okunamadı: %v", err)
		}
		out = append(out, h)
	}
	return out
}

func str(p *string) string {
	if p == nil {
		return "<nil>"
	}
	return *p
}

// expectHistory, bir geçmiş satırının (eski, yeni, reason, source, eski/yeni
// kaynak fiyatı) değerlerini doğrular.
func expectHistory(t *testing.T, h historyRow, old, cur, reason, source, oldSrc, newSrc string) {
	t.Helper()
	if h.Old != old || h.New != cur || h.Reason != reason || str(h.Source) != source || str(h.OldSource) != oldSrc || str(h.NewSource) != newSrc {
		t.Fatalf("geçmiş satırı = {%s -> %s, %s, %s, kaynak %s -> %s}, beklenen {%s -> %s, %s, %s, kaynak %s -> %s}",
			h.Old, h.New, h.Reason, str(h.Source), str(h.OldSource), str(h.NewSource), old, cur, reason, source, oldSrc, newSrc)
	}
}

func onlyProduct(t *testing.T, ps []testProduct, name, unit string, source *string) testProduct {
	t.Helper()
	found := findTestProducts(ps, name, unit, source)
	if len(found) != 1 {
		t.Fatalf("%q/%q/%s: tek ürün bekleniyordu, %d bulundu", name, unit, str(source), len(found))
	}
	return found[0]
}

func productDescription(t *testing.T, pool *pgxpool.Pool, id string) string {
	t.Helper()
	var d string
	if err := pool.QueryRow(context.Background(), `SELECT description FROM products WHERE id = $1`, id).Scan(&d); err != nil {
		t.Fatalf("açıklama okunamadı: %v", err)
	}
	return d
}

func TestDemirProfilSync(t *testing.T) {
	dbURL := testDBURL(t)
	ctx := context.Background()
	pool, err := repository.NewPool(ctx, dbURL)
	if err != nil {
		t.Fatalf("veritabanına bağlanılamadı: %v", err)
	}
	t.Cleanup(func() { pool.Close() })
	q := sqlc.New(pool)
	ulasFake, demirFake := &fakeSource{}, &fakeSource{}
	svc := service.NewPriceSourceService(pool, q, map[string]service.PriceFetcher{
		domain.PriceSourceUlas: ulasFake.fetch, domain.PriceSourceDemirProfil: demirFake.fetch,
	})
	org := mustCreateOrg(t, ctx, service.NewOrganizationService(q), pool, "Demir Profil Senkron", "demir-profil-senkron")
	ulas, demir := strPtr(domain.PriceSourceUlas), strPtr(domain.PriceSourceDemirProfil)

	const (
		kutu     = "Siyah Kutu Profil"
		k1       = "Siyah Kutu Profil 20×20×1,2 mm"
		k2       = "Siyah Kutu Profil 20×80×2,5 mm"
		galvaniz = "Galvaniz Sac"
		s1       = "0,30mm Galvaniz sac"
	)
	// Aynı ad+birim+kategori: elle eklenmiş ve Ulaş'tan gelmiş satırlar.
	// Demir Profil senkronu İKİSİNE de ASLA dokunmamalı.
	manualID := insertTestProduct(t, pool, org.ID, k1, "mt", "99.00", nil, "elle")
	ulasID := insertTestProduct(t, pool, org.ID, k1, "mt", "10.00", ulas, "")
	if _, err := pool.Exec(ctx, `UPDATE products SET category = $2, source_price = 10, source_synced_at = now() WHERE id = $1`, ulasID, kutu); err != nil {
		t.Fatalf("ulas satırı hazırlanamadı: %v", err)
	}
	before := loadTestProducts(t, pool, org.ID)
	manualBefore := onlyProduct(t, before, k1, "mt", nil)
	ulasBefore := onlyProduct(t, before, k1, "mt", ulas)

	demirFake.setLabel("Eylül 2026")
	demirFake.set(nil,
		sourceItem(k1, "mt", kutu, "28.80", "6 m boy · 0,700 kg/m"),
		sourceItem(k2, "mt", kutu, "173.60", "6 m boy · 3,925 kg/m"),
		sourceItem(s1, "kg", galvaniz, "51.08", "2,36 kg/m²"),
		sourceItem("Eski Profil", "kg", "H profil", "34.30", ""),
	)

	t.Run("ilk senkron: yeni ürünler açıklama ve dönemle oluşur, başka kaynaklara dokunulmaz", func(t *testing.T) {
		res, err := svc.Sync(ctx, org.ID, domain.PriceSourceDemirProfil, "")
		if err != nil {
			t.Fatalf("senkron hatası: %v", err)
		}
		expectResult(t, res, 4, 4, 0, 0, 0)
		if res.ListLabel != "Eylül 2026" {
			t.Fatalf("sonuç dönemi = %q", res.ListLabel)
		}
		after := loadTestProducts(t, pool, org.ID)
		k := onlyProduct(t, after, k1, "mt", demir)
		if k.UnitPrice != "33.12" || str(k.SourcePrice) != "28.80" || k.Category != kutu || k.SyncedAt == nil {
			t.Fatalf("Demir Profil ürünü yanlış: %+v", k)
		}
		if d := productDescription(t, pool, k.ID); d != "6 m boy · 0,700 kg/m" {
			t.Fatalf("yeni ürünün açıklaması = %q", d)
		}
		if m := onlyProduct(t, after, k1, "mt", nil); m.ID != manualID || m.fingerprint() != manualBefore.fingerprint() {
			t.Fatalf("elle eklenen aynı adlı ürün değişti: %+v", m)
		}
		if u := onlyProduct(t, after, k1, "mt", ulas); u.ID != ulasID || u.fingerprint() != ulasBefore.fingerprint() {
			t.Fatalf("Ulaş'tan gelen aynı adlı ürün değişti: %+v", u)
		}

		ov := sourceOverview(t, svc, org.ID, domain.PriceSourceDemirProfil)
		if ov.LastStatus != domain.PriceSyncStatusSuccess || ov.ListLabel != "Eylül 2026" || ov.ProductCount != 4 || ov.MissingCount != 0 {
			t.Fatalf("Demir Profil özeti yanlış: %+v", ov)
		}
		if ov.LastChanges == nil || ov.LastChanges.Increased != 0 || ov.LastChanges.Decreased != 0 || ov.LastChanges.AvgIncreasePercent != nil {
			t.Fatalf("ilk senkronda fiyat değişimi yok: %+v", ov.LastChanges)
		}
		// Ulaş özeti Demir Profil ürünlerini saymaz.
		if u := ulasOverview(t, svc, org.ID); u.ProductCount != 1 || u.LastStatus != domain.PriceSyncStatusNever || u.LastChanges != nil {
			t.Fatalf("Ulaş özeti yanlış: %+v", u)
		}
		var label *string
		if err := pool.QueryRow(ctx, `SELECT metadata->>'list_label' FROM organization_events
			WHERE organization_id = $1 AND event_type = $2 ORDER BY created_at DESC LIMIT 1`,
			org.ID, domain.OrgEventPriceSourceSynced).Scan(&label); err != nil || str(label) != "Eylül 2026" {
			t.Fatalf("olay kaydında dönem yok: %v %v", str(label), err)
		}
	})

	t.Run("ikinci senkron: güncellenen/değişmeyen/eksik + tedarikçi geçmişi", func(t *testing.T) {
		demirFake.setLabel("Ekim 2026")
		demirFake.set(nil,
			sourceItem(k1, "mt", kutu, "30.00", "açıklama değişti"),
			sourceItem(k2, "mt", kutu, "173.60", ""),
			sourceItem(s1, "kg", galvaniz, "50.00", ""),
			sourceItem("100 H Profil", "kg", "H profil", "34.30", ""),
		)
		res, err := svc.Sync(ctx, org.ID, domain.PriceSourceDemirProfil, "")
		if err != nil {
			t.Fatalf("senkron hatası: %v", err)
		}
		expectResult(t, res, 4, 1, 2, 1, 1)
		after := loadTestProducts(t, pool, org.ID)
		k := onlyProduct(t, after, k1, "mt", demir)
		h := loadHistoryRows(t, pool, k.ID)
		if len(h) != 1 {
			t.Fatalf("tek geçmiş satırı bekleniyordu: %+v", h)
		}
		expectHistory(t, h[0], "33.12", "34.50", domain.PriceChangeReasonSupplier, domain.PriceSourceDemirProfil, "28.80", "30.00")
		if h[0].Note != "Demir Profil fiyat listesi (Ekim 2026)" {
			t.Fatalf("not = %q", h[0].Note)
		}
		// Açıklama kullanıcıya aittir: senkron değiştirmez.
		if d := productDescription(t, pool, k.ID); d != "6 m boy · 0,700 kg/m" {
			t.Fatalf("eşleşen ürünün açıklaması korunmalı: %q", d)
		}
		s := onlyProduct(t, after, s1, "kg", demir)
		if hs := loadHistoryRows(t, pool, s.ID); len(hs) != 1 {
			t.Fatalf("indirim geçmişi bekleniyordu: %+v", hs)
		} else {
			expectHistory(t, hs[0], "58.74", "57.50", domain.PriceChangeReasonSupplier, domain.PriceSourceDemirProfil, "51.08", "50.00")
		}
		if e := onlyProduct(t, after, "Eski Profil", "kg", demir); e.UnitPrice != "39.45" {
			t.Fatalf("listeden düşen ürün silinmemeli/değişmemeli: %+v", e)
		}
		if u := onlyProduct(t, after, k1, "mt", ulas); u.fingerprint() != ulasBefore.fingerprint() {
			t.Fatalf("Ulaş ürünü Demir Profil senkronundan etkilendi: %+v", u)
		}

		ov := sourceOverview(t, svc, org.ID, domain.PriceSourceDemirProfil)
		if ov.ListLabel != "Ekim 2026" || ov.MissingCount != 1 || ov.LastResult.Missing != 1 {
			t.Fatalf("özet yanlış: %+v", ov)
		}
		// 33.12 -> 34.50 = %4.1666 -> 4.17; 58.74 -> 57.50 indirim.
		if lc := ov.LastChanges; lc == nil || lc.Increased != 1 || lc.Decreased != 1 || lc.AvgIncreasePercent == nil ||
			!lc.AvgIncreasePercent.Equal(decimal.RequireFromString("4.17")) {
			t.Fatalf("son senkron değişimleri yanlış: %+v", lc)
		}
	})

	t.Run("aynı liste: hepsi değişmedi, geçmiş yazılmaz", func(t *testing.T) {
		hist := countHistoryForOrg(t, pool, org.ID)
		res, err := svc.Sync(ctx, org.ID, domain.PriceSourceDemirProfil, "")
		if err != nil {
			t.Fatalf("senkron hatası: %v", err)
		}
		expectResult(t, res, 4, 0, 0, 4, 1)
		if n := countHistoryForOrg(t, pool, org.ID); n != hist {
			t.Fatalf("değişiklik yokken geçmiş yazıldı: %d -> %d", hist, n)
		}
		if lc := sourceOverview(t, svc, org.ID, domain.PriceSourceDemirProfil).LastChanges; lc == nil || lc.Increased != 0 || lc.Decreased != 0 {
			t.Fatalf("son senkronda değişim yoktu: %+v", lc)
		}
	})

	t.Run("kâr oranı: yalnızca o kaynağın ürünleri, reason markup, kaynak fiyatı eşit", func(t *testing.T) {
		res, err := svc.UpdatePriceSource(ctx, org.ID, domain.PriceSourceDemirProfil, "", service.PriceSourceSettingsInput{
			MarkupPercent:   decimal.NewFromInt(20),
			CategoryMarkups: []domain.PriceSourceCategoryMarkup{{Category: galvaniz, MarkupPercent: decimal.NewFromInt(10)}},
		})
		if err != nil {
			t.Fatalf("güncelleme hatası: %v", err)
		}
		// k1 34.50->36.00, k2 199.64->208.32, s1 57.50->55.00, H 39.45->41.16, Eski 39.45->41.16.
		if res.Recomputed != 5 {
			t.Fatalf("yeniden fiyatlanan = %d, beklenen 5", res.Recomputed)
		}
		after := loadTestProducts(t, pool, org.ID)
		k := onlyProduct(t, after, k1, "mt", demir)
		h := loadHistoryRows(t, pool, k.ID)
		expectHistory(t, h[len(h)-1], "34.50", "36.00", domain.PriceChangeReasonMarkup, domain.PriceSourceDemirProfil, "30.00", "30.00")
		if h[len(h)-1].Note != "Demir Profil kâr oranı güncellendi" {
			t.Fatalf("not = %q", h[len(h)-1].Note)
		}
		s := onlyProduct(t, after, s1, "kg", demir)
		if s.UnitPrice != "55.00" {
			t.Fatalf("kategori oranı uygulanmadı: %s", s.UnitPrice)
		}
		if u := onlyProduct(t, after, k1, "mt", ulas); u.fingerprint() != ulasBefore.fingerprint() {
			t.Fatalf("Demir Profil kâr oranı Ulaş ürününü değiştirdi: %+v", u)
		}
		if u := ulasOverview(t, svc, org.ID); !u.MarkupPercent.Equal(decimal.NewFromInt(15)) || len(u.CategoryMarkups) != 0 {
			t.Fatalf("Demir Profil ayarı Ulaş'a sızdı: %+v", u)
		}
	})

	t.Run("Ulaş senkronu aynı adlı Demir Profil ürününe dokunmaz", func(t *testing.T) {
		demirBefore := onlyProduct(t, loadTestProducts(t, pool, org.ID), k1, "mt", demir)
		ulasFake.set(nil, sourceItem(k1, "mt", kutu, "12", ""))
		res, err := svc.Sync(ctx, org.ID, domain.PriceSourceUlas, "")
		if err != nil {
			t.Fatalf("senkron hatası: %v", err)
		}
		expectResult(t, res, 1, 0, 1, 0, 0)
		after := loadTestProducts(t, pool, org.ID)
		if u := onlyProduct(t, after, k1, "mt", ulas); u.ID != ulasID || u.UnitPrice != "13.80" {
			t.Fatalf("Ulaş satırı güncellenmeliydi: %+v", u)
		}
		if d := onlyProduct(t, after, k1, "mt", demir); d.fingerprint() != demirBefore.fingerprint() {
			t.Fatalf("Ulaş senkronu Demir Profil ürününü değiştirdi: %+v", d)
		}
		if m := onlyProduct(t, after, k1, "mt", nil); m.fingerprint() != manualBefore.fingerprint() {
			t.Fatalf("elle eklenen ürün değişti: %+v", m)
		}
		uh := loadHistoryRows(t, pool, ulasID)
		expectHistory(t, uh[len(uh)-1], "10.00", "13.80", domain.PriceChangeReasonSupplier, domain.PriceSourceUlas, "10.00", "12.00")
		if uh[len(uh)-1].Note != domain.PriceHistoryNoteUlasSync {
			t.Fatalf("Ulaş notu dönem almamalı: %q", uh[len(uh)-1].Note)
		}
		// Demir Profil'in eksik sayısı Ulaş senkronundan etkilenmez.
		if ov := sourceOverview(t, svc, org.ID, domain.PriceSourceDemirProfil); ov.MissingCount != 1 {
			t.Fatalf("Demir Profil eksik sayısı değişti: %+v", ov)
		}
	})

	t.Run("elle düzenleme: reason manual, kaynak yok", func(t *testing.T) {
		productSvc := service.NewProductService(q)
		if _, err := productSvc.Update(ctx, manualID, org.ID, k1, "mt", 90, "elle", ""); err != nil {
			t.Fatalf("ürün güncellenemedi: %v", err)
		}
		h := loadHistoryRows(t, pool, manualID)
		if len(h) != 1 {
			t.Fatalf("tek geçmiş satırı bekleniyordu: %+v", h)
		}
		expectHistory(t, h[0], "99.00", "90.00", domain.PriceChangeReasonManual, "<nil>", "<nil>", "<nil>")
		entries, err := productSvc.PriceHistory(ctx, manualID, org.ID)
		if err != nil || len(entries) != 1 || entries[0].Reason != domain.PriceChangeReasonManual || entries[0].Source != "" || entries[0].OldSourcePrice != nil {
			t.Fatalf("ürün fiyat geçmişi yanlış: %+v %v", entries, err)
		}
	})

	t.Run("senkron elle düzenlemeyi geri alırsa tedarikçi zammı sayılmaz", func(t *testing.T) {
		productSvc := service.NewProductService(q)
		k := onlyProduct(t, loadTestProducts(t, pool, org.ID), k1, "mt", demir)
		if k.UnitPrice != "36.00" || str(k.SourcePrice) != "30.00" {
			t.Fatalf("başlangıç durumu beklenmedik: %+v", k)
		}
		if _, err := productSvc.Update(ctx, k.ID, org.ID, k.Name, k.Unit, 20, productDescription(t, pool, k.ID), k.Category); err != nil {
			t.Fatalf("elle düzenleme: %v", err)
		}
		// Liste aynı (k1 tedarikçi fiyatı 30.00): senkron fiyatı kâr oranıyla
		// 36.00'ya geri çeker -- bu tedarikçi zammı DEĞİLDİR.
		res, err := svc.Sync(ctx, org.ID, domain.PriceSourceDemirProfil, "")
		if err != nil {
			t.Fatalf("senkron hatası: %v", err)
		}
		expectResult(t, res, 4, 0, 1, 3, 1)
		h := loadHistoryRows(t, pool, k.ID)
		last := h[len(h)-1]
		expectHistory(t, last, "20.00", "36.00", domain.PriceChangeReasonMarkup, domain.PriceSourceDemirProfil, "30.00", "30.00")
		dp, _ := domain.LookupPriceSource(domain.PriceSourceDemirProfil)
		if last.Note != dp.RepriceNote || !last.ChangedAt.Equal(res.SyncedAt) {
			t.Fatalf("not/an yanlış: %q %s (senkron %s)", last.Note, last.ChangedAt, res.SyncedAt)
		}
		if lc := sourceOverview(t, svc, org.ID, domain.PriceSourceDemirProfil).LastChanges; lc == nil || lc.Increased != 0 || lc.Decreased != 0 || lc.AvgIncreasePercent != nil {
			t.Fatalf("son senkron özeti geri alınan elle düzenlemeyi zam saymamalı: %+v", lc)
		}
		at := service.PriceChangeFilter{From: res.SyncedAt, To: res.SyncedAt.Add(time.Microsecond)}
		if got, err := svc.ListPriceChanges(ctx, org.ID, at); err != nil || got.Total != 0 {
			t.Fatalf("zam gelen ürünler (varsayılan: tedarikçi, artış) boş olmalı: %+v %v", got, err)
		}
		at.Reason = domain.PriceChangeReasonMarkup
		if got, err := svc.ListPriceChanges(ctx, org.ID, at); err != nil || got.Total != 1 || got.Changes[0].ProductID != k.ID {
			t.Fatalf("satır kâr oranı nedeniyle listelenmeli: %+v %v", got, err)
		}
		sum, err := svc.PriceChangeSummary(ctx, org.ID, service.PriceChangeSummaryFilter{From: at.From, To: at.To, Reason: "all"})
		if err != nil || len(sum.Events) != 1 || sum.Events[0].Reason != domain.PriceChangeReasonMarkup || sum.Events[0].ChangeCount != 1 {
			t.Fatalf("özet tek bir kâr oranı olayı göstermeli: %+v %v", sum, err)
		}
	})

	t.Run("bilinmeyen kaynak", func(t *testing.T) {
		if _, err := svc.Sync(ctx, org.ID, "bilinmeyen", ""); !errors.Is(err, domain.ErrUnknownPriceSource) {
			t.Fatalf("ErrUnknownPriceSource bekleniyordu, geldi %v", err)
		}
	})
}

// TestPriceSourceShortListGuard: liste, firmanın o kaynaktaki son başarılı
// senkronunun yarısından az ürün içeriyorsa hiçbir şey değişmez ve açık
// bir hata kaydedilir (tam yarısı kabul edilir).
func TestPriceSourceShortListGuard(t *testing.T) {
	dbURL := testDBURL(t)
	ctx := context.Background()
	pool, err := repository.NewPool(ctx, dbURL)
	if err != nil {
		t.Fatalf("veritabanına bağlanılamadı: %v", err)
	}
	t.Cleanup(func() { pool.Close() })
	q := sqlc.New(pool)
	ulasFake, demirFake := &fakeSource{}, &fakeSource{}
	svc := service.NewPriceSourceService(pool, q, map[string]service.PriceFetcher{
		domain.PriceSourceUlas: ulasFake.fetch, domain.PriceSourceDemirProfil: demirFake.fetch,
	})
	orgSvc := service.NewOrganizationService(q)
	org := mustCreateOrg(t, ctx, orgSvc, pool, "Kısa Liste Eşiği", "kisa-liste-esigi")

	items := func(n int, price string) []pricesource.Item {
		out := make([]pricesource.Item, n)
		for i := range out {
			out[i] = ulasItem(fmt.Sprintf("Ürün %02d", i), "adet", "K", price)
		}
		return out
	}
	ulasFake.set(nil, items(10, "100")...)
	if _, err := svc.Sync(ctx, org.ID, domain.PriceSourceUlas, ""); err != nil {
		t.Fatalf("ilk senkron: %v", err)
	}
	okBefore := ulasOverview(t, svc, org.ID)

	t.Run("yarısından az: failed, hiçbir şey değişmez", func(t *testing.T) {
		snapshot := loadTestProducts(t, pool, org.ID)
		hist := countHistoryForOrg(t, pool, org.ID)
		ulasFake.set(nil, items(4, "999")...)
		_, err := svc.Sync(ctx, org.ID, domain.PriceSourceUlas, "")
		if !errors.Is(err, domain.ErrPriceListTooShort) {
			t.Fatalf("ErrPriceListTooShort bekleniyordu, geldi %v", err)
		}
		if after := loadTestProducts(t, pool, org.ID); !equalProducts(snapshot, after) {
			t.Fatal("kısa liste ürünleri değiştirdi")
		}
		if n := countHistoryForOrg(t, pool, org.ID); n != hist {
			t.Fatalf("kısa liste fiyat geçmişi yazdı: %d -> %d", hist, n)
		}
		ov := ulasOverview(t, svc, org.ID)
		if ov.LastStatus != domain.PriceSyncStatusFailed ||
			!strings.Contains(ov.LastError, "liste beklenenden çok kısa geldi; fiyatlar değiştirilmedi") ||
			!strings.Contains(ov.LastError, "gelen 4 ürün") || !strings.Contains(ov.LastError, "son başarılı senkronda 10") ||
			ov.LastResult.Total != 10 || !ov.LastSyncedAt.Equal(*okBefore.LastSyncedAt) || ov.MissingCount != 0 {
			t.Fatalf("kısa liste yanlış kaydedildi: %+v", ov)
		}
	})

	t.Run("tam yarısı kabul edilir; eşik son başarılı senkrondan hesaplanır", func(t *testing.T) {
		ulasFake.set(nil, items(5, "100")...)
		res, err := svc.Sync(ctx, org.ID, domain.PriceSourceUlas, "")
		if err != nil {
			t.Fatalf("yarı liste kabul edilmeliydi: %v", err)
		}
		expectResult(t, res, 5, 0, 0, 5, 5)
		ulasFake.set(nil, items(2, "100")...) // 2 < 5/2
		if _, err := svc.Sync(ctx, org.ID, domain.PriceSourceUlas, ""); !errors.Is(err, domain.ErrPriceListTooShort) {
			t.Fatalf("ErrPriceListTooShort bekleniyordu, geldi %v", err)
		}
		ulasFake.set(nil, items(3, "100")...)
		if _, err := svc.Sync(ctx, org.ID, domain.PriceSourceUlas, ""); err != nil {
			t.Fatalf("3 >= 5/2 kabul edilmeliydi: %v", err)
		}
	})

	t.Run("eşik kaynak bazındadır: hiç senkronlanmamış kaynakta sınır yok", func(t *testing.T) {
		demirFake.set(nil, items(1, "5")...)
		if _, err := svc.Sync(ctx, org.ID, domain.PriceSourceDemirProfil, ""); err != nil {
			t.Fatalf("ilk Demir Profil senkronu eşiğe takılmamalı: %v", err)
		}
	})

	t.Run("gece işinde de uygulanır", func(t *testing.T) {
		if _, err := svc.UpdatePriceSource(ctx, org.ID, domain.PriceSourceUlas, "", service.PriceSourceSettingsInput{
			MarkupPercent: decimal.NewFromInt(15), AutoSync: true,
		}); err != nil {
			t.Fatalf("ayar: %v", err)
		}
		service.SetNightlyOrgFilterForTest(svc, org.ID)
		ulasFake.set(nil, items(1, "100")...) // son başarılı: 3
		report, err := svc.SyncAutoOrganizations(ctx, time.Now().Add(time.Minute))
		if err != nil || report.Organizations != 1 || report.Failed != 1 || report.Succeeded != 0 {
			t.Fatalf("rapor yanlış: %+v %v", report, err)
		}
		if ov := ulasOverview(t, svc, org.ID); ov.LastStatus != domain.PriceSyncStatusFailed || !strings.Contains(ov.LastError, "çok kısa") {
			t.Fatalf("gece işi kısa listeyi kaydetmeli: %+v", ov)
		}
	})
}

// TestPriceSourceNightlyMultipleSources: gece işi her kaynağı en fazla BİR
// kez indirir ve yalnızca en az bir uygun firma o kaynak için otomatik
// senkronu açtıysa.
func TestPriceSourceNightlyMultipleSources(t *testing.T) {
	dbURL := testDBURL(t)
	ctx := context.Background()
	pool, err := repository.NewPool(ctx, dbURL)
	if err != nil {
		t.Fatalf("veritabanına bağlanılamadı: %v", err)
	}
	t.Cleanup(func() { pool.Close() })
	q := sqlc.New(pool)
	ulasFake, demirFake := &fakeSource{}, &fakeSource{}
	svc := service.NewPriceSourceService(pool, q, map[string]service.PriceFetcher{
		domain.PriceSourceUlas: ulasFake.fetch, domain.PriceSourceDemirProfil: demirFake.fetch,
	})
	orgSvc := service.NewOrganizationService(q)
	a := mustCreateOrg(t, ctx, orgSvc, pool, "Gece İki Kaynak A", "gece-iki-kaynak-a")
	b := mustCreateOrg(t, ctx, orgSvc, pool, "Gece İki Kaynak B", "gece-iki-kaynak-b")
	service.SetNightlyOrgFilterForTest(svc, a.ID, b.ID)
	ulasFake.set(nil, ulasItem("Gece Ulaş", "adet", "K", "100"))
	demirFake.setLabel("Eylül 2026")
	demirFake.set(nil, ulasItem("Gece Demir", "kg", "H profil", "40"))

	enable := func(orgID, source string) {
		t.Helper()
		if _, err := svc.UpdatePriceSource(ctx, orgID, source, "", service.PriceSourceSettingsInput{
			MarkupPercent: decimal.NewFromInt(10), AutoSync: true,
		}); err != nil {
			t.Fatalf("ayar: %v", err)
		}
	}

	t.Run("yalnızca Demir Profil açık: Ulaş hiç indirilmez", func(t *testing.T) {
		enable(a.ID, domain.PriceSourceDemirProfil)
		enable(b.ID, domain.PriceSourceDemirProfil)
		report, err := svc.SyncAutoOrganizations(ctx, time.Now())
		if err != nil || report.Organizations != 2 || report.Succeeded != 2 || report.Failed != 0 {
			t.Fatalf("rapor yanlış: %+v %v", report, err)
		}
		if ulasFake.callCount() != 0 || demirFake.callCount() != 1 {
			t.Fatalf("indirme sayıları ulas=%d demir=%d, beklenen 0/1", ulasFake.callCount(), demirFake.callCount())
		}
		for _, o := range []domain.Organization{a, b} {
			ps := findTestProducts(loadTestProducts(t, pool, o.ID), "Gece Demir", "kg", strPtr(domain.PriceSourceDemirProfil))
			if len(ps) != 1 || ps[0].UnitPrice != "44.00" {
				t.Fatalf("%s senkronlanmalıydı: %+v", o.Slug, ps)
			}
			if ov := sourceOverview(t, svc, o.ID, domain.PriceSourceDemirProfil); ov.ListLabel != "Eylül 2026" {
				t.Fatalf("dönem kaydedilmeli: %+v", ov)
			}
		}
	})

	t.Run("iki kaynak açık: her biri BİR kez indirilir", func(t *testing.T) {
		enable(a.ID, domain.PriceSourceUlas)
		report, err := svc.SyncAutoOrganizations(ctx, time.Now().Add(time.Minute))
		// Demir Profil: a + b; Ulaş: yalnızca a.
		if err != nil || report.Organizations != 3 || report.Succeeded != 3 {
			t.Fatalf("rapor yanlış: %+v %v", report, err)
		}
		if ulasFake.callCount() != 1 || demirFake.callCount() != 2 {
			t.Fatalf("indirme sayıları ulas=%d demir=%d, beklenen 1/2", ulasFake.callCount(), demirFake.callCount())
		}
		if ps := findTestProducts(loadTestProducts(t, pool, b.ID), "Gece Ulaş", "adet", strPtr(domain.PriceSourceUlas)); len(ps) != 0 {
			t.Fatalf("Ulaş'ı açmayan firma senkronlanmamalı: %+v", ps)
		}
	})

	t.Run("bir kaynağın indirme hatası diğerini etkilemez", func(t *testing.T) {
		ulasFake.set(&pricesource.HTTPStatusError{StatusCode: 500})
		report, err := svc.SyncAutoOrganizations(ctx, time.Now().Add(2*time.Minute))
		if err != nil || report.Organizations != 3 || report.Succeeded != 2 || report.Failed != 1 {
			t.Fatalf("rapor yanlış: %+v %v", report, err)
		}
		if ov := ulasOverview(t, svc, a.ID); ov.LastStatus != domain.PriceSyncStatusFailed || ov.LastError != "Ulaş sunucusu HTTP 500 döndü" {
			t.Fatalf("Ulaş hatası kaydedilmeli: %+v", ov)
		}
		if ov := sourceOverview(t, svc, a.ID, domain.PriceSourceDemirProfil); ov.LastStatus != domain.PriceSyncStatusSuccess {
			t.Fatalf("Demir Profil başarılı kalmalı: %+v", ov)
		}
		demirFake.set(errors.New("iç ayrıntı 10.9.9.9"))
		if _, err := svc.Sync(ctx, a.ID, domain.PriceSourceDemirProfil, ""); !errors.Is(err, domain.ErrPriceSourceFetch) {
			t.Fatalf("ErrPriceSourceFetch bekleniyordu: %v", err)
		}
		if ov := sourceOverview(t, svc, a.ID, domain.PriceSourceDemirProfil); ov.LastError != "Demir Profil fiyat listesi alınamadı" {
			t.Fatalf("Demir Profil hata metni sabit ve kaynak adlı olmalı: %q", ov.LastError)
		}
	})
}
