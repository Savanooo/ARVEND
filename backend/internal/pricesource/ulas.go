package pricesource

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/shopspring/decimal"
	"golang.org/x/net/html"
	"golang.org/x/net/html/atom"
	"golang.org/x/net/html/charset"
)

const (
	// UlasURL sabittir -- kullanıcıdan/istekten gelen bir URL ASLA
	// indirilmez; yönlendirmeler de yalnızca Ulaş içinde izlenir (bkz.
	// redirectPolicy).
	UlasURL = "https://ulas.com.tr/flist.asp"
	// UlasName, hata/log metinlerindeki kısa ad.
	UlasName = "Ulaş"
)

// UlasArchiveURL: Wayback Machine'in flist.asp için EN SON kopyası; "id_"
// eki sayfayı arşivin araç çubuğu eklenmeden, orijinal haliyle verir.
// "/web/2id_/" en yeni kopyaya yönlendirir. Sabit adres -- yine yalnızca
// web.archive.org içinde yönlendirme izlenir.
const UlasArchiveURL = "https://web.archive.org/web/2id_/https://ulas.com.tr/flist.asp"

var ulasArchiveFetchSpec = fetchSpec{
	name:    UlasName + " (arşiv)",
	url:     UlasArchiveURL,
	accept:  "text/html,application/xhtml+xml",
	hosts:   []string{"web.archive.org"},
	timeout: 60 * time.Second,
}

// ErrArchiveUndated: arşiv yanıtında kopyanın tarihi yok. Tarihi
// bilinmeyen bir liste, firmanın daha yeni fiyatlarıyla karşılaştırılamaz
// -- uygulanmaz.
var ErrArchiveUndated error = &publicError{"%s arşiv kopyasının tarihi okunamadı"}

// FetchUlasArchive, Ulaş fiyat listesinin Wayback Machine'deki son
// kopyasını indirip ayrıştırır (sahada 2026-10: canlı sayfa HTTP 500).
// Liste dönemi "Arşiv kopyası · 15.06.2026" olur -- fiyatların hangi
// tarihten geldiği ekranda hep görünsün. AsOf, kopyanın alındığı an
// (Memento-Datetime başlığı).
func FetchUlasArchive(ctx context.Context, client *http.Client) (List, error) {
	body, header, err := fetchBodyWithHeader(ctx, client, ulasArchiveFetchSpec)
	if err != nil {
		return List{}, err
	}
	asOf, err := http.ParseTime(header.Get("Memento-Datetime"))
	if err != nil || asOf.IsZero() {
		return List{}, ErrArchiveUndated
	}
	utf8Body, err := charset.NewReader(bytes.NewReader(body), header.Get("Content-Type"))
	if err != nil {
		return List{}, fmt.Errorf("Ulaş (arşiv): %w: %v", ErrCharset, err)
	}
	items, err := ParseUlas(utf8Body)
	if err != nil {
		return List{}, err
	}
	return List{
		Items:  items,
		Label:  ArchiveLabel(asOf),
		Origin: OriginArchive,
		AsOf:   asOf,
	}, nil
}

// ArchiveLabel: "Arşiv kopyası · 15.06.2026" (Türkiye saatiyle gün).
func ArchiveLabel(asOf time.Time) string {
	return "Arşiv kopyası · " + asOf.In(trLocation()).Format("02.01.2006")
}

func trLocation() *time.Location {
	if loc, err := time.LoadLocation("Europe/Istanbul"); err == nil {
		return loc
	}
	return time.FixedZone("TRT", 3*3600)
}

var ulasFetchSpec = fetchSpec{
	name:   UlasName,
	url:    UlasURL,
	accept: "text/html,application/xhtml+xml",
	hosts:  []string{"ulas.com.tr", "www.ulas.com.tr"},
}

// FetchUlas, Ulaş fiyat listesini indirip ayrıştırır. client nil ise
// varsayılan bir istemci kullanılır; her durumda istek 30 sn ile sınırlıdır
// ve yönlendirmeler yalnızca https://(www.)ulas.com.tr içinde izlenir
// (verilen istemcinin CheckRedirect'i de bu politikayla değiştirilir).
// Ulaş liste dönemi vermez: List.Label boştur.
func FetchUlas(ctx context.Context, client *http.Client) (List, error) {
	body, contentType, err := fetchBody(ctx, client, ulasFetchSpec)
	if err != nil {
		return List{}, err
	}
	// Bugün UTF-8; charset.NewReader Content-Type/meta/BOM'a bakıp
	// (ör. eski windows-1254 sayfalar) UTF-8'e çevirir.
	utf8Body, err := charset.NewReader(bytes.NewReader(body), contentType)
	if err != nil {
		return List{}, fmt.Errorf("Ulaş: %w: %v", ErrCharset, err)
	}
	items, err := ParseUlas(utf8Body)
	if err != nil {
		return List{}, err
	}
	return List{Items: items}, nil
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
