package service

import (
	"context"
	"errors"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/platform/crypto"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

// ErrDuplicateSupplierCode, aynı organizasyon içinde ZATEN kullanılan bir
// kodla yeni bir suppliers satırı oluşturma girişiminde döner (bkz.
// migration 0037 UNIQUE(organization_id, code) -- CostCodeService.
// ErrDuplicateCostCode İLE AYNI desen).
var ErrDuplicateSupplierCode = errors.New("bu tedarikçi kodu bu firmada zaten kullanılıyor")

// ErrSupplierFieldsRequired, code/legal_name boş bırakıldığında döner.
var ErrSupplierFieldsRequired = errors.New("tedarikçi kodu ve unvanı zorunludur")

// ErrSupplierLegalNameRequired: güncellemede unvan boş bırakıldı. Create
// bunu zaten reddediyordu; Update etmiyordu ve unvanı boş bir tedarikçi
// kartı (seçim listelerinde adsız satır) oluşabiliyordu.
var ErrSupplierLegalNameRequired = errors.New("tedarikçi unvanı zorunludur")

// ErrDuplicateSupplierTaxNumber, aynı firmada aynı vergi numarasıyla
// kayıtlı başka bir tedarikçi olduğunda döner (errors.Is ile; ayrıntı
// *DuplicateSupplierTaxNumberError'da). Eskiden kontrol yoktu -- aynı
// tedarikçi farklı kodlarla tekrar açılıp siparişleri/ödemeleri kartlara
// dağılıyordu.
var ErrDuplicateSupplierTaxNumber = errors.New("bu vergi numarasıyla kayıtlı bir tedarikçi zaten var")

type DuplicateSupplierTaxNumberError struct {
	Existing domain.Supplier
}

func (e *DuplicateSupplierTaxNumberError) Error() string {
	msg := "bu vergi numarasıyla kayıtlı bir tedarikçi zaten var: " + e.Existing.Code + " - " + e.Existing.LegalName
	if !e.Existing.IsActive {
		msg += " (arşivde)"
	}
	return msg
}

func (e *DuplicateSupplierTaxNumberError) Is(target error) bool {
	return target == ErrDuplicateSupplierTaxNumber
}

// checkSupplierTaxNumber, vergi numarası (normalize edilmiş anahtarıyla)
// başka bir tedarikçide kayıtlıysa *DuplicateSupplierTaxNumberError döner.
// Boş/çok kısa numara karşılaştırılmaz.
func (s *SupplierService) checkSupplierTaxNumber(ctx context.Context, orgID, excludeID pgtype.UUID, taxNumber string) error {
	key := customerTaxKey(taxNumber)
	if key == "" {
		return nil
	}
	row, err := s.q.FindSupplierByTaxKey(ctx, sqlc.FindSupplierByTaxKeyParams{OrganizationID: orgID, ExcludeID: excludeID, TaxKey: key})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil
		}
		return err
	}
	return &DuplicateSupplierTaxNumberError{Existing: repository.ToDomainSupplier(row)}
}

// SupplierService, suppliers (kuruluş-seviyeli, projeler arası
// PAYLAŞILAN tedarikçi kataloğu) için CRUD işlemlerini yönetir --
// CostCodeService İLE AYNI kardinalite deseni (proje-bağımsız), YENİ bir
// tip icat etmez, aynı iskeleti tekrarlar.
type SupplierService struct {
	pool *pgxpool.Pool
	q    *sqlc.Queries
	box  *crypto.SecretBox
}

func NewSupplierService(pool *pgxpool.Pool, q *sqlc.Queries, box *crypto.SecretBox) *SupplierService {
	return &SupplierService{pool: pool, q: q, box: box}
}

// SupplierInput, IBAN plaintext'i YALNIZCA istek gövdesinde taşır --
// asla domain.Supplier'a kopyalanmaz (bkz. IBANEncSet -- organization_
// commercial_settings İLE AYNI "_set" boolean deseni).
type SupplierInput struct {
	Code        string
	LegalName   string
	TradeName   string
	TaxNumber   string
	TaxOffice   string
	ContactName string
	Email       string
	Phone       string
	Address     string
	City        string
	Country     string
	Specialty   string
	// IBAN, nil ise DEĞİŞTİRİLMEZ (Update'te); boş string ise TEMİZLENİR;
	// dolu ise şifrelenip YENİDEN yazılır (organization_commercial_
	// settings.IBAN alanının AYNI üç-durumlu semantiği, bkz. onboarding_
	// service.go).
	IBAN   *string
	Notes  string
	UserID string
}

func (s *SupplierService) List(ctx context.Context, organizationID string) ([]domain.Supplier, error) {
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, err
	}
	rows, err := s.q.ListSuppliers(ctx, orgID)
	if err != nil {
		return nil, err
	}
	out := make([]domain.Supplier, len(rows))
	for i, r := range rows {
		out[i] = repository.ToDomainSupplier(r)
	}
	return out, nil
}

func (s *SupplierService) Get(ctx context.Context, id, organizationID string) (*domain.Supplier, error) {
	sid, err := repository.StringToUUID(id)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, err
	}
	row, err := s.q.GetSupplier(ctx, sqlc.GetSupplierParams{ID: sid, OrganizationID: orgID})
	if err != nil {
		return nil, domain.ErrNotFound
	}
	out := repository.ToDomainSupplier(row)
	return &out, nil
}

func (s *SupplierService) Create(ctx context.Context, organizationID string, in SupplierInput) (*domain.Supplier, error) {
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, err
	}
	in.Code = strings.TrimSpace(in.Code)
	in.LegalName = strings.TrimSpace(in.LegalName)
	if in.Code == "" || in.LegalName == "" {
		return nil, ErrSupplierFieldsRequired
	}
	in.TaxNumber = normalizeTaxNumber(in.TaxNumber)
	if err := s.checkSupplierTaxNumber(ctx, orgID, pgtype.UUID{}, in.TaxNumber); err != nil {
		return nil, err
	}
	ibanEnc, err := s.encryptIBAN(in.IBAN, "")
	if err != nil {
		return nil, err
	}

	row, err := s.q.CreateSupplier(ctx, sqlc.CreateSupplierParams{
		OrganizationID: orgID, Code: in.Code, LegalName: in.LegalName, TradeName: strings.TrimSpace(in.TradeName),
		TaxNumber: in.TaxNumber, TaxOffice: strings.TrimSpace(in.TaxOffice),
		ContactName: strings.TrimSpace(in.ContactName), Email: strings.TrimSpace(in.Email), Phone: strings.TrimSpace(in.Phone),
		Address: in.Address, City: strings.TrimSpace(in.City), Country: strings.TrimSpace(in.Country),
		IbanEnc: ibanEnc, Notes: in.Notes, CreatedBy: actorUUID(in.UserID), Specialty: strings.TrimSpace(in.Specialty),
	})
	if err != nil {
		if isUniqueViolation(err) {
			return nil, ErrDuplicateSupplierCode
		}
		return nil, err
	}
	if err := logOrgEvent(ctx, s.q, orgID, domain.OrgEventSupplierCreated, actorUUID(in.UserID),
		map[string]any{"supplier_id": row.ID.String(), "code": row.Code}); err != nil {
		return nil, err
	}
	out := repository.ToDomainSupplier(row)
	return &out, nil
}

func (s *SupplierService) Update(ctx context.Context, id, organizationID string, in SupplierInput) (*domain.Supplier, error) {
	sid, err := repository.StringToUUID(id)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, err
	}
	in.LegalName = strings.TrimSpace(in.LegalName)
	if in.LegalName == "" {
		return nil, ErrSupplierLegalNameRequired
	}
	current, err := s.q.GetSupplier(ctx, sqlc.GetSupplierParams{ID: sid, OrganizationID: orgID})
	if err != nil {
		return nil, domain.ErrNotFound
	}
	in.TaxNumber = normalizeTaxNumber(in.TaxNumber)
	// Yalnızca vergi numarası DEĞİŞTİYSE kontrol edilir: bugünden önce
	// oluşmuş bir çift kaydın başka bir alanını düzenlemek engellenmemeli.
	if customerTaxKey(in.TaxNumber) != customerTaxKey(current.TaxNumber) {
		if err := s.checkSupplierTaxNumber(ctx, orgID, sid, in.TaxNumber); err != nil {
			return nil, err
		}
	}
	ibanEnc, err := s.encryptIBAN(in.IBAN, current.IbanEnc)
	if err != nil {
		return nil, err
	}
	row, err := s.q.UpdateSupplier(ctx, sqlc.UpdateSupplierParams{
		ID: sid, OrganizationID: orgID,
		LegalName: in.LegalName, TradeName: strings.TrimSpace(in.TradeName),
		TaxNumber: in.TaxNumber, TaxOffice: strings.TrimSpace(in.TaxOffice),
		ContactName: strings.TrimSpace(in.ContactName), Email: strings.TrimSpace(in.Email), Phone: strings.TrimSpace(in.Phone),
		Address: in.Address, City: strings.TrimSpace(in.City), Country: strings.TrimSpace(in.Country),
		IbanEnc: ibanEnc, Notes: in.Notes, Specialty: strings.TrimSpace(in.Specialty),
	})
	if err != nil {
		return nil, err
	}
	if err := logOrgEvent(ctx, s.q, orgID, domain.OrgEventSupplierUpdated, actorUUID(in.UserID),
		map[string]any{"supplier_id": id}); err != nil {
		return nil, err
	}
	out := repository.ToDomainSupplier(row)
	return &out, nil
}

// Archive, HARD DELETE DEĞİLDİR (CostCodeService.Archive İLE AYNI ilke)
// -- geçmiş PR/RFQ/teklif/PO kayıtları bu tedarikçiye referans veriyor
// olabilir; yalnızca is_active=false yapar, YENİ seçim listelerinden
// çıkarma kararı istemci tarafındadır.
func (s *SupplierService) Archive(ctx context.Context, id, organizationID, userID string) error {
	sid, err := repository.StringToUUID(id)
	if err != nil {
		return domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return err
	}
	n, err := s.q.ArchiveSupplier(ctx, sqlc.ArchiveSupplierParams{ID: sid, OrganizationID: orgID})
	if err != nil {
		return err
	}
	if n == 0 {
		return domain.ErrNotFound
	}
	return logOrgEvent(ctx, s.q, orgID, domain.OrgEventSupplierArchived, actorUUID(userID), map[string]any{"supplier_id": id})
}

func (s *SupplierService) Reactivate(ctx context.Context, id, organizationID, userID string) error {
	sid, err := repository.StringToUUID(id)
	if err != nil {
		return domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return err
	}
	n, err := s.q.ReactivateSupplier(ctx, sqlc.ReactivateSupplierParams{ID: sid, OrganizationID: orgID})
	if err != nil {
		return err
	}
	if n == 0 {
		return domain.ErrNotFound
	}
	return logOrgEvent(ctx, s.q, orgID, domain.OrgEventSupplierReactivated, actorUUID(userID), map[string]any{"supplier_id": id})
}

// encryptIBAN, onboarding_service.go'daki IBAN üç-durumlu (nil=değiştirme,
// boş=temizle, dolu=şifrele) deseninin AYNISIdır -- yeni bir şifreleme
// ilkesi İCAT EDİLMEDİ (internal/platform/crypto.SecretBox, AES-256-GCM).
func (s *SupplierService) encryptIBAN(iban *string, current string) (string, error) {
	if iban == nil {
		return current, nil
	}
	trimmed := strings.TrimSpace(*iban)
	if trimmed == "" {
		return "", nil
	}
	return s.box.Encrypt(trimmed)
}
