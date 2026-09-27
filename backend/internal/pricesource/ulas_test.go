package pricesource

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strings"
	"testing"

	"github.com/shopspring/decimal"
)

func mustOpen(t *testing.T, path string) *os.File {
	t.Helper()
	f, err := os.Open(path)
	if err != nil {
		t.Fatalf("fixture açılamadı: %v", err)
	}
	t.Cleanup(func() { f.Close() })
	return f
}

func TestParseUlasFixture(t *testing.T) {
	items, err := ParseUlas(mustOpen(t, "testdata/ulas_flist_fixture.html"))
	if err != nil {
		t.Fatalf("ayrıştırma hatası: %v", err)
	}
	const cati, alci, sandvic = "ÇATI MALZEMELERİ", "ALÇILAR VE PROFİLLERİ", "SANDVİÇ PANEL"
	want := []struct{ name, unit, category, price string }{
		// Henüz ürün yokken 2 hücreli satır: ad = açıklama.
		{"Serbest Varyant Satırı", "adet", cati, "15"},
		{"Sandviç Panel Sac", "m2", cati, "500"},
		{"Alüminyum Sandviç Panel (alm+alm+18 dns eps)", "m2", cati, "1200"},
		{"Alüminyum Sandviç Panel (sac+sac+18 dns eps)", "m2", cati, "5400"},
		{"Onduline", "adet", cati, "1200.5"},
		{"Dekor Silteks Dış Cephe Rulo", "adet", cati, "12.5"},
		// "&nbsp;" ayırıcı satırı kategoriyi SIFIRLAMAZ.
		{"Birimsiz Vida", "adet", cati, "0.13"},
		// Fiyatsız üst satır eklenmez; açıklaması boş varyant onun adını alır.
		{"Mahya Kiremidi", "adet", cati, "25"},
		{"Perlitli Sıva Alçısı 25 kg", "torba", alci, "7.5"},
		{"Profil Paketi", "paket", alci, "1234567"},
		{"Perlitli Sıva Alçısı 25 kg", "palet", alci, "350"},
		{"Köşe Profili (25x25)", "mt", alci, "30"},
		{"Köşe Profili (30x30)", "mt", alci, "35.75"},
		// 3 hücreli üst satırın varyantları: ad VE birim ("rulo") ondan.
		{"Alüminyum Folyo Bant 48mm", "rulo", alci, "40"},
		{"Alüminyum Folyo Bant 48mm (15x10m)", "rulo", alci, "41"},
		{"Alüminyum Folyo Bant 48mm (25x50m)", "rulo", alci, "1200"}, // "1&nbsp;200"
		// Aynı ad+birim başka kategoride: ayrı ürün.
		{"Sandviç Panel Sac", "m2", sandvic, "480"},
	}
	if len(items) != len(want) {
		for _, it := range items {
			t.Logf("%q %q %q %s", it.Name, it.Unit, it.Category, it.Price)
		}
		t.Fatalf("ürün sayısı = %d, beklenen %d", len(items), len(want))
	}
	for i, w := range want {
		got := items[i]
		if got.Name != w.name || got.Unit != w.unit || got.Category != w.category || !got.Price.Equal(decimal.RequireFromString(w.price)) {
			t.Errorf("#%d = {%q %q %q %s}, beklenen {%q %q %q %s}", i,
				got.Name, got.Unit, got.Category, got.Price, w.name, w.unit, w.category, w.price)
		}
	}
}

func TestParsePrice(t *testing.T) {
	valid := map[string]string{
		"500 TL":            "500",
		"500TL":             "500",
		"1.200 TL":          "1200",
		"1.200,50 TL":       "1200.5",
		"12.345.678 TL":     "12345678",
		"12,5 TL":           "12.5",
		"7.5 TL":            "7.5", // üç hane yoksa nokta ondalıktır (BYZ ile aynı)
		"1200,50":           "1200.5",
		"0,125 TL":          "0.13", // yarım yukarı
		"0,005":             "0.01",
		"\u00a0250\u00a0TL": "250",
		"1\u00a0200 TL":     "1200", // NBSP binlik ay\u0131r\u0131c\u0131 (BYZ ile ayn\u0131)
		"1\u00a0200,50 TL":  "1200.5",
	}
	for in, want := range valid {
		got, ok := ParsePrice(in)
		if !ok || !got.Equal(decimal.RequireFromString(want)) {
			t.Errorf("ParsePrice(%q) = %s,%v; beklenen %s", in, got, ok, want)
		}
	}
	for _, in := range []string{"", "TL", "0 TL", "0,00", "0,004", "-5 TL", "Fiyat Sorunuz", "1e5", "inf", "NaN",
		"1 200 TL", "12,5,0", "1.2.3", "10000000000000 TL"} {
		if got, ok := ParsePrice(in); ok {
			t.Errorf("ParsePrice(%q) = %s geçerli sayıldı, reddedilmeliydi", in, got)
		}
	}
}

func TestParseUlasTruncatesToColumnLimits(t *testing.T) {
	longName := strings.Repeat("Ş", MaxNameLen+20)
	longUnit := strings.Repeat("ü", MaxUnitLen+5)
	longCat := strings.Repeat("İ", MaxCategoryLen+5)
	page := `<table><tr><td>Ürün</td></tr>
		<tr><th>` + longCat + `</th></tr>
		<tr><td>` + longName + `</td><td>` + longUnit + `</td><td>10 TL</td></tr>
		<tr><td>` + longName + `X</td><td>` + longUnit + `</td><td>20 TL</td></tr>
	</table>`
	items, err := ParseUlas(strings.NewReader(page))
	if err != nil {
		t.Fatalf("ayrıştırma hatası: %v", err)
	}
	// İkinci satır kısaltıldıktan sonra ilkiyle AYNI anahtara düşer -> tekrar.
	if len(items) != 1 {
		t.Fatalf("ürün sayısı = %d, beklenen 1", len(items))
	}
	it := items[0]
	if n := len([]rune(it.Name)); n != MaxNameLen || it.Name != strings.Repeat("Ş", MaxNameLen) {
		t.Errorf("ad %d karaktere kısaltılmalıydı, %d", MaxNameLen, n)
	}
	if n := len([]rune(it.Unit)); n != MaxUnitLen {
		t.Errorf("birim %d karaktere kısaltılmalıydı, %d", MaxUnitLen, n)
	}
	if n := len([]rune(it.Category)); n != MaxCategoryLen {
		t.Errorf("kategori %d karaktere kısaltılmalıydı, %d", MaxCategoryLen, n)
	}
}

// TestParseUlasSkipsHeaderRow: ilk satır, fiyat gibi ayrıştırılabilse bile
// başlıktır (gerçek başlığın "Fiyat" hücresi zaten ayrıştırılamadığı için
// fixture bunu kanıtlayamaz).
func TestParseUlasSkipsHeaderRow(t *testing.T) {
	page := `<table>
		<tr><td>Başlık Gibi Ürün</td><td></td><td>adet</td><td>1 TL</td></tr>
		<tr><th>KATEGORİ</th></tr>
		<tr><td>Gerçek Ürün</td><td>adet</td><td>5 TL</td></tr>
	</table>`
	items, err := ParseUlas(strings.NewReader(page))
	if err != nil {
		t.Fatalf("ayrıştırma hatası: %v", err)
	}
	if len(items) != 1 || items[0].Name != "Gerçek Ürün" {
		t.Fatalf("ilk satır atlanmalıydı: %+v", items)
	}
}

// TestParseUlasNBSPOnlyInPriceCell: NBSP yalnızca fiyat hücresinde silinir;
// ad/kategori hücrelerinde kelime ayırıcı olarak kalır.
func TestParseUlasNBSPOnlyInPriceCell(t *testing.T) {
	page := `<table><tr><td>Ürün</td><td></td><td>Birim</td><td>Fiyat</td></tr>
		<tr><th colspan=4>KAT&nbsp;A</th></tr>
		<tr><td colspan=2>Panel&nbsp;A</td><td>m2</td><td><span class="fyt">1&nbsp;200</span> <small><b>TL</b></small></td></tr>
		<tr><td colspan=2>Panel B</td><td>m2</td><td><span class="fyt">1 200</span> <small><b>TL</b></small></td></tr>
		<tr><td colspan=2>Panel C</td><td>m2</td><td><span class="fyt">500</span> <small><b>TL</b></small></td></tr>
	</table>`
	items, err := ParseUlas(strings.NewReader(page))
	if err != nil {
		t.Fatalf("ayrıştırma hatası: %v", err)
	}
	// "1 200" (düz boşluk) BYZ'de de geçersizdi -> Panel B atlanır.
	if len(items) != 2 || items[0].Name != "Panel A" || items[0].Category != "KAT A" ||
		!items[0].Price.Equal(decimal.NewFromInt(1200)) || items[1].Name != "Panel C" {
		t.Fatalf("beklenmeyen sonuç: %+v", items)
	}
}

func TestParseUlasRejectsEmptyPages(t *testing.T) {
	cases := map[string]error{
		`<html><body><p>Bakımdayız</p></body></html>`:                                       ErrNoTable,
		`<table><tr><td>Ürün</td><td></td><td>Birim</td><td>Fiyat</td></tr></table>`:        ErrNoItems,
		`<table><tr><td>Ürün</td></tr><tr><td>A</td><td>adet</td><td>yok</td></tr></table>`: ErrNoItems,
		``: ErrNoTable,
	}
	for page, want := range cases {
		items, err := ParseUlas(strings.NewReader(page))
		if !errors.Is(err, want) || items != nil {
			t.Errorf("sayfa %q: err=%v items=%d, beklenen %v", page, err, len(items), want)
		}
	}
}

// TestParseUlasRealSnapshot, gerçek sayfanın yerel bir kopyasıyla (repo'ya
// EKLENMEZ) isteğe bağlı bir akıl sağlığı kontrolüdür:
// ULAS_FLIST_SNAPSHOT=/yol/ulas_flist.html go test ./internal/pricesource/
func TestParseUlasRealSnapshot(t *testing.T) {
	path := os.Getenv("ULAS_FLIST_SNAPSHOT")
	if path == "" {
		t.Skip("ULAS_FLIST_SNAPSHOT ayarlanmamış, atlanıyor")
	}
	items, err := ParseUlas(mustOpen(t, path))
	if err != nil {
		t.Fatalf("ayrıştırma hatası: %v", err)
	}
	cats := map[string]int{}
	seen := map[[3]string]bool{}
	byNameUnit := map[[2]string][]Item{}
	for _, it := range items {
		key := [3]string{it.Name, it.Unit, it.Category}
		if seen[key] {
			t.Errorf("tekrar eden anahtar: %q", key)
		}
		seen[key] = true
		if it.Category == "" || it.Name == "" || it.Unit == "" || !it.Price.IsPositive() {
			t.Errorf("eksik alanlı ürün: %+v", it)
		}
		cats[it.Category]++
		nu := [2]string{it.Name, it.Unit}
		byNameUnit[nu] = append(byNameUnit[nu], it)
	}
	multi := 0
	for _, its := range byNameUnit {
		if len(its) > 1 {
			multi++
		}
	}
	t.Logf("%d ürün, %d kategori, %d ad+birim birden çok kategoride", len(items), len(cats), multi)
	// 27.09.2026 anlık görüntüsü (BYZ'nin ham satır sayısıyla aynı: 628).
	// Başka bir güne ait kopyayla bu sayılar değişebilir.
	if len(items) != 628 || len(cats) != 41 || multi != 31 {
		t.Fatalf("ürün/kategori/çok kategorili = %d/%d/%d, beklenen 628/41/31", len(items), len(cats), multi)
	}

	spot := []struct{ name, unit, category, price string }{
		// 3 hücreli üst satırın varyantı (sayfadaki en yaygın varyant düzeni).
		{"Alüminyum folyo bant 48mmx25 mt", "adet", "NALBURİYE MALZEMELERİ", "40"},
		{"Alüminyum folyo bant 48mmx25 mt (15x10m)", "adet", "NALBURİYE MALZEMELERİ", "41"},
		// Aynı ad+birim, iki kategori, FARKLI fiyat: ikisi de kalır.
		{"Gazbeton Yapıştırıcısı", "torba", "FİXA YAPI KİMYASALLARI", "130"},
		{"Gazbeton Yapıştırıcısı", "torba", "GAZBETON MALZEMELERİ", "120"},
		// Aynı ürün iki kategoride listelenmiş.
		{"Sandviç Panel Sac", "m2", "ÇATI MALZEMELERİ", "500"},
		{"Sandviç Panel Sac", "m2", "SANDVİÇ PANEL", "500"},
	}
	for _, s := range spot {
		found := false
		for _, it := range byNameUnit[[2]string{s.name, s.unit}] {
			if it.Category == s.category {
				found = true
				if !it.Price.Equal(decimal.RequireFromString(s.price)) {
					t.Errorf("%q/%q/%q fiyatı = %s, beklenen %s", s.name, s.unit, s.category, it.Price, s.price)
				}
			}
		}
		if !found {
			t.Errorf("%q/%q/%q bulunamadı", s.name, s.unit, s.category)
		}
	}
}

// redirectTransport, (www.)ulas.com.tr'ye giden istekleri yerel test
// sunucusuna yönlendirir -- testler gerçek ulas.com.tr'ye ASLA gitmez.
// Başka hostlara giden istekler OLDUĞU GİBİ gider (yönlendirme testinde
// "iç ağ" sunucusuna gerçekten ulaşılıp ulaşılmadığı görülsün diye).
type redirectTransport struct {
	target *url.URL
	seen   *http.Request
}

func (rt *redirectTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	if h := req.URL.Hostname(); h != "ulas.com.tr" && h != "www.ulas.com.tr" {
		return http.DefaultTransport.RoundTrip(req)
	}
	rt.seen = req
	r := req.Clone(req.Context())
	r.URL.Scheme = rt.target.Scheme
	r.URL.Host = rt.target.Host
	r.Host = rt.target.Host
	return http.DefaultTransport.RoundTrip(r)
}

func testClient(t *testing.T, h http.HandlerFunc) (*http.Client, *redirectTransport) {
	t.Helper()
	srv := httptest.NewServer(h)
	t.Cleanup(srv.Close)
	u, _ := url.Parse(srv.URL)
	rt := &redirectTransport{target: u}
	return &http.Client{Transport: rt}, rt
}

func TestFetchUlas(t *testing.T) {
	ctx := context.Background()

	t.Run("başarılı indirme + windows-1254 karakter kodlaması", func(t *testing.T) {
		// "ÇATI" / "Sandviç" windows-1254'te: Ç=0xC7, ç=0xE7.
		page := "<table><tr><td>Ürün</td></tr><tr><th>\xc7ATI</th></tr>" +
			"<tr><td>Sandvi\xe7 Panel</td><td>m2</td><td>1.200,50 TL</td></tr></table>"
		client, rt := testClient(t, func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "text/html; charset=windows-1254")
			_, _ = io.WriteString(w, page)
		})
		items, err := FetchUlas(ctx, client)
		if err != nil {
			t.Fatalf("hata: %v", err)
		}
		if len(items) != 1 || items[0].Name != "Sandviç Panel" || items[0].Category != "ÇATI" ||
			!items[0].Price.Equal(decimal.RequireFromString("1200.50")) {
			t.Fatalf("beklenmeyen sonuç: %+v", items)
		}
		if rt.seen.URL.String() != UlasURL || !strings.Contains(rt.seen.Header.Get("User-Agent"), "Mozilla/5.0") {
			t.Fatalf("istek sabit URL'e tarayıcı User-Agent'ı ile gitmeli: %s %q", rt.seen.URL, rt.seen.Header.Get("User-Agent"))
		}
	})

	t.Run("2xx dışı yanıt hatadır", func(t *testing.T) {
		client, _ := testClient(t, func(w http.ResponseWriter, r *http.Request) {
			http.Error(w, "bakım", http.StatusServiceUnavailable)
		})
		_, err := FetchUlas(ctx, client)
		var statusErr *HTTPStatusError
		if !errors.As(err, &statusErr) || statusErr.StatusCode != http.StatusServiceUnavailable {
			t.Fatalf("503 hatası bekleniyordu, geldi %v", err)
		}
	})

	t.Run("Ulaş dışına yönlendirme izlenmez", func(t *testing.T) {
		internalHits := 0
		internal := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			internalHits++
			w.WriteHeader(http.StatusUnauthorized)
		}))
		t.Cleanup(internal.Close)
		for _, target := range []string{
			internal.URL + "/latest/meta-data/",            // iç ağ adresi (http)
			"http://ulas.com.tr/flist.asp",                 // https'ten http'ye düşürme
			"https://ulas.com.tr.saldirgan.example/x",      // benzer görünen başka host
			"https://ulas.com.tr:8443/flist.asp",           // başka port
			"https://" + internal.Listener.Addr().String(), // IP ile
		} {
			client, _ := testClient(t, func(w http.ResponseWriter, r *http.Request) {
				http.Redirect(w, r, target, http.StatusFound)
			})
			_, err := FetchUlas(ctx, client)
			if !errors.Is(err, ErrUnexpectedRedirect) {
				t.Fatalf("%s: ErrUnexpectedRedirect bekleniyordu, geldi %v", target, err)
			}
			if msg := PublicErrorMessage(err); msg != ErrUnexpectedRedirect.Error() || strings.Contains(msg, "127.0.0.1") {
				t.Fatalf("%s: last_error sabit metin olmalı, geldi %q", target, msg)
			}
		}
		if internalHits != 0 {
			t.Fatalf("iç ağ sunucusuna %d istek gitti", internalHits)
		}
	})

	t.Run("Ulaş içi https yönlendirme izlenir; verilen istemci değişmez", func(t *testing.T) {
		var client *http.Client
		client, _ = testClient(t, func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path == "/flist.asp" {
				http.Redirect(w, r, "https://www.ulas.com.tr/yeni-flist.asp", http.StatusMovedPermanently)
				return
			}
			_, _ = io.WriteString(w, `<table><tr><td>Ürün</td></tr><tr><th>KAT</th></tr><tr><td>A</td><td>adet</td><td>5 TL</td></tr></table>`)
		})
		items, err := FetchUlas(ctx, client)
		if err != nil || len(items) != 1 || items[0].Name != "A" {
			t.Fatalf("Ulaş içi yönlendirme izlenmeliydi: %+v %v", items, err)
		}
		if client.CheckRedirect != nil {
			t.Fatal("FetchUlas çağıranın istemcisini değiştirmemeli")
		}
	})

	t.Run("boş sayfa hatadır", func(t *testing.T) {
		client, _ := testClient(t, func(w http.ResponseWriter, r *http.Request) {
			_, _ = io.WriteString(w, "<html><body></body></html>")
		})
		if _, err := FetchUlas(ctx, client); !errors.Is(err, ErrNoTable) {
			t.Fatalf("ErrNoTable bekleniyordu, geldi %v", err)
		}
	})

	t.Run("boyut sınırı aşılırsa hatadır", func(t *testing.T) {
		client, _ := testClient(t, func(w http.ResponseWriter, r *http.Request) {
			_, _ = w.Write([]byte(strings.Repeat("a", maxBodyBytes+10)))
		})
		if _, err := FetchUlas(ctx, client); err == nil || !strings.Contains(err.Error(), "büyük") {
			t.Fatalf("boyut hatası bekleniyordu, geldi %v", err)
		}
	})
}

func TestNormalize(t *testing.T) {
	d := decimal.RequireFromString
	got := Normalize([]Item{
		{Name: "  Vida \n  8mm ", Unit: " ", Category: " BAĞLANTI  ELEMANLARI ", Price: d("1.005")},
		{Name: "Vida 8mm", Unit: "adet", Category: "BAĞLANTI ELEMANLARI", Price: d("99")}, // aynı anahtar -> atlanır
		{Name: "Vida 8mm", Unit: "adet", Category: "BAŞKA", Price: d("2")},                // başka kategori -> ayrı ürün
		{Name: "", Unit: "adet", Price: d("5")},                                           // adsız -> atlanır
		{Name: "Sıfır", Unit: "adet", Price: d("0.004")},                                  // 0.00'a yuvarlanır -> atlanır
		{Name: "Negatif", Unit: "adet", Price: d("-3")},
		{Name: "Aşırı", Unit: "adet", Price: d("1000000000000.01")},
		{Name: "Vida 8mm", Unit: "kutu", Category: "", Price: d("40")},
	})
	want := []Item{
		{Name: "Vida 8mm", Unit: "adet", Category: "BAĞLANTI ELEMANLARI", Price: d("1.01")},
		{Name: "Vida 8mm", Unit: "adet", Category: "BAŞKA", Price: d("2")},
		{Name: "Vida 8mm", Unit: "kutu", Category: "", Price: d("40")},
	}
	if len(got) != len(want) {
		t.Fatalf("Normalize = %+v, beklenen %+v", got, want)
	}
	for i := range want {
		if got[i].Name != want[i].Name || got[i].Unit != want[i].Unit || got[i].Category != want[i].Category || !got[i].Price.Equal(want[i].Price) {
			t.Errorf("#%d = %+v, beklenen %+v", i, got[i], want[i])
		}
	}
}

// TestPublicErrorMessage: last_error'a (products.read ile herkese açık)
// yalnızca sabit metin gider -- çözümleyici/proxy adresi, yönlendirme
// hedefi gibi iç ayrıntılar ASLA.
func TestPublicErrorMessage(t *testing.T) {
	dnsErr := &url.Error{Op: "Get", URL: UlasURL, Err: &net.OpError{
		Op: "dial", Net: "tcp", Err: &net.DNSError{Err: "no such host", Name: "ulas.com.tr", Server: "10.0.0.2:53"},
	}}
	proxyErr := &url.Error{Op: "Get", URL: UlasURL, Err: &net.OpError{
		Op: "proxyconnect", Net: "tcp", Addr: &net.TCPAddr{IP: net.ParseIP("10.1.2.3"), Port: 3128}, Err: errors.New("connection refused"),
	}}
	timeoutErr := &url.Error{Op: "Get", URL: UlasURL, Err: context.DeadlineExceeded}
	cases := []struct {
		err  error
		want string
	}{
		{nil, ""},
		{&HTTPStatusError{StatusCode: 503}, "Ulaş sunucusu HTTP 503 döndü"},
		{fmt.Errorf("Ulaş fiyat listesi indirilemedi: %w", dnsErr), "Ulaş sunucusuna bağlanılamadı"},
		{fmt.Errorf("Ulaş fiyat listesi indirilemedi: %w", proxyErr), "Ulaş sunucusuna bağlanılamadı"},
		{fmt.Errorf("Ulaş fiyat listesi indirilemedi: %w", timeoutErr), "Ulaş sunucusu zamanında yanıt vermedi (zaman aşımı)"},
		{context.DeadlineExceeded, "Ulaş sunucusu zamanında yanıt vermedi (zaman aşımı)"},
		{fmt.Errorf("sarılmış: %w", ErrNoItems), ErrNoItems.Error()},
		{ErrNoTable, ErrNoTable.Error()},
		{&url.Error{Op: "Get", URL: "http://169.254.169.254/", Err: ErrUnexpectedRedirect}, ErrUnexpectedRedirect.Error()},
		{ErrTooLarge, ErrTooLarge.Error()},
		{fmt.Errorf("%w: gizli ayrıntı", ErrCharset), ErrCharset.Error()},
		{errors.New("iç ayrıntı: /etc/secret 10.9.9.9"), "Ulaş fiyat listesi alınamadı"},
	}
	for _, c := range cases {
		got := PublicErrorMessage(c.err)
		if got != c.want {
			t.Errorf("PublicErrorMessage(%v) = %q, beklenen %q", c.err, got, c.want)
		}
		for _, leak := range []string{"10.0.0.2", "10.1.2.3", "169.254", "10.9.9.9", "secret", "gizli"} {
			if strings.Contains(got, leak) {
				t.Errorf("PublicErrorMessage(%v) iç ayrıntı sızdırdı: %q", c.err, got)
			}
		}
	}
}
