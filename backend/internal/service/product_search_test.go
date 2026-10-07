package service_test

import (
	"context"
	"fmt"
	"slices"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

// Canlı firmanın kataloğuna benzeyen ürünler: Demir Profil adlarında
// tedarikçi adı GEÇMEZ ("demir" yalnızca tedarikçide), ölçüler "×" ile,
// ondalık virgülle yazılır; Ulaş kategorileri büyük harf ve Türkçe.
type searchSeed struct {
	name, unit, price, category string
	source                      *string
}

var (
	srcDemir = ptrStr(domain.PriceSourceDemirProfil)
	srcUlas  = ptrStr(domain.PriceSourceUlas)
)

func ptrStr(s string) *string { return &s }

var searchCatalog = []searchSeed{
	{"Siyah Kutu Profil 30×90×2 mm", "boy", "640.50", "Siyah Kutu Profil", srcDemir},
	{"Siyah Kutu Profil 40×40×2 mm", "boy", "512.00", "Siyah Kutu Profil", srcDemir},
	{"Siyah Kutu Profil 140×140×4 mm", "boy", "2950.00", "Siyah Kutu Profil", srcDemir},
	{"Siyah Kutu Profil 30×40×1,5 mm", "boy", "355.20", "Siyah Kutu Profil", srcDemir},
	{"Galvaniz Kutu Profil 40×40×1,35 mm", "boy", "498.75", "Galvaniz Kutu Profil", srcDemir},
	{"Paslanmaz Boru Ø38×2 mm", "boy", "1210.00", "Paslanmaz Boru", srcDemir},
	{"Paslanmaz Boru Ø138×3 mm", "boy", "5400.00", "Paslanmaz Boru", srcDemir},
	{"Delikli Sac 1 mm", "adet", "880.00", "Delikli Sac", srcDemir},
	{"Nervürlü İnşaat Demiri Ø12", "ton", "24500.00", "İNŞAAT DEMİRİ", srcUlas},
	{"Sandviç Panel Sac 40 mm", "m2", "690.00", "SANDVİÇ PANEL", srcUlas},
	{"Gazbeton Yapıştırıcısı", "torba", "120.00", "GAZBETON MALZEMELERİ", srcUlas},
	{"Alüminyum Profil Köşebent 40 x 40", "boy", "210.00", "", nil},
	{"İşçilik (montaj)", "saat", "450.00", "", nil},
}

// Başka bir firmanın, aynı adlı ürünleri: hiçbir aramada görünmemeli.
var otherFirmCatalog = []searchSeed{
	{"Siyah Kutu Profil 40×40×2 mm", "boy", "1.00", "Siyah Kutu Profil", srcDemir},
	{"Rakip Firma Kutu Profil 40×40", "boy", "1.00", "Siyah Kutu Profil", srcDemir},
	{"Paslanmaz Boru Ø38×2 mm", "boy", "1.00", "Paslanmaz Boru", srcDemir},
	{"Ulaş Gizli Ürün", "adet", "1.00", "GİZLİ", srcUlas},
}

func seedSearchCatalog(t *testing.T, pool *pgxpool.Pool, orgID string, seeds []searchSeed) {
	t.Helper()
	for _, s := range seeds {
		if _, err := pool.Exec(context.Background(), `
			INSERT INTO products (organization_id, name, normalized_name, unit, unit_price, description, category, source)
			VALUES ($1, $2, $3, $4, $5::numeric, '', $6, $7)`,
			orgID, s.name, domain.NormalizeName(s.name), s.unit, s.price, s.category, s.source); err != nil {
			t.Fatalf("ürün eklenemedi (%s): %v", s.name, err)
		}
	}
}

// TestProductSearch: kelime bazlı katalog araması (domain/product_search.go
// + SearchProducts) -- eşleşme kuralları, sıralama, toplamın
// listeyle tutarlılığı ve firma izolasyonu.
func TestProductSearch(t *testing.T) {
	dbURL := testDBURL(t)
	_ = testSecretBox(t) // diğer DB testleriyle aynı kapı: anahtarsız ortamda atlanır
	ctx := context.Background()
	pool, err := repository.NewPool(ctx, dbURL)
	if err != nil {
		t.Fatalf("veritabanına bağlanılamadı: %v", err)
	}
	t.Cleanup(func() { pool.Close() })
	q := sqlc.New(pool)
	orgSvc := service.NewOrganizationService(q)
	svc := service.NewProductService(q)

	org := mustCreateOrg(t, ctx, orgSvc, pool, "Ürün Arama Test", "urun-arama-test")
	other := mustCreateOrg(t, ctx, orgSvc, pool, "Ürün Arama Rakip", "urun-arama-rakip")
	seedSearchCatalog(t, pool, org.ID, searchCatalog)
	seedSearchCatalog(t, pool, other.ID, otherFirmCatalog)

	search := func(t *testing.T, query string) []string {
		t.Helper()
		res, err := svc.List(ctx, org.ID, query, 1, 200)
		if err != nil {
			t.Fatalf("arama %q: %v", query, err)
		}
		names := make([]string, len(res.Products))
		for i, p := range res.Products {
			if p.OrganizationID != org.ID {
				t.Fatalf("arama %q başka firmanın ürününü döndü: %+v", query, p)
			}
			names[i] = p.Name
		}
		if int(res.Total) != len(names) {
			t.Errorf("arama %q: toplam %d, liste %d -- pencere sayımı ile liste ayrışmış", query, res.Total, len(names))
		}
		return names
	}
	expectSet := func(t *testing.T, query string, want ...string) []string {
		t.Helper()
		got := search(t, query)
		if !slices.Equal(sorted(got), sorted(want)) {
			t.Errorf("arama %q\n  bulunan: %q\n  beklenen: %q", query, got, want)
		}
		return got
	}

	t.Run("demir: tedarikçi adıyla Demir Profil ürünleri, adında demir geçen önce", func(t *testing.T) {
		got := search(t, "demir")
		if len(got) != 9 || got[0] != "Nervürlü İnşaat Demiri Ø12" {
			t.Fatalf("8 Demir Profil ürünü + adında 'demir' geçen Ulaş ürünü (ilk sırada) beklenirdi: %q", got)
		}
		for _, n := range got[1:] {
			if !slices.ContainsFunc(searchCatalog, func(s searchSeed) bool { return s.name == n && s.source == srcDemir }) {
				t.Errorf("Demir Profil dışı ürün: %q", n)
			}
		}
	})

	t.Run("profil: adında geçenler önce, kısa ad önce; tedarikçi eşleşmesi sonra", func(t *testing.T) {
		got := search(t, "profil")
		// Adında "profil" geçen 6 ürün; Demir Profil'in adında profil
		// geçmeyen 3 ürünü (boru, sac) tedarikçi adıyla eşleşir ve sona düşer.
		if len(got) != 9 {
			t.Fatalf("9 ürün beklenirdi: %q", got)
		}
		for i, n := range got {
			hasProfil := strings.Contains(strings.ToLower(n), "profil")
			if (i < 6) != hasProfil {
				t.Errorf("%d. sıradaki %q: ad eşleşmeleri ilk 6 sırada olmalı: %q", i, n, got)
			}
		}
		if got[0] != "Siyah Kutu Profil 30×90×2 mm" && got[0] != "Siyah Kutu Profil 40×40×2 mm" {
			t.Errorf("en kısa ad önce gelmeli: %q", got)
		}
	})

	t.Run("kutu 40: her kelime; 40 kelime başında olanlar 140×140'tan önce", func(t *testing.T) {
		got := expectSet(t, "kutu 40",
			"Siyah Kutu Profil 40×40×2 mm",
			"Siyah Kutu Profil 30×40×1,5 mm",
			"Galvaniz Kutu Profil 40×40×1,35 mm",
			"Siyah Kutu Profil 140×140×4 mm",
		)
		if len(got) == 4 && got[3] != "Siyah Kutu Profil 140×140×4 mm" {
			t.Errorf("140×140 sona düşmeli: %q", got)
		}
	})

	t.Run("40x40: x, X, *, boşluklu yazım ve × aynı", func(t *testing.T) {
		want := []string{
			"Siyah Kutu Profil 40×40×2 mm",
			"Galvaniz Kutu Profil 40×40×1,35 mm",
			"Alüminyum Profil Köşebent 40 x 40",
		}
		for _, query := range []string{"40x40", "40X40", "40*40", "40 x 40", "40×40"} {
			expectSet(t, query, want...)
		}
	})

	t.Run("paslanmaz boru 38: Ø38, Ø138'den önce", func(t *testing.T) {
		got := expectSet(t, "paslanmaz boru 38", "Paslanmaz Boru Ø38×2 mm", "Paslanmaz Boru Ø138×3 mm")
		if len(got) == 2 && got[0] != "Paslanmaz Boru Ø38×2 mm" {
			t.Errorf("Ø38 önce gelmeli: %q", got)
		}
	})

	t.Run("ondalık virgül/nokta aynı", func(t *testing.T) {
		expectSet(t, "1.35", "Galvaniz Kutu Profil 40×40×1,35 mm")
		expectSet(t, "1,35", "Galvaniz Kutu Profil 40×40×1,35 mm")
	})

	t.Run("ulaş/ulas: tedarikçi; kategori Türkçe büyük harfle eşleşir", func(t *testing.T) {
		ulas := []string{"Nervürlü İnşaat Demiri Ø12", "Sandviç Panel Sac 40 mm", "Gazbeton Yapıştırıcısı"}
		expectSet(t, "ulaş", ulas...)
		expectSet(t, "ULAS", ulas...)
		// "malzemeleri" yalnızca kategoride (GAZBETON MALZEMELERİ).
		expectSet(t, "malzemeleri", "Gazbeton Yapıştırıcısı")
		expectSet(t, "sandvic panel", "Sandviç Panel Sac 40 mm")
		// Kelimeler farklı alanlardan gelebilir: "sac" adda, "ulas" tedarikçide.
		expectSet(t, "sac ulas", "Sandviç Panel Sac 40 mm")
	})

	t.Run("eşleşmeyen kelime sonucu boşaltır; joker karakter yok", func(t *testing.T) {
		expectSet(t, "kutu zzz")
		// Eskiden sorgu ILIKE desenine olduğu gibi giriyordu: "s_c" "sac"ı,
		// "k%u" "kutu"yu buluyordu. Artık düz alt dize.
		expectSet(t, "s_c")
		expectSet(t, "k%u")
		// Yalnızca noktalamadan oluşan sorgu filtre değildir (eskiden "%"
		// de her şeyi döndürüyordu).
		if got := search(t, "%"); len(got) != len(searchCatalog) {
			t.Errorf("noktalama sorgusu tüm kataloğu döndürmeli: %q", got)
		}
	})

	t.Run("her ürün kendi adı ve kategorisiyle bulunur (Go ve SQL katlaması aynı)", func(t *testing.T) {
		for _, s := range searchCatalog {
			if got := search(t, s.name); !slices.Contains(got, s.name) {
				t.Errorf("%q kendi adıyla bulunamadı: %q", s.name, got)
			} else if got[0] != s.name {
				t.Errorf("%q kendi adıyla aranınca ilk sırada olmalı: %q", s.name, got)
			}
			if s.category != "" {
				if got := search(t, s.category); !slices.Contains(got, s.name) {
					t.Errorf("%q kategorisiyle (%q) bulunamadı: %q", s.name, s.category, got)
				}
			}
		}
	})

	t.Run("arama yoksa tüm katalog ad sırasıyla; sayfalama tutarlı", func(t *testing.T) {
		all := search(t, "")
		if len(all) != len(searchCatalog) {
			t.Fatalf("tüm katalog (%d) beklenirdi: %d", len(searchCatalog), len(all))
		}
		// Eski sıra (ORDER BY name, id; veritabanı harmanlamasıyla) korunur.
		var byName []string
		rows, err := pool.Query(ctx, `SELECT name FROM products WHERE organization_id = $1 ORDER BY name, id`, org.ID)
		if err != nil {
			t.Fatal(err)
		}
		for rows.Next() {
			var n string
			if err := rows.Scan(&n); err != nil {
				t.Fatal(err)
			}
			byName = append(byName, n)
		}
		rows.Close()
		if !slices.Equal(all, byName) {
			t.Errorf("arama yokken ad sırası korunmalı:\n  %q\n  %q", all, byName)
		}
		var paged []string
		for page := 1; page <= 3; page++ {
			res, err := svc.List(ctx, org.ID, "profil", page, 4)
			if err != nil {
				t.Fatal(err)
			}
			if res.Total != 9 {
				t.Errorf("sayfa %d: toplam 9 olmalı: %d", page, res.Total)
			}
			for _, p := range res.Products {
				paged = append(paged, p.Name)
			}
		}
		if want := search(t, "profil"); !slices.Equal(paged, want) {
			t.Errorf("sayfalar tek listeyle aynı sırada olmalı:\n  %q\n  %q", paged, want)
		}
		// Sonun ötesindeki sayfa: satır yok ama toplam yine doğru.
		res, err := svc.List(ctx, org.ID, "profil", 4, 4)
		if err != nil || len(res.Products) != 0 || res.Total != 9 {
			t.Errorf("sonun ötesindeki sayfa: %d ürün, toplam %d (9 beklenirdi), err=%v", len(res.Products), res.Total, err)
		}
	})

	t.Run("firma izolasyonu: rakip firma kendi kataloğunu görür, bizimkini görmez", func(t *testing.T) {
		for _, query := range []string{"", "rakip", "gizli", "kutu 40"} {
			res, err := svc.List(ctx, other.ID, query, 1, 200)
			if err != nil {
				t.Fatal(err)
			}
			for _, p := range res.Products {
				if p.OrganizationID != other.ID {
					t.Errorf("arama %q başka firmanın ürününü döndü: %+v", query, p)
				}
			}
		}
		expectSet(t, "rakip")
		expectSet(t, "gizli")
	})
}

func sorted(s []string) []string {
	out := slices.Clone(s)
	slices.Sort(out)
	return out
}

// refMatch: eşleşme kuralının Go'daki başvuru uygulaması -- her kelime
// adda, kategoride ya da tedarikçi etiketinde geçmeli. SQL'in (SearchProducts)
// aynı kararı verdiği ölçekte doğrulanır.
func refMatch(terms []string, name, category string, source *string) bool {
	codes, labels := domain.ProductSearchSources()
	src := ""
	if source != nil {
		src = strings.ToLower(*source)
		if i := slices.Index(codes, *source); i >= 0 {
			src = labels[i]
		}
	}
	n, c := domain.ProductSearchFold(name), domain.ProductSearchFold(category)
	for _, t := range terms {
		if !strings.Contains(n, t) && !strings.Contains(c, t) && !strings.Contains(src, t) {
			return false
		}
	}
	return true
}

// TestProductSearchScale: canlı firma ölçeğinde (~4000 ürün: 3400 Demir
// Profil, 600 Ulaş) SQL'in eşleşme kararı Go başvuru uygulamasıyla
// (refMatch) birebir aynı ve toplam/sayfa tutarlı. Süre burada ölçülmez
// (paylaşımlı makinede kırılgan olurdu).
func TestProductSearchScale(t *testing.T) {
	dbURL := testDBURL(t)
	_ = testSecretBox(t)
	ctx := context.Background()
	pool, err := repository.NewPool(ctx, dbURL)
	if err != nil {
		t.Fatalf("veritabanına bağlanılamadı: %v", err)
	}
	t.Cleanup(func() { pool.Close() })
	q := sqlc.New(pool)
	org := mustCreateOrg(t, ctx, service.NewOrganizationService(q), pool, "Ürün Arama Ölçek", "urun-arama-olcek")
	svc := service.NewProductService(q)

	var names, norms, categories, sources []string
	kinds := []string{"Siyah Kutu Profil", "Galvaniz Kutu Profil", "Paslanmaz Boru", "Delikli Sac"}
	for g := 1; g <= 4000; g++ {
		var name, category, source string
		if g <= 3400 {
			category = kinds[g%len(kinds)]
			name = fmt.Sprintf("%s %d×%d×%d,%d mm", category, 10+g%190, 10+g%90, 1+g%4, g%10)
			source = domain.PriceSourceDemirProfil
		} else {
			category = []string{"GAZBETON MALZEMELERİ", "SANDVİÇ PANEL", "İNŞAAT DEMİRİ"}[g%3]
			name = fmt.Sprintf("Ulaş Ürünü %d Çatı Şap", g)
			source = domain.PriceSourceUlas
		}
		names = append(names, name)
		norms = append(norms, domain.NormalizeName(name))
		categories = append(categories, category)
		sources = append(sources, source)
	}
	if _, err := pool.Exec(ctx, `
		INSERT INTO products (organization_id, name, normalized_name, unit, unit_price, description, category, source)
		SELECT $1, u.n, u.nn, 'boy', 100, '', u.c, u.s
		FROM unnest($2::text[], $3::text[], $4::text[], $5::text[]) AS u(n, nn, c, s)`,
		org.ID, names, norms, categories, sources); err != nil {
		t.Fatal(err)
	}

	for _, query := range []string{
		"demir", "ulaş", "profil", "kutu 40", "40x40", "kutu 40 x 40", "paslanmaz boru 38", "1,5", "sap cati",
		"galvaniz 1.5", "demiri", "malzemeleri", "omega", "zzz", "",
	} {
		terms := domain.ProductSearchTerms(query)
		var want int64
		for i := range names {
			if refMatch(terms, names[i], categories[i], &sources[i]) {
				want++
			}
		}
		res, err := svc.List(ctx, org.ID, query, 1, 20)
		if err != nil {
			t.Fatal(err)
		}
		if res.Total != want || len(res.Products) != min(20, int(want)) {
			t.Errorf("arama %q: toplam %d (Go başvurusu %d), sayfa %d", query, res.Total, want, len(res.Products))
		}
		for _, p := range res.Products {
			src := p.Source
			if !refMatch(terms, p.Name, p.Category, &src) {
				t.Errorf("arama %q: eşleşmemesi gereken ürün döndü: %q", query, p.Name)
			}
		}
	}
}
