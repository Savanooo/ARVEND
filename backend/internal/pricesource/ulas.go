// Package pricesource, tedarikçi fiyat listelerini indirip ayrıştırır.
// Şimdilik tek kaynak Ulaş'tır (https://ulas.com.tr/flist.asp) -- BYZ'deki
// services/ulas_scraper.py'nin Go karşılığı. Bu paket veritabanına
// DOKUNMAZ: yalnızca []Item üretir; ürün kataloğuna uygulama (kâr oranı,
// eşleştirme, fiyat geçmişi) service.PriceSourceService'in işidir.
package pricesource

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/shopspring/decimal"
	"golang.org/x/net/html"
	"golang.org/x/net/html/atom"
	"golang.org/x/net/html/charset"
)

const (
	// UlasURL sabittir -- kullanıcıdan/istekten gelen bir URL ASLA
	// indirilmez; yönlendirmeler de yalnızca Ulaş içinde izlenir (bkz.
	// checkUlasRedirect).
	UlasURL = "https://ulas.com.tr/flist.asp"

	// Tarayıcı benzeri User-Agent: site botlara farklı sayfa döndürmesin
	// diye (BYZ'de de aynıydı). robots.txt '/' için izin veriyor.
	userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"

	fetchTimeout = 30 * time.Second
	// Bugünkü sayfa ~200 KB; 5 MiB üstü bozuk/beklenmedik bir yanıttır.
	maxBodyBytes = 5 << 20
	// Yönlendirme yalnızca Ulaş'ın kendi https adresleri arasında izlenir.
	maxRedirects = 5

	// products tablosunun kolon sınırları (varchar karakter sayısı).
	MaxNameLen     = 200
	MaxUnitLen     = 30
	MaxCategoryLen = 100

	defaultUnit = "adet"
)

// maxPrice, numeric(18,2) kolonunda %1000 kâr oranıyla bile taşmayacak
// üst sınır -- bunun üstü bir ayrıştırma hatasıdır, satır atlanır.
var maxPrice = decimal.New(1, 12)

// Item, fiyat listesindeki tek bir ürün satırıdır. Price, tedarikçinin
// (kâr oranı UYGULANMAMIŞ) fiyatıdır ve 2 ondalığa yuvarlanmıştır --
// products.source_price ile birebir aynı değer, böylece senkron ile kâr
// oranı yeniden hesaplaması aynı tabandan çalışır.
type Item struct {
	Name     string
	Unit     string
	Category string
	Price    decimal.Decimal
}

var (
	// ErrNoItems: sayfa indi ama tek bir ürün bile çıkmadı. Boş/bozuk bir
	// sayfa ASLA "tüm ürünler listeden düştü" diye yorumlanmamalı.
	ErrNoItems = errors.New("Ulaş fiyat listesinde ürün bulunamadı (sayfa yapısı değişmiş olabilir)")
	// ErrNoTable: sayfada hiç <table> yok.
	ErrNoTable = errors.New("Ulaş fiyat listesinde tablo bulunamadı (sayfa yapısı değişmiş olabilir)")
	// ErrUnexpectedRedirect: Ulaş, https://(www.)ulas.com.tr dışına (başka
	// bir sunucuya, http'ye, iç ağ adresine) yönlendirdi -- izlenmez.
	ErrUnexpectedRedirect = errors.New("Ulaş beklenmeyen bir adrese yönlendirdi")
	ErrTooLarge           = fmt.Errorf("Ulaş fiyat listesi beklenenden büyük (> %d MiB)", maxBodyBytes>>20)
	ErrCharset            = errors.New("Ulaş fiyat listesinin karakter kodlaması çözülemedi")
)

// HTTPStatusError: Ulaş 2xx dışı bir yanıt döndü.
type HTTPStatusError struct{ StatusCode int }

func (e *HTTPStatusError) Error() string {
	return fmt.Sprintf("Ulaş sunucusu HTTP %d döndü", e.StatusCode)
}

// PublicErrorMessage, bir indirme/ayrıştırma hatasını SABİT, kısa bir
// Türkçe metne çevirir. Bu metin organization_price_sources.last_error'a
// yazılır ve products.read sahibi herkes okur -- ham Go hatası (çözümleyici/
// proxy adresi, yönlendirme hedefi...) ASLA oraya gitmez; o yalnızca
// sunucu loguna yazılır.
func PublicErrorMessage(err error) string {
	if err == nil {
		return ""
	}
	var statusErr *HTTPStatusError
	if errors.As(err, &statusErr) {
		return statusErr.Error()
	}
	for _, known := range []error{ErrNoItems, ErrNoTable, ErrUnexpectedRedirect, ErrTooLarge, ErrCharset} {
		if errors.Is(err, known) {
			return known.Error()
		}
	}
	// *url.Error da net.Error'dır: client.Do'dan gelen her ağ hatası buraya düşer.
	var netErr net.Error
	isNetErr := errors.As(err, &netErr)
	switch {
	case errors.Is(err, context.DeadlineExceeded), isNetErr && netErr.Timeout():
		return "Ulaş sunucusu zamanında yanıt vermedi (zaman aşımı)"
	case isNetErr, errors.Is(err, io.ErrUnexpectedEOF):
		return "Ulaş sunucusuna bağlanılamadı"
	}
	return "Ulaş fiyat listesi alınamadı"
}

// FetchUlas, Ulaş fiyat listesini indirip ayrıştırır. client nil ise
// varsayılan bir istemci kullanılır; her durumda istek 30 sn ile sınırlıdır
// ve yönlendirmeler yalnızca https://(www.)ulas.com.tr içinde izlenir
// (verilen istemcinin CheckRedirect'i de bu politikayla değiştirilir).
func FetchUlas(ctx context.Context, client *http.Client) ([]Item, error) {
	c := http.Client{Timeout: fetchTimeout}
	if client != nil {
		c = *client // sığ kopya: çağıranın istemcisi değişmesin
	}
	c.CheckRedirect = checkUlasRedirect
	ctx, cancel := context.WithTimeout(ctx, fetchTimeout)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, UlasURL, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", userAgent)
	req.Header.Set("Accept", "text/html,application/xhtml+xml")
	req.Header.Set("Accept-Language", "tr-TR,tr;q=0.9")

	resp, err := c.Do(req)
	if err != nil {
		return nil, fmt.Errorf("Ulaş fiyat listesi indirilemedi: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		return nil, &HTTPStatusError{StatusCode: resp.StatusCode}
	}

	body, err := io.ReadAll(io.LimitReader(resp.Body, maxBodyBytes+1))
	if err != nil {
		return nil, fmt.Errorf("Ulaş fiyat listesi okunamadı: %w", err)
	}
	if len(body) > maxBodyBytes {
		return nil, ErrTooLarge
	}
	// Bugün UTF-8; charset.NewReader Content-Type/meta/BOM'a bakıp
	// (ör. eski windows-1254 sayfalar) UTF-8'e çevirir.
	utf8Body, err := charset.NewReader(bytes.NewReader(body), resp.Header.Get("Content-Type"))
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrCharset, err)
	}
	return ParseUlas(utf8Body)
}

// checkUlasRedirect: URL sabit olsa da yönlendirme hedefi üçüncü tarafın
// elindedir. Ulaş'ın sitesi/DNS'i ele geçirilirse sunucumuz iç ağa
// (127.0.0.1, 169.254.169.254, LAN) yönlendirilmesin diye yalnızca
// https + ulas.com.tr/www.ulas.com.tr (varsayılan port) izlenir.
func checkUlasRedirect(req *http.Request, via []*http.Request) error {
	if len(via) >= maxRedirects || !isUlasURL(req.URL) {
		return ErrUnexpectedRedirect
	}
	return nil
}

func isUlasURL(u *url.URL) bool {
	if u == nil || u.Scheme != "https" || (u.Port() != "" && u.Port() != "443") {
		return false
	}
	host := strings.ToLower(u.Hostname())
	return host == "ulas.com.tr" || host == "www.ulas.com.tr"
}

// ParseUlas, flist.asp HTML'ini (UTF-8) ayrıştırır -- BYZ fetch_ulas_products
// ile aynı kurallar:
//
//   - Sayfadaki İLK <table> okunur, İLK satırı başlıktır ("Ürün","","Birim","Fiyat") -> atlanır.
//   - 1 hücre  -> kategori başlığı (boşsa -- "&nbsp;" ayırıcı satırı -- yok sayılır).
//   - 3 hücre  -> [ad, birim, fiyat].
//   - 4 hücre  -> [ad, açıklama, birim, fiyat]; açıklama doluysa ad "ad (açıklama)".
//   - 2 hücre  -> [varyant, fiyat]: önceki ürünün alt varyantı, ad "öncekiAd (varyant)", birim önceki birim.
//   - Fiyatı geçersiz/sıfır/negatif satırlar atlanır; birim boşsa "adet".
//
// (ad, birim, kategori) tekrarlarında İLK satır kazanır (bkz. Normalize).
// Hiç ürün çıkmazsa ErrNoItems.
func ParseUlas(r io.Reader) ([]Item, error) {
	doc, err := html.Parse(r)
	if err != nil {
		return nil, fmt.Errorf("Ulaş fiyat listesi ayrıştırılamadı: %w", err)
	}
	table := findFirst(doc, atom.Table)
	if table == nil {
		return nil, ErrNoTable
	}

	var (
		raw      []Item
		category string
		lastName string
		lastUnit = defaultUnit
	)
	add := func(name, unit string, price decimal.Decimal) {
		raw = append(raw, Item{Name: name, Unit: unit, Category: category, Price: price})
	}

	for i, row := range findAll(table, atom.Tr) {
		if i == 0 {
			continue // başlık satırı
		}
		nodes := findAll(row, atom.Td, atom.Th)
		cells := make([]string, len(nodes))
		for j, c := range nodes {
			cells[j] = cellText(c)
		}
		// Fiyat her zaman son hücredir (2-4 hücreli satırlar).
		var priceText string
		if len(nodes) >= 2 {
			priceText = priceCellText(nodes[len(nodes)-1])
		}
		switch len(cells) {
		case 1:
			if cells[0] != "" {
				category = cells[0]
			}
		case 3:
			name, unit := cells[0], cells[1]
			lastName = name
			lastUnit = orDefaultUnit(unit)
			if price, ok := ParsePrice(priceText); ok && name != "" {
				add(name, unit, price)
			}
		case 4:
			name, desc, unit := cells[0], cells[1], cells[2]
			lastName = name
			lastUnit = orDefaultUnit(unit)
			if price, ok := ParsePrice(priceText); ok && name != "" {
				add(withVariant(name, desc), unit, price)
			}
		case 2:
			desc := cells[0]
			name := lastName
			switch {
			case desc != "" && lastName != "":
				name = withVariant(lastName, desc)
			case lastName == "":
				name = desc
			}
			if price, ok := ParsePrice(priceText); ok && name != "" {
				add(name, lastUnit, price)
			}
		}
	}
	items := Normalize(raw)
	if len(items) == 0 {
		return nil, ErrNoItems
	}
	return items, nil
}

// Normalize, ürün kataloğuna yazılmadan önce her kaynağın çıktısına
// uygulanan ORTAK temizliktir (ParseUlas da bunu kullanır; servis, sahte/
// başka bir fetcher'dan gelen listeyi de buradan geçirir):
//
//   - ad/birim/kategori: boşluklar tek boşluğa iner, kırpılır ve kolon
//     sınırlarına (200/30/100 karakter) rune-güvenli kısaltılır;
//   - birim boşsa "adet"; ad boşsa satır atlanır;
//   - fiyat 2 ondalığa yarım yukarı yuvarlanır, sıfır/negatif/aşırı büyükse atlanır;
//   - (ad, birim, kategori) tekrarlarında İLK satır kazanır.
//
// Kategori anahtarın parçasıdır: Ulaş aynı ad+birimi birden çok kategoride
// listeler -- çoğu aynı ürünün iki kategoride görünmesidir (ör. "Sandviç
// Panel Sac" ÇATI MALZEMELERİ ve SANDVİÇ PANEL'de), ama bazıları FARKLI
// ürünlerdir ("Gazbeton Yapıştırıcısı" torba: FİXA 130 TL, GAZBETON
// MALZEMELERİ 120 TL). (ad, birim) ile tekilleştirmek ikincisinin fiyatını
// birincininkiyle ezer, kategori oranını da hiç uygulatmazdı.
func Normalize(items []Item) []Item {
	out := make([]Item, 0, len(items))
	seen := make(map[[3]string]bool, len(items))
	for _, it := range items {
		name := truncateRunes(CollapseSpaces(it.Name), MaxNameLen)
		unit := truncateRunes(CollapseSpaces(it.Unit), MaxUnitLen)
		if unit == "" {
			unit = defaultUnit
		}
		category := truncateRunes(CollapseSpaces(it.Category), MaxCategoryLen)
		price := it.Price.Round(2)
		key := [3]string{name, unit, category}
		if name == "" || !price.IsPositive() || price.GreaterThan(maxPrice) || seen[key] {
			continue
		}
		seen[key] = true
		out = append(out, Item{Name: name, Unit: unit, Category: category, Price: price})
	}
	return out
}

// CollapseSpaces, her türlü boşluk dizisini (NBSP, satır sonu dahil) tek
// boşluğa indirir ve kırpar. Senkron eşleştirmesi mevcut satırların ad/
// birimini de bununla karşılaştırır (BYZ çift boşlukları korurdu).
func CollapseSpaces(s string) string {
	return strings.Join(strings.Fields(s), " ")
}

// turkishThousands: "1.200", "1.200,50", "12.345.678" -- nokta binlik
// ayırıcı, virgül ondalık (BYZ _parse_price ile aynı desen).
var (
	turkishThousands = regexp.MustCompile(`^\d{1,3}(\.\d{3})+(,\d+)?$`)
	plainNumber      = regexp.MustCompile(`^\d+(\.\d+)?$`)
)

// ParsePrice, "500 TL", "1.200 TL", "1.200,50 TL", "12,5TL" gibi metinleri
// 2 ondalığa yuvarlanmış (yarım yukarı) pozitif bir tutara çevirir.
// Geçersiz, sıfır veya negatif -> ok=false.
func ParsePrice(s string) (decimal.Decimal, bool) {
	s = strings.ReplaceAll(s, "TL", "")
	s = strings.ReplaceAll(s, "\u00a0", "")
	s = strings.TrimSpace(s)
	if turkishThousands.MatchString(s) {
		s = strings.ReplaceAll(s, ".", "")
	}
	s = strings.ReplaceAll(s, ",", ".")
	// BYZ float() kullanıyordu; burada yalnızca düz ondalık sayı kabul
	// edilir ("1e5", "inf", "-3" gibi girdiler reddedilir).
	if !plainNumber.MatchString(s) {
		return decimal.Decimal{}, false
	}
	d, err := decimal.NewFromString(s)
	if err != nil {
		return decimal.Decimal{}, false
	}
	d = d.Round(2)
	if !d.IsPositive() || d.GreaterThan(maxPrice) {
		return decimal.Decimal{}, false
	}
	return d, true
}

func withVariant(name, desc string) string {
	if desc == "" {
		return name
	}
	return name + " (" + desc + ")"
}

func orDefaultUnit(unit string) string {
	if unit == "" {
		return defaultUnit
	}
	return unit
}

// cellText, hücredeki tüm metin düğümlerini birleştirir (HTML varlıkları
// -- &#199; / &nbsp; -- ayrıştırıcı tarafından zaten çözülmüştür), boşlukları
// (NBSP dahil) tek boşluğa indirger ve kırpar.
func cellText(n *html.Node) string {
	return CollapseSpaces(rawText(n))
}

// priceCellText: fiyat hücresinde NBSP binlik ayırıcı olabilir
// ("1&nbsp;200 TL"). BYZ _parse_price gibi NBSP, boşluklar tek boşluğa
// indirgenmeden ÖNCE silinir -- yoksa "1 200" olur ve reddedilirdi. Düz
// boşluklu "1 200" ise (BYZ'de de olduğu gibi) geçersiz kalır.
func priceCellText(n *html.Node) string {
	return CollapseSpaces(strings.ReplaceAll(rawText(n), " ", ""))
}

func rawText(n *html.Node) string {
	var b strings.Builder
	var walk func(*html.Node)
	walk = func(n *html.Node) {
		if n.Type == html.TextNode {
			b.WriteString(n.Data)
			return
		}
		for c := n.FirstChild; c != nil; c = c.NextSibling {
			walk(c)
		}
	}
	walk(n)
	return b.String()
}

// truncateRunes, s'yi en fazla max karaktere (rune) kısaltır -- UTF-8
// dizisini ortadan bölmez.
func truncateRunes(s string, max int) string {
	if utf8.RuneCountInString(s) <= max {
		return s
	}
	return strings.TrimSpace(string([]rune(s)[:max]))
}

// findFirst, n'nin altındaki (belge sırasıyla) ilk a öğesini döner.
func findFirst(n *html.Node, a atom.Atom) *html.Node {
	if n.Type == html.ElementNode && n.DataAtom == a {
		return n
	}
	for c := n.FirstChild; c != nil; c = c.NextSibling {
		if f := findFirst(c, a); f != nil {
			return f
		}
	}
	return nil
}

// findAll, n'nin ALTINDAKİ (n'nin kendisi hariç) verilen türlerdeki tüm
// öğeleri belge sırasıyla döner -- BeautifulSoup find_all gibi özyinelemeli.
func findAll(n *html.Node, atoms ...atom.Atom) []*html.Node {
	var out []*html.Node
	var walk func(*html.Node)
	walk = func(n *html.Node) {
		for c := n.FirstChild; c != nil; c = c.NextSibling {
			if c.Type == html.ElementNode {
				for _, a := range atoms {
					if c.DataAtom == a {
						out = append(out, c)
						break
					}
				}
			}
			walk(c)
		}
	}
	walk(n)
	return out
}
