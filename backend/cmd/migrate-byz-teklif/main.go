// migrate-byz-teklif, eski BYZ (Flask + MongoDB) sistemindeki teklifleri
// ("offers") ARVEND'de TEK bir organizasyona aktarır: teklif başlığı,
// revizyonlar, kalemler, müşteriler ve olay geçmişi.
//
// TEK SEFERLİK bir araçtır. Kaynağa (Mongo) yalnızca OKUMA yapar.
// Güvenlik modeli migrate-byz-personel ile aynıdır: varsayılan DENEME (her şey
// tek transaction'da yazılıp sınanır, sonra ROLLBACK), yalnızca APPLY=1 ile
// COMMIT; herhangi bir hata = hiçbir şey yazılmaz.
//
// BYZ'de revizyonlar İKİ farklı düzende tutulmuş (2026-10-04'te veri
// üzerinde doğrulandı):
//
//   - eski düzen: her revizyon AYRI bir belge, numarasında "-R<n>" eki
//     (TKF-2026-0004-R1, TKF-2026-0004-R3; 0008-R3 iki kez, biri pasif);
//   - yeni düzen: tek belge = güncel hâl (revision = N), revisions[] = önceki
//     hâllerin anlık görüntüleri (revision 0..N-1, revised_at = yerine yenisi
//     geçtiği an);
//   - 0008-R4 ikisini birden yapmış: ayrı belge + içinde 5 gömülü revizyon.
//
// Aktarım: belgeler "-R<n>" eki atılmış TEMEL numaraya göre gruplanır; grup
// içinde (ek numarası, oluşturulma) sırasıyla her belgenin gömülü
// revizyonları ve ardından kendi güncel hâli dizilir. ARVEND revizyonları
// 0'dan başlayıp ardışık artar (MAX+1) -- dizilen sıra 0..k-1 olarak yazılır.
// Hiçbir anlık görüntü düşürülmez (0008'in iki R3'ü de revizyon olur).
//
// Gömülü revizyonlarda müşteri alanı YOK -- ait olduğu belgenin müşterisi
// kullanılır. Oluşturulma anları yeniden kurulur: gömülü i. görüntü,
// (i-1).'nin revised_at anında oluşmuştur; ilki belgenin created_at'ında.
//
// Müşteriler: tekliflerdeki her farklı müşteri adı (domain.NormalizeName ile)
// ARVEND'de aynı adlı müşteri varsa ona bağlanır, yoksa oluşturulur (BYZ'nin
// customers koleksiyonunda kaydı varsa iletişim bilgisi/notu oradan alınır).
// Kalemler ürün adına göre organizasyonun ürünlerine bağlanır -- YALNIZCA tek
// bir eşleşme varsa; bağlanamayan kalem adıyla/fiyatıyla aynen kalır
// (product_id NULL, tablo buna izin veriyor).
//
// ARVEND'de karşılığı OLMAYAN BYZ alanları ARŞİV dosyasına yazılır (kaybolmaz,
// ama müşteriye görünen teklif notlarına da KARIŞTIRILMAZ -- iç maliyetler
// müşteri PDF'ine sızardı): masraflar (teklif iç masrafları), plan (iş planı),
// share (paylaşım linki; eski BYZ linkleri ARVEND'de çalışmaz). Paylaşım
// üzerinden yapılmış müşteri KABULÜ ise ARVEND'in olay geçmişine
// customer_accepted olarak işlenir.
//
// Tekrar çalıştırılabilir: ARVEND'de aynı numaralı ve offer_created olayının
// metadata.source'u "byz" olan bir teklif zaten varsa o grup atlanır. Aynı
// numarada BYZ'den GELMEMİŞ bir teklif varsa bu bir ÇAKIŞMADIR -- araç tahmin
// etmez, raporlayıp hiçbir şey yazmadan durur.
//
// Çakışmada araç iki tarafı yan yana basar (müşteri, tarih, tutar, durum) ve
// durur. Karar verildikten sonra SKIP_OFFERS="TKF-2026-0004,TKF-2026-0005"
// ile o numaralar atlanır: ARVEND'deki teklif olduğu gibi kalır, BYZ'deki
// tüm belgeleri arşiv dosyasına yazılır (kaybolmaz). Farklı tekliflerse
// RENAME_OFFERS="TKF-2026-0004=TKF-2026-0004-BYZ,..." ile BYZ'deki yeni
// numarayla aktarılır; asıl BYZ numarası olay metadata'sında (byz_offer_no)
// saklanır. (2026-10-04: canlıda ARVEND'in 0004/0005'i farklı müşterilerin
// teklifleriydi -- ARVEND'in sayacı baştan başlamıştı.)
//
// Kullanım:
//
//	SOURCE_MONGO_URI=... SOURCE_MONGO_DB=erp_teklif_sistemi DB_URL=... \
//	  TARGET_ORG_SLUG=arvend-yapi1 [SKIP_OFFERS=...] [APPLY=1] [SKIPPED_OUT=arsiv.json] \
//	  go run ./cmd/migrate-byz-teklif
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
	_ "time/tzdata"

	"github.com/jackc/pgx/v5"
	"go.mongodb.org/mongo-driver/v2/bson"
	"go.mongodb.org/mongo-driver/v2/mongo"
	"go.mongodb.org/mongo-driver/v2/mongo/options"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
)

// offers_status_check / offer_revisions_status_check ile aynı küme.
var allowedStatuses = map[string]bool{"taslak": true, "gönderildi": true, "kabul edildi": true, "reddedildi": true}

var (
	revSuffix = regexp.MustCompile(`-R(\d+)$`)
	offerNoRe = regexp.MustCompile(`^([A-Z]+)-(\d{4})-(\d{4})$`)
)

type byzItem struct {
	ProductName  string  `bson:"product_name"`
	Quantity     float64 `bson:"quantity"`
	UnitPrice    float64 `bson:"unit_price"`
	LineTotal    float64 `bson:"line_total"`
	SectionLabel *string `bson:"section_label"`
}

type byzRevision struct {
	Revision   float64    `bson:"revision"`
	ValidUntil *time.Time `bson:"valid_until"`
	Status     string     `bson:"status"`
	Notes      string     `bson:"notes"`
	Subtotal   float64    `bson:"subtotal"`
	VatRate    float64    `bson:"vat_rate"`
	VatAmount  float64    `bson:"vat_amount"`
	GrandTotal float64    `bson:"grand_total"`
	Items      []byzItem  `bson:"items"`
	RevisedAt  *time.Time `bson:"revised_at"`
}

type byzShare struct {
	AcceptedAt *time.Time `bson:"accepted_at"`
	AcceptedBy string     `bson:"accepted_by"`
}

type byzOffer struct {
	ID              bson.ObjectID `bson:"_id"`
	OfferNo         string        `bson:"offer_no"`
	CreatedAt       time.Time     `bson:"created_at"`
	OfferDate       *time.Time    `bson:"offer_date"`
	ValidUntil      *time.Time    `bson:"valid_until"`
	CustomerName    string        `bson:"customer_name"`
	CustomerPhone   string        `bson:"customer_phone"`
	CustomerEmail   string        `bson:"customer_email"`
	CustomerAddress string        `bson:"customer_address"`
	Status          string        `bson:"status"`
	Notes           string        `bson:"notes"`
	IsPassive       *bool         `bson:"is_passive"`
	Subtotal        float64       `bson:"subtotal"`
	VatRate         float64       `bson:"vat_rate"`
	VatAmount       float64       `bson:"vat_amount"`
	GrandTotal      float64       `bson:"grand_total"`
	Items           []byzItem     `bson:"items"`
	Revisions       []byzRevision `bson:"revisions"`
	Masraflar       bson.A        `bson:"masraflar"`
	Plan            bson.M        `bson:"plan"`
	Share           *byzShare     `bson:"share"`
}

type byzCustomer struct {
	Name    string `bson:"name"`
	Phone   string `bson:"phone"`
	Email   string `bson:"email"`
	Address string `bson:"address"`
	Notes   string `bson:"notes"`
}

// snapshot, ARVEND'de bir offer_revisions satırı olacak tek bir BYZ hâli.
type snapshot struct {
	source     string // ör. "TKF-2026-0008-R4 (gömülü rev 2)"
	doc        *byzOffer
	validUntil *time.Time
	status     string
	notes      string
	subtotal   float64
	vatRate    float64
	vatAmount  float64
	grandTotal float64
	items      []byzItem
	createdAt  time.Time
}

type archiveRow struct {
	OfferNo string          `json:"offer_no"`
	Field   string          `json:"field"`
	Reason  string          `json:"reason"`
	Data    json.RawMessage `json:"data"`
}

func main() {
	ctx := context.Background()

	sourceURI := os.Getenv("SOURCE_MONGO_URI")
	sourceDB := os.Getenv("SOURCE_MONGO_DB")
	pgURL := os.Getenv("DB_URL")
	orgSlug := os.Getenv("TARGET_ORG_SLUG")
	apply := os.Getenv("APPLY") == "1"
	skipOffers := map[string]bool{}
	for _, n := range strings.Split(os.Getenv("SKIP_OFFERS"), ",") {
		if n = strings.TrimSpace(n); n != "" {
			skipOffers[n] = true
		}
	}
	renames := map[string]string{}
	for _, pair := range strings.Split(os.Getenv("RENAME_OFFERS"), ",") {
		if from, to, ok := strings.Cut(strings.TrimSpace(pair), "="); ok {
			from, to = strings.TrimSpace(from), strings.TrimSpace(to)
			if from == "" || to == "" || len([]rune(to)) > 30 {
				log.Fatalf("RENAME_OFFERS geçersiz: %q (YENİ numara boş olamaz ve en çok 30 karakter)", pair)
			}
			renames[from] = to
		}
	}
	archiveOut := os.Getenv("SKIPPED_OUT")
	if archiveOut == "" {
		archiveOut = "byz-teklif-arsiv.json"
	}
	if sourceURI == "" || sourceDB == "" || pgURL == "" || orgSlug == "" {
		log.Fatal("SOURCE_MONGO_URI, SOURCE_MONGO_DB, DB_URL ve TARGET_ORG_SLUG gerekli")
	}
	ist, err := time.LoadLocation("Europe/Istanbul")
	if err != nil {
		log.Fatalf("Europe/Istanbul yüklenemedi: %v", err)
	}
	day := func(t *time.Time) *string {
		if t == nil || t.IsZero() {
			return nil
		}
		s := t.In(ist).Format("2006-01-02")
		return &s
	}

	if apply {
		fmt.Println(">>> GERÇEK AKTARIM (APPLY=1): sonunda COMMIT edilecek.")
	} else {
		fmt.Println(">>> DENEME: her şey yazılıp kısıtlarla sınanacak, sonunda GERİ ALINACAK (hiçbir şey kaydedilmez).")
	}

	// --- Kaynak ------------------------------------------------------------------
	mc, err := mongo.Connect(options.Client().ApplyURI(sourceURI))
	if err != nil {
		log.Fatalf("MongoDB'ye bağlanılamadı: %v", err)
	}
	defer mc.Disconnect(ctx)
	src := mc.Database(sourceDB)

	var offers []byzOffer
	if err := readAll(ctx, src.Collection("offers"), &offers); err != nil {
		log.Fatalf("offers okunamadı: %v", err)
	}
	// share'in tamamı arşiv için ham olarak da lazım.
	var rawShares []struct {
		ID    bson.ObjectID `bson:"_id"`
		Share bson.M        `bson:"share"`
	}
	if err := readAll(ctx, src.Collection("offers"), &rawShares); err != nil {
		log.Fatalf("offers (share) okunamadı: %v", err)
	}
	shareByID := map[bson.ObjectID]bson.M{}
	for _, r := range rawShares {
		if r.Share != nil {
			shareByID[r.ID] = r.Share
		}
	}
	var byzCustomers []byzCustomer
	if err := readAll(ctx, src.Collection("customers"), &byzCustomers); err != nil {
		log.Fatalf("customers okunamadı: %v", err)
	}
	byzCustByKey := map[string]byzCustomer{}
	for _, c := range byzCustomers {
		byzCustByKey[nameKey(c.Name)] = c
	}
	fmt.Printf("BYZ: %d teklif belgesi, %d müşteri kaydı okundu.\n", len(offers), len(byzCustomers))

	// --- Gruplama: temel numara -> belgeler -> anlık görüntüler ------------------
	groups := map[string][]*byzOffer{}
	for i := range offers {
		o := &offers[i]
		base := revSuffix.ReplaceAllString(strings.TrimSpace(o.OfferNo), "")
		groups[base] = append(groups[base], o)
	}
	bases := make([]string, 0, len(groups))
	for b := range groups {
		bases = append(bases, b)
	}
	sort.Strings(bases)

	var problems []string
	type plan struct {
		base       string
		prefix     string
		year, seq  int
		docs       []*byzOffer
		snaps      []snapshot
		latest     *byzOffer
		offerDate  string
		isPassive  bool
		status     string
		customerNm string
	}
	var plans []plan
	for _, base := range bases {
		docs := groups[base]
		sort.SliceStable(docs, func(i, j int) bool {
			si, sj := suffixNum(docs[i].OfferNo), suffixNum(docs[j].OfferNo)
			if si != sj {
				return si < sj
			}
			return docs[i].CreatedAt.Before(docs[j].CreatedAt)
		})
		m := offerNoRe.FindStringSubmatch(base)
		if m == nil {
			problems = append(problems, fmt.Sprintf("%s: teklif numarası beklenen biçimde değil (ÖNEK-YYYY-NNNN)", base))
			continue
		}
		year, _ := strconv.Atoi(m[2])
		seq, _ := strconv.Atoi(m[3])

		var snaps []snapshot
		for _, d := range docs {
			emb := append([]byzRevision(nil), d.Revisions...)
			sort.SliceStable(emb, func(i, j int) bool { return emb[i].Revision < emb[j].Revision })
			for i, r := range emb {
				created := d.CreatedAt
				if i > 0 && emb[i-1].RevisedAt != nil {
					created = *emb[i-1].RevisedAt
				}
				snaps = append(snaps, snapshot{
					source: fmt.Sprintf("%s (gömülü rev %d)", d.OfferNo, int(r.Revision)), doc: d,
					validUntil: r.ValidUntil, status: strings.TrimSpace(r.Status), notes: r.Notes,
					subtotal: r.Subtotal, vatRate: r.VatRate, vatAmount: r.VatAmount, grandTotal: r.GrandTotal,
					items: r.Items, createdAt: created,
				})
			}
			created := d.CreatedAt
			if n := len(emb); n > 0 && emb[n-1].RevisedAt != nil {
				created = *emb[n-1].RevisedAt
			}
			snaps = append(snaps, snapshot{
				source: d.OfferNo, doc: d,
				validUntil: d.ValidUntil, status: strings.TrimSpace(d.Status), notes: d.Notes,
				subtotal: d.Subtotal, vatRate: d.VatRate, vatAmount: d.VatAmount, grandTotal: d.GrandTotal,
				items: d.Items, createdAt: created,
			})
		}
		latest := docs[len(docs)-1]
		p := plan{base: base, prefix: m[1], year: year, seq: seq, docs: docs, snaps: snaps, latest: latest,
			status: snaps[len(snaps)-1].status, customerNm: strings.Join(strings.Fields(latest.CustomerName), " ")}
		if od := day(docs[0].OfferDate); od != nil {
			p.offerDate = *od
		} else {
			p.offerDate = docs[0].CreatedAt.In(ist).Format("2006-01-02")
		}
		if latest.IsPassive != nil {
			p.isPassive = *latest.IsPassive
		}
		// Uzunluk ve küme kontrolleri -- DB hatasıyla tek tek değil, hepsi bir arada.
		check := func(label, v string, max int) {
			if n := len([]rune(v)); n > max {
				problems = append(problems, fmt.Sprintf("%s: %s %d karakter (en çok %d)", base, label, n, max))
			}
		}
		for _, s := range snaps {
			if !allowedStatuses[s.status] {
				problems = append(problems, fmt.Sprintf("%s: %s durumu %q ARVEND'de yok", base, s.source, s.status))
			}
			check("müşteri adı", s.doc.CustomerName, 200)
			check("telefon", s.doc.CustomerPhone, 40)
			check("e-posta", s.doc.CustomerEmail, 120)
			check("adres", s.doc.CustomerAddress, 500)
			for _, it := range s.items {
				check("ürün adı", it.ProductName, 200)
				if it.SectionLabel != nil {
					check("bölüm etiketi", *it.SectionLabel, 120)
				}
			}
		}
		if p.customerNm == "" {
			problems = append(problems, fmt.Sprintf("%s: müşteri adı boş", base))
		}
		plans = append(plans, p)
	}
	if len(problems) > 0 {
		fmt.Println("\nAKTARILAMAYAN VERİ -- hiçbir şey yazılmadı:")
		for _, p := range problems {
			fmt.Println("  - " + p)
		}
		os.Exit(1)
	}

	// --- Hedef --------------------------------------------------------------------
	pool, err := repository.NewPool(ctx, pgURL)
	if err != nil {
		log.Fatalf("PostgreSQL'e bağlanılamadı: %v", err)
	}
	defer pool.Close()
	tx, err := pool.Begin(ctx)
	if err != nil {
		log.Fatalf("transaction açılamadı: %v", err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck

	var orgID, orgName string
	if err := tx.QueryRow(ctx, `SELECT id, name FROM organizations WHERE slug = $1 AND deleted_at IS NULL`, orgSlug).
		Scan(&orgID, &orgName); err != nil {
		log.Fatalf("organizasyon bulunamadı (slug %q): %v", orgSlug, err)
	}
	fmt.Printf("Hedef organizasyon: %s (%s)\n", orgName, orgSlug)
	before := countOrg(ctx, tx, orgID)
	fmt.Printf("ARVEND'de ŞU AN: %d teklif, %d revizyon, %d müşteri.\n\n", before.offers, before.revisions, before.customers)

	// Mevcut müşteriler (ada göre) ve ürünler (normalize ada göre, YALNIZCA tekil eşleşme).
	custByKey := map[string]string{}
	rows, err := tx.Query(ctx, `SELECT id, name FROM customers WHERE organization_id = $1`, orgID)
	if err != nil {
		log.Fatalf("müşteriler okunamadı: %v", err)
	}
	for rows.Next() {
		var id, name string
		if err := rows.Scan(&id, &name); err != nil {
			log.Fatalf("müşteriler okunamadı: %v", err)
		}
		custByKey[nameKey(name)] = id
	}
	rows.Close()

	type prod struct{ id, unit string }
	prodByKey := map[string][]prod{}
	rows, err = tx.Query(ctx, `SELECT id, normalized_name, unit FROM products WHERE organization_id = $1`, orgID)
	if err != nil {
		log.Fatalf("ürünler okunamadı: %v", err)
	}
	for rows.Next() {
		var id, nn, unit string
		if err := rows.Scan(&id, &nn, &unit); err != nil {
			log.Fatalf("ürünler okunamadı: %v", err)
		}
		prodByKey[nn] = append(prodByKey[nn], prod{id, unit})
	}
	rows.Close()

	var archive []archiveRow
	var conflicts []string
	var nOffers, nRevs, nItems, nLinked, nUnlinked, nCustNew, nCustReused, nEvents, nSkipped int
	maxSeq := map[int]int{}

	fmt.Println("TEKLİFLER")
	var nUserSkipped int
	for _, p := range plans {
		if skipOffers[p.base] {
			for _, d := range p.docs {
				archive = append(archive, archiveRow{d.OfferNo, "teklif", "ARVEND'de aynı numarada teklif var; SKIP_OFFERS ile atlandı (ARVEND'deki korundu)", extJSON(rawOffer(ctx, src, d.ID))})
			}
			nUserSkipped++
			fmt.Printf("  - %-15s SKIP_OFFERS: atlandı, BYZ belgeleri arşive yazıldı\n", p.base)
			continue
		}
		offerNo := p.base
		if r, ok := renames[p.base]; ok {
			offerNo = r
		}

		// Daha önce bu araçla aktarılmış mı / çakışıyor mu?
		var existingID string
		var fromBYZ bool
		err := tx.QueryRow(ctx, `
			SELECT o.id, EXISTS (SELECT 1 FROM offer_events e WHERE e.offer_id = o.id
			                     AND e.event_type = 'offer_created' AND e.metadata->>'source' = 'byz')
			FROM offers o WHERE o.organization_id = $1 AND o.offer_no = $2`, orgID, offerNo).Scan(&existingID, &fromBYZ)
		if err == nil {
			if fromBYZ {
				nSkipped++
				fmt.Printf("  = %-17s daha önce aktarılmış, atlandı\n", offerNo)
				continue
			}
			conflicts = append(conflicts, offerNo)
			continue
		} else if !errors.Is(err, pgx.ErrNoRows) {
			log.Fatalf("%s kontrol edilemedi: %v", p.base, err)
		}

		// Müşteri: varsa bağla, yoksa oluştur.
		ck := nameKey(p.customerNm)
		custID, ok := custByKey[ck]
		if ok {
			nCustReused++
		} else {
			phone, email, address, notes := p.latest.CustomerPhone, p.latest.CustomerEmail, p.latest.CustomerAddress, ""
			if bc, ok := byzCustByKey[ck]; ok {
				phone, email, address, notes = firstNonEmpty(bc.Phone, phone), firstNonEmpty(bc.Email, email), firstNonEmpty(bc.Address, address), bc.Notes
			}
			if err := tx.QueryRow(ctx, `
				INSERT INTO customers (organization_id, name, phone, email, address, notes, created_at, updated_at)
				VALUES ($1, $2, $3, $4, $5, $6, $7, now()) RETURNING id`,
				orgID, p.customerNm, strings.TrimSpace(phone), strings.TrimSpace(email), strings.TrimSpace(address), notes, p.docs[0].CreatedAt,
			).Scan(&custID); err != nil {
				log.Fatalf("%s müşterisi %q oluşturulamadı: %v (hiçbir şey yazılmadı)", p.base, p.customerNm, err)
			}
			custByKey[ck] = custID
			nCustNew++
		}

		// Teklif başlığı -- current_revision_id revizyonlardan sonra bağlanır.
		var offerID string
		first, last := p.snaps[0], p.snaps[len(p.snaps)-1]
		if err := tx.QueryRow(ctx, `
			INSERT INTO offers (organization_id, offer_no, offer_date, status, is_passive, created_at, updated_at)
			VALUES ($1, $2, $3::date, $4, $5, $6, $7) RETURNING id`,
			orgID, offerNo, p.offerDate, p.status, p.isPassive, first.createdAt, last.createdAt,
		).Scan(&offerID); err != nil {
			log.Fatalf("%s eklenemedi: %v (hiçbir şey yazılmadı)", p.base, err)
		}

		var revIDs []string
		for n, s := range p.snaps {
			var revID string
			if err := tx.QueryRow(ctx, `
				INSERT INTO offer_revisions (organization_id, offer_id, revision_no, customer_id,
				    customer_name, customer_phone, customer_email, customer_address, valid_until,
				    subtotal, vat_rate, vat_amount, grand_total, notes, status, created_at)
				VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9::date, $10, $11, $12, $13, $14, $15, $16)
				RETURNING id`,
				orgID, offerID, n, custID,
				strings.Join(strings.Fields(s.doc.CustomerName), " "), strings.TrimSpace(s.doc.CustomerPhone),
				strings.TrimSpace(s.doc.CustomerEmail), strings.TrimSpace(s.doc.CustomerAddress), day(s.validUntil),
				repository.Float64ToNumeric(s.subtotal), repository.Float64ToNumeric(s.vatRate),
				repository.Float64ToNumeric(s.vatAmount), repository.Float64ToNumeric(s.grandTotal),
				s.notes, s.status, s.createdAt,
			).Scan(&revID); err != nil {
				log.Fatalf("%s revizyon %d (%s) eklenemedi: %v (hiçbir şey yazılmadı)", p.base, n, s.source, err)
			}
			revIDs = append(revIDs, revID)
			nRevs++

			for i, it := range s.items {
				var productID *string
				unit := ""
				if m := prodByKey[domain.NormalizeName(strings.Join(strings.Fields(it.ProductName), " "))]; len(m) == 1 {
					productID, unit = &m[0].id, m[0].unit
					nLinked++
				} else {
					nUnlinked++
				}
				var section *string
				if it.SectionLabel != nil && strings.TrimSpace(*it.SectionLabel) != "" {
					v := strings.TrimSpace(*it.SectionLabel)
					section = &v
				}
				if _, err := tx.Exec(ctx, `
					INSERT INTO offer_revision_items (revision_id, product_id, product_name, quantity, unit_price,
					                                  line_total, sort_order, unit, section_label)
					VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)`,
					revID, productID, strings.TrimSpace(it.ProductName), repository.Float64ToNumeric(it.Quantity),
					repository.Float64ToNumeric(it.UnitPrice), repository.Float64ToNumeric(it.LineTotal), i, unit, section,
				); err != nil {
					log.Fatalf("%s rev %d kalem %d eklenemedi: %v (hiçbir şey yazılmadı)", p.base, n, i, err)
				}
				nItems++
			}

			evType, meta := "revision_created", map[string]any{"source": "byz", "revision_no": n, "byz": s.source}
			if n == 0 {
				ids := make([]string, len(p.docs))
				for i, d := range p.docs {
					ids[i] = d.ID.Hex()
				}
				evType, meta = "offer_created", map[string]any{"source": "byz", "byz_ids": ids, "byz": s.source, "byz_offer_no": p.base}
			}
			if err := insertEvent(ctx, tx, orgID, offerID, revID, evType, meta, s.createdAt); err != nil {
				log.Fatalf("%s olay kaydı eklenemedi: %v", p.base, err)
			}
			nEvents++
		}

		if _, err := tx.Exec(ctx, `UPDATE offers SET current_revision_id = $2 WHERE id = $1`, offerID, revIDs[len(revIDs)-1]); err != nil {
			log.Fatalf("%s güncel revizyon bağlanamadı: %v", p.base, err)
		}

		// Müşteri kabulü (paylaşım linkiyle) -> olay geçmişi; geri kalan her şey arşive.
		for _, d := range p.docs {
			if d.Share != nil && d.Share.AcceptedAt != nil {
				if err := insertEvent(ctx, tx, orgID, offerID, revIDs[len(revIDs)-1], "customer_accepted",
					map[string]any{"source": "byz", "accepted_by": d.Share.AcceptedBy, "byz": d.OfferNo}, *d.Share.AcceptedAt); err != nil {
					log.Fatalf("%s kabul olayı eklenemedi: %v", p.base, err)
				}
				nEvents++
			}
			if len(d.Masraflar) > 0 {
				archive = append(archive, archiveRow{d.OfferNo, "masraflar", "ARVEND tekliflerinde iç masraf alanı yok", extJSON(d.Masraflar)})
			}
			if len(d.Plan) > 0 {
				archive = append(archive, archiveRow{d.OfferNo, "plan", "ARVEND tekliflerinde iş planı alanı yok", extJSON(d.Plan)})
			}
			if sh, ok := shareByID[d.ID]; ok {
				archive = append(archive, archiveRow{d.OfferNo, "share", "eski BYZ paylaşım linki ARVEND'de çalışmaz (kabul, olay geçmişine işlendi)", extJSON(sh)})
			}
		}

		if p.seq > maxSeq[p.year] {
			maxSeq[p.year] = p.seq
		}
		nOffers++
		pas := ""
		if p.isPassive {
			pas = "  (pasif)"
		}
		yeni := ""
		if offerNo != p.base {
			yeni = "  (BYZ'de " + p.base + ")"
		}
		fmt.Printf("  + %-17s %2d revizyon  %-13s %s%s%s\n", offerNo, len(p.snaps), p.status, p.customerNm, pas, yeni)
	}

	if len(conflicts) > 0 {
		fmt.Println("\nÇAKIŞMA -- ARVEND'de bu numaralarla BYZ'den GELMEMİŞ teklifler var, hiçbir şey yazılmadı.")
		fmt.Println("Aynı teklifse SKIP_OFFERS ile atlayın; farklıysa numaralandırma kararı gerekir.")
		byBase := map[string]plan{}
		for _, p := range plans {
			byBase[p.base] = p
		}
		for _, c := range conflicts {
			fmt.Printf("\n  %s\n", c)
			var date, status, cust, created string
			var total float64
			var revs int
			if err := tx.QueryRow(ctx, `
				SELECT o.offer_date::text, o.status, COALESCE(r.customer_name, ''), COALESCE(r.grand_total, 0)::float8,
				       to_char(o.created_at AT TIME ZONE 'Europe/Istanbul', 'YYYY-MM-DD HH24:MI'),
				       (SELECT count(*) FROM offer_revisions x WHERE x.offer_id = o.id)
				FROM offers o LEFT JOIN offer_revisions r ON r.id = o.current_revision_id
				WHERE o.organization_id = $1 AND o.offer_no = $2`, orgID, c,
			).Scan(&date, &status, &cust, &total, &created, &revs); err == nil {
				fmt.Printf("    ARVEND : %s  %-13s %-32s %14s  (%d rev, oluşturuldu %s)\n", date, status, cust, money(total), revs, created)
			}
			if p, ok := byBase[c]; ok {
				last := p.snaps[len(p.snaps)-1]
				fmt.Printf("    BYZ    : %s  %-13s %-32s %14s  (%d rev, oluşturuldu %s)\n", p.offerDate, p.status, p.customerNm, money(last.grandTotal), len(p.snaps), p.docs[0].CreatedAt.In(ist).Format("2006-01-02 15:04"))
			}
		}
		fmt.Println("\n  ARVEND'de zaten olan diğer teklifler (BYZ'den gelmeyen):")
		crow, _ := tx.Query(ctx, `
			SELECT o.offer_no, o.offer_date::text, o.status, COALESCE(r.customer_name, ''), COALESCE(r.grand_total, 0)::float8
			FROM offers o LEFT JOIN offer_revisions r ON r.id = o.current_revision_id
			WHERE o.organization_id = $1
			  AND NOT EXISTS (SELECT 1 FROM offer_events e WHERE e.offer_id = o.id
			                  AND e.event_type = 'offer_created' AND e.metadata->>'source' = 'byz')
			ORDER BY o.offer_no`, orgID)
		for crow.Next() {
			var no, date, status, cust string
			var total float64
			_ = crow.Scan(&no, &date, &status, &cust, &total)
			if !contains(conflicts, no) {
				fmt.Printf("    %s  %s  %-13s %-32s %14s\n", no, date, status, cust, money(total))
			}
		}
		crow.Close()
		os.Exit(1)
	}

	// Sayaç: ARVEND'de açılacak ilk yeni teklif aktarılanlarla çakışmasın.
	for year, seq := range maxSeq {
		var old int
		_ = tx.QueryRow(ctx, `SELECT seq FROM offer_counters WHERE organization_id = $1 AND year = $2`, orgID, year).Scan(&old)
		if _, err := tx.Exec(ctx, `
			INSERT INTO offer_counters (organization_id, year, seq) VALUES ($1, $2, $3)
			ON CONFLICT (organization_id, year) DO UPDATE SET seq = GREATEST(offer_counters.seq, EXCLUDED.seq)`,
			orgID, year, seq); err != nil {
			log.Fatalf("teklif sayacı güncellenemedi: %v", err)
		}
		fmt.Printf("\nTeklif sayacı %d: %d -> %d (sıradaki yeni teklif %04d)\n", year, old, max(old, seq), max(old, seq)+1)
	}

	after := countOrg(ctx, tx, orgID)
	fmt.Println()
	fmt.Println("ÖZET")
	fmt.Printf("  Teklif    : %d eklendi, %d daha önce aktarılmıştı, %d SKIP_OFFERS ile atlandı (ARVEND: %d -> %d)\n", nOffers, nSkipped, nUserSkipped, before.offers, after.offers)
	fmt.Printf("  Revizyon  : %d (ARVEND: %d -> %d)\n", nRevs, before.revisions, after.revisions)
	fmt.Printf("  Kalem     : %d (%d ürüne bağlandı, %d yalnızca adıyla)\n", nItems, nLinked, nUnlinked)
	fmt.Printf("  Müşteri   : %d yeni, %d mevcut kullanıldı (ARVEND: %d -> %d)\n", nCustNew, nCustReused, before.customers, after.customers)
	fmt.Printf("  Olay      : %d (oluşturma/revizyon/müşteri kabulü)\n", nEvents)
	fmt.Printf("  Arşiv     : %d kayıt (masraflar/plan/paylaşım linki)\n", len(archive))

	if len(archive) > 0 {
		b, _ := json.MarshalIndent(archive, "", "  ")
		if err := os.WriteFile(archiveOut, b, 0o600); err != nil {
			log.Fatalf("arşiv dosyası yazılamadı (%s): %v -- aktarım iptal", archiveOut, err)
		}
		fmt.Printf("  Arşiv dosyası: %s\n", archiveOut)
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

type orgCounts struct{ offers, revisions, customers int }

func countOrg(ctx context.Context, tx pgx.Tx, orgID string) orgCounts {
	var c orgCounts
	if err := tx.QueryRow(ctx, `
		SELECT (SELECT count(*) FROM offers          WHERE organization_id = $1),
		       (SELECT count(*) FROM offer_revisions WHERE organization_id = $1),
		       (SELECT count(*) FROM customers       WHERE organization_id = $1)`, orgID,
	).Scan(&c.offers, &c.revisions, &c.customers); err != nil {
		log.Fatalf("kayıtlar sayılamadı: %v", err)
	}
	return c
}

func insertEvent(ctx context.Context, tx pgx.Tx, orgID, offerID, revID, eventType string, meta map[string]any, at time.Time) error {
	b, err := json.Marshal(meta)
	if err != nil {
		return err
	}
	_, err = tx.Exec(ctx, `
		INSERT INTO offer_events (organization_id, offer_id, revision_id, event_type, metadata, created_at)
		VALUES ($1, $2, $3, $4, $5::jsonb, $6)`, orgID, offerID, revID, eventType, string(b), at)
	return err
}

// suffixNum, "-R3" -> 3; eki olmayan belge 0 (en önce).
func suffixNum(offerNo string) int {
	if m := revSuffix.FindStringSubmatch(strings.TrimSpace(offerNo)); m != nil {
		n, _ := strconv.Atoi(m[1])
		return n
	}
	return 0
}

func contains(list []string, v string) bool {
	for _, x := range list {
		if x == v {
			return true
		}
	}
	return false
}

// money, "1234567.5" -> "1.234.567,50 TL" (rapor okunaklı olsun diye).
func money(v float64) string {
	s := strconv.FormatFloat(v, 'f', 2, 64)
	intPart, frac := s[:len(s)-3], s[len(s)-2:]
	var b strings.Builder
	for i, r := range intPart {
		if i > 0 && (len(intPart)-i)%3 == 0 && r != '-' {
			b.WriteByte('.')
		}
		b.WriteRune(r)
	}
	return b.String() + "," + frac + " TL"
}

// rawOffer, arşiv için belgenin HAM hâli (hiçbir alan düşmeden).
func rawOffer(ctx context.Context, src *mongo.Database, id bson.ObjectID) bson.M {
	var m bson.M
	if err := src.Collection("offers").FindOne(ctx, bson.M{"_id": id}).Decode(&m); err != nil {
		return bson.M{"_id": id, "okuma_hatasi": err.Error()}
	}
	return m
}

func nameKey(s string) string { return domain.NormalizeName(strings.Join(strings.Fields(s), " ")) }

func firstNonEmpty(a, b string) string {
	if strings.TrimSpace(a) != "" {
		return a
	}
	return b
}

func extJSON(v any) json.RawMessage {
	b, err := bson.MarshalExtJSON(bson.M{"v": v}, false, false)
	if err != nil {
		return json.RawMessage(fmt.Sprintf("%q", fmt.Sprint(v)))
	}
	var wrapped struct {
		V json.RawMessage `json:"v"`
	}
	if err := json.Unmarshal(b, &wrapped); err != nil {
		return json.RawMessage(b)
	}
	return wrapped.V
}
