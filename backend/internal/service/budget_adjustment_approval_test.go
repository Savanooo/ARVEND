package service_test

// Bütçe revizyonu onayı (ürün kararı 2026-10-07, migration 0062): kişi
// kendi revizyonuna karar veremez (Sahip hariç), revize bütçeyi negatife
// düşüren onay reddedilir, yeni revizyon onay iznini taşıyanlara bildirim
// olarak düşer. Gerçek PostgreSQL gerektirir (bkz. tenant_isolation_test.go).

import (
	"context"
	"errors"
	"testing"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

func TestBudgetAdjustmentApproval(t *testing.T) {
	dbURL := testDBURL(t)
	box := testSecretBox(t)
	ctx := context.Background()

	pool, err := repository.NewPool(ctx, dbURL)
	if err != nil {
		t.Fatalf("veritabanına bağlanılamadı: %v", err)
	}
	t.Cleanup(func() { pool.Close() })

	q := sqlc.New(pool)
	userSvc := service.NewUserService(pool, q)
	authzSvc := service.NewAuthorizationService(pool, q)
	settingsSvc := service.NewSettingsService(q, box)
	offerSvc := service.NewOfferService(pool, q, settingsSvc, "http://localhost:3000")
	projectSvc := service.NewProjectService(pool, q, mustTestStore(t), settingsSvc, "http://localhost:3000")
	costCodeSvc := service.NewCostCodeService(pool, q)
	notifSvc := service.NewNotificationService(q)
	platformSvc := service.NewPlatformService(pool, q, userSvc, service.NewCalcService(q), service.NewProductService(q))

	// Sistem rolleri gerekiyor (Sahip/Finans/Proje Yöneticisi) -- sade
	// OrganizationService.Create seed_system_roles_for_org'u çağırmaz.
	const slug = "butce-onay-test"
	var existing string
	if pool.QueryRow(ctx, "SELECT id FROM organizations WHERE slug = $1", slug).Scan(&existing) == nil {
		cleanupOrganization(t, pool, existing)
	}
	created, err := platformSvc.CreateOrganizationWithOwner(ctx, service.CreateOrganizationInput{
		Name: "Bütçe Onay Test", Slug: slug,
		OwnerUsername: "owner_" + slug, OwnerPassword: "GeciciSifre123!", OwnerFullName: "Bütçe Sahibi",
	})
	if err != nil {
		t.Fatalf("firma+sahip oluşturulamadı: %v", err)
	}
	t.Cleanup(func() { cleanupOrganization(t, pool, created.Organization.ID) })
	orgID := created.Organization.ID
	owner := &created.Owner

	roleUser := func(t *testing.T, username, roleCode string) *domain.User {
		t.Helper()
		u, err := userSvc.Create(ctx, orgID, username, "GeciciSifre123!", username, domain.RoleKullanici, "")
		if err != nil {
			t.Fatalf("%s oluşturulamadı: %v", username, err)
		}
		if _, err := authzSvc.SetUserOrganizationRole(ctx, u.ID, orgID, "", roleCode); err != nil {
			t.Fatalf("%s için rol atanamadı: %v", username, err)
		}
		return u
	}
	finA := roleUser(t, "butce_fin_a", domain.OrgRoleFinance)
	finB := roleUser(t, "butce_fin_b", domain.OrgRoleFinance)
	finOutside := roleUser(t, "butce_fin_disari", domain.OrgRoleFinance) // projeye erişimi YOK
	pm := roleUser(t, "butce_pm", domain.OrgRoleProjectManager)
	admin := roleUser(t, "butce_admin", domain.OrgRoleAdmin)

	ccSeq := 0
	// newLine: kabul edilmiş tekliften proje + tek kalemli, baseline alınmış
	// bütçe. Finans A/B ve PM projenin Erişim listesine eklenir.
	newLine := func(t *testing.T, original float64) (*domain.Project, *domain.BudgetLine) {
		t.Helper()
		o, err := offerSvc.Create(ctx, service.CreateOfferInput{
			OrganizationID: orgID, CustomerName: "Bütçe Müşteri", VatRate: ptrFloat(0),
			Items: []service.OfferItemInput{{ProductName: "İş", Quantity: 1, UnitPrice: 100000}},
		})
		if err != nil {
			t.Fatalf("teklif oluşturulamadı: %v", err)
		}
		if _, err := offerSvc.UpdateStatus(ctx, o.ID, orgID, domain.OfferStatusGonderildi, ""); err != nil {
			t.Fatalf("gönderilemedi: %v", err)
		}
		link, err := offerSvc.CreateShareLink(ctx, o.ID, orgID, "", nil)
		if err != nil {
			t.Fatalf("link oluşturulamadı: %v", err)
		}
		if _, err := offerSvc.RespondByShareLinkToken(ctx, link.Token, domain.OfferStatusKabulEdildi, "", ""); err != nil {
			t.Fatalf("kabul edilemedi: %v", err)
		}
		p, err := projectSvc.CreateFromOffer(ctx, o.ID, orgID, service.CreateProjectInput{Name: "Bütçe Onay Projesi"})
		if err != nil {
			t.Fatalf("proje oluşturulamadı: %v", err)
		}
		for _, u := range []string{finA.ID, finB.ID, pm.ID} {
			if _, err := authzSvc.AddProjectUser(ctx, p.ID, orgID, service.ProjectUserInput{UserID: u, ProjectRole: domain.ProjectRoleMember, CreatedBy: owner.ID}); err != nil {
				t.Fatalf("proje erişimi verilemedi: %v", err)
			}
		}
		ccSeq++
		cc, err := costCodeSvc.Create(ctx, orgID, service.CostCodeInput{Code: "ONAY-" + string(rune('A'+ccSeq)), Name: "Onay Kodu", Category: "Malzeme"})
		if err != nil {
			t.Fatalf("maliyet kodu oluşturulamadı: %v", err)
		}
		line, err := projectSvc.CreateBudgetLine(ctx, p.ID, orgID, service.BudgetLineInput{CostCodeID: cc.ID, Description: "Onay kalemi", OriginalAmount: original})
		if err != nil {
			t.Fatalf("bütçe kalemi oluşturulamadı: %v", err)
		}
		if _, err := projectSvc.BaselineProjectBudget(ctx, p.ID, orgID, owner.ID); err != nil {
			t.Fatalf("baseline alınamadı: %v", err)
		}
		return p, line
	}
	createAdj := func(t *testing.T, p *domain.Project, line *domain.BudgetLine, amount float64, by string) *domain.BudgetAdjustment {
		t.Helper()
		a, err := projectSvc.CreateBudgetAdjustment(ctx, p.ID, orgID, service.BudgetAdjustmentInput{
			BudgetLineID: line.ID, Amount: amount, Reason: "Test revizyonu", UserID: by,
		})
		if err != nil {
			t.Fatalf("revizyon oluşturulamadı: %v", err)
		}
		return a
	}
	revised := func(t *testing.T, p *domain.Project, line *domain.BudgetLine) float64 {
		t.Helper()
		lines, err := projectSvc.CostControlLines(ctx, p.ID, orgID)
		if err != nil {
			t.Fatalf("kırılım alınamadı: %v", err)
		}
		for _, l := range lines {
			if l.BudgetLineID != nil && *l.BudgetLineID == line.ID {
				return l.RevisedBudget
			}
		}
		t.Fatalf("kalem bulunamadı")
		return 0
	}

	t.Run("own_adjustment_cannot_be_decided", func(t *testing.T) {
		p, line := newLine(t, 10000)
		adj := createAdj(t, p, line, 2000, finA.ID)
		if _, err := projectSvc.ApproveBudgetAdjustment(ctx, p.ID, adj.ID, orgID, finA.ID); !errors.Is(err, service.ErrOwnAdjustmentDecision) {
			t.Fatalf("kendi revizyonunu onaylama: beklenen ErrOwnAdjustmentDecision, geldi %v", err)
		}
		if _, err := projectSvc.RejectBudgetAdjustment(ctx, p.ID, adj.ID, orgID, finA.ID); !errors.Is(err, service.ErrOwnAdjustmentDecision) {
			t.Fatalf("kendi revizyonunu reddetme: beklenen ErrOwnAdjustmentDecision, geldi %v", err)
		}
		if got := revised(t, p, line); got != 10000 {
			t.Errorf("reddedilen karar bütçeyi değiştirmemeli: %v", got)
		}
		// Başka bir onaylayıcı karar verebilir; kararı veren kaydedilir.
		approved, err := projectSvc.ApproveBudgetAdjustment(ctx, p.ID, adj.ID, orgID, finB.ID)
		if err != nil {
			t.Fatalf("başkasının revizyonu onaylanamadı: %v", err)
		}
		if approved.ApprovedBy == nil || *approved.ApprovedBy != finB.ID {
			t.Errorf("approved_by = %v, beklenen %s", approved.ApprovedBy, finB.ID)
		}
		if got := revised(t, p, line); got != 12000 {
			t.Errorf("revize bütçe = %v, beklenen 12000", got)
		}
	})

	t.Run("admin_cannot_decide_own_adjustment", func(t *testing.T) {
		p, line := newLine(t, 10000)
		adj := createAdj(t, p, line, 500, admin.ID)
		if _, err := projectSvc.ApproveBudgetAdjustment(ctx, p.ID, adj.ID, orgID, admin.ID); !errors.Is(err, service.ErrOwnAdjustmentDecision) {
			t.Fatalf("Yönetici de kendi revizyonunu onaylayamamalı, geldi %v", err)
		}
	})

	t.Run("owner_may_decide_own_adjustment", func(t *testing.T) {
		// Tek onaylayıcısı olan küçük firma kilitlenmesin.
		p, line := newLine(t, 10000)
		adj := createAdj(t, p, line, 1500, owner.ID)
		if _, err := projectSvc.ApproveBudgetAdjustment(ctx, p.ID, adj.ID, orgID, owner.ID); err != nil {
			t.Fatalf("Sahip kendi revizyonunu onaylayabilmeli: %v", err)
		}
		adj2 := createAdj(t, p, line, 700, owner.ID)
		if _, err := projectSvc.RejectBudgetAdjustment(ctx, p.ID, adj2.ID, orgID, owner.ID); err != nil {
			t.Fatalf("Sahip kendi revizyonunu reddedebilmeli: %v", err)
		}
		if got := revised(t, p, line); got != 11500 {
			t.Errorf("revize bütçe = %v, beklenen 11500", got)
		}
	})

	t.Run("approval_cannot_push_revised_budget_below_zero", func(t *testing.T) {
		p, line := newLine(t, 1000)
		tooMuch := createAdj(t, p, line, -1000.01, finA.ID)
		if _, err := projectSvc.ApproveBudgetAdjustment(ctx, p.ID, tooMuch.ID, orgID, finB.ID); !errors.Is(err, service.ErrAdjustmentWouldGoNegative) {
			t.Fatalf("beklenen ErrAdjustmentWouldGoNegative, geldi %v", err)
		}
		// Reddetmek bütçeyi değiştirmez -- serbest.
		if _, err := projectSvc.RejectBudgetAdjustment(ctx, p.ID, tooMuch.ID, orgID, finB.ID); err != nil {
			t.Fatalf("negatife düşürecek revizyon reddedilebilmeli: %v", err)
		}
		// Tam sıfıra indirmek serbest (numeric karşılaştırma, float gürültüsü yok).
		toZero := createAdj(t, p, line, -1000, finA.ID)
		if _, err := projectSvc.ApproveBudgetAdjustment(ctx, p.ID, toZero.ID, orgID, finB.ID); err != nil {
			t.Fatalf("revize bütçeyi tam sıfıra indiren revizyon onaylanabilmeli: %v", err)
		}
		if got := revised(t, p, line); got != 0 {
			t.Errorf("revize bütçe = %v, beklenen 0", got)
		}
	})

	t.Run("negative_check_counts_approved_adjustments", func(t *testing.T) {
		p, line := newLine(t, 1000)
		plus := createAdj(t, p, line, 500, finA.ID)
		minus := createAdj(t, p, line, -1400, finA.ID)
		// Artış henüz onaylanmadan azaltım bütçeyi negatife düşürür.
		if _, err := projectSvc.ApproveBudgetAdjustment(ctx, p.ID, minus.ID, orgID, finB.ID); !errors.Is(err, service.ErrAdjustmentWouldGoNegative) {
			t.Fatalf("beklenen ErrAdjustmentWouldGoNegative, geldi %v", err)
		}
		if _, err := projectSvc.ApproveBudgetAdjustment(ctx, p.ID, plus.ID, orgID, finB.ID); err != nil {
			t.Fatalf("artış onaylanamadı: %v", err)
		}
		// 1000 + 500 - 1400 = 100 >= 0
		if _, err := projectSvc.ApproveBudgetAdjustment(ctx, p.ID, minus.ID, orgID, finB.ID); err != nil {
			t.Fatalf("onaylı artıştan sonra azaltım onaylanabilmeli: %v", err)
		}
		if got := revised(t, p, line); got != 100 {
			t.Errorf("revize bütçe = %v, beklenen 100", got)
		}
	})

	t.Run("new_adjustment_notifies_approvers_except_creator", func(t *testing.T) {
		p, line := newLine(t, 5000)
		before := map[string]int64{}
		users := map[string]*domain.User{
			"owner": owner, "admin": admin, "finA": finA, "finB": finB, "finOutside": finOutside, "pm": pm,
		}
		count := func(t *testing.T, u *domain.User) int64 {
			t.Helper()
			res, err := notifSvc.List(ctx, u.ID, orgID, 1, 100)
			if err != nil {
				t.Fatalf("bildirimler alınamadı: %v", err)
			}
			var n int64
			for _, nt := range res.Notifications {
				if nt.Type == domain.NotificationBudgetAdjustmentSubmitted && nt.ProjectID != nil && *nt.ProjectID == p.ID {
					n++
					if nt.ActionTarget != "/projeler/"+p.ID+"/maliyet/revizyonlar" {
						t.Errorf("action_target = %q", nt.ActionTarget)
					}
					if nt.EntityType != domain.NotificationEntityBudgetAdjustment {
						t.Errorf("entity_type = %q", nt.EntityType)
					}
				}
			}
			return n
		}
		for name, u := range users {
			before[name] = count(t, u)
		}
		createAdj(t, p, line, 250, finA.ID)
		want := map[string]int64{
			"owner": 1, "admin": 1, "finB": 1, // onay izni + projeye erişim
			"finA":       0, // oluşturan
			"finOutside": 0, // izni var ama projede değil
			"pm":         0, // onay izni yok
		}
		for name, u := range users {
			if got := count(t, u) - before[name]; got != want[name] {
				t.Errorf("%s: %d bildirim, beklenen %d", name, got, want[name])
			}
		}
	})
}
