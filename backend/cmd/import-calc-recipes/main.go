// import-calc-recipes, BYZ'den çıkarılan Metraj Hesaplama fixture'ını
// (scripts/extract_byz_calc_recipes.py çıktısı, bkz.
// db/fixtures/byz_calc_recipes.json) BİR ARVEND ORGANİZASYONUNA aktarır.
//
// TEK SEFERLİK bir araçtır -- kalıcı uygulama kodu DEĞİLDİR. Sunucu
// açılışında OTOMATİK ÇALIŞMAZ (BYZ'nin her boot'ta seed_calculation_data()
// çalıştırıp kullanıcı düzenlemelerini ezmesi -- rapor §11.1 -- BİLİNÇLİ
// OLARAK taşınmadı). Aynı zamanda "controlled provisioning" aracıdır:
// yeni bir organizasyon için varsayılan Metraj Hesaplama kataloğu
// isteniyorsa bu araç o organizasyonun id'siyle yeniden çalıştırılır.
//
// Asıl mantık service.ProvisionCalcCatalog'a taşındı (PlatformService, yeni
// bir organizasyon oluştururken AYNI fonksiyonu embed edilmiş varsayılan
// fixture'la çağırıyor) -- bu araç artık ince bir CLI sarmalayıcı: fixture'ı
// diskten okur (embed edilmiş kopyanın aksine, operatör özel bir dosya
// verebilsin diye) ve sonucu konsola özetler.
//
// İDEMPOTENT-GÜVENLİ: (organization_id, slug) zaten varsa grup/kategori
// ATLANIR (üzerine YAZILMAZ) -- admin'in sonradan yaptığı düzenlemeler
// hiçbir zaman sessizce ezilmez. Reçete kalemleri (category_id,
// material_name, unit) üçlüsüyle aynı şekilde atlanır.
//
// Kullanım:
//
//	DB_URL="postgres://.../arvend_dev" go run ./cmd/import-calc-recipes \
//	  --fixture db/fixtures/byz_calc_recipes.json \
//	  --org 00000000-0000-0000-0000-000000000001 \
//	  [--link-products]
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"

	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

func main() {
	fixturePath := flag.String("fixture", "db/fixtures/byz_calc_recipes.json", "Fixture JSON yolu")
	orgID := flag.String("org", "", "Hedef organizasyon id'si (zorunlu)")
	linkProducts := flag.Bool("link-products", false, "Reçete kalemlerini (ad+birim eşleşmesiyle) ürünlere bağla; yoksa yeni ürün oluştur")
	flag.Parse()

	if *orgID == "" {
		fmt.Fprintln(os.Stderr, "kullanım: import-calc-recipes --fixture <yol> --org <organization_id> [--link-products]")
		os.Exit(1)
	}

	raw, err := os.ReadFile(*fixturePath)
	if err != nil {
		log.Fatalf("fixture okunamadı: %v", err)
	}

	dbURL := os.Getenv("DB_URL")
	if dbURL == "" {
		log.Fatal("DB_URL ortam değişkeni gerekli")
	}
	ctx := context.Background()
	pool, err := repository.NewPool(ctx, dbURL)
	if err != nil {
		log.Fatalf("veritabanına bağlanılamadı: %v", err)
	}
	defer pool.Close()

	q := sqlc.New(pool)
	calcSvc := service.NewCalcService(q)
	productSvc := service.NewProductService(q)

	orgUUID, err := repository.StringToUUID(*orgID)
	if err != nil {
		log.Fatalf("geçersiz --org: %v", err)
	}
	if _, err := q.GetOrganizationByID(ctx, orgUUID); err != nil {
		log.Fatalf("organizasyon bulunamadı (%s): %v", *orgID, err)
	}

	res, err := service.ProvisionCalcCatalog(ctx, calcSvc, productSvc, q, *orgID, *linkProducts, raw)
	if err != nil {
		log.Fatalf("içe aktarma başarısız: %v", err)
	}

	fmt.Printf("Gruplar: %d oluşturuldu, %d zaten vardı (atlandı)\n", res.GroupsCreated, res.GroupsSkipped)
	fmt.Printf("Kategoriler: %d oluşturuldu, %d zaten vardı (atlandı), %d yetim (tanınmayan grup)\n",
		res.CategoriesCreated, res.CategoriesSkipped, res.CategoriesOrphan)
	fmt.Printf("Reçete kalemleri: %d oluşturuldu, %d zaten vardı (atlandı), %d yetim (tanınmayan kategori), %d başarısız\n",
		res.ItemsCreated, res.ItemsSkipped, res.ItemsOrphan, res.ItemsFailed)
	if *linkProducts {
		fmt.Println("Ürün eşleştirme etkindi (--link-products).")
	} else {
		fmt.Println("Ürün bağlama atlandı (--link-products verilmedi) -- tüm kalemler product_id=NULL ile eklendi.")
	}
	fmt.Println("Not: veri kalitesi raporundaki (docs/byz-metraj-import-veri-kalitesi-raporu.md) hiçbir sorun burada otomatik düzeltilmedi.")
}
