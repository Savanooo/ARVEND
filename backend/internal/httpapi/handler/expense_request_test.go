package handler

import (
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/Savanooo/ARVEND/backend/internal/platform/httpjson"
)

// Masraf KDV oranı (migration 0065) opsiyoneldir: bugünkü web formu alanı
// hiç göndermez ve istek "belirtilmedi" olarak kabul edilmeli (Decode
// bilinmeyen alanı reddettiği için gövde birebir web'in gönderdiğidir).
func TestExpenseRequestVATRateOptional(t *testing.T) {
	cases := []struct {
		name string
		body string
		want *float64
	}{
		{"web formu (alan yok)", `{"category":"material","description":"Çimento","amount":1200,"expense_date":"2026-10-07",` +
			`"supplier_name":"","invoice_no":"","notes":"","change_order_id":"","cost_code_id":"","budget_line_id":"",` +
			`"currency":"TRY","idempotency_key":"k1"}`, nil},
		{"null", `{"category":"material","description":"Çimento","amount":1200,"vat_rate":null}`, nil},
		{"%20", `{"category":"material","description":"Çimento","amount":1200,"vat_rate":20}`, ptr(20.0)},
		{"KDV yok", `{"category":"material","description":"Çimento","amount":1200,"vat_rate":0}`, ptr(0.0)},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			r := httptest.NewRequest("POST", "/", strings.NewReader(c.body))
			var req expenseRequest
			if err := httpjson.Decode(r, &req); err != nil {
				t.Fatalf("gövde reddedildi: %v", err)
			}
			got := req.toInput("u1", time.Now()).VATRate
			if (got == nil) != (c.want == nil) || (got != nil && *got != *c.want) {
				t.Fatalf("vat_rate: %v, beklenen %v", got, c.want)
			}
		})
	}
}

func ptr[T any](v T) *T { return &v }
