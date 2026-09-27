package pricesource

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"github.com/shopspring/decimal"
)

func readFixture(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("fixture okunamadı: %v", err)
	}
	return string(b)
}

// withFiller, metne n satırlık geçerli bir kutu profil ailesi ekler: küçük
// fixture'lar DemirProfilMinItems (100) eşiğine takılmadan düzen kurallarını
// sınayabilsin diye.
func withFiller(base string, n int) string {
	var b strings.Builder
	b.WriteString(base)
	fmt.Fprintf(&b, "\n## Dolgu Kutu Profil (%d kalem)\n\nebat (mm) | et (mm) | kg/m | ₺/m | ₺/boy | KDV dahil ₺/boy\n", n)
	for i := 1; i <= n; i++ {
		fmt.Fprintf(&b, "- 10×%d | 1 | 0,500 | %d,25 | %d,50 | 1,00\n", i, i, i*6+1)
	}
	return b.String()
}

func mustParseDemirProfil(t *testing.T, text string) (List, DemirProfilStats) {
	t.Helper()
	list, stats, err := ParseDemirProfil(strings.NewReader(text))
	if err != nil {
		t.Fatalf("ayrıştırma hatası: %v", err)
	}
	return list, stats
}

func findItem(items []Item, name string) *Item {
	for i := range items {
		if items[i].Name == name {
			return &items[i]
		}
	}
	return nil
}

func TestParseDemirProfilFixture(t *testing.T) {
	list, stats := mustParseDemirProfil(t, withFiller(readFixture(t, "testdata/demirprofil_fixture.txt"), 100))

	want := []struct{ name, unit, category, price, desc string }{
		// Düzen 1 (kutu profil): ad "<Aile> <ebat>×<et> mm", birim mt, fiyat ₺/m.
		{"Siyah Kutu Profil 20×80×2,5 mm", "mt", "Siyah Kutu Profil", "173.60", "6 m boy · 3,925 kg/m"},
		{"Siyah Kutu Profil 20×20×1,2 mm", "mt", "Siyah Kutu Profil", "1041.50", "6 m boy · 0,700 kg/m"},
		// Düzen 2 (boru). İkinci satırda ₺/boy ÷ ₺/m tam sayı değil -> boy yazılmaz.
		{"Siyah Çelik Boru Ø21,3×2 mm", "mt", "Siyah Çelik Boru", "40.30", "6 m boy · 0,952 kg/m"},
		{"Siyah Çelik Boru Ø26,9×2 mm", "mt", "Siyah Çelik Boru", "52.10", "1,230 kg/m"},
		// Düzen 3 (sac): fiyat ₺/kg ("51.075" ₺/ton DEĞİL).
		{"0,30mm Galvaniz sac", "kg", "Galvaniz Sac", "51.08", "2,36 kg/m²"},
		{"4mm Galvaniz sac", "kg", "Galvaniz Sac", "42.40", "31,40 kg/m²"},
		// Düzen 4 (hadde/köşebent/lama).
		{"100 H Profil", "kg", "H profil", "34.30", ""},
		{"60 Npu Profil", "kg", "Npu Profil", "34.15", ""},
		// Düzen 5 (sandviç panel): fiyat ₺/m², KDV dahil kolonu değil.
		{"4cm 0,30mm Sandviç Panel", "m2", "Sandviç Panel", "535.50", ""},
		// Düzen 6 (delikli sac).
		{"DKP Delikli Sac 1 mm Ø4 1000x2000", "adet", "Delikli Sac", "1254", ""},
	}
	if len(list.Items) != len(want)+100 {
		for _, it := range list.Items[:min(len(list.Items), 20)] {
			t.Logf("%q %q %q %s %q", it.Name, it.Unit, it.Category, it.Price, it.Description)
		}
		t.Fatalf("ürün sayısı = %d, beklenen %d", len(list.Items), len(want)+100)
	}
	for i, w := range want {
		got := list.Items[i]
		if got.Name != w.name || got.Unit != w.unit || got.Category != w.category ||
			!got.Price.Equal(decimal.RequireFromString(w.price)) || got.Description != w.desc {
			t.Errorf("#%d = {%q %q %q %s %q}, beklenen %+v", i, got.Name, got.Unit, got.Category, got.Price, got.Description, w)
		}
	}
	if list.Label != "Eylül 2026" {
		t.Errorf("dönem = %q, beklenen %q", list.Label, "Eylül 2026")
	}

	// Sayımlar: düzen başına kataloğa giren satırlar (tekrar düşmeden önce).
	wantByLayout := map[string]int{"kutu_profil": 3 + 100, "boru": 2, "sac": 2, "hadde_kg": 2, "sandvic_panel": 1, "delikli_sac": 1}
	if len(stats.ByLayout) != len(wantByLayout) {
		t.Errorf("düzen sayımları = %v, beklenen %v", stats.ByLayout, wantByLayout)
	}
	for k, v := range wantByLayout {
		if stats.ByLayout[k] != v {
			t.Errorf("düzen sayımları = %v, beklenen %v", stats.ByLayout, wantByLayout)
			break
		}
	}
	// Satır: 5+2+2+1+1+2+1+2 (+ tanınmayan 1+2) + dolgu 100. Okunamayan: kısa
	// kutu satırı, "yok" fiyatlı kutu satırı, fiyatı "Fiyat sorunuz" olan
	// sandviç satırı. Tekrar: ikinci "20×80 / 2,5".
	if stats.Rows != 19+100 || stats.Malformed != 3 || stats.Unpriced != 2 || stats.UnknownRows != 3 || stats.Duplicates != 1 {
		t.Errorf("sayımlar yanlış: %+v", stats)
	}

	// Uyarılar: tanınmayan iki bölüm, kalem sayısı tutmayan Npu, okunamayan satırlar.
	for _, frag := range []string{`"Boyalı Kutu Profil (1 kalem)" bölümü atlandı`, `"Yeni Aile (2 kalem)" bölümü atlandı`,
		`"Npu Profil (3 kalem)" bölümünde 3 kalem bekleniyordu, 1 satır bulundu`, "3 satır okunamadığı için atlandı"} {
		found := false
		for _, w := range list.Warnings {
			found = found || strings.Contains(w, frag)
		}
		if !found {
			t.Errorf("uyarı bulunamadı: %q (uyarılar: %q)", frag, list.Warnings)
		}
	}
	if len(list.Warnings) != 4 {
		t.Errorf("uyarı sayısı = %d, beklenen 4: %q", len(list.Warnings), list.Warnings)
	}
	// Bağlantı listeleri, "Kaliteler", "|" içeren "Kullanım notu" düz yazısı
	// ve çatı ürünleri ürün üretmez.
	for _, it := range list.Items {
		if strings.Contains(it.Name, "Trapez") || strings.Contains(it.Name, "ST44") || strings.Contains(it.Name, "Gizemli") ||
			strings.Contains(it.Category, "Kullanım") || strings.Contains(it.Category, "Kaliteler") || strings.Contains(it.Category, "Boyalı") {
			t.Errorf("atlanması gereken satır ürün oldu: %+v", it)
		}
	}
}

// TestParseDemirProfilNeverUsesVATIncludedColumns: "KDV dahil" kolonlar
// fiyat olarak ASLA okunmaz -- ne kendi düzeninde (fixture'daki KDV dahil
// değerleri hiçbir üründe yok), ne fiyat kolonu okunamadığında yedek olarak
// (sandviç "Fiyat sorunuz"), ne de düzende ₺/m yerine yalnızca "KDV dahil
// ₺/m" varken (bölüm tanınmaz, atlanır).
func TestParseDemirProfilNeverUsesVATIncludedColumns(t *testing.T) {
	list, _ := mustParseDemirProfil(t, withFiller(readFixture(t, "testdata/demirprofil_fixture.txt"), 100))
	vatIncluded := []string{"1249.92", "7498.80", "999.99", "1296", "290.16", "396", "642.60", "630", "37.92", "227.52", "1"}
	for _, it := range list.Items {
		for _, v := range vatIncluded {
			if it.Price.Equal(decimal.RequireFromString(v)) {
				t.Errorf("%q fiyatı %s: KDV dahil kolondan okunmuş", it.Name, it.Price)
			}
		}
	}
	if findItem(list.Items, "5cm Sandviç Panel") != nil {
		t.Error("fiyatı okunamayan satır KDV dahil kolona düşmemeli, atlanmalı")
	}
	if findItem(list.Items, "Boyalı Kutu Profil 10×20×1,2 mm") != nil {
		t.Error("₺/m yerine yalnızca KDV dahil ₺/m olan bölüm tanınmamalı")
	}
	// Düzen tanımlarının hiçbiri KDV dahil kolondan fiyat okumaz.
	for _, l := range demirProfilLayouts {
		if strings.HasPrefix(l.price, vatIncludedPrefix) {
			t.Errorf("%s düzeni KDV dahil kolondan fiyat okuyor: %q", l.key, l.price)
		}
	}
}

func TestParseDemirProfilUnknownHeader(t *testing.T) {
	text := withFiller(`> Liste Ekim 2026, KDV hariç, toptan.

## Kutu Profil (2 kalem)

ebat (mm) | et (mm) | kg/m | ₺/m | ₺/boy | KDV dahil ₺/boy | yeni kolon
- 10×10 | 1 | 0,3 | 20,00 | 120,00 | 144,00 | x
- 10×20 | 1 | 0,4 | 25,00 | 150,00 | 180,00 | y

## Tekrarlı Kolon (1 kalem)

ölçü | ₺/kg | ₺/kg
- 50 Köşebent | 35,00 | 36,00
`, 100)
	list, stats := mustParseDemirProfil(t, text)
	if len(list.Items) != 100 || stats.UnknownRows != 3 {
		t.Fatalf("tanınmayan bölümler atlanmalı: %d ürün, %+v", len(list.Items), stats)
	}
	if len(list.Warnings) != 2 || !strings.Contains(list.Warnings[0], "tanınmayan başlık") || !strings.Contains(list.Warnings[1], "Tekrarlı Kolon") {
		t.Fatalf("tanınmayan başlık uyarısı bekleniyordu: %q", list.Warnings)
	}
	if list.Label != "Ekim 2026" {
		t.Fatalf("dönem = %q", list.Label)
	}
}

func TestParseDemirProfilMalformedRows(t *testing.T) {
	text := withFiller(`> Liste Eylül 2026, KDV hariç, toptan.

## Köşebent (6 kalem)

ölçü | ₺/kg | not
- 25 Köşebent | 36,70 | not
- 30 Köşebent | 35,70
- 40 Köşebent | 35,70 | not | fazla
- 50 Köşebent | 0 | not
-  | 35,70 | adsız
- 60 Köşebent | -3 | negatif
`, 100)
	list, stats := mustParseDemirProfil(t, text)
	if it := findItem(list.Items, "25 Köşebent"); it == nil || !it.Price.Equal(decimal.RequireFromString("36.70")) {
		t.Fatalf("geçerli satır okunmalı: %+v", it)
	}
	for _, name := range []string{"30 Köşebent", "40 Köşebent", "50 Köşebent", "60 Köşebent"} {
		if findItem(list.Items, name) != nil {
			t.Errorf("%q atlanmalıydı", name)
		}
	}
	if stats.Malformed != 5 || len(list.Items) != 101 {
		t.Fatalf("okunamayan satır = %d (beklenen 5), ürün %d", stats.Malformed, len(list.Items))
	}
}

// TestParseDemirProfilBlankNameCells: adı oluşturan hücrelerden biri boş
// olan satır ("Paslanmaz Kutu Profil × mm", "mm Ø") ürün OLMAZ, okunamayan
// sayılır; adın parçası olmayan boş hücreler (not, kalınlık) sorun değildir.
func TestParseDemirProfilBlankNameCells(t *testing.T) {
	text := withFiller(`> Liste Eylül 2026, KDV hariç, toptan.

## Paslanmaz Kutu Profil (3 kalem)

ebat (mm) | et (mm) | kg/m | ₺/m | ₺/boy | KDV dahil ₺/boy
- 10×15 | 1 | 0,370 | 71,25 | 427,50 | 513,00
-  |  | 0,370 | 71,26 | 427,56 | 513,07
- 10×20 |  | 0,370 | 71,27 | 427,62 | 513,14

## Çelik Çekme Boru (2 kalem)

dış çap (mm) | et (mm) | kg/m | ₺/m | ₺/boy | KDV dahil ₺/boy
- Ø21,3 |  | 0,952 | 40,30 | 241,80 | 290,16
-  | 2 | 0,952 | 40,31 | 241,86 | 290,23

## Delikli Sac (3 kalem)

malzeme | kalınlık | delik Ø | ebat | ₺/adet
-  |  |  |  | 1254
- DKP Delikli Sac | 1 |  | 1000x2000 | 1255
- DKP Delikli Sac | 1 | 4 | 1000x2000 | 1256

## Galvaniz Sac (2 kalem)

ürün | kalınlık (mm) | ₺/ton | ₺/kg | kg/m² | ₺/m²
-  | 1 | 51.075 | 51,08 | 2,36 | 120,00
- 1mm Galvaniz sac |  | 51.075 | 51,08 |  |

## Köşebent (2 kalem)

ölçü | ₺/kg | not
-  | 35,00 | not
- 50 Köşebent | 35,00 |
`, 100)
	list, stats := mustParseDemirProfil(t, text)
	for _, name := range []string{"Paslanmaz Kutu Profil 10×15×1 mm", "DKP Delikli Sac 1 mm Ø4 1000x2000", "1mm Galvaniz sac", "50 Köşebent"} {
		if findItem(list.Items, name) == nil {
			t.Errorf("%q okunmalıydı", name)
		}
	}
	// Okunamayan: kutu 2, boru 2, delikli 2, sac 1, köşebent 1.
	if len(list.Items) != 4+100 || stats.Malformed != 8 {
		for _, it := range list.Items[:min(len(list.Items), 8)] {
			t.Logf("%q", it.Name)
		}
		t.Fatalf("ürün %d (beklenen 104), okunamayan %d (beklenen 8)", len(list.Items), stats.Malformed)
	}
	for _, it := range list.Items {
		if strings.Contains(it.Name, "× mm") || strings.Contains(it.Name, " ×") || strings.HasPrefix(it.Name, "mm") || strings.Contains(it.Name, "Ø ") {
			t.Errorf("anlamsız adlı ürün: %q", it.Name)
		}
	}
}

// TestParseDemirProfilHeadingLevels: bir aile tablosu "## " dışında bir
// başlık altında gelirse sessizce kaybolmaz -- "(N kalem)" diyen daha derin
// başlıklar ve boşluksuz "##" bölüm açar; bölüm dışındaki tablo satırları
// ve tablosuz "(N kalem)" bölümü uyarılır. "(N kalem)" demeyen derin
// başlıklar (bağlantı listeleri) bölüm açmaz, uyarı üretmez.
func TestParseDemirProfilHeadingLevels(t *testing.T) {
	text := withFiller(`# demirprofil.com.tr
> Liste Eylül 2026, KDV hariç, toptan.

## Tam gam
### Profil ([hub](https://www.demirprofil.com.tr/profil-fiyatlari/))
- [Kutu profil](https://www.demirprofil.com.tr/kutu-profil/)

# Tam fiyat listesi (Eylül 2026; KDV hariç)

### Derin Aile (2 kalem)

ölçü | ₺/kg | not
- 50 Köşebent | 35,00 |
- 60 Köşebent | 36,00 |

##Bitişik Aile (1 kalem)
ölçü | ₺/kg | not
- 70 Köşebent | 37,00 |

#### Bağlantılar
- 80 Köşebent | 38,00 | başlıksız tablo satırı

## Bölünmüş Aile (3 kalem)

Bu ailenin tablosu alt başlıklarda.
`, 100)
	list, stats := mustParseDemirProfil(t, text)
	for name, category := range map[string]string{"50 Köşebent": "Derin Aile", "60 Köşebent": "Derin Aile", "70 Köşebent": "Bitişik Aile"} {
		if it := findItem(list.Items, name); it == nil || it.Category != category {
			t.Errorf("%q, %q kategorisinde okunmalıydı: %+v", name, category, it)
		}
	}
	if findItem(list.Items, "80 Köşebent") != nil || len(list.Items) != 3+100 || stats.UnknownRows != 1 {
		t.Fatalf("bölüm dışı satır atlanmalı: %d ürün, %+v", len(list.Items), stats)
	}
	wantWarnings := []string{"1 tablo satırı bir aile başlığı", `"Bölünmüş Aile (3 kalem)" bölümünde tablo bulunamadı`}
	if len(list.Warnings) != len(wantWarnings) {
		t.Fatalf("uyarılar = %q, beklenen %q", list.Warnings, wantWarnings)
	}
	for _, frag := range wantWarnings {
		found := false
		for _, w := range list.Warnings {
			found = found || strings.Contains(w, frag)
		}
		if !found {
			t.Errorf("uyarı bulunamadı: %q (uyarılar: %q)", frag, list.Warnings)
		}
	}
}

func TestParseDemirProfilListLabel(t *testing.T) {
	cases := map[string]string{
		"> Liste Eylül 2026, haftalık yenilenir, KDV hariç, toptan.": "Eylül 2026",
		"> Fiyatlar. Liste Şubat 2027; KDV hariç, toptan.":           "Şubat 2027",
		"> Liste fiyatları 2026, KDV hariç, toptan.":                 "",
		"> Liste Eylul 2026, KDV hariç, toptan.":                     "", // Türkçe ay adı değil
		"> KDV hariç, toptan.":                                       "",
		// Alıntı bloğu birden çok satıra bölünmüş: satırlar birleştirilir.
		"# Başlık\n\n> Demir profil fiyat ve ölçü sitesi;\n> Liste Ekim 2026, haftalık yenilenir,\n>\n> KDV hariç, toptan.": "Ekim 2026",
		// İlk "Liste <kelime> <yıl>" bir ay değil: sonraki geçerli eşleşme alınır.
		"> Liste fiyatları 2026 güncel; Liste Eylül 2026, KDV hariç, toptan.": "Eylül 2026",
		// Özette dönem yok: "Tam fiyat listesi (<Ay> <Yıl>; ...)" başlığı yedektir.
		"> KDV hariç, toptan.\n\n# Tam fiyat listesi (Kasım 2026; toptan liste fiyatları, KDV hariç)": "Kasım 2026",
		"> KDV hariç, toptan.\n\n# Tam fiyat listesi (Güncel 2026; toptan)":                           "",
		// Yalnızca İLK alıntı bloğu özettir; sonraki bloktaki dönem alınmaz.
		"> KDV hariç, toptan.\n\nAra metin.\n\n> Liste Mart 2026": "",
	}
	for summary, want := range cases {
		list, _ := mustParseDemirProfil(t, withFiller(summary+"\n", 100))
		if list.Label != want {
			t.Errorf("%q: dönem = %q, beklenen %q", summary, list.Label, want)
		}
		hasWarning := false
		for _, w := range list.Warnings {
			hasWarning = hasWarning || strings.Contains(w, "liste dönemi")
			// Bölünmüş özet de "KDV hariç"i içerir: sahte uyarı olmamalı.
			if strings.Contains(w, "KDV hariç") {
				t.Errorf("%q: beklenmeyen KDV uyarısı: %q", summary, w)
			}
		}
		if hasWarning != (want == "") {
			t.Errorf("%q: dönem uyarısı = %v", summary, hasWarning)
		}
	}
	// "KDV hariç" ibaresi kaybolursa uyarılır (fiyat esası değişmiş olabilir).
	list, _ := mustParseDemirProfil(t, withFiller("> Liste Eylül 2026, KDV dahil fiyatlar.\n", 100))
	if len(list.Warnings) != 1 || !strings.Contains(list.Warnings[0], "KDV hariç") {
		t.Fatalf("KDV hariç uyarısı bekleniyordu: %q", list.Warnings)
	}
}

func TestParseDemirProfilTooFewItems(t *testing.T) {
	for name, text := range map[string]string{
		"fixture tek başına (10 ürün)": readFixture(t, "testdata/demirprofil_fixture.txt"),
		"99 ürün":                      withFiller("> Liste Eylül 2026, KDV hariç, toptan.\n", 99),
		"boş dosya":                    "",
		"HTML hata sayfası":            "<html><body><h1>503</h1></body></html>",
	} {
		list, _, err := ParseDemirProfil(strings.NewReader(text))
		if !errors.Is(err, ErrTooFewItems) || list.Items != nil {
			t.Errorf("%s: ErrTooFewItems bekleniyordu, geldi %v (%d ürün)", name, err, len(list.Items))
		}
	}
	if _, _, err := ParseDemirProfil(strings.NewReader(withFiller("", 100))); err != nil {
		t.Fatalf("100 ürün eşiği geçmeli: %v", err)
	}
}

// TestParseDemirProfilRealSnapshot, gerçek dosyanın yerel bir kopyasıyla
// (repo'ya EKLENMEZ) isteğe bağlı bir akıl sağlığı kontrolüdür:
// DEMIRPROFIL_SNAPSHOT=/yol/llms-full.txt go test -run Snapshot -v ./internal/pricesource/
func TestParseDemirProfilRealSnapshot(t *testing.T) {
	path := os.Getenv("DEMIRPROFIL_SNAPSHOT")
	if path == "" {
		t.Skip("DEMIRPROFIL_SNAPSHOT ayarlanmamış, atlanıyor")
	}
	list, stats, err := ParseDemirProfil(mustOpen(t, path))
	if err != nil {
		t.Fatalf("ayrıştırma hatası: %v", err)
	}
	cats := map[string]int{}
	for _, it := range list.Items {
		if it.Category == "" || it.Name == "" || it.Unit == "" || !it.Price.IsPositive() {
			t.Errorf("eksik alanlı ürün: %+v", it)
		}
		cats[it.Category]++
	}
	t.Logf("%d ürün, %d kategori, dönem %q, sayımlar %+v, uyarılar %q", len(list.Items), len(cats), list.Label, stats, list.Warnings)
	// 27.09.2026 anlık görüntüsü: 3042 satır, 20'si fiyatsız çatı ürünü.
	// Başka bir haftaya ait kopyayla bu sayılar değişebilir.
	if len(list.Items) != 3022 || stats.Rows != 3042 || stats.Unpriced != 20 || stats.Malformed != 0 || len(list.Warnings) != 0 {
		t.Fatalf("ürün/satır/fiyatsız/okunamayan/uyarı = %d/%d/%d/%d/%d, beklenen 3022/3042/20/0/0",
			len(list.Items), stats.Rows, stats.Unpriced, stats.Malformed, len(list.Warnings))
	}
	spot := []struct{ name, unit, category, price string }{
		{"Siyah Kutu Profil 20×80×2,5 mm", "mt", "Siyah Kutu Profil", ""},
		{"Siyah Çelik Boru Ø21,3×2 mm", "mt", "Siyah Çelik Boru", ""},
		{"0,30mm Galvaniz sac", "kg", "Galvaniz Sac", "51.08"},
		{"100 H Profil", "kg", "H profil", "34.30"},
		{"4cm 0,30mm Sandviç Panel", "m2", "Sandviç Panel", "535.50"},
		{"DKP Delikli Sac 1 mm Ø4 1000x2000", "adet", "Delikli Sac", "1254"},
	}
	for _, s := range spot {
		it := findItem(list.Items, s.name)
		if it == nil || it.Unit != s.unit || it.Category != s.category ||
			(s.price != "" && !it.Price.Equal(decimal.RequireFromString(s.price))) {
			t.Errorf("%q beklenen %+v, bulunan %+v", s.name, s, it)
		}
	}
}

func TestFetchDemirProfil(t *testing.T) {
	ctx := context.Background()
	valid := withFiller("> Liste Eylül 2026, KDV hariç, toptan.\n", 120)

	t.Run("başarılı indirme: sabit URL, tarayıcı UA, BOM atlanır", func(t *testing.T) {
		client, rt := testClient(t, func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "text/plain; charset=utf-8")
			_, _ = io.WriteString(w, "\uFEFF"+valid)
		})
		list, err := FetchDemirProfil(ctx, client)
		if err != nil {
			t.Fatalf("hata: %v", err)
		}
		if len(list.Items) != 120 || list.Label != "Eylül 2026" || list.Items[0].Category != "Dolgu Kutu Profil" {
			t.Fatalf("beklenmeyen sonuç: %d ürün, dönem %q", len(list.Items), list.Label)
		}
		if rt.seen.URL.String() != DemirProfilURL || !strings.Contains(rt.seen.Header.Get("User-Agent"), "Mozilla/5.0") {
			t.Fatalf("istek sabit URL'e tarayıcı User-Agent'ı ile gitmeli: %s %q", rt.seen.URL, rt.seen.Header.Get("User-Agent"))
		}
	})

	t.Run("2xx dışı yanıt hatadır", func(t *testing.T) {
		client, _ := testClient(t, func(w http.ResponseWriter, r *http.Request) {
			http.Error(w, "yok", http.StatusNotFound)
		})
		_, err := FetchDemirProfil(ctx, client)
		var statusErr *HTTPStatusError
		if !errors.As(err, &statusErr) || statusErr.StatusCode != http.StatusNotFound {
			t.Fatalf("404 hatası bekleniyordu, geldi %v", err)
		}
		if msg := PublicErrorMessage(DemirProfilName, err); msg != "Demir Profil sunucusu HTTP 404 döndü" {
			t.Fatalf("kamuya açık metin yanlış: %q", msg)
		}
	})

	t.Run("site dışına yönlendirme izlenmez", func(t *testing.T) {
		internalHits := 0
		internal := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			internalHits++
		}))
		t.Cleanup(internal.Close)
		for _, target := range []string{
			internal.URL + "/latest/meta-data/",
			"http://www.demirprofil.com.tr/llms-full.txt",
			"https://www.demirprofil.com.tr.saldirgan.example/llms-full.txt",
			"https://www.demirprofil.com.tr:8443/llms-full.txt",
			"https://ulas.com.tr/flist.asp", // başka bir tedarikçi de olsa izin yok
		} {
			client, _ := testClient(t, func(w http.ResponseWriter, r *http.Request) {
				http.Redirect(w, r, target, http.StatusFound)
			})
			_, err := FetchDemirProfil(ctx, client)
			if !errors.Is(err, ErrUnexpectedRedirect) {
				t.Fatalf("%s: ErrUnexpectedRedirect bekleniyordu, geldi %v", target, err)
			}
		}
		if internalHits != 0 {
			t.Fatalf("iç ağ sunucusuna %d istek gitti", internalHits)
		}
	})

	t.Run("site içi https yönlendirme izlenir", func(t *testing.T) {
		client, _ := testClient(t, func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path == "/llms-full.txt" && r.URL.Query().Get("v") == "" {
				http.Redirect(w, r, "https://demirprofil.com.tr/llms-full.txt?v=2", http.StatusMovedPermanently)
				return
			}
			_, _ = io.WriteString(w, valid)
		})
		if list, err := FetchDemirProfil(ctx, client); err != nil || len(list.Items) != 120 {
			t.Fatalf("site içi yönlendirme izlenmeliydi: %d %v", len(list.Items), err)
		}
	})

	t.Run("UTF-8 olmayan içerik reddedilir", func(t *testing.T) {
		client, _ := testClient(t, func(w http.ResponseWriter, r *http.Request) {
			_, _ = io.WriteString(w, strings.ReplaceAll(valid, "Dolgu", "D\xf6lgu")) // latin-1 'ö'
		})
		if _, err := FetchDemirProfil(ctx, client); !errors.Is(err, ErrCharset) {
			t.Fatalf("ErrCharset bekleniyordu, geldi %v", err)
		}
	})

	t.Run("boyut sınırı ve yarım dosya hatadır", func(t *testing.T) {
		client, _ := testClient(t, func(w http.ResponseWriter, r *http.Request) {
			_, _ = w.Write([]byte(strings.Repeat("a", maxBodyBytes+10)))
		})
		if _, err := FetchDemirProfil(ctx, client); !errors.Is(err, ErrTooLarge) {
			t.Fatalf("ErrTooLarge bekleniyordu, geldi %v", err)
		}
		client, _ = testClient(t, func(w http.ResponseWriter, r *http.Request) {
			_, _ = io.WriteString(w, valid[:len(valid)/3])
		})
		_, err := FetchDemirProfil(ctx, client)
		if !errors.Is(err, ErrTooFewItems) {
			t.Fatalf("ErrTooFewItems bekleniyordu, geldi %v", err)
		}
		if msg := PublicErrorMessage(DemirProfilName, err); msg != "Demir Profil fiyat listesinde beklenenden az ürün var (dosya yapısı değişmiş olabilir)" {
			t.Fatalf("kamuya açık metin yanlış: %q", msg)
		}
	})
}
