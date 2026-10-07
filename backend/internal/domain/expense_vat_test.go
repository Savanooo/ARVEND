package domain

import "testing"

func TestExpenseVAT(t *testing.T) {
	f := func(v float64) *float64 { return &v }
	for _, tc := range []struct {
		rate *float64
		ok   bool
	}{{nil, true}, {f(0), true}, {f(20), true}, {f(100), true}, {f(-0.01), false}, {f(100.01), false}} {
		if got := ValidExpenseVATRate(tc.rate); got != tc.ok {
			t.Errorf("oran %v: %v", tc.rate, got)
		}
	}

	if (Expense{Amount: 100}).NetAmount() != nil {
		t.Error("KDV belirtilmemişse KDV hariç tutar bilinmez (nil)")
	}
	if net := (Expense{Amount: 120000, VATRate: f(20), VATAmount: f(20000)}).NetAmount(); net == nil || *net != 100000 {
		t.Errorf("KDV hariç: %v", net)
	}
	if net := (Expense{Amount: 100.01, VATRate: f(1), VATAmount: f(0.99)}).NetAmount(); net == nil || *net != 99.02 {
		t.Errorf("kuruş: %v", net)
	}
}
