package main

import "testing"

// BYZ'deki 15 gerçek masraf satırının (2026-10-04) kategori eşlemesi. Yanlış
// kategori proje maliyet raporlarını sessizce bozar -- bu tablo değişirse
// bilinçli değişmeli.
func TestCategorizeRealBYZLines(t *testing.T) {
	cases := []struct{ kalem, not, want string }{
		{"Su tesisat malzemesi", "", "material"},
		{"Yemek", "", "food"},
		{"yemek", "", "food"},
		{"Personel", "", "personnel"},
		{"personel", "", "personnel"},
		{"Doğal gaz tesisat proje", "", "other"},
		{"Demir malzeme", "İlke kart", "material"},
		{"nakliye", "", "transport"},
		{"masraf", "", "other"},
		{"yakıt-masrsf", "", "transport"},
		// Kalem bir kişi adı; ne ödendiği notta yazıyor.
		{"Fatih atar", "Varollar profil ödemesi", "material"},
	}
	for _, c := range cases {
		if got := categorize(c.kalem, c.not); got != c.want {
			t.Errorf("categorize(%q, %q) = %q, beklenen %q", c.kalem, c.not, got, c.want)
		}
	}
}
