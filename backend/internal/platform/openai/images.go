// Package openai, OpenAI Images API'sinin (görsel üretme ve düzenleme)
// ihtiyacımız olan iki çağrısı için küçük bir istemcidir. Resmi SDK yerine
// elle yazıldı: yalnızca iki HTTP isteği, bağımlılık eklemeye değmez (FCM
// istemcisiyle aynı karar, bkz. platform/fcm).
//
// Doğrulanan sözleşme (developers.openai.com/api/reference/resources/images,
// 2026-10-29):
//   - POST /v1/images/generations: JSON {model, prompt, size, quality,
//     output_format, n, safety_identifier}.
//   - POST /v1/images/edits: multipart/form-data; giriş görselleri "image[]"
//     dosya parçaları (en çok 16), aynı alanlar form alanı olarak. İsteğe
//     bağlı "mask" parçası (2026-10-30, image-generation rehberi): PNG,
//     alfa kanallı, düzenlenen görselle AYNI biçim ve boyutta (50 MB altı);
//     birden çok görselde ilk görsele uygulanır. GPT görsel modellerinde
//     maskeleme "tamamen talimat tabanlı": model maskeyi rehber olarak
//     kullanır, sınırına birebir uymayabilir.
//   - Yanıt: {"created", "data":[{"b64_json"}], ...}; GPT görsel modelleri
//     her zaman base64 döner (response_format onlarda desteklenmez).
//   - Hata: {"error":{"message","type","code","param"}}; güvenlik reddi
//     code "moderation_blocked"; 429 hem hız sınırı hem kota/kredi bitti
//     (type/code "insufficient_quota", "credit_balance_exhausted").
//
// Anahtar yalnızca Authorization başlığına girer: hata metinlerine, loglara
// ya da yanıtlara hiçbir yolla yazılmaz.
package openai

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/textproto"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const (
	DefaultBaseURL = "https://api.openai.com/v1"
	// DefaultImageModel: düzenleme hassasiyetinin en önemli olduğu işler için
	// önerilen model ("önce/sonra" ve iyileştirme aynı odayı, aynı açıyı
	// korumalı). gpt-image-1 23 Ekim 2026'da kapatıldı.
	DefaultImageModel = "gpt-image-2.5-sunburst"

	// Belgeye göre karmaşık istekler 2 dakikayı bulabilir; istemci bundan
	// uzun bekler, işin kendi zaman aşımı servistedir.
	defaultTimeout = 4 * time.Minute
	// Yanıt üst sınırı: en büyük (3840x2160) görselin base64'ü de sığar.
	maxResponseBytes = 64 << 20
	// MaxInputImageBytes: giriş görseli başına üst sınır (belge: 50 MB'tan
	// küçük).
	MaxInputImageBytes = 50<<20 - 1
)

// ErrNoImage: başarılı yanıt geldi ama içinde görsel yok.
var ErrNoImage = errors.New("openai: yanıtta görsel yok")

type Client struct {
	key        string
	baseURL    string
	http       *http.Client
	retryDelay time.Duration
}

type Option func(*Client)

// WithBaseURL: testlerde sahte sunucu (httptest) için.
func WithBaseURL(u string) Option { return func(c *Client) { c.baseURL = strings.TrimRight(u, "/") } }

func WithHTTPClient(h *http.Client) Option { return func(c *Client) { c.http = h } }

// WithRetryDelay: geçici hatada (5xx, hız sınırı) tek yeniden denemeden
// önceki bekleme (testlerde kısa tutulur).
func WithRetryDelay(d time.Duration) Option { return func(c *Client) { c.retryDelay = d } }

// LoadKeyFile: anahtarı dosyadan okur (sunucuda 600 izinli, servis
// kullanıcısına ait dosya). Hata metinleri anahtarın kendisini asla içermez.
func LoadKeyFile(path string) (string, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("openai: anahtar dosyası okunamadı: %w", err)
	}
	key := strings.TrimSpace(string(raw))
	if key == "" {
		return "", errors.New("openai: anahtar dosyası boş")
	}
	if strings.ContainsAny(key, " \t\r\n") || len(key) > 512 {
		return "", errors.New("openai: anahtar dosyasında tek satır anahtar olmalı")
	}
	return key, nil
}

// KeyFileTooOpen: dosyayı servis kullanıcısından başkası okuyabiliyor mu
// (grup/diğerleri izni). Açılışta uyarı için.
func KeyFileTooOpen(path string) bool {
	st, err := os.Stat(path)
	if err != nil {
		return false
	}
	return st.Mode().Perm()&0o077 != 0
}

func NewFromKeyFile(path string, opts ...Option) (*Client, error) {
	key, err := LoadKeyFile(path)
	if err != nil {
		return nil, err
	}
	return New(key, opts...)
}

func New(key string, opts ...Option) (*Client, error) {
	if strings.TrimSpace(key) == "" {
		return nil, errors.New("openai: anahtar boş")
	}
	c := &Client{
		key:        strings.TrimSpace(key),
		baseURL:    DefaultBaseURL,
		http:       &http.Client{Timeout: defaultTimeout},
		retryDelay: 3 * time.Second,
	}
	for _, o := range opts {
		o(c)
	}
	return c, nil
}

// InputImage: düzenlemeye gönderilen görsel (JPEG, PNG ya da WebP).
type InputImage struct {
	Data     []byte
	MIMEType string
	Name     string
}

// ImageRequest: Images boşsa yeni görsel (generations), doluysa düzenleme
// (edits). Boş alanlar gönderilmez, API varsayılanı geçer.
type ImageRequest struct {
	Model  string
	Prompt string
	Images []InputImage
	// Mask: yalnızca düzenlemede; saydam (alfa 0) alan değişecek yer.
	Mask    *InputImage
	Size    string // "auto", "1024x1024", "1536x1024", "1024x1536"
	Quality string // "low", "medium", "high", "auto" ...
	// OutputFormat: "png", "jpeg", "webp" (API varsayılanı png).
	OutputFormat string
	// InputFidelity: yalnızca destekleyen modellerde (gpt-image-1.5);
	// gpt-image-2 ailesinde gönderilmemeli.
	InputFidelity string
	// SafetyIdentifier: kötüye kullanımda OpenAI'nin kişiyi ayırt etmesi
	// için kişisel veri içermeyen kalıcı kimlik (en çok 128 karakter).
	SafetyIdentifier string
}

type ImageResult struct {
	Data         []byte
	OutputFormat string
	Size         string
}

// APIError: OpenAI'nin hata yanıtı. Message İngilizce ve teknik --
// kullanıcıya değil sunucu loguna.
type APIError struct {
	StatusCode int
	Type       string
	Code       string
	Param      string
	Message    string
}

func (e *APIError) Error() string {
	detail := strings.Trim(e.Type+"/"+e.Code, "/")
	msg := e.Message
	if len(msg) > 300 {
		msg = msg[:300] + "…"
	}
	return fmt.Sprintf("openai: HTTP %d (%s): %s", e.StatusCode, detail, msg)
}

// IsModerationBlocked: istek ya da üretilen görsel güvenlik kurallarına takıldı.
func (e *APIError) IsModerationBlocked() bool {
	return e.Code == "moderation_blocked" || e.Code == "content_policy_violation"
}

// IsQuota: kredi/kota/harcama sınırı bitti -- yeniden denemek işe yaramaz.
func (e *APIError) IsQuota() bool {
	return e.Type == "insufficient_quota" || e.Code == "insufficient_quota" ||
		e.Code == "credit_balance_exhausted" || strings.Contains(e.Code, "spend") ||
		strings.Contains(e.Code, "billing")
}

// retryable: hız sınırı ya da sunucu tarafı geçici hata (kota hariç).
func (e *APIError) retryable() bool {
	switch e.StatusCode {
	case http.StatusTooManyRequests:
		return !e.IsQuota()
	case http.StatusInternalServerError, http.StatusBadGateway, http.StatusServiceUnavailable, http.StatusGatewayTimeout:
		return true
	}
	return false
}

// CreateImage: Images boşsa üretir, doluysa düzenler. Geçici hatada bir kez
// yeniden dener (belgedeki öneri: hız sınırı ve sunucu hatası yeniden
// denenir, kota ve kullanıcı hataları denenmez).
func (c *Client) CreateImage(ctx context.Context, req ImageRequest) (*ImageResult, error) {
	if strings.TrimSpace(req.Prompt) == "" {
		return nil, errors.New("openai: prompt boş")
	}
	var (
		body        []byte
		contentType string
		endpoint    string
		err         error
	)
	if len(req.Images) == 0 {
		endpoint = "/images/generations"
		contentType = "application/json"
		body, err = generationBody(req)
	} else {
		endpoint = "/images/edits"
		body, contentType, err = editBody(req)
	}
	if err != nil {
		return nil, err
	}

	res, err := c.do(ctx, endpoint, contentType, body)
	var apiErr *APIError
	if err != nil && errors.As(err, &apiErr) && apiErr.retryable() {
		wait := c.retryDelay
		select {
		case <-ctx.Done():
			return nil, err
		case <-time.After(wait):
		}
		res, err = c.do(ctx, endpoint, contentType, body)
	}
	return res, err
}

func generationBody(req ImageRequest) ([]byte, error) {
	payload := map[string]any{
		"model":  req.Model,
		"prompt": req.Prompt,
		"n":      1,
	}
	setIf := func(k, v string) {
		if v != "" {
			payload[k] = v
		}
	}
	setIf("size", req.Size)
	setIf("quality", req.Quality)
	setIf("output_format", req.OutputFormat)
	setIf("safety_identifier", req.SafetyIdentifier)
	return json.Marshal(payload)
}

func editBody(req ImageRequest) ([]byte, string, error) {
	var buf bytes.Buffer
	w := multipart.NewWriter(&buf)
	fields := [][2]string{
		{"model", req.Model},
		{"prompt", req.Prompt},
		{"n", "1"},
		{"size", req.Size},
		{"quality", req.Quality},
		{"output_format", req.OutputFormat},
		{"input_fidelity", req.InputFidelity},
		{"safety_identifier", req.SafetyIdentifier},
	}
	for _, f := range fields {
		if f[1] == "" {
			continue
		}
		if err := w.WriteField(f[0], f[1]); err != nil {
			return nil, "", err
		}
	}
	for i, img := range req.Images {
		if len(img.Data) == 0 {
			return nil, "", errors.New("openai: boş giriş görseli")
		}
		if len(img.Data) > MaxInputImageBytes {
			return nil, "", errors.New("openai: giriş görseli 50 MB sınırını aşıyor")
		}
		name := img.Name
		if name == "" {
			name = "image-" + strconv.Itoa(i+1)
		}
		h := make(textproto.MIMEHeader)
		h.Set("Content-Disposition", fmt.Sprintf(`form-data; name="image[]"; filename=%q`, name))
		h.Set("Content-Type", img.MIMEType)
		part, err := w.CreatePart(h)
		if err != nil {
			return nil, "", err
		}
		if _, err := part.Write(img.Data); err != nil {
			return nil, "", err
		}
	}
	if m := req.Mask; m != nil {
		if len(m.Data) == 0 || len(m.Data) > MaxInputImageBytes {
			return nil, "", errors.New("openai: maske boş ya da 50 MB sınırını aşıyor")
		}
		h := make(textproto.MIMEHeader)
		h.Set("Content-Disposition", `form-data; name="mask"; filename="mask.png"`)
		h.Set("Content-Type", "image/png")
		part, err := w.CreatePart(h)
		if err != nil {
			return nil, "", err
		}
		if _, err := part.Write(m.Data); err != nil {
			return nil, "", err
		}
	}
	if err := w.Close(); err != nil {
		return nil, "", err
	}
	return buf.Bytes(), w.FormDataContentType(), nil
}

func (c *Client) do(ctx context.Context, endpoint, contentType string, body []byte) (*ImageResult, error) {
	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, c.baseURL+endpoint, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	httpReq.Header.Set("Authorization", "Bearer "+c.key)
	httpReq.Header.Set("Content-Type", contentType)
	resp, err := c.http.Do(httpReq)
	if err != nil {
		// *url.Error yalnızca yöntem + URL taşır (başlık yok): anahtar sızmaz.
		return nil, fmt.Errorf("openai: istek gönderilemedi: %w", err)
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, maxResponseBytes+1))
	if err != nil {
		return nil, fmt.Errorf("openai: yanıt okunamadı: %w", err)
	}
	if len(raw) > maxResponseBytes {
		return nil, errors.New("openai: yanıt beklenenden büyük")
	}
	if resp.StatusCode != http.StatusOK {
		apiErr := parseAPIError(resp.StatusCode, raw)
		apiErr.Message = redactKeys(apiErr.Message, c.key)
		return nil, apiErr
	}
	var out struct {
		Data []struct {
			B64JSON string `json:"b64_json"`
		} `json:"data"`
		OutputFormat string `json:"output_format"`
		Size         string `json:"size"`
	}
	if err := json.Unmarshal(raw, &out); err != nil {
		return nil, fmt.Errorf("openai: yanıt çözülemedi: %w", err)
	}
	if len(out.Data) == 0 || out.Data[0].B64JSON == "" {
		return nil, ErrNoImage
	}
	img, err := base64.StdEncoding.DecodeString(out.Data[0].B64JSON)
	if err != nil {
		return nil, fmt.Errorf("openai: görsel çözülemedi: %w", err)
	}
	return &ImageResult{Data: img, OutputFormat: out.OutputFormat, Size: out.Size}, nil
}

func parseAPIError(status int, raw []byte) *APIError {
	e := &APIError{StatusCode: status}
	var body struct {
		Error struct {
			Message string          `json:"message"`
			Type    string          `json:"type"`
			Code    json.RawMessage `json:"code"`
			Param   string          `json:"param"`
		} `json:"error"`
	}
	if json.Unmarshal(raw, &body) == nil {
		e.Message = body.Error.Message
		e.Type = body.Error.Type
		e.Param = body.Error.Param
		// code bazen string, bazen sayı/null.
		var code string
		if json.Unmarshal(body.Error.Code, &code) == nil {
			e.Code = code
		} else if len(body.Error.Code) > 0 && string(body.Error.Code) != "null" {
			e.Code = string(body.Error.Code)
		}
	}
	if e.Message == "" {
		e.Message = strings.TrimSpace(string(raw))
	}
	return e
}

// keyLike: OpenAI anahtar biçimi. 401 yanıtı anahtarın maskeli bir parçasını
// ("sk-proj-****abcd") mesajda geri yollar; loga o parça da yazılmasın.
var keyLike = regexp.MustCompile(`sk-[A-Za-z0-9_\-*]{2,}`)

func redactKeys(msg, key string) string {
	if key != "" {
		msg = strings.ReplaceAll(msg, key, "sk-***")
	}
	return keyLike.ReplaceAllString(msg, "sk-***")
}
