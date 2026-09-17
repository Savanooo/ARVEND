package handler

// İç Taşeron Fiyatlama (migration 0040) — güvenlik/sızıntı testleri.
// Bu paket testi (package handler, package handler_test DEĞİL) BİLİNÇLİ
// OLARAK unexported toOfferResponse/toOfferRevisionResponse/
// attachInternalPricing'e doğrudan erişir: asıl kanıtlanmak istenen şey
// PublicOfferHandler'ın (bkz. public_offer_handler.go) KULLANDIĞI TAM O
// fonksiyonların hiçbir koşulda iç fiyatlama alanı ÜRETMEDİĞİdir — bu,
// DB/HTTP sunucusu gerektirmeyen, hızlı ve deterministik bir testtir.

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
)

func ptrF(f float64) *float64 { return &f }
func ptrS(s string) *string   { return &s }

// offerWithInternalPricing, hem "iç fiyatlama uygulanmış" (kalem 0) hem
// "uygulanmamış" (kalem 1, ProductID/CalcCategoryID gibi diğer nil alanlar
// İLE AYNI durum) kalemleri BİR ARADA taşıyan, tespiti kolay/ayırt edici
// değerlerle dolu bir domain.Offer döner.
func offerWithInternalPricing() domain.Offer {
	return domain.Offer{
		ID:           "offer-1",
		OfferNo:      "TKF-2026-0001",
		CustomerName: "Test Müşteri",
		Items: []domain.OfferItem{
			{
				ID:                      "item-1",
				ProductName:             "Asma Tavan Montajı",
				Quantity:                1,
				UnitPrice:               91000, // = 70000 * 1.30 (markup modu)
				LineTotal:               91000,
				InternalSubcontractCost: ptrF(70000),
				PricingMode:             ptrS(domain.OfferItemPricingModeMarkup),
				MarkupPercent:           ptrF(30),
			},
			{
				ID:          "item-2",
				ProductName: "Standart Malzeme",
				Quantity:    1,
				UnitPrice:   1000,
				LineTotal:   1000,
				// İç fiyatlama uygulanmamış kalem -- hepsi nil.
			},
		},
	}
}

// marshalNoErr, testte tekrar eden json.Marshal+hata kontrolünü sarmalar.
func marshalNoErr(t *testing.T, v any) string {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("json.Marshal: %v", err)
	}
	return string(b)
}

// leakMarkers, JSON gövdesinde KESİNLİKLE görünmemesi gereken -- iç
// fiyatlamaya özgü -- alan adları ve ayırt edici değerlerdir. "70000"/"30"
// gibi ham sayılar yerine üretilen JSON'un TAMAMINDA bu alan adlarının hiç
// geçmediğini kontrol etmek daha güvenilirdir (bir sayı başka bir alanda
// tesadüfen aynı olabilir, ama "internal_subcontract_cost" anahtarı ASLA
// tesadüfen görünmez).
var leakMarkers = []string{
	"internal_pricing",
	"internal_subcontract_cost",
	"pricing_mode",
	"markup_percent",
	"expected_profit",
	"effective_markup_percent",
}

func assertNoLeakMarkers(t *testing.T, jsonBody string) {
	t.Helper()
	for _, marker := range leakMarkers {
		if strings.Contains(jsonBody, marker) {
			t.Errorf("GÜVENLİK: yanıt gövdesi sızdırmaması gereken alanı içeriyor (%q):\n%s", marker, jsonBody)
		}
	}
}

// 1) toOfferResponse -- PublicOfferHandler.Get/Respond'un TEK kullandığı
// fonksiyon (bkz. public_offer_handler.go:62,82) -- HİÇBİR KOŞULDA iç
// fiyatlama alanı üretmemelidir. Bu, "müşteri/public offer serileştirici"
// ve "unauthenticated paylaşım linki" güvenlik gereksinimlerinin DOĞRUDAN
// kanıtıdır: PublicOfferHandler bambaşka bir fonksiyon ÇAĞIRMAZ, bu
// fonksiyonun kendisi test edilir.
func TestToOfferResponse_NeverLeaksInternalPricing(t *testing.T) {
	offer := offerWithInternalPricing()
	resp := toOfferResponse(offer)

	for i, it := range resp.Items {
		if it.InternalPricing != nil {
			t.Fatalf("resp.Items[%d].InternalPricing nil OLMALI (toOfferResponse hiç doldurmamalı), geldi: %+v", i, *it.InternalPricing)
		}
	}

	body := marshalNoErr(t, resp)
	assertNoLeakMarkers(t, body)
	// Müşterinin GÖRMESİ gereken satış fiyatı (91000, markup uygulanmış
	// satış fiyatı) elbette JSON'da OLMALI -- bu bir "hiçbir şey dönme"
	// testi değil, yalnızca İÇ maliyet/marj alanlarının yokluğunu kanıtlar.
	if !strings.Contains(body, `"unit_price":91000`) {
		t.Fatalf("satış fiyatı (unit_price) normal şekilde dönmeli, gövde: %s", body)
	}
}

// 2) publicOfferResponse -- PublicOfferHandler.Get'in GERÇEKTEN sunduğu
// zarf (offerResponse + can_respond). toOfferResponse zaten sızdırmadığını
// kanıtladı; bu test o kompozisyonun KENDİSİNİN de (ek bir alan
// eklenmemiş) sızdırmadığını doğrular -- public_offer_handler.go:50-53'teki
// struct'ın BİREBİR aynısı.
func TestPublicOfferResponse_NeverLeaksInternalPricing(t *testing.T) {
	offer := offerWithInternalPricing()
	resp := publicOfferResponse{offerResponse: toOfferResponse(offer), CanRespond: true}
	assertNoLeakMarkers(t, marshalNoErr(t, resp))
}

// 3) toOfferRevisionResponse -- personel-only revizyon detay uçları
// (ListRevisions/GetRevision) İÇİN DE aynı "varsayılan güvenli" ilke
// geçerli olmalı; internal_pricing yalnızca attachRevisionInternalPricing
// AYRICA çağrılırsa eklenir (bkz. test 5).
func TestToOfferRevisionResponse_NeverLeaksInternalPricing(t *testing.T) {
	offer := offerWithInternalPricing()
	rev := domain.OfferRevision{
		ID: "rev-1", OfferID: offer.ID, RevisionNo: 0,
		CustomerName: offer.CustomerName, Items: offer.Items,
	}
	resp := toOfferRevisionResponse(rev)
	for i, it := range resp.Items {
		if it.InternalPricing != nil {
			t.Fatalf("resp.Items[%d].InternalPricing nil OLMALI, geldi: %+v", i, *it.InternalPricing)
		}
	}
	assertNoLeakMarkers(t, marshalNoErr(t, resp))
}

// 4) attachInternalPricing -- OPT-IN yolun GERÇEKTEN çalıştığını (yalnızca
// "sessizce hiçbir şey yapmıyor" olmadığını) kanıtlar -- personel uçlarının
// izinli kullanıcıya doğru veriyi göstermesi de bir gereksinimdir, yalnızca
// sızdırmama değil. ExpectedProfit=21000 (91000-70000), EffectiveMarkupPercent
// = round2((91000-70000)*100/70000) = 30.0 (markup modunda hedeflenenle
// AYNI çıkması beklenir, spec'in "manual" örneğindeki 35.714...% farklı bir
// senaryo).
func TestAttachInternalPricing_AddsExpectedValuesWhenCalled(t *testing.T) {
	offer := offerWithInternalPricing()
	resp := toOfferResponse(offer)
	attachInternalPricing(&resp, offer)

	ip := resp.Items[0].InternalPricing
	if ip == nil {
		t.Fatal("attachInternalPricing çağrıldıktan SONRA InternalPricing dolu olmalı")
	}
	if ip.Cost != 70000 {
		t.Errorf("Cost = %v, beklenen 70000", ip.Cost)
	}
	if ip.PricingMode != domain.OfferItemPricingModeMarkup {
		t.Errorf("PricingMode = %v, beklenen %v", ip.PricingMode, domain.OfferItemPricingModeMarkup)
	}
	if ip.MarkupPercent == nil || *ip.MarkupPercent != 30 {
		t.Errorf("MarkupPercent = %v, beklenen 30", ip.MarkupPercent)
	}
	if ip.ExpectedProfit != 21000 {
		t.Errorf("ExpectedProfit = %v, beklenen 21000 (91000-70000)", ip.ExpectedProfit)
	}
	if ip.EffectiveMarkupPercent == nil || *ip.EffectiveMarkupPercent != 30 {
		t.Errorf("EffectiveMarkupPercent = %v, beklenen 30", ip.EffectiveMarkupPercent)
	}
	// İç fiyatlama uygulanmamış kalem (item-2) attachInternalPricing
	// SONRASINDA da nil KALMALI.
	if resp.Items[1].InternalPricing != nil {
		t.Errorf("iç fiyatlama uygulanmamış kalemde InternalPricing nil KALMALI, geldi: %+v", *resp.Items[1].InternalPricing)
	}

	body := marshalNoErr(t, resp)
	if !strings.Contains(body, "internal_pricing") {
		t.Fatalf("attachInternalPricing SONRASI JSON'da internal_pricing GÖRÜNMELİ, gövde: %s", body)
	}
}

// 5) attachRevisionInternalPricing -- (4) İLE AYNI kanıt, revizyon yanıtı
// için.
func TestAttachRevisionInternalPricing_AddsValuesWhenCalled(t *testing.T) {
	offer := offerWithInternalPricing()
	rev := domain.OfferRevision{ID: "rev-1", OfferID: offer.ID, Items: offer.Items}
	resp := toOfferRevisionResponse(rev)
	attachRevisionInternalPricing(&resp, rev)

	if resp.Items[0].InternalPricing == nil {
		t.Fatal("attachRevisionInternalPricing çağrıldıktan SONRA InternalPricing dolu olmalı")
	}
	if resp.Items[0].InternalPricing.Cost != 70000 {
		t.Errorf("Cost = %v, beklenen 70000", resp.Items[0].InternalPricing.Cost)
	}
}

// 6) canSeeOfferInternalPricing/canManageOfferInternalPricing -- "deny by
// default" kanıtı: context'inde HİÇBİR yetkilendirme bilgisi (AuthzContext)
// olmayan bir istek (ör. LoadAuthorization zincirlenmemiş ya da izin
// kümesi boş) FALSE dönmelidir -- "offers.read izni olan HERKES" değil,
// yalnızca AÇIKÇA offers.internal_pricing.* verilmiş kullanıcılar true
// alır. super_admin İSTİSNASI (platform rolü, tenant izin sistemine hiç
// girmeden HER ŞEYİ görür, RequirePermission İLE AYNI ilke) AYRICA
// doğrulanır.
func TestCanSeeOfferInternalPricing_DenyByDefault(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/api/v1/offers/x", nil)
	// Context'e HİÇBİR middleware.RoleFromContext/AuthzContextFromRequest
	// değeri KONULMADI -- gerçek hayatta bu, LoadAuthorization'ın
	// çalışmadığı ya da (teorik) bir hata durumuna karşılık gelir.
	if canSeeOfferInternalPricing(req) {
		t.Fatal("yetkilendirme bağlamı YOKKEN canSeeOfferInternalPricing true DÖNMEMELİ (deny-by-default)")
	}
	if canManageOfferInternalPricing(req) {
		t.Fatal("yetkilendirme bağlamı YOKKEN canManageOfferInternalPricing true DÖNMEMELİ (deny-by-default)")
	}
}
