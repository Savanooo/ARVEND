package handler

// /calculations/run yanıtının istemcilerin dayandığı şekli: mobil
// input.pitch_deg anahtarının VARLIĞINA bakarak yeni sunucuyu eskisinden
// ayırır (anahtar yoksa istekteki eğime düşer); min_quantity/package_size
// yalnızca reçetede tanımlıysa gelir. DB gerektirmez.

import (
	"encoding/json"
	"testing"

	"github.com/shopspring/decimal"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
)

func runResponseJSON(t *testing.T, result *domain.CalcResult) map[string]any {
	t.Helper()
	b, err := json.Marshal(toCalcRunResponse(result))
	if err != nil {
		t.Fatalf("yanıt JSON'a çevrilemedi: %v", err)
	}
	var m map[string]any
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatalf("yanıt JSON değil: %v", err)
	}
	return m
}

func TestCalcRunResponse_PitchKeyAlwaysPresent(t *testing.T) {
	flat := &domain.CalcResult{
		Category: domain.CalcCategory{ID: "c1", Slug: "s", Name: "Alçıpan"},
		Geometry: domain.CalcGeometry{FootprintArea: decimal.NewFromInt(100), EffectiveArea: decimal.NewFromInt(100)},
	}
	input := runResponseJSON(t, flat)["input"].(map[string]any)
	if v, ok := input["pitch_deg"]; !ok || v != nil {
		t.Fatalf("eğimsiz hesapta input.pitch_deg = %v (var=%v), istenen null ve anahtar mevcut", v, ok)
	}

	pitch := decimal.NewFromInt(30)
	roof := &domain.CalcResult{
		Category: domain.CalcCategory{ID: "c2", Slug: "s", Name: "Onduline"},
		Geometry: domain.CalcGeometry{
			FootprintArea: decimal.NewFromInt(100), EffectiveArea: decimal.RequireFromString("115.47"), PitchDeg: &pitch,
		},
	}
	if got := runResponseJSON(t, roof)["input"].(map[string]any)["pitch_deg"]; got != "30" {
		t.Fatalf("input.pitch_deg = %v, istenen \"30\"", got)
	}
}

func TestCalcRunResponse_PackageRuleOnlyWhenSet(t *testing.T) {
	minQ, pkg := decimal.NewFromInt(2), decimal.RequireFromString("3.6")
	result := &domain.CalcResult{
		Category: domain.CalcCategory{ID: "c1", Slug: "s", Name: "Mantolama"},
		Geometry: domain.CalcGeometry{FootprintArea: decimal.NewFromInt(10), EffectiveArea: decimal.NewFromInt(10)},
		Items: []domain.CalcResultItem{
			{RecipeItemID: "r1", Quantity: decimal.NewFromInt(4), MinQuantity: &minQ, PackageSize: &pkg},
			{RecipeItemID: "r2", Quantity: decimal.RequireFromString("64.84")},
		},
	}
	items := runResponseJSON(t, result)["items"].([]any)
	withRule, plain := items[0].(map[string]any), items[1].(map[string]any)
	if withRule["min_quantity"] != "2" || withRule["package_size"] != "3.6" {
		t.Errorf("paket/minimum = %v/%v, istenen \"3.6\"/\"2\"", withRule["package_size"], withRule["min_quantity"])
	}
	for _, k := range []string{"min_quantity", "package_size"} {
		if _, ok := plain[k]; ok {
			t.Errorf("kuralı olmayan satırda %q gönderilmemeli: %v", k, plain[k])
		}
	}
	if plain["quantity"] != "64.84" {
		t.Errorf("quantity = %v, istenen \"64.84\"", plain["quantity"])
	}
}
