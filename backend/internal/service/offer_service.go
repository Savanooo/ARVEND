package service

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

type OfferService struct {
	pool *pgxpool.Pool
	q    *sqlc.Queries
}

func NewOfferService(pool *pgxpool.Pool, q *sqlc.Queries) *OfferService {
	return &OfferService{pool: pool, q: q}
}

type OfferItemInput struct {
	ProductID   *string
	ProductName string
	Quantity    float64
	UnitPrice   float64
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
// metin satıra düşürülür.
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
		itemRow, err := txq.CreateOfferRevisionItem(ctx, sqlc.CreateOfferRevisionItemParams{
			RevisionID:    revisionID,
			ProductID:     productID,
			ProductName:   strings.TrimSpace(it.ProductName),
			Quantity:      repository.Float64ToNumeric(it.Quantity),
			UnitPrice:     repository.Float64ToNumeric(it.UnitPrice),
			DiscountType:  domain.DiscountNone,
			DiscountValue: repository.Float64ToNumeric(0),
			LineTotal:     repository.Float64ToNumeric(it.LineTotal),
			SortOrder:     int32(i),
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
func cloneRevisionItems(ctx context.Context, txq *sqlc.Queries, newRevisionID pgtype.UUID, items []sqlc.OfferRevisionItem) error {
	for _, it := range items {
		if _, err := txq.CreateOfferRevisionItem(ctx, sqlc.CreateOfferRevisionItemParams{
			RevisionID:    newRevisionID,
			ProductID:     it.ProductID,
			ProductName:   it.ProductName,
			Quantity:      it.Quantity,
			UnitPrice:     it.UnitPrice,
			DiscountType:  it.DiscountType,
			DiscountValue: it.DiscountValue,
			LineTotal:     it.LineTotal,
			SortOrder:     it.SortOrder,
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

	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}

	base := repository.ToDomainOfferBase(offerRow)
	rev := repository.ToDomainOfferRevision(updatedRev)
	offer := repository.MergeOfferRevision(base, rev, domainItems)
	return &offer, nil
}

var ErrOfferLocked = errors.New("kabul edilmiş teklif/revizyon durumu değiştirilemez")

func (s *OfferService) UpdateStatus(ctx context.Context, id, organizationID, status string) (*domain.Offer, error) {
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
	offerRow, err := s.q.GetOfferByID(ctx, sqlc.GetOfferByIDParams{ID: uid, OrganizationID: orgID})
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

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

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

func (s *OfferService) TogglePassive(ctx context.Context, id, organizationID string) error {
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
	return s.q.SetOfferPassive(ctx, sqlc.SetOfferPassiveParams{ID: uid, OrganizationID: orgID, IsPassive: !row.IsPassive})
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
	if _, err := tx.Exec(ctx, "SELECT pg_advisory_xact_lock(hashtext($1))", id); err != nil {
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

// GetByShareToken, müşterinin auth gerektirmeyen paylaşım linkinden teklifi
// görüntülemesi için kullanılır -- güvenlik sınırı organization_id değil,
// tahmin edilemez token'ın kendisidir (bu yüzden organizationID parametresi
// almaz). Her zaman teklifin O ANKİ (current) revizyonunu gösterir --
// yeni bir revizyon açılırsa müşteri artık eski içeriği görmez.
func (s *OfferService) GetByShareToken(ctx context.Context, token string) (*domain.Offer, error) {
	tid, err := repository.StringToUUID(token)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	offerRow, err := s.q.GetOfferByShareToken(ctx, tid)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	return s.loadOfferWithCurrentRevision(ctx, offerRow, offerRow.OrganizationID)
}

var ErrOfferNotRespondable = errors.New("bu teklif için onay/red işlemi yapılamaz")

// RespondByShareToken, müşterinin paylaşım linkinden teklifi kabul/red
// etmesini sağlar. Yalnızca teklifin O ANKİ revizyonu "gönderildi"
// durumundaysa geçerlidir -- taslak bir revizyon henüz müşteriye
// ulaşmamıştır, kabul/red edilmiş olan zaten karara bağlanmıştır. Karar
// her zaman current_revision_id'ye yazılır: yeni bir revizyon açılıp
// gönderildiyse, eski revizyonun "gönderildi" durumu donmuş kalır ve bir
// daha bu yoldan erişilemez -- müşteri yalnızca EN SON gönderilen
// revizyona karar verebilir.
func (s *OfferService) RespondByShareToken(ctx context.Context, token, decision string) (*domain.Offer, error) {
	if decision != domain.OfferStatusKabulEdildi && decision != domain.OfferStatusReddedildi {
		return nil, errors.New("geçersiz karar")
	}
	tid, err := repository.StringToUUID(token)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	offerRow, err := s.q.GetOfferByShareToken(ctx, tid)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	if offerRow.Status != domain.OfferStatusGonderildi {
		return nil, ErrOfferNotRespondable
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	updatedRev, err := txq.UpdateOfferRevisionStatus(ctx, sqlc.UpdateOfferRevisionStatusParams{
		ID: offerRow.CurrentRevisionID, OrganizationID: offerRow.OrganizationID, Status: decision,
	})
	if err != nil {
		return nil, err
	}
	if err := txq.SetOfferCurrentRevision(ctx, sqlc.SetOfferCurrentRevisionParams{
		ID: offerRow.ID, CurrentRevisionID: offerRow.CurrentRevisionID, Status: decision,
	}); err != nil {
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
	offerRow.Status = decision
	base := repository.ToDomainOfferBase(offerRow)
	rev := repository.ToDomainOfferRevision(updatedRev)
	offer := repository.MergeOfferRevision(base, rev, items)
	return &offer, nil
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
