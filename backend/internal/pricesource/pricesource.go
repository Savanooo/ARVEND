// Package pricesource, tedarikçi fiyat listelerini indirip ayrıştırır:
//
//   - Ulaş (https://ulas.com.tr/flist.asp, HTML tablo) -- BYZ'deki
//     services/ulas_scraper.py'nin Go karşılığı (ulas.go);
//   - Demir Profil / Omega Çelik (https://www.demirprofil.com.tr/llms-full.txt,
//     düz metin) -- demirprofil.go.
//
// Bu paket veritabanına DOKUNMAZ: yalnızca List ([]Item + liste dönemi +
// uyarılar) üretir; ürün kataloğuna uygulama (kâr oranı, eşleştirme, fiyat
// geçmişi) service.PriceSourceService'in işidir.
package pricesource

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"slices"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/shopspring/decimal"
)

const (
	// Tarayıcı benzeri User-Agent: siteler botlara farklı sayfa döndürmesin
	// diye (BYZ'de de aynıydı). İki kaynağın robots.txt'i de indirilen
	// adrese izin veriyor.
	userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"

	fetchTimeout = 30 * time.Second
	// Bugün Ulaş ~200 KB, Demir Profil ~176 KB; 5 MiB üstü bozuk/beklenmedik
	// bir yanıttır.
	maxBodyBytes = 5 << 20
	// Yönlendirme yalnızca kaynağın kendi https adresleri arasında izlenir.
	maxRedirects = 5

	// products tablosunun kolon sınırları (varchar karakter sayısı).
	MaxNameLen     = 200
	MaxUnitLen     = 30
	MaxCategoryLen = 100
	// description text'tir; yine de tek bir satır listeyi şişirmesin.
	maxDescriptionLen = 500

	defaultUnit = "adet"
)

// maxPrice, numeric(18,2) kolonunda %1000 kâr oranıyla bile taşmayacak
// üst sınır -- bunun üstü bir ayrıştırma hatasıdır, satır atlanır.
var maxPrice = decimal.New(1, 12)

// Item, fiyat listesindeki tek bir ürün satırıdır. Price, tedarikçinin
// (kâr oranı UYGULANMAMIŞ) fiyatıdır ve 2 ondalığa yuvarlanmıştır --
// products.source_price ile birebir aynı değer, böylece senkron ile kâr
// oranı yeniden hesaplaması aynı tabandan çalışır. Description yalnızca
// YENİ oluşturulan ürüne yazılır (mevcut ürünün açıklaması kullanıcıya
// aittir, senkron değiştirmez); bu yüzden içine fiyat YAZILMAZ -- zamanla
// eskir ve products.read sahibine tedarikçi maliyetini gösterirdi.
type Item struct {
	Name        string
	Unit        string
	Category    string
	Description string
	Price       decimal.Decimal
}

// List, bir kaynağın tek indirmesinin sonucudur.
type List struct {
	Items []Item
	// Label, listenin dönemi ("Eylül 2026"); kaynak vermiyorsa "".
	Label string
	// Warnings: ayrıştırıcının atladığı bölümler/satırlar (tanınmayan
	// başlık, hücre sayısı tutmayan satır...). Senkronu DURDURMAZ, servis
	// loglar -- sessizce kaybolan bir bölüm fark edilsin diye.
	Warnings []string

	// Origin: listenin nereden geldiği -- OriginLive (tedarikçinin sitesi,
	// varsayılan ""), OriginArchive (Wayback Machine kopyası) ya da
	// OriginSnapshot (sunucuda saklı son başarılı liste). Bkz.
	// service.priceFallbackFetcher.
	Origin string
	// AsOf: listenin VERİ tarihi. Canlı listede indirme anı, arşivde
	// kopyanın alındığı an. Sıfırsa "şimdi" sayılır.
	AsOf time.Time
	// LiveErr: yedek bir liste döndüyse canlı sitenin neden alınamadığı
	// (kullanıcıya PublicErrorMessage ile gösterilir).
	LiveErr error
}

const (
	OriginLive     = ""
	OriginArchive  = "archive"
	OriginSnapshot = "snapshot"
)

// IsFallback: liste canlı siteden değil yedekten (arşiv/saklı kopya) geldi.
func (l List) IsFallback() bool { return l.Origin != OriginLive }

// Clone, listenin (dilimler dahil) bağımsız bir kopyasını döner --
// paylaşımlı önbellekten dönen liste çağıranlar arasında paylaşılmasın.
func (l List) Clone() List {
	return List{
		Items: slices.Clone(l.Items), Label: l.Label, Warnings: slices.Clone(l.Warnings),
		Origin: l.Origin, AsOf: l.AsOf, LiveErr: l.LiveErr,
	}
}

// publicError: metni kaynak adıyla tamamlanan, kullanıcıya gösterilebilir
// sabit bir hata. Error() log içindir; organization_price_sources.last_error'a
// PublicErrorMessage(kaynakAdı, err) ile gelen metin yazılır.
type publicError struct{ format string }

func (e *publicError) Error() string                    { return fmt.Sprintf(e.format, "tedarikçi") }
func (e *publicError) publicMessage(name string) string { return fmt.Sprintf(e.format, name) }

var (
	// ErrNoItems: sayfa indi ama tek bir ürün bile çıkmadı. Boş/bozuk bir
	// sayfa ASLA "tüm ürünler listeden düştü" diye yorumlanmamalı.
	ErrNoItems error = &publicError{"%s fiyat listesinde ürün bulunamadı (sayfa yapısı değişmiş olabilir)"}
	// ErrNoTable: sayfada hiç <table> yok (Ulaş).
	ErrNoTable error = &publicError{"%s fiyat listesinde tablo bulunamadı (sayfa yapısı değişmiş olabilir)"}
	// ErrTooFewItems: liste ayrıştırıldı ama beklenenden çok az ürün çıktı
	// (Demir Profil: < 100) -- yarım/bozuk bir dosya.
	ErrTooFewItems error = &publicError{"%s fiyat listesinde beklenenden az ürün var (dosya yapısı değişmiş olabilir)"}
	// ErrUnexpectedRedirect: kaynak kendi https adresleri dışına (başka bir
	// sunucuya, http'ye, iç ağ adresine) yönlendirdi -- izlenmez.
	ErrUnexpectedRedirect error = &publicError{"%s beklenmeyen bir adrese yönlendirdi"}
	ErrTooLarge           error = &publicError{fmt.Sprintf("%%s fiyat listesi beklenenden büyük (> %d MiB)", maxBodyBytes>>20)}
	ErrCharset            error = &publicError{"%s fiyat listesinin karakter kodlaması çözülemedi"}
)

// HTTPStatusError: tedarikçi 2xx dışı bir yanıt döndü. Source yalnızca log
// metni içindir (kullanıcıya giden metin PublicErrorMessage'ın adını kullanır).
type HTTPStatusError struct {
	Source     string
	StatusCode int
}

func (e *HTTPStatusError) Error() string {
	name := e.Source
	if name == "" {
		name = "tedarikçi"
	}
	return fmt.Sprintf("%s sunucusu HTTP %d döndü", name, e.StatusCode)
}

// PublicErrorMessage, bir indirme/ayrıştırma hatasını SABİT, kısa bir
// Türkçe metne çevirir (name: kaynağın kısa adı, ör. "Ulaş"). Bu metin
// organization_price_sources.last_error'a yazılır ve products.read sahibi
// herkes okur -- ham Go hatası (çözümleyici/proxy adresi, yönlendirme
// hedefi...) ASLA oraya gitmez; o yalnızca sunucu loguna yazılır.
func PublicErrorMessage(name string, err error) string {
	if err == nil {
		return ""
	}
	var statusErr *HTTPStatusError
	if errors.As(err, &statusErr) {
		return fmt.Sprintf("%s sunucusu HTTP %d döndü", name, statusErr.StatusCode)
	}
	var pubErr *publicError
	if errors.As(err, &pubErr) {
		return pubErr.publicMessage(name)
	}
	// *url.Error da net.Error'dır: client.Do'dan gelen her ağ hatası buraya düşer.
	var netErr net.Error
	isNetErr := errors.As(err, &netErr)
	switch {
	case errors.Is(err, context.DeadlineExceeded), isNetErr && netErr.Timeout():
		return name + " sunucusu zamanında yanıt vermedi (zaman aşımı)"
	case isNetErr, errors.Is(err, io.ErrUnexpectedEOF):
		return name + " sunucusuna bağlanılamadı"
	}
	return name + " fiyat listesi alınamadı"
}

// fetchSpec, sabit bir kaynak adresinin indirme kurallarıdır.
type fetchSpec struct {
	name   string   // log metinleri için kısa ad ("Ulaş")
	url    string   // sabit adres -- kullanıcıdan/istekten gelen URL ASLA indirilmez
	accept string   // Accept başlığı
	hosts  []string // yönlendirmede izin verilen hostlar (yalnızca https, varsayılan port)
	// timeout: 0 ise fetchTimeout. Arşiv (web.archive.org) yavaş olabilir.
	timeout time.Duration
}

// fetchBody, spec.url'i indirir: tarayıcı benzeri UA, 30 sn sınırı, 5 MiB
// gövde sınırı, 2xx dışı yanıt hatadır. client nil ise varsayılan bir
// istemci kullanılır; verilen istemcinin CheckRedirect'i (sığ kopyada)
// spec.hosts politikasıyla değiştirilir -- çağıranın istemcisi değişmez.
func fetchBody(ctx context.Context, client *http.Client, spec fetchSpec) (body []byte, contentType string, err error) {
	body, header, err := fetchBodyWithHeader(ctx, client, spec)
	return body, header.Get("Content-Type"), err
}

// fetchBodyWithHeader, fetchBody'nin yanıt başlıklarını da döneni (arşiv
// kopyasının tarihi Memento-Datetime başlığındadır).
func fetchBodyWithHeader(ctx context.Context, client *http.Client, spec fetchSpec) (body []byte, header http.Header, err error) {
	c := http.Client{Timeout: fetchTimeout}
	if client != nil {
		c = *client // sığ kopya: çağıranın istemcisi değişmesin
	}
	c.CheckRedirect = redirectPolicy(spec.hosts)
	timeout := fetchTimeout
	if spec.timeout > 0 {
		timeout = spec.timeout
		if c.Timeout != 0 && c.Timeout < timeout {
			c.Timeout = timeout
		}
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, spec.url, nil)
	if err != nil {
		return nil, nil, err
	}
	req.Header.Set("User-Agent", userAgent)
	req.Header.Set("Accept", spec.accept)
	req.Header.Set("Accept-Language", "tr-TR,tr;q=0.9")

	resp, err := c.Do(req)
	if err != nil {
		return nil, nil, fmt.Errorf("%s fiyat listesi indirilemedi: %w", spec.name, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		return nil, nil, &HTTPStatusError{Source: spec.name, StatusCode: resp.StatusCode}
	}

	body, err = io.ReadAll(io.LimitReader(resp.Body, maxBodyBytes+1))
	if err != nil {
		return nil, nil, fmt.Errorf("%s fiyat listesi okunamadı: %w", spec.name, err)
	}
	if len(body) > maxBodyBytes {
		return nil, nil, fmt.Errorf("%s: %w", spec.name, ErrTooLarge)
	}
	return body, resp.Header, nil
}

// redirectPolicy: URL sabit olsa da yönlendirme hedefi üçüncü tarafın
// elindedir. Kaynağın sitesi/DNS'i ele geçirilirse sunucumuz iç ağa
// (127.0.0.1, 169.254.169.254, LAN) yönlendirilmesin diye yalnızca https +
// izinli hostlar (varsayılan port) izlenir.
func redirectPolicy(hosts []string) func(*http.Request, []*http.Request) error {
	return func(req *http.Request, via []*http.Request) error {
		if len(via) >= maxRedirects || !allowedURL(req.URL, hosts) {
			return ErrUnexpectedRedirect
		}
		return nil
	}
}

func allowedURL(u *url.URL, hosts []string) bool {
	if u == nil || u.Scheme != "https" || (u.Port() != "" && u.Port() != "443") {
		return false
	}
	return slices.Contains(hosts, strings.ToLower(u.Hostname()))
}

// Normalize, ürün kataloğuna yazılmadan önce her kaynağın çıktısına
// uygulanan ORTAK temizliktir (ayrıştırıcılar da bunu kullanır; servis,
// sahte/başka bir fetcher'dan gelen listeyi de buradan geçirir):
//
//   - ad/birim/kategori/açıklama: boşluklar tek boşluğa iner, kırpılır ve
//     kolon sınırlarına (200/30/100/500 karakter) rune-güvenli kısaltılır;
//   - birim boşsa "adet"; ad boşsa satır atlanır;
//   - fiyat 2 ondalığa yarım yukarı yuvarlanır, sıfır/negatif/aşırı büyükse atlanır;
//   - (ad, birim, kategori) tekrarlarında İLK satır kazanır.
//
// Kategori anahtarın parçasıdır: Ulaş aynı ad+birimi birden çok kategoride
// listeler -- çoğu aynı ürünün iki kategoride görünmesidir (ör. "Sandviç
// Panel Sac" ÇATI MALZEMELERİ ve SANDVİÇ PANEL'de), ama bazıları FARKLI
// ürünlerdir ("Gazbeton Yapıştırıcısı" torba: FİXA 130 TL, GAZBETON
// MALZEMELERİ 120 TL). (ad, birim) ile tekilleştirmek ikincisinin fiyatını
// birincininkiyle ezer, kategori oranını da hiç uygulatmazdı.
func Normalize(items []Item) []Item {
	out := make([]Item, 0, len(items))
	seen := make(map[[3]string]bool, len(items))
	for _, it := range items {
		name := truncateRunes(CollapseSpaces(it.Name), MaxNameLen)
		unit := truncateRunes(CollapseSpaces(it.Unit), MaxUnitLen)
		if unit == "" {
			unit = defaultUnit
		}
		category := truncateRunes(CollapseSpaces(it.Category), MaxCategoryLen)
		price := it.Price.Round(2)
		key := [3]string{name, unit, category}
		if name == "" || !price.IsPositive() || price.GreaterThan(maxPrice) || seen[key] {
			continue
		}
		seen[key] = true
		out = append(out, Item{
			Name: name, Unit: unit, Category: category,
			Description: truncateRunes(CollapseSpaces(it.Description), maxDescriptionLen),
			Price:       price,
		})
	}
	return out
}

// CollapseSpaces, her türlü boşluk dizisini (NBSP, satır sonu dahil) tek
// boşluğa indirir ve kırpar. Senkron eşleştirmesi mevcut satırların ad/
// birimini de bununla karşılaştırır (BYZ çift boşlukları korurdu).
func CollapseSpaces(s string) string {
	return strings.Join(strings.Fields(s), " ")
}

// turkishThousands: "1.200", "1.200,50", "12.345.678" -- nokta binlik
// ayırıcı, virgül ondalık (BYZ _parse_price ile aynı desen).
var (
	turkishThousands = regexp.MustCompile(`^\d{1,3}(\.\d{3})+(,\d+)?$`)
	plainNumber      = regexp.MustCompile(`^\d+(\.\d+)?$`)
)

// ParsePrice, "500 TL", "1.200 TL", "1.200,50 TL", "12,5TL" gibi metinleri
// 2 ondalığa yuvarlanmış (yarım yukarı) pozitif bir tutara çevirir.
// Geçersiz, sıfır veya negatif -> ok=false.
func ParsePrice(s string) (decimal.Decimal, bool) {
	s = strings.ReplaceAll(s, "TL", "")
	s = strings.ReplaceAll(s, " ", "")
	s = strings.TrimSpace(s)
	if turkishThousands.MatchString(s) {
		s = strings.ReplaceAll(s, ".", "")
	}
	s = strings.ReplaceAll(s, ",", ".")
	// BYZ float() kullanıyordu; burada yalnızca düz ondalık sayı kabul
	// edilir ("1e5", "inf", "-3" gibi girdiler reddedilir).
	if !plainNumber.MatchString(s) {
		return decimal.Decimal{}, false
	}
	d, err := decimal.NewFromString(s)
	if err != nil {
		return decimal.Decimal{}, false
	}
	d = d.Round(2)
	if !d.IsPositive() || d.GreaterThan(maxPrice) {
		return decimal.Decimal{}, false
	}
	return d, true
}

// truncateRunes, s'yi en fazla max karaktere (rune) kısaltır -- UTF-8
// dizisini ortadan bölmez.
func truncateRunes(s string, max int) string {
	if utf8.RuneCountInString(s) <= max {
		return s
	}
	return strings.TrimSpace(string([]rune(s)[:max]))
}
