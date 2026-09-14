package service

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/platform/mailer"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

type OfferService struct {
	pool        *pgxpool.Pool
	q           *sqlc.Queries
	settingsSvc *SettingsService
	frontendURL string

	// SendMailFunc, gerçek SMTP gönderimini yapar -- varsayılan olarak
	// mailer.Send'dir, testlerde sahte (fake) bir gönderici ile
	// değiştirilebilir (email_sent/email_failed senaryolarını gerçek bir
	// SMTP sunucusu olmadan test edebilmek için).
	SendMailFunc func(domain.SmtpSettings, mailer.Message) error
}

func NewOfferService(pool *pgxpool.Pool, q *sqlc.Queries, settingsSvc *SettingsService, frontendURL string) *OfferService {
	return &OfferService{pool: pool, q: q, settingsSvc: settingsSvc, frontendURL: frontendURL, SendMailFunc: mailer.Send}
}

// truncateRunes, bir metni en fazla max KARAKTERE kısaltır (Postgres
// varchar(n) sınırı da karakter cinsindendir; bayt cinsinden kesmek çok
// baytlı bir karakteri ortadan bölerdi).
func truncateRunes(s string, max int) string {
	r := []rune(s)
	if len(r) <= max {
		return s
	}
	return string(r[:max])
}

// logOfferEvent, offer_events'e değişmez bir denetim kaydı yazar. Durum
// değiştiren akışlarda (Create/Update/Revise/UpdateStatus/...) çağıran,
// AYNI transaction'ın q'sunu (txq) geçirmelidir -- böylece olay kaydı,
// tetikleyen durum değişikliğiyle atomik olur: ya ikisi de commit olur ya
// hiçbiri (audit log'un "state değişti ama kaydı yok" durumuna düşmemesi
// için). Salt-okunur genel uçlardaki (customer_viewed gibi) tek istisna
// için çağıran hatayı bilerek yutabilir. Paket düzeyinde bir fonksiyondur
// (OfferService metodu değil), çünkü ProjectService de teklifin zaman
// çizelgesine project_created olayını yazar.
func logOfferEvent(ctx context.Context, q *sqlc.Queries, orgID, offerID, revisionID pgtype.UUID, eventType string, userID pgtype.UUID, metadata map[string]any, ip, userAgent string) error {
	// ip/user_agent tamamen istemcinin (ya da aradaki proxy'lerin) kontrol
	// ettiği başlıklardan gelir ve kolonlardan uzun olabilir. Kolon sınırını
	// aşan bir değer INSERT'i patlatır; RespondByShareLinkToken'da olay
	// kaydı kararın transaction'ı İÇİNDE olduğundan bu, müşterinin teklifi
	// kabul etmesini tamamen engellerdi. Denetim kaydı asla bu yüzden
	// başarısız olmamalı -- sınıra kısaltıyoruz.
	ip = truncateRunes(ip, 45)
	userAgent = truncateRunes(userAgent, 500)

	metaBytes := []byte("{}")
	if len(metadata) > 0 {
		b, err := json.Marshal(metadata)
		if err != nil {
			return err
		}
		metaBytes = b
	}
	_, err := q.CreateOfferEvent(ctx, sqlc.CreateOfferEventParams{
		OrganizationID: orgID,
		OfferID:        offerID,
		RevisionID:     revisionID,
		EventType:      eventType,
		UserID:         userID,
		Metadata:       metaBytes,
		IpAddress:      ip,
		UserAgent:      userAgent,
	})
	return err
}

type OfferItemInput struct {
	ProductID   *string
	ProductName string
	Quantity    float64
	UnitPrice   float64

	// Unit/SectionLabel/CalcCategoryID/CalcSnapshot: Metraj Hesaplama
	// entegrasyonundan ("Metraj Hesapla" -> "Teklife Ekle") gelen
	// kalemler için doldurulur; serbest/elle girilen kalemlerde hepsi
	// sıfır değerdir. CalcCategoryID verilmişse aynı organizasyona ait
	// olduğu doğrulanır (bkz. insertRevisionItems) -- doğrulanamazsa
	// sessizce NULL'a düşürülür (product_id ile AYNI, mevcut ilke).
	Unit           string
	SectionLabel   *string
	CalcCategoryID *string
	CalcSnapshot   json.RawMessage
}

type CreateOfferInput struct {
	// CustomerID doluysa, customer_name/phone/email/address burada ne
	// gönderilirse gönderilsin YOK SAYILIR -- o anki müşteri kartından
	// alınıp revizyona anlık görüntü (snapshot) olarak yazılır.
	CustomerID      *string
	CustomerName    string
	CustomerPhone   string
	CustomerEmail   string
	CustomerAddress string
	ValidUntil      *time.Time
	Notes           string
	// VatRate nil ise (istekte hiç gönderilmemişse) %20 varsayılır;
	// açıkça 0 gönderilirse 0 olarak KALIR (BYZ'deki falsy-zero bug'ının
	// tekrarlanmaması için pointer kullanılır).
	VatRate        *float64
	Items          []OfferItemInput
	UserID         string
	OrganizationID string
}

type computedOfferItem struct {
	OfferItemInput
	LineTotal float64
}

// computeOfferTotals, Create/Update/Revise arasında paylaşılan hesaplama
// mantığı -- frontend'den gelen subtotal/vat_amount/grand_total değerlerine
// ASLA güvenilmez, her zaman burada sunucu tarafında yeniden hesaplanır.
func computeOfferTotals(items []OfferItemInput, vatRateInput *float64) ([]computedOfferItem, float64, float64, float64, float64, error) {
	vatRate := 20.0
	if vatRateInput != nil {
		vatRate = *vatRateInput
	}
	computed := make([]computedOfferItem, 0, len(items))
	subtotal := 0.0
	for _, it := range items {
		name := strings.TrimSpace(it.ProductName)
		if name == "" || it.Quantity <= 0 || it.UnitPrice < 0 {
			continue
		}
		lineTotal := round2(it.Quantity * it.UnitPrice)
		subtotal += lineTotal
		computed = append(computed, computedOfferItem{OfferItemInput: it, LineTotal: lineTotal})
	}
	if len(computed) == 0 {
		return nil, 0, 0, 0, 0, errors.New("geçerli en az bir kalem girilmelidir")
	}
	subtotal = round2(subtotal)
	vatAmount := round2(subtotal * vatRate / 100)
	grandTotal := round2(subtotal + vatAmount)
	return computed, subtotal, vatRate, vatAmount, grandTotal, nil
}

// resolveCustomerSnapshot, customerID doluysa o müşterinin o anki
// bilgilerini döner (snapshot için); boşsa sıfır değerler döner ve
// çağıran serbest-metin girdiyi kullanmaya devam eder.
func resolveCustomerSnapshot(ctx context.Context, txq *sqlc.Queries, orgID pgtype.UUID, customerID *string) (pgtype.UUID, sqlc.Customer, error) {
	var custID pgtype.UUID
	if customerID == nil || *customerID == "" {
		return custID, sqlc.Customer{}, nil
	}
	cid, err := repository.StringToUUID(*customerID)
	if err != nil {
		return custID, sqlc.Customer{}, errors.New("geçersiz müşteri")
	}
	customer, err := txq.GetCustomerByID(ctx, sqlc.GetCustomerByIDParams{ID: cid, OrganizationID: orgID})
	if err != nil {
		return custID, sqlc.Customer{}, errors.New("geçersiz müşteri")
	}
	return cid, customer, nil
}

// insertRevisionItems, yeni girilen kalemleri bir revizyona yazar -- her
// product_id (varsa) aynı organizasyona ait olmadan kabul edilmez (tenant
// izolasyonu); aksi halde geçersiz UUID'de olduğu gibi sessizce serbest
// metin satıra düşürülür. calc_category_id AYNI ilkeyle doğrulanır --
// başka bir organizasyonun kategori id'si sessizce NULL'a düşer, calc_snapshot
// (dondurulmuş sonuç) buna bakılmaksızın olduğu gibi yazılır.
func insertRevisionItems(ctx context.Context, txq *sqlc.Queries, revisionID, orgID pgtype.UUID, items []computedOfferItem) ([]domain.OfferItem, error) {
	domainItems := make([]domain.OfferItem, 0, len(items))
	for i, it := range items {
		var productID pgtype.UUID
		if it.ProductID != nil {
			if pid, err := repository.StringToUUID(*it.ProductID); err == nil {
				if _, err := txq.GetProductByID(ctx, sqlc.GetProductByIDParams{ID: pid, OrganizationID: orgID}); err == nil {
					productID = pid
				}
			}
		}
		var calcCategoryID pgtype.UUID
		if it.CalcCategoryID != nil {
			if cid, err := repository.StringToUUID(*it.CalcCategoryID); err == nil {
				if _, err := txq.GetCalcCategoryByID(ctx, sqlc.GetCalcCategoryByIDParams{ID: cid, OrganizationID: orgID}); err == nil {
					calcCategoryID = cid
				}
			}
		}
		itemRow, err := txq.CreateOfferRevisionItem(ctx, sqlc.CreateOfferRevisionItemParams{
			RevisionID:     revisionID,
			ProductID:      productID,
			ProductName:    strings.TrimSpace(it.ProductName),
			Quantity:       repository.Float64ToNumeric(it.Quantity),
			UnitPrice:      repository.Float64ToNumeric(it.UnitPrice),
			DiscountType:   domain.DiscountNone,
			DiscountValue:  repository.Float64ToNumeric(0),
			LineTotal:      repository.Float64ToNumeric(it.LineTotal),
			SortOrder:      int32(i),
			Unit:           strings.TrimSpace(it.Unit),
			SectionLabel:   it.SectionLabel,
			CalcCategoryID: calcCategoryID,
			CalcSnapshot:   []byte(it.CalcSnapshot),
		})
		if err != nil {
			return nil, err
		}
		domainItems = append(domainItems, repository.ToDomainOfferRevisionItem(itemRow))
	}
	return domainItems, nil
}

// cloneRevisionItems, "Revize Et" ile önceki revizyonun kalemlerini AYNEN
// yeni revizyona kopyalar -- product_id tekrar doğrulanmaz (önceki
// revizyonda zaten doğrulanmıştı, organizasyon değişmez).
// cloneRevisionItems, "Revize Et" ile önceki revizyonun kalemlerini AYNEN
// yeni revizyona kopyalar -- calc_category_id/calc_snapshot dahil, TÜM
// alanlar birebir taşınır (calc_category_id zaten bir önceki revizyonda
// doğrulanmıştı, tekrar sorgulanmaz -- product_id ile aynı ilke).
func cloneRevisionItems(ctx context.Context, txq *sqlc.Queries, newRevisionID pgtype.UUID, items []sqlc.OfferRevisionItem) error {
	for _, it := range items {
		if _, err := txq.CreateOfferRevisionItem(ctx, sqlc.CreateOfferRevisionItemParams{
			RevisionID:     newRevisionID,
			ProductID:      it.ProductID,
			ProductName:    it.ProductName,
			Quantity:       it.Quantity,
			UnitPrice:      it.UnitPrice,
			DiscountType:   it.DiscountType,
			DiscountValue:  it.DiscountValue,
			LineTotal:      it.LineTotal,
			SortOrder:      it.SortOrder,
			Unit:           it.Unit,
			SectionLabel:   it.SectionLabel,
			CalcCategoryID: it.CalcCategoryID,
			CalcSnapshot:   it.CalcSnapshot,
		}); err != nil {
			return err
		}
	}
	return nil
}

func (s *OfferService) Create(ctx context.Context, in CreateOfferInput) (*domain.Offer, error) {
	orgID, err := repository.StringToUUID(in.OrganizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	if len(in.Items) == 0 {
		return nil, errors.New("en az bir kalem girilmelidir")
	}
	items, subtotal, vatRate, vatAmount, grandTotal, err := computeOfferTotals(in.Items, in.VatRate)
	if err != nil {
		return nil, err
	}

	offerNo, err := s.generateOfferNo(ctx, orgID)
	if err != nil {
		return nil, err
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	// pgtype.UUID zero-value (Valid=false) NULL'a karşılık gelir; UserID
	// boşsa ya da parse edilemezse createdBy sessizce NULL kalır.
	var createdBy pgtype.UUID
	if in.UserID != "" {
		if uid, err := repository.StringToUUID(in.UserID); err == nil {
			createdBy = uid
		}
	}

	offerRow, err := txq.CreateOffer(ctx, sqlc.CreateOfferParams{
		OrganizationID: orgID,
		OfferNo:        offerNo,
		Status:         domain.OfferStatusTaslak,
		CreatedBy:      createdBy,
	})
	if err != nil {
		return nil, err
	}

	custID, customer, err := resolveCustomerSnapshot(ctx, txq, orgID, in.CustomerID)
	if err != nil {
		return nil, err
	}
	customerName, customerPhone, customerEmail, customerAddress := in.CustomerName, in.CustomerPhone, in.CustomerEmail, in.CustomerAddress
	if custID.Valid {
		customerName, customerPhone, customerEmail, customerAddress = customer.Name, customer.Phone, customer.Email, customer.Address
	}
	customerName = strings.TrimSpace(customerName)
	if customerName == "" {
		return nil, errors.New("müşteri adı zorunludur")
	}

	revRow, err := txq.CreateOfferRevision(ctx, sqlc.CreateOfferRevisionParams{
		OrganizationID:  orgID,
		OfferID:         offerRow.ID,
		RevisionNo:      0,
		CustomerID:      custID,
		CustomerName:    customerName,
		CustomerPhone:   strings.TrimSpace(customerPhone),
		CustomerEmail:   strings.TrimSpace(customerEmail),
		CustomerAddress: strings.TrimSpace(customerAddress),
		ValidUntil:      repository.TimePtrToDate(in.ValidUntil),
		Subtotal:        repository.Float64ToNumeric(subtotal),
		DiscountType:    domain.DiscountNone,
		DiscountValue:   repository.Float64ToNumeric(0),
		DiscountAmount:  repository.Float64ToNumeric(0),
		VatRate:         repository.Float64ToNumeric(vatRate),
		VatAmount:       repository.Float64ToNumeric(vatAmount),
		GrandTotal:      repository.Float64ToNumeric(grandTotal),
		Currency:        "TRY",
		Notes:           strings.TrimSpace(in.Notes),
		Status:          domain.OfferStatusTaslak,
		CreatedBy:       createdBy,
	})
	if err != nil {
		return nil, err
	}

	domainItems, err := insertRevisionItems(ctx, txq, revRow.ID, orgID, items)
	if err != nil {
		return nil, err
	}

	if err := txq.SetOfferCurrentRevision(ctx, sqlc.SetOfferCurrentRevisionParams{
		ID:                offerRow.ID,
		CurrentRevisionID: revRow.ID,
		Status:            domain.OfferStatusTaslak,
	}); err != nil {
		return nil, err
	}

	if err := logOfferEvent(ctx, txq, orgID, offerRow.ID, revRow.ID, domain.EventOfferCreated, createdBy, nil, "", ""); err != nil {
		return nil, err
	}

	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}

	offerRow.CurrentRevisionID = revRow.ID
	base := repository.ToDomainOfferBase(offerRow)
	rev := repository.ToDomainOfferRevision(revRow)
	offer := repository.MergeOfferRevision(base, rev, domainItems)
	return &offer, nil
}

func (s *OfferService) generateOfferNo(ctx context.Context, orgID pgtype.UUID) (string, error) {
	year := time.Now().Year()
	seq, err := s.q.NextOfferSeq(ctx, sqlc.NextOfferSeqParams{OrganizationID: orgID, Year: int32(year)})
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("TKF-%d-%04d", year, seq), nil
}

type OfferListResult struct {
	Offers []domain.Offer
	Total  int64
}

func (s *OfferService) List(ctx context.Context, organizationID string, isPassive bool, page, limit int) (*OfferListResult, error) {
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	if page <= 0 {
		page = 1
	}
	rows, err := s.q.ListOffers(ctx, sqlc.ListOffersParams{
		OrganizationID: orgID,
		IsPassive:      isPassive,
		Limit:          int32(limit),
		Offset:         int32((page - 1) * limit),
	})
	if err != nil {
		return nil, err
	}
	total, err := s.q.CountOffers(ctx, sqlc.CountOffersParams{OrganizationID: orgID, IsPassive: isPassive})
	if err != nil {
		return nil, err
	}
	offers := make([]domain.Offer, len(rows))
	for i, r := range rows {
		offers[i] = repository.ToDomainOfferListItem(r)
	}
	return &OfferListResult{Offers: offers, Total: total}, nil
}

func (s *OfferService) Get(ctx context.Context, id, organizationID string) (*domain.Offer, error) {
	uid, err := repository.StringToUUID(id)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	offerRow, err := s.q.GetOfferByID(ctx, sqlc.GetOfferByIDParams{ID: uid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	return s.loadOfferWithCurrentRevision(ctx, offerRow, orgID)
}

// loadOfferWithCurrentRevision, offerRow'un current_revision_id'sini okuyup
// birleştirilmiş ("düz") görünümü üretir.
func (s *OfferService) loadOfferWithCurrentRevision(ctx context.Context, offerRow sqlc.Offer, orgID pgtype.UUID) (*domain.Offer, error) {
	revRow, err := s.q.GetOfferRevisionByID(ctx, sqlc.GetOfferRevisionByIDParams{ID: offerRow.CurrentRevisionID, OrganizationID: orgID})
	if err != nil {
		return nil, err
	}
	itemRows, err := s.q.ListOfferRevisionItems(ctx, revRow.ID)
	if err != nil {
		return nil, err
	}
	items := make([]domain.OfferItem, len(itemRows))
	for i, r := range itemRows {
		items[i] = repository.ToDomainOfferRevisionItem(r)
	}
	base := repository.ToDomainOfferBase(offerRow)
	rev := repository.ToDomainOfferRevision(revRow)
	offer := repository.MergeOfferRevision(base, rev, items)
	return &offer, nil
}

var ErrOfferNotEditable = errors.New("yalnızca taslak durumundaki teklifler düzenlenebilir")

type UpdateOfferInput struct {
	CustomerID      *string
	CustomerName    string
	CustomerPhone   string
	CustomerEmail   string
	CustomerAddress string
	ValidUntil      *time.Time
	Notes           string
	VatRate         *float64
	Items           []OfferItemInput
	UserID          string
}

// Update, yalnızca "taslak" durumundaki (henüz gönderilmemiş ya da yeni
// "Revize Et" ile açılmış) mevcut revizyonu YERİNDE günceller -- bu YENİ
// bir revizyon SAYMAZ, revision_no değişmez. Gönderilmiş/kabul edilmiş bir
// teklif için Revise() kullanılmalıdır.
func (s *OfferService) Update(ctx context.Context, id, organizationID string, in UpdateOfferInput) (*domain.Offer, error) {
	uid, err := repository.StringToUUID(id)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}

	offerRow, err := s.q.GetOfferByID(ctx, sqlc.GetOfferByIDParams{ID: uid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	if offerRow.Status != domain.OfferStatusTaslak {
		return nil, ErrOfferNotEditable
	}

	if len(in.Items) == 0 {
		return nil, errors.New("en az bir kalem girilmelidir")
	}
	items, subtotal, vatRate, vatAmount, grandTotal, err := computeOfferTotals(in.Items, in.VatRate)
	if err != nil {
		return nil, err
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	custID, customer, err := resolveCustomerSnapshot(ctx, txq, orgID, in.CustomerID)
	if err != nil {
		return nil, err
	}
	customerName, customerPhone, customerEmail, customerAddress := in.CustomerName, in.CustomerPhone, in.CustomerEmail, in.CustomerAddress
	if custID.Valid {
		customerName, customerPhone, customerEmail, customerAddress = customer.Name, customer.Phone, customer.Email, customer.Address
	}
	customerName = strings.TrimSpace(customerName)
	if customerName == "" {
		return nil, errors.New("müşteri adı zorunludur")
	}

	updatedRev, err := txq.UpdateOfferRevision(ctx, sqlc.UpdateOfferRevisionParams{
		ID:              offerRow.CurrentRevisionID,
		OrganizationID:  orgID,
		CustomerID:      custID,
		CustomerName:    customerName,
		CustomerPhone:   strings.TrimSpace(customerPhone),
		CustomerEmail:   strings.TrimSpace(customerEmail),
		CustomerAddress: strings.TrimSpace(customerAddress),
		ValidUntil:      repository.TimePtrToDate(in.ValidUntil),
		Subtotal:        repository.Float64ToNumeric(subtotal),
		VatRate:         repository.Float64ToNumeric(vatRate),
		VatAmount:       repository.Float64ToNumeric(vatAmount),
		GrandTotal:      repository.Float64ToNumeric(grandTotal),
		Notes:           strings.TrimSpace(in.Notes),
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			// status='taslak' koşulu WHERE'de de var -- ilk kontrolden
			// sonra bir yarış durumuyla değişmiş olabilir.
			return nil, ErrOfferNotEditable
		}
		return nil, err
	}

	if err := txq.DeleteOfferRevisionItems(ctx, offerRow.CurrentRevisionID); err != nil {
		return nil, err
	}
	domainItems, err := insertRevisionItems(ctx, txq, offerRow.CurrentRevisionID, orgID, items)
	if err != nil {
		return nil, err
	}

	var actorID pgtype.UUID
	if in.UserID != "" {
		if u, err := repository.StringToUUID(in.UserID); err == nil {
			actorID = u
		}
	}
	if err := logOfferEvent(ctx, txq, orgID, offerRow.ID, offerRow.CurrentRevisionID, domain.EventOfferUpdated, actorID, nil, "", ""); err != nil {
		return nil, err
	}

	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}

	base := repository.ToDomainOfferBase(offerRow)
	rev := repository.ToDomainOfferRevision(updatedRev)
	offer := repository.MergeOfferRevision(base, rev, domainItems)
	return &offer, nil
}

var ErrOfferLocked = errors.New("kabul edilmiş teklif/revizyon durumu değiştirilemez")

// UpdateStatus, personelin (dashboard'daki durum seçiciyle) teklifin
// GÜNCEL revizyonunun durumunu doğrudan değiştirmesini sağlar --
// müşterinin public paylaşım linkinden verdiği karar için bkz.
// RespondByShareLinkToken (o yol customer_accepted/customer_rejected
// olaylarını üretir, bu yol ise revision_sent/offer_updated üretir).
// Durum "taslak"tan "gönderildi"ye geçtiğinde -- ister burada doğrudan
// isterse SendOfferEmail üzerinden -- teklifin ÖNCEKİ revizyonlarına ait
// hâlâ aktif olan paylaşım bağlantıları otomatik iptal edilir (bkz. dosya
// başı Faz 4 notu): "yeni revizyon müşteriye gönderildiğinde önceki
// revizyona ait aktif linkler iptal edilir".
//
// Revise/RespondByShareLinkToken ile AYNI advisory lock'u alır ve teklifi
// kilit altında TAZE okur. Kilitsiz okumak, bu metodu senkronize edilmemiş
// tek yazar yapardı ve iki ciddi soruna yol açardı: (1) müşterinin tam o
// sırada commit ettiği kabulü sessizce ezip ErrOfferLocked güvencesini
// delmek, (2) eşzamanlı bir Revise'dan sonra current_revision_id'yi GERİYE
// alıp eski bir paylaşım linkini yeniden karar verilebilir hale getirmek.
func (s *OfferService) UpdateStatus(ctx context.Context, id, organizationID, status, userID string) (*domain.Offer, error) {
	if !domain.ValidOfferStatus(status) {
		return nil, errors.New("geçersiz durum")
	}
	uid, err := repository.StringToUUID(id)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}

	var actorID pgtype.UUID
	if userID != "" {
		if u, err := repository.StringToUUID(userID); err == nil {
			actorID = u
		}
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	if _, err := tx.Exec(ctx, "SELECT pg_advisory_xact_lock(hashtext($1))", uid.String()); err != nil {
		return nil, err
	}

	offerRow, err := txq.GetOfferByID(ctx, sqlc.GetOfferByIDParams{ID: uid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	// Kabul edilmiş bir teklifin durumu (dolayısıyla revizyonu) bir daha
	// değiştirilemez -- "kabul edilen revizyon sonradan overwrite
	// edilmez" kuralının durum boyutu.
	if offerRow.Status == domain.OfferStatusKabulEdildi {
		return nil, ErrOfferLocked
	}
	previousStatus := offerRow.Status

	updatedRev, err := txq.UpdateOfferRevisionStatus(ctx, sqlc.UpdateOfferRevisionStatusParams{
		ID: offerRow.CurrentRevisionID, OrganizationID: orgID, Status: status,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	if err := txq.SetOfferCurrentRevision(ctx, sqlc.SetOfferCurrentRevisionParams{
		ID: offerRow.ID, CurrentRevisionID: offerRow.CurrentRevisionID, Status: status,
	}); err != nil {
		return nil, err
	}

	eventType := domain.EventOfferUpdated
	justSent := status == domain.OfferStatusGonderildi && previousStatus != domain.OfferStatusGonderildi
	if justSent {
		eventType = domain.EventRevisionSent
		revokedLinks, err := txq.RevokeShareLinksForOtherRevisions(ctx, sqlc.RevokeShareLinksForOtherRevisionsParams{
			OfferID: offerRow.ID, RevisionID: offerRow.CurrentRevisionID,
		})
		if err != nil {
			return nil, err
		}
		for _, link := range revokedLinks {
			if err := logOfferEvent(ctx, txq, orgID, offerRow.ID, link.RevisionID, domain.EventShareLinkRevoked, actorID,
				map[string]any{"reason": "revision_sent", "link_id": link.ID.String()}, "", ""); err != nil {
				return nil, err
			}
		}
	}
	if err := logOfferEvent(ctx, txq, orgID, offerRow.ID, offerRow.CurrentRevisionID, eventType, actorID, nil, "", ""); err != nil {
		return nil, err
	}

	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}

	itemRows, err := s.q.ListOfferRevisionItems(ctx, offerRow.CurrentRevisionID)
	if err != nil {
		return nil, err
	}
	items := make([]domain.OfferItem, len(itemRows))
	for i, r := range itemRows {
		items[i] = repository.ToDomainOfferRevisionItem(r)
	}
	offerRow.Status = status
	base := repository.ToDomainOfferBase(offerRow)
	rev := repository.ToDomainOfferRevision(updatedRev)
	offer := repository.MergeOfferRevision(base, rev, items)
	return &offer, nil
}

// TogglePassive, teklifi arşivler/arşivden çıkarır. Yalnızca arşive
// GİRİŞ (is_passive false -> true) bir "offer_cancelled" olayı üretir --
// arşivden çıkarmanın gerekli kabul edilen 12 olay tipi arasında bir
// karşılığı yok, bu yüzden loglanmaz.
func (s *OfferService) TogglePassive(ctx context.Context, id, organizationID, userID string) error {
	uid, err := repository.StringToUUID(id)
	if err != nil {
		return domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return domain.ErrNotFound
	}
	row, err := s.q.GetOfferByID(ctx, sqlc.GetOfferByIDParams{ID: uid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return domain.ErrNotFound
		}
		return err
	}
	newPassive := !row.IsPassive

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	if err := txq.SetOfferPassive(ctx, sqlc.SetOfferPassiveParams{ID: uid, OrganizationID: orgID, IsPassive: newPassive}); err != nil {
		return err
	}
	if newPassive {
		var actorID pgtype.UUID
		if userID != "" {
			if u, err := repository.StringToUUID(userID); err == nil {
				actorID = u
			}
		}
		if err := logOfferEvent(ctx, txq, orgID, uid, row.CurrentRevisionID, domain.EventOfferCancelled, actorID, nil, "", ""); err != nil {
			return err
		}
	}
	return tx.Commit(ctx)
}

var ErrOfferNotRevisable = errors.New("bu teklif için revizyon oluşturulamaz")

// Revise, mevcut (current) revizyonun içeriğini başlangıç verisi olarak
// kopyalayıp yeni, "taslak" durumunda bir revizyon açar ve teklifin
// current_revision_id'sini ona taşır. Yalnızca "gönderildi" veya
// "reddedildi" durumundaki bir revizyon için çağrılabilir -- taslak zaten
// Update() ile düzenlenir, kabul edilmiş teklif kilitlidir. Aynı teklif
// için eşzamanlı çağrılar bir advisory lock ile serileştirilir, böylece
// iki istek asla aynı revision_no'yu üretemez.
func (s *OfferService) Revise(ctx context.Context, id, organizationID, userID string) (*domain.Offer, error) {
	uid, err := repository.StringToUUID(id)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	// hashtext(id), teklif UUID'sini 32 bitlik bir tam sayıya indirger;
	// nadir hash çakışmaları yalnızca FARKLI tekliflerin gereksiz yere
	// birbirini beklemesine yol açar, doğruluğu etkilemez. Kilit,
	// transaction commit/rollback olduğunda otomatik serbest kalır.
	// Anahtar, çağıranın gönderdiği ham metin DEĞİL, ayrıştırılmış UUID'nin
	// kanonik gösterimidir -- aksi halde büyük harfli bir UUID ile gelen
	// istek, aynı teklif için farklı bir kilit anahtarı üretip
	// RespondByShareLinkToken ile karşılıklı dışlamayı sessizce kaybederdi.
	if _, err := tx.Exec(ctx, "SELECT pg_advisory_xact_lock(hashtext($1))", uid.String()); err != nil {
		return nil, err
	}

	offerRow, err := txq.GetOfferByID(ctx, sqlc.GetOfferByIDParams{ID: uid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	if offerRow.Status == domain.OfferStatusTaslak || offerRow.Status == domain.OfferStatusKabulEdildi {
		return nil, ErrOfferNotRevisable
	}

	currentRev, err := txq.GetOfferRevisionByID(ctx, sqlc.GetOfferRevisionByIDParams{ID: offerRow.CurrentRevisionID, OrganizationID: orgID})
	if err != nil {
		return nil, err
	}
	currentItems, err := txq.ListOfferRevisionItems(ctx, currentRev.ID)
	if err != nil {
		return nil, err
	}

	nextNo, err := txq.GetLatestRevisionNo(ctx, offerRow.ID)
	if err != nil {
		return nil, err
	}
	nextNo++

	var createdBy pgtype.UUID
	if userID != "" {
		if u, err := repository.StringToUUID(userID); err == nil {
			createdBy = u
		}
	}

	newRev, err := txq.CreateOfferRevision(ctx, sqlc.CreateOfferRevisionParams{
		OrganizationID:  orgID,
		OfferID:         offerRow.ID,
		RevisionNo:      nextNo,
		CustomerID:      currentRev.CustomerID,
		CustomerName:    currentRev.CustomerName,
		CustomerPhone:   currentRev.CustomerPhone,
		CustomerEmail:   currentRev.CustomerEmail,
		CustomerAddress: currentRev.CustomerAddress,
		ValidUntil:      currentRev.ValidUntil,
		Subtotal:        currentRev.Subtotal,
		DiscountType:    currentRev.DiscountType,
		DiscountValue:   currentRev.DiscountValue,
		DiscountAmount:  currentRev.DiscountAmount,
		VatRate:         currentRev.VatRate,
		VatAmount:       currentRev.VatAmount,
		GrandTotal:      currentRev.GrandTotal,
		Currency:        currentRev.Currency,
		Notes:           currentRev.Notes,
		Status:          domain.OfferStatusTaslak,
		CreatedBy:       createdBy,
	})
	if err != nil {
		return nil, err
	}

	if err := cloneRevisionItems(ctx, txq, newRev.ID, currentItems); err != nil {
		return nil, err
	}

	if err := txq.SetOfferCurrentRevision(ctx, sqlc.SetOfferCurrentRevisionParams{
		ID:                offerRow.ID,
		CurrentRevisionID: newRev.ID,
		Status:            domain.OfferStatusTaslak,
	}); err != nil {
		return nil, err
	}

	if err := logOfferEvent(ctx, txq, orgID, offerRow.ID, newRev.ID, domain.EventRevisionCreated, createdBy, nil, "", ""); err != nil {
		return nil, err
	}

	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}

	itemRows, err := s.q.ListOfferRevisionItems(ctx, newRev.ID)
	if err != nil {
		return nil, err
	}
	items := make([]domain.OfferItem, len(itemRows))
	for i, r := range itemRows {
		items[i] = repository.ToDomainOfferRevisionItem(r)
	}
	offerRow.CurrentRevisionID = newRev.ID
	offerRow.Status = domain.OfferStatusTaslak
	base := repository.ToDomainOfferBase(offerRow)
	rev := repository.ToDomainOfferRevision(newRev)
	offer := repository.MergeOfferRevision(base, rev, items)
	return &offer, nil
}

// ListRevisions, bir teklifin tüm revizyonlarını (en yeni önce) döner.
// Sorgu zaten organization_id ile filtrelendiğinden, başka bir firmanın
// offer_id'si için boş liste döner -- veri sızmaz.
func (s *OfferService) ListRevisions(ctx context.Context, offerID, organizationID string) ([]domain.OfferRevision, error) {
	uid, err := repository.StringToUUID(offerID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	rows, err := s.q.ListOfferRevisions(ctx, sqlc.ListOfferRevisionsParams{OfferID: uid, OrganizationID: orgID})
	if err != nil {
		return nil, err
	}
	out := make([]domain.OfferRevision, len(rows))
	for i, r := range rows {
		out[i] = repository.ToDomainOfferRevision(r)
	}
	return out, nil
}

// GetRevision, geçmiş (veya mevcut) bir revizyonun tam, salt-okunur
// içeriğini döner -- eski revizyonlar bu yolla görüntülenir ama hiçbir
// zaman bu fonksiyon üzerinden değiştirilemez (böyle bir uç yok).
func (s *OfferService) GetRevision(ctx context.Context, revisionID, organizationID string) (*domain.OfferRevision, error) {
	rid, err := repository.StringToUUID(revisionID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	row, err := s.q.GetOfferRevisionByID(ctx, sqlc.GetOfferRevisionByIDParams{ID: rid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	itemRows, err := s.q.ListOfferRevisionItems(ctx, rid)
	if err != nil {
		return nil, err
	}
	rev := repository.ToDomainOfferRevision(row)
	rev.Items = make([]domain.OfferItem, len(itemRows))
	for i, r := range itemRows {
		rev.Items[i] = repository.ToDomainOfferRevisionItem(r)
	}
	return &rev, nil
}

var (
	ErrShareLinkRevoked    = errors.New("bu paylaşım bağlantısı iptal edilmiş")
	ErrShareLinkExpired    = errors.New("bu paylaşım bağlantısının süresi dolmuş")
	ErrOfferSuperseded     = errors.New("bu teklif için yeni bir revizyon oluşturuldu, bu bağlantı üzerinden artık karar verilemez")
	ErrOfferNotRespondable = errors.New("bu teklif için onay/red işlemi yapılamaz")
)

// CreateShareLink, teklifin O ANKİ (current) revizyonuna bağlı yeni bir
// paylaşım bağlantısı oluşturur. Bir bağlantı oluşturulduğu andaki
// revizyona sabitlenir -- teklif sonradan revize edilse bile bu bağlantı
// hep AYNI (eski) revizyonu göstermeye devam eder (bkz. ResolveActiveShareLink).
func (s *OfferService) CreateShareLink(ctx context.Context, offerID, organizationID, userID string, expiresAt *time.Time) (*domain.OfferShareLink, error) {
	uid, err := repository.StringToUUID(offerID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	offerRow, err := txq.GetOfferByID(ctx, sqlc.GetOfferByIDParams{ID: uid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}

	var createdBy pgtype.UUID
	if userID != "" {
		if u, err := repository.StringToUUID(userID); err == nil {
			createdBy = u
		}
	}

	link, err := txq.CreateShareLink(ctx, sqlc.CreateShareLinkParams{
		OrganizationID: orgID,
		OfferID:        offerRow.ID,
		RevisionID:     offerRow.CurrentRevisionID,
		CreatedBy:      createdBy,
		ExpiresAt:      repository.TimePtrToTimestamptz(expiresAt),
	})
	if err != nil {
		return nil, err
	}

	if err := logOfferEvent(ctx, txq, orgID, offerRow.ID, link.RevisionID, domain.EventShareLinkCreated, createdBy, nil, "", ""); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	dl := repository.ToDomainOfferShareLink(link)
	return &dl, nil
}

// ListShareLinks, bir teklifin TÜM bağlantılarını (aktif/iptal edilmiş/
// süresi dolmuş) en yeniden eskiye döner -- teklif detayında "aktif link"
// ile geçmiş bağlantıların birlikte gösterilebilmesi için.
func (s *OfferService) ListShareLinks(ctx context.Context, offerID, organizationID string) ([]domain.OfferShareLink, error) {
	uid, err := repository.StringToUUID(offerID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	rows, err := s.q.ListShareLinksByOffer(ctx, sqlc.ListShareLinksByOfferParams{OfferID: uid, OrganizationID: orgID})
	if err != nil {
		return nil, err
	}
	out := make([]domain.OfferShareLink, len(rows))
	for i, r := range rows {
		out[i] = repository.ToDomainOfferShareLink(r)
	}
	return out, nil
}

// RevokeShareLink, bir bağlantıyı manuel olarak iptal eder -- iptal
// edilmiş bir bağlantı üzerinden ne teklif görüntülenebilir ne de karar
// verilebilir (bkz. resolveActiveShareLink).
func (s *OfferService) RevokeShareLink(ctx context.Context, linkID, organizationID, userID string) error {
	lid, err := repository.StringToUUID(linkID)
	if err != nil {
		return domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return domain.ErrNotFound
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	link, err := txq.RevokeShareLink(ctx, sqlc.RevokeShareLinkParams{ID: lid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			// id yok, başka org'a ait ya da zaten iptal edilmiş -- hangisi
			// olduğunu ayırt etmeye gerek yok, hepsi aynı sonucu hak eder.
			return domain.ErrNotFound
		}
		return err
	}

	var actorID pgtype.UUID
	if userID != "" {
		if u, err := repository.StringToUUID(userID); err == nil {
			actorID = u
		}
	}
	if err := logOfferEvent(ctx, txq, orgID, link.OfferID, link.RevisionID, domain.EventShareLinkRevoked, actorID,
		map[string]any{"reason": "manual"}, "", ""); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// resolveActiveShareLink, bir token'ı, HÂLÂ AKTİF (iptal edilmemiş, süresi
// dolmamış) bir offer_share_links kaydına çözer. Public uçların (Get/
// Respond) tek giriş noktasıdır -- güvenlik sınırı organization_id değil,
// tahmin edilemez token'ın kendisidir.
func (s *OfferService) resolveActiveShareLink(ctx context.Context, q *sqlc.Queries, token string) (sqlc.OfferShareLink, error) {
	tid, err := repository.StringToUUID(token)
	if err != nil {
		return sqlc.OfferShareLink{}, domain.ErrNotFound
	}
	link, err := q.GetShareLinkByToken(ctx, tid)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return sqlc.OfferShareLink{}, domain.ErrNotFound
		}
		return sqlc.OfferShareLink{}, err
	}
	if link.RevokedAt.Valid {
		return sqlc.OfferShareLink{}, ErrShareLinkRevoked
	}
	if link.ExpiresAt.Valid && time.Now().After(link.ExpiresAt.Time) {
		return sqlc.OfferShareLink{}, ErrShareLinkExpired
	}
	return link, nil
}

// GetByShareLinkToken, müşterinin auth gerektirmeyen paylaşım linkinden
// teklifi görüntülemesi için kullanılır. Bağlantının bağlı olduğu
// revizyonu gösterir -- bu, teklifin O ANKİ revizyonundan FARKLI olabilir
// (personel yeni bir revizyon açmış ama henüz bu eski linki iptal
// etmemişse); "eski revizyon görüntülenebilir, ancak artık karar
// verilemez" kuralının görüntüleme yarısı budur (karar yarısı için bkz.
// RespondByShareLinkToken). Her başarılı çağrı bir customer_viewed olayı
// üretir; bu kayıt best-effort'tur (bir insert hatası müşterinin teklifi
// görmesini engellemez).
// Dönen ikinci değer (canRespond), müşterinin bu bağlantı üzerinden
// kabul/red YAPABİLİR olup olmadığıdır: bağlı revizyon hâlâ teklifin
// güncel revizyonu olmalı VE "gönderildi" durumunda bulunmalıdır --
// RespondByShareLinkToken'ın uyguladığı kuralların aynısı. Frontend
// kabul/red butonlarını buna göre gösterir; aksi halde müşteriye asla
// başarılı olamayacak bir buton gösterilmiş olurdu (karar zaten
// verilmişse ya da yeni bir revizyon gönderilmişse).
func (s *OfferService) GetByShareLinkToken(ctx context.Context, token, ip, userAgent string) (*domain.Offer, bool, error) {
	link, err := s.resolveActiveShareLink(ctx, s.q, token)
	if err != nil {
		return nil, false, err
	}
	offerRow, err := s.q.GetOfferByID(ctx, sqlc.GetOfferByIDParams{ID: link.OfferID, OrganizationID: link.OrganizationID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, false, domain.ErrNotFound
		}
		return nil, false, err
	}
	revRow, err := s.q.GetOfferRevisionByID(ctx, sqlc.GetOfferRevisionByIDParams{ID: link.RevisionID, OrganizationID: link.OrganizationID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, false, domain.ErrNotFound
		}
		return nil, false, err
	}
	canRespond := offerRow.CurrentRevisionID.String() == link.RevisionID.String() &&
		revRow.Status == domain.OfferStatusGonderildi
	itemRows, err := s.q.ListOfferRevisionItems(ctx, revRow.ID)
	if err != nil {
		return nil, false, err
	}
	items := make([]domain.OfferItem, len(itemRows))
	for i, r := range itemRows {
		items[i] = repository.ToDomainOfferRevisionItem(r)
	}
	base := repository.ToDomainOfferBase(offerRow)
	// Müşteri, teklifin o anki durumunu değil, KENDİSİNE GÖNDERİLEN
	// revizyonun (donmuş) durumunu görmeli -- eski bir linkte teklif
	// çoktan yeni bir taslak revizyona geçmiş olsa bile.
	base.Status = revRow.Status
	rev := repository.ToDomainOfferRevision(revRow)
	offer := repository.MergeOfferRevision(base, rev, items)

	if err := logOfferEvent(ctx, s.q, link.OrganizationID, link.OfferID, link.RevisionID, domain.EventCustomerViewed,
		pgtype.UUID{}, nil, ip, userAgent); err != nil {
		log.Printf("customer_viewed olayı yazılamadı: %v", err)
	}
	return &offer, canRespond, nil
}

// RespondByShareLinkToken, müşterinin paylaşım linkinden teklifi kabul/red
// etmesini sağlar. Karar yalnızca linkin bağlı olduğu revizyon HÂLÂ
// teklifin GÜNCEL revizyonuysa VE o revizyon "gönderildi" durumundaysa
// kabul edilir.
//
// Yarış durumu savunması: personelin tam bu sırada yeni bir revizyon
// oluşturup göndermesiyle çakışmayı önlemek için, Revise() ile AYNI
// advisory lock (offer_id anahtarlı) kullanılır. Böylece iki senaryo da
// güvenlidir:
//   - Müşteri kilidi önce alırsa: karar işlenir, sonra Revise() (kilidi
//     bekleyen) teklifin artık "taslak" olmadığını değil, tam tersine artık
//     "kabul edildi"/"reddedildi" olduğunu görüp ErrOfferNotRevisable ile
//     reddedilir.
//   - Personel kilidi önce alırsa: yeni revizyon oluşur ve current_revision_id
//     değişir; müşterinin isteği (kilidi bekleyen) fresh current_revision_id'yi
//     okur, artık eski revizyona eşit olmadığını görüp ErrOfferSuperseded
//     ile reddedilir -- link henüz (send adımı tamamlanmadıysa) iptal
//     edilmemiş olsa bile.
//
// Aynı link üzerinden İKİNCİ bir kabul/red isteği de doğal olarak korunur:
// ilk istek revizyonun durumunu "gönderildi"den çıkardığı için, ikinci
// istek revRow.Status kontrolünde ErrOfferNotRespondable ile temiz
// biçimde reddedilir (ayrı bir idempotency-key mekanizmasına gerek yok).
func (s *OfferService) RespondByShareLinkToken(ctx context.Context, token, decision, ip, userAgent string) (*domain.Offer, error) {
	if decision != domain.OfferStatusKabulEdildi && decision != domain.OfferStatusReddedildi {
		return nil, errors.New("geçersiz karar")
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	// İlk çözüm yalnızca kilit anahtarını (offer_id) öğrenmek içindir.
	link, err := s.resolveActiveShareLink(ctx, txq, token)
	if err != nil {
		return nil, err
	}

	if _, err := tx.Exec(ctx, "SELECT pg_advisory_xact_lock(hashtext($1))", link.OfferID.String()); err != nil {
		return nil, err
	}

	// Kilidi beklerken personel bu bağlantıyı iptal etmiş olabilir; kararın
	// dayandığı HER ŞEY kilit altında taze okunmalı (READ COMMITTED'da her
	// sorgu yeni bir snapshot görür), yoksa iptal, uçuşta olan bir kabul
	// isteğiyle yarışı kaybederdi.
	link, err = s.resolveActiveShareLink(ctx, txq, token)
	if err != nil {
		return nil, err
	}

	offerRow, err := txq.GetOfferByID(ctx, sqlc.GetOfferByIDParams{ID: link.OfferID, OrganizationID: link.OrganizationID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	if offerRow.CurrentRevisionID.String() != link.RevisionID.String() {
		return nil, ErrOfferSuperseded
	}

	revRow, err := txq.GetOfferRevisionByID(ctx, sqlc.GetOfferRevisionByIDParams{ID: link.RevisionID, OrganizationID: link.OrganizationID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	if revRow.Status != domain.OfferStatusGonderildi {
		return nil, ErrOfferNotRespondable
	}

	updatedRev, err := txq.UpdateOfferRevisionStatus(ctx, sqlc.UpdateOfferRevisionStatusParams{
		ID: revRow.ID, OrganizationID: link.OrganizationID, Status: decision,
	})
	if err != nil {
		return nil, err
	}
	if err := txq.SetOfferCurrentRevision(ctx, sqlc.SetOfferCurrentRevisionParams{
		ID: offerRow.ID, CurrentRevisionID: revRow.ID, Status: decision,
	}); err != nil {
		return nil, err
	}

	eventType := domain.EventCustomerAccepted
	if decision == domain.OfferStatusReddedildi {
		eventType = domain.EventCustomerRejected
	}
	if err := logOfferEvent(ctx, txq, link.OrganizationID, link.OfferID, link.RevisionID, eventType, pgtype.UUID{}, nil, ip, userAgent); err != nil {
		return nil, err
	}

	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}

	itemRows, err := s.q.ListOfferRevisionItems(ctx, revRow.ID)
	if err != nil {
		return nil, err
	}
	items := make([]domain.OfferItem, len(itemRows))
	for i, r := range itemRows {
		items[i] = repository.ToDomainOfferRevisionItem(r)
	}
	offerRow.Status = decision
	base := repository.ToDomainOfferBase(offerRow)
	rev := repository.ToDomainOfferRevision(updatedRev)
	offer := repository.MergeOfferRevision(base, rev, items)
	return &offer, nil
}

// ListEvents, bir teklifin tüm denetim olaylarını (en eskiden en yeniye,
// zaman çizelgesi sırasında) döner.
func (s *OfferService) ListEvents(ctx context.Context, offerID, organizationID string) ([]domain.OfferEvent, error) {
	uid, err := repository.StringToUUID(offerID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	rows, err := s.q.ListOfferEvents(ctx, sqlc.ListOfferEventsParams{OfferID: uid, OrganizationID: orgID})
	if err != nil {
		return nil, err
	}
	out := make([]domain.OfferEvent, len(rows))
	for i, r := range rows {
		out[i] = repository.ToDomainOfferEvent(r)
	}
	return out, nil
}

// ListEmailLogs, bir teklifle ilgili gönderilmiş (başarılı/başarısız) tüm
// e-posta kayıtlarını en yeniden eskiye döner.
func (s *OfferService) ListEmailLogs(ctx context.Context, offerID, organizationID string) ([]domain.OfferEmailLog, error) {
	uid, err := repository.StringToUUID(offerID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	rows, err := s.q.ListEmailLogsByOffer(ctx, sqlc.ListEmailLogsByOfferParams{OfferID: uid, OrganizationID: orgID})
	if err != nil {
		return nil, err
	}
	out := make([]domain.OfferEmailLog, len(rows))
	for i, r := range rows {
		out[i] = repository.ToDomainOfferEmailLog(r)
	}
	return out, nil
}

// getOrCreateActiveShareLink, teklifin belirtilen revizyonu için hâlâ
// aktif bir bağlantı varsa onu döner, yoksa (süresiz) yeni bir tane
// oluşturur -- SendOfferEmail'in "e-mail her zaman belirli revizyonun
// paylaşım linkini içersin" kuralını, personel önceden manuel bir link
// oluşturmamış olsa bile garanti etmesi için.
func (s *OfferService) getOrCreateActiveShareLink(ctx context.Context, offerID, organizationID, revisionID, userID string) (*domain.OfferShareLink, error) {
	links, err := s.ListShareLinks(ctx, offerID, organizationID)
	if err != nil {
		return nil, err
	}
	now := time.Now()
	for _, l := range links {
		if l.RevisionID == revisionID && l.IsActive(now) {
			return &l, nil
		}
	}
	return s.CreateShareLink(ctx, offerID, organizationID, userID, nil)
}

type SendOfferEmailInput struct {
	To      string
	Subject string
	Message string
}

// SendOfferEmail, teklifin güncel revizyonu için (var olan ya da yeni
// oluşturulan) bir paylaşım linkiyle müşteriye mail gönderir. Gönderim
// SONUCU ne olursa olsun (başarılı/başarısız) bir offer_email_logs kaydı
// ve karşılık gelen email_sent/email_failed olayı üretilir. Yalnızca
// gönderim BAŞARILIYSA ve revizyon hâlâ taslaksa durum "gönderildi"ye
// geçirilir (bu da UpdateStatus üzerinden önceki revizyonların aktif
// bağlantılarını iptal eder) -- başarısız gönderimde revizyon taslak
// kalır, böylece personel düzeltip tekrar deneyebilir.
func (s *OfferService) SendOfferEmail(ctx context.Context, offerID, organizationID, userID string, in SendOfferEmailInput) (*domain.Offer, error) {
	offer, err := s.Get(ctx, offerID, organizationID)
	if err != nil {
		return nil, err
	}

	to := in.To
	if to == "" {
		to = offer.CustomerEmail
	}
	if to == "" {
		return nil, errors.New("alıcı e-posta adresi belirtilmedi")
	}
	// offer_email_logs.recipient varchar(255): mail GÖNDERİLDİKTEN sonra
	// log yazımının patlamaması için sınırı baştan uygulayalım. Adresi
	// sessizce kısaltmak yanlış alıcıya göndermek demek olurdu, bu yüzden
	// kısaltmak yerine reddediyoruz.
	if len([]rune(to)) > 255 {
		return nil, errors.New("alıcı e-posta adresi çok uzun")
	}

	link, err := s.getOrCreateActiveShareLink(ctx, offer.ID, organizationID, offer.CurrentRevisionID, userID)
	if err != nil {
		return nil, err
	}

	subject := in.Subject
	if subject == "" {
		subject = "Teklifiniz: " + offer.OfferNo
	}
	subject = truncateRunes(subject, 300) // offer_email_logs.subject varchar(300)
	shareURL := s.frontendURL + "/paylas/" + link.Token
	body := in.Message
	if body == "" {
		body = "Sayın " + offer.CustomerName + ",\n\nTalebiniz üzerine hazırladığımız teklifi aşağıdaki bağlantıdan inceleyebilirsiniz:\n"
	} else {
		body += "\n\n"
	}
	body += shareURL

	settings, err := s.settingsSvc.GetSmtp(ctx, organizationID)
	if err != nil {
		return nil, err
	}
	sendErr := s.SendMailFunc(*settings, mailer.Message{To: to, Subject: subject, Body: body})

	orgID, _ := repository.StringToUUID(organizationID)
	offerUUID, _ := repository.StringToUUID(offer.ID)
	// Log/olay, GERÇEKTE gönderilen linkin bağlı olduğu revizyona yazılır.
	// offer.CurrentRevisionID ile aynı olması beklenir, ama araya eşzamanlı
	// bir "Revize Et" girdiyse ikisi ayrışabilir; müşteriye hangi revizyonun
	// linki gittiyse kayıt onu göstermeli.
	revUUID, _ := repository.StringToUUID(link.RevisionID)
	linkUUID, _ := repository.StringToUUID(link.ID)
	var sentBy pgtype.UUID
	if userID != "" {
		if u, err := repository.StringToUUID(userID); err == nil {
			sentBy = u
		}
	}

	status, errMsg, eventType := domain.EmailLogStatusSent, "", domain.EventEmailSent
	if sendErr != nil {
		status, errMsg, eventType = domain.EmailLogStatusFailed, sendErr.Error(), domain.EventEmailFailed
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	if _, err := txq.CreateEmailLog(ctx, sqlc.CreateEmailLogParams{
		OrganizationID: orgID, OfferID: offerUUID, RevisionID: revUUID, ShareLinkID: linkUUID,
		Recipient: to, Subject: subject, Status: status, ErrorMessage: errMsg, SentBy: sentBy,
	}); err != nil {
		return nil, err
	}
	if err := logOfferEvent(ctx, txq, orgID, offerUUID, revUUID, eventType, sentBy, nil, "", ""); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}

	if sendErr != nil {
		return nil, sendErr
	}
	if offer.Status == domain.OfferStatusTaslak {
		return s.UpdateStatus(ctx, offer.ID, organizationID, domain.OfferStatusGonderildi, userID)
	}
	return offer, nil
}

var ErrOfferAccepted = errors.New("kabul edilmiş teklif silinemez")

// Delete, BYZ'deki kuralı korur: kabul edilmiş bir teklifin tek dayanağı
// olduğu müşteri onayı/alacak kaydı olabileceğinden, "kabul edildi"
// durumundaki teklifler silinemez. offers.status, current revizyonun
// aynası olduğundan ayrıca revizyon fetch etmeye gerek yoktur.
func (s *OfferService) Delete(ctx context.Context, id, organizationID string) error {
	uid, err := repository.StringToUUID(id)
	if err != nil {
		return domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return domain.ErrNotFound
	}
	offerRow, err := s.q.GetOfferByID(ctx, sqlc.GetOfferByIDParams{ID: uid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return domain.ErrNotFound
		}
		return err
	}
	if offerRow.Status == domain.OfferStatusKabulEdildi {
		return ErrOfferAccepted
	}
	return s.q.DeleteOffer(ctx, sqlc.DeleteOfferParams{ID: uid, OrganizationID: orgID})
}

func round2(f float64) float64 {
	return float64(int64(f*100+0.5)) / 100
}
