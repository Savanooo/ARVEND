package service_test

// Sözleşme testi (spec §4.11 "Contract"): docs/dashboard/fixtures/*.json
// -- web (node --test) ve mobil (flutter test) testlerinin de kullandığı
// ORTAK örnek yanıtlar -- domain.Dashboard'a DisallowUnknownFields ile
// çözülmeli ve geri yazıldığında AYNI JSON'u vermeli (eksik/fazla alan,
// tip ya da null/[] farkı yakalanır). Ayrıca her fixture'ın gündemi
// BuildDashboardAgenda'nın kendi kurallarıyla (şerit, önem, sıralama,
// sayaçlar) tutarlı olmalı ve bölüm kümesi personanın izinlerinden gelen
// kapılarla BİREBİR örtüşmeli. DB gerektirmez.

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"testing"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

const dashboardFixtureDir = "../../../docs/dashboard/fixtures"

type dashboardPersona struct {
	name       string
	roleCode   string
	coarseRole domain.Role
	perms      []string
}

var dashboardPersonas = []dashboardPersona{
	{"owner", domain.OrgRoleOwner, domain.RoleAdmin, permsAll},
	{"empty_company", domain.OrgRoleOwner, domain.RoleAdmin, permsAll},
	{"field", domain.OrgRoleField, domain.RoleKullanici, permsField},
	{"finance", domain.OrgRoleFinance, domain.RoleKullanici, permsFinance},
}

func loadDashboardFixture(t *testing.T, name string) ([]byte, domain.Dashboard) {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join(dashboardFixtureDir, name+".json"))
	if err != nil {
		t.Fatalf("fixture okunamadı: %v", err)
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	var d domain.Dashboard
	if err := dec.Decode(&d); err != nil {
		t.Fatalf("%s.json domain.Dashboard'a çözülemedi (sözleşme kayması): %v", name, err)
	}
	if dec.More() {
		t.Fatalf("%s.json: fazladan veri", name)
	}
	return raw, d
}

func TestDashboardFixturesMatchContract(t *testing.T) {
	files, err := filepath.Glob(filepath.Join(dashboardFixtureDir, "*.json"))
	if err != nil {
		t.Fatal(err)
	}
	if len(files) < len(dashboardPersonas) {
		t.Fatalf("en az %d fixture beklenir, %d bulundu", len(dashboardPersonas), len(files))
	}
	// 1) Klasördeki HER fixture: bilinmeyen alan yok ve gidiş-dönüş
	// (struct -> JSON) fixture ile anlamca aynı (eksik alan, null/[] farkı).
	roundTrip := map[string][]byte{}
	for _, f := range files {
		name := filepath.Base(f[:len(f)-len(".json")])
		raw, d := loadDashboardFixture(t, name)
		again, err := json.Marshal(d)
		if err != nil {
			t.Fatal(err)
		}
		var want, got any
		_ = json.Unmarshal(raw, &want)
		_ = json.Unmarshal(again, &got)
		if !reflect.DeepEqual(want, got) {
			t.Errorf("%s.json gidiş-dönüşte değişti -- fixture ile Go tipleri ayrışmış (eksik alan, null/[] farkı?)", name)
		}
		roundTrip[name] = again
	}
	for _, p := range dashboardPersonas {
		t.Run(p.name, func(t *testing.T) {
			_, d := loadDashboardFixture(t, p.name)
			again, ok := roundTrip[p.name]
			if !ok {
				t.Fatalf("%s.json yok", p.name)
			}

			// 2) Bölüm kümesi = personanın kapıları.
			authz := &service.AuthzContext{RoleCode: p.roleCode, Permissions: map[string]bool{}}
			for _, c := range p.perms {
				authz.Permissions[c] = true
			}
			wantKeys := service.DashboardSectionKeysFor(authz, p.coarseRole)
			gotKeys := sectionKeys(t, again)
			slices.Sort(wantKeys)
			slices.Sort(gotKeys)
			if !reflect.DeepEqual(wantKeys, gotKeys) {
				t.Errorf("bölümler\n got  %v\n want %v", gotKeys, wantKeys)
			}
			if d.Viewer.AllProjects != authz.BypassesProjectMembership() || d.Viewer.OrganizationRoleCode != p.roleCode ||
				d.Viewer.IsAdmin != (p.coarseRole == domain.RoleAdmin) {
				t.Errorf("viewer personayla uyuşmuyor: %+v", d.Viewer)
			}

			// 3) Gündem, kuralların kendisiyle yeniden kurulduğunda aynı.
			inputs := make([]service.DashboardAttentionInput, 0, len(d.Agenda.Groups))
			for _, g := range d.Agenda.Groups {
				inputs = append(inputs, service.DashboardAttentionInput{
					Code: g.Code, Count: g.Count, Amounts: g.Amounts, OldestDays: g.OldestDays, Items: g.Items,
				})
			}
			// Ters sırayla verilir: sıralama girdiden bağımsız olmalı.
			slices.Reverse(inputs)
			upcoming := append([]domain.UpcomingItem{}, d.Agenda.Upcoming...)
			slices.Reverse(upcoming)
			rebuilt := service.BuildDashboardAgenda(inputs, upcoming, permSet(p.perms), d.PrimaryCurrency)
			if !reflect.DeepEqual(rebuilt, d.Agenda) {
				rb, _ := json.MarshalIndent(rebuilt, "", " ")
				t.Errorf("fixture gündemi kurallarla tutarsız; kurallarla:\n%s", rb)
			}

			// 4) Her grup görünür bir bölüme ait.
			for _, g := range d.Agenda.Groups {
				if !slices.Contains(gotKeys, g.Module) {
					t.Errorf("%s grubu görünmeyen %q bölümüne ait", g.Code, g.Module)
				}
			}

			// 5) Kurulum yalnızca yeni firmada.
			if (d.Onboarding != nil) != (p.name == "empty_company") {
				t.Errorf("onboarding varlığı yanlış: %v", d.Onboarding != nil)
			}
			if d.SectionErrors == nil {
				t.Error("section_errors {} olmalı, null değil")
			}
		})
	}
}

// Saha personasında hiçbir para alanı dolu olmamalı (spec §10 kabul
// ölçütü: "no money value anywhere").
func TestDashboardFieldFixtureHasNoMoney(t *testing.T) {
	raw, _ := loadDashboardFixture(t, "field")
	var body map[string]any
	if err := json.Unmarshal(raw, &body); err != nil {
		t.Fatal(err)
	}
	assertNoMoneyValues(t, "field", body)
}

func sectionKeys(t *testing.T, raw []byte) []string {
	t.Helper()
	var body struct {
		Sections map[string]json.RawMessage `json:"sections"`
	}
	if err := json.Unmarshal(raw, &body); err != nil {
		t.Fatal(err)
	}
	keys := make([]string, 0, len(body.Sections))
	for k := range body.Sections {
		keys = append(keys, k)
	}
	return keys
}

// moneyKeys: değeri tutar olan alanlar; saha gibi finans izni olmayan bir
// izleyicide bunlar ya hiç yoktur ya da null / boş dizidir.
var moneyKeys = map[string]bool{
	"amount": true, "amounts": true, "current_value": true, "portfolio_value": true, "collected_total": true,
	"open_receivable": true, "realized_cost": true, "cash_balance": true, "paid_to_date": true,
	"committed_active": true, "approved_net_this_month": true, "by_currency": true, "approved_this_month": true,
}

func assertNoMoneyValues(t *testing.T, path string, v any) {
	t.Helper()
	switch x := v.(type) {
	case map[string]any:
		for k, child := range x {
			p := path + "." + k
			if moneyKeys[k] {
				switch c := child.(type) {
				case nil:
				case []any:
					if len(c) > 0 {
						t.Errorf("%s: para dizisi dolu: %v", p, c)
					}
				default:
					t.Errorf("%s: para değeri var: %v", p, c)
				}
				continue
			}
			assertNoMoneyValues(t, p, child)
		}
	case []any:
		for i, child := range x {
			assertNoMoneyValues(t, path+"["+itoa(i)+"]", child)
		}
	case string:
		if bytes.Contains([]byte(x), []byte(" TL")) {
			t.Errorf("%s: metinde tutar: %q", path, x)
		}
	}
}

func itoa(i int) string {
	b, _ := json.Marshal(i)
	return string(b)
}
