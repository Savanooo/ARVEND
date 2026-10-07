package domain

import (
	"strings"
	"unicode"
)

// NormalizePersonName, iki ad soyadın "aynı kişi adı" olup olmadığını
// karşılaştırmak için kullanılan anahtardır (giriş hesabı açılırken aynı
// adlı bağlantısız personeli bulmak, kullanıcı adı değişince personel adını
// eşitlemek). Gösterim için DEĞİL, yalnızca karşılaştırma içindir.
//
// Neden Türkçe harfler de ASCII'ye katlanıyor (yalnızca büyük/küçük harf
// değil): aynı kişi bir ekranda telefon klavyesiyle "Batuhan İnci", başka
// bir ekranda bilgisayarda "BATUHAN INCI" ya da "Batuhan Inci" yazılıyor.
// Yalnızca Türkçe büyük/küçük harf kuralı uygulansa "INCI" -> "ıncı" olur
// ve "inci" ile eşleşmezdi. Yalnızca bir şapka/çengel farkıyla ayrılan iki
// gerçek kişi pratikte yok; AYNI adı taşıyan iki gerçek kişi ise var ve o
// durum burada değil, çağıranda (birden çok aday = otomatik eşleştirme yok)
// ele alınır.
//
// Boşluklar tek boşluğa indirilir, baştaki/sondaki boşluk atılır. Unicode'un
// "i + birleşik nokta" (U+0307) biçimi -- bazı klavyelerin/kopyala-yapıştırın
// "İ" için ürettiği -- noktası atılarak "i" sayılır.
func NormalizePersonName(s string) string {
	var b strings.Builder
	b.Grow(len(s))
	for i, word := range strings.Fields(s) {
		if i > 0 {
			b.WriteByte(' ')
		}
		for _, r := range word {
			if r == '̇' {
				continue
			}
			b.WriteRune(foldTurkishRune(r))
		}
	}
	return b.String()
}

func foldTurkishRune(r rune) rune {
	switch r {
	case 'İ', 'I', 'ı', 'i', 'Î', 'î':
		return 'i'
	case 'Ş', 'ş':
		return 's'
	case 'Ğ', 'ğ':
		return 'g'
	case 'Ü', 'ü', 'Û', 'û':
		return 'u'
	case 'Ö', 'ö':
		return 'o'
	case 'Ç', 'ç':
		return 'c'
	case 'Â', 'â':
		return 'a'
	}
	return unicode.ToLower(r)
}

// SamePersonName, iki adın NormalizePersonName'e göre aynı olup olmadığını
// söyler; boş ad hiçbir adla (boşla da) eşleşmez.
func SamePersonName(a, b string) bool {
	na := NormalizePersonName(a)
	return na != "" && na == NormalizePersonName(b)
}
