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
	"github.com/shopspring/decimal"

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
	// ID: düzenlenen taslakta bu satırın karşılık geldiği MEVCUT kalemin
	// id'si (yeni eklenen satırlarda nil). Yalnızca Update'te, iç fiyatlama
	// yetkisi olmayan bir düzenleyicinin kaydında mevcut kalemlerin iç
	// maliyetini taşımak için kullanılır (bkz. carryOverInternalPricing) --
	// satırlar her kayıtta yine silinip yeniden yazılır.
	ID          *string
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

	// İç Taşeron Fiyatlama (migration 0040) -- yalnızca çağıran
	// offers.internal_pricing.manage iznine sahipse İŞLENİR (bkz.
	// computeOfferTotals); aksi halde SESSİZCE temizlenir. PricingMode ""
	// ise (pointer değil) bu kaleme iç fiyatlama uygulanmamış demektir --
	// domain.OfferItem'ın *string'inden FARKLI olarak burada boş dize
	// "yok" anlamına gelir (createOfferItemRequest JSON'unda daha basit).
	InternalSubcontractCost *float64
	PricingMode             string
	MarkupPercent           *float64
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
	// ValidUntilProvided: ValidUntil nil iken alanın bilerek boş mu
	// gönderildiğini (true: süresiz teklif) yoksa hiç gönderilmediğini
	// (false: firma varsayılan geçerlilik süresi uygulanır) ayırır.
	ValidUntilProvided bool
	Notes              string
	// VatRate nil ise (istekte hiç gönderilmemişse) firmanın varsayılan
	// KDV'si (ayar yoksa %20) uygulanır; açıkça 0 gönderilirse 0 olarak
	// KALIR (BYZ'deki falsy-zero bug'ının tekrarlanmaması için pointer).
	VatRate *float64
	// Currency nil/boş ise firmanın varsayılan para birimi (yoksa TRY).
	Currency       *string
	Items          []OfferItemInput
	UserID         string
	OrganizationID string
	// CanManageInternalPricing: handler'ın (AuthzContext üzerinden)
	// hesapladığı, offers.internal_pricing.manage iznine sahip olup
	// olmadığı -- false ise Items'taki iç fiyatlama alanları
	// computeOfferTotals içinde SESSİZCE temizlenir (bkz. o fonksiyonun
	// yorumu).
	CanManageInternalPricing bool
}

type computedOfferItem struct {
	OfferItemInput
	LineTotal float64
}

// computeOfferTotals, Create/Update arasında paylaşılan hesaplama mantığı --
// frontend'den gelen subtotal/vat_amount/grand_total değerlerine ASLA
// güvenilmez, her zaman burada sunucu tarafında yeniden hesaplanır.
//
// İç Taşeron Fiyatlama (migration 0040): canManageInternalPricing false ise
// (çağıranın offers.internal_pricing.manage izni yoksa) her kalemin iç
// fiyatlama alanları SESSİZCE temizlenir -- product_id/calc_category_id
// çapraz-org referanslarının "sessizce NULL'a düşürülmesi" İLE AYNI ilke,
// izin yok diye 400 üretmek yerine. İzin VARSA ve PricingMode="markup" ise
// unit_price -- computeOfferTotals'ın HİÇBİR istemci toplamına güvenmeme
// ilkesiyle BİREBİR AYNI gerekçeyle -- istemcinin gönderdiği değer ne
// olursa olsun cost*(1+markup/100) olarak SUNUCUDA yeniden hesaplanır;
// "manual" modda ise unit_price OLDUĞU GİBİ (dokunulmadan) kullanılır --
// elle girilen satış fiyatı hiçbir zaman otomatik ÜZERİNE YAZILMAZ.
//
// Yuvarlama: miktar, birim fiyat ve iç maliyet kolonları numeric(12,2)'dir
// -- bu yüzden ÖNCE ikisi de 2 haneye (decimal ile, float gürültüsü
// olmadan) yuvarlanır, satır toplamı ANCAK SONRA bu yuvarlanmış değerlerin
// çarpımından hesaplanır. Aksi halde (eski hâl) satır toplamı yuvarlanmamış
// miktardan hesaplanıp miktar kolona yuvarlanarak yazılıyordu ve müşterinin
// gördüğü "miktar × birim fiyat" satır toplamını tutmuyordu.
//
// Doğrulama sırası: negatif birim fiyat kontrolü marj yeniden hesabından
// SONRA yapılır (%-100'ün altındaki bir marj aksi halde negatif satış
// fiyatı üretiyordu); KDV oranı 0-100 aralığında olmalıdır (negatif değer
// kabul ediliyor, 999,99 üstü ise numeric(5,2) taşıp 500 dönüyordu).
func computeOfferTotals(items []OfferItemInput, vatRateInput *float64, canManageInternalPricing bool) ([]computedOfferItem, float64, float64, float64, float64, error) {
	fail := func(msg string) ([]computedOfferItem, float64, float64, float64, float64, error) {
		return nil, 0, 0, 0, 0, errors.New(msg)
	}
	hundred := decimal.NewFromInt(100)
	// Çağıranlar oranı (istek ya da firma varsayılanı) zaten çözer; nil
	// yalnızca son çare.
	vatRate := decimal.NewFromFloat(domain.DefaultOfferVATRate)
	if vatRateInput != nil {
		vatRate = decimal.NewFromFloat(*vatRateInput).Round(2)
	}
	if vatRate.IsNegative() || vatRate.GreaterThan(hundred) {
		return fail("KDV oranı 0 ile 100 arasında olmalıdır")
	}
	computed := make([]computedOfferItem, 0, len(items))
	subtotal := decimal.Zero
	for _, it := range items {
		name := strings.TrimSpace(it.ProductName)
		qty := decimal.NewFromFloat(it.Quantity).Round(2)
		// Adı boş ya da miktarı 0 olan satırlar formun boş bıraktığı
		// satırlardır -- sessizce atlanır (mevcut davranış).
		if name == "" || !qty.IsPositive() {
			continue
		}
		if !canManageInternalPricing {
			it.InternalSubcontractCost = nil
			it.PricingMode = ""
			it.MarkupPercent = nil
		}
		price := decimal.NewFromFloat(it.UnitPrice).Round(2)
		if it.InternalSubcontractCost != nil {
			cost := decimal.NewFromFloat(*it.InternalSubcontractCost).Round(2)
			if cost.IsNegative() {
				return fail("iç taşeron maliyeti negatif olamaz")
			}
			if !cost.LessThan(offerAmountLimit) {
				return fail("iç taşeron maliyeti çok büyük")
			}
			costF := cost.InexactFloat64()
			it.InternalSubcontractCost = &costF
			switch it.PricingMode {
			case domain.OfferItemPricingModeMarkup:
				if it.MarkupPercent == nil {
					return fail("marj yüzdesi girilmelidir")
				}
				markup := decimal.NewFromFloat(*it.MarkupPercent).Round(2)
				// markup_percent numeric(6,2): ±9999,99.
				if !markup.Abs().LessThan(decimal.NewFromInt(10000)) {
					return fail("marj yüzdesi -9999,99 ile 9999,99 arasında olmalıdır")
				}
				markupF := markup.InexactFloat64()
				it.MarkupPercent = &markupF
				price = cost.Mul(decimal.NewFromInt(1).Add(markup.Div(hundred))).Round(2)
			case domain.OfferItemPricingModeManual:
				it.MarkupPercent = nil
			default:
				return fail("geçersiz fiyatlama modu")
			}
		} else {
			it.PricingMode = ""
			it.MarkupPercent = nil
		}
		if price.IsNegative() {
			return fail(fmt.Sprintf("%q kaleminin birim fiyatı negatif olamaz", name))
		}
		lineTotal := qty.Mul(price).Round(2)
		if !qty.LessThan(offerAmountLimit) || !price.LessThan(offerAmountLimit) || !lineTotal.LessThan(offerAmountLimit) {
			return fail(fmt.Sprintf("%q kaleminin miktarı veya tutarı çok büyük", name))
		}
		it.Quantity = qty.InexactFloat64()
		it.UnitPrice = price.InexactFloat64()
		subtotal = subtotal.Add(lineTotal)
		computed = append(computed, computedOfferItem{OfferItemInput: it, LineTotal: lineTotal.InexactFloat64()})
	}
	if len(computed) == 0 {
		return fail("geçerli en az bir kalem girilmelidir")
	}
	vatAmount := subtotal.Mul(vatRate).Div(hundred).Round(2)
	grandTotal := subtotal.Add(vatAmount)
	if !grandTotal.LessThan(offerAmountLimit) {
		return fail("teklif toplamı çok büyük")
	}
	return computed, subtotal.InexactFloat64(), vatRate.InexactFloat64(), vatAmount.InexactFloat64(), grandTotal.InexactFloat64(), nil
}

// offerAmountLimit: teklif miktar/tutar kolonları numeric(12,2) -- en çok
// 9.999.999.999,99. Sınırı aşan bir değer INSERT'te "numeric field
// overflow" ile 500'e düşerdi; computeOfferTotals anlaşılır bir mesajla
// reddeder.
var offerAmountLimit = decimal.New(1, 10)

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
		var pricingMode *string
		if it.PricingMode != "" {
			pm := it.PricingMode
			pricingMode = &pm
		}
		itemRow, err := txq.CreateOfferRevisionItem(ctx, sqlc.CreateOfferRevisionItemParams{
			RevisionID:              revisionID,
			ProductID:               productID,
			ProductName:             strings.TrimSpace(it.ProductName),
			Quantity:                repository.Float64ToNumeric(it.Quantity),
			UnitPrice:               repository.Float64ToNumeric(it.UnitPrice),
			DiscountType:            domain.DiscountNone,
			DiscountValue:           repository.Float64ToNumeric(0),
			LineTotal:               repository.Float64ToNumeric(it.LineTotal),
			SortOrder:               int32(i),
			Unit:                    strings.TrimSpace(it.Unit),
			SectionLabel:            it.SectionLabel,
			CalcCategoryID:          calcCategoryID,
			CalcSnapshot:            []byte(it.CalcSnapshot),
			InternalSubcontractCost: repository.Float64PtrToNumeric(it.InternalSubcontractCost),
			PricingMode:             pricingMode,
			MarkupPercent:           repository.Float64PtrToNumeric(it.MarkupPercent),
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
			// İç Taşeron Fiyatlama (migration 0040): calc_snapshot İLE AYNI
			// ilke -- "Revize Et" önceki revizyonun İÇ fiyatlama
			// varsayımlarını da AYNEN taşır, MUTATE ETMEZ (spec: "Do not
			// mutate historical revision assumptions when creating a new
			// revision" -- yeni revizyonda kullanıcı Update() ile bilinçli
			// olarak değiştirene kadar).
			InternalSubcontractCost: it.InternalSubcontractCost,
			PricingMode:             it.PricingMode,
			MarkupPercent:           it.MarkupPercent,
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
	now := time.Now()
	if err := validateOfferValidUntil(in.ValidUntil, now); err != nil {
		return nil, err
	}
	// Gönderilmeyen KDV/para birimi/geçerlilik firma ayarından gelir;
	// gönderilen değer (0 ve "süresiz" dahil) her zaman korunur.
	defaults, err := loadOfferDefaults(ctx, s.q, orgID)
	if err != nil {
		return nil, err
	}
	vatIn := in.VatRate
	if vatIn == nil {
		vatIn = &defaults.VATRate
	}
	currency := defaults.Currency
	if in.Currency != nil && strings.TrimSpace(*in.Currency) != "" {
		c, ok := domain.NormalizeCurrency(*in.Currency)
		if !ok {
			return nil, ErrInvalidOfferCurrency
		}
		currency = c
	}
	validUntil := in.ValidUntil
	if validUntil == nil && !in.ValidUntilProvided {
		validUntil = defaults.ValidUntilFrom(istanbulDay(now))
	}
	items, subtotal, vatRate, vatAmount, grandTotal, err := computeOfferTotals(in.Items, vatIn, in.CanManageInternalPricing)
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
		ValidUntil:      repository.TimePtrToDate(validUntil),
		Subtotal:        repository.Float64ToNumeric(subtotal),
		DiscountType:    domain.DiscountNone,
		DiscountValue:   repository.Float64ToNumeric(0),
		DiscountAmount:  repository.Float64ToNumeric(0),
		VatRate:         repository.Float64ToNumeric(vatRate),
		VatAmount:       repository.Float64ToNumeric(vatAmount),
		GrandTotal:      repository.Float64ToNumeric(grandTotal),
		Currency:        currency,
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
	prefix, err := s.q.GetOfferPrefix(ctx, orgID)
	if err != nil {
		// Satır yok (organization_commercial_settings henüz yapılandırılmamış
		// -- ör. onboarding'in "Teklif" adımı henüz tamamlanmamış bir
		// organizasyon) -- "TKF" varsayılanına düş. offer_counters zaten
		// tamamen org-partitioned olduğu için bu, mevcut TKF-YYYY-NNNN
		// numaralandırmasını hiçbir şekilde etkilemez (bkz. Arvend Yapı'nın
		// migration 0032'de açıkça seed edilen offer_prefix='TKF' satırı).
		if !errors.Is(err, pgx.ErrNoRows) {
			return "", err
		}
		prefix = "TKF"
	}
	if prefix == "" {
		prefix = "TKF"
	}
	return fmt.Sprintf("%s-%d-%04d", prefix, year, seq), nil
}

type OfferListResult struct {
	Offers []domain.Offer
	// Total: filtrelerin (durum dahil) eşleştiği TÜM tekliflerin sayısı --
	// sayfadaki satır sayısı değil.
	Total int64
	// StatusCounts: aynı filtrelerle (durum HARİÇ) her durumdaki teklif
	// sayısı -- durum sekmelerinin sayaçları. Hiç teklifi olmayan durumlar
	// 0 ile yer alır.
	StatusCounts map[string]int64
	Page         int
	Limit        int
}

// OfferListFilter, teklif listesinin sunucu tarafı filtreleridir; boş
// alanlar filtresizdir.
type OfferListFilter struct {
	IsPassive  bool
	CustomerID string
	Status     string
	Search     string
	DateFrom   *time.Time
	DateTo     *time.Time
	Page       int
	Limit      int
}

// escapeLikePattern, kullanıcı aramasındaki LIKE joker karakterlerini
// (%, _ ve kaçış karakteri \) düz metne çevirir -- "%" araması her teklifi
// eşleştirmesin.
func escapeLikePattern(s string) string {
	return strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`).Replace(s)
}

func (s *OfferService) List(ctx context.Context, organizationID string, f OfferListFilter) (*OfferListResult, error) {
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	if f.Limit <= 0 || f.Limit > 200 {
		f.Limit = 50
	}
	if f.Page <= 0 {
		f.Page = 1
	}
	var custID pgtype.UUID
	if f.CustomerID != "" {
		if cid, err := repository.StringToUUID(f.CustomerID); err == nil {
			custID = cid
		}
	}
	var status *string
	if f.Status != "" {
		if !domain.ValidOfferStatus(f.Status) {
			return nil, errors.New("geçersiz durum filtresi")
		}
		status = &f.Status
	}
	var search *string
	if q := strings.TrimSpace(f.Search); q != "" {
		escaped := escapeLikePattern(q)
		search = &escaped
	}
	dateFrom, dateTo := repository.TimePtrToDate(f.DateFrom), repository.TimePtrToDate(f.DateTo)

	rows, err := s.q.ListOffers(ctx, sqlc.ListOffersParams{
		OrganizationID: orgID,
		IsPassive:      f.IsPassive,
		CustomerID:     custID,
		Status:         status,
		DateFrom:       dateFrom,
		DateTo:         dateTo,
		Search:         search,
		RowLimit:       int32(f.Limit),
		RowOffset:      int32((f.Page - 1) * f.Limit),
	})
	if err != nil {
		return nil, err
	}
	countRows, err := s.q.CountOffersByStatus(ctx, sqlc.CountOffersByStatusParams{
		OrganizationID: orgID, IsPassive: f.IsPassive, CustomerID: custID,
		DateFrom: dateFrom, DateTo: dateTo, Search: search,
	})
	if err != nil {
		return nil, err
	}
	counts := map[string]int64{
		domain.OfferStatusTaslak: 0, domain.OfferStatusGonderildi: 0,
		domain.OfferStatusKabulEdildi: 0, domain.OfferStatusReddedildi: 0,
	}
	var all int64
	for _, c := range countRows {
		counts[c.Status] = c.Count
		all += c.Count
	}
	total := all
	if status != nil {
		total = counts[*status]
	}
	offers := make([]domain.Offer, len(rows))
	for i, r := range rows {
		offers[i] = repository.ToDomainOfferListItem(r)
	}
	return &OfferListResult{Offers: offers, Total: total, StatusCounts: counts, Page: f.Page, Limit: f.Limit}, nil
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

// ErrOfferInternalPricingUnmatched: taslakta iç maliyet bilgisi olan
// kalemler var, düzenleyicinin bunları görme/değiştirme yetkisi yok VE
// gönderilen kalemler mevcut kalemlerle (id ile) eşleştirilemiyor. Kaydı
// kabul etmek iç maliyetleri sessizce silmek olurdu -- bu yüzden reddedilir.
var ErrOfferInternalPricingUnmatched = errors.New("bu taslaktaki bazı kalemlerde iç maliyet bilgisi var ve gönderilen kalemler mevcut kalemlerle eşleştirilemedi; iç maliyetlerin silinmemesi için kayıt yapılmadı. Uygulamayı güncelleyip tekrar deneyin ya da iç fiyatlama yetkisi olan bir kullanıcıdan düzenlemesini isteyin")

// carryOverInternalPricing, offers.internal_pricing.manage yetkisi OLMAYAN
// bir düzenleyicinin gönderdiği kalemlere, mevcut revizyondaki karşılık
// gelen kalemin (istekteki id ile eşleşen) iç fiyatlama alanlarını taşır.
// İstemcinin gönderdiği iç alanlar her durumda yok sayılır (yetki sınırı).
//
//   - Mevcut kalemlerin hiçbirinde iç maliyet yoksa kaybedilecek bir şey
//     yoktur -- kalemler olduğu gibi döner.
//   - Varsa ama istekteki HİÇBİR kalem id taşımıyorsa (id göndermeyen eski
//     istemci) eşleştirme güvenilir değildir -> ErrOfferInternalPricingUnmatched.
//     İstek id taşıyorsa, hiçbir satırın işaret etmediği mevcut kalemler
//     düzenleyicinin bilerek sildiği kalemlerdir.
//   - "markup" modundaki bir kalemin birim fiyatını düzenleyici değiştirdiyse
//     kalem "manual"a çevrilir (maliyet korunur): aksi halde sunucu fiyatı
//     maliyet × marjdan yeniden hesaplayıp düzenleyicinin -- iç maliyeti
//     göremeyen kişinin -- girdiği fiyatı sessizce geri alırdı.
func carryOverInternalPricing(items []OfferItemInput, existing []sqlc.OfferRevisionItem) ([]OfferItemInput, error) {
	withInternal := make(map[string]sqlc.OfferRevisionItem)
	for _, e := range existing {
		if e.InternalSubcontractCost.Valid {
			withInternal[e.ID.String()] = e
		}
	}
	out := make([]OfferItemInput, len(items))
	anyID := false
	for i, it := range items {
		it.InternalSubcontractCost, it.PricingMode, it.MarkupPercent = nil, "", nil
		if it.ID != nil && strings.TrimSpace(*it.ID) != "" {
			anyID = true
			if uid, err := repository.StringToUUID(strings.TrimSpace(*it.ID)); err == nil {
				if e, ok := withInternal[uid.String()]; ok {
					it.InternalSubcontractCost = repository.NumericToFloat64Ptr(e.InternalSubcontractCost)
					if e.PricingMode != nil {
						it.PricingMode = *e.PricingMode
					}
					it.MarkupPercent = repository.NumericToFloat64Ptr(e.MarkupPercent)
					if it.PricingMode == domain.OfferItemPricingModeMarkup &&
						!decimal.NewFromFloat(it.UnitPrice).Round(2).Equal(repository.NumericToDecimal(e.UnitPrice)) {
						it.PricingMode = domain.OfferItemPricingModeManual
						it.MarkupPercent = nil
					}
				}
			}
		}
		out[i] = it
	}
	if len(withInternal) > 0 && !anyID {
		return nil, ErrOfferInternalPricingUnmatched
	}
	return out, nil
}

type UpdateOfferInput struct {
	CustomerID      *string
	CustomerName    string
	CustomerPhone   string
	CustomerEmail   string
	CustomerAddress string
	ValidUntil      *time.Time
	// ValidUntilProvided false ise (istemci alanı hiç göndermedi ya da null
	// gönderdi) revizyonun mevcut geçerlilik tarihi KORUNUR; true ise
	// ValidUntil yazılır (nil = tarihi temizle). Eskiden alanı göndermeyen
	// her kayıt (ör. mobil form) tarihi sessizce NULL'a çekiyordu.
	ValidUntilProvided bool
	Notes              string
	VatRate            *float64 // nil = revizyonun mevcut oranı korunur
	Items              []OfferItemInput
	UserID             string
	// CanManageInternalPricing: bkz. CreateOfferInput.
	CanManageInternalPricing bool
}

// ErrOfferValidUntilInPast: yeni girilen geçerlilik tarihi bugünden önce
// olamaz -- böyle bir teklif müşteriye ulaştığı anda yanıtlanamazdı.
var ErrOfferValidUntilInPast = errors.New("geçerlilik tarihi bugünden önce olamaz")

// ErrInvalidOfferCurrency: para birimi 3 harfli bir kod olmalı (currency
// kolonu varchar(3); daha uzun bir değer ham "value too long" ile 500'e
// düşerdi).
var ErrInvalidOfferCurrency = errors.New("para birimi 3 harfli bir kod olmalıdır (ör. TRY, USD, EUR)")

// calendarDay, bir anın takvim gününü (saat/dilim bilgisi atılmış) döner.
func calendarDay(t time.Time) time.Time {
	y, m, d := t.Date()
	return time.Date(y, m, d, 0, 0, 0, 0, time.UTC)
}

func validateOfferValidUntil(validUntil *time.Time, now time.Time) error {
	if validUntil != nil && calendarDay(*validUntil).Before(calendarDay(IstanbulNow(now))) {
		return ErrOfferValidUntilInPast
	}
	return nil
}

// OfferValidityExpired, geçerlilik tarihi (dahil) geçmiş bir teklif için
// true döner -- "bugün" İstanbul takvim günüdür (bkz. timezone.go). Tarihi
// olmayan teklif süresiz geçerlidir. Müşteri kararı (RespondByShareLinkToken)
// ve public sayfanın "süresi doldu" bilgisi bu TEK fonksiyondan türer.
func OfferValidityExpired(validUntil *time.Time, now time.Time) bool {
	return validUntil != nil && calendarDay(IstanbulNow(now)).After(calendarDay(*validUntil))
}

func offerRevisionValidityExpired(rev sqlc.OfferRevision, now time.Time) bool {
	if !rev.ValidUntil.Valid {
		return false
	}
	t := rev.ValidUntil.Time
	return OfferValidityExpired(&t, now)
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
	if in.ValidUntilProvided {
		if err := validateOfferValidUntil(in.ValidUntil, time.Now()); err != nil {
			return nil, err
		}
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	// Gönderilmeyen geçerlilik tarihi ve KDV oranı KORUNUR (Create'teki
	// firma varsayılanı burada uygulanmaz -- taslak zaten bir değer taşır;
	// eskiden KDV'siz bir kayıt oranı sessizce %20'ye çeviriyordu).
	validUntil := repository.TimePtrToDate(in.ValidUntil)
	vatIn := in.VatRate
	if !in.ValidUntilProvided || vatIn == nil {
		currentRev, err := txq.GetOfferRevisionByID(ctx, sqlc.GetOfferRevisionByIDParams{ID: offerRow.CurrentRevisionID, OrganizationID: orgID})
		if err != nil {
			return nil, err
		}
		if !in.ValidUntilProvided {
			validUntil = currentRev.ValidUntil
		}
		if vatIn == nil {
			v := repository.NumericToFloat64(currentRev.VatRate)
			vatIn = &v
		}
	}

	// İç fiyatlama yetkisi olmayan düzenleyici: istemcinin gönderdiği iç
	// alanlara hiç güvenilmez, mevcut kalemlerinkiler id ile taşınır (bkz.
	// carryOverInternalPricing). Taşınan değerler veritabanından geldiği
	// için hesaplama bu durumda "yetkili" yoldan yapılır -- aksi halde
	// computeOfferTotals onları da silerdi (eski hata: kalemler silinip
	// yeniden yazıldığı için iç maliyetler sessizce kayboluyordu).
	itemsIn, trustInternal := in.Items, in.CanManageInternalPricing
	if !in.CanManageInternalPricing {
		existing, err := txq.ListOfferRevisionItems(ctx, offerRow.CurrentRevisionID)
		if err != nil {
			return nil, err
		}
		if itemsIn, err = carryOverInternalPricing(in.Items, existing); err != nil {
			return nil, err
		}
		trustInternal = true
	}
	items, subtotal, vatRate, vatAmount, grandTotal, err := computeOfferTotals(itemsIn, vatIn, trustInternal)
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

	updatedRev, err := txq.UpdateOfferRevision(ctx, sqlc.UpdateOfferRevisionParams{
		ID:              offerRow.CurrentRevisionID,
		OrganizationID:  orgID,
		CustomerID:      custID,
		CustomerName:    customerName,
		CustomerPhone:   strings.TrimSpace(customerPhone),
		CustomerEmail:   strings.TrimSpace(customerEmail),
		CustomerAddress: strings.TrimSpace(customerAddress),
		ValidUntil:      validUntil,
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

// ErrOfferCannotReturnToDraft: müşteriye gönderilmiş (ya da müşterinin/
// personelin karar verdiği) bir revizyon "taslak"a geri alınamaz. Taslak,
// Update()'in revizyonu YERİNDE yeniden yazdığı tek durumdur -- geri dönüşe
// izin vermek, müşterinin elindeki hâlâ aktif paylaşım linkinin gösterdiği
// içeriği sessizce değiştirmek (ve sonra yeniden "gönderildi" yapınca
// müşterinin görmediği bir içeriği kabul ettirmek) demekti. Değişiklik için
// her zaman "Revize Et" (yeni revizyon + eski linklerin iptali) kullanılır.
var ErrOfferCannotReturnToDraft = errors.New("müşteriye gönderilmiş bir teklif taslağa geri alınamaz; değişiklik için \"Revize Et\" ile yeni bir revizyon oluşturun")

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
	if status == domain.OfferStatusTaslak && offerRow.Status != domain.OfferStatusTaslak {
		return nil, ErrOfferCannotReturnToDraft
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
	if justSent && offerRevisionValidityExpired(updatedRev, time.Now()) {
		return nil, ErrOfferSendExpired
	}
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
	// from_status/to_status: iç (panelden verilen) kabul/red kararının
	// tarihi bu olaydan okunur (ana sayfa "son 90 gün" kabul oranı, bkz.
	// DashboardOffersByCurrency) -- offers.updated_at her düzenlemede
	// değiştiği için karar tarihi olarak KULLANILMAZ.
	statusMeta := map[string]any{"from_status": previousStatus, "to_status": status}
	if err := logOfferEvent(ctx, txq, orgID, offerRow.ID, offerRow.CurrentRevisionID, eventType, actorID, statusMeta, "", ""); err != nil {
		return nil, err
	}
	// Yalnızca gerçek geçişte: zaten reddedilmiş teklifi yeniden "reddedildi"
	// kaydetmek herkese ikinci bir bildirim düşürmesin.
	if status != previousStatus {
		if err := notifyOfferDecision(ctx, txq, offerRow, updatedRev, status, actorID); err != nil {
			return nil, err
		}
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

	// Süresi zaten dolmuş bir geçerlilik tarihi yeni revizyona taşınmaz:
	// yeni revizyon yeni bir fiyat/süre teklifidir, eski tarihle gönderilirse
	// müşteri onu hiç yanıtlayamazdı. Personel yeni tarihi taslakta girer.
	validUntil := currentRev.ValidUntil
	if offerRevisionValidityExpired(currentRev, time.Now()) {
		validUntil = pgtype.Date{}
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
		ValidUntil:      validUntil,
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
	// ErrOfferValidityExpired: revizyonun geçerlilik tarihi (valid_until,
	// o gün dahil) geçmiş -- müşteri artık kabul/red veremez. Eskiden tarih
	// hiç kontrol edilmiyordu; süresi aylar önce dolmuş bir fiyat kabul
	// edilebiliyordu.
	ErrOfferValidityExpired = errors.New("bu teklifin geçerlilik süresi dolmuş; onay/red işlemi yapılamaz. Güncel bir teklif için lütfen teklifi gönderen firmayla iletişime geçin")
	// ErrOfferSendExpired: geçerlilik tarihi geçmiş bir revizyon müşteriye
	// gönderilemez -- gönderilen link hiçbir zaman yanıtlanamazdı.
	ErrOfferSendExpired = errors.New("teklifin geçerlilik tarihi geçmiş; göndermeden önce geçerlilik tarihini güncelleyin")
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
	link, _, err := s.resolveActiveShareLinkWithOrg(ctx, q, token)
	return link, err
}

// resolveActiveShareLinkWithOrg, resolveActiveShareLink'in bağlantının
// firmasını da (public sayfadaki firma adı için) dönen hâlidir.
// Askıya alınmış/iptal edilmiş/silinmiş firmanın linki çalışmaz (bkz.
// publicLinkOrganization); Respond'da bu kontrol de kilit altında tekrarlanır
// (çözüm orada ikinci kez yapılır).
func (s *OfferService) resolveActiveShareLinkWithOrg(ctx context.Context, q *sqlc.Queries, token string) (sqlc.OfferShareLink, sqlc.Organization, error) {
	tid, err := repository.StringToUUID(token)
	if err != nil {
		return sqlc.OfferShareLink{}, sqlc.Organization{}, domain.ErrNotFound
	}
	link, err := q.GetShareLinkByToken(ctx, tid)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return sqlc.OfferShareLink{}, sqlc.Organization{}, domain.ErrNotFound
		}
		return sqlc.OfferShareLink{}, sqlc.Organization{}, err
	}
	if link.RevokedAt.Valid {
		return sqlc.OfferShareLink{}, sqlc.Organization{}, ErrShareLinkRevoked
	}
	if link.ExpiresAt.Valid && time.Now().After(link.ExpiresAt.Time) {
		return sqlc.OfferShareLink{}, sqlc.Organization{}, ErrShareLinkExpired
	}
	org, err := publicLinkOrganization(ctx, q, link.OrganizationID)
	if err != nil {
		return sqlc.OfferShareLink{}, sqlc.Organization{}, err
	}
	return link, org, nil
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
	v, err := s.GetPublicView(ctx, token, ip, userAgent)
	if err != nil {
		return nil, false, err
	}
	return &v.Offer, v.CanRespond, nil
}

// PublicOfferView, müşteri paylaşım sayfasının ihtiyaç duyduğu her şeydir:
// bağlı revizyonun içeriği, şu an karar verilip verilemeyeceği, geçerlilik
// süresinin dolup dolmadığı ve teklifi veren firmanın adı (sayfa başlığı
// her firmanın müşterisine "Arvend Yapı" gösteriyordu).
type PublicOfferView struct {
	Offer            domain.Offer
	CanRespond       bool
	ValidityExpired  bool
	OrganizationName string
}

// GetPublicView: bkz. GetByShareLinkToken. Pasife (arşive) alınmış bir
// teklifin linki artık açılmaz (ErrPublicLinkUnavailable) -- arşive almak
// teklifi geri çekmektir; eskiden link çalışmaya ve teklif kabul
// edilebilmeye devam ediyordu. Arşivden çıkarılınca linkler yeniden
// çalışır (iptal edilmezler, yalnızca reddedilirler).
func (s *OfferService) GetPublicView(ctx context.Context, token, ip, userAgent string) (*PublicOfferView, error) {
	link, org, err := s.resolveActiveShareLinkWithOrg(ctx, s.q, token)
	if err != nil {
		return nil, err
	}
	offerRow, err := s.q.GetOfferByID(ctx, sqlc.GetOfferByIDParams{ID: link.OfferID, OrganizationID: link.OrganizationID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	if offerRow.IsPassive {
		return nil, ErrPublicLinkUnavailable
	}
	revRow, err := s.q.GetOfferRevisionByID(ctx, sqlc.GetOfferRevisionByIDParams{ID: link.RevisionID, OrganizationID: link.OrganizationID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	now := time.Now()
	expired := offerRevisionValidityExpired(revRow, now)
	canRespond := offerRow.CurrentRevisionID.String() == link.RevisionID.String() &&
		revRow.Status == domain.OfferStatusGonderildi && !expired
	itemRows, err := s.q.ListOfferRevisionItems(ctx, revRow.ID)
	if err != nil {
		return nil, err
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

	awaitingDecision := offerRow.CurrentRevisionID == link.RevisionID && revRow.Status == domain.OfferStatusGonderildi
	if err := s.recordCustomerView(ctx, offerRow, revRow, awaitingDecision, ip, userAgent); err != nil {
		log.Printf("customer_viewed olayı yazılamadı: %v", err)
	}
	return &PublicOfferView{Offer: offer, CanRespond: canRespond, ValidityExpired: expired, OrganizationName: org.Name}, nil
}

// recordCustomerView, customer_viewed olayını yazar. Revizyon müşterinin
// kararını beklerken (teklifin güncel revizyonu, "gönderildi") yapılan İLK
// açılışta olay first_open ile işaretlenir ve teklifi hazırlayana "Müşteri
// teklifi açtı" bildirimi gider (notifyOfferFirstOpen). Gürültüyü düşük
// tutan kural:
//   - Revizyon başına BİR kez. Sayfa yenileme, linki tekrar açma, aynı
//     revizyonun ikinci bir linki bildirim üretmez; yeni bir revizyon
//     gönderilince onun ilk açılışı yeniden bildirilir (müşterinin revize
//     teklife baktığı da haberdir).
//   - Yalnızca karar beklenirken. Taslak revizyonun linkini personelin
//     önizlemesi ya da karar verilmiş/eskimiş bir revizyonun açılması
//     bildirim değildir ve "ilk açılış" hakkını da tüketmez.
//   - "İlk" bilgisi offer_events'in kendisinden okunur (first_open işaretli
//     bir görüntülenme var mı) -- ayrı kolon/migration yok. Eşzamanlı iki
//     açılış revizyon anahtarlı advisory lock ile sıraya girer; yalnızca
//     biri "ilk" sayılır.
//
// Bot/önizleme ayıklanmaz, ayıklanamaz: müşteri sayfası (/paylas) Next.js
// sunucusunda render edilir ve bu ucu kendisi çağırır; tarayıcının
// User-Agent'ı ve IP'si buraya ulaşmaz (gelen her istek Next sunucusunun
// kendisidir). Linki WhatsApp'a yapıştırınca gönderenin telefonunun
// yaptığı önizleme ya da e-posta güvenlik tarayıcısının tıklaması da bu
// yüzden "açılış" görünür (Ana Sayfa'daki görüntülenme sayıları da aynı
// durumda, bkz. DashboardOfferLatestViews).
//
// En iyi çaba: hata müşterinin teklifi görmesini engellemez (çağıran
// yalnızca loglar).
func (s *OfferService) recordCustomerView(ctx context.Context, offerRow sqlc.Offer, revRow sqlc.OfferRevision, awaitingDecision bool, ip, userAgent string) error {
	if !awaitingDecision {
		return logOfferEvent(ctx, s.q, offerRow.OrganizationID, offerRow.ID, revRow.ID, domain.EventCustomerViewed,
			pgtype.UUID{}, nil, ip, userAgent)
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)
	// Respond/Revise'ın teklif kilidinden ayrı anahtar: bir görüntülenme
	// kaydı müşterinin kabul/red isteğini beklemesin.
	if _, err := tx.Exec(ctx, "SELECT pg_advisory_xact_lock(hashtext($1))", "offer_first_open:"+revRow.ID.String()); err != nil {
		return err
	}
	logged, err := txq.OfferRevisionFirstOpenLogged(ctx, sqlc.OfferRevisionFirstOpenLoggedParams{OfferID: offerRow.ID, RevisionID: revRow.ID})
	if err != nil {
		return err
	}
	var meta map[string]any
	if !logged {
		meta = map[string]any{"first_open": true}
	}
	if err := logOfferEvent(ctx, txq, offerRow.OrganizationID, offerRow.ID, revRow.ID, domain.EventCustomerViewed,
		pgtype.UUID{}, meta, ip, userAgent); err != nil {
		return err
	}
	if !logged {
		if err := notifyOfferFirstOpen(ctx, txq, offerRow, revRow); err != nil {
			return err
		}
	}
	return tx.Commit(ctx)
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
	if offerRow.IsPassive {
		return nil, ErrPublicLinkUnavailable
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
	if offerRevisionValidityExpired(revRow, time.Now()) {
		return nil, ErrOfferValidityExpired
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
	if err := notifyOfferDecision(ctx, txq, offerRow, updatedRev, decision, pgtype.UUID{}); err != nil {
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
	// Mail gönderilMEDEN önce: süresi dolmuş bir teklifin linki müşteriye
	// gitse bile hiçbir zaman yanıtlanamaz (bkz. RespondByShareLinkToken).
	if OfferValidityExpired(offer.ValidUntil, time.Now()) {
		return nil, ErrOfferSendExpired
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

// round2, 2 haneye yuvarlar (yarım değerler sıfırdan uzağa). decimal
// üzerinden yapılır: eski float hâli (int64(f*100+0.5)) 1.005 gibi ikili
// tabanda tam temsil edilemeyen değerleri aşağı, negatif değerleri ise
// yanlış yöne yuvarlıyordu.
func round2(f float64) float64 {
	return decimal.NewFromFloat(f).Round(2).InexactFloat64()
}
