// migrate-byz-proje, BYZ'deki teklif MASRAFLARINI ve İŞ PLANINI, ARVEND'de o
// tekliften dönüştürülmüş PROJEYE aktarır.
//
// Neden projeye: BYZ'de proje kavramı yoktu; kabul edilen bir işin gerçek
// harcamaları (malzeme, yemek, personel) ve ekibi teklifin içine yazılıyordu
// (offers.masraflar, offers.plan). ARVEND'de bunların karşılığı zaten var ve
// projededir: proje masrafları, proje ekibi, başlangıç tarihi. Yeni bir modül
// gerekmez (2026-10-04 kararı).
//
// Projeyi bu araç OLUŞTURMAZ: "Projeye Dönüştür" proje numarası, boş taslak
// bütçe ve iki taraflı olay kaydı üretiyor (ProjectService.CreateFromOffer) --
// taklit etmek yerine kullanıcı ARVEND'de dönüştürür, araç projeyi
// source_offer_id üzerinden bulur. Proje yoksa durur ve söyler.
//
// Yazma ARVEND'in KENDİ servisleriyle yapılır (ProjectService.CreateExpense /
// AssignMember) -- web'den girilmiş bir masraftan farkı olmasın: aynı
// doğrulama, aynı proje olay kaydı. Bu servisler kendi transaction'larını
// açtığı için DENEME modu burada "yaz ve geri al" değil, PLAN modudur: her
// şeyi çözümler (proje, kategori, tarih, personel) ve gösterir, hiçbir şey
// yazmaz. Tekrar çalıştırma güvenlidir: masraflar idempotency_key
// ("byz:<teklif>:masraf:<sıra>") ile, ekip UNIQUE(proje, personel) ile korunur.
//
// Aktarılmayanlar: plan.expenses ({name, amount} -- "TAHA 222", "TAHA 5",
// "0") deneme verisi; arşiv dosyasında zaten duruyor.
//
// Kullanım:
//
//	SOURCE_MONGO_URI=... SOURCE_MONGO_DB=... DB_URL=... TARGET_ORG_SLUG=arvend-yapi1 \
//	  [APPLY=1] go run ./cmd/migrate-byz-proje
package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"os"
	"regexp"
	"sort"
	"strings"
	"time"
	_ "time/tzdata"

	"go.mongodb.org/mongo-driver/v2/bson"
	"go.mongodb.org/mongo-driver/v2/mongo"
	"go.mongodb.org/mongo-driver/v2/mongo/options"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

var revSuffix = regexp.MustCompile(`-R(\d+)$`)

type byzMasraf struct {
	Kalem   string     `bson:"kalem"`
	Tutar   float64    `bson:"tutar"`
	Tarih   string     `bson:"tarih"`
	Not     string     `bson:"not"`
	Sira    float64    `bson:"sira"`
	Eklenme *time.Time `bson:"eklenme"`
}

type byzPlan struct {
	StartDate   string   `bson:"start_date"`
	EndDate     string   `bson:"end_date"`
	EmployeeIDs []string `bson:"employee_ids"`
}

type byzOffer struct {
	OfferNo   string      `bson:"offer_no"`
	Status    string      `bson:"status"`
	IsPassive *bool       `bson:"is_passive"`
	Masraflar []byzMasraf `bson:"masraflar"`
	Plan      *byzPlan    `bson:"plan"`
}

type byzEmployee struct {
	ID       bson.ObjectID `bson:"_id"`
	FullName string        `bson:"full_name"`
}

// Kategori: kalem + not metnindeki anahtar kelimelerden (Türkçe katlanmış,
// küçük harf). İlk eşleşen kazanır; hiçbiri yoksa "other". Gerçek 15 satırın
// hepsi deneme çıktısında kategoriyle birlikte gösterilir.
var categoryRules = []struct {
	category string
	words    []string
}{
	{"food", []string{"yemek", "kahvalti", "ogle"}},
	{"personnel", []string{"personel", "isci", "usta", "yevmiye", "maas"}},
	{"transport", []string{"nakliye", "yakit", "benzin", "mazot", "akaryakit", "ulasim", "kargo"}},
	{"accommodation", []string{"konaklama", "otel", "pansiyon"}},
	{"equipment", []string{"ekipman", "kiralama", "makine", "alet"}},
	{"material", []string{"malzeme", "profil", "demir", "cimento", "boya", "kablo", "boru"}},
}

func categorize(kalem, not string) string {
	text := domain.NormalizeName(kalem + " " + not)
	for _, r := range categoryRules {
		for _, w := range r.words {
			if strings.Contains(text, w) {
				return r.category
			}
		}
	}
	return "other"
}

func main() {
	ctx := context.Background()
	sourceURI, sourceDB := os.Getenv("SOURCE_MONGO_URI"), os.Getenv("SOURCE_MONGO_DB")
	pgURL, orgSlug := os.Getenv("DB_URL"), os.Getenv("TARGET_ORG_SLUG")
	apply := os.Getenv("APPLY") == "1"
	if sourceURI == "" || sourceDB == "" || pgURL == "" || orgSlug == "" {
		log.Fatal("SOURCE_MONGO_URI, SOURCE_MONGO_DB, DB_URL ve TARGET_ORG_SLUG gerekli")
	}
	ist, err := time.LoadLocation("Europe/Istanbul")
	if err != nil {
		log.Fatalf("Europe/Istanbul yüklenemedi: %v", err)
	}
	if apply {
		fmt.Println(">>> GERÇEK AKTARIM (APPLY=1): ARVEND servisleriyle yazılacak.")
	} else {
		fmt.Println(">>> PLAN: her şey çözümlenip gösterilecek, HİÇBİR ŞEY yazılmayacak.")
	}

	mc, err := mongo.Connect(options.Client().ApplyURI(sourceURI))
	if err != nil {
		log.Fatalf("MongoDB'ye bağlanılamadı: %v", err)
	}
	defer mc.Disconnect(ctx)
	src := mc.Database(sourceDB)

	var offers []byzOffer
	cur, err := src.Collection("offers").Find(ctx, bson.M{"$or": bson.A{
		bson.M{"masraflar.0": bson.M{"$exists": true}},
		bson.M{"plan.start_date": bson.M{"$nin": bson.A{nil, ""}}},
		bson.M{"plan.employee_ids.0": bson.M{"$exists": true}},
	}})
	if err != nil || cur.All(ctx, &offers) != nil {
		log.Fatalf("offers okunamadı: %v", err)
	}
	var employees []byzEmployee
	cur, err = src.Collection("employees").Find(ctx, bson.M{})
	if err != nil || cur.All(ctx, &employees) != nil {
		log.Fatalf("employees okunamadı: %v", err)
	}
	empName := map[string]string{}
	for _, e := range employees {
		empName[e.ID.Hex()] = e.FullName
	}

	pool, err := repository.NewPool(ctx, pgURL)
	if err != nil {
		log.Fatalf("PostgreSQL'e bağlanılamadı: %v", err)
	}
	defer pool.Close()
	q := sqlc.New(pool)
	// CreateExpense/AssignMember dosya deposu ya da e-posta ayarı KULLANMIYOR
	// (2026-10-04'te kontrol edildi) -- nil verilebilir.
	svc := service.NewProjectService(pool, q, nil, nil, "")

	var orgID, orgName string
	if err := pool.QueryRow(ctx, `SELECT id, name FROM organizations WHERE slug = $1 AND deleted_at IS NULL`, orgSlug).
		Scan(&orgID, &orgName); err != nil {
		log.Fatalf("organizasyon bulunamadı (slug %q): %v", orgSlug, err)
	}
	fmt.Printf("Hedef: %s (%s)\n", orgName, orgSlug)

	arvEmp := map[string]string{} // nameKey -> ARVEND employee id
	rows, err := pool.Query(ctx, `SELECT id, full_name FROM employees WHERE organization_id = $1`, orgID)
	if err != nil {
		log.Fatalf("personel okunamadı: %v", err)
	}
	for rows.Next() {
		var id, n string
		_ = rows.Scan(&id, &n)
		arvEmp[nameKey(n)] = id
	}
	rows.Close()

	sort.Slice(offers, func(i, j int) bool { return offers[i].OfferNo < offers[j].OfferNo })
	var missingProjects []string
	var nExp, nExpDone, nMem, nMemDone, nStart int
	var totalAmount float64

	for _, o := range offers {
		base := revSuffix.ReplaceAllString(strings.TrimSpace(o.OfferNo), "")
		hasWork := len(o.Masraflar) > 0 || (o.Plan != nil && (o.Plan.StartDate != "" || len(o.Plan.EmployeeIDs) > 0))
		if !hasWork {
			continue
		}
		// Kabul edilmemiş tekliflerin "planı" iş değil, taslak/deneme: projeye
		// dönüştürülemezler de (CreateFromOffer kabul ister).
		if o.Status != "kabul edildi" {
			fmt.Printf("\n%s (%s): kabul edilmemiş teklif -- projeye ait veri değil, atlandı\n", o.OfferNo, o.Status)
			continue
		}

		var projectID, projectNo, projectName, currency string
		var startDate *time.Time
		err := pool.QueryRow(ctx, `
			SELECT p.id, p.project_no, p.name, p.currency, p.start_date
			FROM projects p JOIN offers ofr ON ofr.id = p.source_offer_id
			WHERE p.organization_id = $1 AND ofr.offer_no = $2`, orgID, base,
		).Scan(&projectID, &projectNo, &projectName, &currency, &startDate)
		if err != nil {
			missingProjects = append(missingProjects, base)
			continue
		}
		fmt.Printf("\n%s -> proje %s \"%s\"\n", base, projectNo, projectName)

		// --- Masraflar ---
		ms := append([]byzMasraf(nil), o.Masraflar...)
		sort.SliceStable(ms, func(i, j int) bool { return ms[i].Sira < ms[j].Sira })
		for _, m := range ms {
			kalem := strings.TrimSpace(m.Kalem)
			date, dateNote := parseDay(m.Tarih, ist)
			if date.IsZero() && m.Eklenme != nil {
				date, dateNote = m.Eklenme.In(ist), " (tarih boştu, eklendiği gün)"
			}
			if date.IsZero() {
				log.Fatalf("%s sıra %v: masrafın tarihi de eklenme anı da yok -- hiçbir şey yazılmadı", base, m.Sira)
			}
			cat := categorize(kalem, m.Not)
			key := fmt.Sprintf("byz:%s:masraf:%d", base, int(m.Sira))
			var exists bool
			_ = pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM project_expenses WHERE project_id = $1 AND idempotency_key = $2)`,
				projectID, key).Scan(&exists)
			mark := "+"
			if exists {
				mark, nExpDone = "=", nExpDone+1
			}
			fmt.Printf("  %s masraf %-26s %-13s %10.2f  %s%s\n", mark, quoteTR(kalem), cat, m.Tutar, date.Format("2006-01-02"), dateNote)
			totalAmount += m.Tutar
			if exists || !apply {
				if !exists {
					nExp++
				}
				continue
			}
			if _, err := svc.CreateExpense(ctx, projectID, orgID, service.ExpenseInput{
				Category: cat, Description: kalem, Amount: m.Tutar, Currency: currency,
				ExpenseDate: date, Notes: strings.TrimSpace(m.Not), IdempotencyKey: key,
			}); err != nil {
				log.Fatalf("%s masraf %q eklenemedi: %v (önceki satırlar yazıldı; tekrar çalıştırmak güvenli)", base, kalem, err)
			}
			nExp++
		}

		// --- Ekip + başlangıç tarihi ---
		if o.Plan != nil {
			planStart, _ := parseDay(o.Plan.StartDate, ist)
			for _, raw := range o.Plan.EmployeeIDs {
				name, ok := empName[strings.TrimSpace(raw)]
				if !ok {
					fmt.Printf("  ! ekip: BYZ personeli %s bulunamadı (silinmiş) -- atlandı\n", raw)
					continue
				}
				eid, ok := arvEmp[nameKey(name)]
				if !ok {
					fmt.Printf("  ! ekip: %s ARVEND'de yok -- atlandı\n", name)
					continue
				}
				var exists bool
				_ = pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM project_members WHERE project_id = $1 AND employee_id = $2)`,
					projectID, eid).Scan(&exists)
				mark := "+"
				if exists {
					mark, nMemDone = "=", nMemDone+1
				}
				fmt.Printf("  %s ekip   %s\n", mark, name)
				if exists || !apply {
					if !exists {
						nMem++
					}
					continue
				}
				var sd *time.Time
				if !planStart.IsZero() {
					sd = &planStart
				}
				if _, err := svc.AssignMember(ctx, projectID, orgID, service.ProjectMemberInput{
					EmployeeID: eid, StartDate: sd, Notes: "BYZ iş planından aktarıldı",
				}); err != nil && !errors.Is(err, service.ErrDuplicateMember) {
					log.Fatalf("%s ekip %s eklenemedi: %v", base, name, err)
				}
				nMem++
			}
			if !planStart.IsZero() {
				if startDate != nil {
					fmt.Printf("  = başlangıç tarihi zaten %s -- dokunulmadı\n", startDate.Format("2006-01-02"))
				} else {
					fmt.Printf("  + başlangıç tarihi %s\n", planStart.Format("2006-01-02"))
					nStart++
					if apply {
						if _, err := pool.Exec(ctx, `UPDATE projects SET start_date = $3::date, updated_at = now()
							WHERE id = $1 AND organization_id = $2 AND start_date IS NULL`,
							projectID, orgID, planStart.Format("2006-01-02")); err != nil {
							log.Fatalf("%s başlangıç tarihi yazılamadı: %v", base, err)
						}
					}
				}
			}
		}
	}

	if len(missingProjects) > 0 {
		fmt.Println("\nPROJE YOK -- önce ARVEND'de bu teklifleri \"Projeye Dönüştür\"ün (hiçbir şey yazılmadı):")
		for _, b := range missingProjects {
			fmt.Println("  - " + b)
		}
		os.Exit(1)
	}

	verb := "eklenecek"
	if apply {
		verb = "eklendi"
	}
	fmt.Println("\nÖZET")
	fmt.Printf("  Masraf : %d %s, %d zaten vardı (toplam %.2f TL)\n", nExp, verb, nExpDone, totalAmount)
	fmt.Printf("  Ekip   : %d %s, %d zaten vardı\n", nMem, verb, nMemDone)
	fmt.Printf("  Başlangıç tarihi: %d proje\n", nStart)
	if !apply {
		fmt.Println("\nPLAN BİTTİ -- hiçbir şey yazılmadı. Uygulamak için APPLY=1.")
		return
	}
	fmt.Println("\nAKTARIM TAMAM.")
}

// parseDay, "YYYY-MM-DD" -> İstanbul gününün başı; boş/geçersizse sıfır.
func parseDay(s string, ist *time.Location) (time.Time, string) {
	t, err := time.ParseInLocation("2006-01-02", strings.TrimSpace(s), ist)
	if err != nil {
		return time.Time{}, ""
	}
	return t, ""
}

func nameKey(s string) string { return domain.NormalizeName(strings.Join(strings.Fields(s), " ")) }

func quoteTR(s string) string {
	if r := []rune(s); len(r) > 24 {
		return string(r[:23]) + "…"
	}
	return s
}
