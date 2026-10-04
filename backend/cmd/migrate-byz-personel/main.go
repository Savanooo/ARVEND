// migrate-byz-personel, eski BYZ (Flask + MongoDB) sistemindeki personel
// ("employees"), mesai ("attendance_logs") ve maaş ödemesi ("salary_payments")
// kayıtlarını ARVEND'de TEK bir organizasyona aktarır.
//
// TEK SEFERLİK bir araçtır -- kalıcı uygulama kodu değildir. Kaynağa (Mongo)
// yalnızca OKUMA yapar. Hedefte migration 0048 (salary_payments) uygulanmış
// olmalıdır.
//
// Güvenlik (migrate-products'tan farklı olarak):
//   - Varsayılan DENEME modudur. Her şey tek bir transaction içinde gerçekten
//     yazılır -- yani ARVEND'in bütün kısıtları ve tetikleyicileri gerçek
//     veriyle sınanır -- sonra ROLLBACK edilir. Yalnızca APPLY=1 verilirse
//     COMMIT edilir.
//   - Tek transaction: herhangi bir hata = hiçbir şey yazılmaz. migrate-products
//     hatalı kaydı atlayıp devam ediyordu; yarım kalmış bir aktarım, hiç
//     yapılmamış olandan daha zor temizlenir.
//   - Tekrar çalıştırılabilir:
//     personel  -> organizasyonda aynı adla zaten varsa (domain.NormalizeName +
//     iç boşluklar tekleştirilerek) YENİDEN EKLENMEZ, mevcut kayıt
//     kullanılır;
//     mesai     -> (personel, gün) zaten varsa atlanır (ON CONFLICT DO NOTHING),
//     mevcut kaydın üzerine YAZILMAZ;
//     maaş      -> doğal bir anahtarı yok (aynı ay birden çok ödeme olabilir).
//     (personel, ay, tutar, ödeme günü, açıklama) grubunda BYZ'de
//     n, ARVEND'de m kayıt varsa yalnızca n-m kadar yazılır.
//
// ARVEND'e sığmayan kayıtlar atlanır ve SKIPPED_OUT dosyasına JSON olarak
// yazılır; hiçbir şey sessizce kaybolmaz:
//   - personeli BYZ'den silinmiş mesai/maaş kayıtları (ARVEND'de her ikisi de
//     bir personele bağlı olmak zorunda),
//   - BYZ'nin kendi içindeki aynı personel+gün mesai çiftleri (ARVEND'de
//     UNIQUE; en son girilen tutulur),
//   - ARVEND'in kurallarına uymayan maaş kayıtları (geçersiz ay, tutar <= 0,
//     "ödenmedi" işaretli -- ARVEND'de ödenmemiş ödeme kavramı yok).
//
// Tarihler (2026-10-04'te BYZ verisi üzerinde doğrulandı):
//   - mesai tarihleri UTC gece yarısında saklanan TAKVİM GÜNLERİDİR (438/438
//     kayıt 00:00:00Z) -> UTC günü alınır.
//   - created_at / paid_date ise GERÇEK UTC anlardır (56/56 kayıtta ObjectId
//     zamanıyla birebir aynı). Gece 23:31Z'de girilen bir ödeme İstanbul'da
//     ERTESİ GÜNDÜR -> ödeme günü Europe/Istanbul'a göre alınır.
//
// Kullanım:
//
//	SOURCE_MONGO_URI="mongodb://..." SOURCE_MONGO_DB="erp_teklif_sistemi" \
//	  DB_URL="postgres://..." TARGET_ORG_SLUG="arvend-yapi" \
//	  [APPLY=1] [SKIPPED_OUT=atlananlar.json] \
//	  go run ./cmd/migrate-byz-personel
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"math"
	"os"
	"sort"
	"strings"
	"time"
	_ "time/tzdata" // Europe/Istanbul sunucunun zoneinfo'suna bağlı kalmasın

	"github.com/jackc/pgx/v5"
	"go.mongodb.org/mongo-driver/v2/bson"
	"go.mongodb.org/mongo-driver/v2/mongo"
	"go.mongodb.org/mongo-driver/v2/mongo/options"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
)

// attendance_logs_status_check ile birebir aynı küme.
var allowedStatuses = map[string]bool{"geldi": true, "yarım gün": true, "gelmedi": true, "izinli": true}

type byzEmployee struct {
	ID          bson.ObjectID `bson:"_id"`
	FullName    string        `bson:"full_name"`
	Phone       string        `bson:"phone"`
	Position    string        `bson:"position"`
	Salary      float64       `bson:"salary"`
	DailyWage   float64       `bson:"daily_wage"`
	StartDate   *time.Time    `bson:"start_date"`
	IsActive    bool          `bson:"is_active"`
	Description string        `bson:"description"`
	CreatedAt   time.Time     `bson:"created_at"`
}

type byzAttendance struct {
	ID         bson.ObjectID `bson:"_id"`
	EmployeeID bson.ObjectID `bson:"employee_id"`
	Date       time.Time     `bson:"date"`
	CheckIn    string        `bson:"check_in"`
	CheckOut   string        `bson:"check_out"`
	WorkHours  float64       `bson:"work_hours"`
	Status     string        `bson:"status"`
	Note       string        `bson:"note"`
	CreatedAt  time.Time     `bson:"created_at"`
}

type byzSalary struct {
	ID          bson.ObjectID `bson:"_id"`
	EmployeeID  bson.ObjectID `bson:"employee_id"`
	Month       string        `bson:"month"`
	Amount      float64       `bson:"amount"`
	IsPaid      bool          `bson:"is_paid"`
	PaidDate    *time.Time    `bson:"paid_date"`
	Description string        `bson:"description"`
	CreatedAt   time.Time     `bson:"created_at"`
}

type skippedRow struct {
	Reason string `json:"reason"`
	Record any    `json:"record"`
}

func main() {
	ctx := context.Background()

	sourceURI := os.Getenv("SOURCE_MONGO_URI")
	sourceDB := os.Getenv("SOURCE_MONGO_DB")
	pgURL := os.Getenv("DB_URL")
	orgSlug := os.Getenv("TARGET_ORG_SLUG")
	apply := os.Getenv("APPLY") == "1"
	skippedOut := os.Getenv("SKIPPED_OUT")
	if skippedOut == "" {
		skippedOut = "byz-personel-atlananlar.json"
	}
	if sourceURI == "" || sourceDB == "" || pgURL == "" || orgSlug == "" {
		log.Fatal("SOURCE_MONGO_URI, SOURCE_MONGO_DB, DB_URL ve TARGET_ORG_SLUG gerekli")
	}
	istanbul, err := time.LoadLocation("Europe/Istanbul")
	if err != nil {
		log.Fatalf("Europe/Istanbul yüklenemedi: %v", err)
	}

	if apply {
		fmt.Println(">>> GERÇEK AKTARIM (APPLY=1): sonunda COMMIT edilecek.")
	} else {
		fmt.Println(">>> DENEME: her şey yazılıp kısıtlarla sınanacak, sonunda GERİ ALINACAK (hiçbir şey kaydedilmez).")
	}

	// --- Kaynak: BYZ (yalnızca okuma) ---------------------------------------
	mc, err := mongo.Connect(options.Client().ApplyURI(sourceURI))
	if err != nil {
		log.Fatalf("MongoDB'ye bağlanılamadı: %v", err)
	}
	defer mc.Disconnect(ctx)
	if err := mc.Ping(ctx, nil); err != nil {
		log.Fatalf("MongoDB ping başarısız: %v", err)
	}
	src := mc.Database(sourceDB)

	var employees []byzEmployee
	if err := readAll(ctx, src.Collection("employees"), &employees); err != nil {
		log.Fatalf("employees okunamadı: %v", err)
	}
	var logs []byzAttendance
	if err := readAll(ctx, src.Collection("attendance_logs"), &logs); err != nil {
		log.Fatalf("attendance_logs okunamadı: %v", err)
	}
	var salaries []byzSalary
	if err := readAll(ctx, src.Collection("salary_payments"), &salaries); err != nil {
		log.Fatalf("salary_payments okunamadı: %v", err)
	}
	sort.Slice(employees, func(i, j int) bool { return employees[i].CreatedAt.Before(employees[j].CreatedAt) })
	sort.Slice(salaries, func(i, j int) bool { return salaries[i].CreatedAt.Before(salaries[j].CreatedAt) })
	fmt.Printf("BYZ: %d personel, %d mesai, %d maaş ödemesi okundu.\n", len(employees), len(logs), len(salaries))

	// BYZ'nin kendi içinde aynı adlı iki personel varsa hangisinin kaydı
	// kime ait belirsizleşir -- tahmin etmek yerine dur.
	seen := map[string]string{}
	for _, e := range employees {
		k := nameKey(e.FullName)
		if k == "" {
			log.Fatalf("BYZ'de adı boş bir personel var (_id %s) -- önce BYZ'de düzeltin", e.ID.Hex())
		}
		if prev, ok := seen[k]; ok {
			log.Fatalf("BYZ'de aynı adlı iki personel var (%s, %s) -- hangisi hangisi belirsiz, durdum", prev, e.ID.Hex())
		}
		seen[k] = e.ID.Hex()
	}

	// --- Hedef: ARVEND ---------------------------------------------------------
	pool, err := repository.NewPool(ctx, pgURL)
	if err != nil {
		log.Fatalf("PostgreSQL'e bağlanılamadı: %v", err)
	}
	defer pool.Close()

	tx, err := pool.Begin(ctx)
	if err != nil {
		log.Fatalf("transaction açılamadı: %v", err)
	}
	// COMMIT edilmediyse her çıkış yolunda geri alınır.
	defer tx.Rollback(ctx) //nolint:errcheck

	var hasSalaryTable bool
	if err := tx.QueryRow(ctx, `SELECT to_regclass('salary_payments') IS NOT NULL`).Scan(&hasSalaryTable); err != nil || !hasSalaryTable {
		log.Fatal("hedefte salary_payments tablosu yok -- önce migration 0048 uygulanmalı (yeni sürüm deploy edilmeli)")
	}

	var orgID, orgName string
	if err := tx.QueryRow(ctx,
		`SELECT id, name FROM organizations WHERE slug = $1 AND deleted_at IS NULL`, orgSlug,
	).Scan(&orgID, &orgName); err != nil {
		log.Fatalf("organizasyon bulunamadı (slug %q): %v", orgSlug, err)
	}
	fmt.Printf("Hedef organizasyon: %s (%s)\n", orgName, orgSlug)

	before := countOrg(ctx, tx, orgID)
	fmt.Printf("ARVEND'de ŞU AN: %d personel, %d mesai, %d maaş ödemesi.\n\n", before.emp, before.att, before.sal)

	existing := map[string]string{}
	rows, err := tx.Query(ctx, `SELECT id, full_name FROM employees WHERE organization_id = $1`, orgID)
	if err != nil {
		log.Fatalf("mevcut personel okunamadı: %v", err)
	}
	for rows.Next() {
		var id, name string
		if err := rows.Scan(&id, &name); err != nil {
			log.Fatalf("mevcut personel okunamadı: %v", err)
		}
		existing[nameKey(name)] = id
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		log.Fatalf("mevcut personel okunamadı: %v", err)
	}

	var skipped []skippedRow

	// --- Personel --------------------------------------------------------------
	idMap := map[bson.ObjectID]string{}
	var empInserted, empReused int
	fmt.Println("PERSONEL")
	for _, e := range employees {
		name := strings.Join(strings.Fields(e.FullName), " ")
		if id, ok := existing[nameKey(name)]; ok {
			idMap[e.ID] = id
			empReused++
			fmt.Printf("  = %-32s zaten var, mevcut kayıt kullanılacak\n", name)
			continue
		}
		var startDate *string
		if e.StartDate != nil {
			s := e.StartDate.In(istanbul).Format("2006-01-02")
			startDate = &s
		}
		var newID string
		if err := tx.QueryRow(ctx, `
			INSERT INTO employees (organization_id, full_name, phone, position, salary, daily_wage,
			                       start_date, is_active, description, created_at, updated_at)
			VALUES ($1, $2, $3, $4, $5, $6, $7::date, $8, $9, $10, now())
			RETURNING id
		`, orgID, name, strings.TrimSpace(e.Phone), strings.TrimSpace(e.Position),
			repository.Float64ToNumeric(e.Salary), repository.Float64ToNumeric(e.DailyWage),
			startDate, e.IsActive, e.Description, e.CreatedAt,
		).Scan(&newID); err != nil {
			log.Fatalf("personel %q eklenemedi: %v (hiçbir şey yazılmadı)", name, err)
		}
		idMap[e.ID] = newID
		existing[nameKey(name)] = newID
		empInserted++
		durum := ""
		if !e.IsActive {
			durum = " (pasif)"
		}
		fmt.Printf("  + %-32s eklendi%s\n", name, durum)
	}

	// --- Mesai -----------------------------------------------------------------
	// BYZ içi çiftler: aynı personel + aynı gün için en son girileni tut.
	type attKey struct {
		emp bson.ObjectID
		day string
	}
	latest := map[attKey]byzAttendance{}
	var attDup int
	for _, l := range logs {
		k := attKey{l.EmployeeID, l.Date.UTC().Format("2006-01-02")}
		prev, ok := latest[k]
		if !ok {
			latest[k] = l
			continue
		}
		older, newer := prev, l
		if l.CreatedAt.Before(prev.CreatedAt) {
			older, newer = l, prev
		}
		latest[k] = newer
		attDup++
		skipped = append(skipped, skippedRow{"mesai: BYZ içinde aynı personel+gün için ikinci kayıt; en son girilen aktarıldı, bu atlandı", attendanceJSON(older)})
	}
	attKeys := make([]attKey, 0, len(latest))
	for k := range latest {
		attKeys = append(attKeys, k)
	}
	sort.Slice(attKeys, func(i, j int) bool { return attKeys[i].day < attKeys[j].day })

	var attInserted, attExisting, attOrphan, attBadStatus int
	for _, k := range attKeys {
		l := latest[k]
		empID, ok := idMap[l.EmployeeID]
		if !ok {
			attOrphan++
			skipped = append(skipped, skippedRow{"mesai: personeli BYZ'den silinmiş", attendanceJSON(l)})
			continue
		}
		status := strings.TrimSpace(l.Status)
		if !allowedStatuses[status] {
			attBadStatus++
			skipped = append(skipped, skippedRow{fmt.Sprintf("mesai: ARVEND'in kabul etmediği durum %q", status), attendanceJSON(l)})
			continue
		}
		tag, err := tx.Exec(ctx, `
			INSERT INTO attendance_logs (organization_id, employee_id, date, check_in, check_out,
			                             work_hours, status, note, created_at)
			VALUES ($1, $2, $3::date, $4, $5, $6, $7, $8, $9)
			ON CONFLICT (employee_id, date) DO NOTHING
		`, orgID, empID, k.day, strings.TrimSpace(l.CheckIn), strings.TrimSpace(l.CheckOut),
			repository.Float64ToNumeric(l.WorkHours), status, l.Note, l.CreatedAt)
		if err != nil {
			log.Fatalf("mesai %s / %s eklenemedi: %v (hiçbir şey yazılmadı)", l.ID.Hex(), k.day, err)
		}
		if tag.RowsAffected() == 1 {
			attInserted++
		} else {
			attExisting++
		}
	}

	// --- Maaş ödemeleri ----------------------------------------------------------
	type salKey struct {
		emp    string // ARVEND employee id
		period string
		cents  int64
		day    string
		desc   string
	}
	groups := map[salKey][]byzSalary{}
	var salKeys []salKey
	var salOrphan, salInvalid int
	for _, s := range salaries {
		empID, ok := idMap[s.EmployeeID]
		if !ok {
			salOrphan++
			skipped = append(skipped, skippedRow{"maaş: personeli BYZ'den silinmiş", salaryJSON(s, istanbul)})
			continue
		}
		period := strings.TrimSpace(s.Month)
		reason := ""
		switch {
		case !s.IsPaid:
			reason = "maaş: BYZ'de ödenmedi işaretli (ARVEND'de ödenmemiş ödeme kavramı yok)"
		case !domain.ValidPeriod(period):
			reason = fmt.Sprintf("maaş: geçersiz ay %q", s.Month)
		case math.IsNaN(s.Amount) || s.Amount <= 0:
			reason = "maaş: tutar sıfır ya da eksi"
		}
		if reason != "" {
			salInvalid++
			skipped = append(skipped, skippedRow{reason, salaryJSON(s, istanbul)})
			continue
		}
		k := salKey{empID, period, int64(math.Round(s.Amount * 100)), paidDay(s, istanbul), strings.TrimSpace(s.Description)}
		if _, ok := groups[k]; !ok {
			salKeys = append(salKeys, k)
		}
		groups[k] = append(groups[k], s)
	}

	var salInserted, salExisting int
	for _, k := range salKeys {
		docs := groups[k]
		var already int
		if err := tx.QueryRow(ctx, `
			SELECT count(*) FROM salary_payments
			WHERE organization_id = $1 AND employee_id = $2 AND period = $3
			  AND amount = $4 AND paid_date = $5::date AND description = $6
		`, orgID, k.emp, k.period, repository.Float64ToNumeric(float64(k.cents)/100), k.day, k.desc).Scan(&already); err != nil {
			log.Fatalf("mevcut maaş ödemeleri sayılamadı: %v", err)
		}
		if already >= len(docs) {
			salExisting += len(docs)
			continue
		}
		salExisting += already
		for _, s := range docs[already:] {
			if _, err := tx.Exec(ctx, `
				INSERT INTO salary_payments (organization_id, employee_id, period, payment_type,
				                             amount, paid_date, description, created_at, updated_at)
				VALUES ($1, $2, $3, 'maaş', $4, $5::date, $6, $7, now())
			`, orgID, k.emp, k.period, repository.Float64ToNumeric(float64(k.cents)/100), k.day, k.desc, s.CreatedAt); err != nil {
				log.Fatalf("maaş ödemesi %s eklenemedi: %v (hiçbir şey yazılmadı)", s.ID.Hex(), err)
			}
			salInserted++
		}
	}

	after := countOrg(ctx, tx, orgID)

	fmt.Println()
	fmt.Println("ÖZET")
	fmt.Printf("  Personel : %3d eklendi, %3d zaten vardı (ARVEND: %d -> %d)\n", empInserted, empReused, before.emp, after.emp)
	fmt.Printf("  Mesai    : %3d eklendi, %3d zaten vardı (ARVEND: %d -> %d)\n", attInserted, attExisting, before.att, after.att)
	fmt.Printf("  Maaş     : %3d eklendi, %3d zaten vardı (ARVEND: %d -> %d)\n", salInserted, salExisting, before.sal, after.sal)
	fmt.Printf("  Atlanan  : %d\n", len(skipped))
	fmt.Printf("     mesai -> personeli silinmiş %d, BYZ içi çift %d, geçersiz durum %d\n", attOrphan, attDup, attBadStatus)
	fmt.Printf("     maaş  -> personeli silinmiş %d, kurala uymayan %d\n", salOrphan, salInvalid)

	if len(skipped) > 0 {
		b, _ := json.MarshalIndent(skipped, "", "  ")
		if err := os.WriteFile(skippedOut, b, 0o600); err != nil {
			log.Fatalf("atlanan kayıtlar dosyaya yazılamadı (%s): %v -- aktarım iptal", skippedOut, err)
		}
		fmt.Printf("  Atlanan kayıtların tamamı: %s\n", skippedOut)
	}

	if !apply {
		fmt.Println("\nDENEME BİTTİ -- hiçbir şey kaydedilmedi. Gerçek aktarım için APPLY=1.")
		return
	}
	if err := tx.Commit(ctx); err != nil {
		log.Fatalf("COMMIT başarısız: %v (hiçbir şey yazılmadı)", err)
	}
	fmt.Println("\nAKTARIM TAMAM -- kaydedildi.")
}

func readAll[T any](ctx context.Context, col *mongo.Collection, out *[]T) error {
	cur, err := col.Find(ctx, bson.M{})
	if err != nil {
		return err
	}
	return cur.All(ctx, out)
}

type orgCounts struct{ emp, att, sal int }

func countOrg(ctx context.Context, tx pgx.Tx, orgID string) orgCounts {
	var c orgCounts
	if err := tx.QueryRow(ctx, `
		SELECT (SELECT count(*) FROM employees       WHERE organization_id = $1),
		       (SELECT count(*) FROM attendance_logs WHERE organization_id = $1),
		       (SELECT count(*) FROM salary_payments WHERE organization_id = $1)
	`, orgID).Scan(&c.emp, &c.att, &c.sal); err != nil {
		log.Fatalf("kayıtlar sayılamadı: %v", err)
	}
	return c
}

// nameKey, "Ahmet  YILMAZ " ile "ahmet yılmaz"ı aynı kişi sayar.
func nameKey(s string) string {
	return domain.NormalizeName(strings.Join(strings.Fields(s), " "))
}

// paidDay, ödemenin İstanbul takvim günü. paid_date yoksa (BYZ'de hiç
// görülmedi) kaydın oluşturulma anı kullanılır.
func paidDay(s byzSalary, istanbul *time.Location) string {
	t := s.CreatedAt
	if s.PaidDate != nil {
		t = *s.PaidDate
	}
	return t.In(istanbul).Format("2006-01-02")
}

func attendanceJSON(l byzAttendance) map[string]any {
	return map[string]any{
		"byz_id":          l.ID.Hex(),
		"byz_employee_id": l.EmployeeID.Hex(),
		"date":            l.Date.UTC().Format("2006-01-02"),
		"check_in":        l.CheckIn,
		"check_out":       l.CheckOut,
		"work_hours":      l.WorkHours,
		"status":          l.Status,
		"note":            l.Note,
		"created_at":      l.CreatedAt.UTC().Format(time.RFC3339),
	}
}

func salaryJSON(s byzSalary, istanbul *time.Location) map[string]any {
	return map[string]any{
		"byz_id":          s.ID.Hex(),
		"byz_employee_id": s.EmployeeID.Hex(),
		"month":           s.Month,
		"amount":          s.Amount,
		"is_paid":         s.IsPaid,
		"paid_day":        paidDay(s, istanbul),
		"description":     s.Description,
		"created_at":      s.CreatedAt.UTC().Format(time.RFC3339),
	}
}
