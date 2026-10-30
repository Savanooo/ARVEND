package service

// Bölge düzenleme ("kalem", 2026-10-30): kişi fotoğrafta değişecek alanı
// boyar, uygulama bunu maske olarak gönderir; yalnızca 'edit' türünde,
// stüdyoda ve proje ucunda. OpenAI sözleşmesi (image-generation rehberi,
// 2026-10-30 doğrulandı): maske PNG ve alfa kanallı, düzenlenen görselle
// AYNI biçim ve boyutta (50 MB altı), saydam alan değişecek yer. GPT görsel
// modellerinde maskeleme "tamamen talimat tabanlıdır" -- model maskeyi rehber
// olarak kullanır, sınırına birebir uymayabilir; bu yüzden talimata da
// "yalnızca işaretli alanı değiştir" eklenir (aiMaskPromptSuffix).
//
// Sunucu kaynağı yeniden boyutlandırmaz: maske kaynağın piksel boyutunda
// olmalı (uygulama maskeyi gönderdiği fotoğrafın boyutunda çizer). "Aynı
// biçim" kuralı için maskeli işte JPEG kaynak gönderilmeden önce PNG'ye
// çevrilir (prepareMaskedEdit).

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"image"
	"image/png"
	"io"
	"net/http"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/Savanooo/ARVEND/backend/internal/platform/openai"
	"github.com/Savanooo/ARVEND/backend/internal/platform/storage"
)

// aiMaskMaxBytes: alfa maskesi düz renkli alanlardır, en büyük telefon
// fotoğrafının boyutunda bile birkaç MB'ı geçmez.
const aiMaskMaxBytes = 10 << 20

const aiMaskPromptSuffix = " Only change the area marked by the mask (its transparent region); keep everything outside that area exactly as it is."

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
