package service

// Uzaktan güncelleme -- latest.json doğrulaması. Veritabanı gerektirmez:
// her test kendi geçici APP_RELEASES_DIR'ını kurar. Kanıtlanan ilke: diskte
// eksik/bozuk/tutarsız HER ŞEY "yayın yok" sayılır, asla hata ya da yarım
// bir yayın olarak istemciye ulaşmaz.

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

type logCapture struct {
	mu    sync.Mutex
	lines []string
}

func (c *logCapture) logf(format string, args ...any) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.lines = append(c.lines, fmt.Sprintf(format, args...))
}

func (c *logCapture) warnings() []string {
	c.mu.Lock()
	defer c.mu.Unlock()
	var out []string
	for _, l := range c.lines {
		if strings.HasPrefix(l, "UYARI") {
			out = append(out, l)
		}
	}
	return out
}

func newTestAppReleaseService(t *testing.T, dir string) (*AppReleaseService, *logCapture) {
	t.Helper()
	logs := &logCapture{}
	s := NewAppReleaseService(dir)
	s.logf = logs.logf
	return s, logs
}

func testAPKBytes(build int) []byte {
	// Sıkıştırılamayan, build'e göre değişen içerik: farklı build'lerin
	// özetleri kesin farklı olsun.
	b := make([]byte, 64<<10)
	for i := range b {
		b[i] = byte((i*31 + build*7) % 251)
	}
	return b
}

func sha256Hex(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

// writeFileAtomic, yayinla.sh gibi geçici adla yazıp rename eder (yeni inode).
func writeFileAtomic(t *testing.T, path string, data []byte) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(tmp, path); err != nil {
		t.Fatal(err)
	}
}

// publishTestRelease, geçerli bir yayını (APK + latest.json) yazar ve
// latest.json alanlarını döner; mutate verilirse JSON yazılmadan önce
// değiştirilir.
func publishTestRelease(t *testing.T, dir string, build int, mutate func(m map[string]any)) (map[string]any, []byte) {
	t.Helper()
	apk := testAPKBytes(build)
	file := fmt.Sprintf("arvend-%d.apk", build)
	writeFileAtomic(t, filepath.Join(dir, "android", file), apk)
	m := map[string]any{
		"build":        build,
		"version":      fmt.Sprintf("1.%d.0", build),
		"sha256":       sha256Hex(apk),
		"size":         len(apk),
		"notes":        "Yeni ana sayfa ve hata düzeltmeleri",
		"min_build":    0,
		"file":         file,
		"published_at": "2026-09-28T10:00:00Z",
	}
	if mutate != nil {
		mutate(m)
	}
	raw, err := json.Marshal(m)
	if err != nil {
		t.Fatal(err)
	}
	writeFileAtomic(t, filepath.Join(dir, "android", "latest.json"), raw)
	return m, apk
}

func TestAppRelease_ValidRelease(t *testing.T) {
	dir := t.TempDir()
	_, apk := publishTestRelease(t, dir, 3, func(m map[string]any) {
		m["min_build"] = 2
		m["published_at"] = "2026-09-28T13:04:05+03:00"
	})
	s, logs := newTestAppReleaseService(t, dir)

	rel, err := s.Latest("android")
	if err != nil {
		t.Fatalf("Latest: %v", err)
	}
	if rel.Platform != "android" || rel.Build != 3 || rel.Version != "1.3.0" || rel.MinBuild != 2 ||
		rel.SHA256 != sha256Hex(apk) || rel.Size != int64(len(apk)) || rel.File != "arvend-3.apk" ||
		rel.Notes != "Yeni ana sayfa ve hata düzeltmeleri" {
		t.Fatalf("yayın alanları yanlış: %+v", rel)
	}
	want := time.Date(2026, 9, 28, 10, 4, 5, 0, time.UTC)
	if !rel.PublishedAt.Equal(want) {
		t.Fatalf("PublishedAt = %v, want %v", rel.PublishedAt, want)
	}
	if w := logs.warnings(); len(w) != 0 {
		t.Fatalf("geçerli yayında uyarı loglanmamalı: %v", w)
	}

	_, f, err := s.Open("android")
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer f.Close()
	got, err := io.ReadAll(f)
	if err != nil {
		t.Fatal(err)
	}
	if sha256Hex(got) != sha256Hex(apk) {
		t.Fatal("Open farklı baytlar döndü")
	}
}

func TestAppRelease_MissingDirIsNoRelease(t *testing.T) {
	s, logs := newTestAppReleaseService(t, filepath.Join(t.TempDir(), "yok"))
	for i := 0; i < 3; i++ {
		if _, err := s.Latest("android"); !errors.Is(err, ErrAppReleaseNotFound) {
			t.Fatalf("dizin yokken err = %v, want ErrAppReleaseNotFound", err)
		}
		if _, _, err := s.Open("android"); !errors.Is(err, ErrAppReleaseNotFound) {
			t.Fatalf("dizin yokken Open err = %v, want ErrAppReleaseNotFound", err)
		}
	}
	// Uyarı değişiklik başına bir kez: her istekte log yağmuru olmamalı.
	if w := logs.warnings(); len(w) != 1 {
		t.Fatalf("uyarı sayısı = %d, want 1: %v", len(w), w)
	}
}

func TestAppRelease_UnknownPlatform(t *testing.T) {
	dir := t.TempDir()
	publishTestRelease(t, dir, 3, nil)
	s, _ := newTestAppReleaseService(t, dir)
	for _, p := range []string{"", "ios", "Android", "../android", "android/..", "android/"} {
		if _, err := s.Latest(p); !errors.Is(err, ErrUnknownAppPlatform) {
			t.Errorf("platform %q: err = %v, want ErrUnknownAppPlatform", p, err)
		}
		if _, _, err := s.Open(p); !errors.Is(err, ErrUnknownAppPlatform) {
			t.Errorf("platform %q: Open err = %v, want ErrUnknownAppPlatform", p, err)
		}
	}
}

func TestAppRelease_CorruptJSONIsNoRelease(t *testing.T) {
	for name, raw := range map[string]string{
		"bozuk":         `{"build": 3, "version": "1.3.0",`,
		"boş":           ``,
		"dizi":          `[]`,
		"build metin":   `{"build":"3","version":"1.3.0","sha256":"` + strings.Repeat("a", 64) + `","size":1,"file":"arvend-3.apk","published_at":"2026-09-28T10:00:00Z"}`,
		"build kesirli": `{"build":3.5,"version":"1.3.0","sha256":"` + strings.Repeat("a", 64) + `","size":1,"file":"arvend-3.apk","published_at":"2026-09-28T10:00:00Z"}`,
	} {
		t.Run(name, func(t *testing.T) {
			dir := t.TempDir()
			publishTestRelease(t, dir, 3, nil)
			writeFileAtomic(t, filepath.Join(dir, "android", "latest.json"), []byte(raw))
			s, logs := newTestAppReleaseService(t, dir)
			if _, err := s.Latest("android"); !errors.Is(err, ErrAppReleaseNotFound) {
				t.Fatalf("err = %v, want ErrAppReleaseNotFound", err)
			}
			if len(logs.warnings()) == 0 {
				t.Fatal("bozuk latest.json uyarı loglamalı")
			}
		})
	}
}

func TestAppRelease_OversizedManifestIsNoRelease(t *testing.T) {
	dir := t.TempDir()
	publishTestRelease(t, dir, 3, func(m map[string]any) {
		m["padding"] = strings.Repeat("x", maxAppReleaseManifestBytes)
	})
	s, _ := newTestAppReleaseService(t, dir)
	if _, err := s.Latest("android"); !errors.Is(err, ErrAppReleaseNotFound) {
		t.Fatalf("err = %v, want ErrAppReleaseNotFound", err)
	}
}

func TestAppRelease_PathTraversalInFileIsRejected(t *testing.T) {
	for _, file := range []string{
		"../secret.apk",
		"../../secret.apk",
		"/etc/passwd",
		"android/../arvend-3.apk",
		"./arvend-3.apk",
		"arvend-3.apk/../arvend-3.apk",
		"sub/arvend-3.apk",
		`..\arvend-3.apk`,
		"arvend-3.apk\x00",
		"ARVEND-3.apk",
		"arvend-3.APK",
		"arvend-.apk",
		"arvend-3.apk ",
	} {
		t.Run(file, func(t *testing.T) {
			dir := t.TempDir()
			_, apk := publishTestRelease(t, dir, 3, func(m map[string]any) { m["file"] = file })
			// Saldırganın hedeflediği dosyalar gerçekten var ve özeti
			// latest.json'dakiyle tutuyor olsa bile servis etmemeli.
			writeFileAtomic(t, filepath.Join(dir, "secret.apk"), apk)
			writeFileAtomic(t, filepath.Join(dir, "android", "sub", "arvend-3.apk"), apk)
			s, logs := newTestAppReleaseService(t, dir)
			if _, err := s.Latest("android"); !errors.Is(err, ErrAppReleaseNotFound) {
				t.Fatalf("file=%q: err = %v, want ErrAppReleaseNotFound", file, err)
			}
			if _, f, err := s.Open("android"); err == nil {
				f.Close()
				t.Fatalf("file=%q: Open bir dosya döndü", file)
			}
			if len(logs.warnings()) == 0 {
				t.Fatalf("file=%q: uyarı loglanmalı", file)
			}
		})
	}
}

func TestAppRelease_SymlinkIsRejected(t *testing.T) {
	dir := t.TempDir()
	_, apk := publishTestRelease(t, dir, 3, nil)
	outside := filepath.Join(t.TempDir(), "baska.apk")
	if err := os.WriteFile(outside, apk, 0o644); err != nil {
		t.Fatal(err)
	}
	apkPath := filepath.Join(dir, "android", "arvend-3.apk")
	if err := os.Remove(apkPath); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, apkPath); err != nil {
		t.Skipf("sembolik bağ oluşturulamadı: %v", err)
	}
	s, _ := newTestAppReleaseService(t, dir)
	if _, err := s.Latest("android"); !errors.Is(err, ErrAppReleaseNotFound) {
		t.Fatalf("sembolik bağ APK: err = %v, want ErrAppReleaseNotFound", err)
	}
}

func TestAppRelease_SHAAndSizeMismatch(t *testing.T) {
	cases := map[string]func(m map[string]any){
		"sha farklı":     func(m map[string]any) { m["sha256"] = sha256Hex([]byte("başka dosya")) },
		"sha büyük harf": func(m map[string]any) { m["sha256"] = strings.ToUpper(m["sha256"].(string)) },
		"sha kısa":       func(m map[string]any) { m["sha256"] = m["sha256"].(string)[:63] },
		"sha onaltılık değil": func(m map[string]any) {
			m["sha256"] = strings.Repeat("g", 64)
		},
		"size büyük":   func(m map[string]any) { m["size"] = m["size"].(int) + 1 },
		"size küçük":   func(m map[string]any) { m["size"] = m["size"].(int) - 1 },
		"size sıfır":   func(m map[string]any) { m["size"] = 0 },
		"size negatif": func(m map[string]any) { m["size"] = -1 },
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			dir := t.TempDir()
			publishTestRelease(t, dir, 3, mutate)
			s, logs := newTestAppReleaseService(t, dir)
			if _, err := s.Latest("android"); !errors.Is(err, ErrAppReleaseNotFound) {
				t.Fatalf("err = %v, want ErrAppReleaseNotFound", err)
			}
			if _, f, err := s.Open("android"); err == nil {
				f.Close()
				t.Fatal("tutarsız yayında Open bir dosya döndü")
			}
			if len(logs.warnings()) == 0 {
				t.Fatal("tutarsız yayın uyarı loglamalı")
			}
		})
	}
}

func TestAppRelease_InvalidFieldsAreNoRelease(t *testing.T) {
	cases := map[string]func(m map[string]any){
		"build eksik":            func(m map[string]any) { delete(m, "build") },
		"version eksik":          func(m map[string]any) { delete(m, "version") },
		"sha256 eksik":           func(m map[string]any) { delete(m, "sha256") },
		"size eksik":             func(m map[string]any) { delete(m, "size") },
		"file eksik":             func(m map[string]any) { delete(m, "file") },
		"published_at eksik":     func(m map[string]any) { delete(m, "published_at") },
		"build sıfır":            func(m map[string]any) { m["build"] = 0 },
		"build negatif":          func(m map[string]any) { m["build"] = -3 },
		"file build'le tutmuyor": func(m map[string]any) { m["build"] = 4 },
		"version biçimsiz":       func(m map[string]any) { m["version"] = "1.3" },
		"version başlık enjeksiyonu": func(m map[string]any) {
			m["version"] = "1.3.0\"\r\nX-Evil: 1"
		},
		"min_build build'den büyük": func(m map[string]any) { m["min_build"] = 4 },
		"min_build negatif":         func(m map[string]any) { m["min_build"] = -1 },
		"published_at biçimsiz":     func(m map[string]any) { m["published_at"] = "28.09.2026" },
		"notes çok uzun":            func(m map[string]any) { m["notes"] = strings.Repeat("ş", maxAppReleaseNotesBytes) },
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			dir := t.TempDir()
			publishTestRelease(t, dir, 3, mutate)
			s, _ := newTestAppReleaseService(t, dir)
			if _, err := s.Latest("android"); !errors.Is(err, ErrAppReleaseNotFound) {
				t.Fatalf("err = %v, want ErrAppReleaseNotFound", err)
			}
		})
	}
}

func TestAppRelease_MissingAPKIsNoRelease(t *testing.T) {
	dir := t.TempDir()
	publishTestRelease(t, dir, 3, nil)
	if err := os.Remove(filepath.Join(dir, "android", "arvend-3.apk")); err != nil {
		t.Fatal(err)
	}
	s, _ := newTestAppReleaseService(t, dir)
	if _, err := s.Latest("android"); !errors.Is(err, ErrAppReleaseNotFound) {
		t.Fatalf("APK yokken err = %v, want ErrAppReleaseNotFound", err)
	}
}

// Yayınlama sırası (önce APK, sonra latest.json; ikisi de rename) API'yi
// yeniden başlatmadan görünür; eski sürüm yeni JSON gelene kadar sunulur,
// APK sonradan bozulursa yayın hemen geri çekilir.
func TestAppRelease_PicksUpChangesWithoutRestart(t *testing.T) {
	dir := t.TempDir()
	s, logs := newTestAppReleaseService(t, dir)

	if _, err := s.Latest("android"); !errors.Is(err, ErrAppReleaseNotFound) {
		t.Fatalf("başlangıçta err = %v, want ErrAppReleaseNotFound", err)
	}

	publishTestRelease(t, dir, 3, nil)
	rel, err := s.Latest("android")
	if err != nil || rel.Build != 3 {
		t.Fatalf("build 3 görünmeli: %+v, %v", rel, err)
	}

	// Yeni APK yüklendi ama latest.json henüz değişmedi: hâlâ build 3.
	apk4 := testAPKBytes(4)
	writeFileAtomic(t, filepath.Join(dir, "android", "arvend-4.apk"), apk4)
	if rel, err := s.Latest("android"); err != nil || rel.Build != 3 {
		t.Fatalf("latest.json değişmeden build 3 kalmalı: %+v, %v", rel, err)
	}

	publishTestRelease(t, dir, 4, nil)
	rel, err = s.Latest("android")
	if err != nil || rel.Build != 4 || rel.SHA256 != sha256Hex(apk4) {
		t.Fatalf("build 4 görünmeli: %+v, %v", rel, err)
	}

	// APK yerine farklı içerik kondu (aynı ad): özet tutmaz -> yayın yok.
	writeFileAtomic(t, filepath.Join(dir, "android", "arvend-4.apk"), testAPKBytes(5))
	if _, err := s.Latest("android"); !errors.Is(err, ErrAppReleaseNotFound) {
		t.Fatalf("APK değiştirildikten sonra err = %v, want ErrAppReleaseNotFound", err)
	}
	if _, _, err := s.Open("android"); !errors.Is(err, ErrAppReleaseNotFound) {
		t.Fatalf("APK değiştirildikten sonra Open err = %v, want ErrAppReleaseNotFound", err)
	}
	before := len(logs.warnings())
	for i := 0; i < 5; i++ {
		_, _ = s.Latest("android")
	}
	if after := len(logs.warnings()); after != before {
		t.Fatalf("aynı geçersiz durum tekrar tekrar loglandı: %d -> %d", before, after)
	}
}

// Yalnızca latest.json değişirse (ör. notlar düzeltildi) APK yeniden
// hashlenmez -- ama APK değişirse mutlaka hashlenir.
func TestAppRelease_HashReusedOnlyForSameFile(t *testing.T) {
	dir := t.TempDir()
	publishTestRelease(t, dir, 3, nil)
	s, _ := newTestAppReleaseService(t, dir)
	if _, err := s.Latest("android"); err != nil {
		t.Fatal(err)
	}
	firstSumOf := s.state["android"].apkSumOf

	publishTestRelease(t, dir, 3, func(m map[string]any) { m["notes"] = "düzeltilmiş not" })
	// publishTestRelease APK'yı da yeniden yazar (yeni inode) -- bu yüzden
	// özet yeniden hesaplanmış olmalı.
	rel, err := s.Latest("android")
	if err != nil || rel.Notes != "düzeltilmiş not" {
		t.Fatalf("yeni not görünmeli: %+v, %v", rel, err)
	}
	if sameAppReleaseFile(firstSumOf, s.state["android"].apkSumOf) {
		t.Fatal("APK yeni bir dosya olduğu halde eski özet kullanıldı")
	}

	// Şimdi YALNIZCA latest.json değişsin.
	sumOf := s.state["android"].apkSumOf
	m := map[string]any{
		"build": 3, "version": "1.3.0", "sha256": rel.SHA256, "size": rel.Size,
		"notes": "yalnız JSON değişti", "min_build": 0, "file": "arvend-3.apk",
		"published_at": "2026-09-28T11:00:00Z",
	}
	raw, _ := json.Marshal(m)
	writeFileAtomic(t, filepath.Join(dir, "android", "latest.json"), raw)
	rel, err = s.Latest("android")
	if err != nil || rel.Notes != "yalnız JSON değişti" {
		t.Fatalf("yeni not görünmeli: %+v, %v", rel, err)
	}
	if s.state["android"].apkSumOf != sumOf {
		t.Fatal("APK değişmediği halde yeniden hashlendi")
	}
}
