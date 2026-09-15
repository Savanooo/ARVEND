package handler

import (
	"errors"
	"net/http"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/httpapi/middleware"
	"github.com/Savanooo/ARVEND/backend/internal/platform/httpjson"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

// OnboardingHandler, hem ilk-giriş onboarding sihirbazının (/onboarding/*,
// her adımda ileri bir sonraki adıma geçer) HEM DE onboarding sonrası
// "Firma Ayarları" düzenleme ekranının (/organization/settings/*, aynı
// adımlar ama serbest sırayla düzenlenebilir) TEK ortak handler'ıdır --
// ikisi de AYNI OnboardingService metodlarını çağırır (advancePast zaten
// tamamlanmış bir organizasyonda no-op'tur), mantığı iki kez yazmanın bir
// gerekçesi yok. Router.go bu handler'ı iki farklı path altında mount eder.
type OnboardingHandler struct {
	svc *service.OnboardingService
}

func NewOnboardingHandler(svc *service.OnboardingService) *OnboardingHandler {
	return &OnboardingHandler{svc: svc}
}

type onboardingProfileResponse struct {
	AuthorizedPerson string `json:"authorized_person"`
	Phone            string `json:"phone"`
	Email            string `json:"email"`
	Website          string `json:"website"`
	LogoObjectKey    string `json:"logo_object_key"`
	LegalName        string `json:"legal_name"`
	TaxOffice        string `json:"tax_office"`
	TaxNumber        string `json:"tax_number"`
	InvoiceAddress   string `json:"invoice_address"`
	City             string `json:"city"`
	District         string `json:"district"`
	Country          string `json:"country"`
	BusinessType     string `json:"business_type"`
}

type onboardingCommercialResponse struct {
	DefaultCurrency      string  `json:"default_currency"`
	DefaultVATRate       float64 `json:"default_vat_rate"`
	OfferPrefix          string  `json:"offer_prefix"`
	OfferValidityDays    int     `json:"offer_validity_days"`
	DefaultOfferFooter   string  `json:"default_offer_footer"`
	DefaultPaymentTerms  string  `json:"default_payment_terms"`
	DefaultDeliveryTerms string  `json:"default_delivery_terms"`
	BankName             string  `json:"bank_name"`
	AccountHolder        string  `json:"account_holder"`
	IBANSet              bool    `json:"iban_set"`
	PaymentDueDays       *int    `json:"payment_due_days,omitempty"`
}

type onboardingStateResponse struct {
	OnboardingCompleted bool                         `json:"onboarding_completed"`
	OnboardingStep      string                       `json:"onboarding_step"`
	Profile             onboardingProfileResponse    `json:"profile"`
	Commercial          onboardingCommercialResponse `json:"commercial"`
}

func toOnboardingStateResponse(st service.OnboardingState) onboardingStateResponse {
	return onboardingStateResponse{
		OnboardingCompleted: st.OnboardingCompleted,
		OnboardingStep:      string(st.OnboardingStep),
		Profile: onboardingProfileResponse{
			AuthorizedPerson: st.Profile.AuthorizedPerson, Phone: st.Profile.Phone, Email: st.Profile.Email,
			Website: st.Profile.Website, LogoObjectKey: st.Profile.LogoObjectKey, LegalName: st.Profile.LegalName,
			TaxOffice: st.Profile.TaxOffice, TaxNumber: st.Profile.TaxNumber, InvoiceAddress: st.Profile.InvoiceAddress,
			City: st.Profile.City, District: st.Profile.District, Country: st.Profile.Country,
			BusinessType: st.Profile.BusinessType,
		},
		Commercial: onboardingCommercialResponse{
			DefaultCurrency: st.Commercial.DefaultCurrency, DefaultVATRate: st.Commercial.DefaultVATRate,
			OfferPrefix: st.Commercial.OfferPrefix, OfferValidityDays: st.Commercial.OfferValidityDays,
			DefaultOfferFooter: st.Commercial.DefaultOfferFooter, DefaultPaymentTerms: st.Commercial.DefaultPaymentTerms,
			DefaultDeliveryTerms: st.Commercial.DefaultDeliveryTerms, BankName: st.Commercial.BankName,
			AccountHolder: st.Commercial.AccountHolder, IBANSet: st.Commercial.IBANSet, PaymentDueDays: st.Commercial.PaymentDueDays,
		},
	}
}

func (h *OnboardingHandler) GetState(w http.ResponseWriter, r *http.Request) {
	orgID, ok := middleware.OrganizationIDFromContext(r.Context())
	if !ok || orgID == "" {
		httpjson.Error(w, http.StatusForbidden, "bu uç bir organizasyon hesabı gerektirir")
		return
	}
	st, err := h.svc.GetState(r.Context(), orgID)
	if err != nil {
		h.writeOnboardingError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toOnboardingStateResponse(*st))
}

type companyStepRequest struct {
	AuthorizedPerson string `json:"authorized_person"`
	Phone            string `json:"phone"`
	Email            string `json:"email"`
	Website          string `json:"website"`
	City             string `json:"city"`
	District         string `json:"district"`
	Country          string `json:"country"`
}

func (h *OnboardingHandler) SaveCompany(w http.ResponseWriter, r *http.Request) {
	var req companyStepRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	st, err := h.svc.SaveCompanyStep(r.Context(), orgID, service.CompanyStepInput{
		AuthorizedPerson: req.AuthorizedPerson, Phone: req.Phone, Email: req.Email,
		Website: req.Website, City: req.City, District: req.District, Country: req.Country,
	})
	if err != nil {
		h.writeOnboardingError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toOnboardingStateResponse(*st))
}

type billingStepRequest struct {
	LegalName      string `json:"legal_name"`
	TaxOffice      string `json:"tax_office"`
	TaxNumber      string `json:"tax_number"`
	InvoiceAddress string `json:"invoice_address"`
}

func (h *OnboardingHandler) SaveBilling(w http.ResponseWriter, r *http.Request) {
	var req billingStepRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	st, err := h.svc.SaveBillingStep(r.Context(), orgID, service.BillingStepInput{
		LegalName: req.LegalName, TaxOffice: req.TaxOffice, TaxNumber: req.TaxNumber, InvoiceAddress: req.InvoiceAddress,
	})
	if err != nil {
		h.writeOnboardingError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toOnboardingStateResponse(*st))
}

type offersStepRequest struct {
	DefaultCurrency      string  `json:"default_currency"`
	DefaultVATRate       float64 `json:"default_vat_rate"`
	OfferPrefix          string  `json:"offer_prefix"`
	OfferValidityDays    int     `json:"offer_validity_days"`
	DefaultOfferFooter   string  `json:"default_offer_footer"`
	DefaultPaymentTerms  string  `json:"default_payment_terms"`
	DefaultDeliveryTerms string  `json:"default_delivery_terms"`
}

func (h *OnboardingHandler) SaveOffers(w http.ResponseWriter, r *http.Request) {
	var req offersStepRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	st, err := h.svc.SaveOffersStep(r.Context(), orgID, service.OffersStepInput{
		DefaultCurrency: req.DefaultCurrency, DefaultVATRate: req.DefaultVATRate, OfferPrefix: req.OfferPrefix,
		OfferValidityDays: req.OfferValidityDays, DefaultOfferFooter: req.DefaultOfferFooter,
		DefaultPaymentTerms: req.DefaultPaymentTerms, DefaultDeliveryTerms: req.DefaultDeliveryTerms,
	})
	if err != nil {
		h.writeOnboardingError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toOnboardingStateResponse(*st))
}

type financeStepRequest struct {
	BankName       string  `json:"bank_name"`
	AccountHolder  string  `json:"account_holder"`
	IBAN           *string `json:"iban"` // nil = mevcut IBAN korunur, "" = temizle
	PaymentDueDays *int    `json:"payment_due_days"`
}

func (h *OnboardingHandler) SaveFinance(w http.ResponseWriter, r *http.Request) {
	var req financeStepRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	st, err := h.svc.SaveFinanceStep(r.Context(), orgID, service.FinanceStepInput{
		BankName: req.BankName, AccountHolder: req.AccountHolder, IBAN: req.IBAN, PaymentDueDays: req.PaymentDueDays,
	})
	if err != nil {
		h.writeOnboardingError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toOnboardingStateResponse(*st))
}

type businessStepRequest struct {
	BusinessType  string  `json:"business_type"`
	LogoObjectKey *string `json:"logo_object_key"`
}

func (h *OnboardingHandler) SaveBusiness(w http.ResponseWriter, r *http.Request) {
	var req businessStepRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	st, err := h.svc.SaveBusinessStep(r.Context(), orgID, service.BusinessStepInput{
		BusinessType: req.BusinessType, LogoObjectKey: req.LogoObjectKey,
	})
	if err != nil {
		h.writeOnboardingError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toOnboardingStateResponse(*st))
}

func (h *OnboardingHandler) writeOnboardingError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, domain.ErrNotFound):
		httpjson.Error(w, http.StatusNotFound, "organizasyon bulunamadı")
	default:
		httpjson.Error(w, http.StatusBadRequest, err.Error())
	}
}
