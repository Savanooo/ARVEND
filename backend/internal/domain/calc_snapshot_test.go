package domain_test

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
)

func normalizedSnapshot(t *testing.T, raw string) map[string]any {
	t.Helper()
	out := domain.NormalizeCalcSnapshot(json.RawMessage(raw))
	if out == nil {
		t.Fatalf("NormalizeCalcSnapshot(%s) = nil, nesne bekleniyordu", raw)
	}
	var m map[string]any
	if err := json.Unmarshal(out, &m); err != nil {
		t.Fatalf("çıktı JSON değil: %v (%s)", err, out)
	}
	return m
}

func TestNormalizeCalcSnapshot_WebSchemaUnchanged(t *testing.T) {
	web := `{"area":"20","perimeter":null,"pitch_deg":"30","recipe_factor":"5","waste_percent":"0",` +
		`"rounding_type":"none","price_at_calc":"230.00","category_name":"Onduline","group_name":"Çatı Hesaplamaları"}`
	got := normalizedSnapshot(t, web)
	var want map[string]any
	_ = json.Unmarshal([]byte(web), &want)
	if len(got) != len(want) {
		t.Fatalf("anahtar sayısı = %d, istenen %d: %v", len(got), len(want), got)
	}
	for k, v := range want {
		if gv, ok := got[k]; !ok || gv != v {
			t.Errorf("%s = %v, istenen %v", k, gv, v)
		}
	}
}

func TestNormalizeCalcSnapshot_LegacyMobileKeysMapped(t *testing.T) {
	legacy := `{"recipe_item_id":"r1","category_id":"c1","category_name":"Tavan","footprint_area":"10",` +
		`"effective_area":"11.547005","perimeter":null,"calculation_type":"area_based","factor":"5",` +
		`"waste_percent":"0","rounding_type":"none","price_at_calc":"200.00","price_source":"reference"}`
	got := normalizedSnapshot(t, legacy)
	if got["area"] != "11.547005" {
		t.Errorf("area = %v, istenen effective_area'dan 11.547005", got["area"])
	}
	if got["recipe_factor"] != "5" {
		t.Errorf("recipe_factor = %v, istenen factor'dan 5", got["recipe_factor"])
	}
	for _, old := range []string{"effective_area", "factor"} {
		if _, ok := got[old]; ok {
			t.Errorf("eski anahtar %q çıktıda kalmamalı", old)
		}
	}
	if _, ok := got["pitch_deg"]; ok {
		t.Error("eski kayıtta olmayan pitch_deg uydurulmamalı (bilinmiyor != eğim yok)")
	}
	for _, k := range []string{"recipe_item_id", "category_id", "footprint_area", "calculation_type", "price_source"} {
		if _, ok := got[k]; !ok {
			t.Errorf("%q korunmalıydı", k)
		}
	}
	if v, ok := got["perimeter"]; !ok || v != nil {
		t.Errorf("perimeter = %v (var=%v), istenen null", v, ok)
	}
}

func TestNormalizeCalcSnapshot_CanonicalKeyWinsOverLegacy(t *testing.T) {
	got := normalizedSnapshot(t, `{"area":"20","effective_area":"99","recipe_factor":"5","factor":"7"}`)
	if got["area"] != "20" || got["recipe_factor"] != "5" {
		t.Fatalf("kanonik anahtar öncelikli olmalı: %v", got)
	}
}

func TestNormalizeCalcSnapshot_DropsUnknownAndOddValues(t *testing.T) {
	long := strings.Repeat("ş", 500)
	got := normalizedSnapshot(t, `{"area":20.5,"waste_percent":0,"foo":"bar","price_at_calc":{"x":1},`+
		`"rounding_type":true,"category_name":"`+long+`"}`)
	if got["area"] != "20.5" || got["waste_percent"] != "0" {
		t.Errorf("sayılar yazıldığı gibi metne çevrilmeli: area=%v waste=%v", got["area"], got["waste_percent"])
	}
	for _, k := range []string{"foo", "price_at_calc", "rounding_type"} {
		if _, ok := got[k]; ok {
			t.Errorf("%q atılmalıydı: %v", k, got[k])
		}
	}
	if n := len([]rune(got["category_name"].(string))); n != 200 {
		t.Errorf("uzun değer 200 karaktere kısaltılmalı, uzunluk %d", n)
	}
}

func TestNormalizeCalcSnapshot_EmptyOrNonObjectIsNil(t *testing.T) {
	for _, raw := range []string{"", "null", "[]", `"metin"`, "12", "{}", `{"foo":"bar"}`, "{bozuk"} {
		if out := domain.NormalizeCalcSnapshot(json.RawMessage(raw)); out != nil {
			t.Errorf("NormalizeCalcSnapshot(%q) = %s, nil bekleniyordu", raw, out)
		}
	}
}

func TestComputeGeometry_ReportsAppliedPitchOnly(t *testing.T) {
	geo, err := domain.ComputeGeometry(domain.CalcInput{Area: dPtr("100"), PitchDeg: dPtr("30")})
	if err != nil {
		t.Fatalf("ComputeGeometry: %v", err)
	}
	if geo.PitchDeg == nil || !geo.PitchDeg.Equal(d("30")) {
		t.Errorf("uygulanan eğim = %v, istenen 30", geo.PitchDeg)
	}
	for _, pitch := range []string{"0", "90", "120"} {
		geo, err := domain.ComputeGeometry(domain.CalcInput{Area: dPtr("100"), PitchDeg: dPtr(pitch)})
		if err != nil {
			t.Fatalf("ComputeGeometry(pitch=%s): %v", pitch, err)
		}
		if geo.PitchDeg != nil {
			t.Errorf("pitch=%s yok sayıldığı halde eğim bildirildi: %s", pitch, geo.PitchDeg)
		}
	}
	flat, _ := domain.ComputeGeometry(domain.CalcInput{Area: dPtr("100")})
	if flat.PitchDeg != nil {
		t.Errorf("eğim verilmediğinde PitchDeg nil olmalı, geldi %s", flat.PitchDeg)
	}
}
