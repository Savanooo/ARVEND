package domain

import (
	"strings"
	"unicode"
)

// NormalizeIBAN, IBAN'daki boşlukları atar ve harfleri büyütür ("tr33 0006
// 1005 ..." -> "TR330006100..."). Mobil normalizeIban ile aynı kural.
func NormalizeIBAN(raw string) string {
	var b strings.Builder
	for _, r := range raw {
		if unicode.IsSpace(r) {
			continue
		}
		b.WriteRune(unicode.ToUpper(r))
	}
	return b.String()
}

// ValidIBAN, NORMALİZE edilmiş bir IBAN'ı ISO 13616'ya göre doğrular: iki
// harf ülke kodu, iki kontrol basamağı, 11-30 harf/rakam ve mod-97 = 1. TR
// IBAN'ları 26 karakterdir. Mobil isValidIban ile aynı kural -- tedarikçi
// IBAN'ı kaydedildikten sonra hiçbir ekranda geri okunamadığı için yazım
// hatası sonradan fark edilemez; kayıtta yakalanmalı.
func ValidIBAN(iban string) bool {
	n := len(iban)
	if n < 15 || n > 34 {
		return false
	}
	for i, r := range iban {
		switch {
		case i < 2 && (r < 'A' || r > 'Z'):
			return false
		case i >= 2 && i < 4 && (r < '0' || r > '9'):
			return false
		case i >= 4 && !((r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9')):
			return false
		}
	}
	if strings.HasPrefix(iban, "TR") && n != 26 {
		return false
	}
	rearranged := iban[4:] + iban[:4]
	remainder := 0
	for _, r := range rearranged {
		if r >= 'A' && r <= 'Z' {
			v := int(r-'A') + 10
			remainder = (remainder*100 + v) % 97
		} else {
			remainder = (remainder*10 + int(r-'0')) % 97
		}
	}
	return remainder == 1
}
