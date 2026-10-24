package service_test

// Taşeron Paneli (migration 0075) -- gerçek bir PostgreSQL bağlantısı
// gerektirir. Uç güvenliği middleware/subcontractor_portal_security_test.go'da;
// burada rol korumaları ve sözleşmeli taşeronun panel rakamları.

import (
	"errors"
	"math"
	"testing"
	"time"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

func TestSubcontractorPortal(t *testing.T) {
	e := newDashTestEnv(t, "taseron-paneli")
	ctx := e.ctx
	org := e.org.ID
	q := sqlc.New(e.pool)
	supplierSvc := service.NewSupplierService(e.pool, q, testSecretBox(t))
	costCodeSvc := service.NewCostCodeService(e.pool, q)
	authz := service.NewAuthorizationService(e.pool, q)
	svc := e.projectSvc
	today := time.Now()
	near := func(a, b float64) bool { return math.Abs(a-b) < 0.005 }
	// OrganizationService.Create sistem rollerini kurmaz (platform yolu kurar).
	orgUUID, _ := repository.StringToUUID(org)
	if err := q.SeedSystemRolesForOrg(ctx, orgUUID); err != nil {
		t.Fatal(err)
	}

	card, err := supplierSvc.CreateSubcontractorCard(ctx, org, service.SupplierInput{LegalName: "Kalıp Usta", TradeName: "Kalıpçı Ali"})
	if err != nil {
		t.Fatal(err)
	}
	portalUser, err := supplierSvc.CreatePortalUser(ctx, org, card.ID, service.PortalUserInput{
		FullName: "Ali Usta", Username: "kalip_ali_portal", TemporaryPassword: "GeciciSifre123!",
	})
	if err != nil {
		t.Fatal(err)
	}
	staff, _ := e.owner(t, "taseron_paneli_sahip")

	t.Run("1_role_guards", func(t *testing.T) {
		if _, err := authz.SetUserOrganizationRole(ctx, portalUser.ID, org, "", domain.OrgRoleField); !errors.Is(err, domain.ErrPortalUserLocked) {
			t.Errorf("taşeron hesabının rolü değişmemeli: %v", err)
		}
		if _, err := authz.SetUserOrganizationRole(ctx, staff.ID, org, "", domain.OrgRoleSubcontractor); !errors.Is(err, domain.ErrRoleNotAssignable) {
			t.Errorf("çalışana Taşeron rolü elle verilememeli: %v", err)
		}
		if _, err := authz.SetUserPermissions(ctx, portalUser.ID, org, "", []string{domain.PermProjectsRead}); !errors.Is(err, domain.ErrPortalUserLocked) {
			t.Errorf("taşeron hesabına kişiye özel izin verilememeli: %v", err)
		}
		roles, err := authz.ListOrganizationRoles(ctx, org, false)
		if err != nil {
			t.Fatal(err)
		}
		for _, r := range roles {
			if r.Code == domain.OrgRoleSubcontractor {
				t.Fatal("Taşeron rolü rol seçicide görünmemeli")
			}
		}
		all, err := authz.ListOrganizationRoles(ctx, org, true)
		if err != nil {
			t.Fatal(err)
		}
		for _, r := range all {
			if r.Code == domain.OrgRoleSubcontractor {
				if _, err := authz.SetRolePermissions(ctx, r.ID, org, []string{domain.PermProjectsRead}); !errors.Is(err, domain.ErrPortalRoleLocked) {
					t.Errorf("Taşeron rolünün izinleri değişmemeli: %v", err)
				}
			}
		}
	})

	t.Run("2_contract_figures_and_grants", func(t *testing.T) {
		p := e.project(t, "Panel Sözleşmeli", domain.ProjectStatusActive, "TRY", 1000000)
		if _, err := authz.AddProjectUser(ctx, p.ID, org, service.ProjectUserInput{
			UserID: portalUser.ID, ProjectRole: domain.ProjectRoleMember,
		}); !errors.Is(err, domain.ErrPortalUserLocked) {
			t.Errorf("taşeron hesabı proje ekibine eklenmemeli: %v", err)
		}
		cc, err := costCodeSvc.Create(ctx, org, service.CostCodeInput{Code: "TP-KAL", Name: "Kalıp", Category: "Taşeron"})
		if err != nil {
			t.Fatal(err)
		}
		sc, err := svc.CreateSubcontract(ctx, p.ID, org, service.SubcontractInput{
			SupplierID: card.ID, Title: "Kalıp işleri", RetentionPercent: ptrFloat(5),
			Items: []service.SubcontractItemInput{{CostCodeID: cc.ID, Description: "Kalıp", OriginalAmount: 200000}},
		})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := svc.ActivateSubcontract(ctx, p.ID, sc.ID, org, ""); err != nil {
			t.Fatal(err)
		}
		items, err := svc.ListSubcontractItems(ctx, p.ID, sc.ID, org)
		if err != nil {
			t.Fatal(err)
		}
		claim, err := svc.CreateProgressClaim(ctx, p.ID, sc.ID, org, service.ProgressClaimInput{
			PeriodEnd: today, Items: []service.ProgressClaimItemInput{{SubcontractItemID: items[0].ID, CurrentProgressAmount: 80000}},
		})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := svc.SubmitProgressClaim(ctx, p.ID, claim.ID, org, ""); err != nil {
			t.Fatal(err)
		}
		if _, err := svc.CertifyProgressClaim(ctx, p.ID, claim.ID, org, ""); err != nil {
			t.Fatal(err)
		}
		if _, err := svc.CreateSubcontractPayment(ctx, p.ID, sc.ID, org, service.SubcontractPaymentInput{
			ProgressClaimID: claim.ID, Amount: 50000, Currency: "TRY", PaidDate: today,
		}); err != nil {
			t.Fatal(err)
		}

		// İzin yokken panelde iş görünmez.
		o, err := supplierSvc.PortalOverview(ctx, org, card.ID)
		if err != nil {
			t.Fatal(err)
		}
		if len(o.Engagements) != 0 || len(o.Payments) != 0 || o.SupplierName != "Kalıpçı Ali" {
			t.Fatalf("izinsiz proje görünmemeli: %+v", o)
		}

		if _, err := supplierSvc.SetPortalProjects(ctx, org, card.ID, []string{p.ID}, ""); err != nil {
			t.Fatal(err)
		}
		o, err = supplierSvc.PortalOverview(ctx, org, card.ID)
		if err != nil {
			t.Fatal(err)
		}
		if len(o.Engagements) != 1 || len(o.Projects) != 1 {
			t.Fatalf("izinli projedeki sözleşme görünmeli: %+v", o)
		}
		g := o.Engagements[0]
		// 80.000 onaylı iş, %5 teminat 4.000, net 76.000; 50.000 ödendi.
		if g.Kind != "contract" || g.Certified == nil || !near(*g.Certified, 80000) || !near(g.Paid, 50000) ||
			!near(g.Payable, 26000) || !near(g.Retention, 4000) || !near(g.Remaining, 150000) || !near(g.ContractAmount, 200000) {
			t.Errorf("sözleşme rakamları: %+v", g)
		}
		if len(o.Totals) != 1 || !near(o.Totals[0].Paid, 50000) || !near(o.Totals[0].Payable, 26000) {
			t.Errorf("toplamlar: %+v", o.Totals)
		}

		// İzin geri alınınca kaybolur.
		if _, err := supplierSvc.SetPortalProjects(ctx, org, card.ID, nil, ""); err != nil {
			t.Fatal(err)
		}
		if o, _ = supplierSvc.PortalOverview(ctx, org, card.ID); len(o.Engagements) != 0 {
			t.Errorf("izin geri alınınca iş görünmemeli: %+v", o.Engagements)
		}
	})

	// Taşeron hesabı firmanın personeli değildir ve proje ekibine giremez:
	// Ana Sayfa'nın "projesi olmayan" / "personel kaydı olmayan" uyarıları
	// onu saymamalı (hiç kapanmayan uyarı olurdu), personele bağlanamamalı.
	t.Run("3_not_staff", func(t *testing.T) {
		before, err := q.DashboardUserCounts(ctx, orgUUID)
		if err != nil {
			t.Fatal(err)
		}
		second, err := supplierSvc.CreatePortalUser(ctx, org, card.ID, service.PortalUserInput{
			FullName: "Veli Usta", Username: "kalip_veli_portal", TemporaryPassword: "GeciciSifre123!",
		})
		if err != nil {
			t.Fatal(err)
		}
		after, err := q.DashboardUserCounts(ctx, orgUUID)
		if err != nil {
			t.Fatal(err)
		}
		if after.Active != before.Active+1 {
			t.Errorf("aktif kullanıcı sayısı taşeron hesabını saymalı: %d -> %d", before.Active, after.Active)
		}
		if after.RestrictedWithoutProject != before.RestrictedWithoutProject || after.WithoutEmployeeLink != before.WithoutEmployeeLink {
			t.Errorf("taşeron hesabı uyarılara sayılmamalı: önce %+v, sonra %+v", before, after)
		}
		top, err := q.DashboardUsersWithoutProjectTop(ctx, orgUUID)
		if err != nil {
			t.Fatal(err)
		}
		for _, u := range top {
			if u.ID.String() == second.ID || u.ID.String() == portalUser.ID {
				t.Errorf("taşeron hesabı 'projesi olmayan' listesinde: %+v", u)
			}
		}

		employees := service.NewEmployeeService(e.pool, q)
		if _, err := employees.Create(ctx, org, service.EmployeeInput{FullName: "Bağlanamaz", IsActive: true, UserID: &second.ID}); !errors.Is(err, service.ErrEmployeeUserIsPortal) {
			t.Errorf("taşeron hesabı personele bağlanmamalı: %v", err)
		}
		// Aynı adlı personel olsa da bağlama önerisi çıkmamalı.
		if _, err := employees.Create(ctx, org, service.EmployeeInput{FullName: "Veli Usta", IsActive: true}); err != nil {
			t.Fatal(err)
		}
		sugg, err := employees.LinkSuggestions(ctx, org)
		if err != nil {
			t.Fatal(err)
		}
		for _, sg := range sugg {
			if sg.UserID == second.ID {
				t.Errorf("taşeron hesabı personel bağlama önerisinde: %+v", sg)
			}
		}
	})
}
