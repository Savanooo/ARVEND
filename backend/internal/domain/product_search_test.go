package domain

import (
	"slices"
	"strings"
	"testing"
)

func TestProductSearchFold(t *testing.T) {
	cases := []struct{ in, want string }{
		// Türkçe harfler NormalizeName ile aynı katlanır.
		{"Galvaniz Kutu Profil 40×40×1,35 mm", "galvaniz kutu profil 40x40x1.35 mm"},
		{"SANDVİÇ PANEL ŞAP ĞÜÖÇI", "sandvic panel sap guoci"},
		// Ölçü ayracı: ×, x, X, * aynı; boşluklu yazım birleşir.
		{"40X40", "40x40"},
		{"40*40", "40x40"},
		{"40 x 40", "40x40"},
		{"40  ×  40 × 2", "40x40x2"},
		// Tek rakamlı zincirde ortadaki rakam da ayraç alır (tekrarlı geçiş).
		{"4 x 5 x 6", "4x5x6"},
		// Rakamlar arasında olmayan x'e dokunulmaz.
		{"Max 40 x mm", "max 40 x mm"},
		{"Paslanmaz Boru Ø38×2 mm", "paslanmaz boru ø38x2 mm"},
	}
	for _, c := range cases {
		if got := ProductSearchFold(c.in); got != c.want {
			t.Errorf("ProductSearchFold(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestProductSearchTerms(t *testing.T) {
	cases := []struct {
		in   string
		want []string
	}{
		{"", nil},
		{"   ", nil},
		{"demir", []string{"demir"}},
		{"Kutu 40", []string{"kutu", "40"}},
		{"paslanmaz  BORU 38", []string{"paslanmaz", "boru", "38"}},
		{"40 x 40", []string{"40x40"}},
		{"Ulaş", []string{"ulas"}},
		// Kelime kenarındaki noktalama atılır, içindeki ondalık kalır.
		{"kutu, profil. (1,35)", []string{"kutu", "profil", "1.35"}},
		// Yalnızca noktalamadan oluşan parça ve tekrarlar düşer.
		{"profil - profil / PROFİL", []string{"profil"}},
	}
	for _, c := range cases {
		if got := ProductSearchTerms(c.in); !slices.Equal(got, c.want) {
			t.Errorf("ProductSearchTerms(%q) = %q, want %q", c.in, got, c.want)
		}
	}

	many := ProductSearchTerms("a1 a2 a3 a4 a5 a6 a7 a8 a9 a10")
	if len(many) != MaxProductSearchTerms || many[0] != "a1" {
		t.Errorf("en fazla %d kelime, ilk kelimeden itibaren: %q", MaxProductSearchTerms, many)
	}
	if got := ProductSearchTerms(strings.Repeat("ab", 500)); len(got) != 1 || len([]rune(got[0])) != maxProductSearchRunes {
		t.Errorf("sorgu %d karakterle sınırlı olmalı: %d", maxProductSearchRunes, len([]rune(got[0])))
	}
}

func TestProductSearchPatterns(t *testing.T) {
	contains, wordStart := ProductSearchPatterns([]string{"kutu", "s_c", "50%", `a\b`})
	if want := []string{"%kutu%", `%s\_c%`, `%50\%%`, `%a\\b%`}; !slices.Equal(contains, want) {
		t.Errorf("contains = %q, want %q", contains, want)
	}
	if want := []string{"% kutu%", `% s\_c%`, `% 50\%%`, `% a\\b%`}; !slices.Equal(wordStart, want) {
		t.Errorf("wordStart = %q, want %q", wordStart, want)
	}
}

func TestProductSearchSources(t *testing.T) {
	codes, labels := ProductSearchSources()
	if len(codes) != len(priceSourceRegistry) || len(labels) != len(codes) {
		t.Fatalf("her kaynak için kod+etiket: %q %q", codes, labels)
	}
	label := func(code string) string {
		i := slices.Index(codes, code)
		if i < 0 {
			t.Fatalf("%s kayıt defterinde yok", code)
		}
		return labels[i]
	}
	for _, term := range []string{"demir", "profil", "demirprofil", "omega", "celik"} {
		if !strings.Contains(label(PriceSourceDemirProfil), term) {
			t.Errorf("Demir Profil etiketi %q içermeli: %q", term, label(PriceSourceDemirProfil))
		}
	}
	for _, q := range []string{"ulaş", "ULAS", "Ulaş"} {
		if !strings.Contains(label(PriceSourceUlas), ProductSearchTerms(q)[0]) {
			t.Errorf("Ulaş etiketi %q ile bulunmalı: %q", q, label(PriceSourceUlas))
		}
	}
	if strings.Contains(label(PriceSourceUlas), "demir") {
		t.Errorf("Ulaş etiketi demir içermemeli: %q", label(PriceSourceUlas))
	}
}
