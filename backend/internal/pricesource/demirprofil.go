package pricesource

import (
	"bufio"
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"slices"
	"strings"
	"unicode/utf8"

	"github.com/shopspring/decimal"
)

const (
	// DemirProfilURL sabittir (robots.txt izin veriyor; dosya haftalık
	// yenilenir). Yönlendirmeler yalnızca https://(www.)demirprofil.com.tr
	// içinde izlenir.
	DemirProfilURL = "https://www.demirprofil.com.tr/llms-full.txt"
	// DemirProfilName, hata/log metinlerindeki kısa ad.
	DemirProfilName = "Demir Profil"

	// DemirProfilMinItems: tekilleştirilmiş ürün sayısı bunun altındaysa
	// dosya yarım/bozuktur (bugün ~3000 kalem) -- ErrTooFewItems.
	DemirProfilMinItems = 100

	// vatIncludedPrefix: bu önekle başlayan kolonlar (KDV dahil fiyatlar)
	// satır haritasına HİÇ alınmaz -- düzen tanımları yanlışlıkla bile
	// okuyamaz. Ürün fiyatı her zaman KDV hariç liste fiyatıdır.
	vatIncludedPrefix = "KDV dahil"
)

var demirProfilFetchSpec = fetchSpec{
	name:   DemirProfilName,
	url:    DemirProfilURL,
	accept: "text/plain",
	hosts:  []string{"www.demirprofil.com.tr", "demirprofil.com.tr"},
}

// FetchDemirProfil, Demir Profil'in llms-full.txt dosyasını indirip
// ayrıştırır (bkz. ParseDemirProfil). client nil ise varsayılan istemci;
// istek 30 sn ve 5 MiB ile sınırlıdır.
func FetchDemirProfil(ctx context.Context, client *http.Client) (List, error) {
	body, _, err := fetchBody(ctx, client, demirProfilFetchSpec)
	if err != nil {
		return List{}, err
	}
	// Dosya UTF-8'dir (text/plain; charset=utf-8); başka bir kodlama
	// sessizce bozuk ad üretmesin diye tahmin edilmez, reddedilir.
	body = bytes.TrimPrefix(body, []byte("\uFEFF"))
	if !utf8.Valid(body) {
		return List{}, fmt.Errorf("%s: %w", DemirProfilName, ErrCharset)
	}
	list, _, err := ParseDemirProfil(bytes.NewReader(body))
	return list, err
}

// DemirProfilStats, ParseDemirProfil'in satır sayımı (log/test içindir).
type DemirProfilStats struct {
	// Rows: tablo bölümlerindeki toplam "- " satırı.
	Rows int
	// ByLayout: düzen adı -> kataloğa giren (fiyatlı, geçerli) satır sayısı.
	ByLayout map[string]int
	// Unpriced: fiyat kolonu olmayan düzenin (çatı ürünleri) satırları.
	Unpriced int
	// Malformed: hücre sayısı başlıkla tutmayan ya da fiyatı/adı (adı
	// oluşturan hücrelerden biri) okunamayan satırlar.
	Malformed int
	// UnknownRows: tanınmayan başlıklı bölümlerin, başlık satırı olmayan
	// bölümlerin ve hiçbir bölümün içinde olmayan (atlanan) tablo satırları.
	UnknownRows int
	// Duplicates: (ad, birim, kategori) tekrarı yüzünden düşen satırlar.
	Duplicates int
}

// dpRow, bir tablo satırının kolon adı -> hücre haritasıdır. KDV dahil
// kolonlar buraya HİÇ girmez (bkz. vatIncludedPrefix).
type dpRow map[string]string

// dpLayout, tanınan bir tablo düzenidir: başlığın kolon adları (boşluklar
// tek boşluğa indirilmiş) columns kümesiyle BİREBİR aynı olmalıdır --
// eksik/fazla/bilinmeyen kolon = tanınmayan düzen, bölüm atlanır (tahmin
// YOK). Kolonlara sırayla değil adla erişilir.
type dpLayout struct {
	key     string
	columns []string
	unit    string
	// price: fiyat kolonu; "" -> düzen fiyatsızdır (satırlar sayılır, atlanır).
	price string
	// required: adı oluşturan kolonlar; biri boşsa satır okunamaz sayılır
	// ("Paslanmaz Kutu Profil × mm" gibi anlamsız bir ad ürün olmasın).
	required []string
	name     func(family string, r dpRow) string
	desc     func(r dpRow) string
}

// demirProfilLayouts, llms-full.txt'teki (Eylül 2026) tablo düzenleri.
var demirProfilLayouts = []dpLayout{
	{
		// Kutu profil aileleri: fiyat ₺/m, 1 boy = 6 m.
		key:      "kutu_profil",
		columns:  []string{"ebat (mm)", "et (mm)", "kg/m", "₺/m", "₺/boy", "KDV dahil ₺/boy"},
		unit:     "mt",
		price:    "₺/m",
		required: []string{"ebat (mm)", "et (mm)"},
		name:     func(f string, r dpRow) string { return f + " " + r["ebat (mm)"] + "×" + r["et (mm)"] + " mm" },
		desc:     barDescription,
	},
	{
		// Boru aileleri: fiyat ₺/m, 1 boy = 6 m.
		key:      "boru",
		columns:  []string{"dış çap (mm)", "et (mm)", "kg/m", "₺/m", "₺/boy", "KDV dahil ₺/boy"},
		unit:     "mt",
		price:    "₺/m",
		required: []string{"dış çap (mm)", "et (mm)"},
		name:     func(f string, r dpRow) string { return f + " " + r["dış çap (mm)"] + "×" + r["et (mm)"] + " mm" },
		desc:     barDescription,
	},
	{
		// Sac aileleri: fiyat ₺/kg (₺/ton ve ₺/m² yalnızca bilgi).
		key:      "sac",
		columns:  []string{"ürün", "kalınlık (mm)", "₺/ton", "₺/kg", "kg/m²", "₺/m²"},
		unit:     "kg",
		price:    "₺/kg",
		required: []string{"ürün"},
		name:     func(_ string, r dpRow) string { return r["ürün"] },
		desc: func(r dpRow) string {
			if w := r["kg/m²"]; w != "" {
				return w + " kg/m²"
			}
			return ""
		},
	},
	{
		// Hadde profil (H/NPI/NPU), köşebent, lama: fiyat ₺/kg.
		key:      "hadde_kg",
		columns:  []string{"ölçü", "₺/kg", "not"},
		unit:     "kg",
		price:    "₺/kg",
		required: []string{"ölçü"},
		name:     func(_ string, r dpRow) string { return r["ölçü"] },
	},
	{
		// Sandviç panel: fiyat ₺/m².
		key:      "sandvic_panel",
		columns:  []string{"ürün", "kalınlık (mm)", "₺/m²", "KDV dahil ₺/m²"},
		unit:     "m2",
		price:    "₺/m²",
		required: []string{"ürün"},
		name:     func(_ string, r dpRow) string { return r["ürün"] },
	},
	{
		// Delikli sac: plaka başına fiyat.
		key:      "delikli_sac",
		columns:  []string{"malzeme", "kalınlık", "delik Ø", "ebat", "₺/adet"},
		unit:     "adet",
		price:    "₺/adet",
		required: []string{"malzeme", "kalınlık", "delik Ø", "ebat"},
		name: func(_ string, r dpRow) string {
			return r["malzeme"] + " " + r["kalınlık"] + " mm Ø" + r["delik Ø"] + " " + r["ebat"]
		},
	},
	{
		// Çatı ürünleri (trapez, oluklu, metal kiremit): listede fiyat YOK
		// (ürün sayfasında) -- satırlar sayılır ve atlanır.
		key:     "cati_fiyatsiz",
		columns: []string{"ürün", "kalınlık (mm)", "not"},
	},
}

// barDescription: kutu profil/boru için boy uzunluğu ve metre ağırlığı.
// Boy uzunluğu ₺/boy ÷ ₺/m'den çıkarılır (bugün hep 6 m) -- tam sayı
// çıkmazsa yazılmaz. Fiyat açıklamaya YAZILMAZ (bkz. Item).
func barDescription(r dpRow) string {
	var parts []string
	perMetre, ok1 := ParsePrice(r["₺/m"])
	perBar, ok2 := ParsePrice(r["₺/boy"])
	if ok1 && ok2 {
		ratio := perBar.Div(perMetre)
		n := ratio.Round(0)
		if ratio.Sub(n).Abs().LessThan(decimal.RequireFromString("0.02")) && n.IntPart() >= 1 && n.IntPart() <= 24 {
			parts = append(parts, fmt.Sprintf("%d m boy", n.IntPart()))
		}
	}
	if w := r["kg/m"]; w != "" {
		parts = append(parts, w+" kg/m")
	}
	return strings.Join(parts, " · ")
}

var (
	// "## Siyah Kutu Profil (468 kalem)" -> aile + beklenen kalem sayısı.
	familyHeading = regexp.MustCompile(`^(.*?)\s*\((\d+)\s+kalem\)$`)
	// Özet satırındaki dönem: "Liste Eylül 2026".
	listLabelPattern = regexp.MustCompile(`Liste\s+(\p{L}+)\s+(\d{4})`)
	// Özette dönem yoksa yedek: "# Tam fiyat listesi (Eylül 2026; ...)".
	headingLabelPattern = regexp.MustCompile(`(?i)fiyat listesi\s*\(\s*(\p{L}+)\s+(\d{4})\b`)
	turkishMonths       = []string{"Ocak", "Şubat", "Mart", "Nisan", "Mayıs", "Haziran", "Temmuz", "Ağustos", "Eylül", "Ekim", "Kasım", "Aralık"}
)

// ParseDemirProfil, llms-full.txt'i ayrıştırır. Biçim:
//
//	# başlık
//	> özet ... Liste Eylül 2026 ... KDV hariç, toptan.
//	## <Aile> (<N> kalem)
//	<kolon> | <kolon> | ...        <- TEK başlık satırı
//	- <hücre> | <hücre> | ...      <- satırlar
//
// Kurallar (tahmin YOK):
//   - Bölüm = ikinci seviye başlıktan ("## ", boşluksuz "##" de) ya da
//     "(N kalem)" ile biten daha derin bir başlıktan ("### Aile (N kalem)")
//     bir sonraki "#" ile başlayan satıra kadar. Diğer başlıklar ("# Tam
//     fiyat listesi", "### Profil ([hub](...))") bölüm açmaz. Başlık satırı
//     ("- " ile başlamayan, "|" içeren ilk satır) olmayan bölümler
//     (bağlantı listeleri, "Kaliteler", "Kullanım notu") tablo değildir, yok
//     sayılır; "(N kalem)" diyen bölümde tablo yoksa uyarılır.
//   - Hiçbir bölümün içinde olmayan tablo satırları ("- " + "|") atlanır
//     ve uyarılır -- bir aile sessizce kaybolmasın.
//   - Düzen başlığın kolon adlarıyla BİREBİR tanınır (demirProfilLayouts);
//     tanınmayan düzenli bölüm atlanır ve Warnings'e yazılır.
//   - "KDV dahil" ile başlayan kolonlar ASLA okunmaz.
//   - Hücre sayısı başlıkla tutmayan, adını oluşturan bir hücresi boş ya da
//     fiyatı okunamayan satır atlanır (sayılır). Kategori = aile adı ("(N
//     kalem)" olmadan).
//   - Dönem, ilk alıntı bloğundaki ("> ..." satırları birleştirilir) ilk
//     geçerli "Liste <Ay> <Yıl>"dan; yoksa "fiyat listesi (<Ay> <Yıl>"
//     diyen bir başlıktan çıkarılır.
//   - Tekilleştirme Normalize ile; DemirProfilMinItems'tan az ürün
//     ErrTooFewItems'tır (yarım/bozuk dosya).
func ParseDemirProfil(r io.Reader) (List, DemirProfilStats, error) {
	stats := DemirProfilStats{ByLayout: map[string]int{}}
	var (
		list List
		raw  []Item
		sec  *dpSection
		// summaryLines: ilk alıntı bloğu; summaryDone: blok bitti.
		summaryLines []string
		summaryDone  bool
		headings     []string
		// strayRows: hiçbir bölümün içinde olmayan tablo satırları.
		strayRows int
	)
	finish := func() {
		if sec != nil {
			raw = append(raw, sec.finish(&stats, &list.Warnings)...)
			sec = nil
		}
	}

	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 0, 64<<10), maxBodyBytes)
	for sc.Scan() {
		line := strings.TrimRight(sc.Text(), " \t\r")
		if !summaryDone {
			if quoted, ok := strings.CutPrefix(line, ">"); ok {
				summaryLines = append(summaryLines, strings.TrimSpace(quoted))
				continue
			}
			summaryDone = len(summaryLines) > 0
		}
		switch {
		case strings.HasPrefix(line, "#"):
			finish()
			level, heading := splitHeading(line)
			headings = append(headings, heading)
			if heading != "" && (level == 2 || (level > 2 && familyHeading.MatchString(heading))) {
				sec = newSection(heading)
			}
		case sec != nil:
			sec.add(line)
		case strings.HasPrefix(line, "- ") && strings.Contains(line, "|"):
			strayRows++
		}
	}
	if err := sc.Err(); err != nil {
		return List{}, stats, fmt.Errorf("%s fiyat listesi okunamadı: %w", DemirProfilName, err)
	}
	finish()
	if strayRows > 0 {
		list.Warnings = append(list.Warnings, fmt.Sprintf("%d tablo satırı bir aile başlığı (\"## <Aile> (N kalem)\") altında değil; atlandı", strayRows))
		stats.UnknownRows += strayRows
	}

	summary := strings.Join(summaryLines, " ")
	list.Label = listLabel(summary, headings)
	if list.Label == "" {
		list.Warnings = append(list.Warnings, "liste dönemi (\"Liste <Ay> <Yıl>\") özet satırında bulunamadı")
	}
	if !strings.Contains(summary, "KDV hariç") {
		list.Warnings = append(list.Warnings, "özet satırında \"KDV hariç\" ibaresi bulunamadı; fiyat esası değişmiş olabilir")
	}
	if stats.Malformed > 0 {
		list.Warnings = append(list.Warnings, fmt.Sprintf("%d satır okunamadığı için atlandı", stats.Malformed))
	}

	list.Items = Normalize(raw)
	stats.Duplicates = len(raw) - len(list.Items)
	if len(list.Items) < DemirProfilMinItems {
		return List{}, stats, fmt.Errorf("%s: %d ürün: %w", DemirProfilName, len(list.Items), ErrTooFewItems)
	}
	return list, stats, nil
}

// listLabel, "Eylül 2026" gibi dönemi çıkarır: özetteki ilk geçerli "Liste
// <Ay> <Yıl>", yoksa "fiyat listesi (<Ay> <Yıl>" diyen ilk başlık. Ay adı
// Türkçe ay adlarından biri olmayan eşleşmeler atlanır (yanlış bir metin
// etiket olmasın); hiçbiri yoksa "".
func listLabel(summary string, headings []string) string {
	if l := firstMonthLabel(listLabelPattern, summary); l != "" {
		return l
	}
	for _, h := range headings {
		if l := firstMonthLabel(headingLabelPattern, h); l != "" {
			return l
		}
	}
	return ""
}

func firstMonthLabel(re *regexp.Regexp, text string) string {
	for _, m := range re.FindAllStringSubmatch(text, -1) {
		if slices.Contains(turkishMonths, m[1]) {
			return m[1] + " " + m[2]
		}
	}
	return ""
}

// splitHeading: "### Aile (3 kalem)" -> (3, "Aile (3 kalem)"); başlıktan
// sonra boşluk olmasa da ("##Aile") seviye doğru sayılır.
func splitHeading(line string) (int, string) {
	rest := strings.TrimLeft(line, "#")
	return len(line) - len(rest), strings.TrimSpace(rest)
}

// dpSection, bir "## " bölümünün toplanan satırlarıdır.
type dpSection struct {
	heading  string
	family   string
	expected int // "(N kalem)"; yoksa -1
	header   []string
	rows     []string
	// orphanRows: başlık satırından ÖNCE gelen, "|" içeren "- " satırları.
	orphanRows int
}

func newSection(heading string) *dpSection {
	s := &dpSection{heading: CollapseSpaces(heading), expected: -1}
	s.family = s.heading
	if m := familyHeading.FindStringSubmatch(s.heading); m != nil {
		s.family = m[1]
		fmt.Sscan(m[2], &s.expected) //nolint:errcheck // regexp yalnızca rakam yakalar
	}
	return s
}

func (s *dpSection) add(line string) {
	switch {
	case strings.HasPrefix(line, "- "):
		if s.header != nil {
			s.rows = append(s.rows, line[2:])
		} else if strings.Contains(line, "|") {
			s.orphanRows++
		}
	case s.header == nil && strings.Contains(line, "|"):
		s.header = splitCells(line)
	}
}

// finish, bölümü düzenine göre Item'lara çevirir; sayımları stats'a,
// atlanan bölümleri warnings'e yazar.
func (s *dpSection) finish(stats *DemirProfilStats, warnings *[]string) []Item {
	if s.header != nil && len(s.rows) == 0 && s.expected < 0 {
		s.header = nil // "|" içeren tek bir düz yazı satırı: tablo değil
	}
	if s.header == nil {
		switch {
		case s.orphanRows > 0:
			*warnings = append(*warnings, fmt.Sprintf("%q bölümünde başlık satırı yok; %d satır atlandı", s.heading, s.orphanRows))
			stats.UnknownRows += s.orphanRows
		case s.expected > 0:
			// "(N kalem)" diyen ama tablosu olmayan aile (tablo alt başlıklara
			// bölünmüş olabilir): sessizce kaybolmasın.
			*warnings = append(*warnings, fmt.Sprintf("%q bölümünde tablo bulunamadı", s.heading))
		}
		return nil // tablo olmayan bölüm (bağlantılar, notlar)
	}
	stats.Rows += len(s.rows)
	if s.expected >= 0 && s.expected != len(s.rows) {
		*warnings = append(*warnings, fmt.Sprintf("%q bölümünde %d kalem bekleniyordu, %d satır bulundu", s.heading, s.expected, len(s.rows)))
	}
	layout := matchLayout(s.header)
	if layout == nil {
		*warnings = append(*warnings, fmt.Sprintf("%q bölümü atlandı: tanınmayan başlık %q", s.heading, strings.Join(s.header, " | ")))
		stats.UnknownRows += len(s.rows)
		return nil
	}
	if layout.price == "" {
		stats.Unpriced += len(s.rows)
		return nil
	}

	var items []Item
	for _, text := range s.rows {
		cells := splitCells(text)
		if len(cells) != len(s.header) {
			stats.Malformed++
			continue
		}
		row := make(dpRow, len(cells))
		for i, col := range s.header {
			if !strings.HasPrefix(col, vatIncludedPrefix) {
				row[col] = cells[i]
			}
		}
		price, ok := ParsePrice(row[layout.price])
		for _, col := range layout.required {
			ok = ok && row[col] != ""
		}
		name := CollapseSpaces(layout.name(s.family, row))
		if !ok || name == "" {
			stats.Malformed++
			continue
		}
		it := Item{Name: name, Unit: layout.unit, Category: s.family, Price: price}
		if layout.desc != nil {
			it.Description = layout.desc(row)
		}
		items = append(items, it)
		stats.ByLayout[layout.key]++
	}
	return items
}

// matchLayout: başlığın kolon kümesi bir düzeninkiyle BİREBİR aynıysa o
// düzen (tekrarlanan kolon adı = tanınmaz).
func matchLayout(header []string) *dpLayout {
	for i := range demirProfilLayouts {
		l := &demirProfilLayouts[i]
		if len(l.columns) != len(header) {
			continue
		}
		seen := make(map[string]bool, len(header))
		match := true
		for _, col := range header {
			if seen[col] || !slices.Contains(l.columns, col) {
				match = false
				break
			}
			seen[col] = true
		}
		if match {
			return l
		}
	}
	return nil
}

func splitCells(line string) []string {
	parts := strings.Split(line, "|")
	for i, p := range parts {
		parts[i] = CollapseSpaces(p)
	}
	return parts
}
