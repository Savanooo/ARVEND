package service

// Bölge düzenleme ("kalem", 2026-10-30): kişi fotoğrafta değişecek alanı
// boyar, uygulama bunu maske olarak gönderir; yalnızca 'edit' türünde,
// stüdyoda ve proje ucunda. OpenAI sözleşmesi (image-generation rehberi,
// 2026-10-30 doğrulandı): maske PNG ve alfa kanallı, düzenlenen görselle
// AYNI biçim ve boyutta (50 MB altı), saydam alan değişecek yer. GPT görsel
// modellerinde maskeleme "tamamen talimat tabanlıdır" -- model maskeyi rehber
// olarak kullanır, sınırına birebir uymayabilir; bu yüzden talimata da
// "yalnızca işaretli alanı değiştir" eklenir (buildAIMaskedEditPrompt).
//
// Sunucu kaynağı yeniden boyutlandırmaz: maske kaynağın piksel boyutunda
// olmalı (uygulama maskeyi gönderdiği fotoğrafın boyutunda çizer). "Aynı
// biçim" kuralı için maskeli işte JPEG kaynak gönderilmeden önce PNG'ye
// çevrilir (prepareMaskedEdit).
//
// Canlı hata (2026-10-30): "Kalemle seçilen alanı sil", "Burayı kaldır" gibi
// maskeli işler "bitti" dönüp görsel neredeyse AYNI geldi. Maskenin yönü
// doğruydu; model maskeyi yalnızca rehber sayıyor ve eski talimat ("istenen
// değişikliği yap, gerisini AYNEN koru, diğer nesneler değişmesin") belirsiz
// bir Türkçe istekle birleşince model neredeyse hiçbir şeyi değiştirmiyordu.
// Şimdi: (1) silme isteği tanınır ve açık "tamamen kaldır, arkasını doldur"
// talimatı verilir; (2) maskenin yanında İKİNCİ görsel olarak alanı kırmızıyla
// boyanmış kaynak gider (markMaskedArea); (3) "değiştirme" kısıtı yalnızca
// işaretli alanın DIŞI için söylenir.

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"io"
	"net/http"
	"strings"
	"unicode"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/Savanooo/ARVEND/backend/internal/platform/openai"
	"github.com/Savanooo/ARVEND/backend/internal/platform/storage"
)

// aiMaskMaxBytes: alfa maskesi düz renkli alanlardır, en büyük telefon
// fotoğrafının boyutunda bile birkaç MB'ı geçmez.
const aiMaskMaxBytes = 10 << 20

// aiMarkColor/aiMarkOpacity: ikinci görseldeki işaret -- parlak kırmızı-mor,
// yarı saydam (altındaki nesne görünsün, model neyin işaretlendiğini anlasın).
var aiMarkColor = color.NRGBA{R: 255, G: 0, B: 128, A: 255}

const aiMarkOpacity = 0.55

// aiRemovalStems: silme isteğinin Türkçe kökleri (küçük harf, aksansız --
// bkz. aiFoldTurkish); kelime BAŞINDA aranır ("silin", "kaldırın", "çıkart").
var aiRemovalStems = []string{
	"sil", "kaldir", "temizle", "cikar", "gotur", "bosalt", "kalmasin", "olmasin",
	"kaybol", "uzaklastir", "gitsin", "atin",
}

// aiRemovalPhrases: iki kelimelik silme kalıpları ("yok et", "yok olsun").
var aiRemovalPhrases = []string{"yok et", "yok ed", "yok ols"}

// aiNotRemoval: kökle başlayan ama silme demeyen şantiye sözcükleri --
// "silikon çek", "kaldırım taşı" silme sanılmasın. aiNotRemovalWords:
// olumsuz emir ("bunu silme"), yalnızca kelimenin TAMAMI ("silmek" silmedir).
var aiNotRemoval = []string{"silikon", "silindir", "siluet", "silah", "kaldirim"}

var aiNotRemovalWords = map[string]bool{"silme": true, "kaldirma": true, "cikarma": true}

// aiFoldTurkish: büyük/küçük harf ve Türkçe aksan farkını kaldırır (İ/I/ı -> i,
// ş -> s ...): "BURAYI KALDIR", "kaldır", "kaldir" aynı sayılsın.
func aiFoldTurkish(s string) string {
	return strings.Map(func(r rune) rune {
		switch r {
		case 'İ', 'I', 'ı', 'î', 'Î':
			return 'i'
		case 'ç', 'Ç':
			return 'c'
		case 'ğ', 'Ğ':
			return 'g'
		case 'ö', 'Ö':
			return 'o'
		case 'ş', 'Ş':
			return 's'
		case 'ü', 'Ü', 'û', 'Û':
			return 'u'
		case 'â', 'Â':
			return 'a'
		}
		return unicode.ToLower(r)
	}, s)
}

// aiRemovalIntent: düzenleme isteği bir şeyi KALDIRMAK mı istiyor.
func aiRemovalIntent(text string) bool {
	words := strings.FieldsFunc(aiFoldTurkish(text), func(r rune) bool { return !unicode.IsLetter(r) })
	joined := " " + strings.Join(words, " ")
	for _, p := range aiRemovalPhrases {
		if strings.Contains(joined, " "+p) {
			return true
		}
	}
	for _, w := range words {
		skip := aiNotRemovalWords[w]
		for _, n := range aiNotRemoval {
			if strings.HasPrefix(w, n) {
				skip = true
				break
			}
		}
		if skip {
			continue
		}
		for _, stem := range aiRemovalStems {
			if strings.HasPrefix(w, stem) {
				return true
			}
		}
	}
	return false
}

// buildAIMaskedEditPrompt: maskeli 'edit' talimatı (stüdyo ve proje ucu).
// İşaretli alanın İÇİNDE değişiklik açıkça ve tam istenir; "aynen koru"
// yalnızca DIŞI için. Kullanıcının Türkçe metni tırnak içinde kalır.
func buildAIMaskedEditPrompt(userText string) string {
	quoted := `"` + strings.ReplaceAll(strings.TrimSpace(userText), `"`, "'") + `"`
	var p string
	if aiRemovalIntent(userText) {
		p = "Completely remove every object inside the marked area and fill that area naturally with the surrounding background " +
			"— continue the wall, floor, ceiling, textures and lighting — so it looks like nothing was ever there. " +
			"The request is in Turkish: " + quoted + ". "
	} else {
		p = "Edit the input photo as requested (the request is in Turkish): " + quoted + ". " +
			"Inside the marked area, make the requested change clearly and completely; you may replace, reshape or remove what is there to do it. "
	}
	return p + "Do not change anything outside the marked area: keep the same scene, perspective, camera angle, framing and lighting there. " +
		"The second image only marks, in red, the exact area to change; output the first image edited only in that area. " +
		"Do not include the red marking in the output. Keep it a realistic, natural-looking photograph. No watermark."
}

// markMaskedArea: kaynağın (prepareMaskedEdit'in PNG'si) maskede saydam olan
// (değişecek) yerini yarı saydam kırmızıyla boyar; OpenAI'ye maskenin
// yanında İKİNCİ görsel olarak gider. Maske ilk görsele uygulanır.
func markMaskedArea(src openai.InputImage, mask []byte) (openai.InputImage, error) {
	base, err := png.Decode(bytes.NewReader(src.Data))
	if err != nil {
		return openai.InputImage{}, &aiJobError{ErrAIImageUnreadable.Error()}
	}
	m, err := png.Decode(bytes.NewReader(mask))
	if err != nil {
		return openai.InputImage{}, &aiJobError{ErrAIMaskUnreadable.Error()}
	}
	b, mb := base.Bounds(), m.Bounds()
	out := image.NewNRGBA(b)
	mix := func(c, k uint8) uint8 { return uint8(float64(c)*(1-aiMarkOpacity) + float64(k)*aiMarkOpacity + 0.5) }
	for y := b.Min.Y; y < b.Max.Y; y++ {
		for x := b.Min.X; x < b.Max.X; x++ {
			c := color.NRGBAModel.Convert(base.At(x, y)).(color.NRGBA)
			if _, _, _, a := m.At(mb.Min.X+x-b.Min.X, mb.Min.Y+y-b.Min.Y).RGBA(); a < 0x8000 {
				c = color.NRGBA{R: mix(c.R, aiMarkColor.R), G: mix(c.G, aiMarkColor.G), B: mix(c.B, aiMarkColor.B), A: 255}
			}
			out.SetNRGBA(x, y, c)
		}
	}
	var buf bytes.Buffer
	if err := png.Encode(&buf, out); err != nil {
		return openai.InputImage{}, err
	}
	return openai.InputImage{Data: buf.Bytes(), MIMEType: "image/png", Name: "isaretli-alan.png"}, nil
}

var (
	ErrAIMaskOnlyEdit   = errors.New("Seçili alan (kalemle boyanan yer) yalnızca düzenlemede kullanılır.")
	ErrAIMaskNotPNG     = errors.New("Seçili alan (maske) PNG olmalı.")
	ErrAIMaskTooLarge   = errors.New("Seçili alan dosyası en fazla 10 MB olabilir.")
	ErrAIMaskUnreadable = errors.New("Seçili alan okunamadı; alanı yeniden boyayıp tekrar deneyin.")
	ErrAIMaskEmpty      = errors.New("Değişecek yeri fotoğrafın üzerinde boyayın; seçili alanda boyalı (saydam) yer yok.")
	ErrAIMaskSourceType = errors.New("Bölge düzenleme için fotoğraf JPEG ya da PNG olmalı.")
	// ErrAIMaskSize: errors.Is ile; metni boyutlarla aiMaskSizeError üretir.
	ErrAIMaskSize = errors.New("Seçili alan fotoğrafla aynı boyutta olmalı.")
)

type aiMaskSizeError struct{ sw, sh, mw, mh int }

func (e *aiMaskSizeError) Error() string {
	return fmt.Sprintf("Seçili alan fotoğrafla aynı boyutta olmalı (fotoğraf %d×%d, seçili alan %d×%d piksel).",
		e.sw, e.sh, e.mw, e.mh)
}

func (e *aiMaskSizeError) Is(target error) bool { return target == ErrAIMaskSize }

// readAIMask: yüklenen maskeyi sınırla okur.
func readAIMask(r io.Reader) ([]byte, error) {
	data, err := io.ReadAll(io.LimitReader(r, aiMaskMaxBytes+1))
	if err != nil {
		return nil, ErrAIMaskUnreadable
	}
	if len(data) == 0 {
		return nil, ErrAIMaskUnreadable
	}
	if len(data) > aiMaskMaxBytes {
		return nil, ErrAIMaskTooLarge
	}
	return data, nil
}

// validateAIMask: maske PNG, çözülebilir, en az bir saydam pikseli var (alfa
// kanalı yoksa ya da hepsi opaksa değişecek yer yok demektir) ve kaynakla
// aynı piksel boyutunda. source: OpenAI'ye gidecek kaynak (JPEG/PNG; WebP'nin
// boyutu standart kitaplıkla okunamaz).
func validateAIMask(mask, source []byte) error {
	if http.DetectContentType(mask) != "image/png" {
		return ErrAIMaskNotPNG
	}
	switch http.DetectContentType(source) {
	case "image/jpeg", "image/png":
	default:
		return ErrAIMaskSourceType
	}
	// Kaynağın GÖSTERİLEN boyutu (EXIF yönü uygulanmış): uygulama maskeyi
	// o boyutta çizer.
	sw, sh, err := orientedSize(source)
	if err != nil {
		return ErrAIImageUnreadable
	}
	img, err := png.Decode(bytes.NewReader(mask))
	if err != nil {
		return ErrAIMaskUnreadable
	}
	b := img.Bounds()
	if b.Dx() != sw || b.Dy() != sh {
		return &aiMaskSizeError{sw: sw, sh: sh, mw: b.Dx(), mh: b.Dy()}
	}
	if o, ok := img.(interface{ Opaque() bool }); ok && o.Opaque() {
		return ErrAIMaskEmpty
	}
	return nil
}

// storeAIMask: proje işinde maskeyi kaynak fotoğrafa (depodaki nesne) göre
// doğrular ve depoya yazar; dönen anahtar işe yazılır (denetim). Kaynak,
// işçinin göndereceği haliyle (prepareAIInputImage: GIF -> PNG) ölçülür.
func (s *AIImageService) storeAIMask(ctx context.Context, orgID pgtype.UUID, sourceKey string, mask []byte) (string, error) {
	rc, err := s.projects.store.Open(ctx, sourceKey)
	if err != nil {
		return "", wrapStorageErr(err)
	}
	data, err := io.ReadAll(io.LimitReader(rc, MaxUploadBytes+1))
	rc.Close()
	if err != nil {
		return "", wrapStorageErr(err)
	}
	src, err := prepareAIInputImage(data)
	if err != nil {
		return "", ErrAIMaskSourceType
	}
	if err := validateAIMask(mask, src.Data); err != nil {
		return "", err
	}
	return s.putAIMask(ctx, orgID, mask)
}

func (s *AIImageService) putAIMask(ctx context.Context, orgID pgtype.UUID, mask []byte) (string, error) {
	key := storage.BuildKey("ai-masks", orgID.String(), "jobs", uuid.NewString(), ".png")
	if _, err := s.projects.store.Put(ctx, key, bytes.NewReader(mask)); err != nil {
		return "", wrapStorageErr(err)
	}
	return key, nil
}

// readAIMaskObject: işçi, işin maskesini depodan okur.
func (s *AIImageService) readAIMaskObject(ctx context.Context, key string) ([]byte, error) {
	rc, err := s.projects.store.Open(ctx, key)
	if err != nil {
		if errors.Is(err, storage.ErrNotFound) {
			return nil, &aiJobError{"Seçili alan bulunamadı; alanı yeniden boyayıp tekrar deneyin."}
		}
		return nil, err
	}
	defer rc.Close()
	return io.ReadAll(io.LimitReader(rc, aiMaskMaxBytes+1))
}

// prepareMaskedEdit: işçide, gönderimden hemen önce. Maske yeniden doğrulanır
// (iş açılırken doğrulandı; depodaki dosya değişmiş olamaz ama ucuz) ve JPEG
// kaynak PNG'ye çevrilir: belge maske ile görselin aynı biçimde olmasını
// istiyor.
func prepareMaskedEdit(src openai.InputImage, mask []byte) (openai.InputImage, *openai.InputImage, error) {
	if err := validateAIMask(mask, src.Data); err != nil {
		return openai.InputImage{}, nil, &aiJobError{err.Error()}
	}
	if src.MIMEType != "image/png" {
		decoded, _, err := image.Decode(bytes.NewReader(src.Data))
		if err != nil {
			return openai.InputImage{}, nil, &aiJobError{ErrAIImageUnreadable.Error()}
		}
		// Kaynak normalde zaten dik (prepareAIInputImage); EXIF'li gelirse
		// maskeyle aynı yöne burada çevrilir.
		decoded = applyOrientation(decoded, jpegOrientation(src.Data))
		var buf bytes.Buffer
		if err := png.Encode(&buf, decoded); err != nil {
			return openai.InputImage{}, nil, err
		}
		src = openai.InputImage{Data: buf.Bytes(), MIMEType: "image/png", Name: "kaynak.png"}
	}
	return src, &openai.InputImage{Data: mask, MIMEType: "image/png", Name: "mask.png"}, nil
}
