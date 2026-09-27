package middleware_test

// Tedarikçi fiyat kaynağı uçları (GET/PUT /products/price-sources, POST
// .../sync) gerçek router'a karşı: kim okuyabilir/değiştirebilir, kâr
// oranı ve kaynak fiyatı yalnızca products.manage'e döner, statik
// "/price-sources" yolu "/{id}" tarafından yakalanmaz, hata kodları
// (404/400/409/502). Fiyat listesi sahte fetcher'dan gelir -- ulas.com.tr'ye
// ASLA istek gitmez.

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/shopspring/decimal"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/pricesource"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

type stubPriceFetcher struct {
	mu    sync.Mutex
	items []pricesource.Item
	label string
	err   error
}

func (f *stubPriceFetcher) set(err error, items ...pricesource.Item) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.items, f.err = items, err
}

func (f *stubPriceFetcher) setLabel(label string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.label = label
}

func (f *stubPriceFetcher) fetch(context.Context) (pricesource.List, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.err != nil {
		return pricesource.List{}, f.err
	}
	return pricesource.List{Items: append([]pricesource.Item(nil), f.items...), Label: f.label}, nil
}

func TestPriceSourceEndpoints(t *testing.T) {
	d := setupRBACTestRouter(t)
	ctx := context.Background()

	org := mustCreateReadyOrg(t, ctx, d, "price-src-http")
	t.Cleanup(func() { rbacCleanupOrg(t, d.pool, org.Organization.ID) })
	orgID := org.Organization.ID
	ownerToken, err := d.issuer.IssueAccessToken(org.Owner.ID, domain.RoleAdmin, orgID)
	if err != nil {
		t.Fatalf("owner token: %v", err)
	}
	_, pmToken := mustCreateRoleUser(t, ctx, d, orgID, "price_src_pm", domain.OrgRoleProjectManager)
	_, fieldToken := mustCreateRoleUser(t, ctx, d, orgID, "price_src_field", domain.OrgRoleField)

	const (
		listPath = "/api/v1/products/price-sources"
		putPath  = "/api/v1/products/price-sources/ulas"
		syncPath = "/api/v1/products/price-sources/ulas/sync"
		putBody  = `{"markup_percent":20,"auto_sync":true,"category_markups":[{"category":"ÇATI MALZEMELERİ","markup_percent":12.5}]}`
	)
	d.priceFetch.set(nil,
		pricesource.Item{Name: "Sandviç Panel Sac", Unit: "m2", Category: "ÇATI MALZEMELERİ", Price: decimal.RequireFromString("500")},
		pricesource.Item{Name: "Perlitli Alçı", Unit: "torba", Category: "ALÇILAR", Price: decimal.RequireFromString("333.33")},
	)

	firstSource := func(t *testing.T, body map[string]any) map[string]any {
		t.Helper()
		return sourceFromList(t, body, "ulas")
	}

	t.Run("okuma: products.read yeterli, kâr oranları yalnızca products.manage'e", func(t *testing.T) {
		rec, body := rbacDo(t, d.router, http.MethodGet, listPath, ownerToken, "")
		if rec.Code != http.StatusOK {
			t.Fatalf("Sahip okuyamadı (statik yol /{id}'ye mi düştü?): %d %s", rec.Code, rec.Body.String())
		}
		src := firstSource(t, body)
		if src["markup_percent"] != float64(15) || src["auto_sync"] != false || src["last_status"] != "never" {
			t.Fatalf("varsayılanlar yanlış: %v", src)
		}
		if cms, ok := src["category_markups"].([]any); !ok || len(cms) != 0 {
			t.Fatalf("Sahip için category_markups boş liste olmalı: %v", src["category_markups"])
		}

		rec, body = rbacDo(t, d.router, http.MethodGet, listPath, pmToken, "")
		if rec.Code != http.StatusOK {
			t.Fatalf("products.read olan Proje Yöneticisi okuyabilmeli: %d", rec.Code)
		}
		src = firstSource(t, body)
		if src["markup_percent"] != nil || src["category_markups"] != nil {
			t.Fatalf("products.manage olmadan kâr oranları gizlenmeli: %v", src)
		}

		rec, body = rbacDo(t, d.router, http.MethodGet, listPath, fieldToken, "")
		if rec.Code != http.StatusForbidden || body["code"] != "permission_denied" {
			t.Fatalf("products.read olmayan Saha 403 almalı: %d %v", rec.Code, body)
		}
		if rec, _ := rbacDo(t, d.router, http.MethodGet, listPath, "", ""); rec.Code != http.StatusUnauthorized {
			t.Fatalf("oturumsuz istek 401 almalı: %d", rec.Code)
		}
	})

	t.Run("yazma: products.manage olmayan PUT/POST 403", func(t *testing.T) {
		for _, token := range []string{pmToken, fieldToken} {
			if rec, _ := rbacDo(t, d.router, http.MethodPut, putPath, token, putBody); rec.Code != http.StatusForbidden {
				t.Fatalf("PUT 403 bekleniyordu, geldi %d", rec.Code)
			}
			if rec, _ := rbacDo(t, d.router, http.MethodPost, syncPath, token, ""); rec.Code != http.StatusForbidden {
				t.Fatalf("POST sync 403 bekleniyordu, geldi %d", rec.Code)
			}
		}
		var n int
		if err := d.pool.QueryRow(ctx, "SELECT count(*) FROM organization_price_sources WHERE organization_id = $1", orgID).Scan(&n); err != nil || n != 0 {
			t.Fatalf("reddedilen istekler ayar yazmamalı: %d %v", n, err)
		}
	})

	t.Run("Sahip senkronu: sahte liste uygulanır, sayılar döner", func(t *testing.T) {
		rec, body := rbacDo(t, d.router, http.MethodPost, syncPath, ownerToken, "")
		if rec.Code != http.StatusOK {
			t.Fatalf("senkron başarısız: %d %s", rec.Code, rec.Body.String())
		}
		if body["source"] != "ulas" || body["total"] != float64(2) || body["created"] != float64(2) ||
			body["updated"] != float64(0) || body["unchanged"] != float64(0) || body["missing"] != float64(0) || body["synced_at"] == "" {
			t.Fatalf("senkron yanıtı yanlış: %v", body)
		}
	})

	t.Run("ürün JSON'u: source/source_synced_at herkese, source_price yalnızca products.manage'e", func(t *testing.T) {
		find := func(t *testing.T, token string) map[string]any {
			t.Helper()
			rec, body := rbacDo(t, d.router, http.MethodGet, "/api/v1/products/?q=sandvic", token, "")
			if rec.Code != http.StatusOK {
				t.Fatalf("ürün listesi: %d", rec.Code)
			}
			products, _ := body["products"].([]any)
			if len(products) != 1 {
				t.Fatalf("tek ürün bekleniyordu: %v", body)
			}
			return products[0].(map[string]any)
		}
		owner := find(t, ownerToken)
		if owner["source"] != "ulas" || owner["source_synced_at"] == nil || owner["source_price"] != float64(500) ||
			owner["unit_price"] != float64(575) || owner["category"] != "ÇATI MALZEMELERİ" {
			t.Fatalf("Sahip ürün yanıtı yanlış: %v", owner)
		}
		pm := find(t, pmToken)
		if pm["source"] != "ulas" || pm["source_synced_at"] == nil || pm["source_price"] != nil {
			t.Fatalf("PM kaynak fiyatını görmemeli: %v", pm)
		}
		rec, body := rbacDo(t, d.router, http.MethodGet, "/api/v1/products/"+owner["id"].(string), pmToken, "")
		if rec.Code != http.StatusOK || body["source_price"] != nil || body["source"] != "ulas" {
			t.Fatalf("PM ürün detayında kaynak fiyatı gizli olmalı: %d %v", rec.Code, body)
		}
		if rec, _ := rbacDo(t, d.router, http.MethodGet, "/api/v1/products/", fieldToken, ""); rec.Code != http.StatusForbidden {
			t.Fatalf("Saha ürün listesini görememeli: %d", rec.Code)
		}
	})

	t.Run("Sahip ayar günceller: yeniden fiyatlama sayısı ve yeni oranlar döner", func(t *testing.T) {
		rec, body := rbacDo(t, d.router, http.MethodPut, putPath, ownerToken, putBody)
		if rec.Code != http.StatusOK {
			t.Fatalf("PUT başarısız: %d %s", rec.Code, rec.Body.String())
		}
		ps, _ := body["price_source"].(map[string]any)
		// Sandviç 500 @ %12.5 (kategori) = 562.50; Perlitli 333.33 @ %20 = 400.00.
		if body["recomputed"] != float64(2) || ps["markup_percent"] != float64(20) || ps["auto_sync"] != true {
			t.Fatalf("PUT yanıtı yanlış: %v", body)
		}
		cms, _ := ps["category_markups"].([]any)
		if len(cms) != 1 || cms[0].(map[string]any)["markup_percent"] != float64(12.5) {
			t.Fatalf("kategori oranı dönmedi: %v", ps)
		}
		rec, body = rbacDo(t, d.router, http.MethodGet, "/api/v1/products/?q=sandvic", ownerToken, "")
		products, _ := body["products"].([]any)
		if rec.Code != http.StatusOK || len(products) != 1 || products[0].(map[string]any)["unit_price"] != float64(562.5) {
			t.Fatalf("yeniden fiyatlama yansımadı: %v", body)
		}
		// PM ayarları okur ama oranları göremez.
		_, body = rbacDo(t, d.router, http.MethodGet, listPath, pmToken, "")
		if src := firstSource(t, body); src["markup_percent"] != nil || src["auto_sync"] != true || src["product_count"] != float64(2) {
			t.Fatalf("PM özeti yanlış: %v", src)
		}
	})

	t.Run("hatalar: bilinmeyen kaynak 404, geçersiz gövde 400, indirme hatası 502, meşgul 409", func(t *testing.T) {
		if rec, _ := rbacDo(t, d.router, http.MethodPut, "/api/v1/products/price-sources/bilinmeyen", ownerToken, putBody); rec.Code != http.StatusNotFound {
			t.Fatalf("bilinmeyen kaynak PUT 404 bekleniyordu, geldi %d", rec.Code)
		}
		if rec, _ := rbacDo(t, d.router, http.MethodPost, "/api/v1/products/price-sources/bilinmeyen/sync", ownerToken, ""); rec.Code != http.StatusNotFound {
			t.Fatalf("bilinmeyen kaynak sync 404 bekleniyordu, geldi %d", rec.Code)
		}
		for _, body := range []string{
			`{"markup_percent":1000.01,"auto_sync":false,"category_markups":[]}`,
			`{"markup_percent":-1,"auto_sync":false,"category_markups":[]}`,
			`{"markup_percent":12.345,"auto_sync":false,"category_markups":[]}`,
			`{"auto_sync":false,"category_markups":[]}`,
			`{"markup_percent":10,"category_markups":[]}`,
			`{"markup_percent":10,"auto_sync":false}`,
			`{"markup_percent":10,"auto_sync":false,"category_markups":[{"category":"","markup_percent":5}]}`,
			`{"markup_percent":10,"auto_sync":false,"category_markups":[{"category":"A"}]}`,
			`{"markup_percent":"abc","auto_sync":false,"category_markups":[]}`,
			`{"markup_percent":10,"auto_sync":false,"category_markups":[],"bilinmeyen":1}`,
			// Aşırı üslü sayılar: decimal bunları kabul eder, karşılaştırma
			// 10^|üs|'lük big.Int kurardı -- aritmetikten ÖNCE 400.
			`{"markup_percent":1e2147483647,"auto_sync":false,"category_markups":[]}`,
			`{"markup_percent":1e-2147483648,"auto_sync":false,"category_markups":[]}`,
			`{"markup_percent":0e2147483647,"auto_sync":false,"category_markups":[]}`,
			`{"markup_percent":10,"auto_sync":false,"category_markups":[{"category":"A","markup_percent":1e-2000000000}]}`,
			// Gövde boyut sınırı (256 KiB).
			`{"markup_percent":10,"auto_sync":false,"category_markups":[{"category":"` + strings.Repeat("A", 300<<10) + `","markup_percent":5}]}`,
		} {
			start := time.Now()
			if rec, parsed := rbacDo(t, d.router, http.MethodPut, putPath, ownerToken, body); rec.Code != http.StatusBadRequest || parsed["error"] == "" {
				t.Fatalf("%.120s: 400 bekleniyordu, geldi %d %v", body, rec.Code, parsed)
			}
			if el := time.Since(start); el > 2*time.Second {
				t.Fatalf("%.120s: 400 yanıtı %s sürdü (aşırı üs aritmetikten önce reddedilmeli)", body, el)
			}
		}

		d.priceFetch.set(&pricesource.HTTPStatusError{StatusCode: 503})
		rec, body := rbacDo(t, d.router, http.MethodPost, syncPath, ownerToken, "")
		if rec.Code != http.StatusBadGateway || body["error"] != domain.ErrPriceSourceFetch.Error() {
			t.Fatalf("indirme hatası 502 bekleniyordu: %d %v", rec.Code, body)
		}
		_, body = rbacDo(t, d.router, http.MethodGet, listPath, ownerToken, "")
		if src := firstSource(t, body); src["last_status"] != "failed" || src["last_error"] != "Ulaş sunucusu HTTP 503 döndü" {
			t.Fatalf("başarısız deneme kaydedilmeli: %v", src)
		}
		// Ham ağ hatasının iç ayrıntısı products.read sahibine (PM) sızmaz.
		d.priceFetch.set(errors.New("Get \"https://ulas.com.tr/flist.asp\": proxyconnect tcp: dial tcp 10.1.2.3:3128: connect: connection refused"))
		if rec, _ := rbacDo(t, d.router, http.MethodPost, syncPath, ownerToken, ""); rec.Code != http.StatusBadGateway {
			t.Fatalf("indirme hatası 502 bekleniyordu: %d", rec.Code)
		}
		_, body = rbacDo(t, d.router, http.MethodGet, listPath, pmToken, "")
		if src := firstSource(t, body); strings.Contains(src["last_error"].(string), "10.1.2.3") || src["last_error"] == "" {
			t.Fatalf("last_error sabit metin olmalı: %v", src["last_error"])
		}

		d.priceFetch.set(nil, pricesource.Item{Name: "Sandviç Panel Sac", Unit: "m2", Category: "ÇATI MALZEMELERİ", Price: decimal.RequireFromString("500")})
		tx, err := d.pool.Begin(ctx)
		if err != nil {
			t.Fatalf("tx: %v", err)
		}
		defer tx.Rollback(ctx) //nolint:errcheck
		class, key := service.PriceSyncAdvisoryLock(orgID, domain.PriceSourceUlas)
		if _, err := tx.Exec(ctx, "SELECT pg_advisory_xact_lock($1, hashtext($2))", class, key); err != nil {
			t.Fatalf("kilit: %v", err)
		}
		if rec, _ := rbacDo(t, d.router, http.MethodPost, syncPath, ownerToken, ""); rec.Code != http.StatusConflict {
			t.Fatalf("eşzamanlı senkron 409 bekleniyordu, geldi %d", rec.Code)
		}
	})
}

// sourceFromList: GET /products/price-sources yanıtı kayıt defterindeki
// iki kaynağı sabit sırayla (ulas, demirprofil) döner; istenen seçilir.
func sourceFromList(t *testing.T, body map[string]any, source string) map[string]any {
	t.Helper()
	list, ok := body["sources"].([]any)
	if !ok || len(list) != 2 || list[0].(map[string]any)["source"] != "ulas" || list[1].(map[string]any)["source"] != "demirprofil" {
		t.Fatalf("sources listesi [ulas, demirprofil] bekleniyordu: %v", body)
	}
	for _, item := range list {
		if src := item.(map[string]any); src["source"] == source {
			return src
		}
	}
	t.Fatalf("%s kaynağı yok: %v", source, body)
	return nil
}
