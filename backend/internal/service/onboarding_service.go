package service

import (
	"context"
	"errors"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/platform/crypto"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

// OnboardingService, ilk-giriş onboarding sihirbazının (5 adım: Firma,
// Resmi/Fatura, Teklif, Finans, İşletme+Tamamlama) server-authoritative
// durumunu yönetir -- web ve mobil AYNI state'i (organizations.onboarding_
// step/onboarding_completed + organization_profile/organization_commercial_
// settings) okur, ayrı bir yerel state tutmazlar.
//
// organization_profile 3 adıma yayılır (Firma/Resmi-Fatura/İşletme),
// organization_commercial_settings 2 adıma (Teklif/Finans) -- bkz. migration
// 0032 yorumu. Her adım UPSERT tam satırı yeniden yazdığı için (sqlc'nin
// "tek sorgu, tüm kolonlar" deseni, smtp_settings ile aynı), her Save*
// metodu önce MEVCUT satırı okur ve yalnızca kendi adımının alanlarını
// değiştirip geri yazar -- başka bir adımın daha önce kaydettiği veriyi
// asla sessizce sıfırlamaz.
type OnboardingService struct {
	q   *sqlc.Queries
	box *crypto.SecretBox
}

func NewOnboardingService(q *sqlc.Queries, box *crypto.SecretBox) *OnboardingService {
	return &OnboardingService{q: q, box: box}
}

type OnboardingState struct {
	OnboardingCompleted bool
	OnboardingStep      domain.OnboardingStep
	Profile             domain.OrganizationProfile
	Commercial          domain.OrganizationCommercialSettings
}

func (s *OnboardingService) GetState(ctx context.Context, organizationID string) (*OnboardingState, error) {
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	orgRow, err := s.q.GetOrganizationByID(ctx, orgID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	profileRow, err := s.currentProfile(ctx, orgID)
	if err != nil {
		return nil, err
	}
	commercialRow, err := s.currentCommercial(ctx, orgID)
	if err != nil {
		return nil, err
	}
	commercial := repository.ToDomainOrganizationCommercialSettings(commercialRow)
	commercial.IBAN = "" // ASLA API yanıtına yazılmaz -- IBANSet zaten şifreli alanın dolu olup olmadığını taşır
	return &OnboardingState{
		OnboardingCompleted: orgRow.OnboardingCompleted,
		OnboardingStep:      domain.OnboardingStep(orgRow.OnboardingStep),
		Profile:             repository.ToDomainOrganizationProfile(profileRow),
		Commercial:          commercial,
	}, nil
}

type CompanyStepInput struct {
	AuthorizedPerson string
	Phone            string
	Email            string
	Website          string
	City             string
	District         string
	Country          string
}

// SaveCompanyStep, Adım 1 "Firma"yı kaydeder.
func (s *OnboardingService) SaveCompanyStep(ctx context.Context, organizationID string, in CompanyStepInput) (*OnboardingState, error) {
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	row, err := s.currentProfile(ctx, orgID)
	if err != nil {
		return nil, err
	}
	row.AuthorizedPerson = strings.TrimSpace(in.AuthorizedPerson)
	row.Phone = strings.TrimSpace(in.Phone)
	row.Email = strings.TrimSpace(in.Email)
	row.Website = strings.TrimSpace(in.Website)
	row.City = strings.TrimSpace(in.City)
	row.District = strings.TrimSpace(in.District)
	if c := strings.TrimSpace(in.Country); c != "" {
		row.Country = c
	}
	if row.AuthorizedPerson == "" {
		return nil, errors.New("yetkili kişi zorunludur")
	}
	if _, err := s.q.UpsertOrganizationProfile(ctx, sqlc.UpsertOrganizationProfileParams{
		OrganizationID: orgID, AuthorizedPerson: row.AuthorizedPerson, Phone: row.Phone, Email: row.Email,
		Website: row.Website, LogoObjectKey: row.LogoObjectKey, LegalName: row.LegalName, TaxOffice: row.TaxOffice,
		TaxNumber: row.TaxNumber, InvoiceAddress: row.InvoiceAddress, City: row.City, District: row.District,
		Country: row.Country, BusinessType: row.BusinessType,
	}); err != nil {
		return nil, err
	}
	if err := s.advancePast(ctx, orgID, domain.OnboardingStepCompany); err != nil {
		return nil, err
	}
	return s.GetState(ctx, organizationID)
}

type BillingStepInput struct {
	LegalName      string
	TaxOffice      string
	TaxNumber      string
	InvoiceAddress string
}

// SaveBillingStep, Adım 2 "Resmi/Fatura"yı kaydeder.
func (s *OnboardingService) SaveBillingStep(ctx context.Context, organizationID string, in BillingStepInput) (*OnboardingState, error) {
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	row, err := s.currentProfile(ctx, orgID)
	if err != nil {
		return nil, err
	}
	row.LegalName = strings.TrimSpace(in.LegalName)
	row.TaxOffice = strings.TrimSpace(in.TaxOffice)
	row.TaxNumber = strings.TrimSpace(in.TaxNumber)
	row.InvoiceAddress = strings.TrimSpace(in.InvoiceAddress)
	if row.LegalName == "" || row.TaxNumber == "" {
		return nil, errors.New("resmi unvan ve vergi numarası zorunludur")
	}
	if _, err := s.q.UpsertOrganizationProfile(ctx, sqlc.UpsertOrganizationProfileParams{
		OrganizationID: orgID, AuthorizedPerson: row.AuthorizedPerson, Phone: row.Phone, Email: row.Email,
		Website: row.Website, LogoObjectKey: row.LogoObjectKey, LegalName: row.LegalName, TaxOffice: row.TaxOffice,
		TaxNumber: row.TaxNumber, InvoiceAddress: row.InvoiceAddress, City: row.City, District: row.District,
		Country: row.Country, BusinessType: row.BusinessType,
	}); err != nil {
		return nil, err
	}
	if err := s.advancePast(ctx, orgID, domain.OnboardingStepBilling); err != nil {
		return nil, err
	}
	return s.GetState(ctx, organizationID)
}

type OffersStepInput struct {
	DefaultCurrency      string
	DefaultVATRate       float64
	OfferPrefix          string
	OfferValidityDays    int
	DefaultOfferFooter   string
	DefaultPaymentTerms  string
	DefaultDeliveryTerms string
}

// SaveOffersStep, Adım 3 "Teklif" varsayılanlarını kaydeder.
func (s *OnboardingService) SaveOffersStep(ctx context.Context, organizationID string, in OffersStepInput) (*OnboardingState, error) {
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	row, err := s.currentCommercial(ctx, orgID)
	if err != nil {
		return nil, err
	}
	currency := strings.TrimSpace(in.DefaultCurrency)
	if currency == "" {
		currency = "TRY"
	}
	prefix := strings.TrimSpace(in.OfferPrefix)
	if prefix == "" {
		prefix = "TKF"
	}
	validityDays := in.OfferValidityDays
	if validityDays <= 0 {
		validityDays = 30
	}
	row.DefaultCurrency = currency
	row.DefaultVatRate = repository.Float64ToNumeric(in.DefaultVATRate)
	row.OfferPrefix = prefix
	row.OfferValidityDays = int32(validityDays)
	row.DefaultOfferFooter = strings.TrimSpace(in.DefaultOfferFooter)
	row.DefaultPaymentTerms = strings.TrimSpace(in.DefaultPaymentTerms)
	row.DefaultDeliveryTerms = strings.TrimSpace(in.DefaultDeliveryTerms)
	if _, err := s.q.UpsertOrganizationCommercialSettings(ctx, sqlc.UpsertOrganizationCommercialSettingsParams{
		OrganizationID: orgID, DefaultCurrency: row.DefaultCurrency, DefaultVatRate: row.DefaultVatRate,
		OfferPrefix: row.OfferPrefix, OfferValidityDays: row.OfferValidityDays, DefaultOfferFooter: row.DefaultOfferFooter,
		DefaultPaymentTerms: row.DefaultPaymentTerms, DefaultDeliveryTerms: row.DefaultDeliveryTerms,
		BankName: row.BankName, AccountHolder: row.AccountHolder, IbanEnc: row.IbanEnc, PaymentDueDays: row.PaymentDueDays,
	}); err != nil {
		return nil, err
	}
	if err := s.advancePast(ctx, orgID, domain.OnboardingStepOffers); err != nil {
		return nil, err
	}
	return s.GetState(ctx, organizationID)
}

type FinanceStepInput struct {
	BankName       string
	AccountHolder  string
	IBAN           *string // nil = mevcut IBAN korunur (SmtpSettings.Password ile aynı konvansiyon)
	PaymentDueDays *int
}

// SaveFinanceStep, Adım 4 "Finans"ı kaydeder. IBAN, smtp şifresiyle AYNI
// SecretBox ile şifrelenir -- yanıt hiçbir zaman plaintext IBAN taşımaz.
func (s *OnboardingService) SaveFinanceStep(ctx context.Context, organizationID string, in FinanceStepInput) (*OnboardingState, error) {
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	row, err := s.currentCommercial(ctx, orgID)
	if err != nil {
		return nil, err
	}
	row.BankName = strings.TrimSpace(in.BankName)
	row.AccountHolder = strings.TrimSpace(in.AccountHolder)
	row.PaymentDueDays = nil
	if in.PaymentDueDays != nil {
		v := int32(*in.PaymentDueDays)
		row.PaymentDueDays = &v
	}
	if in.IBAN != nil {
		iban := strings.TrimSpace(*in.IBAN)
		if iban == "" {
			row.IbanEnc = ""
		} else {
			enc, err := s.box.Encrypt(iban)
			if err != nil {
				return nil, err
			}
			row.IbanEnc = enc
		}
	}
	if _, err := s.q.UpsertOrganizationCommercialSettings(ctx, sqlc.UpsertOrganizationCommercialSettingsParams{
		OrganizationID: orgID, DefaultCurrency: row.DefaultCurrency, DefaultVatRate: row.DefaultVatRate,
		OfferPrefix: row.OfferPrefix, OfferValidityDays: row.OfferValidityDays, DefaultOfferFooter: row.DefaultOfferFooter,
		DefaultPaymentTerms: row.DefaultPaymentTerms, DefaultDeliveryTerms: row.DefaultDeliveryTerms,
		BankName: row.BankName, AccountHolder: row.AccountHolder, IbanEnc: row.IbanEnc, PaymentDueDays: row.PaymentDueDays,
	}); err != nil {
		return nil, err
	}
	if err := s.advancePast(ctx, orgID, domain.OnboardingStepFinance); err != nil {
		return nil, err
	}
	return s.GetState(ctx, organizationID)
}

type BusinessStepInput struct {
	BusinessType  string
	LogoObjectKey *string // nil = mevcut logo korunur
}

// SaveBusinessStep, Adım 5 "İşletme"yi kaydeder VE onboarding'i TAMAMLAR
// (spec: "İşletme+Tamamlama" tek adım). CompleteOnboarding sorgusu
// idempotenttir -- bu adım tekrar çağrılırsa (ör. kullanıcı geri gelip
// bilgilerini günceller) yeniden tamamlamak zararsızdır.
func (s *OnboardingService) SaveBusinessStep(ctx context.Context, organizationID string, in BusinessStepInput) (*OnboardingState, error) {
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	businessType := strings.TrimSpace(in.BusinessType)
	if !domain.ValidBusinessType(businessType) {
		return nil, errors.New("geçersiz işletme türü")
	}
	row, err := s.currentProfile(ctx, orgID)
	if err != nil {
		return nil, err
	}
	row.BusinessType = businessType
	if in.LogoObjectKey != nil {
		row.LogoObjectKey = strings.TrimSpace(*in.LogoObjectKey)
	}
	if _, err := s.q.UpsertOrganizationProfile(ctx, sqlc.UpsertOrganizationProfileParams{
		OrganizationID: orgID, AuthorizedPerson: row.AuthorizedPerson, Phone: row.Phone, Email: row.Email,
		Website: row.Website, LogoObjectKey: row.LogoObjectKey, LegalName: row.LegalName, TaxOffice: row.TaxOffice,
		TaxNumber: row.TaxNumber, InvoiceAddress: row.InvoiceAddress, City: row.City, District: row.District,
		Country: row.Country, BusinessType: row.BusinessType,
	}); err != nil {
		return nil, err
	}
	if _, err := s.q.CompleteOnboarding(ctx, orgID); err != nil {
		return nil, err
	}
	return s.GetState(ctx, organizationID)
}

func (s *OnboardingService) currentProfile(ctx context.Context, orgID pgtype.UUID) (sqlc.OrganizationProfile, error) {
	row, err := s.q.GetOrganizationProfile(ctx, orgID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return sqlc.OrganizationProfile{OrganizationID: orgID, Country: "Türkiye"}, nil
		}
		return sqlc.OrganizationProfile{}, err
	}
	return row, nil
}

func (s *OnboardingService) currentCommercial(ctx context.Context, orgID pgtype.UUID) (sqlc.OrganizationCommercialSetting, error) {
	row, err := s.q.GetOrganizationCommercialSettings(ctx, orgID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return sqlc.OrganizationCommercialSetting{
				OrganizationID: orgID, DefaultCurrency: "TRY", DefaultVatRate: repository.Float64ToNumeric(20),
				OfferPrefix: "TKF", OfferValidityDays: 30,
			}, nil
		}
		return sqlc.OrganizationCommercialSetting{}, err
	}
	return row, nil
}

// advancePast, yalnızca organizasyon HÂLÂ step'te veya step'ten ÖNCEDEYSE
// bir sonraki adıma ilerletir -- daha ileri bir adımdaki (veya tamamlanmış)
// bir organizasyon, önceki bir adımı düzenlerse onboarding_step ASLA
// geriletilmez.
func (s *OnboardingService) advancePast(ctx context.Context, orgID pgtype.UUID, step domain.OnboardingStep) error {
	orgRow, err := s.q.GetOrganizationByID(ctx, orgID)
	if err != nil {
		return err
	}
	current := domain.OnboardingStep(orgRow.OnboardingStep)
	if current.Index() > step.Index() {
		return nil
	}
	_, err = s.q.AdvanceOnboardingStep(ctx, sqlc.AdvanceOnboardingStepParams{ID: orgID, OnboardingStep: string(step.Next())})
	return err
}
