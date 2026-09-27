package service_test

// Zam geçmişi (migration 0046) gerçek veritabanına karşı: filtreler, sıralama,
// sayfalama, varsayılan aralık, firma izolasyonu, özet/olay gruplaması ve
// 0046'nın geri doldurma kuralları. Fiyat değişiklikleri gerçek akışlarla
// (sahte listeyle senkron, kâr oranı güncellemesi, elle ürün düzenleme)
// üretilir.

import (
	"context"
	"errors"
	"os"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
	"github.com/shopspring/decimal"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

func dec(s string) decimal.Decimal { return decimal.RequireFromString(s) }

func decPtrString(d *decimal.Decimal) string {
	if d == nil {
		return "<nil>"
	}
	return d.StringFixed(2)
}

func changeKeys(cs []domain.PriceChange) map[string]bool {
	out := map[string]bool{}
	for _, c := range cs {
		out[c.ProductName+"|"+c.Reason+"|"+c.Source] = true
	}
	return out
}

func expectChangeKeys(t *testing.T, got []domain.PriceChange, want ...string) {
	t.Helper()
	keys := changeKeys(got)
	if len(got) != len(want) || len(keys) != len(want) {
		t.Fatalf("değişiklikler = %v, beklenen %v", keys, want)
	}
	for _, w := range want {
		if !keys[w] {
			t.Fatalf("değişiklikler = %v, beklenen %v", keys, want)
		}
	}
}

func TestPriceChanges(t *testing.T) {
	dbURL := testDBURL(t)
	ctx := context.Background()
	pool, err := repository.NewPool(ctx, dbURL)
	if err != nil {
		t.Fatalf("veritabanına bağlanılamadı: %v", err)
	}
	t.Cleanup(func() { pool.Close() })
	q := sqlc.New(pool)
	orgSvc := service.NewOrganizationService(q)
	productSvc := service.NewProductService(q)
	ulasFake, demirFake := &fakeSource{}, &fakeSource{}
	svc := service.NewPriceSourceService(pool, q, map[string]service.PriceFetcher{
		domain.PriceSourceUlas: ulasFake.fetch, domain.PriceSourceDemirProfil: demirFake.fetch,
	})
	orgA := mustCreateOrg(t, ctx, orgSvc, pool, "Zam Geçmişi A", "zam-gecmisi-a")
	orgB := mustCreateOrg(t, ctx, orgSvc, pool, "Zam Geçmişi B", "zam-gecmisi-b")

	// Yüzdeler tam çıksın diye kâr oranı önce %0 (ürün yokken: geçmiş yazılmaz).
	for _, src := range []string{domain.PriceSourceUlas, domain.PriceSourceDemirProfil} {
		if _, err := svc.UpdatePriceSource(ctx, orgA.ID, src, "", service.PriceSourceSettingsInput{MarkupPercent: decimal.Zero}); err != nil {
			t.Fatalf("ayar: %v", err)
		}
	}
	sync := func(src string) {
		t.Helper()
		if _, err := svc.Sync(ctx, orgA.ID, src, ""); err != nil {
			t.Fatalf("%s senkronu: %v", src, err)
		}
	}
	// Olaylar: ulas oluşturma (geçmiş yok) -> demir oluşturma (geçmiş yok)
	// -> ulas fiyat değişimi (A1 +%10, A2 -%10, A3 +%20) -> demir fiyat
	// değişimi (D1 +%10) -> ulas kâr oranı %0 -> %10 (A1-A3 +%10) -> elle
	// (D1 -%50, sıfır fiyatlı Z 0 -> 5).
	ulasFake.set(nil, ulasItem("Çimento", "torba", "YAPI", "100"), ulasItem("Kum", "ton", "YAPI", "200"), ulasItem("Alçı", "torba", "ALÇI", "50"))
	sync(domain.PriceSourceUlas)
	demirFake.set(nil, ulasItem("Siyah Kutu Profil 20×20×1,2 mm", "mt", "Siyah Kutu Profil", "30"), ulasItem("Çimento", "torba", "YAPI", "90"))
	sync(domain.PriceSourceDemirProfil)
	ulasFake.set(nil, ulasItem("Çimento", "torba", "YAPI", "110"), ulasItem("Kum", "ton", "YAPI", "180"), ulasItem("Alçı", "torba", "ALÇI", "60"))
	sync(domain.PriceSourceUlas)
	demirFake.set(nil, ulasItem("Siyah Kutu Profil 20×20×1,2 mm", "mt", "Siyah Kutu Profil", "33"), ulasItem("Çimento", "torba", "YAPI", "90"))
	sync(domain.PriceSourceDemirProfil)
	if _, err := svc.UpdatePriceSource(ctx, orgA.ID, domain.PriceSourceUlas, "", service.PriceSourceSettingsInput{MarkupPercent: decimal.NewFromInt(10)}); err != nil {
		t.Fatalf("kâr oranı: %v", err)
	}
	products := loadTestProducts(t, pool, orgA.ID)
	d1 := onlyProduct(t, products, "Siyah Kutu Profil 20×20×1,2 mm", "mt", strPtr(domain.PriceSourceDemirProfil))
	if _, err := productSvc.Update(ctx, d1.ID, orgA.ID, d1.Name, d1.Unit, 16.5, "", d1.Category); err != nil {
		t.Fatalf("elle düzenleme: %v", err)
	}
	zero, err := productSvc.Create(ctx, orgA.ID, "Sıfır Fiyatlı", "adet", 0, "", "ELLE")
	if err != nil {
		t.Fatalf("ürün: %v", err)
	}
	if _, err := productSvc.Update(ctx, zero.ID, orgA.ID, zero.Name, zero.Unit, 5, "", "ELLE"); err != nil {
		t.Fatalf("elle düzenleme: %v", err)
	}
	// Başka firmanın değişikliği: A'nın hiçbir sorgusunda görünmemeli.
	bProduct, err := productSvc.Create(ctx, orgB.ID, "Çimento", "torba", 100, "", "YAPI")
	if err != nil {
		t.Fatalf("B ürünü: %v", err)
	}
	if _, err := productSvc.Update(ctx, bProduct.ID, orgB.ID, "Çimento", "torba", 500, "", "YAPI"); err != nil {
		t.Fatalf("B düzenleme: %v", err)
	}

	const (
		supUlas  = "|supplier|ulas"
		supDemir = "|supplier|demirprofil"
		mkUlas   = "|markup|ulas"
		manual   = "|manual|"
	)

	t.Run("varsayılan: son 30 gün, zamlar, tedarikçi, en yeni önce", func(t *testing.T) {
		res, err := svc.ListPriceChanges(ctx, orgA.ID, service.PriceChangeFilter{})
		if err != nil {
			t.Fatalf("liste: %v", err)
		}
		expectChangeKeys(t, res.Changes, "Çimento"+supUlas, "Alçı"+supUlas, "Siyah Kutu Profil 20×20×1,2 mm"+supDemir)
		if res.Total != 3 || res.Page != 1 || res.Limit != 50 {
			t.Fatalf("toplam/sayfa yanlış: %d %d %d", res.Total, res.Page, res.Limit)
		}
		// En yeni önce: Demir Profil senkronu Ulaş'ınkinden sonraydı.
		if res.Changes[0].Source != domain.PriceSourceDemirProfil {
			t.Fatalf("en yeni değişiklik önce gelmeli: %+v", res.Changes[0])
		}
		for _, c := range res.Changes {
			if c.ProductName == "Alçı" {
				if !c.OldPrice.Equal(dec("50")) || !c.NewPrice.Equal(dec("60")) || !c.ChangeAmount.Equal(dec("10")) ||
					decPtrString(c.ChangePercent) != "20.00" || c.Unit != "torba" || c.Category != "ALÇI" ||
					decPtrString(c.OldSourcePrice) != "50.00" || decPtrString(c.NewSourcePrice) != "60.00" || c.Note != domain.PriceHistoryNoteUlasSync {
					t.Fatalf("Alçı satırı yanlış: %+v", c)
				}
			}
		}
	})

	t.Run("filtreler: yön, neden, kaynak, kategori, arama", func(t *testing.T) {
		list := func(f service.PriceChangeFilter) []domain.PriceChange {
			t.Helper()
			res, err := svc.ListPriceChanges(ctx, orgA.ID, f)
			if err != nil {
				t.Fatalf("liste %+v: %v", f, err)
			}
			if int(res.Total) != len(res.Changes) {
				t.Fatalf("toplam %d, satır %d", res.Total, len(res.Changes))
			}
			return res.Changes
		}
		expectChangeKeys(t, list(service.PriceChangeFilter{Direction: "down"}), "Kum"+supUlas)
		expectChangeKeys(t, list(service.PriceChangeFilter{Direction: "all", Reason: "all"}),
			"Çimento"+supUlas, "Kum"+supUlas, "Alçı"+supUlas, "Siyah Kutu Profil 20×20×1,2 mm"+supDemir,
			"Çimento"+mkUlas, "Kum"+mkUlas, "Alçı"+mkUlas, "Siyah Kutu Profil 20×20×1,2 mm"+manual, "Sıfır Fiyatlı"+manual)
		expectChangeKeys(t, list(service.PriceChangeFilter{Source: domain.PriceSourceDemirProfil}), "Siyah Kutu Profil 20×20×1,2 mm"+supDemir)
		expectChangeKeys(t, list(service.PriceChangeFilter{Reason: "markup"}), "Çimento"+mkUlas, "Kum"+mkUlas, "Alçı"+mkUlas)
		expectChangeKeys(t, list(service.PriceChangeFilter{Reason: "manual", Direction: "down"}), "Siyah Kutu Profil 20×20×1,2 mm"+manual)
		expectChangeKeys(t, list(service.PriceChangeFilter{Category: " ALÇI ", Reason: "all"}), "Alçı"+supUlas, "Alçı"+mkUlas)
		// Arama Türkçe karakter katlamalı (normalized_name): "cimento" Çimento'yu bulur;
		// Demir Profil'in Çimento'sunun fiyatı hiç değişmedi.
		expectChangeKeys(t, list(service.PriceChangeFilter{Query: "cimento", Reason: "all", Direction: "all"}), "Çimento"+supUlas, "Çimento"+mkUlas)

		// Kaynak/elle ayrımı ve kaynak fiyatları.
		for _, c := range list(service.PriceChangeFilter{Direction: "all", Reason: "all"}) {
			switch c.Reason {
			case domain.PriceChangeReasonMarkup:
				if c.OldSourcePrice == nil || !c.OldSourcePrice.Equal(*c.NewSourcePrice) || decPtrString(c.ChangePercent) != "10.00" {
					t.Fatalf("kâr oranı satırında kaynak fiyatı değişmemeli: %+v", c)
				}
			case domain.PriceChangeReasonManual:
				if c.Source != "" || c.OldSourcePrice != nil || c.NewSourcePrice != nil || c.Note != "" {
					t.Fatalf("elle düzenleme satırı yanlış: %+v", c)
				}
				if c.ProductName == "Sıfır Fiyatlı" && (c.ChangePercent != nil || !c.ChangeAmount.Equal(dec("5"))) {
					t.Fatalf("eski fiyat 0 iken yüzde tanımsız olmalı: %+v", c)
				}
			}
		}
	})

	t.Run("sıralama ve sayfalama", func(t *testing.T) {
		res, err := svc.ListPriceChanges(ctx, orgA.ID, service.PriceChangeFilter{Reason: "all", Sort: service.PriceChangeSortLargestIncrease})
		if err != nil {
			t.Fatalf("liste: %v", err)
		}
		// Zamlar: Alçı %20 önce; yüzdesi tanımsız (0 -> 5) en sonda.
		if len(res.Changes) != 7 || res.Changes[0].ProductName != "Alçı" || res.Changes[0].Reason != domain.PriceChangeReasonSupplier ||
			res.Changes[6].ProductName != "Sıfır Fiyatlı" {
			t.Fatalf("en büyük zam sıralaması yanlış: %v", changeKeys(res.Changes))
		}
		res, err = svc.ListPriceChanges(ctx, orgA.ID, service.PriceChangeFilter{Reason: "all", Direction: "all", Sort: service.PriceChangeSortLargestDecrease})
		if err != nil {
			t.Fatalf("liste: %v", err)
		}
		if res.Changes[0].ProductName != "Siyah Kutu Profil 20×20×1,2 mm" || decPtrString(res.Changes[0].ChangePercent) != "-50.00" ||
			res.Changes[1].ProductName != "Kum" || res.Changes[1].Reason != domain.PriceChangeReasonSupplier {
			t.Fatalf("en büyük indirim sıralaması yanlış: %+v / %+v", res.Changes[0], res.Changes[1])
		}

		seen := map[string]bool{}
		for page := 1; page <= 5; page++ {
			res, err := svc.ListPriceChanges(ctx, orgA.ID, service.PriceChangeFilter{Reason: "all", Direction: "all", Page: page, Limit: 2})
			if err != nil {
				t.Fatalf("sayfa %d: %v", page, err)
			}
			if res.Total != 9 {
				t.Fatalf("sayfa %d: toplam %d, beklenen 9", page, res.Total)
			}
			wantRows := map[int]int{1: 2, 2: 2, 3: 2, 4: 2, 5: 1}[page]
			if len(res.Changes) != wantRows {
				t.Fatalf("sayfa %d: %d satır, beklenen %d", page, len(res.Changes), wantRows)
			}
			for _, c := range res.Changes {
				if seen[c.ID] {
					t.Fatalf("sayfalar arasında tekrar eden satır: %s", c.ID)
				}
				seen[c.ID] = true
			}
		}
		if res, err := svc.ListPriceChanges(ctx, orgA.ID, service.PriceChangeFilter{Reason: "all", Direction: "all", Page: 6, Limit: 2}); err != nil ||
			len(res.Changes) != 0 || res.Total != 9 {
			t.Fatalf("son sayfadan sonrası boş olmalı, toplam korunmalı: %+v %v", res, err)
		}
		if res, err := svc.ListPriceChanges(ctx, orgA.ID, service.PriceChangeFilter{Limit: 5000}); err != nil || res.Limit != 200 {
			t.Fatalf("limit 200 ile sınırlanmalı: %+v %v", res, err)
		}
	})

	t.Run("zaman aralığı: varsayılan 30 gün, tarih/an sınırları dahil", func(t *testing.T) {
		// Alçı'nın tedarikçi zammını 40 gün öncesine taşı.
		alci := onlyProduct(t, loadTestProducts(t, pool, orgA.ID), "Alçı", "torba", strPtr(domain.PriceSourceUlas))
		var original time.Time
		if err := pool.QueryRow(ctx, `SELECT changed_at FROM product_price_history WHERE product_id = $1 AND reason = 'supplier'`, alci.ID).Scan(&original); err != nil {
			t.Fatalf("tarih okunamadı: %v", err)
		}
		old := time.Now().Add(-40 * 24 * time.Hour)
		if _, err := pool.Exec(ctx, `UPDATE product_price_history SET changed_at = $2 WHERE product_id = $1 AND reason = 'supplier'`, alci.ID, old); err != nil {
			t.Fatalf("tarih taşınamadı: %v", err)
		}
		// Sonraki alt testlerin olay gruplaması (aynı senkron = aynı an) bozulmasın.
		defer func() {
			if _, err := pool.Exec(ctx, `UPDATE product_price_history SET changed_at = $2 WHERE product_id = $1 AND reason = 'supplier'`, alci.ID, original); err != nil {
				t.Fatalf("tarih geri alınamadı: %v", err)
			}
		}()
		res, err := svc.ListPriceChanges(ctx, orgA.ID, service.PriceChangeFilter{})
		if err != nil {
			t.Fatalf("liste: %v", err)
		}
		expectChangeKeys(t, res.Changes, "Çimento"+supUlas, "Siyah Kutu Profil 20×20×1,2 mm"+supDemir)

		day := old.In(mustIstanbul(t)).Format("2006-01-02")
		from, err := service.ParsePriceChangeTime(day, false)
		if err != nil {
			t.Fatalf("tarih: %v", err)
		}
		to, err := service.ParsePriceChangeTime(day, true)
		if err != nil {
			t.Fatalf("tarih: %v", err)
		}
		res, err = svc.ListPriceChanges(ctx, orgA.ID, service.PriceChangeFilter{From: from, To: to})
		if err != nil {
			t.Fatalf("liste: %v", err)
		}
		expectChangeKeys(t, res.Changes, "Alçı"+supUlas)

		// from = to = olayın changed_at'i (RFC3339Nano) o olayı birebir süzer.
		instant := res.Changes[0].ChangedAt.Format(time.RFC3339Nano)
		from, _ = service.ParsePriceChangeTime(instant, false)
		to, _ = service.ParsePriceChangeTime(instant, true)
		if res, err := svc.ListPriceChanges(ctx, orgA.ID, service.PriceChangeFilter{From: from, To: to}); err != nil || len(res.Changes) != 1 {
			t.Fatalf("an sınırı dahil olmalı: %+v %v", res, err)
		}
	})

	t.Run("doğrulama hataları", func(t *testing.T) {
		now := time.Now()
		for _, f := range []service.PriceChangeFilter{
			{Direction: "yukari"}, {Reason: "hepsi"}, {Source: "bilinmeyen"}, {Sort: "fiyat"},
			{Page: -1}, {Limit: -5}, {Page: 100001},
			{From: now, To: now.Add(-time.Hour)},
			{Query: strings.Repeat("a", 101)},
			// PostgreSQL'in reddettiği metinler 500 değil doğrulama hatası olmalı.
			{Category: "\xff"}, {Category: "a\x00b"}, {Query: "a\x00b"}, {Query: "\xc3("},
		} {
			if _, err := svc.ListPriceChanges(ctx, orgA.ID, f); !service.IsPriceChangeValidationError(err) {
				t.Errorf("%+v: doğrulama hatası bekleniyordu, geldi %v", f, err)
			}
		}
		for _, v := range []string{"2026-13-01", "dün", "2026-09-27T25:00:00Z", "1695800000"} {
			if _, err := service.ParsePriceChangeTime(v, false); !service.IsPriceChangeValidationError(err) {
				t.Errorf("%q: doğrulama hatası bekleniyordu, geldi %v", v, err)
			}
		}
		if _, err := svc.PriceChangeSummary(ctx, orgA.ID, service.PriceChangeSummaryFilter{Reason: "x"}); !service.IsPriceChangeValidationError(err) {
			t.Errorf("özet: doğrulama hatası bekleniyordu, geldi %v", err)
		}
	})

	t.Run("özet: sayılar ve olay gruplaması", func(t *testing.T) {
		sum, err := svc.PriceChangeSummary(ctx, orgA.ID, service.PriceChangeSummaryFilter{Reason: "all"})
		if err != nil {
			t.Fatalf("özet: %v", err)
		}
		// Zam: Çimento/Alçı (Ulaş) + D1 (Demir) + 3 kâr oranı + Z (0 -> 5) = 7;
		// indirim: Kum (Ulaş) + D1 (elle) = 2. Tekil zam gelen: Çimento, Alçı,
		// D1, Kum (kâr oranı), Z = 5. Ortalama zam (eski > 0): (10+20+10+10+10+10)/6 = 11.67.
		if sum.IncreasedCount != 7 || sum.DecreasedCount != 2 || sum.ProductsIncreased != 5 || decPtrString(sum.AvgIncreasePercent) != "11.67" {
			t.Fatalf("özet sayıları yanlış: %+v (ort %s)", sum, decPtrString(sum.AvgIncreasePercent))
		}
		if sum.MaxIncrease == nil || sum.MaxIncrease.ProductName != "Alçı" || !sum.MaxIncrease.ChangePercent.Equal(dec("20")) {
			t.Fatalf("en yüksek zam yanlış: %+v", sum.MaxIncrease)
		}
		type ev struct {
			count, inc, decr int
			avg, max         string
		}
		want := map[string]ev{
			domain.PriceSourceUlas + "|supplier":        {3, 2, 1, "6.67", "20.00"},
			domain.PriceSourceDemirProfil + "|supplier": {1, 1, 0, "10.00", "10.00"},
			domain.PriceSourceUlas + "|markup":          {3, 3, 0, "10.00", "10.00"},
			// Elle düzenlemeler gün başına tek olay; Z'nin yüzdesi tanımsız.
			"|manual": {2, 1, 1, "-50.00", "<nil>"},
		}
		if len(sum.Events) != len(want) {
			t.Fatalf("olay sayısı = %d, beklenen %d: %+v", len(sum.Events), len(want), sum.Events)
		}
		for _, e := range sum.Events {
			w, ok := want[e.Source+"|"+e.Reason]
			if !ok || e.ChangeCount != w.count || e.Increased != w.inc || e.Decreased != w.decr ||
				decPtrString(e.AvgChangePercent) != w.avg || decPtrString(e.MaxIncreasePercent) != w.max {
				t.Fatalf("olay %s|%s yanlış: %+v (ort %s, en yüksek %s)", e.Source, e.Reason, e,
					decPtrString(e.AvgChangePercent), decPtrString(e.MaxIncreasePercent))
			}
			if e.Reason == domain.PriceChangeReasonManual {
				ist := e.ChangedAt.In(mustIstanbul(t))
				if ist.Hour() != 0 || ist.Minute() != 0 || ist.Second() != 0 {
					t.Fatalf("elle düzenleme olayı İstanbul günü başına gruplanmalı: %s", ist)
				}
			}
		}
		// Olaylar en yeniden eskiye; aynı senkronun satırları tek olay (changed_at).
		for i := 1; i < len(sum.Events); i++ {
			if sum.Events[i].ChangedAt.After(sum.Events[i-1].ChangedAt) {
				t.Fatalf("olaylar en yeni önce sıralanmalı: %+v", sum.Events)
			}
		}
		// Her olayın from/to'su (JSON'daki gibi RFC3339Nano, liste ucunun
		// çözümlemesiyle) + reason + source + direction=all, listede TAM o
		// olayın satırlarını getirir -- elle düzenleme günü dahil.
		for _, e := range sum.Events {
			from, err := service.ParsePriceChangeTime(e.RangeFrom.Format(time.RFC3339Nano), false)
			if err != nil {
				t.Fatalf("from: %v", err)
			}
			to, err := service.ParsePriceChangeTime(e.RangeTo.Format(time.RFC3339Nano), true)
			if err != nil {
				t.Fatalf("to: %v", err)
			}
			res, err := svc.ListPriceChanges(ctx, orgA.ID, service.PriceChangeFilter{
				From: from, To: to, Reason: e.Reason, Source: e.Source, Direction: service.PriceChangeDirectionAll,
			})
			if err != nil || int(res.Total) != e.ChangeCount {
				t.Fatalf("olay %s|%s (%s..%s): listede %d satır, olayda %d (%v)", e.Source, e.Reason, e.RangeFrom, e.RangeTo, res.Total, e.ChangeCount, err)
			}
			for _, c := range res.Changes {
				if c.Reason != e.Reason || c.Source != e.Source {
					t.Fatalf("olay %s|%s listesinde yabancı satır: %+v", e.Source, e.Reason, c)
				}
			}
			if e.Reason != domain.PriceChangeReasonManual && (!e.RangeFrom.Equal(e.ChangedAt) || !e.RangeTo.Equal(e.ChangedAt)) {
				t.Fatalf("senkron/kâr oranı olayının aralığı tek an olmalı: %+v", e)
			}
		}

		// Varsayılan (tedarikçi) ve kaynak filtresi.
		sum, err = svc.PriceChangeSummary(ctx, orgA.ID, service.PriceChangeSummaryFilter{})
		if err != nil || sum.IncreasedCount != 3 || sum.DecreasedCount != 1 || sum.ProductsIncreased != 3 ||
			decPtrString(sum.AvgIncreasePercent) != "13.33" || len(sum.Events) != 2 {
			t.Fatalf("tedarikçi özeti yanlış: %+v %v", sum, err)
		}
		sum, err = svc.PriceChangeSummary(ctx, orgA.ID, service.PriceChangeSummaryFilter{Source: domain.PriceSourceDemirProfil})
		if err != nil || sum.IncreasedCount != 1 || len(sum.Events) != 1 || sum.MaxIncrease == nil ||
			sum.MaxIncrease.ProductName != "Siyah Kutu Profil 20×20×1,2 mm" {
			t.Fatalf("Demir Profil özeti yanlış: %+v %v", sum, err)
		}
		// Hiç değişiklik olmayan aralık: sayılar 0, ortalama/en yüksek null, olay listesi boş (nil değil).
		from := time.Now().Add(-90 * 24 * time.Hour)
		sum, err = svc.PriceChangeSummary(ctx, orgA.ID, service.PriceChangeSummaryFilter{From: from, To: from.Add(time.Hour)})
		if err != nil || sum.IncreasedCount != 0 || sum.AvgIncreasePercent != nil || sum.MaxIncrease != nil || sum.Events == nil || len(sum.Events) != 0 {
			t.Fatalf("boş özet yanlış: %+v %v", sum, err)
		}
	})

	t.Run("firma izolasyonu", func(t *testing.T) {
		res, err := svc.ListPriceChanges(ctx, orgB.ID, service.PriceChangeFilter{Reason: "all", Direction: "all"})
		if err != nil {
			t.Fatalf("liste: %v", err)
		}
		if len(res.Changes) != 1 || res.Changes[0].ProductID != bProduct.ID || res.Total != 1 {
			t.Fatalf("B yalnızca kendi değişikliğini görmeli: %+v", res.Changes)
		}
		sum, err := svc.PriceChangeSummary(ctx, orgB.ID, service.PriceChangeSummaryFilter{Reason: "all"})
		if err != nil || sum.IncreasedCount != 1 || sum.ProductsIncreased != 1 || len(sum.Events) != 1 {
			t.Fatalf("B özeti yalnızca kendi verisi olmalı: %+v %v", sum, err)
		}
		resA, err := svc.ListPriceChanges(ctx, orgA.ID, service.PriceChangeFilter{Reason: "all", Direction: "all", Limit: 200})
		if err != nil {
			t.Fatalf("liste: %v", err)
		}
		for _, c := range resA.Changes {
			if c.ProductID == bProduct.ID {
				t.Fatal("A, B'nin değişikliğini gördü")
			}
		}
	})

	t.Run("fiyat kaynağı özetinde son senkronun zamları", func(t *testing.T) {
		// Ulaş'ın son başarılı senkronu: Çimento +%10, Alçı +%20, Kum -%10
		// (sonraki kâr oranı güncellemesi senkron sayılmaz).
		ov := ulasOverview(t, svc, orgA.ID)
		if ov.LastChanges == nil || ov.LastChanges.Increased != 2 || ov.LastChanges.Decreased != 1 || decPtrString(ov.LastChanges.AvgIncreasePercent) != "15.00" {
			t.Fatalf("Ulaş son senkron değişimleri yanlış: %+v", ov.LastChanges)
		}
		dv := sourceOverview(t, svc, orgA.ID, domain.PriceSourceDemirProfil)
		if dv.LastChanges == nil || dv.LastChanges.Increased != 1 || dv.LastChanges.Decreased != 0 || decPtrString(dv.LastChanges.AvgIncreasePercent) != "10.00" {
			t.Fatalf("Demir Profil son senkron değişimleri yanlış: %+v", dv.LastChanges)
		}
	})
}

// TestManualPriceEditWaitsForConcurrentSync: elle düzenleme, satırı tutan
// eşzamanlı bir senkronu bekler ve fiyat geçmişine eski fiyat olarak
// senkronun YAZDIĞI fiyatı yazar -- satırlar zincir kurar (100 -> 110
// senkron, 110 -> 120 elle). Eskiden eski fiyat kilitsiz, güncellemeden
// önce okunuyordu: elle satır 100 -> 120 (+%20) olurdu.
func TestManualPriceEditWaitsForConcurrentSync(t *testing.T) {
	dbURL := testDBURL(t)
	ctx := context.Background()
	pool, err := repository.NewPool(ctx, dbURL)
	if err != nil {
		t.Fatalf("veritabanına bağlanılamadı: %v", err)
	}
	t.Cleanup(func() { pool.Close() })
	q := sqlc.New(pool)
	org := mustCreateOrg(t, ctx, service.NewOrganizationService(q), pool, "Elle Düzenleme Yarışı", "elle-duzenleme-yarisi")
	productID := insertTestProduct(t, pool, org.ID, "Yarış Ürünü", "adet", "100.00", strPtr(domain.PriceSourceUlas), "")
	productSvc := service.NewProductService(q)

	// Senkronu taklit eden transaction: satırı senkron gibi kilitler, fiyatı
	// 110 yapar, geçmişini yazar ve commit'i bekletir.
	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatalf("tx: %v", err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	var holderPID int
	if err := tx.QueryRow(ctx, `SELECT pg_backend_pid()`).Scan(&holderPID); err != nil {
		t.Fatalf("pid: %v", err)
	}
	for _, stmt := range []string{
		`SELECT id FROM products WHERE id = $1 FOR NO KEY UPDATE`,
		`UPDATE products SET unit_price = 110 WHERE id = $1`,
		`INSERT INTO product_price_history (product_id, old_price, new_price, note, reason, source) VALUES ($1, 100, 110, 'Ulaş fiyat listesi', 'supplier', 'ulas')`,
	} {
		if _, err := tx.Exec(ctx, stmt, productID); err != nil {
			t.Fatalf("senkron taklidi (%s): %v", stmt, err)
		}
	}

	done := make(chan error, 1)
	go func() {
		_, err := productSvc.Update(ctx, productID, org.ID, "Yarış Ürünü", "adet", 120, "", "")
		done <- err
	}()
	// Elle düzenleme senkronun kilidini beklemeye başlayana kadar bekle.
	deadline := time.Now().Add(10 * time.Second)
	for {
		var waiting int
		if err := pool.QueryRow(ctx, `SELECT count(*) FROM pg_stat_activity WHERE $1 = ANY(pg_blocking_pids(pid))`, holderPID).Scan(&waiting); err != nil {
			t.Fatalf("kilit beklemesi okunamadı: %v", err)
		}
		if waiting > 0 {
			break
		}
		select {
		case err := <-done:
			t.Fatalf("elle düzenleme senkronun kilidini beklemeden bitti: %v", err)
		default:
		}
		if time.Now().After(deadline) {
			t.Fatal("elle düzenleme kilit beklemesine girmedi")
		}
		time.Sleep(10 * time.Millisecond)
	}
	if err := tx.Commit(ctx); err != nil {
		t.Fatalf("commit: %v", err)
	}
	if err := <-done; err != nil {
		t.Fatalf("elle düzenleme: %v", err)
	}

	h := loadHistoryRows(t, pool, productID)
	if len(h) != 2 {
		t.Fatalf("iki geçmiş satırı bekleniyordu: %+v", h)
	}
	expectHistory(t, h[0], "100.00", "110.00", domain.PriceChangeReasonSupplier, domain.PriceSourceUlas, "<nil>", "<nil>")
	expectHistory(t, h[1], "110.00", "120.00", domain.PriceChangeReasonManual, "<nil>", "<nil>", "<nil>")

	// Fiyatı değişmeyen düzenleme geçmiş yazmaz; başka firmanın ürünü bulunamaz.
	if _, err := productSvc.Update(ctx, productID, org.ID, "Yarış Ürünü 2", "adet", 120, "", ""); err != nil {
		t.Fatalf("elle düzenleme: %v", err)
	}
	if n := len(loadHistoryRows(t, pool, productID)); n != 2 {
		t.Fatalf("fiyat değişmeden geçmiş yazıldı: %d satır", n)
	}
	other := mustCreateOrg(t, ctx, service.NewOrganizationService(q), pool, "Elle Düzenleme Yarışı B", "elle-duzenleme-yarisi-b")
	if _, err := productSvc.Update(ctx, productID, other.ID, "X", "adet", 1, "", ""); !errors.Is(err, domain.ErrNotFound) {
		t.Fatalf("başka firmanın ürünü: ErrNotFound bekleniyordu, geldi %v", err)
	}
	if n := len(loadHistoryRows(t, pool, productID)); n != 2 {
		t.Fatalf("başka firmanın denemesi geçmiş yazdı: %d satır", n)
	}
}

func mustIstanbul(t *testing.T) *time.Location {
	t.Helper()
	loc, err := time.LoadLocation("Europe/Istanbul")
	if err != nil {
		t.Fatalf("Europe/Istanbul: %v", err)
	}
	return loc
}

// backfillStatements, 0046 up migration'ındaki geri doldurma UPDATE'lerini
// dosyadan okur -- test, migration'ın KENDİ ifadelerini çalıştırır.
func backfillStatements(t *testing.T) []string {
	t.Helper()
	b, err := os.ReadFile("../../db/migrations/0046_add_demirprofil_and_price_change_history.up.sql")
	if err != nil {
		t.Fatalf("migration okunamadı: %v", err)
	}
	stmts := regexp.MustCompile(`(?m)^UPDATE product_price_history .*;$`).FindAllString(string(b), -1)
	if len(stmts) != 6 {
		t.Fatalf("altı geri doldurma ifadesi bekleniyordu: %q", stmts)
	}
	return stmts
}

// TestPriceHistoryBackfillMigration: 0046 uygulanmış veritabanında, 0045
// döneminde (ya da 0046 down'dan sonra) yazılmış gibi (reason varsayılan
// 'manual', source NULL) satırlar oluşturulur ve migration'ın geri doldurma
// ifadeleri TEK bir transaction içinde çalıştırılıp geri alınır: kayıt
// defterindeki her kaynağın sabit notları (senkron, dönemli senkron, kâr
// oranı, "tedarikçi fiyatı aynı") sınıflandırılır, diğerleri elle düzenleme
// kalır. Şema kısıtları da doğrulanır.
func TestPriceHistoryBackfillMigration(t *testing.T) {
	dbURL := testDBURL(t)
	ctx := context.Background()
	pool, err := repository.NewPool(ctx, dbURL)
	if err != nil {
		t.Fatalf("veritabanına bağlanılamadı: %v", err)
	}
	t.Cleanup(func() { pool.Close() })
	q := sqlc.New(pool)
	org := mustCreateOrg(t, ctx, service.NewOrganizationService(q), pool, "Geri Doldurma", "zam-geri-doldurma")
	productID := insertTestProduct(t, pool, org.ID, "Geri Doldurma Ürünü", "adet", "10.00", strPtr(domain.PriceSourceUlas), "")

	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatalf("tx: %v", err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	want := map[string][2]string{
		"":                          {"manual", "<nil>"},
		"ulas":                      {"manual", "<nil>"},
		"Ulaş fiyat listesi (eski)": {"manual", "<nil>"},
		"Demir Profil":              {"manual", "<nil>"},
		"Demir Profil fiyat listesi (Eylül 2026) ek": {"manual", "<nil>"},
	}
	// Kayıt defterindeki her kaynağın notları: bir kaynak eklenir ya da bir
	// not değişirse migration'ın geri doldurması da güncellenmeli.
	for _, info := range domain.PriceSources() {
		want[info.SyncNote] = [2]string{"supplier", info.Code}
		want[info.MarkupNote] = [2]string{"markup", info.Code}
		want[info.RepriceNote] = [2]string{"markup", info.Code}
	}
	// Dönemli senkron notu (yalnızca Demir Profil dönem verir).
	dp, _ := domain.LookupPriceSource(domain.PriceSourceDemirProfil)
	want[dp.SyncHistoryNote("Eylül 2026")] = [2]string{"supplier", domain.PriceSourceDemirProfil}
	if want[domain.PriceHistoryNoteUlasSync] != [2]string{"supplier", "ulas"} || want[domain.PriceHistoryNoteUlasMarkup] != [2]string{"markup", "ulas"} {
		t.Fatalf("Ulaş notları kayıt defterinde değişmiş: %v", want)
	}
	notes := make([]string, 0, len(want))
	for note := range want {
		notes = append(notes, note)
	}
	for _, note := range notes {
		// 0045 dönemindeki INSERT: reason/source verilmez -> varsayılanlar.
		if _, err := tx.Exec(ctx, `INSERT INTO product_price_history (product_id, old_price, new_price, note) VALUES ($1, 1, 2, $2)`, productID, note); err != nil {
			t.Fatalf("eski biçim satır eklenemedi: %v", err)
		}
	}
	for _, stmt := range backfillStatements(t) {
		if _, err := tx.Exec(ctx, stmt); err != nil {
			t.Fatalf("geri doldurma çalışmadı (%s): %v", stmt, err)
		}
	}
	rows, err := tx.Query(ctx, `SELECT note, reason, coalesce(source, '<nil>'), old_source_price IS NULL AND new_source_price IS NULL
		FROM product_price_history WHERE product_id = $1`, productID)
	if err != nil {
		t.Fatalf("okuma: %v", err)
	}
	n := 0
	for rows.Next() {
		var note, reason, source string
		var noSourcePrices bool
		if err := rows.Scan(&note, &reason, &source, &noSourcePrices); err != nil {
			t.Fatalf("satır: %v", err)
		}
		n++
		if w := want[note]; w != [2]string{reason, source} || !noSourcePrices {
			t.Errorf("not %q: reason=%s source=%s, beklenen %v (kaynak fiyatları NULL)", note, reason, source, w)
		}
	}
	rows.Close()
	if n != len(notes) {
		t.Fatalf("%d satır okundu, beklenen %d", n, len(notes))
	}

	// Kısıtlar: reason kümesi, kaynak kümesi, dönem varsayılanı.
	expectCheckViolation := func(sql string, args ...any) {
		t.Helper()
		if _, err := tx.Exec(ctx, "SAVEPOINT kisit"); err != nil {
			t.Fatalf("savepoint: %v", err)
		}
		_, err := tx.Exec(ctx, sql, args...)
		var pgErr *pgconn.PgError
		if !errors.As(err, &pgErr) || pgErr.Code != "23514" {
			t.Fatalf("CHECK ihlali bekleniyordu (%s), geldi %v", sql, err)
		}
		if _, err := tx.Exec(ctx, "ROLLBACK TO SAVEPOINT kisit"); err != nil {
			t.Fatalf("savepoint geri alınamadı: %v", err)
		}
	}
	expectCheckViolation(`INSERT INTO product_price_history (product_id, old_price, new_price, reason) VALUES ($1, 1, 2, 'diger')`, productID)
	expectCheckViolation(`INSERT INTO organization_price_sources (organization_id, source) VALUES ($1, 'bilinmeyen')`, org.ID)
	var label string
	if err := tx.QueryRow(ctx, `INSERT INTO organization_price_sources (organization_id, source) VALUES ($1, 'demirprofil') RETURNING last_list_label`, org.ID).Scan(&label); err != nil || label != "" {
		t.Fatalf("demirprofil kaynağı kabul edilmeli, dönem varsayılanı '': %q %v", label, err)
	}
}
