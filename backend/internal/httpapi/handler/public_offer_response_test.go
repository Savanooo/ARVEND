package handler

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
)

// TestPublicOfferResponseHidesCalcSnapshot: müşteriye giden teklif JSON'u
// Metraj Hesaplama'nın dondurulmuş hesap kaydını (fire yüzdesi, reçete
// katsayısı, katalog fiyatı) ve iç kategori id'sini taşımamalı; personel
// yanıtı (toOfferResponse) ise taşımaya devam eder.
func TestPublicOfferResponseHidesCalcSnapshot(t *testing.T) {
	snapshot := json.RawMessage(`{"waste_percent":"12.5","factor":"3.6","catalog_unit_price":"41.20"}`)
	o := domain.Offer{
		ID: "offer-1", OfferNo: "TKF-2026-0001", CustomerName: "Müşteri",
		Items: []domain.OfferItem{{
			ID: "item-1", ProductName: "Petek Tavan", Quantity: 10, UnitPrice: 50, LineTotal: 500,
			Unit: "m²", CalcCategoryID: ptrS("cat-1"), CalcSnapshot: snapshot,
		}},
	}

	public := marshalNoErr(t, toPublicOfferResponse(o))
	for _, leak := range []string{"calc_snapshot", "waste_percent", "catalog_unit_price", "calc_category_id"} {
		if strings.Contains(public, leak) {
			t.Errorf("public yanıt %q içermemeli: %s", leak, public)
		}
	}
	for _, keep := range []string{`"product_name":"Petek Tavan"`, `"unit":"m²"`, `"line_total":500`} {
		if !strings.Contains(public, keep) {
			t.Errorf("public yanıt %q içermeli: %s", keep, public)
		}
	}
	if staff := marshalNoErr(t, toOfferResponse(o)); !strings.Contains(staff, "calc_snapshot") {
		t.Errorf("personel yanıtı calc_snapshot'ı korumalı: %s", staff)
	}
}
