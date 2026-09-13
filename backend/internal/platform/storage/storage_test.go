package storage

import (
	"context"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Anahtar doğrulaması, dosya yükleme güvenliğinin temel taşı: kullanıcı
// girdisi hiçbir zaman anahtar haline gelmese de, bu kontrolün gerçekten
// tuttuğunu doğruluyoruz.
func TestValidateKeyRejectsTraversal(t *testing.T) {
	bad := []string{
		"", "/etc/passwd", "../secret", "a/../../b", "a//b", "a/./b",
		"./a", "..", "a/..", "\\..\\windows", "a/b/../../../c",
		strings.Repeat("a", 501),
	}
	for _, k := range bad {
		if err := ValidateKey(k); err == nil {
			t.Errorf("tehlikeli anahtar kabul edildi: %q", k)
		}
	}
	good := []string{
		"files/org/proj/abc.pdf",
		"photos/11111111-1111-1111-1111-111111111111/22222222-2222-2222-2222-222222222222/33333333.jpg",
		"a",
	}
	for _, k := range good {
		if err := ValidateKey(k); err != nil {
			t.Errorf("geçerli anahtar reddedildi: %q (%v)", k, err)
		}
	}
}

func TestSafeExt(t *testing.T) {
	cases := map[string]string{
		"rapor.pdf":          ".pdf",
		"FOTO.JPG":           ".jpg",
		"arsiv.tar.gz":       ".gz",
		"dosya":              "",
		"../../etc/passwd":   "",
		"kotu.p hp":          "",
		"uzun.abcdefghijklm": "",
		"nokta.":             "",
	}
	for in, want := range cases {
		if got := SafeExt(in); got != want {
			t.Errorf("SafeExt(%q) = %q, want %q", in, got, want)
		}
	}
}

// LocalStore, kök dizinin DIŞINA yazmayı/okumayı hiçbir koşulda kabul
// etmemeli.
func TestLocalStoreConfinedToRoot(t *testing.T) {
	root := t.TempDir()
	outside := filepath.Join(t.TempDir(), "gizli.txt")
	if err := os.WriteFile(outside, []byte("gizli"), 0o600); err != nil {
		t.Fatal(err)
	}

	s, err := NewLocalStore(root)
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()

	for _, key := range []string{"../gizli.txt", "/etc/passwd", "a/../../gizli.txt"} {
		if _, err := s.Put(ctx, key, strings.NewReader("x")); err == nil {
			t.Errorf("kök dışına yazma kabul edildi: %q", key)
		}
		if _, err := s.Open(ctx, key); err == nil {
			t.Errorf("kök dışından okuma kabul edildi: %q", key)
		}
	}
}

func TestLocalStoreRoundTripAndHash(t *testing.T) {
	s, err := NewLocalStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	content := "merhaba dünya"

	obj, err := s.Put(ctx, "files/org/proj/abc.txt", strings.NewReader(content))
	if err != nil {
		t.Fatalf("yazılamadı: %v", err)
	}
	if obj.Size != int64(len(content)) {
		t.Errorf("boyut yanlış: %d want %d", obj.Size, len(content))
	}
	// "merhaba dünya" için bilinen sha256
	if len(obj.SHA256) != 64 {
		t.Errorf("sha256 beklenen formatta değil: %q", obj.SHA256)
	}

	rc, err := s.Open(ctx, obj.Key)
	if err != nil {
		t.Fatalf("okunamadı: %v", err)
	}
	defer rc.Close()
	got, _ := io.ReadAll(rc)
	if string(got) != content {
		t.Errorf("içerik bozuldu: %q", string(got))
	}

	if err := s.Delete(ctx, obj.Key); err != nil {
		t.Fatalf("silinemedi: %v", err)
	}
	if _, err := s.Open(ctx, obj.Key); err != ErrNotFound {
		t.Errorf("silinen dosya hâlâ açılabiliyor: %v", err)
	}
}
