// Package storage, yüklenen dosyaların saklanmasını soyutlar. Bugün
// yalnızca yerel disk uygulaması var; ileride S3 uyumlu bir depolamaya
// geçmek için Store arayüzünün ikinci bir uygulamasını yazmak yeterli --
// servis/handler katmanı değişmez.
package storage

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

var ErrNotFound = errors.New("dosya bulunamadı")

// Object, depolanan bir nesnenin doğrulanmış üst verisidir.
type Object struct {
	Key      string
	Size     int64
	SHA256   string
	MIMEType string
}

type Store interface {
	// Put, veriyi key altında saklar ve gerçekte yazılan boyut/özet
	// bilgisini döner.
	Put(ctx context.Context, key string, r io.Reader) (Object, error)
	Open(ctx context.Context, key string) (io.ReadCloser, error)
	Delete(ctx context.Context, key string) error
}

// keyPattern, kabul edilen nesne anahtarlarını sınırlar: yalnızca
// harf/rakam/tire/alt tire/nokta ve "/" ayracı. Anahtarlar zaten sunucu
// tarafında UUID'lerden üretilir (kullanıcı girdisi anahtar haline
// GELMEZ); bu kontrol, bir kod değişikliğinin yanlışlıkla dışarıdan gelen
// bir değeri anahtar olarak kullanmasına karşı ikinci savunma hattıdır.
var keyPattern = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9._\-/]*$`)

// ValidateKey, anahtarın güvenli olduğunu doğrular. ".." veya mutlak yol
// içeren, boş segmentli ya da desene uymayan hiçbir anahtar kabul edilmez.
func ValidateKey(key string) error {
	if key == "" || len(key) > 500 {
		return errors.New("geçersiz nesne anahtarı")
	}
	if !keyPattern.MatchString(key) {
		return errors.New("geçersiz nesne anahtarı")
	}
	if strings.HasPrefix(key, "/") || filepath.IsAbs(key) {
		return errors.New("geçersiz nesne anahtarı")
	}
	for _, seg := range strings.Split(key, "/") {
		if seg == "" || seg == "." || seg == ".." {
			return errors.New("geçersiz nesne anahtarı")
		}
	}
	return nil
}

// LocalStore, nesneleri kök dizin altında saklar.
type LocalStore struct {
	root string
}

func NewLocalStore(root string) (*LocalStore, error) {
	abs, err := filepath.Abs(root)
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(abs, 0o755); err != nil {
		return nil, err
	}
	return &LocalStore{root: abs}, nil
}

// resolve, anahtarı kök dizin altındaki mutlak yola çevirir ve sonucun
// GERÇEKTEN kökün altında kaldığını doğrular -- ValidateKey'e ek olarak,
// sembolik bağ/normalizasyon sürprizlerine karşı son kontrol.
func (s *LocalStore) resolve(key string) (string, error) {
	if err := ValidateKey(key); err != nil {
		return "", err
	}
	full := filepath.Join(s.root, filepath.FromSlash(key))
	clean := filepath.Clean(full)
	if clean != s.root && !strings.HasPrefix(clean, s.root+string(os.PathSeparator)) {
		return "", errors.New("geçersiz nesne anahtarı")
	}
	return clean, nil
}

func (s *LocalStore) Put(ctx context.Context, key string, r io.Reader) (Object, error) {
	path, err := s.resolve(key)
	if err != nil {
		return Object{}, err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return Object{}, err
	}

	// Önce geçici dosyaya yaz, sonra yerine taşı: yarım kalmış bir yükleme
	// asla geçerli bir nesne gibi görünmez.
	tmp, err := os.CreateTemp(filepath.Dir(path), ".upload-*")
	if err != nil {
		return Object{}, err
	}
	tmpName := tmp.Name()
	defer func() {
		tmp.Close()
		os.Remove(tmpName) // başarıyla taşındıysa zaten yok
	}()

	hasher := sha256.New()
	size, err := io.Copy(io.MultiWriter(tmp, hasher), r)
	if err != nil {
		return Object{}, err
	}
	if err := tmp.Close(); err != nil {
		return Object{}, err
	}
	if err := os.Rename(tmpName, path); err != nil {
		return Object{}, err
	}
	return Object{Key: key, Size: size, SHA256: hex.EncodeToString(hasher.Sum(nil))}, nil
}

func (s *LocalStore) Open(ctx context.Context, key string) (io.ReadCloser, error) {
	path, err := s.resolve(key)
	if err != nil {
		return nil, err
	}
	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	return f, nil
}

func (s *LocalStore) Delete(ctx context.Context, key string) error {
	path, err := s.resolve(key)
	if err != nil {
		return err
	}
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}

// BuildKey, bir nesne anahtarını YALNIZCA sunucu tarafındaki kimliklerden
// üretir. Kullanıcının gönderdiği dosya adı buraya hiç girmez; yalnızca
// uzantı, katı bir doğrulamadan geçirilerek kullanılır.
func BuildKey(kind, organizationID, projectID, objectID, ext string) string {
	return fmt.Sprintf("%s/%s/%s/%s%s", kind, organizationID, projectID, objectID, SafeExt(ext))
}

var extPattern = regexp.MustCompile(`^\.[a-zA-Z0-9]{1,10}$`)

// SafeExt, dosya adından gelen uzantıyı güvenli hale getirir: noktadan
// sonrası yalnızca harf/rakam olabilir, aksi halde uzantı tamamen düşer.
// Böylece "rapor.pdf.exe" ya da "../../etc/passwd" gibi adlar anahtarı
// etkileyemez.
func SafeExt(name string) string {
	ext := strings.ToLower(filepath.Ext(name))
	if !extPattern.MatchString(ext) {
		return ""
	}
	return ext
}
