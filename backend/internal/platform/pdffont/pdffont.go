// Package pdffont, sunucuda üretilen PDF'lerin (maaş dökümü) gömülü
// fontudur. fpdf'in yerleşik fontları (Helvetica vb.) Latin-1'dir; "ş, ğ,
// İ, ı" basılamaz. DejaVu Sans Condensed tam Türkçe karakter kümesini
// içerir ve serbest lisanslıdır (Bitstream Vera türevi; yeniden dağıtım
// serbest) -- dosyalar github.com/go-pdf/fpdf v0.9.0'ın font/ dizininden
// alındı.
package pdffont

import _ "embed"

//go:embed DejaVuSansCondensed.ttf
var Regular []byte

//go:embed DejaVuSansCondensed-Bold.ttf
var Bold []byte

// Family, fpdf'e kaydedilen aile adı.
const Family = "dejavu"
