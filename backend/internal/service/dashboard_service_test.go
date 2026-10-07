package service_test

// Ana sayfa özetinin SQL/servis katmanı -- GERÇEK PostgreSQL'e (DB_URL)
// karşı (spec §4.11 "Service and SQL"). Veriler çoğunlukla doğrudan SQL
// ile kurulur: tarih/durum kombinasyonlarını (geçen ay, dün, iptal edilmiş
// proje, 120 gün önceki karar ...) servis akışlarıyla üretmek mümkün
// değil ya da çok dolaylı.

import (
	"context"
	"slices"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

type dashTestEnv struct {
	ctx        context.Context
	pool       *pgxpool.Pool
	offerSvc   *service.OfferService
	projectSvc *service.ProjectService
	userSvc    *service.UserService
	svc        *service.DashboardService
	org        domain.Organization
	now        time.Time
	clk        service.DashboardClock
}

func newDashTestEnv(t *testing.T, slug string) *dashTestEnv {
	t.Helper()
	dbURL := testDBURL(t)
	box := testSecretBox(t)
	ctx := context.Background()
	pool, err := repository.NewPool(ctx, dbURL)
	if err != nil {
		t.Fatalf("db: %v", err)
	}
	t.Cleanup(pool.Close)
	q := sqlc.New(pool)
	settingsSvc := service.NewSettingsService(q, box)
	now := time.Now()
	env := &dashTestEnv{
		ctx: ctx, pool: pool,
		offerSvc:   service.NewOfferService(pool, q, settingsSvc, "http://localhost:3000"),
		projectSvc: service.NewProjectService(pool, q, mustTestStore(t), settingsSvc, "http://localhost:3000"),
		userSvc:    service.NewUserService(pool, q),
		svc:        service.NewDashboardService(pool, q),
		now:        now,
		clk:        service.NewDashboardClock(now),
	}
	env.org = mustCreateOrg(t, ctx, service.NewOrganizationService(q), pool, "Dashboard "+slug, slug)
	return env
}

func (e *dashTestEnv) exec(t *testing.T, sql string, args ...any) {
	t.Helper()
	if _, err := e.pool.Exec(e.ctx, sql, args...); err != nil {
		t.Fatalf("SQL başarısız (%s): %v", sql, err)
	}
}

func (e *dashTestEnv) scalar(t *testing.T, sql string, args ...any) string {
	t.Helper()
	var out string
	if err := e.pool.QueryRow(e.ctx, sql, args...).Scan(&out); err != nil {
		t.Fatalf("SQL başarısız (%s): %v", sql, err)
	}
	return out
}

// day: bugünden gün farkıyla İstanbul takvim günü ("2006-01-02").
func (e *dashTestEnv) day(offset int) string {
	return e.clk.Today.AddDate(0, 0, offset).Format("2006-01-02")
}

func (e *dashTestEnv) monthStart() string { return e.clk.MonthStart.Format("2006-01-02") }

// project: gerçek akış (teklif -> gönder -> link -> kabul -> dönüştür),
// ardından tutar/para birimi/durum doğrudan ayarlanır.
func (e *dashTestEnv) project(t *testing.T, name, status, currency string, contract float64) *domain.Project {
	t.Helper()
	o, err := e.offerSvc.Create(e.ctx, service.CreateOfferInput{
		OrganizationID: e.org.ID, CustomerName: "Dashboard Müşteri",
		Items: []service.OfferItemInput{{ProductName: "İş", Quantity: 1, UnitPrice: 1000}},
	})
	if err != nil {
		t.Fatalf("teklif: %v", err)
	}
	if _, err := e.offerSvc.UpdateStatus(e.ctx, o.ID, e.org.ID, domain.OfferStatusGonderildi, ""); err != nil {
		t.Fatalf("gönder: %v", err)
	}
	link, err := e.offerSvc.CreateShareLink(e.ctx, o.ID, e.org.ID, "", nil)
	if err != nil {
		t.Fatalf("link: %v", err)
	}
	if _, err := e.offerSvc.RespondByShareLinkToken(e.ctx, link.Token, domain.OfferStatusKabulEdildi, "", ""); err != nil {
		t.Fatalf("kabul: %v", err)
	}
	p, err := e.projectSvc.CreateFromOffer(e.ctx, o.ID, e.org.ID, service.CreateProjectInput{Name: name})
	if err != nil {
		t.Fatalf("proje: %v", err)
	}
	e.exec(t, "UPDATE projects SET status = $2, currency = $3, contract_amount = $4 WHERE id = $1",
		p.ID, status, currency, contract)
	return p
}

func (e *dashTestEnv) owner(t *testing.T, username string) (*domain.User, *service.AuthzContext) {
	t.Helper()
	u, err := e.userSvc.Create(e.ctx, e.org.ID, username, "GeciciSifre123!", "Dashboard Sahip", domain.RoleAdmin, "")
	if err != nil {
		t.Fatalf("kullanıcı: %v", err)
	}
	authz := &service.AuthzContext{UserID: u.ID, OrganizationID: e.org.ID, RoleCode: domain.OrgRoleOwner,
		Permissions: map[string]bool{}}
	for _, c := range permsAll {
		authz.Permissions[c] = true
	}
	return u, authz
}

func (e *dashTestEnv) get(t *testing.T, authz *service.AuthzContext, role domain.Role) *domain.Dashboard {
	t.Helper()
	d, err := e.svc.Get(e.ctx, service.DashboardInput{
		OrganizationID: e.org.ID, UserID: authz.UserID, CoarseRole: role, Authz: authz, Now: e.now,
	})
	if err != nil {
		t.Fatalf("dashboard: %v", err)
	}
	if len(d.SectionErrors) != 0 {
		t.Fatalf("beklenmeyen bölüm hataları: %v", d.SectionErrors)
	}
	return d
}

func findGroup(d *domain.Dashboard, code string) *domain.AttentionGroup {
	for i := range d.Agenda.Groups {
		if d.Agenda.Groups[i].Code == code {
			return &d.Agenda.Groups[i]
		}
	}
	return nil
}

func approx(a, b float64) bool {
	d := a - b
	return d < 0.005 && d > -0.005
}

func TestDashboardFinanceSection(t *testing.T) {
	e := newDashTestEnv(t, "dash-svc-finance")
	_, authz := e.owner(t, "dash_fin_owner")
	org := e.org.ID

	pA := e.project(t, "Dashboard A", "active", "TRY", 100000)
	pB := e.project(t, "Dashboard B", "active", "TRY", 50000)
	pC := e.project(t, "Dashboard C (iptal)", "cancelled", "TRY", 80000)
	pD := e.project(t, "Dashboard D (USD)", "active", "USD", 1000000)
	ms := e.monthStart()
	lastMonth := e.clk.MonthStart.AddDate(0, 0, -1).Format("2006-01-02")

	// Ek işler: onaylı ek (bu ay) güncel bedele girer; taslak girmez.
	e.exec(t, `INSERT INTO project_change_orders (organization_id, project_id, sequence_no, change_type, title, currency,
	            status, subtotal, grand_total, approved_at) VALUES ($1, $2, 1, 'addition', 'Onaylı ek', 'TRY', 'approved', 5000, 5000, now())`, org, pA.ID)
	e.exec(t, `INSERT INTO project_change_orders (organization_id, project_id, sequence_no, change_type, title, currency,
	            status, subtotal, grand_total) VALUES ($1, $2, 2, 'addition', 'Taslak ek', 'TRY', 'draft', 7000, 7000)`, org, pA.ID)

	// Tahsilatlar: iptal edilen (voided) hariç; iptal edilmiş projeninki
	// portföyde yok ama bu ayın nakdinde var; B fazla tahsil edilmiş.
	e.exec(t, `INSERT INTO project_collections (organization_id, project_id, amount, currency, received_date)
	           VALUES ($1, $2, 30000, 'TRY', $3::date)`, org, pA.ID, ms)
	e.exec(t, `INSERT INTO project_collections (organization_id, project_id, amount, currency, received_date, voided_at)
	           VALUES ($1, $2, 5000, 'TRY', $3::date, now())`, org, pA.ID, ms)
	e.exec(t, `INSERT INTO project_collections (organization_id, project_id, amount, currency, received_date)
	           VALUES ($1, $2, 70000, 'TRY', $3::date)`, org, pB.ID, lastMonth)
	e.exec(t, `INSERT INTO project_collections (organization_id, project_id, amount, currency, received_date)
	           VALUES ($1, $2, 10000, 'TRY', $3::date)`, org, pC.ID, ms)

	// Ödeme planı (A): vadesi BUGÜN (gecikmiş değil), dün (gecikmiş), 10 gün
	// önce ama tamamı bağlı tahsilatla ödenmiş (gecikmiş değil).
	e.exec(t, "DELETE FROM project_payment_plan_items WHERE project_id = ANY($1::uuid[])",
		[]string{pA.ID, pB.ID, pC.ID, pD.ID})
	e.exec(t, `INSERT INTO project_payment_plan_items (organization_id, project_id, name, planned_amount, due_date, sort_order)
	           VALUES ($1, $2, 'Bugün vadeli', 20000, $3::date, 1)`, org, pA.ID, e.day(0))
	e.exec(t, `INSERT INTO project_payment_plan_items (organization_id, project_id, name, planned_amount, due_date, sort_order)
	           VALUES ($1, $2, 'Dün vadeli', 15000, $3::date, 2)`, org, pA.ID, e.day(-1))
	paidItem := e.scalar(t, `INSERT INTO project_payment_plan_items (organization_id, project_id, name, planned_amount, due_date, sort_order)
	           VALUES ($1, $2, 'Ödenmiş', 10000, $3::date, 3) RETURNING id::text`, org, pA.ID, e.day(-10))
	e.exec(t, `INSERT INTO project_collections (organization_id, project_id, amount, currency, received_date, payment_plan_item_id)
	           VALUES ($1, $2, 10000, 'TRY', $3::date, $4)`, org, pA.ID, ms, paidItem)

	// Maliyet: masraf + eski taşeron ödemesi + Sprint 5 taşeron ödemesi.
	// Yalnızca ONAYLI masraf sayılır (migration 0060): bekleyen ve reddedilen
	// masraflar hiçbir rakamı değiştirmemeli.
	e.exec(t, `INSERT INTO project_expenses (organization_id, project_id, category, description, amount, currency, expense_date, approval_status)
	           VALUES ($1, $2, 'material', 'Malzeme', 8000, 'TRY', $3::date, 'approved'),
	                  ($1, $2, 'material', 'Onay bekleyen', 4000, 'TRY', $3::date, 'pending'),
	                  ($1, $2, 'material', 'Reddedilen', 700, 'TRY', $3::date, 'rejected')`, org, pA.ID, ms)
	// İptal edilmiş projede karar verilemez (finans kilidi): gündeme girmez.
	e.exec(t, `INSERT INTO project_expenses (organization_id, project_id, category, description, amount, currency, expense_date, approval_status)
	           VALUES ($1, $2, 'material', 'Kapalı projede bekleyen', 900, 'TRY', $3::date, 'pending')`, org, pC.ID, ms)
	legacySub := e.scalar(t, `INSERT INTO project_subcontractors (organization_id, project_id, name, contract_amount, currency)
	           VALUES ($1, $2, 'Eski Taşeron', 10000, 'TRY') RETURNING id::text`, org, pA.ID)
	e.exec(t, `INSERT INTO project_subcontractor_payments (organization_id, project_id, subcontractor_id, amount, currency, paid_date)
	           VALUES ($1, $2, $3, 2000, 'TRY', $4::date)`, org, pA.ID, legacySub, ms)
	supplier := e.scalar(t, `INSERT INTO suppliers (organization_id, code, legal_name) VALUES ($1, 'DASH-SUP', 'Dashboard Tedarikçi') RETURNING id::text`, org)
	sc := e.scalar(t, `INSERT INTO project_subcontracts (organization_id, project_id, subcontract_no, supplier_id, title, currency, status, original_amount)
	           VALUES ($1, $2, 'DASH-SC-1', $3, 'Kaba inşaat', 'TRY', 'active', 20000) RETURNING id::text`, org, pA.ID, supplier)
	e.exec(t, `INSERT INTO subcontract_payments (organization_id, project_id, subcontract_id, amount, currency, paid_date)
	           VALUES ($1, $2, $3, 3000, 'TRY', $4::date)`, org, pA.ID, sc, ms)

	// Satış faturaları: yalnızca "issued/sent" ve vadesi DÜN olan gecikmiş.
	for _, inv := range []struct {
		no, typ, status, due string
		amount               float64
	}{
		{"DASH-F1", "sales", "issued", e.day(-1), 12000},
		{"DASH-F2", "sales", "issued", e.day(0), 9000},
		{"DASH-F3", "sales", "paid", e.day(-1), 4000},
		{"DASH-F4", "purchase", "issued", e.day(-1), 3000},
	} {
		e.exec(t, `INSERT INTO project_invoices (organization_id, project_id, invoice_no, invoice_type, invoice_date, due_date, amount, currency, status)
		           VALUES ($1, $2, $3, $4, $5::date, $6::date, $7, 'TRY', $8)`, org, pA.ID, inv.no, inv.typ, e.day(-20), inv.due, inv.amount, inv.status)
	}

	d := e.get(t, authz, domain.RoleAdmin)
	fin := d.Sections.Finance
	if fin == nil || len(fin.ByCurrency) != 2 {
		t.Fatalf("finance: iki para birimi beklenir: %+v", fin)
	}
	if fin.ByCurrency[0].Currency != "TRY" || fin.ByCurrency[1].Currency != "USD" {
		t.Fatalf("birincil para birimi (TRY) önce gelmeli (USD portföyü daha büyük olsa da): %s, %s",
			fin.ByCurrency[0].Currency, fin.ByCurrency[1].Currency)
	}
	try := fin.ByCurrency[0]
	checks := []struct {
		name      string
		got, want float64
	}{
		// A: 100.000 + onaylı ek 5.000; B: 50.000; C (iptal) hariç.
		{"portfolio_value", try.PortfolioValue, 155000},
		// A: 30.000 + bağlı 10.000 (iptal edilen 5.000 hariç); B: 70.000.
		{"collected_total", try.CollectedTotal, 110000},
		// Proje başına sıfırın altına düşmez: A 65.000 + B max(-20.000, 0).
		{"open_receivable", try.OpenReceivable, 65000},
		// Masraf 8.000 + eski taşeron 2.000 + Sprint 5 taşeron 3.000.
		{"realized_cost", try.RealizedCost, 13000},
		{"cash_balance", try.CashBalance, 97000},
		// Bu ay: iptal edilmiş C dahil (nakit gerçektir); B geçen ay.
		{"month.collections", try.Month.Collections, 50000},
		{"month.expenses", try.Month.Expenses, 8000},
		{"month.subcontract_payments", try.Month.SubcontractPayments, 5000},
		{"month.outflows", try.Month.Outflows, 13000},
		{"month.net_cash", try.Month.NetCash, 37000},
		{"overdue_plan.amount", try.OverduePlan.Amount, 15000},
		{"overdue_sales_invoices.amount", try.OverdueSalesInvoices.Amount, 12000},
	}
	for _, c := range checks {
		if !approx(c.got, c.want) {
			t.Errorf("%s = %v, beklenen %v", c.name, c.got, c.want)
		}
	}
	if try.CollectionPct == nil || !approx(*try.CollectionPct, 71.0) {
		t.Errorf("collection_pct = %v, beklenen 71.0", try.CollectionPct)
	}
	if try.OverduePlan.Count != 1 || try.OverdueSalesInvoices.Count != 1 {
		t.Errorf("gecikmiş sayıları: plan %d, fatura %d (vade günü bugün olan gecikmiş SAYILMAZ)",
			try.OverduePlan.Count, try.OverdueSalesInvoices.Count)
	}
	if len(try.Trend6m) != 6 {
		t.Fatalf("trend_6m tam 6 ay olmalı: %d", len(try.Trend6m))
	}
	if try.Trend6m[5].Month != e.clk.MonthStart.Format("2006-01") || !approx(try.Trend6m[5].Collections, 50000) ||
		!approx(try.Trend6m[5].Net, 37000) {
		t.Errorf("trendin son ayı bu ay olmalı: %+v", try.Trend6m[5])
	}
	if !approx(try.Trend6m[4].Collections, 70000) {
		t.Errorf("geçen ayın tahsilatı trendde görünmeli: %+v", try.Trend6m[4])
	}
	usd := fin.ByCurrency[1]
	if !approx(usd.PortfolioValue, 1000000) || usd.CollectionPct == nil || *usd.CollectionPct != 0 {
		t.Errorf("USD satırı: %+v", usd)
	}

	g := findGroup(d, domain.AttnPlanItemOverdue)
	if g == nil || g.Count != 1 || g.Lane != domain.LaneMine || len(g.Items) != 1 || g.Items[0].Label != "Dün vadeli" ||
		g.Items[0].Days == nil || *g.Items[0].Days != 1 || g.Items[0].Ref.Kind != domain.RefKindPaymentPlanItem {
		t.Errorf("plan_item_overdue grubu: %+v", g)
	}
	if g := findGroup(d, domain.AttnSalesInvoiceOverdue); g == nil || g.Count != 1 || g.Items[0].Label != "DASH-F1" {
		t.Errorf("sales_invoice_overdue grubu: %+v", g)
	}
	// Onay bekleyen masraf (A'da 4.000) onaylayabilen Sahip'in sırasında;
	// satır projenin Finans görünümünü açar.
	if g := findGroup(d, domain.AttnExpenseApproval); g == nil || g.Count != 1 || g.Lane != domain.LaneMine ||
		len(g.Items) != 1 || g.Items[0].Label != "Onay bekleyen" || g.Items[0].Ref.Kind != domain.RefKindProjectFinance ||
		g.Items[0].Ref.ID != pA.ID || len(g.Amounts) != 1 || !approx(g.Amounts[0].Amount, 4000) {
		t.Errorf("expense_approval grubu: %+v", g)
	}
	foundDue := false
	for _, u := range d.Agenda.Upcoming {
		if u.Kind == domain.UpcomingPlanItemDue && u.Date == e.day(0) {
			foundDue = u.Amount != nil && approx(u.Amount.Amount, 20000)
		}
	}
	if !foundDue {
		t.Errorf("vadesi bugün olan kalem Yaklaşan'da olmalı: %+v", d.Agenda.Upcoming)
	}

	co := d.Sections.ChangeOrders
	if co == nil || len(co.ByCurrency) != 1 || co.ByCurrency[0].Draft.Count != 1 || !approx(co.ByCurrency[0].Draft.Amount, 7000) ||
		!approx(co.ByCurrency[0].ApprovedNetThisMonth, 5000) {
		t.Errorf("change_orders: %+v", co)
	}
	sub := d.Sections.Subcontracts
	if sub == nil || sub.ActiveCount != 1 || len(sub.ByCurrency) != 1 || !approx(sub.ByCurrency[0].CurrentValue, 20000) ||
		sub.ByCurrency[0].PaidToDate == nil || !approx(*sub.ByCurrency[0].PaidToDate, 3000) ||
		sub.ByCurrency[0].PaidPct == nil || !approx(*sub.ByCurrency[0].PaidPct, 15) {
		t.Errorf("subcontracts: %+v", sub)
	}
	pr := d.Sections.Projects
	if pr.Counts.Active != 3 || pr.Counts.Cancelled != 1 || pr.Counts.Total != 4 {
		t.Errorf("proje sayıları: %+v", pr.Counts)
	}
	for _, row := range pr.Top {
		if row.Ref.ID == pA.ID {
			if row.CurrentValue == nil || !approx(row.CurrentValue.Amount, 105000) {
				t.Errorf("A güncel bedeli: %+v", row.CurrentValue)
			}
			if !contains(row.Flags, domain.ProjectFlagOverduePlan) {
				t.Errorf("A overdue_plan bayrağı taşımalı: %v", row.Flags)
			}
		}
		if row.Ref.ID == pC.ID {
			t.Error("iptal edilmiş proje açık proje satırlarında olmamalı")
		}
	}
	if d.Viewer.AccessibleProjectCount != 4 || !d.Viewer.AllProjects || d.Onboarding != nil {
		t.Errorf("viewer/onboarding: %+v onboarding=%v", d.Viewer, d.Onboarding)
	}
}

func TestDashboardOffersSection(t *testing.T) {
	e := newDashTestEnv(t, "dash-svc-offers")
	_, authz := e.owner(t, "dash_off_owner")
	org := e.org.ID

	newOffer := func(t *testing.T) string {
		t.Helper()
		o, err := e.offerSvc.Create(e.ctx, service.CreateOfferInput{
			OrganizationID: org, CustomerName: "Teklif Müşterisi",
			Items: []service.OfferItemInput{{ProductName: "İş", Quantity: 1, UnitPrice: 1000}},
		})
		if err != nil {
			t.Fatalf("teklif: %v", err)
		}
		return o.ID
	}
	setStatus := func(t *testing.T, id, status string) {
		t.Helper()
		e.exec(t, "UPDATE offers SET status = $2 WHERE id = $1", id, status)
		e.exec(t, "UPDATE offer_revisions SET status = $2 WHERE id = (SELECT current_revision_id FROM offers WHERE id = $1)", id, status)
	}
	event := func(t *testing.T, id, eventType, metadata string, daysAgo int) {
		t.Helper()
		e.exec(t, `INSERT INTO offer_events (organization_id, offer_id, revision_id, event_type, metadata, created_at)
		           SELECT organization_id, id, current_revision_id, $2, $3::jsonb, now() - make_interval(days => $4)
		           FROM offers WHERE id = $1`, id, eventType, metadata, daysAgo)
	}

	// O1: arşivlenmiş (is_passive) -- HİÇBİR sayıma girmez.
	o1 := newOffer(t)
	if _, err := e.offerSvc.UpdateStatus(e.ctx, o1, org, domain.OfferStatusGonderildi, ""); err != nil {
		t.Fatal(err)
	}
	e.exec(t, "UPDATE offers SET is_passive = true WHERE id = $1", o1)
	e.exec(t, "UPDATE offer_revisions SET valid_until = $2::date WHERE id = (SELECT current_revision_id FROM offers WHERE id = $1)", o1, e.day(-3))

	// O2: teklif tarihi eski, müşteri kabulü 10 gün önce -> son 90 günde.
	o2 := newOffer(t)
	e.exec(t, "UPDATE offers SET offer_date = $2::date WHERE id = $1", o2, e.day(-200))
	setStatus(t, o2, domain.OfferStatusKabulEdildi)
	event(t, o2, domain.EventCustomerAccepted, "{}", 10)

	// O3: panelden (iç) kabul -- B1: offer_updated olayına to_status yazılır.
	o3 := newOffer(t)
	if _, err := e.offerSvc.UpdateStatus(e.ctx, o3, org, domain.OfferStatusKabulEdildi, ""); err != nil {
		t.Fatal(err)
	}
	meta := e.scalar(t, `SELECT metadata->>'from_status' || '>' || (metadata->>'to_status') FROM offer_events
	                     WHERE offer_id = $1 AND event_type = 'offer_updated' ORDER BY created_at DESC LIMIT 1`, o3)
	if meta != domain.OfferStatusTaslak+">"+domain.OfferStatusKabulEdildi {
		t.Errorf("UpdateStatus olay metadata'sı = %q, beklenen taslak>kabul edildi", meta)
	}

	// O4: 120 gün önce (iç) reddedildi -> 90 gün dışında.
	o4 := newOffer(t)
	setStatus(t, o4, domain.OfferStatusReddedildi)
	event(t, o4, domain.EventOfferUpdated, `{"to_status":"`+domain.OfferStatusReddedildi+`"}`, 120)

	// O5: gönderildi, süresi dün doldu. O6: gönderildi, 3 gün sonra doluyor, müşteri bugün gördü.
	o5 := newOffer(t)
	if _, err := e.offerSvc.UpdateStatus(e.ctx, o5, org, domain.OfferStatusGonderildi, ""); err != nil {
		t.Fatal(err)
	}
	e.exec(t, "UPDATE offer_revisions SET valid_until = $2::date WHERE id = (SELECT current_revision_id FROM offers WHERE id = $1)", o5, e.day(-1))
	o6 := newOffer(t)
	if _, err := e.offerSvc.UpdateStatus(e.ctx, o6, org, domain.OfferStatusGonderildi, ""); err != nil {
		t.Fatal(err)
	}
	e.exec(t, "UPDATE offer_revisions SET valid_until = $2::date WHERE id = (SELECT current_revision_id FROM offers WHERE id = $1)", o6, e.day(3))
	event(t, o6, domain.EventCustomerViewed, "{}", 0)
	// Paylaşım linki tekrar tekrar açıldı (yenileme/önizleme botu): her
	// açılış ayrı bir customer_viewed yazar.
	for i := 0; i < 12; i++ {
		e.exec(t, `INSERT INTO offer_events (organization_id, offer_id, revision_id, event_type, created_at)
		           SELECT organization_id, id, current_revision_id, 'customer_viewed', now() - make_interval(mins => $2)
		           FROM offers WHERE id = $1`, o6, i+1)
	}

	// O7: teklif tarihi YENİ (dün) ama müşteri 30 gün önce kabul etti --
	// dönüşüm için en uzun bekleyen O7'dir (offer_date'e göre O2 önde olurdu).
	o7 := newOffer(t)
	e.exec(t, "UPDATE offers SET offer_date = $2::date WHERE id = $1", o7, e.day(-1))
	setStatus(t, o7, domain.OfferStatusKabulEdildi)
	event(t, o7, domain.EventCustomerAccepted, "{}", 30)

	d := e.get(t, authz, domain.RoleAdmin)
	off := d.Sections.Offers
	if off == nil {
		t.Fatal("offers bölümü yok")
	}
	if off.TotalActive != 6 {
		t.Errorf("total_active = %d, beklenen 6 (arşivlenmiş hariç)", off.TotalActive)
	}
	if len(off.ByCurrency) != 1 {
		t.Fatalf("by_currency: %+v", off.ByCurrency)
	}
	cur := off.ByCurrency[0]
	if cur.Accepted90d.Count != 3 || cur.Rejected90d.Count != 0 {
		t.Errorf("90 gün kararları: kabul %d (eski tarihli teklif + iç kabul + O7), red %d (120 gün önce, dışarıda)",
			cur.Accepted90d.Count, cur.Rejected90d.Count)
	}
	if off.ConversionRate90dPct == nil || *off.ConversionRate90dPct != 100 {
		t.Errorf("conversion_rate_90d_pct = %v, beklenen 100", off.ConversionRate90dPct)
	}
	if cur.AwaitingCustomer.Count != 2 || cur.Draft.Count != 0 {
		t.Errorf("yanıt bekleyen %d (O5+O6), taslak %d", cur.AwaitingCustomer.Count, cur.Draft.Count)
	}
	if off.ExpiredAwaiting != 1 || off.ExpiringWithin7d != 1 || off.ViewedByCustomer7d != 1 || off.AcceptedNotConverted != 3 {
		t.Errorf("sayılar: süresi dolan %d, 7 günde dolacak %d, görülen %d, dönüştürülmeyen %d",
			off.ExpiredAwaiting, off.ExpiringWithin7d, off.ViewedByCustomer7d, off.AcceptedNotConverted)
	}
	if g := findGroup(d, domain.AttnOfferExpiredAwaiting); g == nil || g.Count != 1 || g.Items[0].Ref.ID != o5 ||
		g.Items[0].Days == nil || *g.Items[0].Days != 1 {
		t.Errorf("offer_expired_awaiting: %+v", g)
	}
	g := findGroup(d, domain.AttnOfferAcceptedNotConverted)
	if g == nil || g.Count != 3 || g.Items[0].Ref.Action != domain.RefActionConvert {
		t.Errorf("offer_accepted_not_converted (projects.create ile convert): %+v", g)
	}
	// Kayıtlar grubun oldest_days'iyle AYNI karar tarihine göre sıralı: en
	// uzun bekleyen (O7, 30 gün) önce, sonra O2 (10 gün), sonra O3 (bugün).
	if g != nil {
		if g.OldestDays == nil || *g.OldestDays != 30 {
			t.Errorf("offer_accepted_not_converted oldest_days = %v, beklenen 30", g.OldestDays)
		}
		if len(g.Items) != 3 || g.Items[0].Ref.ID != o7 || g.Items[1].Ref.ID != o2 || g.Items[2].Ref.ID != o3 {
			ids := []string{}
			for _, it := range g.Items {
				ids = append(ids, it.Ref.ID)
			}
			t.Errorf("dönüştürülmeyen kayıt sırası = %v, beklenen [O7 %s, O2 %s, O3 %s]", ids, o7, o2, o3)
		}
	}
	// Son hareketler: 13 kez görüntülenen O6 tek satırla (en son görüntülenme)
	// yer alır; tekrarlar diğer teklif olaylarını listeden itmez.
	if d.Sections.Activity == nil {
		t.Fatal("activity bölümü yok")
	}
	views, others := 0, 0
	for _, it := range d.Sections.Activity.Items {
		if it.EventType == domain.EventCustomerViewed {
			views++
			if it.Ref.ID != o6 {
				t.Errorf("beklenmeyen görüntülenme satırı: %+v", it)
			}
		} else {
			others++
		}
	}
	if views != 1 || others == 0 {
		t.Errorf("Son hareketler: %d görüntülenme satırı (beklenen 1), %d diğer olay", views, others)
	}
	foundExpiry := false
	for _, u := range d.Agenda.Upcoming {
		if u.Kind == domain.UpcomingOfferExpiry && u.Ref.ID == o6 && u.Date == e.day(3) {
			foundExpiry = true
		}
		if u.Ref.ID == o1 {
			t.Error("arşivlenmiş teklif Yaklaşan'da görünmemeli")
		}
	}
	if !foundExpiry {
		t.Errorf("O6 Yaklaşan'da olmalı: %+v", d.Agenda.Upcoming)
	}
	// Onboarding: aktif teklif varken null (kaba admin olsa bile).
	if d.Onboarding != nil {
		t.Error("teklifi olan firmada kurulum rehberi dönmemeli")
	}
}

func TestDashboardSectionIsolationAndOnboarding(t *testing.T) {
	e := newDashTestEnv(t, "dash-svc-isolation")
	_, authz := e.owner(t, "dash_iso_owner")

	// Yeni firma: 0 proje + 0 teklif -> kaba admin için kurulum rehberi.
	d := e.get(t, authz, domain.RoleAdmin)
	if d.Onboarding == nil || d.Onboarding.Total != 6 || d.Onboarding.DoneCount != 0 {
		t.Fatalf("kurulum rehberi: %+v", d.Onboarding)
	}
	if len(service.DashboardSectionKeysFor(authz, domain.RoleAdmin)) != 20 {
		t.Error("Sahip 20 bölümün hepsini görmeli")
	}
	e.exec(t, `INSERT INTO products (organization_id, name, normalized_name, unit, unit_price, description, category, source)
	           VALUES ($1, 'Profil', 'profil', 'm', 10, '', '', 'ulas')`, e.org.ID)
	d = e.get(t, authz, domain.RoleAdmin)
	if d.Onboarding.DoneCount != 1 || !d.Onboarding.Steps[1].Done || d.Onboarding.Steps[1].Detail == nil ||
		*d.Onboarding.Steps[1].Detail != "1 ürün" {
		t.Errorf("katalog adımı: %+v", d.Onboarding.Steps[1])
	}
	// Okuma izni kişiye özel geri alınmış bir admin (rolü owner değil):
	// adım "tamamlandı" görünür ama sayılı ayrıntı dönmez -- ilgili bölüm de
	// dönmediği için sayı başka yoldan sızmamalı (spec D2).
	if _, err := e.userSvc.Create(e.ctx, e.org.ID, "dash_iso_second", "GeciciSifre123!", "İkinci", domain.RoleKullanici, ""); err != nil {
		t.Fatal(err)
	}
	revoked := &service.AuthzContext{UserID: authz.UserID, OrganizationID: e.org.ID, RoleCode: domain.OrgRoleAdmin,
		Permissions: map[string]bool{}}
	for c := range authz.Permissions {
		if c != domain.PermProductsRead && c != domain.PermOrganizationUsersRead {
			revoked.Permissions[c] = true
		}
	}
	dr := e.get(t, revoked, domain.RoleAdmin)
	if dr.Onboarding == nil {
		t.Fatal("kaba admin için kurulum rehberi dönmeli")
	}
	if dr.Sections.Products != nil || dr.Sections.Users != nil {
		t.Error("geri alınmış okuma izniyle products/users bölümü dönmemeli")
	}
	for _, st := range dr.Onboarding.Steps {
		switch st.Key {
		case domain.OnboardingStepCatalog, domain.OnboardingStepTeam:
			if !st.Done || st.Detail != nil {
				t.Errorf("%s adımı: tamamlandı olmalı, ayrıntı (sayı) null olmalı: done=%v detail=%v", st.Key, st.Done, st.Detail)
			}
		}
	}
	// Aynı veriyle tam yetkili admin sayıyı görür.
	if d = e.get(t, authz, domain.RoleAdmin); d.Onboarding.Steps[3].Detail == nil || *d.Onboarding.Steps[3].Detail != "2 kullanıcı" {
		t.Errorf("ekip adımı: %+v", d.Onboarding.Steps[3])
	}
	// Kaba admin değilse (aynı izinlerle bile) rehber de Ekip bölümü de yok.
	d2, err := e.svc.Get(e.ctx, service.DashboardInput{OrganizationID: e.org.ID, UserID: authz.UserID,
		CoarseRole: domain.RoleKullanici, Authz: authz, Now: e.now})
	if err != nil {
		t.Fatal(err)
	}
	if d2.Onboarding != nil || d2.Sections.Users != nil {
		t.Error("kaba admin olmayan kullanıcıya onboarding/users dönmemeli")
	}

	// Bir bölüm veritabanı hatası verse de diğerleri sağlam kalır.
	e.svc.FailSection(domain.DashSectionFinance, domain.DashSectionActivity)
	t.Cleanup(func() { e.svc.FailSection() })
	d3, err := e.svc.Get(e.ctx, service.DashboardInput{OrganizationID: e.org.ID, UserID: authz.UserID,
		CoarseRole: domain.RoleAdmin, Authz: authz, Now: e.now})
	if err != nil {
		t.Fatalf("bölüm hatası tüm isteği düşürmemeli: %v", err)
	}
	if len(d3.SectionErrors) != 2 || d3.SectionErrors[domain.DashSectionFinance] != domain.DashSectionFailed ||
		d3.SectionErrors[domain.DashSectionActivity] != domain.DashSectionFailed {
		t.Errorf("section_errors = %v", d3.SectionErrors)
	}
	if d3.Sections.Finance != nil || d3.Sections.Activity != nil {
		t.Error("hata veren bölüm sections'ta olmamalı")
	}
	if d3.Sections.Projects == nil || d3.Sections.Users == nil || d3.Sections.Notifications == nil || d3.Sections.Products == nil {
		t.Error("savepoint'e dönüş sonrası diğer bölümler hesaplanmalı")
	}
	// İzni olmayan bölüm hiç çalıştırılmaz, hatası da raporlanmaz.
	limited := &service.AuthzContext{UserID: authz.UserID, OrganizationID: e.org.ID, RoleCode: domain.OrgRoleField,
		Permissions: map[string]bool{domain.PermProjectsRead: true}}
	d4, err := e.svc.Get(e.ctx, service.DashboardInput{OrganizationID: e.org.ID, UserID: authz.UserID,
		CoarseRole: domain.RoleKullanici, Authz: limited, Now: e.now})
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := d4.SectionErrors[domain.DashSectionFinance]; ok {
		t.Error("izni olmayan bölüm section_errors'ta görünmemeli")
	}
	if d4.SectionErrors[domain.DashSectionActivity] != domain.DashSectionFailed {
		t.Error("activity herkes için değerlendirilir; zorlanan hatası raporlanmalı")
	}
}

func TestDashboardProjectOptionsAndMembership(t *testing.T) {
	e := newDashTestEnv(t, "dash-svc-options")
	_, ownerAuthz := e.owner(t, "dash_opt_owner")
	member, err := e.userSvc.Create(e.ctx, e.org.ID, "dash_opt_member", "GeciciSifre123!", "Üye", domain.RoleKullanici, "")
	if err != nil {
		t.Fatal(err)
	}
	p1 := e.project(t, "Seçici Bir", "active", "TRY", 1000)
	p2 := e.project(t, "Seçici İki", "planned", "TRY", 1000)
	e.project(t, "Seçici Bitti", "completed", "TRY", 1000)
	e.exec(t, "INSERT INTO project_users (organization_id, project_id, user_id, project_role) VALUES ($1, $2, $3, 'member')",
		e.org.ID, p1.ID, member.ID)

	all, err := e.svc.ProjectOptions(e.ctx, e.org.ID, ownerAuthz, "")
	if err != nil {
		t.Fatal(err)
	}
	if len(all) != 2 {
		t.Fatalf("açık projeler (tamamlanan hariç) = %d, beklenen 2", len(all))
	}
	memberAuthz := &service.AuthzContext{UserID: member.ID, OrganizationID: e.org.ID, RoleCode: domain.OrgRoleField,
		Permissions: map[string]bool{domain.PermProjectsRead: true}}
	mine, err := e.svc.ProjectOptions(e.ctx, e.org.ID, memberAuthz, "")
	if err != nil {
		t.Fatal(err)
	}
	if len(mine) != 1 || mine[0].ID != p1.ID {
		t.Errorf("üye yalnızca üyesi olduğu projeyi görmeli: %+v", mine)
	}
	found, err := e.svc.ProjectOptions(e.ctx, e.org.ID, ownerAuthz, "iki")
	if err != nil {
		t.Fatal(err)
	}
	if len(found) != 1 || found[0].ID != p2.ID {
		t.Errorf("ad araması (büyük/küçük harf duyarsız): %+v", found)
	}

	// Üyelik kısıtı dashboard sayılarında da geçerli.
	d := e.get(t, memberAuthz, domain.RoleKullanici)
	if d.Viewer.AllProjects || d.Viewer.AccessibleProjectCount != 1 || d.Sections.Projects.Counts.Total != 1 {
		t.Errorf("üyelik kapsamı: viewer %+v, projeler %+v", d.Viewer, d.Sections.Projects.Counts)
	}
	for _, row := range d.Sections.Projects.Top {
		if row.CurrentValue != nil || row.CollectionPct != nil || row.TaskProgressPct != nil {
			t.Errorf("izinsiz alt bloklar null olmalı: %+v", row)
		}
	}
}

// Taşeron / maliyet kontrolü / sözleşme / tedarikçi bölümleri: dikkat
// kodları toplam sorgusu + LIMIT 3 kayıt sorgusuyla üretilir (spec §4.6),
// bölümler arası paylaşılan sorgular (bütçe aşımı, sözleşmesiz proje) iki
// bölümde de aynı sonucu verir, Tedarikçiler'in "bu ay sipariş" notu Satın
// Alma kartıyla aynı sipariş kümesini sayar.
func TestDashboardSubcontractCostContractSections(t *testing.T) {
	e := newDashTestEnv(t, "dash-svc-subcost")
	_, authz := e.owner(t, "dash_sc_owner")
	org := e.org.ID

	p1 := e.project(t, "Alfa", "active", "TRY", 1000)
	p2 := e.project(t, "Beta", "active", "TRY", 1000)
	p3 := e.project(t, "Gama", "active", "TRY", 1000)
	p4 := e.project(t, "Delta", "active", "TRY", 1000)
	e.project(t, "Epsilon", "active", "TRY", 1000)
	pX := e.project(t, "İptal", "cancelled", "TRY", 1000)

	id := func(t *testing.T, sql string, args ...any) string { t.Helper(); return e.scalar(t, sql, args...) }
	supplier := func(t *testing.T, code string) string {
		t.Helper()
		return id(t, `INSERT INTO suppliers (organization_id, code, legal_name) VALUES ($1, $2, $2) RETURNING id::text`, org, code)
	}
	s1, s2, s3 := supplier(t, "TD-1"), supplier(t, "TD-2"), supplier(t, "TD-3")

	// --- taşeron: Alfa'da tek aktif sözleşme ---
	sc := id(t, `INSERT INTO project_subcontracts (organization_id, project_id, subcontract_no, supplier_id, title, currency, status, original_amount)
	             VALUES ($1, $2, 'TS-1', $3, 'Kaba inşaat', 'TRY', 'active', 1000) RETURNING id::text`, org, p1.ID, s1)
	claim := func(t *testing.T, no, status string, net float64, daysAgo int) string {
		t.Helper()
		return id(t, `INSERT INTO subcontract_progress_claims (organization_id, project_id, subcontract_id, claim_number, period_end,
		                  status, net_payable, submitted_at, certified_at)
		              VALUES ($1, $2, $3, $4, CURRENT_DATE, $5::text, $6, now() - make_interval(days => $7),
		                      CASE WHEN $5::text = 'certified' THEN now() - make_interval(days => $7) END) RETURNING id::text`,
			org, p1.ID, sc, no, status, net, daysAgo)
	}
	// 4 onay bekleyen hakediş (en eskisi 10 gün): sayı/toplam hepsinden,
	// kayıtlar en eski 3'ü.
	hk1 := claim(t, "HK-1", "submitted", 100, 10)
	hk2 := claim(t, "HK-2", "submitted", 100, 8)
	hk3 := claim(t, "HK-3", "submitted", 100, 6)
	claim(t, "HK-4", "submitted", 100, 4)
	// Onaylı: HK-5 kısmen ödendi (500 - 200 = 300 kaldı), HK-6 tamamen ödendi.
	hk5 := claim(t, "HK-5", "certified", 500, 20)
	hk6 := claim(t, "HK-6", "certified", 100, 15)
	pay := func(t *testing.T, claimID string, amount float64) {
		t.Helper()
		e.exec(t, `INSERT INTO subcontract_payments (organization_id, project_id, subcontract_id, progress_claim_id, amount, currency, paid_date)
		           VALUES ($1, $2, $3, $4, $5, 'TRY', CURRENT_DATE)`, org, p1.ID, sc, claimID, amount)
	}
	pay(t, hk5, 200)
	pay(t, hk6, 100)
	var cos []string
	for i, daysAgo := range []int{9, 7, 5, 3} {
		cos = append(cos, id(t, `INSERT INTO subcontract_change_orders (organization_id, project_id, subcontract_id, number, title,
		                            change_type, amount, status, requested_at)
		                        VALUES ($1, $2, $3, $4, 'Ek iş', 'addition', 50, 'submitted', now() - make_interval(days => $5))
		                        RETURNING id::text`, org, p1.ID, sc, "TD-DE-"+string(rune('1'+i)), daysAgo))
	}

	// --- maliyet: Alfa'nın onaylı bütçesi 100, bütçe kalemine bağlı masraf
	// 150 (%50 aşım); 4 onay bekleyen revizyon (en eskisi 12 gün).
	cc := id(t, `INSERT INTO organization_cost_codes (organization_id, code, name) VALUES ($1, 'MK-1', 'Beton') RETURNING id::text`, org)
	// Projeye dönüştürme taslak bir bütçe açar; Alfa'nınki onaylanır.
	budget := id(t, `UPDATE project_budgets SET status = 'baselined', currency = 'TRY' WHERE project_id = $1 AND organization_id = $2
	                 RETURNING id::text`, p1.ID, org)
	line := id(t, `INSERT INTO project_budget_lines (organization_id, project_id, budget_id, cost_code_id, original_amount)
	               VALUES ($1, $2, $3, $4, 100) RETURNING id::text`, org, p1.ID, budget, cc)
	// Onay bekleyen masraf aşımı büyütmemeli (yalnızca onaylı sayılır).
	e.exec(t, `INSERT INTO project_expenses (organization_id, project_id, category, description, amount, currency, expense_date, budget_line_id, approval_status)
	           VALUES ($1, $2, 'material', 'Beton', 150, 'TRY', CURRENT_DATE, $3, 'approved'),
	                  ($1, $2, 'material', 'Onay bekleyen', 900, 'TRY', CURRENT_DATE, $3, 'pending')`, org, p1.ID, line)
	var adjs []string
	for i, daysAgo := range []int{12, 11, 10, 9} {
		adjs = append(adjs, id(t, `INSERT INTO project_budget_adjustments (organization_id, project_id, budget_id, budget_line_id, amount, reason, status, created_at)
		                          VALUES ($1, $2, $3, $4, 10, $5, 'draft', now() - make_interval(days => $6)) RETURNING id::text`,
			org, p1.ID, budget, line, "Revizyon "+string(rune('1'+i)), daysAgo))
	}

	// --- sözleşme: yalnızca Alfa'nın sözleşmesi var ---
	e.exec(t, `INSERT INTO project_contracts (organization_id, project_id, currency, status) VALUES ($1, $2, 'TRY', 'active')`, org, p1.ID)

	// --- satın alma: bu ay onaylanan 3 sipariş; yalnızca biri geçerli ---
	po := func(t *testing.T, no, projectID, supplierID, status string) {
		t.Helper()
		e.exec(t, `INSERT INTO purchase_orders (organization_id, project_id, po_no, supplier_id, currency, issue_date, status, total, approved_at)
		           VALUES ($1, $2, $3, $4, 'TRY', CURRENT_DATE, $5, 100, now())`, org, projectID, no, supplierID, status)
	}
	po(t, "SA-1", p1.ID, s1, "approved")  // sayılır
	po(t, "SA-2", p1.ID, s2, "cancelled") // onaylandıktan sonra iptal: sayılmaz
	po(t, "SA-3", pX.ID, s3, "approved")  // iptal edilmiş projede: sayılmaz

	d := e.get(t, authz, domain.RoleAdmin)

	// Taşeron.
	sub := d.Sections.Subcontracts
	if sub == nil || sub.Claims == nil || sub.Claims.CertifiedUnpaid == nil {
		t.Fatalf("subcontracts bölümü eksik: %+v", sub)
	}
	checkCA := func(name string, ca domain.CountAmounts, count int, amount float64) {
		t.Helper()
		if ca.Count != count || len(ca.Amounts) != 1 || !approx(ca.Amounts[0].Amount, amount) {
			t.Errorf("%s = %+v, beklenen %d / %.2f", name, ca, count, amount)
		}
	}
	checkCA("claims.submitted", sub.Claims.Submitted, 4, 400)
	checkCA("claims.certified_unpaid", *sub.Claims.CertifiedUnpaid, 1, 300)
	checkCA("change_orders_submitted", sub.ChangeOrdersSubmitted, 4, 200)

	checkGroup := func(code string, count int, amount float64, oldest int, ids ...string) {
		t.Helper()
		g := findGroup(d, code)
		if g == nil {
			t.Errorf("%s grubu yok", code)
			return
		}
		if g.Count != count || g.OldestDays == nil || *g.OldestDays != oldest {
			t.Errorf("%s: count %d oldest %v, beklenen %d / %d", code, g.Count, g.OldestDays, count, oldest)
		}
		if amount >= 0 && (len(g.Amounts) != 1 || !approx(g.Amounts[0].Amount, amount)) {
			t.Errorf("%s tutarı: %+v, beklenen %.2f", code, g.Amounts, amount)
		}
		if len(g.Items) != len(ids) {
			t.Errorf("%s kayıtları: %d, beklenen %d", code, len(g.Items), len(ids))
			return
		}
		for i, want := range ids {
			if g.Items[i].Ref.ID != want {
				t.Errorf("%s kayıt %d = %s, beklenen %s (en eskiden)", code, i, g.Items[i].Ref.ID, want)
			}
		}
	}
	checkGroup(domain.AttnProgressClaimCertify, 4, 400, 10, hk1, hk2, hk3)
	checkGroup(domain.AttnClaimCertifiedUnpaid, 1, 300, 20, hk5)
	checkGroup(domain.AttnSubcontractCOApproval, 4, 200, 9, cos[0], cos[1], cos[2])
	checkGroup(domain.AttnBudgetAdjustmentApproval, 4, 40, 12, adjs[0], adjs[1], adjs[2])

	// Onaylı bütçesi olmayan 4 aktif proje (iptal edilen hariç): sayı pencere
	// sayımından, kayıtlar ada göre ilk 3.
	if g := findGroup(d, domain.AttnActiveWithoutBudget); g == nil || g.Count != 4 || len(g.Items) != 3 ||
		g.Items[0].Ref.ID != p2.ID || g.Items[1].Ref.ID != p4.ID {
		t.Errorf("active_without_budget: %+v", g)
	}

	// Bütçe aşımı ve sözleşmesiz proje: iki bölümde de aynı sonuç.
	cost := d.Sections.CostControl
	if cost == nil || cost.OverBudget == nil || cost.OverBudget.Count != 1 || cost.OverBudget.Worst == nil ||
		cost.OverBudget.Worst.Ref.ID != p1.ID || cost.OverBudget.Worst.OverrunPct != 50 {
		t.Errorf("cost_control.over_budget: %+v", cost)
	}
	if cost.PendingAdjustments == nil {
		t.Fatal("pending_adjustments null olmamalı")
	}
	checkCA("pending_adjustments", *cost.PendingAdjustments, 4, 40)
	if d.Sections.Contracts == nil || d.Sections.Contracts.ActiveProjectsWithoutContract != 4 {
		t.Errorf("contracts.active_projects_without_contract: %+v", d.Sections.Contracts)
	}
	if g := findGroup(d, domain.AttnActiveWithoutContract); g == nil || g.Count != 4 || len(g.Items) != 3 {
		t.Errorf("active_without_contract: %+v", g)
	}
	flags := map[string][]string{}
	for _, row := range d.Sections.Projects.Top {
		flags[row.Ref.ID] = row.Flags
	}
	if len(flags) != 5 {
		t.Fatalf("5 açık proje satırı beklenirdi: %+v", flags)
	}
	has := func(fs []string, f string) bool { return slices.Contains(fs, f) }
	if !has(flags[p1.ID], domain.ProjectFlagOverBudget) || has(flags[p1.ID], domain.ProjectFlagNoContract) {
		t.Errorf("Alfa bayrakları: %v (over_budget var, no_contract yok olmalı)", flags[p1.ID])
	}
	for _, p := range []string{p2.ID, p3.ID, p4.ID} {
		if has(flags[p], domain.ProjectFlagOverBudget) || !has(flags[p], domain.ProjectFlagNoContract) {
			t.Errorf("proje %s bayrakları: %v (no_contract olmalı)", p, flags[p])
		}
	}

	// Tedarikçiler "bu ay sipariş" = Satın Alma approved_this_month kümesi.
	if sup := d.Sections.Suppliers; sup == nil || sup.OrderedThisMonth == nil || *sup.OrderedThisMonth != 1 {
		t.Errorf("suppliers.ordered_this_month: %+v (iptal edilen sipariş ve iptal edilmiş proje sayılmamalı)", d.Sections.Suppliers)
	}
	if pr := d.Sections.Procurement; pr == nil || len(pr.ApprovedThisMonth) != 1 || pr.ApprovedThisMonth[0].Count != 1 {
		t.Errorf("procurement.approved_this_month: %+v", d.Sections.Procurement)
	}
}
