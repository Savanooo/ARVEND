package service

import (
	"testing"

	"github.com/shopspring/decimal"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
)

func f64(v float64) *float64 { return &v }

// TestComputeOfferTotalsRoundsBeforeMultiplying: miktar ve birim fiyat
// kolonları numeric(12,2) -- satır toplamı, kolona YAZILAN (yuvarlanmış)
// değerlerin çarpımı olmalı. Eskiden 1,005 × 100 satırı 100,50 toplamla
// ama 1,00 miktarla kaydediliyordu (müşteri 1,00 × 100 = 100,50 görüyordu).
func TestComputeOfferTotalsRoundsBeforeMultiplying(t *testing.T) {
	cases := []struct {
		qty, price, wantQty, wantPrice, wantLine float64
	}{
		{1.005, 100, 1.01, 100, 101},
		{2.333, 3.335, 2.33, 3.34, 7.78},
		{0.125, 0.125, 0.13, 0.13, 0.02},
		{3, 19.999, 3, 20, 60},
	}
	for _, c := range cases {
		items, subtotal, _, _, _, err := computeOfferTotals(
			[]OfferItemInput{{ProductName: "Kalem", Quantity: c.qty, UnitPrice: c.price}}, f64(0), false)
		if err != nil {
			t.Fatalf("qty=%v price=%v: %v", c.qty, c.price, err)
		}
		it := items[0]
		if it.Quantity != c.wantQty || it.UnitPrice != c.wantPrice || it.LineTotal != c.wantLine {
			t.Errorf("qty=%v price=%v: got qty=%v price=%v line=%v, want %v/%v/%v",
				c.qty, c.price, it.Quantity, it.UnitPrice, it.LineTotal, c.wantQty, c.wantPrice, c.wantLine)
		}
		// Değişmez: miktar × birim fiyat (2 haneye) == satır toplamı.
		prod := decimal.NewFromFloat(it.Quantity).Mul(decimal.NewFromFloat(it.UnitPrice)).Round(2)
		if !prod.Equal(decimal.NewFromFloat(it.LineTotal)) {
			t.Errorf("miktar × fiyat (%s) satır toplamına (%v) eşit değil", prod, it.LineTotal)
		}
		if subtotal != it.LineTotal {
			t.Errorf("ara toplam %v, satır toplamı %v", subtotal, it.LineTotal)
		}
	}
}

func TestComputeOfferTotalsVatAndSums(t *testing.T) {
	items := []OfferItemInput{
		{ProductName: "A", Quantity: 1, UnitPrice: 0.1},
		{ProductName: "B", Quantity: 1, UnitPrice: 0.2},
		{ProductName: "", Quantity: 1, UnitPrice: 5},  // boş form satırı: atlanır
		{ProductName: "C", Quantity: 0, UnitPrice: 5}, // miktar 0: atlanır
	}
	computed, subtotal, vatRate, vatAmount, grand, err := computeOfferTotals(items, f64(18), false)
	if err != nil {
		t.Fatal(err)
	}
	if len(computed) != 2 || subtotal != 0.3 || vatRate != 18 || vatAmount != 0.05 || grand != 0.35 {
		t.Errorf("got n=%d subtotal=%v vat=%v vatAmount=%v grand=%v", len(computed), subtotal, vatRate, vatAmount, grand)
	}
}

func TestComputeOfferTotalsValidation(t *testing.T) {
	base := func() OfferItemInput { return OfferItemInput{ProductName: "Kalem", Quantity: 1, UnitPrice: 10} }
	cases := map[string]struct {
		items     []OfferItemInput
		vat       *float64
		canManage bool
	}{
		"negative_vat":        {[]OfferItemInput{base()}, f64(-1), false},
		"vat_over_100":        {[]OfferItemInput{base()}, f64(1000), false},
		"negative_unit_price": {[]OfferItemInput{{ProductName: "X", Quantity: 1, UnitPrice: -5}}, nil, false},
		// %-150 marj: maliyet 100 -> satış fiyatı -50. Negatif fiyat kontrolü
		// marj yeniden hesabından SONRA yapılmalı.
		"markup_below_minus_100": {[]OfferItemInput{{
			ProductName: "X", Quantity: 1, UnitPrice: 10,
			InternalSubcontractCost: f64(100), PricingMode: domain.OfferItemPricingModeMarkup, MarkupPercent: f64(-150),
		}}, nil, true},
		"markup_too_large": {[]OfferItemInput{{
			ProductName: "X", Quantity: 1, UnitPrice: 10,
			InternalSubcontractCost: f64(1), PricingMode: domain.OfferItemPricingModeMarkup, MarkupPercent: f64(10000),
		}}, nil, true},
		"amount_overflow": {[]OfferItemInput{{ProductName: "X", Quantity: 100000, UnitPrice: 1000000}}, nil, false},
	}
	for name, c := range cases {
		t.Run(name, func(t *testing.T) {
			if _, _, _, _, _, err := computeOfferTotals(c.items, c.vat, c.canManage); err == nil {
				t.Errorf("hata bekleniyordu")
			}
		})
	}

	// Sınırlar dahil: %0 ve %100 KDV, %-100 marj (fiyat 0) geçerlidir.
	for _, vat := range []float64{0, 100} {
		if _, _, _, _, _, err := computeOfferTotals([]OfferItemInput{base()}, f64(vat), false); err != nil {
			t.Errorf("KDV %%%v reddedildi: %v", vat, err)
		}
	}
	items, _, _, _, _, err := computeOfferTotals([]OfferItemInput{{
		ProductName: "X", Quantity: 2, UnitPrice: 999,
		InternalSubcontractCost: f64(100), PricingMode: domain.OfferItemPricingModeMarkup, MarkupPercent: f64(-100),
	}}, nil, true)
	if err != nil || items[0].UnitPrice != 0 {
		t.Errorf("%%-100 marj 0 fiyat üretmeli: items=%+v err=%v", items, err)
	}
}

// Marj modunda satış fiyatı yuvarlanmış maliyet × (1 + yuvarlanmış marj)
// olarak hesaplanır; istemcinin gönderdiği birim fiyat yok sayılır.
func TestComputeOfferTotalsMarkupPrice(t *testing.T) {
	items, subtotal, _, _, _, err := computeOfferTotals([]OfferItemInput{{
		ProductName: "X", Quantity: 3, UnitPrice: 1,
		InternalSubcontractCost: f64(33.333), PricingMode: domain.OfferItemPricingModeMarkup, MarkupPercent: f64(12.5),
	}}, f64(0), true)
	if err != nil {
		t.Fatal(err)
	}
	// 33,33 × 1,125 = 37,49625 -> 37,50; 3 × 37,50 = 112,50
	if items[0].UnitPrice != 37.5 || items[0].LineTotal != 112.5 || subtotal != 112.5 || *items[0].InternalSubcontractCost != 33.33 {
		t.Errorf("got %+v subtotal=%v", items[0], subtotal)
	}
}

func TestRound2(t *testing.T) {
	for in, want := range map[float64]float64{1.005: 1.01, -1.234: -1.23, -1.235: -1.24, 2.675: 2.68, 10: 10} {
		if got := round2(in); got != want {
			t.Errorf("round2(%v) = %v, want %v", in, got, want)
		}
	}
}
