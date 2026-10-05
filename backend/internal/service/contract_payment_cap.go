package service

import (
	"errors"
	"fmt"
	"strings"

	"github.com/shopspring/decimal"
)

// ErrPaymentExceedsContract: taşerona ödenen toplam sözleşme bedelini
// aşamaz (sahada 2026-10: 1.000 TL'lik sözleşmeye 21.000 TL ödeme
// girilebilmişti). errors.Is hedefi; ayrıntı PaymentExceedsContractError'da.
var ErrPaymentExceedsContract = errors.New("ödeme sözleşme bedelini aşıyor")

// PaymentExceedsContractError, kullanıcıya rakamlarla ne yapacağını söyler.
type PaymentExceedsContractError struct {
	Contract decimal.Decimal // sözleşme bedeli (yeni modülde onaylı değişiklikler dahil güncel bedel)
	Paid     decimal.Decimal // şimdiye kadarki geçerli (iptal edilmemiş) ödemeler
	Amount   decimal.Decimal // reddedilen ödeme
	Currency string
	Hint     string // fazlası için ne yapılmalı
}

func (e *PaymentExceedsContractError) Error() string {
	if e.Contract.Sign() <= 0 {
		return "taşeronun sözleşme bedeli girilmemiş; ödeme kaydetmeden önce " + e.Hint
	}
	remaining := e.Contract.Sub(e.Paid)
	if remaining.Sign() < 0 {
		remaining = decimal.Zero
	}
	return fmt.Sprintf("ödeme sözleşme bedelini aşıyor: sözleşme %s, şimdiye kadar ödenen %s, bu ödeme %s. En fazla %s ödenebilir; fazlası için %s.",
		formatMoneyCur(e.Contract, e.Currency), formatMoneyCur(e.Paid, e.Currency),
		formatMoneyCur(e.Amount, e.Currency), formatMoneyCur(remaining, e.Currency), e.Hint)
}

func (e *PaymentExceedsContractError) Unwrap() error { return ErrPaymentExceedsContract }

// checkWithinContract: paid + amount <= contract değilse hata. Kuruş
// hesabı decimal'dir (float toplama 0,01 sapma üretebilirdi).
func checkWithinContract(contract, paid decimal.Decimal, amount float64, currency, hint string) error {
	a := decimal.NewFromFloat(amount).Round(2)
	if contract.Sign() > 0 && paid.Add(a).Cmp(contract) <= 0 {
		return nil
	}
	return &PaymentExceedsContractError{Contract: contract, Paid: paid, Amount: a, Currency: currency, Hint: hint}
}

func formatMoneyCur(d decimal.Decimal, currency string) string {
	f, _ := d.Float64()
	s := FormatTL(f)
	if currency != "" && currency != "TRY" {
		s = strings.TrimSuffix(s, " TL") + " " + currency
	}
	return s
}
