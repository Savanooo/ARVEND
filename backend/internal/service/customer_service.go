package service

import (
	"context"
	"errors"
	"strings"
	"unicode"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

type CustomerService struct {
	q *sqlc.Queries
}

func NewCustomerService(q *sqlc.Queries) *CustomerService {
	return &CustomerService{q: q}
}

type CustomerInput struct {
	Name      string
	Phone     string
	Email     string
	Address   string
	TaxOffice string
	TaxNumber string
	Notes     string
	IsActive  bool
	// AllowDuplicate: kullanıcı "aynı vergi no/telefonla kayıtlı müşteri var"
	// uyarısını gördü ve yine de kaydetmeyi seçti (ör. aynı firmanın iki
	// şubesi tek vergi numarasıyla). false iken çakışma ErrDuplicateCustomer
	// ile reddedilir.
	AllowDuplicate bool
}

// ErrDuplicateCustomer, aynı firmada aynı vergi numarası ya da telefonla
// kayıtlı bir müşteri olduğunda döner (errors.Is ile yakalanır; ayrıntı
// için errors.As ile *DuplicateCustomerError). Eskiden hiçbir kontrol
// yoktu -- aynı müşteri farklı yazımlarla defalarca açılıyor, teklifleri ve
// projeleri kartlar arasında dağılıyordu.
var ErrDuplicateCustomer = errors.New("aynı bilgilerle kayıtlı bir müşteri zaten var")

// DuplicateCustomerError, çakışan mevcut müşteriyi taşır -- istemci adını
// gösterip "yine de kaydet" seçeneği sunabilsin.
type DuplicateCustomerError struct {
	Existing domain.Customer
	// Field: "tax_number" ya da "phone" -- hangi bilginin çakıştığı.
	Field string
}

func (e *DuplicateCustomerError) Error() string {
	what := "telefon numarasıyla"
	if e.Field == "tax_number" {
		what = "vergi numarasıyla"
	}
	msg := "bu " + what + " kayıtlı bir müşteri zaten var: " + e.Existing.Name
	if !e.Existing.IsActive {
		msg += " (arşivde)"
	}
	return msg
}

func (e *DuplicateCustomerError) Is(target error) bool { return target == ErrDuplicateCustomer }

// customerTaxKey, vergi numarasının karşılaştırma anahtarıdır: yalnızca
// harf/rakam, büyük harf ("123 456 78-90" == "1234567890"). 5 karakterden
// kısa anahtar karşılaştırılmaz (yanlış pozitif üretir).
// FindCustomerDuplicates SQL'i AYNI kuralı uygular.
func customerTaxKey(s string) string {
	var b strings.Builder
	for _, r := range s {
		if r < unicode.MaxASCII && (unicode.IsDigit(r) || unicode.IsLetter(r)) {
			b.WriteRune(unicode.ToUpper(r))
		}
	}
	if b.Len() < 5 {
		return ""
	}
	return b.String()
}

func onlyDigits(s string) string {
	var b strings.Builder
	for _, r := range s {
		if r >= '0' && r <= '9' {
			b.WriteRune(r)
		}
	}
	return b.String()
}

// customerPhoneKey, telefonun karşılaştırma anahtarıdır: rakamların son 10
// hanesi (Türkiye'de "+90 532 ...", "0532 ..." ve "532 ..." aynı numaradır).
// 7 rakamdan kısa numara karşılaştırılmaz.
func customerPhoneKey(s string) string {
	d := onlyDigits(s)
	if len(d) < 7 {
		return ""
	}
	if len(d) > 10 {
		d = d[len(d)-10:]
	}
	return d
}

// normalizeTaxNumber, vergi numarasını kaydetmeden önce sadeleştirir:
// boşluk ve yaygın ayraçlar (. - /) atılır, harfler büyütülür -- aynı
// numaranın farklı yazımları aynı değer olarak saklanır. Telefon ise
// kullanıcının yazdığı biçimde (okunaklı) saklanır; yalnızca karşılaştırma
// normalize edilir (bkz. customerPhoneKey).
func normalizeTaxNumber(s string) string {
	return strings.ToUpper(strings.Map(func(r rune) rune {
		if unicode.IsSpace(r) || r == '.' || r == '-' || r == '/' {
			return -1
		}
		return r
	}, s))
}

func (s *CustomerService) List(ctx context.Context, organizationID, search string, activeOnly *bool) ([]domain.Customer, error) {
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	search = strings.TrimSpace(search)
	// Telefon araması yalnızca rakamlarla; baştaki 0'lar ("0532") kayıttaki
	// "+90 532" biçimiyle de eşleşsin diye atılır. 3 rakamdan kısa bir
	// parça her numarada geçeceği için telefon eşleştirmesine katılmaz.
	digits := strings.TrimLeft(onlyDigits(search), "0")
	if len(digits) < 3 {
		digits = ""
	}
	rows, err := s.q.ListCustomers(ctx, sqlc.ListCustomersParams{
		OrganizationID: orgID,
		Search:         escapeLikePattern(search),
		SearchDigits:   digits,
		IsActive:       activeOnly,
	})
	if err != nil {
		return nil, err
	}
	out := make([]domain.Customer, len(rows))
	for i, r := range rows {
		out[i] = repository.ToDomainCustomer(r)
	}
	return out, nil
}

func (s *CustomerService) Get(ctx context.Context, id, organizationID string) (*domain.Customer, error) {
	uid, err := repository.StringToUUID(id)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	row, err := s.q.GetCustomerByID(ctx, sqlc.GetCustomerByIDParams{ID: uid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	c := repository.ToDomainCustomer(row)
	return &c, nil
}

// checkCustomerDuplicate, verilen vergi no/telefon anahtarlarıyla çakışan
// (excludeID dışındaki) ilk müşteriyi *DuplicateCustomerError olarak döner.
func (s *CustomerService) checkCustomerDuplicate(ctx context.Context, orgID, excludeID pgtype.UUID, taxKey, phoneKey string) error {
	if taxKey == "" && phoneKey == "" {
		return nil
	}
	rows, err := s.q.FindCustomerDuplicates(ctx, sqlc.FindCustomerDuplicatesParams{
		OrganizationID: orgID, ExcludeID: excludeID, TaxKey: taxKey, PhoneKey: phoneKey,
	})
	if err != nil {
		return err
	}
	if len(rows) == 0 {
		return nil
	}
	// Vergi numarası telefondan daha güçlü bir kimliktir -- ikisi de
	// çakışıyorsa vergi numarası eşleşmesi raporlanır.
	for _, r := range rows {
		if taxKey != "" && customerTaxKey(r.TaxNumber) == taxKey {
			return &DuplicateCustomerError{Existing: repository.ToDomainCustomer(r), Field: "tax_number"}
		}
	}
	return &DuplicateCustomerError{Existing: repository.ToDomainCustomer(rows[0]), Field: "phone"}
}

func (s *CustomerService) Create(ctx context.Context, organizationID string, in CustomerInput) (*domain.Customer, error) {
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	in.Name = strings.TrimSpace(in.Name)
	if in.Name == "" {
		return nil, errors.New("müşteri adı zorunludur")
	}
	in.TaxNumber = normalizeTaxNumber(in.TaxNumber)
	in.Phone = strings.TrimSpace(in.Phone)
	if !in.AllowDuplicate {
		if err := s.checkCustomerDuplicate(ctx, orgID, pgtype.UUID{}, customerTaxKey(in.TaxNumber), customerPhoneKey(in.Phone)); err != nil {
			return nil, err
		}
	}
	row, err := s.q.CreateCustomer(ctx, sqlc.CreateCustomerParams{
		OrganizationID: orgID,
		Name:           in.Name,
		Phone:          in.Phone,
		Email:          strings.TrimSpace(in.Email),
		Address:        strings.TrimSpace(in.Address),
		TaxOffice:      strings.TrimSpace(in.TaxOffice),
		TaxNumber:      in.TaxNumber,
		Notes:          strings.TrimSpace(in.Notes),
	})
	if err != nil {
		return nil, err
	}
	c := repository.ToDomainCustomer(row)
	return &c, nil
}

func (s *CustomerService) Update(ctx context.Context, id, organizationID string, in CustomerInput) (*domain.Customer, error) {
	uid, err := repository.StringToUUID(id)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	in.Name = strings.TrimSpace(in.Name)
	if in.Name == "" {
		return nil, errors.New("müşteri adı zorunludur")
	}
	in.TaxNumber = normalizeTaxNumber(in.TaxNumber)
	in.Phone = strings.TrimSpace(in.Phone)
	if !in.AllowDuplicate {
		current, err := s.q.GetCustomerByID(ctx, sqlc.GetCustomerByIDParams{ID: uid, OrganizationID: orgID})
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return nil, domain.ErrNotFound
			}
			return nil, err
		}
		// Yalnızca DEĞİŞEN anahtar kontrol edilir: bugünden önce oluşmuş
		// bir çift kaydın adresini/notunu düzenlemek uyarıya takılmamalı.
		taxKey, phoneKey := customerTaxKey(in.TaxNumber), customerPhoneKey(in.Phone)
		if taxKey == customerTaxKey(current.TaxNumber) {
			taxKey = ""
		}
		if phoneKey == customerPhoneKey(current.Phone) {
			phoneKey = ""
		}
		if err := s.checkCustomerDuplicate(ctx, orgID, uid, taxKey, phoneKey); err != nil {
			return nil, err
		}
	}
	row, err := s.q.UpdateCustomer(ctx, sqlc.UpdateCustomerParams{
		ID:             uid,
		OrganizationID: orgID,
		Name:           in.Name,
		Phone:          in.Phone,
		Email:          strings.TrimSpace(in.Email),
		Address:        strings.TrimSpace(in.Address),
		TaxOffice:      strings.TrimSpace(in.TaxOffice),
		TaxNumber:      in.TaxNumber,
		Notes:          strings.TrimSpace(in.Notes),
		IsActive:       in.IsActive,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	c := repository.ToDomainCustomer(row)
	return &c, nil
}

// Archive, diğer modüllerdeki desenle tutarlı: müşteri hard-delete
// edilmez (geçmiş tekliflerin customer_id'si referans verebilir),
// yalnızca pasifleştirilir.
func (s *CustomerService) Archive(ctx context.Context, id, organizationID string) error {
	uid, err := repository.StringToUUID(id)
	if err != nil {
		return domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return domain.ErrNotFound
	}
	rows, err := s.q.ArchiveCustomer(ctx, sqlc.ArchiveCustomerParams{ID: uid, OrganizationID: orgID})
	if err != nil {
		return err
	}
	if rows == 0 {
		return domain.ErrNotFound
	}
	return nil
}
