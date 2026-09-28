package service

// Uzaktan güncelleme (Store öncesi) -- uygulama mağazalara çıkana kadar
// Android uygulaması kendini bizim sunucumuzdan günceller (eski BYZ
// uygulamasının app_version/app_download deseni).
//
// Kaynak: APP_RELEASES_DIR/<platform>/latest.json ve aynı dizindeki
// arvend-<build>.apk. İkisini de mobile/scripts/yayinla.sh yazar: önce APK,
// sonra latest.json; ikisi de geçici adla yüklenip rename edilir, yani
// istemci hiçbir zaman olmayan bir APK'yı gösteren JSON görmez. API bu
// dizini YALNIZCA OKUR (üretimde ProtectSystem=strict, dizin salt-okunur).
//
// Güvenlik modeli üç katmanlıdır (BYZ ile aynı):
//  1. APK'nın kendisi yalnızca oturum açmış bir firma kullanıcısına iner
//     (router: requireAuth + requireTenant).
//  2. İstemci inen dosyanın SHA-256'sını /app-version'daki özetle
//     karşılaştırır; tutmazsa kurulum ekranını hiç açmaz.
//  3. Android güncellemeyi yalnızca kurulu uygulamayla AYNI anahtarla
//     imzalanmışsa kurar.
//
// Bu yüzden burada latest.json'daki her alan doğrulanır: dosya adı sabit bir
// desene uyar (yol geçişi yok), sembolik bağ kabul edilmez, boyut VE SHA-256
// diskteki gerçek dosyayla birebir tutar. Herhangi bir eksik/tutarsızlık
// "yayın yok" sayılır (uyarı loglanır) -- istemciye asla 500 dönmez, yarım
// ya da bozuk bir yayın hiçbir cihaza önerilmez.

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"regexp"
	"sync"
	"time"
)

// AppPlatformAndroid: şimdilik tek platform. iOS'ta mağaza dışı kurulum
// yok; ileride eklenecek bir platform appReleasePlatforms'a yazılmadıkça
// hiçbir dizine bakılmaz.
const AppPlatformAndroid = "android"

var appReleasePlatforms = map[string]bool{AppPlatformAndroid: true}

var (
	ErrUnknownAppPlatform = errors.New("bilinmeyen platform")
	ErrAppReleaseNotFound = errors.New("yayınlanmış bir uygulama sürümü yok")
)

const (
	appReleaseManifestName = "latest.json"
	// latest.json birkaç yüz bayttır; sınır bozuk/dev bir dosyanın belleğe
	// okunmasını engeller.
	maxAppReleaseManifestBytes = 64 << 10
	// yayinla.sh notları 1000 karakterle sınırlar; bu, sunucu tarafındaki
	// ikinci savunma hattı.
	maxAppReleaseNotesBytes = 4000
	// Android versionCode üst sınırı.
	maxAppReleaseBuild = 2100000000
	// Makul bir APK üst sınırı -- her değişiklikte dosyanın tamamı hashlenir.
	maxAppReleaseBytes = 1 << 30
)

var (
	appReleaseFilePattern    = regexp.MustCompile(`^arvend-[0-9]+\.apk$`)
	appReleaseSHA256Pattern  = regexp.MustCompile(`^[0-9a-f]{64}$`)
	appReleaseVersionPattern = regexp.MustCompile(`^[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}$`)
)

// AppRelease, doğrulanmış bir yayın. Version desene uyduğu için
// Content-Disposition gibi başlıklarda güvenle kullanılabilir.
type AppRelease struct {
	Platform    string
	Build       int
	Version     string
	SHA256      string
	Size        int64
	Notes       string
	MinBuild    int
	File        string
	PublishedAt time.Time
	// ModTime, APK dosyasının değişme zamanı (Last-Modified).
	ModTime time.Time

	path string
	info os.FileInfo
}

// appReleaseManifest, latest.json'ın disk biçimi. Zorunlu alanlar pointer:
// eksik alan ile sıfır değer ayırt edilir. Bilinmeyen alanlar yok sayılır
// ve istemciye hiçbir koşulda taşınmaz (yanıtı handler kendi alanlarıyla
// kurar).
type appReleaseManifest struct {
	Build       *int    `json:"build"`
	Version     *string `json:"version"`
	SHA256      *string `json:"sha256"`
	Size        *int64  `json:"size"`
	Notes       string  `json:"notes"`
	MinBuild    int     `json:"min_build"`
	File        *string `json:"file"`
	PublishedAt *string `json:"published_at"`
}

// AppReleaseService, latest.json'ı istek başına yeniden değerlendirir ama
// dosyalar değişmedikçe (inode + boyut + mtime) önbellekten döner: SHA-256
// yalnızca yeni bir APK göründüğünde bir kez hesaplanır, geçersiz bir
// yayının uyarısı da değişiklik başına bir kez loglanır.
type AppReleaseService struct {
	dir  string
	logf func(format string, args ...any)

	mu    sync.Mutex
	state map[string]*appReleaseState
}

type appReleaseState struct {
	manifest os.FileInfo // nil: yok/okunamadı
	apkName  string      // "": latest.json dosya adına kadar doğrulanamadı
	apk      os.FileInfo // nil: yok/okunamadı
	apkSum   string      // hashlenen dosyanın GERÇEK özeti (hesaplandıysa)
	apkSumOf os.FileInfo // apkSum'ın ait olduğu dosya (açılan tanıtıcının Stat'ı)
	release  *AppRelease // nil: geçerli yayın yok
}

func NewAppReleaseService(dir string) *AppReleaseService {
	return &AppReleaseService{dir: dir, logf: log.Printf, state: map[string]*appReleaseState{}}
}

// Latest, platformun geçerli yayınını döner. Geçerli yayın yoksa
// ErrAppReleaseNotFound, desteklenmeyen platformda ErrUnknownAppPlatform.
func (s *AppReleaseService) Latest(platform string) (AppRelease, error) {
	if !appReleasePlatforms[platform] {
		return AppRelease{}, ErrUnknownAppPlatform
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	rel := s.currentLocked(platform)
	if rel == nil {
		return AppRelease{}, ErrAppReleaseNotFound
	}
	return *rel, nil
}

// Open, geçerli yayının APK'sını okumak üzere açar; kapatmak çağıranın
// işidir. Açılan dosya, doğrulanan dosyanın AYNISI olmak zorundadır (aynı
// inode, boyut, mtime): doğrulama ile açma arasında yeni bir sürüm
// yayınlandıysa bir kez daha denenir. Böylece yanıttaki sürüm/ETag (özet)
// her zaman akıtılan baytlarla tutarlıdır.
func (s *AppReleaseService) Open(platform string) (AppRelease, *os.File, error) {
	for attempt := 0; attempt < 2; attempt++ {
		rel, err := s.Latest(platform)
		if err != nil {
			return AppRelease{}, nil, err
		}
		f, err := os.Open(rel.path)
		if err != nil {
			continue
		}
		info, err := f.Stat()
		if err == nil && sameAppReleaseFile(rel.info, info) {
			return rel, f, nil
		}
		f.Close()
	}
	return AppRelease{}, nil, ErrAppReleaseNotFound
}

func (s *AppReleaseService) currentLocked(platform string) *AppRelease {
	pdir := filepath.Join(s.dir, platform)
	prev := s.state[platform]
	if prev != nil && sameAppReleaseFile(prev.manifest, lstatOrNil(filepath.Join(pdir, appReleaseManifestName))) {
		if prev.apkName == "" || sameAppReleaseFile(prev.apk, lstatOrNil(filepath.Join(pdir, prev.apkName))) {
			return prev.release
		}
	}
	next := s.load(platform, pdir, prev)
	s.state[platform] = next
	return next.release
}

// load, latest.json'ı ve APK'yı baştan doğrular. Yalnızca dosyalardan biri
// değiştiğinde çağrılır; uyarılar bu yüzden değişiklik başına bir kez düşer.
func (s *AppReleaseService) load(platform, pdir string, prev *appReleaseState) *appReleaseState {
	manifestPath := filepath.Join(pdir, appReleaseManifestName)
	// Önbellek anahtarı, doğrulama başarısız olsa bile kaydedilir: aynı
	// bozuk dosya her istekte yeniden okunup yeniden loglanmaz.
	st := &appReleaseState{manifest: lstatOrNil(manifestPath)}

	f, _, err := openRegularFile(manifestPath)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			s.logf("UYARI: uygulama sürümü (%s): %s yok -- güncelleme önerilmeyecek", platform, manifestPath)
		} else {
			s.logf("UYARI: uygulama sürümü (%s): %s okunamadı: %v -- yayın yok sayıldı", platform, manifestPath, err)
		}
		return st
	}
	raw, err := io.ReadAll(io.LimitReader(f, maxAppReleaseManifestBytes+1))
	f.Close()
	if err != nil {
		s.logf("UYARI: uygulama sürümü (%s): %s okunamadı: %v", platform, manifestPath, err)
		return st
	}
	if len(raw) > maxAppReleaseManifestBytes {
		s.logf("UYARI: uygulama sürümü (%s): %s çok büyük -- yayın yok sayıldı", platform, manifestPath)
		return st
	}

	var m appReleaseManifest
	if err := json.Unmarshal(raw, &m); err != nil {
		s.logf("UYARI: uygulama sürümü (%s): %s bozuk JSON: %v -- yayın yok sayıldı", platform, manifestPath, err)
		return st
	}
	rel, err := validateAppReleaseManifest(platform, m)
	if err != nil {
		s.logf("UYARI: uygulama sürümü (%s): %s geçersiz: %v -- yayın yok sayıldı", platform, manifestPath, err)
		return st
	}

	// Buradan sonra dosya adı desene uyuyor (ayraç/".." içeremez), yani
	// yol platform dizininin içinde kalır.
	st.apkName = rel.File
	rel.path = filepath.Join(pdir, rel.File)
	st.apk = lstatOrNil(rel.path)
	apk, apkInfo, err := openRegularFile(rel.path)
	if err != nil {
		s.logf("UYARI: uygulama sürümü (%s): %s açılamadı: %v -- yayın yok sayıldı", platform, rel.path, err)
		return st
	}
	defer apk.Close()

	if apkInfo.Size() != rel.Size {
		s.logf("UYARI: uygulama sürümü (%s): %s boyutu %d, latest.json %d diyor -- yayın yok sayıldı",
			platform, rel.File, apkInfo.Size(), rel.Size)
		return st
	}

	// Yalnızca latest.json değiştiyse (ör. notlar düzeltildi) ve APK aynı
	// dosyaysa özet yeniden hesaplanmaz.
	if prev != nil && prev.apkSum != "" && sameAppReleaseFile(prev.apkSumOf, apkInfo) {
		st.apkSum, st.apkSumOf = prev.apkSum, prev.apkSumOf
	} else {
		h := sha256.New()
		if _, err := io.Copy(h, apk); err != nil {
			s.logf("UYARI: uygulama sürümü (%s): %s okunamadı: %v -- yayın yok sayıldı", platform, rel.path, err)
			return st
		}
		st.apkSum, st.apkSumOf = hex.EncodeToString(h.Sum(nil)), apkInfo
	}
	if st.apkSum != rel.SHA256 {
		s.logf("UYARI: uygulama sürümü (%s): %s SHA-256 özeti latest.json ile tutmuyor -- yayın yok sayıldı",
			platform, rel.File)
		return st
	}

	rel.ModTime = apkInfo.ModTime()
	rel.info = apkInfo
	st.release = &rel
	if prev == nil || prev.release == nil || prev.release.Build != rel.Build || prev.release.SHA256 != rel.SHA256 {
		s.logf("uygulama sürümü (%s): v%s (build %d) yayında", platform, rel.Version, rel.Build)
	}
	return st
}

func validateAppReleaseManifest(platform string, m appReleaseManifest) (AppRelease, error) {
	switch {
	case m.Build == nil, m.Version == nil, m.SHA256 == nil, m.Size == nil, m.File == nil, m.PublishedAt == nil:
		return AppRelease{}, errors.New("zorunlu alan eksik (build, version, sha256, size, file, published_at)")
	case *m.Build < 1 || *m.Build > maxAppReleaseBuild:
		return AppRelease{}, fmt.Errorf("build geçersiz: %d", *m.Build)
	case !appReleaseVersionPattern.MatchString(*m.Version):
		return AppRelease{}, errors.New("version x.y.z biçiminde değil")
	case !appReleaseSHA256Pattern.MatchString(*m.SHA256):
		return AppRelease{}, errors.New("sha256 64 küçük harf onaltılık karakter değil")
	case *m.Size < 1 || *m.Size > maxAppReleaseBytes:
		return AppRelease{}, fmt.Errorf("size geçersiz: %d", *m.Size)
	case !appReleaseFilePattern.MatchString(*m.File):
		return AppRelease{}, errors.New("file arvend-<build>.apk desenine uymuyor")
	case *m.File != fmt.Sprintf("arvend-%d.apk", *m.Build):
		return AppRelease{}, errors.New("file, build numarasıyla tutmuyor")
	case m.MinBuild < 0 || m.MinBuild > *m.Build:
		return AppRelease{}, fmt.Errorf("min_build geçersiz: %d", m.MinBuild)
	case len(m.Notes) > maxAppReleaseNotesBytes:
		return AppRelease{}, errors.New("notes çok uzun")
	}
	publishedAt, err := time.Parse(time.RFC3339, *m.PublishedAt)
	if err != nil {
		return AppRelease{}, errors.New("published_at RFC3339 değil")
	}
	return AppRelease{
		Platform: platform, Build: *m.Build, Version: *m.Version, SHA256: *m.SHA256,
		Size: *m.Size, Notes: m.Notes, MinBuild: m.MinBuild, File: *m.File, PublishedAt: publishedAt,
	}, nil
}

// openRegularFile, yalnızca düz bir dosyayı açar: sembolik bağ, dizin ya da
// aygıt reddedilir. Lstat ile açılan tanıtıcının aynı dosya olması şartı,
// kontrol ile açma arasında yerine bağ konmasını da yakalar.
func openRegularFile(path string) (*os.File, os.FileInfo, error) {
	linfo, err := os.Lstat(path)
	if err != nil {
		return nil, nil, err
	}
	if !linfo.Mode().IsRegular() {
		return nil, nil, errors.New("düz bir dosya değil")
	}
	f, err := os.Open(path)
	if err != nil {
		return nil, nil, err
	}
	info, err := f.Stat()
	if err != nil {
		f.Close()
		return nil, nil, err
	}
	if !os.SameFile(linfo, info) {
		f.Close()
		return nil, nil, errors.New("dosya kontrol sırasında değişti")
	}
	return f, info, nil
}

func lstatOrNil(path string) os.FileInfo {
	info, err := os.Lstat(path)
	if err != nil {
		return nil
	}
	return info
}

// sameAppReleaseFile: iki durum aynı dosyayı mı gösteriyor? Yayınlama
// rename ile yapıldığı için yeni sürüm yeni inode demektir; yerinde
// düzenleme de boyut/mtime değişikliğiyle yakalanır. İkisi de nil (dosya
// yok) ise "aynı" sayılır.
func sameAppReleaseFile(a, b os.FileInfo) bool {
	if a == nil || b == nil {
		return a == nil && b == nil
	}
	return os.SameFile(a, b) && a.Size() == b.Size() && a.ModTime().Equal(b.ModTime()) && a.Mode() == b.Mode()
}
