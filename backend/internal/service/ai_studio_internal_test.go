package service

// Yapay Zekâ Stüdyo ve bölge düzenlemenin veritabanı gerektirmeyen
// parçaları: yüklenen kaynağın türü (HEIC dahil), maske kuralları, maskeli
// işte JPEG -> PNG çevirisi ve talimatlar.

import (
	"bytes"
	"errors"
	"image"
	"image/color"
	"image/gif"
	"image/jpeg"
	"image/png"
	"net/http"
	"strings"
	"testing"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/platform/openai"
)

func testEncodedJPEG(t *testing.T, w, h int) []byte {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for x := 0; x < w; x++ {
		for y := 0; y < h; y++ {
			img.Set(x, y, color.RGBA{R: 120, G: 90, B: 60, A: 255})
		}
	}
	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, img, nil); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

// testMaskPNG: w×h maske; transparent=true ise sol üst çeyrek saydam
// (değişecek yer), değilse tamamen opak.
func testMaskPNG(t *testing.T, w, h int, transparent bool) []byte {
	t.Helper()
	img := image.NewNRGBA(image.Rect(0, 0, w, h))
	for x := 0; x < w; x++ {
		for y := 0; y < h; y++ {
			a := uint8(255)
			if transparent && x < w/2 && y < h/2 {
				a = 0
			}
			img.SetNRGBA(x, y, color.NRGBA{A: a})
		}
	}
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func TestStudioSourceImage(t *testing.T) {
	jpg := testEncodedJPEG(t, 40, 30)
	if img, err := studioSourceImage(jpg, false); err != nil || img.MIMEType != "image/jpeg" || !bytes.Equal(img.Data, jpg) {
		t.Errorf("JPEG olduğu gibi kabul edilmeli: %v %v", img.MIMEType, err)
	}
	webp := append([]byte("RIFF\x00\x00\x00\x00WEBPVP8 "), make([]byte, 32)...)
	if img, err := studioSourceImage(webp, false); err != nil || img.MIMEType != "image/webp" {
		t.Errorf("WebP kabul edilmeli: %v %v", img.MIMEType, err)
	}

	heic := append([]byte("\x00\x00\x00\x18ftypheic\x00\x00\x00\x00mif1heic"), make([]byte, 64)...)
	if _, err := studioSourceImage(heic, false); !errors.Is(err, ErrAIImageHEIC) || !strings.Contains(err.Error(), "HEIC") {
		t.Errorf("HEIC anlaşılır Türkçe nedenle reddedilmeli: %v", err)
	}
	// Telefondan GIF reddedilir; sunucudaki (proje) GIF ilk karesiyle PNG olur.
	pal := image.NewPaletted(image.Rect(0, 0, 4, 4), []color.Color{color.White, color.Black})
	var g bytes.Buffer
	if err := gif.Encode(&g, pal, nil); err != nil {
		t.Fatal(err)
	}
	if _, err := studioSourceImage(g.Bytes(), false); !errors.Is(err, ErrAIImageUnsupported) {
		t.Errorf("yüklenen GIF: %v", err)
	}
	if img, err := studioSourceImage(g.Bytes(), true); err != nil || img.MIMEType != "image/png" {
		t.Errorf("proje GIF'i PNG'ye çevrilmeli: %v %v", img.MIMEType, err)
	}
	for name, data := range map[string][]byte{
		"metin": []byte("merhaba dünya"), "BMP": []byte("BM\x00\x00\x00\x00\x00\x00"),
	} {
		if _, err := studioSourceImage(data, false); !errors.Is(err, ErrAIImageUnsupported) {
			t.Errorf("%s: %v", name, err)
		}
	}
	if _, err := studioSourceImage([]byte("\xff\xd8\xff\xe0bozuk"), false); !errors.Is(err, ErrAIImageUnreadable) {
		t.Errorf("bozuk JPEG: %v", err)
	}
	if _, err := studioSourceImage(nil, false); !errors.Is(err, ErrEmptyFile) {
		t.Errorf("boş dosya: %v", err)
	}
	if _, err := studioSourceImage(make([]byte, MaxUploadBytes+1), false); !errors.Is(err, ErrFileTooLarge) {
		t.Errorf("25 MB üstü: %v", err)
	}
}

func TestValidateAIMask(t *testing.T) {
	src := testEncodedJPEG(t, 40, 30)
	if err := validateAIMask(testMaskPNG(t, 40, 30, true), src); err != nil {
		t.Errorf("geçerli maske: %v", err)
	}
	err := validateAIMask(testMaskPNG(t, 30, 40, true), src)
	if !errors.Is(err, ErrAIMaskSize) || !strings.Contains(err.Error(), "40×30") || !strings.Contains(err.Error(), "30×40") {
		t.Errorf("boyut farkı her iki boyutla söylenmeli: %v", err)
	}
	if err := validateAIMask(testEncodedJPEG(t, 40, 30), src); !errors.Is(err, ErrAIMaskNotPNG) {
		t.Errorf("JPEG maske: %v", err)
	}
	if err := validateAIMask(testMaskPNG(t, 40, 30, false), src); !errors.Is(err, ErrAIMaskEmpty) {
		t.Errorf("tamamen opak maske (boyalı yer yok): %v", err)
	}
	if err := validateAIMask([]byte("\x89PNG\r\n\x1a\nbozuk"), src); !errors.Is(err, ErrAIMaskUnreadable) {
		t.Errorf("bozuk PNG: %v", err)
	}
	webp := append([]byte("RIFF\x00\x00\x00\x00WEBPVP8 "), make([]byte, 32)...)
	if err := validateAIMask(testMaskPNG(t, 40, 30, true), webp); !errors.Is(err, ErrAIMaskSourceType) {
		t.Errorf("WebP kaynakta maske: %v", err)
	}
}

func TestPrepareMaskedEdit(t *testing.T) {
	src := openai.InputImage{Data: testEncodedJPEG(t, 40, 30), MIMEType: "image/jpeg", Name: "kaynak.jpg"}
	mask := testMaskPNG(t, 40, 30, true)
	out, m, err := prepareMaskedEdit(src, mask)
	if err != nil {
		t.Fatal(err)
	}
	// Belge: maske ile görsel aynı biçimde -- JPEG kaynak PNG'ye çevrilir.
	if out.MIMEType != "image/png" || http.DetectContentType(out.Data) != "image/png" || m == nil || !bytes.Equal(m.Data, mask) {
		t.Errorf("çıktı: %v, maske %v", out.MIMEType, m != nil)
	}
	cfg, _, err := image.DecodeConfig(bytes.NewReader(out.Data))
	if err != nil || cfg.Width != 40 || cfg.Height != 30 {
		t.Errorf("çevrilen kaynağın boyutu değişmemeli: %+v %v", cfg, err)
	}
	// İşçide geçersiz maske kullanıcıya Türkçe nedenle döner.
	_, _, err = prepareMaskedEdit(src, testMaskPNG(t, 10, 10, true))
	var jobErr *aiJobError
	if !errors.As(err, &jobErr) || !strings.Contains(aiFailureMessage(err), "aynı boyutta") {
		t.Errorf("işçide boyut farkı: %v", err)
	}
}

func TestIsHEIF(t *testing.T) {
	for _, brand := range []string{"heic", "heix", "mif1", "hevc"} {
		if !isHEIF([]byte("\x00\x00\x00\x18ftyp" + brand + "\x00\x00\x00\x00")) {
			t.Errorf("%s HEIF sayılmalı", brand)
		}
	}
	for _, data := range []string{"\x00\x00\x00\x18ftypavif\x00\x00", "\x00\x00\x00\x18ftypisom\x00\x00", "kısa"} {
		if isHEIF([]byte(data)) {
			t.Errorf("%q HEIF değil", data)
		}
	}
}

func TestAIEditPrompts(t *testing.T) {
	// Proje ucu ve stüdyo aynı düzenleme talimatı.
	for _, p := range []string{
		buildAIImagePrompt(domain.AIImageKindEdit, `duvarı "griye" boya`, true),
		buildAIStudioPrompt(domain.AIImageKindEdit, `duvarı "griye" boya`),
	} {
		if !strings.Contains(p, "Apply only the requested change") || !strings.Contains(p, "duvarı 'griye' boya") {
			t.Errorf("düzenleme talimatı: %q", p)
		}
	}
	// Stüdyoda yeni görsel şantiyeye bağlanmaz; proje ucunda bağlanır.
	if p := buildAIStudioPrompt(domain.AIImageKindGenerate, "Kafe logosu"); strings.Contains(p, "construction") || !strings.Contains(p, "Kafe logosu") {
		t.Errorf("stüdyo yeni görsel: %q", p)
	}
	if p := buildAIImagePrompt(domain.AIImageKindGenerate, "Cephe", false); !strings.Contains(p, "construction") {
		t.Errorf("proje yeni görsel: %q", p)
	}
	if p := buildAIStudioPrompt(domain.AIImageKindBeforeAfter, "Laminat parke"); !strings.Contains(p, "same perspective") {
		t.Errorf("stüdyo bitmiş hali proje talimatıyla aynı olmalı: %q", p)
	}
}

// withEXIFOrientation: JPEG'in başına (SOI'den sonra) yalnızca Orientation
// etiketi taşıyan bir EXIF APP1 bölümü ekler -- telefonların yaptığı gibi.
func withEXIFOrientation(t *testing.T, jpg []byte, orientation uint16, bigEndian bool) []byte {
	t.Helper()
	var tiff []byte
	if bigEndian {
		tiff = []byte{'M', 'M', 0, 42, 0, 0, 0, 8, 0, 1, 0x01, 0x12, 0, 3, 0, 0, 0, 1, byte(orientation >> 8), byte(orientation), 0, 0, 0, 0, 0, 0}
	} else {
		tiff = []byte{'I', 'I', 42, 0, 8, 0, 0, 0, 1, 0, 0x12, 0x01, 3, 0, 1, 0, 0, 0, byte(orientation), byte(orientation >> 8), 0, 0, 0, 0, 0, 0}
	}
	payload := append([]byte("Exif\x00\x00"), tiff...)
	seg := append([]byte{0xFF, 0xE1, byte((len(payload) + 2) >> 8), byte(len(payload) + 2)}, payload...)
	out := append([]byte{}, jpg[:2]...)
	out = append(out, seg...)
	return append(out, jpg[2:]...)
}

// cornerJPEG: w×h, sol üst 8×8 kırmızı, gerisi mavi (yön testleri için).
func cornerJPEG(t *testing.T, w, h int) []byte {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for x := 0; x < w; x++ {
		for y := 0; y < h; y++ {
			c := color.RGBA{B: 255, A: 255}
			if x < 8 && y < 8 {
				c = color.RGBA{R: 255, A: 255}
			}
			img.Set(x, y, c)
		}
	}
	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, img, &jpeg.Options{Quality: 95}); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func isRed(c color.Color) bool {
	r, g, b, _ := c.RGBA()
	return r > 0xB000 && g < 0x5000 && b < 0x5000
}

func TestEXIFOrientation(t *testing.T) {
	base := cornerJPEG(t, 32, 24)
	if o := jpegOrientation(base); o != 1 {
		t.Errorf("EXIF'siz JPEG: %d", o)
	}
	for _, be := range []bool{true, false} {
		if o := jpegOrientation(withEXIFOrientation(t, base, 6, be)); o != 6 {
			t.Errorf("EXIF yönü okunamadı (big-endian=%v): %d", be, o)
		}
	}
	rotated := withEXIFOrientation(t, base, 6, false)
	if w, h, err := orientedSize(rotated); err != nil || w != 24 || h != 32 {
		t.Errorf("gösterilen boyut 24×32 olmalı: %d×%d %v", w, h, err)
	}

	// 6: 90° saat yönünde -- kırmızı köşe sol üstten sağ üste geçer;
	// 8: saat yönünün tersine -- sol alta; 3: 180° -- sağ alta.
	decoded, err := jpeg.Decode(bytes.NewReader(base))
	if err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct {
		o, w, h, px, py int
	}{{6, 24, 32, 20, 3}, {8, 24, 32, 3, 28}, {3, 32, 24, 28, 20}, {2, 32, 24, 28, 3}, {5, 24, 32, 3, 3}} {
		out := applyOrientation(decoded, c.o)
		if b := out.Bounds(); b.Dx() != c.w || b.Dy() != c.h || !isRed(out.At(c.px, c.py)) {
			t.Errorf("yön %d: %v, (%d,%d) kırmızı değil", c.o, out.Bounds(), c.px, c.py)
		}
	}

	norm := normalizeJPEGOrientation(rotated)
	cfg, _, err := image.DecodeConfig(bytes.NewReader(norm))
	if err != nil || cfg.Width != 24 || cfg.Height != 32 || jpegOrientation(norm) != 1 {
		t.Errorf("dik hale getirilen JPEG: %+v %v yön=%d", cfg, err, jpegOrientation(norm))
	}
	// prepareAIInputImage de aynısını yapar (OpenAI'ye dik fotoğraf gider).
	if img, err := prepareAIInputImage(rotated); err != nil || !bytes.Equal(img.Data, norm) {
		t.Errorf("prepareAIInputImage yönü uygulamalı: %v", err)
	}

	// Maske, uygulamanın gördüğü (yönü uygulanmış) boyutta kabul edilir.
	if err := validateAIMask(testMaskPNG(t, 24, 32, true), rotated); err != nil {
		t.Errorf("yönlü kaynakta 24×32 maske: %v", err)
	}
	if err := validateAIMask(testMaskPNG(t, 32, 24, true), rotated); !errors.Is(err, ErrAIMaskSize) {
		t.Errorf("yönlü kaynakta ham (32×24) maske reddedilmeli: %v", err)
	}
	// İşçi EXIF'li kaynağı da maskeyle aynı yöne çevirir.
	out, _, err := prepareMaskedEdit(openai.InputImage{Data: rotated, MIMEType: "image/jpeg"}, testMaskPNG(t, 24, 32, true))
	if err != nil {
		t.Fatal(err)
	}
	pngImg, err := png.Decode(bytes.NewReader(out.Data))
	if err != nil || pngImg.Bounds().Dx() != 24 || pngImg.Bounds().Dy() != 32 || !isRed(pngImg.At(20, 3)) {
		t.Errorf("maskeli kaynak dik PNG olmalı: %v %v", pngImg.Bounds(), err)
	}
}
