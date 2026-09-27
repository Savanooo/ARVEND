package middleware_test

// Demir Profil kaynağı ve zam geçmişi uçları gerçek router'a karşı:
//   - GET /products/price-changes(+/summary) products.read ister (403/401),
//     statik yollar "/{id}" tarafından yakalanmaz, firma izolasyonu;
//   - tedarikçi (kaynak) fiyatları yalnızca products.manage'e döner (zam
//     geçmişi ve ürün fiyat geçmişi);
//   - geçersiz parametreler 400, limit 200 ile sınırlanır;
//   - Demir Profil ayar/senkronu products.manage ister; liste dönemi,
//     kaynak gösterimi, KDV notu ve son senkron zamları döner;
//   - kısa liste eşiği 502 + sabit metin.
// Listeler sahte fetcher'lardan gelir -- tedarikçi sitelerine ASLA gidilmez.

import (
	"context"
	"net/http"
	"net/url"
	"strings"
	"testing"

	"github.com/shopspring/decimal"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/pricesource"
)

func TestPriceChangeEndpoints(t *testing.T) {
	d := setupRBACTestRouter(t)
	ctx := context.Background()

	org := mustCreateReadyOrg(t, ctx, d, "price-change-http")
	t.Cleanup(func() { rbacCleanupOrg(t, d.pool, org.Organization.ID) })
	other := mustCreateReadyOrg(t, ctx, d, "price-change-http-other")
	t.Cleanup(func() { rbacCleanupOrg(t, d.pool, other.Organization.ID) })
	orgID := org.Organization.ID
	ownerToken, err := d.issuer.IssueAccessToken(org.Owner.ID, domain.RoleAdmin, orgID)
	if err != nil {
		t.Fatalf("owner token: %v", err)
	}
	otherToken, err := d.issuer.IssueAccessToken(other.Owner.ID, domain.RoleAdmin, other.Organization.ID)
	if err != nil {
		t.Fatalf("other token: %v", err)
	}
	_, pmToken := mustCreateRoleUser(t, ctx, d, orgID, "price_chg_pm", domain.OrgRoleProjectManager)
	_, fieldToken := mustCreateRoleUser(t, ctx, d, orgID, "price_chg_field", domain.OrgRoleField)

	const (
		sourcesPath = "/api/v1/products/price-sources"
		demirPut    = "/api/v1/products/price-sources/demirprofil"
		demirSync   = "/api/v1/products/price-sources/demirprofil/sync"
		changesPath = "/api/v1/products/price-changes"
		summaryPath = "/api/v1/products/price-changes/summary"
		zeroMarkup  = `{"markup_percent":0,"auto_sync":false,"category_markups":[]}`
	)
	item := func(name, price string) pricesource.Item {
		return pricesource.Item{Name: name, Unit: "mt", Category: "Siyah Kutu Profil", Price: decimal.RequireFromString(price), Description: "6 m boy"}
	}

	t.Run("Demir Profil ayar/senkronu products.manage ister", func(t *testing.T) {
		d.demirFetch.setLabel("Eylül 2026")
		d.demirFetch.set(nil, item("Kutu A", "100"), item("Kutu B", "200"))
		for _, token := range []string{pmToken, fieldToken} {
			if rec, _ := rbacDo(t, d.router, http.MethodPut, demirPut, token, zeroMarkup); rec.Code != http.StatusForbidden {
				t.Fatalf("PUT 403 bekleniyordu, geldi %d", rec.Code)
			}
			if rec, _ := rbacDo(t, d.router, http.MethodPost, demirSync, token, ""); rec.Code != http.StatusForbidden {
				t.Fatalf("POST sync 403 bekleniyordu, geldi %d", rec.Code)
			}
		}
		var n int
		if err := d.pool.QueryRow(ctx, "SELECT count(*) FROM products WHERE organization_id = $1", orgID).Scan(&n); err != nil || n != 0 {
			t.Fatalf("reddedilen senkron ürün yazmamalı: %d %v", n, err)
		}

		if rec, body := rbacDo(t, d.router, http.MethodPut, demirPut, ownerToken, zeroMarkup); rec.Code != http.StatusOK || body["recomputed"] != float64(0) {
			t.Fatalf("Sahip PUT: %d %v", rec.Code, body)
		}
		rec, body := rbacDo(t, d.router, http.MethodPost, demirSync, ownerToken, "")
		if rec.Code != http.StatusOK || body["source"] != "demirprofil" || body["created"] != float64(2) || body["list_label"] != "Eylül 2026" {
			t.Fatalf("Sahip senkronu: %d %v", rec.Code, body)
		}
	})

	t.Run("fiyat kaynakları: iki kaynak, dönem/kaynak gösterimi/KDV notu", func(t *testing.T) {
		rec, body := rbacDo(t, d.router, http.MethodGet, sourcesPath, pmToken, "")
		if rec.Code != http.StatusOK {
			t.Fatalf("PM okuyabilmeli: %d", rec.Code)
		}
		dp := sourceFromList(t, body, "demirprofil")
		if dp["name"] != "Demir Profil (Omega Çelik)" || dp["site_url"] != "https://www.demirprofil.com.tr" ||
			dp["vat_note"] != "KDV hariç, toptan liste fiyatı; kesim ve nakliye hariç" || dp["list_label"] != "Eylül 2026" ||
			dp["attribution"] != "Kaynak: demirprofil.com.tr — Eylül 2026 listesi" || dp["last_status"] != "success" || dp["product_count"] != float64(2) {
			t.Fatalf("Demir Profil özeti yanlış: %v", dp)
		}
		if dp["markup_percent"] != nil || dp["category_markups"] != nil {
			t.Fatalf("PM kâr oranını görmemeli: %v", dp)
		}
		lc, ok := dp["last_changes"].(map[string]any)
		if !ok || lc["increased"] != float64(0) || lc["decreased"] != float64(0) || lc["avg_increase_percent"] != nil {
			t.Fatalf("ilk senkronda last_changes sıfır olmalı: %v", dp["last_changes"])
		}
		ul := sourceFromList(t, body, "ulas")
		if ul["vat_note"] != "KDV durumu listede belirtilmiyor" || ul["attribution"] != "" || ul["list_label"] != "" ||
			ul["site_url"] != "https://ulas.com.tr" || ul["last_changes"] != nil {
			t.Fatalf("Ulaş özeti yanlış: %v", ul)
		}
	})

	// Fiyat değişimi: Kutu A 100 -> 110 (+%10), Kutu B 200 -> 150 (-%25).
	d.demirFetch.setLabel("Ekim 2026")
	d.demirFetch.set(nil, item("Kutu A", "110"), item("Kutu B", "150"))
	if rec, body := rbacDo(t, d.router, http.MethodPost, demirSync, ownerToken, ""); rec.Code != http.StatusOK || body["updated"] != float64(2) {
		t.Fatalf("ikinci senkron: %d %v", rec.Code, body)
	}

	t.Run("zam geçmişi products.read ister; statik yol /{id}'ye düşmez", func(t *testing.T) {
		for _, path := range []string{changesPath, summaryPath} {
			if rec, body := rbacDo(t, d.router, http.MethodGet, path, fieldToken, ""); rec.Code != http.StatusForbidden || body["code"] != "permission_denied" {
				t.Fatalf("%s: products.read olmayan 403 almalı: %d %v", path, rec.Code, body)
			}
			if rec, _ := rbacDo(t, d.router, http.MethodGet, path, "", ""); rec.Code != http.StatusUnauthorized {
				t.Fatalf("%s: oturumsuz 401 almalı: %d", path, rec.Code)
			}
			if rec, _ := rbacDo(t, d.router, http.MethodGet, path, pmToken, ""); rec.Code != http.StatusOK {
				t.Fatalf("%s: products.read olan PM okuyabilmeli (statik yol /{id}'ye mi düştü?): %d %s", path, rec.Code, rec.Body.String())
			}
		}
	})

	t.Run("liste: kaynak fiyatları yalnızca products.manage'e", func(t *testing.T) {
		rec, body := rbacDo(t, d.router, http.MethodGet, changesPath+"?direction=all&source=demirprofil", ownerToken, "")
		changes, _ := body["changes"].([]any)
		if rec.Code != http.StatusOK || len(changes) != 2 || body["total"] != float64(2) || body["page"] != float64(1) || body["limit"] != float64(50) {
			t.Fatalf("Sahip listesi: %d %v", rec.Code, body)
		}
		var up map[string]any
		for _, c := range changes {
			if m := c.(map[string]any); m["product_name"] == "Kutu A" {
				up = m
			}
		}
		if up == nil || up["reason"] != "supplier" || up["source"] != "demirprofil" || up["old_price"] != float64(100) ||
			up["new_price"] != float64(110) || up["change_amount"] != float64(10) || up["change_percent"] != float64(10) ||
			up["old_source_price"] != float64(100) || up["new_source_price"] != float64(110) || up["unit"] != "mt" ||
			up["category"] != "Siyah Kutu Profil" || up["note"] != "Demir Profil fiyat listesi (Ekim 2026)" || up["changed_at"] == "" {
			t.Fatalf("Sahip zam satırı yanlış: %v", up)
		}

		rec, body = rbacDo(t, d.router, http.MethodGet, changesPath+"?direction=all", pmToken, "")
		changes, _ = body["changes"].([]any)
		if rec.Code != http.StatusOK || len(changes) != 2 {
			t.Fatalf("PM listesi: %d %v", rec.Code, body)
		}
		for _, c := range changes {
			m := c.(map[string]any)
			if _, ok := m["old_source_price"]; !ok || m["old_source_price"] != nil || m["new_source_price"] != nil {
				t.Fatalf("PM kaynak fiyatlarını görmemeli: %v", m)
			}
			if m["old_price"] == nil || m["new_price"] == nil {
				t.Fatalf("PM satış fiyatlarını görmeli: %v", m)
			}
		}

		// Varsayılan: yalnızca zamlar (Kutu A); limit 200 ile sınırlanır.
		rec, body = rbacDo(t, d.router, http.MethodGet, changesPath+"?limit=1000&sort=largest_increase", pmToken, "")
		changes, _ = body["changes"].([]any)
		if rec.Code != http.StatusOK || len(changes) != 1 || body["limit"] != float64(200) {
			t.Fatalf("varsayılan/limit yanlış: %d %v", rec.Code, body)
		}
	})

	t.Run("ürün fiyat geçmişi: reason/source herkese, kaynak fiyatı yalnızca products.manage'e", func(t *testing.T) {
		var productID string
		if err := d.pool.QueryRow(ctx, `SELECT id::text FROM products WHERE organization_id = $1 AND name = 'Kutu A'`, orgID).Scan(&productID); err != nil {
			t.Fatalf("ürün: %v", err)
		}
		path := "/api/v1/products/" + productID + "/price-history"
		_, body := rbacDo(t, d.router, http.MethodGet, path, ownerToken, "")
		hist, _ := body["history"].([]any)
		if len(hist) != 1 || hist[0].(map[string]any)["reason"] != "supplier" || hist[0].(map[string]any)["source"] != "demirprofil" ||
			hist[0].(map[string]any)["new_source_price"] != float64(110) {
			t.Fatalf("Sahip ürün geçmişi yanlış: %v", body)
		}
		_, body = rbacDo(t, d.router, http.MethodGet, path, pmToken, "")
		hist, _ = body["history"].([]any)
		if len(hist) != 1 || hist[0].(map[string]any)["reason"] != "supplier" || hist[0].(map[string]any)["new_source_price"] != nil ||
			hist[0].(map[string]any)["old_source_price"] != nil {
			t.Fatalf("PM ürün geçmişinde kaynak fiyatı gizli olmalı: %v", body)
		}
	})

	t.Run("özet ve son senkron zamları", func(t *testing.T) {
		rec, body := rbacDo(t, d.router, http.MethodGet, summaryPath+"?source=demirprofil", pmToken, "")
		if rec.Code != http.StatusOK || body["increased_count"] != float64(1) || body["decreased_count"] != float64(1) ||
			body["products_increased"] != float64(1) || body["avg_increase_percent"] != float64(10) {
			t.Fatalf("özet yanlış: %d %v", rec.Code, body)
		}
		maxInc, _ := body["max_increase"].(map[string]any)
		if maxInc["product_name"] != "Kutu A" || maxInc["change_percent"] != float64(10) || maxInc["product_id"] == "" {
			t.Fatalf("max_increase yanlış: %v", body["max_increase"])
		}
		events, _ := body["events"].([]any)
		if len(events) != 1 {
			t.Fatalf("tek olay bekleniyordu: %v", body["events"])
		}
		ev := events[0].(map[string]any)
		if ev["source"] != "demirprofil" || ev["reason"] != "supplier" || ev["change_count"] != float64(2) || ev["increased"] != float64(1) ||
			ev["decreased"] != float64(1) || ev["avg_change_percent"] != -7.5 || ev["max_increase_percent"] != float64(10) {
			t.Fatalf("olay yanlış: %v", ev)
		}
		// Olayın from/to'su (senkron olayında ikisi de changed_at) + reason +
		// source ile liste birebir süzülür.
		if ev["from"] != ev["changed_at"] || ev["to"] != ev["changed_at"] {
			t.Fatalf("senkron olayının aralığı tek an olmalı: %v", ev)
		}
		_, list := rbacDo(t, d.router, http.MethodGet, changesPath+"?direction=all&reason=supplier&source=demirprofil&from="+
			url.QueryEscape(ev["from"].(string))+"&to="+url.QueryEscape(ev["to"].(string)), pmToken, "")
		if list["total"] != float64(2) {
			t.Fatalf("olay aralığıyla süzme 2 satır döndürmeli: %v", list)
		}

		_, body = rbacDo(t, d.router, http.MethodGet, sourcesPath, pmToken, "")
		dp := sourceFromList(t, body, "demirprofil")
		lc, _ := dp["last_changes"].(map[string]any)
		if dp["list_label"] != "Ekim 2026" || lc["increased"] != float64(1) || lc["decreased"] != float64(1) || lc["avg_increase_percent"] != float64(10) {
			t.Fatalf("son senkron zamları yanlış: %v", dp)
		}
	})

	t.Run("geçersiz parametreler 400", func(t *testing.T) {
		for _, qs := range []string{
			"direction=yukari", "reason=hepsi", "source=bilinmeyen", "sort=fiyat",
			"from=2026-13-01", "to=dun", "from=2026-09-10&to=2026-09-01",
			"page=0", "page=abc", "page=-1", "limit=0", "limit=abc", "limit=-5", "page=100001",
			"q=" + strings.Repeat("a", 101),
			// PostgreSQL'in reddettiği metinler (geçersiz UTF-8, NUL) 500 değil 400.
			"category=%FF", "category=a%00b", "q=a%00b", "q=%C3%28",
		} {
			if rec, body := rbacDo(t, d.router, http.MethodGet, changesPath+"?"+qs, ownerToken, ""); rec.Code != http.StatusBadRequest || body["error"] == "" {
				t.Fatalf("%s: 400 bekleniyordu, geldi %d %v", qs, rec.Code, body)
			}
		}
		for _, qs := range []string{"reason=x", "source=x", "from=bad", "from=2026-09-10&to=2026-09-01"} {
			if rec, _ := rbacDo(t, d.router, http.MethodGet, summaryPath+"?"+qs, ownerToken, ""); rec.Code != http.StatusBadRequest {
				t.Fatalf("özet %s: 400 bekleniyordu, geldi %d", qs, rec.Code)
			}
		}
		// Geçerli tarih biçimleri.
		for _, qs := range []string{"from=2026-01-01&to=2030-12-31", "from=" + url.QueryEscape("2026-01-01T00:00:00+03:00")} {
			if rec, _ := rbacDo(t, d.router, http.MethodGet, changesPath+"?"+qs, ownerToken, ""); rec.Code != http.StatusOK {
				t.Fatalf("%s: 200 bekleniyordu, geldi %d", qs, rec.Code)
			}
		}
	})

	t.Run("firma izolasyonu", func(t *testing.T) {
		rec, body := rbacDo(t, d.router, http.MethodGet, changesPath+"?direction=all&reason=all", otherToken, "")
		if rec.Code != http.StatusOK || body["total"] != float64(0) {
			t.Fatalf("başka firma bu firmanın değişikliklerini görmemeli: %d %v", rec.Code, body)
		}
		_, body = rbacDo(t, d.router, http.MethodGet, summaryPath+"?reason=all", otherToken, "")
		if body["increased_count"] != float64(0) || body["max_increase"] != nil || len(body["events"].([]any)) != 0 {
			t.Fatalf("başka firmanın özeti boş olmalı: %v", body)
		}
	})

	t.Run("kısa liste eşiği: 502, fiyatlar değişmez", func(t *testing.T) {
		d.demirFetch.set(nil) // boş: fetch hatası
		if rec, _ := rbacDo(t, d.router, http.MethodPost, demirSync, ownerToken, ""); rec.Code != http.StatusBadGateway {
			t.Fatalf("boş liste 502 bekleniyordu: %d", rec.Code)
		}
		// Eşik: son başarılı senkron 3 ürün -> 1 ürünlük liste (< 3/2) uygulanmaz.
		d.demirFetch.set(nil, item("Kutu A", "110"), item("Kutu B", "150"), item("Kutu C", "10"))
		if rec, _ := rbacDo(t, d.router, http.MethodPost, demirSync, ownerToken, ""); rec.Code != http.StatusOK {
			t.Fatalf("senkron: %d", rec.Code)
		}
		d.demirFetch.set(nil, item("Kutu A", "999"))
		rec, body := rbacDo(t, d.router, http.MethodPost, demirSync, ownerToken, "")
		if rec.Code != http.StatusBadGateway || body["error"] != domain.ErrPriceListTooShort.Error() {
			t.Fatalf("kısa liste 502 + sabit metin bekleniyordu: %d %v", rec.Code, body)
		}
		_, body = rbacDo(t, d.router, http.MethodGet, sourcesPath, pmToken, "")
		dp := sourceFromList(t, body, "demirprofil")
		if dp["last_status"] != "failed" || !strings.Contains(dp["last_error"].(string), "liste beklenenden çok kısa geldi; fiyatlar değiştirilmedi") {
			t.Fatalf("kısa liste kaydedilmeli: %v", dp)
		}
		var price string
		if err := d.pool.QueryRow(ctx, `SELECT unit_price::text FROM products WHERE organization_id = $1 AND name = 'Kutu A'`, orgID).Scan(&price); err != nil || price != "110.00" {
			t.Fatalf("kısa liste fiyatı değiştirmemeli: %s %v", price, err)
		}
	})
}
