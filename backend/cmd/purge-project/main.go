// purge-project: İPTAL edilmiş bir projeyi bütün kayıtlarıyla (masraf,
// tahsilat, ödeme, fatura, satın alma, taşeron, rapor, görev, dosya...)
// kalıcı siler. Uygulamadaki "Projeyi sil" para hareketi olan projeyi
// silmez; bu araç yanlış ya da deneme için açılmış projeler içindir.
//
// Kullanım (sunucuda, backend ortamıyla):
//
//	purge-project -no TKF-2026-0031 -no TKF-2026-0003          # deneme: yalnızca sayar
//	purge-project -no TKF-2026-0031 -no TKF-2026-0003 -apply   # siler
//
// -no proje numarası, kaynak teklif numarası ya da tam proje adı. Birden çok firmada
// eşleşirse -org <firma kısa adı> ister. Durumu "iptal" olmayan projeye
// dokunmaz. -apply verilmeden hiçbir şey silinmez.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"os"
	"strings"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/platform/storage"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

type multiFlag []string

func (m *multiFlag) String() string     { return strings.Join(*m, ",") }
func (m *multiFlag) Set(v string) error { *m = append(*m, strings.TrimSpace(v)); return nil }

func main() {
	var ids multiFlag
	flag.Var(&ids, "no", "proje numarası, teklif numarası ya da tam proje adı (birden çok verilebilir)")
	org := flag.String("org", "", "firma kısa adı (aynı numara birden çok firmada varsa)")
	apply := flag.Bool("apply", false, "gerçekten sil (verilmezse yalnızca sayar)")
	flag.Parse()
	if len(ids) == 0 {
		fmt.Fprintln(os.Stderr, "kullanım: purge-project -no <proje/teklif no> [-no ...] [-org <firma>] [-apply]")
		os.Exit(2)
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

	// Önce hepsi bulunur ve denetlenir; biri bile sorunluysa hiçbiri silinmez.
	var targets []service.ProjectPurgeTarget
	for _, id := range ids {
		found, err := service.FindProjectsForPurge(ctx, pool, id, *org)
		if err != nil {
			log.Fatalf("%s aranamadı: %v", id, err)
		}
		switch {
		case len(found) == 0:
			log.Fatalf("%s ile eşleşen proje yok", id)
		case len(found) > 1:
			fmt.Printf("%s birden çok projeyle eşleşti, -org ile firmayı seçin:\n", id)
			for _, t := range found {
				fmt.Printf("  - %s (%s) · %s · %s\n", t.OrganizationName, t.OrganizationSlug, t.ProjectNo, t.Name)
			}
			os.Exit(1)
		}
		t := found[0]
		if t.Status != domain.ProjectStatusCancelled {
			log.Fatalf("%s (%s) iptal edilmemiş (durum: %s); önce uygulamada iptal edin", t.ProjectNo, t.Name, t.Status)
		}
		targets = append(targets, t)
	}

	for _, t := range targets {
		fmt.Printf("\n=== %s · %s · %s (teklif %s, açılış %s)\n", t.OrganizationName, t.ProjectNo, t.Name,
			t.OfferNo, t.CreatedAt.Format("02.01.2006"))
		counts, err := service.CountProjectPurge(ctx, pool, t.ID)
		if err != nil {
			log.Fatalf("sayılamadı: %v", err)
		}
		if len(counts) == 0 {
			fmt.Println("  bağlı kayıt yok")
		}
		for _, c := range counts {
			fmt.Printf("  %-36s %d\n", c.Table, c.Rows)
		}
	}
	if !*apply {
		fmt.Println("\nDENEME: hiçbir şey silinmedi. Silmek için aynı komutu -apply ile çalıştırın.")
		return
	}

	root := os.Getenv("STORAGE_ROOT")
	if root == "" {
		root = "./var/uploads"
	}
	store, err := storage.NewLocalStore(root)
	if err != nil {
		log.Fatalf("dosya deposu açılamadı: %v", err)
	}
	for _, t := range targets {
		keys, err := service.PurgeCancelledProject(ctx, pool, t.ID)
		if err != nil {
			if errors.Is(err, domain.ErrNotFound) {
				log.Fatalf("%s bulunamadı (başka biri silmiş olabilir)", t.ProjectNo)
			}
			log.Fatalf("%s silinemedi (hiçbir kaydı değişmedi): %v", t.ProjectNo, err)
		}
		removed := 0
		for _, k := range keys {
			if err := store.Delete(ctx, k); err == nil {
				removed++
			}
		}
		fmt.Printf("SİLİNDİ: %s · %s (%d dosya)\n", t.ProjectNo, t.Name, removed)
	}
}
