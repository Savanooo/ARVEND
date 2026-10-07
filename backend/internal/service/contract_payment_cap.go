package service

import (
	"errors"
	"fmt"
	"strings"

	"github.com/shopspring/decimal"

	"github.com/Savanooo/ARVEND/backend/internal/repository"
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
	a := money2(amount)
	if contract.Sign() > 0 && paid.Add(a).Cmp(contract) <= 0 {
		return nil
	}
	return &PaymentExceedsContractError{Contract: contract, Paid: paid, Amount: a, Currency: currency, Hint: hint}
}

// money2, istemciden gelen float tutarı veritabanına YAZILACAK değerin
// AYNISI olan 2 haneli decimal'e çevirir (repository.Float64ToNumeric ile
// aynı yuvarlama) -- doğrulanan rakam ile saklanan rakam kuruşu kuruşuna
// aynı olsun diye.
func money2(amount float64) decimal.Decimal {
	return repository.NumericToDecimal(repository.Float64ToNumeric(amount))
}

// ErrPaymentExceedsClaim: bir hakedişe BAĞLI ödemelerin toplamı o
// hakedişin net ödenecek tutarını aşamaz (sahada: 10.000 TL net
// hakedişe 50.000 TL'lik ödeme bağlanabiliyordu -- yalnızca sözleşme
// toplamı kontrol ediliyordu). errors.Is hedefi; ayrıntı
// PaymentExceedsClaimError'da.
var ErrPaymentExceedsClaim = errors.New("ödeme hakedişin net ödenecek tutarını aşıyor")

// PaymentExceedsClaimError, kullanıcıya rakamlarla ne yapacağını söyler.
type PaymentExceedsClaimError struct {
	ClaimNumber string
	NetPayable  decimal.Decimal // hakedişin net ödenecek tutarı
	Paid        decimal.Decimal // bu hakedişe bağlı, iptal edilmemiş ödemeler
	Amount      decimal.Decimal // reddedilen ödeme
	Currency    string
}

func (e *PaymentExceedsClaimError) Error() string {
	remaining := e.NetPayable.Sub(e.Paid)
	if remaining.Sign() < 0 {
		remaining = decimal.Zero
	}
	return fmt.Sprintf("ödeme hakedişin net ödenecek tutarını aşıyor: %s net ödenecek %s, bu hakedişe şimdiye kadar ödenen %s, bu ödeme %s. Bu hakedişe en fazla %s ödenebilir; fazlası (ör. avans, teminat iadesi) için ödemeyi bir hakedişe bağlamadan kaydedin.",
		e.ClaimNumber, formatMoneyCur(e.NetPayable, e.Currency), formatMoneyCur(e.Paid, e.Currency),
		formatMoneyCur(e.Amount, e.Currency), formatMoneyCur(remaining, e.Currency))
}

func (e *PaymentExceedsClaimError) Unwrap() error { return ErrPaymentExceedsClaim }

// checkWithinClaim: paidForClaim + amount <= netPayable değilse hata.
func checkWithinClaim(claimNumber string, netPayable, paidForClaim decimal.Decimal, amount float64, currency string) error {
	a := money2(amount)
	if paidForClaim.Add(a).Cmp(netPayable) <= 0 {
		return nil
	}
	return &PaymentExceedsClaimError{ClaimNumber: claimNumber, NetPayable: netPayable, Paid: paidForClaim, Amount: a, Currency: currency}
}

func formatMoneyCur(d decimal.Decimal, currency string) string {
	f, _ := d.Float64()
	s := FormatTL(f)
	if currency != "" && currency != "TRY" {
		s = strings.TrimSuffix(s, " TL") + " " + currency
	}
	return s
}
