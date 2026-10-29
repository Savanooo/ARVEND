package service

// Yapay zekâ görsellerinin veritabanı gerektirmeyen parçaları: giriş görseli
// hazırlığı, Türkçe hata metinleri, türe göre talimat.

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"image"
	"image/color"
	"image/gif"
	"net/http"
	"strings"
	"testing"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/platform/openai"
)

func TestPrepareAIInputImage(t *testing.T) {
	jpegHead := []byte("\xff\xd8\xff\xe0\x00\x10JFIF\x00")
	if img, err := prepareAIInputImage(jpegHead); err != nil || img.MIMEType != "image/jpeg" || !bytes.Equal(img.Data, jpegHead) {
		t.Errorf("JPEG olduğu gibi gitmeli: %+v, %v", img.MIMEType, err)
	}

	// GIF: OpenAI kabul etmez -> ilk kare PNG'ye çevrilir.
	pal := image.NewPaletted(image.Rect(0, 0, 4, 4), []color.Color{color.White, color.Black})
	var g bytes.Buffer
	if err := gif.Encode(&g, pal, nil); err != nil {
		t.Fatal(err)
	}
	img, err := prepareAIInputImage(g.Bytes())
	if err != nil || img.MIMEType != "image/png" || http.DetectContentType(img.Data) != "image/png" {
		t.Errorf("GIF PNG'ye çevrilmeli: %+v, %v", img.MIMEType, err)
	}

	// BMP ve tanınmayan baytlar: anlaşılır Türkçe neden.
	for _, data := range [][]byte{[]byte("BM\x00\x00\x00\x00"), []byte("merhaba")} {
		_, err := prepareAIInputImage(data)
		var je *aiJobError
		if !errors.As(err, &je) || !strings.Contains(je.msg, "JPEG ya da PNG") {
			t.Errorf("desteklenmeyen biçim: %v", err)
		}
	}
}

func TestAIFailureMessage(t *testing.T) {
	cases := []struct {
		err  error
		want string
	}{
		{&openai.APIError{StatusCode: 400, Code: "moderation_blocked"}, "güvenlik kurallarına"},
		{&openai.APIError{StatusCode: 401, Code: "invalid_api_key"}, "anahtarı geçersiz"},
		{&openai.APIError{StatusCode: 403}, "kuruluş doğrulaması"},
		{&openai.APIError{StatusCode: 429, Type: "insufficient_quota"}, "kredisi"},
		{&openai.APIError{StatusCode: 429, Code: "rate_limit_exceeded"}, "çok yoğun"},
		{&openai.APIError{StatusCode: 503}, "yanıt vermiyor"},
		{&openai.APIError{StatusCode: 400, Code: "invalid_value"}, "kabul etmedi"},
		{fmt.Errorf("sarılı: %w", context.DeadlineExceeded), "zamanında"},
		{projectClosedError{cancelled: true}, "iptal edildi"},
		{errors.New("bilinmeyen"), "hazırlanamadı"},
	}
	for _, c := range cases {
		if got := aiFailureMessage(c.err); !strings.Contains(got, c.want) {
			t.Errorf("%v -> %q, %q içermeli", c.err, got, c.want)
		}
	}
}

func TestBuildAIImagePrompt(t *testing.T) {
	ba := buildAIImagePrompt(domain.AIImageKindBeforeAfter, `Alçıpan "asma" tavan`, true)
	if !strings.Contains(ba, "same perspective and camera angle") || !strings.Contains(ba, `"Alçıpan 'asma' tavan"`) {
		t.Errorf("önce/sonra: %q", ba)
	}
	en := buildAIImagePrompt(domain.AIImageKindEnhance, "", true)
	if !strings.Contains(en, "Do not add, remove") || strings.Contains(en, "Additional note") {
		t.Errorf("iyileştirme: %q", en)
	}
	if g := buildAIImagePrompt(domain.AIImageKindGenerate, "Cephe", false); strings.Contains(g, "reference photo") {
		t.Errorf("referanssız üretim referanstan söz etmemeli: %q", g)
	}
	if g := buildAIImagePrompt(domain.AIImageKindGenerate, "Cephe", true); !strings.Contains(g, "reference photo") {
		t.Errorf("referanslı üretim: %q", g)
	}
	if aiResultStage(domain.AIImageKindBeforeAfter, domain.PhotoStageBefore) != domain.PhotoStageAfter ||
		aiResultStage(domain.AIImageKindEnhance, domain.PhotoStageBefore) != domain.PhotoStageBefore ||
		aiResultStage(domain.AIImageKindGenerate, "") != domain.PhotoStageProgress {
		t.Error("aşama seçimi")
	}
}
