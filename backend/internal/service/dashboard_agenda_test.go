package service_test

// Ana sayfa gündemi (şerit, sıralama, sınırlar) ve İstanbul saati --
// saf fonksiyonlar, DB gerektirmez (spec §4.11 "Clock" ve "Agenda").

import (
	"fmt"
	"reflect"
	"testing"
	"time"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

// Varsayılan sistem rollerinin izin kümeleri (migration 0034-0044 seed'i;
// yerel dev DB'deki role_permissions ile aynı).
var (
	permsField = []string{
		"attendance.read", "notifications.read", "projects.operations.manage", "projects.operations.read",
		"projects.read", "projects.tasks.read", "projects.tasks.update",
	}
	permsFinance = []string{
		"notifications.read", "offers.internal_pricing.manage", "offers.internal_pricing.read",
		"organization.cost_codes.manage", "organization.cost_codes.read", "organization.suppliers.manage",
		"organization.suppliers.read", "projects.budget.manage", "projects.budget.read",
		"projects.contracts.lifecycle", "projects.contracts.manage", "projects.contracts.read",
		"projects.cost_control.manage", "projects.cost_control.read", "projects.finance.manage",
		"projects.finance.read", "projects.procurement.approve", "projects.procurement.manage",
		"projects.procurement.read", "projects.read", "projects.subcontract_claims.certify",
		"projects.subcontract_claims.manage", "projects.subcontract_claims.read",
		"projects.subcontract_payments.manage", "projects.subcontract_payments.read",
		"projects.subcontracts.approve", "projects.subcontracts.manage", "projects.subcontracts.read",
	}
	permsProjectManager = []string{
		"calculations.read", "customers.read", "notifications.read", "organization.cost_codes.read",
		"organization.suppliers.read", "products.read", "projects.access.read", "projects.budget.read",
		"projects.contracts.manage", "projects.contracts.read", "projects.cost_control.read",
		"projects.operations.manage", "projects.operations.read", "projects.procurement.manage",
		"projects.procurement.read", "projects.read", "projects.subcontract_claims.manage",
		"projects.subcontract_claims.read", "projects.subcontract_payments.read", "projects.subcontracts.manage",
		"projects.subcontracts.read", "projects.tasks.create", "projects.tasks.read", "projects.tasks.update",
		"projects.update",
	}
	// permsAll: Sahip/Yönetici -- kayıt defterindeki bütün izinler.
	permsAll = []string{
		domain.PermProjectsRead, domain.PermProjectsCreate, domain.PermProjectsUpdate,
		domain.PermProjectsFinanceRead, domain.PermProjectsFinanceManage,
		domain.PermProjectsTasksRead, domain.PermProjectsTasksCreate, domain.PermProjectsTasksUpdate,
		domain.PermProjectsOperationsRead, domain.PermProjectsOperationsManage,
		domain.PermProjectsAccessRead, domain.PermProjectsAccessManage,
		domain.PermOffersRead, domain.PermOffersCreate, domain.PermOffersUpdate, domain.PermOffersApprove,
		domain.PermOffersDelete, domain.PermOffersInternalPricingRead, domain.PermOffersInternalPricingManage,
		domain.PermCalculationsRead, domain.PermCalculationsManage, domain.PermProductsRead, domain.PermProductsManage,
		domain.PermCustomersRead, domain.PermCustomersManage, domain.PermEmployeesRead, domain.PermEmployeesManage,
		domain.PermAttendanceRead, domain.PermAttendanceManage,
		domain.PermOrganizationUsersRead, domain.PermOrganizationUsersManage,
		domain.PermOrganizationRolesRead, domain.PermOrganizationRolesManage,
		domain.PermOrganizationSettingsRead, domain.PermOrganizationSettingsManage,
		domain.PermProjectsBudgetRead, domain.PermProjectsBudgetManage,
		domain.PermProjectsCostControlRead, domain.PermProjectsCostControlManage,
		domain.PermOrganizationCostCodesRead, domain.PermOrganizationCostCodesManage,
		domain.PermProjectsContractsRead, domain.PermProjectsContractsManage, domain.PermProjectsContractsLifecycle,
		domain.PermOrganizationSuppliersRead, domain.PermOrganizationSuppliersManage,
		domain.PermProjectsProcurementRead, domain.PermProjectsProcurementManage, domain.PermProjectsProcurementApprove,
		domain.PermProjectsSubcontractsRead, domain.PermProjectsSubcontractsManage, domain.PermProjectsSubcontractsApprove,
		domain.PermProjectsSubcontractClaimsRead, domain.PermProjectsSubcontractClaimsManage,
		domain.PermProjectsSubcontractClaimsCertify,
		domain.PermProjectsSubcontractPaymentsRead, domain.PermProjectsSubcontractPaymentsManage,
		domain.PermNotificationsRead,
	}
)

func permSet(codes []string) func(string) bool {
	m := map[string]bool{}
	for _, c := range codes {
		m[c] = true
	}
	return func(c string) bool { return m[c] }
}

func TestDashboardClock(t *testing.T) {
	// 2026-09-30 21:30 UTC = İstanbul'da 2026-10-01 00:30 -- sunucu UTC'de
	// olsa bile "bugün" 1 Ekim olmalı.
	clk := service.NewDashboardClock(time.Date(2026, 9, 30, 21, 30, 0, 0, time.UTC))
	check := func(name string, got time.Time, want string) {
		t.Helper()
		if s := got.Format("2006-01-02"); s != want {
			t.Errorf("%s = %s, beklenen %s", name, s, want)
		}
		if got.Location().String() != "Europe/Istanbul" {
			t.Errorf("%s İstanbul saatinde değil: %s", name, got.Location())
		}
	}
	check("Today", clk.Today, "2026-10-01")
	check("MonthStart", clk.MonthStart, "2026-10-01")
	check("NextMonthStart", clk.NextMonthStart, "2026-11-01")
	check("TrendStart", clk.TrendStart, "2026-05-01") // grafik 2026-05 ... 2026-10
	check("D7Start", clk.D7Start, "2026-09-25")
	check("D30Start", clk.D30Start, "2026-09-02")
	check("D90Start", clk.D90Start, "2026-07-04")
	check("Plus6", clk.Plus6, "2026-10-07")
	check("Plus13", clk.Plus13, "2026-10-14")
	check("Plus29", clk.Plus29, "2026-10-30")
	if !clk.IsWorkday {
		t.Error("Perşembe iş günü olmalı")
	}
	// İstanbul gece yarısı sınırı: 2026-09-30T21:00Z.
	if want := time.Date(2026, 9, 30, 21, 0, 0, 0, time.UTC); !clk.Today.Equal(want) {
		t.Errorf("Today anı = %s, beklenen %s", clk.Today.UTC(), want)
	}

	sunday := service.NewDashboardClock(time.Date(2026, 10, 4, 7, 0, 0, 0, time.UTC))
	if sunday.IsWorkday {
		t.Error("Pazar iş günü sayılmamalı")
	}
	saturday := service.NewDashboardClock(time.Date(2026, 10, 3, 7, 0, 0, 0, time.UTC))
	if !saturday.IsWorkday {
		t.Error("Cumartesi iş günü (Pazartesi-Cumartesi)")
	}
	// Yılbaşı geçişi: Ocak ayında trend bir önceki yılın Ağustos'undan başlar.
	jan := service.NewDashboardClock(time.Date(2027, 1, 15, 12, 0, 0, 0, time.UTC))
	check("TrendStart(Ocak)", jan.TrendStart, "2026-08-01")
	if d := clk.DaysSince(time.Date(2026, 9, 21, 0, 0, 0, 0, time.UTC)); d != 10 {
		t.Errorf("DaysSince = %d, beklenen 10", d)
	}
}

func TestDashboardAttentionLanesPerRole(t *testing.T) {
	type roleCase struct {
		name  string
		perms []string
		want  map[string]string // kod -> "mine" | "watching" | "" (gizli)
	}
	all := func(lane string, except map[string]string) map[string]string {
		out := map[string]string{}
		for code := range domain.AttentionRules {
			out[code] = lane
		}
		for k, v := range except {
			out[k] = v
		}
		return out
	}
	cases := []roleCase{
		{"owner", permsAll, all(domain.LaneMine, map[string]string{
			// Ek işte kararı müşteri verir -- kimse aksiyon alamaz.
			domain.AttnChangeOrderAwaitingCust: domain.LaneWatching,
		})},
		{"field", permsField, all("", map[string]string{
			domain.AttnMyTaskOverdue:    domain.LaneMine,
			domain.AttnMyTaskDueToday:   domain.LaneMine,
			domain.AttnMilestoneOverdue: domain.LaneMine, // operations.manage
		})},
		{"project_manager", permsProjectManager, all("", map[string]string{
			domain.AttnPurchaseRequestApproval:  domain.LaneWatching,
			domain.AttnPurchaseOrderDraft:       domain.LaneWatching,
			domain.AttnRFQAward:                 domain.LaneWatching,
			domain.AttnRFQNoQuote:               domain.LaneMine,
			domain.AttnPOLateDelivery:           domain.LaneMine,
			domain.AttnProgressClaimCertify:     domain.LaneWatching,
			domain.AttnClaimCertifiedUnpaid:     domain.LaneWatching,
			domain.AttnSubcontractCOApproval:    domain.LaneWatching,
			domain.AttnBudgetAdjustmentApproval: domain.LaneWatching,
			domain.AttnOverBudget:               domain.LaneWatching,
			domain.AttnContractActivation:       domain.LaneWatching,
			domain.AttnContractPastCompletion:   domain.LaneWatching,
			domain.AttnActiveWithoutContract:    domain.LaneMine,
			domain.AttnProjectPastEnd:           domain.LaneMine,
			domain.AttnMyTaskOverdue:            domain.LaneMine,
			domain.AttnMyTaskDueToday:           domain.LaneMine,
			domain.AttnTeamTaskOverdue:          domain.LaneMine,
			domain.AttnTeamTaskUnassigned:       domain.LaneMine,
			domain.AttnMilestoneOverdue:         domain.LaneMine,
			domain.AttnPriceSyncFailed:          domain.LaneWatching,
		})},
		{"finance", permsFinance, all(domain.LaneMine, map[string]string{
			domain.AttnChangeOrderAwaitingCust:   domain.LaneWatching,
			domain.AttnOfferExpiredAwaiting:      "",
			domain.AttnOfferAcceptedNotConverted: "",
			domain.AttnProjectPastEnd:            "",
			domain.AttnMyTaskOverdue:             "",
			domain.AttnMyTaskDueToday:            "",
			domain.AttnTeamTaskOverdue:           "",
			domain.AttnTeamTaskUnassigned:        "",
			domain.AttnMilestoneOverdue:          "",
			domain.AttnAttendanceNotRecorded:     "",
			domain.AttnPriceSyncFailed:           "",
			domain.AttnPriceSyncNever:            "",
			domain.AttnUsersWithoutProject:       "",
		})},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			can := permSet(tc.perms)
			for code := range domain.AttentionRules {
				in := []service.DashboardAttentionInput{{Code: code, Count: 2}}
				agenda := service.BuildDashboardAgenda(in, nil, can, "TRY")
				got := ""
				if len(agenda.Groups) == 1 {
					got = agenda.Groups[0].Lane
					if agenda.Groups[0].Module != domain.AttentionRules[code].Module {
						t.Errorf("%s: modül = %s", code, agenda.Groups[0].Module)
					}
				}
				if got != tc.want[code] {
					t.Errorf("%s: şerit = %q, beklenen %q", code, got, tc.want[code])
				}
			}
		})
	}
}

func TestDashboardAgendaRankingCapsAndCounts(t *testing.T) {
	ip := func(v int) *int { return &v }
	rec := func(id string) domain.AttentionRecord {
		return domain.AttentionRecord{Ref: domain.DashboardRef{Kind: domain.RefKindOffer, ID: id, Action: domain.RefActionOpen}, Label: id}
	}
	inputs := []service.DashboardAttentionInput{
		{Code: domain.AttnChangeOrderAwaitingCust, Count: 2, OldestDays: ip(40)},                                                               // watching
		{Code: domain.AttnPurchaseRequestApproval, Count: 3, OldestDays: ip(4), Amounts: []domain.MoneyAmount{{Currency: "TRY", Amount: 100}}}, // mine action
		{Code: domain.AttnPurchaseOrderDraft, Count: 1, OldestDays: ip(4), Amounts: []domain.MoneyAmount{{Currency: "USD", Amount: 999999}, {Currency: "TRY", Amount: 500}}},
		{Code: domain.AttnRFQAward, Count: 1, OldestDays: ip(4)},         // aynı gün, tutar yok -> sonra
		{Code: domain.AttnPlanItemOverdue, Count: 4, OldestDays: ip(21)}, // mine danger
		{Code: domain.AttnProjectPastEnd, Count: 2, OldestDays: ip(30)},  // mine danger, daha eski
		{Code: domain.AttnOverBudget, Count: 1},                          // mine danger, gün yok -> danger'ların sonu
		{Code: domain.AttnOfferAcceptedNotConverted, Count: 5, Items: []domain.AttentionRecord{rec("a"), rec("b"), rec("c"), rec("d"), rec("e")}},
		{Code: "unknown_code", Count: 9},                 // bilinmeyen kod -> gizli (fail-closed)
		{Code: domain.AttnSalesInvoiceOverdue, Count: 0}, // sıfır sayı -> yok
	}
	agenda := service.BuildDashboardAgenda(inputs, nil, permSet(permsAll), "TRY")
	var order []string
	for _, g := range agenda.Groups {
		order = append(order, g.Code)
	}
	want := []string{
		domain.AttnProjectPastEnd, domain.AttnPlanItemOverdue, domain.AttnOverBudget,
		domain.AttnPurchaseOrderDraft, domain.AttnPurchaseRequestApproval, domain.AttnRFQAward,
		domain.AttnOfferAcceptedNotConverted,
		domain.AttnChangeOrderAwaitingCust,
	}
	if !reflect.DeepEqual(order, want) {
		t.Fatalf("sıralama\n got  %v\n want %v", order, want)
	}
	if agenda.MineCount != 2+4+1+1+3+1+5 || agenda.MineDangerCount != 2+4+1 || agenda.WatchingCount != 2 {
		t.Errorf("sayaçlar = mine %d / danger %d / watching %d", agenda.MineCount, agenda.MineDangerCount, agenda.WatchingCount)
	}
	for _, g := range agenda.Groups {
		if g.Items == nil || g.Amounts == nil {
			t.Errorf("%s: items/amounts null olmamalı", g.Code)
		}
		if g.Code == domain.AttnOfferAcceptedNotConverted {
			if len(g.Items) != 3 {
				t.Errorf("kayıtlar 3 ile sınırlı olmalı, %d geldi", len(g.Items))
			}
			for _, it := range g.Items {
				if it.Ref.Action != domain.RefActionConvert {
					t.Errorf("projects.create varken action = %q, beklenen convert", it.Ref.Action)
				}
			}
		}
		if g.Code == domain.AttnPurchaseOrderDraft && g.Amounts[0].Currency != "TRY" {
			t.Errorf("birincil para birimi önce gelmeli: %+v", g.Amounts)
		}
	}

	// projects.create yoksa dönüştürme aksiyonu verilmez (teklif açılır).
	noCreate := permSet([]string{domain.PermOffersRead})
	ag := service.BuildDashboardAgenda(inputs[7:8], nil, noCreate, "TRY")
	if len(ag.Groups) != 1 || ag.Groups[0].Lane != domain.LaneWatching {
		t.Fatalf("offer_accepted_not_converted izleyicide watching olmalı: %+v", ag.Groups)
	}
	for _, it := range ag.Groups[0].Items {
		if it.Ref.Action != domain.RefActionOpen {
			t.Errorf("projects.create yokken action = %q, beklenen open", it.Ref.Action)
		}
	}

	// Yaklaşan: tarih, sonra tür sırası; en fazla 8.
	var upcoming []domain.UpcomingItem
	kinds := []string{domain.UpcomingMyTaskDue, domain.UpcomingProjectEnd, domain.UpcomingPlanItemDue}
	for i := 0; i < 12; i++ {
		upcoming = append(upcoming, domain.UpcomingItem{
			Kind: kinds[i%3], Date: fmt.Sprintf("2026-10-%02d", 10-i/2),
			Ref: domain.DashboardRef{ID: fmt.Sprintf("u%02d", i)}, Title: fmt.Sprintf("t%02d", i),
		})
	}
	ag = service.BuildDashboardAgenda(nil, upcoming, noCreate, "TRY")
	if len(ag.Upcoming) != 8 {
		t.Fatalf("yaklaşanlar 8 ile sınırlı olmalı, %d geldi", len(ag.Upcoming))
	}
	for i := 1; i < len(ag.Upcoming); i++ {
		a, b := ag.Upcoming[i-1], ag.Upcoming[i]
		if a.Date > b.Date || (a.Date == b.Date && domain.UpcomingKindOrder[a.Kind] > domain.UpcomingKindOrder[b.Kind]) {
			t.Errorf("yaklaşanlar sırasız: %v -> %v", a, b)
		}
	}
	if ag.Upcoming[0].Date != "2026-10-05" {
		t.Errorf("en yakın tarih önce gelmeli, ilk = %s", ag.Upcoming[0].Date)
	}
	if ag.Groups == nil || len(ag.Groups) != 0 || ag.MineCount != 0 {
		t.Errorf("grup yokken boş dizi ve sıfır sayaç beklenir: %+v", ag)
	}
}
