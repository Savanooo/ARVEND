package service

// Maskeli düzenlemede "sil" işlerinin aynen dönmesi (canlı hata, 2026-10-30):
// silme isteğinin tanınması, açık kaldırma talimatı ve işaretli ikinci görsel.

import (
	"bytes"
	"image"
	"image/color"
	"image/png"
	"strings"
	"testing"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/platform/openai"
)

func TestAIRemovalIntent(t *testing.T) {
	for text, want := range map[string]bool{
		// Canlıdaki istekler.
		"Kalemle seçilen alanı sil":            true,
		"Seçilen yeri sil sadece duvar kalsın": true,
		"Burayı kaldır":                        true,
		// Büyük harf ve aksansız yazım.
		"BURAYI KALDIR":          true,
		"buradaki dolabi kaldir": true,
		"SİL":                    true,
		"Lekeleri temizle":       true,
		"kabloları çıkart":       true,
		"masayı yok et":          true,
		"kutular yok olsun":      true,
		"zemini boşalt":          true,
		"burada eşya kalmasın":   true,
		"silmek istiyorum":       true,
		// Silme olmayanlar.
		"Duvarı griye boya":           false,
		"bu alana pencere ekle":       false,
		"derzlere silikon çek":        false,
		"kaldırım taşı döşe":          false,
		"silindir kolon yap":          false,
		"bunu silme, sadece aydınlat": false,
		"":                            false,
	} {
		if got := aiRemovalIntent(text); got != want {
			t.Errorf("%q: %v (beklenen %v)", text, got, want)
		}
	}
}

func TestAIMaskedEditPrompt(t *testing.T) {
	rm := buildAIMaskedEditPrompt(`Kalemle seçilen "alanı" sil`)
	for _, want := range []string{
		"Completely remove every object inside the marked area",
		"fill that area naturally with the surrounding background",
		"Kalemle seçilen 'alanı' sil",
		"Do not change anything outside the marked area",
		"The second image only marks, in red, the exact area to change",
		"Do not include the red marking in the output",
	} {
		if !strings.Contains(rm, want) {
			t.Errorf("silme talimatında %q yok: %q", want, rm)
		}
	}
	ed := buildAIMaskedEditPrompt("bu alana pencere ekle")
	if strings.Contains(ed, "Completely remove") || !strings.Contains(ed, "make the requested change clearly and completely") ||
		!strings.Contains(ed, "The second image only marks, in red") || strings.Contains(ed, "all other objects unchanged") {
		t.Errorf("maskeli düzenleme talimatı: %q", ed)
	}
	// Maskesiz düzenleme: silme isteği açık talimat alır, diğerleri değişmedi.
	if p := buildAIImagePrompt(domain.AIImageKindEdit, "Burayı kaldır", true); !strings.Contains(p, "Completely remove what this request describes") {
		t.Errorf("maskesiz silme: %q", p)
	}
	if p := buildAIImagePrompt(domain.AIImageKindEdit, "duvarı griye boya", true); !strings.Contains(p, "Apply only the requested change") {
		t.Errorf("maskesiz düzenleme değişmemeli: %q", p)
	}
}

func TestMarkMaskedArea(t *testing.T) {
	src, mask, err := prepareMaskedEdit(openai.InputImage{Data: testEncodedJPEG(t, 40, 30), MIMEType: "image/jpeg"}, testMaskPNG(t, 40, 30, true))
	if err != nil {
		t.Fatal(err)
	}
	marked, err := markMaskedArea(src, mask.Data)
	if err != nil {
		t.Fatal(err)
	}
	if marked.MIMEType != "image/png" {
		t.Fatalf("işaretli görsel PNG olmalı: %s", marked.MIMEType)
	}
	base, _ := png.Decode(bytes.NewReader(src.Data))
	out, err := png.Decode(bytes.NewReader(marked.Data))
	if err != nil || out.Bounds() != base.Bounds() {
		t.Fatalf("işaretli görsel kaynağın boyutunda olmalı: %v %v", err, out)
	}
	rgb := func(img image.Image, x, y int) color.NRGBA {
		return color.NRGBAModel.Convert(img.At(x, y)).(color.NRGBA)
	}
	// Sol üst çeyrek saydam (değişecek yer): kırmızıya çekilmiş.
	in, orig := rgb(out, 5, 5), rgb(base, 5, 5)
	if int(in.R) < int(orig.R)+50 || in.G >= orig.G {
		t.Errorf("işaretli alan kırmızı olmalı: %v (kaynak %v)", in, orig)
	}
	// Dışı birebir aynı.
	if o, b := rgb(out, 35, 25), rgb(base, 35, 25); o != b {
		t.Errorf("işaretin dışı değişmemeli: %v != %v", o, b)
	}
}
