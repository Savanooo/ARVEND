package service

import (
	"errors"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
)

// Satın alma / taşeron / maliyet girişlerinin doğrulama hataları (2026-10
// denetimi). Önceden boş başlık/açıklama, geçersiz değişiklik tipi ve sıfır
// miktar hep ErrInvalidAmount ("tutar sıfırdan büyük olmalıdır") dönüyordu
// -- kullanıcı neyi düzelteceğini anlayamıyordu; negatif/aşırı oranlar ise
// DB CHECK'ine takılıp 500 oluyordu ya da (teminat %100-999) net
// ödenecek tutarı negatife düşürüyordu.
var (
	ErrTitleRequired           = errors.New("başlık zorunludur")
	ErrItemDescriptionRequired = errors.New("her kalemin açıklaması zorunludur")
	ErrInvalidQuantity         = errors.New("miktar sıfırdan büyük olmalıdır")
	ErrInvalidUnitPrice        = errors.New("birim fiyat sıfırdan büyük olmalıdır")
	ErrInvalidChangeType       = errors.New("değişiklik tipi ek iş (addition) ya da eksiltme (deduction) olmalıdır")
	ErrInvalidRetentionPercent = errors.New("teminat kesintisi oranı 0 ile 100 arasında olmalıdır")
	ErrInvalidTaxRate          = errors.New("KDV oranı 0 ile 100 arasında olmalıdır")
	ErrNegativeDeduction       = errors.New("avans mahsubu ve diğer kesintiler negatif olamaz")
	ErrNegativeDiscount        = errors.New("indirim negatif olamaz")
	ErrNegativeAdvance         = errors.New("avans tutarı negatif olamaz")
	ErrNegativeProgress        = errors.New("hakediş kalemi tutarı negatif olamaz")
	ErrQuotationDuplicateItem  = errors.New("aynı RFQ kalemi bir teklifte birden fazla kez yer alamaz")
)

// NotFoundError, errors.Is ile domain.ErrNotFound'a eşlenir (404), ama
// kullanıcıya NEYİN bulunamadığını söyler -- önceden istekteki geçersiz bir
// bütçe kalemi/tedarikçi/SOV kalemi de "proje bulunamadı" görünüyordu.
type NotFoundError struct{ What string }

func (e *NotFoundError) Error() string { return e.What + " bulunamadı" }

func (e *NotFoundError) Is(target error) bool { return target == domain.ErrNotFound }

var (
	ErrBudgetLineRefNotFound      error = &NotFoundError{What: "seçilen bütçe kalemi bu projede"}
	ErrSupplierRefNotFound        error = &NotFoundError{What: "seçilen tedarikçi"}
	ErrSOVItemRefNotFound         error = &NotFoundError{What: "seçilen SOV kalemi bu taşeron sözleşmesinde"}
	ErrRFQItemRefNotFound         error = &NotFoundError{What: "seçilen RFQ kalemi"}
	ErrSourceRFQRefNotFound       error = &NotFoundError{What: "kaynak RFQ bu projede"}
	ErrSourceQuotationNotFound    error = &NotFoundError{What: "kaynak teklif bu projede"}
	ErrPurchaseRequestRefNotFound error = &NotFoundError{What: "seçilen satın alma talebi bu projede"}
)

// validatePercent, 0-100 aralığındaki bir oranı doğrular.
func validatePercent(v float64, errOut error) error {
	if v < 0 || v > 100 {
		return errOut
	}
	return nil
}

// validateSubcontractTerms, sözleşmenin teminat oranını (0-100) ve avans
// tutarını (>= 0) doğrular -- DB CHECK'i yalnızca savunma derinliğidir.
func validateSubcontractTerms(in SubcontractInput) error {
	if in.RetentionPercent != nil {
		if err := validatePercent(*in.RetentionPercent, ErrInvalidRetentionPercent); err != nil {
			return err
		}
	}
	if in.AdvanceAmount != nil && *in.AdvanceAmount < 0 {
		return ErrNegativeAdvance
	}
	return nil
}

// validateProgressClaimTerms: teminat 0-100 (önceden %100-999 kabul edilip
// net ödenecek tutarı negatife düşürüyordu; 1000 ve üstü numeric(5,2)
// taşmasıyla 500 oluyordu), avans mahsubu/diğer kesintiler >= 0.
func validateProgressClaimTerms(in ProgressClaimInput) error {
	if in.RetentionPercent != nil {
		if err := validatePercent(*in.RetentionPercent, ErrInvalidRetentionPercent); err != nil {
			return err
		}
	}
	if in.AdvanceRecoveryAmount < 0 || in.OtherDeductions < 0 {
		return ErrNegativeDeduction
	}
	return nil
}

// validateQuotationTerms: indirim >= 0, KDV 0-100.
func validateQuotationTerms(in QuotationInput) error {
	if in.Discount < 0 {
		return ErrNegativeDiscount
	}
	return validatePercent(in.TaxRate, ErrInvalidTaxRate)
}
