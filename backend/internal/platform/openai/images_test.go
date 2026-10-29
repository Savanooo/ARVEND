package openai

// Gerçek API'ye ASLA gidilmez: her test httptest ile sahte bir OpenAI
// sunucusu kurar. Anahtar test değeridir.

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

const testKey = "sk-test-SAHTE-anahtar-123456"

var pngBytes = []byte("\x89PNG\r\n\x1a\n-sahte-gorsel")

func okImageResponse(w http.ResponseWriter, img []byte) {
	_ = json.NewEncoder(w).Encode(map[string]any{
		"created":       1761730000,
		"data":          []map[string]string{{"b64_json": base64.StdEncoding.EncodeToString(img)}},
		"output_format": "jpeg",
		"size":          "1536x1024",
	})
}

func newTestClient(t *testing.T, srv *httptest.Server) *Client {
	t.Helper()
	c, err := New(testKey, WithBaseURL(srv.URL), WithRetryDelay(time.Millisecond))
	if err != nil {
		t.Fatal(err)
	}
	return c
}

func TestGenerateSendsJSON(t *testing.T) {
	var got map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/images/generations" || r.Method != http.MethodPost {
			t.Errorf("yanlış uç: %s %s", r.Method, r.URL.Path)
		}
		if r.Header.Get("Authorization") != "Bearer "+testKey {
			t.Errorf("Authorization: %q", r.Header.Get("Authorization"))
		}
		if !strings.HasPrefix(r.Header.Get("Content-Type"), "application/json") {
			t.Errorf("Content-Type: %q", r.Header.Get("Content-Type"))
		}
		_ = json.NewDecoder(r.Body).Decode(&got)
		okImageResponse(w, pngBytes)
	}))
	defer srv.Close()

	res, err := newTestClient(t, srv).CreateImage(context.Background(), ImageRequest{
		Model: "gpt-image-2.5-sunburst", Prompt: "bir oda", Size: "auto", Quality: "medium",
		OutputFormat: "jpeg", SafetyIdentifier: "abc",
	})
	if err != nil {
		t.Fatal(err)
	}
	if string(res.Data) != string(pngBytes) || res.OutputFormat != "jpeg" {
		t.Fatalf("sonuç: %+v", res)
	}
	want := map[string]any{"model": "gpt-image-2.5-sunburst", "prompt": "bir oda", "size": "auto",
		"quality": "medium", "output_format": "jpeg", "safety_identifier": "abc", "n": float64(1)}
	for k, v := range want {
		if got[k] != v {
			t.Errorf("%s = %v, beklenen %v", k, got[k], v)
		}
	}
	if _, ok := got["input_fidelity"]; ok {
		t.Error("üretimde input_fidelity gönderilmemeli")
	}
	if _, ok := got["response_format"]; ok {
		t.Error("GPT görsel modellerinde response_format desteklenmez, gönderilmemeli")
	}
}

func TestEditSendsMultipartImage(t *testing.T) {
	src := []byte("\xff\xd8\xff\xe0-kaynak-jpeg")
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/images/edits" {
			t.Errorf("yanlış uç: %s", r.URL.Path)
		}
		if err := r.ParseMultipartForm(10 << 20); err != nil {
			t.Fatalf("multipart değil: %v", err)
		}
		if r.FormValue("model") != "gpt-image-1.5" || r.FormValue("prompt") != "boya" || r.FormValue("input_fidelity") != "high" {
			t.Errorf("alanlar: %v", r.MultipartForm.Value)
		}
		files := r.MultipartForm.File["image[]"]
		if len(files) != 1 {
			t.Fatalf("image[] parçası: %d", len(files))
		}
		if files[0].Header.Get("Content-Type") != "image/jpeg" {
			t.Errorf("parça türü: %q", files[0].Header.Get("Content-Type"))
		}
		f, _ := files[0].Open()
		b, _ := io.ReadAll(f)
		if string(b) != string(src) {
			t.Error("gönderilen görsel kaynakla aynı değil")
		}
		okImageResponse(w, pngBytes)
	}))
	defer srv.Close()

	_, err := newTestClient(t, srv).CreateImage(context.Background(), ImageRequest{
		Model: "gpt-image-1.5", Prompt: "boya", InputFidelity: "high",
		Images: []InputImage{{Data: src, MIMEType: "image/jpeg", Name: "kaynak.jpg"}},
	})
	if err != nil {
		t.Fatal(err)
	}
}

func TestAPIErrors(t *testing.T) {
	cases := []struct {
		name       string
		status     int
		body       string
		moderation bool
		quota      bool
		calls      int32
	}{
		{"güvenlik reddi", 400, `{"error":{"message":"blocked","type":"image_generation_user_error","code":"moderation_blocked"}}`, true, false, 1},
		{"geçersiz anahtar", 401, `{"error":{"message":"Incorrect API key provided: sk-test-****3456.","type":"invalid_request_error","code":"invalid_api_key"}}`, false, false, 1},
		{"kredi bitti", 429, `{"error":{"message":"no credits","type":"insufficient_quota","code":"credit_balance_exhausted"}}`, false, true, 1},
		{"hız sınırı bir kez yeniden denenir", 429, `{"error":{"message":"slow down","type":"requests","code":"rate_limit_exceeded"}}`, false, false, 2},
		{"sunucu hatası bir kez yeniden denenir", 503, `{"error":{"message":"overloaded","type":"service_unavailable_error","code":"server_is_overloaded"}}`, false, false, 2},
		{"json olmayan gövde", 502, `<html>bad gateway</html>`, false, false, 2},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var calls atomic.Int32
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				calls.Add(1)
				w.WriteHeader(tc.status)
				_, _ = w.Write([]byte(tc.body))
			}))
			defer srv.Close()
			_, err := newTestClient(t, srv).CreateImage(context.Background(), ImageRequest{Model: "m", Prompt: "p"})
			var apiErr *APIError
			if !errors.As(err, &apiErr) {
				t.Fatalf("APIError bekleniyordu: %v", err)
			}
			if apiErr.StatusCode != tc.status || apiErr.IsModerationBlocked() != tc.moderation || apiErr.IsQuota() != tc.quota {
				t.Errorf("sınıflandırma: %+v", apiErr)
			}
			if calls.Load() != tc.calls {
				t.Errorf("çağrı sayısı %d, beklenen %d", calls.Load(), tc.calls)
			}
			if strings.Contains(err.Error(), testKey) || strings.Contains(err.Error(), "sk-test-****") {
				t.Errorf("hata metninde anahtar (ya da parçası) var: %v", err)
			}
		})
	}
}

func TestEmptyResponseIsError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"created":1,"data":[]}`))
	}))
	defer srv.Close()
	_, err := newTestClient(t, srv).CreateImage(context.Background(), ImageRequest{Model: "m", Prompt: "p"})
	if !errors.Is(err, ErrNoImage) {
		t.Fatalf("ErrNoImage bekleniyordu: %v", err)
	}
}

func TestLoadKeyFile(t *testing.T) {
	dir := t.TempDir()
	write := func(name, content string, mode os.FileMode) string {
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, []byte(content), mode); err != nil {
			t.Fatal(err)
		}
		return p
	}

	if _, err := LoadKeyFile(filepath.Join(dir, "yok")); err == nil {
		t.Error("olmayan dosya hata vermeli")
	}
	if _, err := LoadKeyFile(write("bos", "  \n", 0o600)); err == nil {
		t.Error("boş dosya hata vermeli")
	}
	if _, err := LoadKeyFile(write("iki", "sk-a\nsk-b\n", 0o600)); err == nil || strings.Contains(err.Error(), "sk-a") {
		t.Errorf("çok satırlı dosya anahtarı göstermeden reddedilmeli: %v", err)
	}
	p := write("iyi", testKey+"\n", 0o600)
	key, err := LoadKeyFile(p)
	if err != nil || key != testKey {
		t.Fatalf("anahtar: %q, %v", key, err)
	}
	if KeyFileTooOpen(p) {
		t.Error("600 izinli dosya açık sayılmamalı")
	}
	if !KeyFileTooOpen(write("acik", testKey, 0o644)) {
		t.Error("644 izinli dosya açık sayılmalı")
	}
}
