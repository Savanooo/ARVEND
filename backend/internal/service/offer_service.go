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
	// alınıp teklife anlık görüntü (snapshot) olarak yazılır. Böylece
	// müşteri kartı sonradan değişse/silinse bile bu teklif sabit kalır.
	// Boşsa mevcut serbest-metin davranışı aynen korunur.
	CustomerID      *string
	CustomerName    string
	CustomerPhone   string
	CustomerEmail   string
	CustomerAddress string
	ValidUntil      *time.Time
	Notes           string
	// VatRate nil ise (istekte hiç gönderilmemişse) %20 varsayılır;
	// açıkça 0 gönderilirse 0 olarak KALIR. BYZ'de tam bu noktada
	// "value or 20" deseni yüzünden KDV=0 sessizce 20'ye dönüyordu --
	// burada baştan işaretçi kullanılarak o hata tekrarlanmıyor.
	VatRate        *float64
	Items          []OfferItemInput
	UserID         string
	OrganizationID string
}

type computedOfferItem struct {
	OfferItemInput
	LineTotal float64
}

// computeOfferTotals, Create ve Update arasında paylaşılan hesaplama
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

	offerRow, err := txq.CreateOffer(ctx, sqlc.CreateOfferParams{
		OrganizationID:  orgID,
		OfferNo:         offerNo,
		CustomerID:      custID,
		CustomerName:    customerName,
		CustomerPhone:   strings.TrimSpace(customerPhone),
		CustomerEmail:   strings.TrimSpace(customerEmail),
		CustomerAddress: strings.TrimSpace(customerAddress),
		OfferDate:       repository.TimeToDate(time.Now()),
		ValidUntil:      repository.TimePtrToDate(in.ValidUntil),
		Subtotal:        repository.Float64ToNumeric(subtotal),
		VatRate:         repository.Float64ToNumeric(vatRate),
		VatAmount:       repository.Float64ToNumeric(vatAmount),
		GrandTotal:      repository.Float64ToNumeric(grandTotal),
		Notes:           strings.TrimSpace(in.Notes),
		Status:          domain.OfferStatusTaslak,
		CreatedBy:       createdBy,
	})
	if err != nil {
		return nil, err
	}

	domainItems, err := insertOfferItems(ctx, txq, offerRow.ID, orgID, items)
	if err != nil {
		return nil, err
	}

	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}

	offer := repository.ToDomainOffer(offerRow)
	offer.Items = domainItems
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
		offers[i] = repository.ToDomainOffer(r)
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
	row, err := s.q.GetOfferByID(ctx, sqlc.GetOfferByIDParams{ID: uid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	itemRows, err := s.q.ListOfferItems(ctx, uid)
	if err != nil {
		return nil, err
	}
	offer := repository.ToDomainOffer(row)
	offer.Items = make([]domain.OfferItem, len(itemRows))
	for i, r := range itemRows {
		offer.Items[i] = repository.ToDomainOfferItem(r)
	}
	return &offer, nil
}

// insertOfferItems, Create ve Update arasında paylaşılan kalem yazma
// mantığı -- her kalemin product_id'si (varsa) aynı organizasyona ait
// olmadan kabul edilmez (tenant izolasyonu), aksi halde geçersiz UUID'de
// olduğu gibi sessizce serbest metin satıra düşürülür.
func insertOfferItems(ctx context.Context, txq *sqlc.Queries, offerID, orgID pgtype.UUID, items []computedOfferItem) ([]domain.OfferItem, error) {
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
		itemRow, err := txq.CreateOfferItem(ctx, sqlc.CreateOfferItemParams{
			OfferID:     offerID,
			ProductID:   productID,
			ProductName: strings.TrimSpace(it.ProductName),
			Quantity:    repository.Float64ToNumeric(it.Quantity),
			UnitPrice:   repository.Float64ToNumeric(it.UnitPrice),
			LineTotal:   repository.Float64ToNumeric(it.LineTotal),
			SortOrder:   int32(i),
		})
		if err != nil {
			return nil, err
		}
		domainItems = append(domainItems, repository.ToDomainOfferItem(itemRow))
	}
	return domainItems, nil
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

// Update, yalnızca "taslak" durumundaki teklifleri düzenler -- gönderilmiş
// veya kabul edilmiş bir teklif doğrudan overwrite edilemez (Faz 3'te bu
// durumlar için revizyon sistemi eklenecek). Kalemler tamamen silinip
// yeniden yazılır, toplamlar sunucu tarafında yeniden hesaplanır.
func (s *OfferService) Update(ctx context.Context, id, organizationID string, in UpdateOfferInput) (*domain.Offer, error) {
	uid, err := repository.StringToUUID(id)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}

	existing, err := s.q.GetOfferByID(ctx, sqlc.GetOfferByIDParams{ID: uid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	if existing.Status != domain.OfferStatusTaslak {
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

	updatedRow, err := txq.UpdateOffer(ctx, sqlc.UpdateOfferParams{
		ID:              uid,
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
			return nil, domain.ErrNotFound
		}
		return nil, err
	}

	if err := txq.DeleteOfferItems(ctx, uid); err != nil {
		return nil, err
	}
	domainItems, err := insertOfferItems(ctx, txq, uid, orgID, items)
	if err != nil {
		return nil, err
	}

	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}

	offer := repository.ToDomainOffer(updatedRow)
	offer.Items = domainItems
	return &offer, nil
}

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
	row, err := s.q.UpdateOfferStatus(ctx, sqlc.UpdateOfferStatusParams{ID: uid, OrganizationID: orgID, Status: status})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	o := repository.ToDomainOffer(row)
	return &o, nil
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

// GetByShareToken, müşterinin auth gerektirmeyen paylaşım linkinden teklifi
// görüntülemesi için kullanılır -- güvenlik sınırı organization_id değil,
// tahmin edilemez token'ın kendisidir (bu yüzden organizationID parametresi
// almaz).
func (s *OfferService) GetByShareToken(ctx context.Context, token string) (*domain.Offer, error) {
	tid, err := repository.StringToUUID(token)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	row, err := s.q.GetOfferByShareToken(ctx, tid)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	itemRows, err := s.q.ListOfferItems(ctx, row.ID)
	if err != nil {
		return nil, err
	}
	offer := repository.ToDomainOffer(row)
	offer.Items = make([]domain.OfferItem, len(itemRows))
	for i, r := range itemRows {
		offer.Items[i] = repository.ToDomainOfferItem(r)
	}
	return &offer, nil
}

var ErrOfferNotRespondable = errors.New("bu teklif için onay/red işlemi yapılamaz")

// RespondByShareToken, müşterinin paylaşım linkinden teklifi kabul/red
// etmesini sağlar. Yalnızca "gönderildi" durumundaki teklifler için
// geçerlidir -- taslak bir teklif henüz müşteriye ulaşmamıştır, kabul/red
// edilmiş bir teklif ise zaten karara bağlanmıştır. organization_id burada
// da token'dan bulunan satırın kendi org'undan alınır (public parametre
// olarak DIŞARIDAN gelmez).
func (s *OfferService) RespondByShareToken(ctx context.Context, token, decision string) (*domain.Offer, error) {
	if decision != domain.OfferStatusKabulEdildi && decision != domain.OfferStatusReddedildi {
		return nil, errors.New("geçersiz karar")
	}
	tid, err := repository.StringToUUID(token)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	row, err := s.q.GetOfferByShareToken(ctx, tid)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	if row.Status != domain.OfferStatusGonderildi {
		return nil, ErrOfferNotRespondable
	}
	updated, err := s.q.UpdateOfferStatus(ctx, sqlc.UpdateOfferStatusParams{ID: row.ID, OrganizationID: row.OrganizationID, Status: decision})
	if err != nil {
		return nil, err
	}
	o := repository.ToDomainOffer(updated)
	return &o, nil
}

var ErrOfferAccepted = errors.New("kabul edilmiş teklif silinemez")

// Delete, BYZ'deki kuralı korur: kabul edilmiş bir teklifin tek dayanağı
// olduğu müşteri onayı/alacak kaydı olabileceğinden, "kabul edildi"
// durumundaki teklifler silinemez.
func (s *OfferService) Delete(ctx context.Context, id, organizationID string) error {
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
	if row.Status == domain.OfferStatusKabulEdildi {
		return ErrOfferAccepted
	}
	return s.q.DeleteOffer(ctx, sqlc.DeleteOfferParams{ID: uid, OrganizationID: orgID})
}

func round2(f float64) float64 {
	return float64(int64(f*100+0.5)) / 100
}
