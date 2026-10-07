package service_test

// Masraf onayı (migration 0060) -- gerçek bir PostgreSQL bağlantısı
// gerektirir. Kural: her masraf onay bekleyerek doğar, para toplamlarına
// yalnızca onaylı (ve iptal edilmemiş) masraf girer; onay/ret
// projects.expenses.approve ister (izin kapısı HTTP katmanında, bkz.
// middleware/expense_approval_security_test.go).

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

// createApprovedExpense, masrafı girip onaylar: toplamları sınayan testler
// "girilmiş ve onaylanmış" masraf kurar (onay bekleyen masraf sayılmaz).
func createApprovedExpense(ctx context.Context, svc *service.ProjectService, projectID, orgID string, in service.ExpenseInput) (*domain.Expense, error) {
	e, err := svc.CreateExpense(ctx, projectID, orgID, in)
	if err != nil {
		return nil, err
	}
	return svc.ApproveExpense(ctx, projectID, e.ID, orgID, in.UserID)
}

func TestExpenseApproval(t *testing.T) {
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

	// Sistem rolleri seed edilmiş firma (OrganizationService.Create rolleri
	// seed etmez -- bkz. notification_events_test.go).
	mustCreateReadyOrg := func(t *testing.T, slug string) *service.CreateOrganizationResult {
		t.Helper()
		var existingID string
		if err := pool.QueryRow(ctx, "SELECT id FROM organizations WHERE slug = $1", slug).Scan(&existingID); err == nil {
			cleanupOrganization(t, pool, existingID)
		}
		res, err := platformSvc.CreateOrganizationWithOwner(ctx, service.CreateOrganizationInput{
			Name: "Masraf Onay " + slug, Slug: slug,
			OwnerUsername: "owner_" + slug, OwnerPassword: "GeciciSifre123!", OwnerFullName: "Onay Sahibi",
		})
		if err != nil {
			t.Fatalf("firma oluşturulamadı: %v", err)
		}
		t.Cleanup(func() { cleanupOrganization(t, pool, res.Organization.ID) })
		return res
	}
	orgARes := mustCreateReadyOrg(t, "masraf-onay-a")
	orgA := orgARes.Organization
	owner := &orgARes.Owner
	orgB := mustCreateReadyOrg(t, "masraf-onay-b").Organization

	roleUser := func(t *testing.T, username, roleCode string) *domain.User {
		t.Helper()
		u, err := userSvc.Create(ctx, orgA.ID, username, "GeciciSifre123!", username, domain.RoleKullanici, "")
		if err != nil {
			t.Fatalf("%s oluşturulamadı: %v", username, err)
		}
		if _, err := authzSvc.SetUserOrganizationRole(ctx, u.ID, orgA.ID, "", roleCode); err != nil {
			t.Fatalf("%s rolü atanamadı: %v", username, err)
		}
		return u
	}
	admin := roleUser(t, "exp_admin", domain.OrgRoleAdmin)
	finance := roleUser(t, "exp_finance", domain.OrgRoleFinance)
	financeOutside := roleUser(t, "exp_finance_out", domain.OrgRoleFinance)
	pm := roleUser(t, "exp_pm", domain.OrgRoleProjectManager)
	// Eski Sistem kullanıcısı finance.manage taşır ama onay iznini taşımaz:
	// sahada masrafı giren tipik kişi.
	clerk := roleUser(t, "exp_clerk", domain.OrgRoleLegacyUser)

	newProject := func(t *testing.T, orgID string) *domain.Project {
		t.Helper()
		o, err := offerSvc.Create(ctx, service.CreateOfferInput{
			OrganizationID: orgID, CustomerName: "Masraf Onay Müşteri", VatRate: ptrFloat(0),
			Items: []service.OfferItemInput{{ProductName: "İş", Quantity: 1, UnitPrice: 100000}},
		})
		if err != nil {
			t.Fatalf("teklif: %v", err)
		}
		if _, err := offerSvc.UpdateStatus(ctx, o.ID, orgID, domain.OfferStatusGonderildi, ""); err != nil {
			t.Fatalf("gönderilemedi: %v", err)
		}
		link, err := offerSvc.CreateShareLink(ctx, o.ID, orgID, "", nil)
		if err != nil {
			t.Fatalf("link: %v", err)
		}
		if _, err := offerSvc.RespondByShareLinkToken(ctx, link.Token, domain.OfferStatusKabulEdildi, "", ""); err != nil {
			t.Fatalf("kabul: %v", err)
		}
		p, err := projectSvc.CreateFromOffer(ctx, o.ID, orgID, service.CreateProjectInput{Name: "Masraf Onay Projesi"})
		if err != nil {
			t.Fatalf("proje: %v", err)
		}
		if orgID == orgA.ID {
			for _, u := range []*domain.User{finance, pm} {
				if _, err := authzSvc.AddProjectUser(ctx, p.ID, orgA.ID, service.ProjectUserInput{
					UserID: u.ID, ProjectRole: domain.ProjectRoleMember, CreatedBy: owner.ID,
				}); err != nil {
					t.Fatalf("proje erişimi: %v", err)
				}
			}
		}
		return p
	}

	today := time.Now()
	expense := func(t *testing.T, p *domain.Project, by string, amount float64) *domain.Expense {
		t.Helper()
		e, err := projectSvc.CreateExpense(ctx, p.ID, orgA.ID, service.ExpenseInput{
			Category: domain.ExpenseMaterial, Description: "Çimento", Amount: amount, Currency: "TRY",
			ExpenseDate: today, UserID: by,
		})
		if err != nil {
			t.Fatalf("masraf eklenemedi: %v", err)
		}
		return e
	}
	totalExpenses := func(t *testing.T, p *domain.Project) float64 {
		t.Helper()
		s, err := projectSvc.FinancialSummary(ctx, p.ID, orgA.ID)
		if err != nil {
			t.Fatalf("özet: %v", err)
		}
		return s.TotalExpenses
	}
	notices := func(t *testing.T, userID, notifType string) []domain.Notification {
		t.Helper()
		res, err := notifSvc.List(ctx, userID, orgA.ID, 1, 100)
		if err != nil {
			t.Fatalf("bildirimler: %v", err)
		}
		var out []domain.Notification
		for _, n := range res.Notifications {
			if n.Type == notifType {
				out = append(out, n)
			}
		}
		return out
	}

	t.Run("1_permission_seeded_for_owner_admin_only", func(t *testing.T) {
		rows, err := pool.Query(ctx, `SELECT r.code FROM role_permissions rp
			JOIN organization_roles r ON r.id = rp.organization_role_id
			WHERE r.organization_id = $1 AND rp.permission_code = $2 ORDER BY r.code`, orgA.ID, domain.PermProjectsExpensesApprove)
		if err != nil {
			t.Fatal(err)
		}
		var codes []string
		for rows.Next() {
			var c string
			if err := rows.Scan(&c); err != nil {
				t.Fatal(err)
			}
			codes = append(codes, c)
		}
		// Finans masraf girer ama onaylamaz (migration 0066, ürün sahibi
		// kararı: "onaylamayı sadece yönetici yapacak").
		if strings.Join(codes, ",") != "admin,owner" {
			t.Errorf("yeni firmada onay izni yalnızca Sahip/Yönetici'de olmalı, geldi: %v", codes)
		}
		var desc, category string
		if err := pool.QueryRow(ctx, `SELECT description, category FROM permissions WHERE code = $1`,
			domain.PermProjectsExpensesApprove).Scan(&desc, &category); err != nil || category != "Finans" || desc == "" {
			t.Errorf("izin kataloğu kaydı eksik: %q %q %v", desc, category, err)
		}
	})

	t.Run("2_new_expense_is_pending_and_not_counted", func(t *testing.T) {
		p := newProject(t, orgA.ID)
		e := expense(t, p, clerk.ID, 1000)
		if e.ApprovalStatus != domain.ExpenseApprovalPending || e.DecidedAt != nil {
			t.Fatalf("yeni masraf onay beklemeli: %+v", e)
		}
		// Sahip'in girdiği masraf da onay bekler.
		if own := expense(t, p, owner.ID, 50); own.ApprovalStatus != domain.ExpenseApprovalPending {
			t.Errorf("Sahip'in masrafı da onay beklemeli: %s", own.ApprovalStatus)
		}
		if got := totalExpenses(t, p); got != 0 {
			t.Errorf("onay bekleyen masraf toplama girmemeli: %v", got)
		}
		list, err := projectSvc.ListExpenses(ctx, p.ID, orgA.ID)
		if err != nil || len(list) != 2 {
			t.Fatalf("liste tüm masrafları göstermeli: %d %v", len(list), err)
		}
	})

	t.Run("3_approvers_get_one_grouped_notice_creator_and_outsiders_none", func(t *testing.T) {
		p := newProject(t, orgA.ID)
		expense(t, p, clerk.ID, 100)
		expense(t, p, clerk.ID, 200)
		target := "/projeler/" + p.ID + "?grup=finans&alt=finans"
		for _, u := range []*domain.User{owner, admin} {
			var mine []domain.Notification
			for _, n := range notices(t, u.ID, domain.NotificationExpensePendingApproval) {
				if n.ProjectID != nil && *n.ProjectID == p.ID {
					mine = append(mine, n)
				}
			}
			if len(mine) != 1 || mine[0].Title != "2 masraf onay bekliyor" || mine[0].ActionTarget != target {
				t.Errorf("%s tek, gruplu bildirim almalı: %+v", u.Username, mine)
				continue
			}
			if !strings.Contains(mine[0].Body, "exp_clerk") || strings.Contains(mine[0].Body, "200") {
				t.Errorf("gövde giren kişiyi taşımalı, tutarı taşımamalı: %q", mine[0].Body)
			}
		}
		// Onay izni olmayan Finans (projede olsa da, 0066), PM ve giren kişi
		// almaz.
		for _, u := range []*domain.User{finance, financeOutside, pm, clerk} {
			if n := len(notices(t, u.ID, domain.NotificationExpensePendingApproval)); n != 0 {
				t.Errorf("%s bildirim almamalı (%d)", u.Username, n)
			}
		}
	})

	t.Run("4_approve_counts_and_tells_the_creator", func(t *testing.T) {
		p := newProject(t, orgA.ID)
		e := expense(t, p, clerk.ID, 1000)
		got, err := projectSvc.ApproveExpense(ctx, p.ID, e.ID, orgA.ID, admin.ID)
		if err != nil {
			t.Fatalf("onaylanamadı: %v", err)
		}
		if got.ApprovalStatus != domain.ExpenseApprovalApproved || got.DecidedBy == nil || *got.DecidedBy != admin.ID || got.DecidedAt == nil {
			t.Errorf("onay izi eksik: %+v", got)
		}
		if total := totalExpenses(t, p); total != 1000 {
			t.Errorf("onaylanan masraf toplama girmeli: %v", total)
		}
		if n := notices(t, clerk.ID, domain.NotificationExpenseApproved); len(n) == 0 || n[0].Title != "Masraf onaylandı" {
			t.Errorf("giren kişiye onay bildirimi gitmeli: %+v", n)
		}
		if _, err := projectSvc.ApproveExpense(ctx, p.ID, e.ID, orgA.ID, admin.ID); !errors.Is(err, service.ErrExpenseNotPending) {
			t.Errorf("ikinci karar reddedilmeli: %v", err)
		}
		if _, err := projectSvc.RejectExpense(ctx, p.ID, e.ID, orgA.ID, admin.ID, "geç"); !errors.Is(err, service.ErrExpenseNotPending) {
			t.Errorf("onaylı masraf reddedilememeli: %v", err)
		}
	})

	t.Run("5_reject_needs_a_reason_and_is_never_counted", func(t *testing.T) {
		p := newProject(t, orgA.ID)
		e := expense(t, p, clerk.ID, 700)
		if _, err := projectSvc.RejectExpense(ctx, p.ID, e.ID, orgA.ID, admin.ID, "   "); !errors.Is(err, service.ErrExpenseRejectReasonRequired) {
			t.Errorf("gerekçesiz ret: %v", err)
		}
		if _, err := projectSvc.RejectExpense(ctx, p.ID, e.ID, orgA.ID, admin.ID, strings.Repeat("ş", 501)); !errors.Is(err, service.ErrExpenseRejectReasonTooLong) {
			t.Errorf("uzun gerekçe: %v", err)
		}
		got, err := projectSvc.RejectExpense(ctx, p.ID, e.ID, orgA.ID, admin.ID, "Fatura eksik")
		if err != nil {
			t.Fatalf("reddedilemedi: %v", err)
		}
		if got.ApprovalStatus != domain.ExpenseApprovalRejected || got.DecisionNote != "Fatura eksik" {
			t.Errorf("ret izi: %+v", got)
		}
		if total := totalExpenses(t, p); total != 0 {
			t.Errorf("reddedilen masraf toplama girmemeli: %v", total)
		}
		n := notices(t, clerk.ID, domain.NotificationExpenseRejected)
		if len(n) == 0 || n[0].Title != "Masraf reddedildi" || !strings.Contains(n[0].Body, "Fatura eksik") {
			t.Errorf("giren kişiye gerekçeli ret bildirimi gitmeli: %+v", n)
		}
		if _, err := projectSvc.ApproveExpense(ctx, p.ID, e.ID, orgA.ID, admin.ID); !errors.Is(err, service.ErrExpenseNotPending) {
			t.Errorf("reddedilen masraf düzenlenmeden onaylanamamalı: %v", err)
		}
	})

	t.Run("6_edit_sends_it_back_to_pending", func(t *testing.T) {
		p := newProject(t, orgA.ID)
		e := expense(t, p, clerk.ID, 1000)
		if _, err := projectSvc.ApproveExpense(ctx, p.ID, e.ID, orgA.ID, admin.ID); err != nil {
			t.Fatal(err)
		}
		before := len(notices(t, admin.ID, domain.NotificationExpensePendingApproval))
		edit := service.ExpenseInput{Category: domain.ExpenseMaterial, Description: "Çimento (düzeltildi)", Amount: 1500, ExpenseDate: today, UserID: clerk.ID}
		got, err := projectSvc.UpdateExpense(ctx, p.ID, e.ID, orgA.ID, edit)
		if err != nil {
			t.Fatalf("düzenlenemedi: %v", err)
		}
		if got.ApprovalStatus != domain.ExpenseApprovalPending || got.DecidedBy != nil || got.DecidedAt != nil {
			t.Errorf("düzenlenen masraf yeniden onay beklemeli, karar temizlenmeli: %+v", got)
		}
		if total := totalExpenses(t, p); total != 0 {
			t.Errorf("düzenlenen (onaysız) tutar toplamda kalmamalı: %v", total)
		}
		// Onaylayıcı yeniden haberdar edilir (okunmamış grup büyür ya da yenisi açılır).
		after := notices(t, admin.ID, domain.NotificationExpensePendingApproval)
		if len(after) < before || len(after) == 0 || after[0].ProjectID == nil || *after[0].ProjectID != p.ID {
			t.Errorf("düzenleme onaylayıcıya bildirilmeli: önce %d, sonra %+v", before, after)
		}

		// Reddedilen masraf düzeltilince gerekçe temizlenir, yeniden onaya düşer.
		r := expense(t, p, clerk.ID, 300)
		if _, err := projectSvc.RejectExpense(ctx, p.ID, r.ID, orgA.ID, admin.ID, "Yanlış tutar"); err != nil {
			t.Fatal(err)
		}
		edit.Amount = 250
		got, err = projectSvc.UpdateExpense(ctx, p.ID, r.ID, orgA.ID, edit)
		if err != nil || got.ApprovalStatus != domain.ExpenseApprovalPending || got.DecisionNote != "" {
			t.Errorf("reddedilen düzeltilince onaya dönmeli: %+v %v", got, err)
		}
		if _, err := projectSvc.ApproveExpense(ctx, p.ID, r.ID, orgA.ID, admin.ID); err != nil {
			t.Errorf("düzeltilen masraf onaylanabilmeli: %v", err)
		}
		if total := totalExpenses(t, p); total != 250 {
			t.Errorf("yalnızca onaylı tutar sayılmalı: %v", total)
		}
	})

	t.Run("7_void_works_for_every_status", func(t *testing.T) {
		p := newProject(t, orgA.ID)
		pending := expense(t, p, clerk.ID, 10)
		rejected := expense(t, p, clerk.ID, 20)
		if _, err := projectSvc.RejectExpense(ctx, p.ID, rejected.ID, orgA.ID, admin.ID, "Mükerrer"); err != nil {
			t.Fatal(err)
		}
		approved, err := createApprovedExpense(ctx, projectSvc, p.ID, orgA.ID, service.ExpenseInput{
			Category: domain.ExpenseMaterial, Description: "Onaylı", Amount: 30, ExpenseDate: today,
		})
		if err != nil {
			t.Fatal(err)
		}
		for _, e := range []*domain.Expense{pending, rejected, approved} {
			if _, err := projectSvc.VoidExpense(ctx, p.ID, e.ID, orgA.ID, clerk.ID, "hatalı"); err != nil {
				t.Errorf("%s masraf iptal edilemedi: %v", e.ApprovalStatus, err)
			}
		}
		if total := totalExpenses(t, p); total != 0 {
			t.Errorf("iptal edilen onaylı masraf düşmeli: %v", total)
		}
		if _, err := projectSvc.ApproveExpense(ctx, p.ID, pending.ID, orgA.ID, admin.ID); !errors.Is(err, service.ErrAlreadyVoided) {
			t.Errorf("iptal edilmiş masraf onaylanamamalı: %v", err)
		}
	})

	t.Run("8_closed_project_locks_decisions", func(t *testing.T) {
		p := newProject(t, orgA.ID)
		e := expense(t, p, clerk.ID, 10)
		if _, err := projectSvc.Update(ctx, p.ID, orgA.ID, service.UpdateProjectInput{Name: p.Name, Status: domain.ProjectStatusCancelled}); err != nil {
			t.Fatalf("iptal edilemedi: %v", err)
		}
		if _, err := projectSvc.ApproveExpense(ctx, p.ID, e.ID, orgA.ID, admin.ID); !errors.Is(err, service.ErrProjectLocked) {
			t.Errorf("kapalı projede onay: %v", err)
		}
		if _, err := projectSvc.RejectExpense(ctx, p.ID, e.ID, orgA.ID, admin.ID, "x"); !errors.Is(err, service.ErrProjectLocked) {
			t.Errorf("kapalı projede ret: %v", err)
		}
	})

	t.Run("9_scoped_to_org_and_project", func(t *testing.T) {
		p := newProject(t, orgA.ID)
		other := newProject(t, orgA.ID)
		e := expense(t, p, clerk.ID, 10)
		if _, err := projectSvc.ApproveExpense(ctx, p.ID, e.ID, orgB.ID, admin.ID); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("başka firma onaylayabildi: %v", err)
		}
		if _, err := projectSvc.ApproveExpense(ctx, other.ID, e.ID, orgA.ID, admin.ID); !errors.Is(err, service.ErrExpenseNotFound) {
			t.Errorf("başka projenin URL'siyle onaylanabildi: %v", err)
		}
		if _, err := projectSvc.RejectExpense(ctx, other.ID, e.ID, orgA.ID, admin.ID, "x"); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("başka projenin URL'siyle reddedilebildi: %v", err)
		}
	})

	t.Run("10_self_approval_allowed_without_self_notices", func(t *testing.T) {
		p := newProject(t, orgA.ID)
		ownerPendingBefore := len(notices(t, owner.ID, domain.NotificationExpensePendingApproval))
		e := expense(t, p, owner.ID, 400)
		if n := len(notices(t, owner.ID, domain.NotificationExpensePendingApproval)); n != ownerPendingBefore {
			t.Errorf("giren onaylayıcı kendi masrafı için bildirim almamalı")
		}
		approvedBefore := len(notices(t, owner.ID, domain.NotificationExpenseApproved))
		if _, err := projectSvc.ApproveExpense(ctx, p.ID, e.ID, orgA.ID, owner.ID); err != nil {
			t.Fatalf("onaylayan kendi masrafını onaylayabilmeli: %v", err)
		}
		if n := len(notices(t, owner.ID, domain.NotificationExpenseApproved)); n != approvedBefore {
			t.Errorf("kendi kararı kendine bildirilmemeli")
		}
	})

	t.Run("11_every_total_ignores_unapproved_expenses", func(t *testing.T) {
		p := newProject(t, orgA.ID)
		cc, err := costCodeSvc.Create(ctx, orgA.ID, service.CostCodeInput{Code: "ONAY-" + p.ID[:8], Name: "Onay testi", Category: "Malzeme"})
		if err != nil {
			t.Fatal(err)
		}
		line, err := projectSvc.CreateBudgetLine(ctx, p.ID, orgA.ID, service.BudgetLineInput{CostCodeID: cc.ID, Description: "Kalem", OriginalAmount: 10000})
		if err != nil {
			t.Fatal(err)
		}
		co, err := projectSvc.CreateChangeOrder(ctx, p.ID, orgA.ID, service.ChangeOrderInput{
			ChangeType: domain.ChangeOrderAddition, Title: "Ek iş",
			Items: []service.ChangeOrderItemInput{{Description: "Kalem", Quantity: 1, Unit: "adet", UnitPrice: 5000}},
		})
		if err != nil {
			t.Fatal(err)
		}
		in := func(amount float64) service.ExpenseInput {
			return service.ExpenseInput{
				Category: domain.ExpenseMaterial, Description: "Masraf", Amount: amount, ExpenseDate: today,
				BudgetLineID: line.ID, ChangeOrderID: co.ID, UserID: clerk.ID,
			}
		}
		if _, err := createApprovedExpense(ctx, projectSvc, p.ID, orgA.ID, in(300)); err != nil {
			t.Fatal(err)
		}
		if _, err := projectSvc.CreateExpense(ctx, p.ID, orgA.ID, in(500)); err != nil { // onay bekliyor
			t.Fatal(err)
		}
		rej, err := projectSvc.CreateExpense(ctx, p.ID, orgA.ID, in(700))
		if err != nil {
			t.Fatal(err)
		}
		if _, err := projectSvc.RejectExpense(ctx, p.ID, rej.ID, orgA.ID, admin.ID, "Hayır"); err != nil {
			t.Fatal(err)
		}

		if got := totalExpenses(t, p); got != 300 {
			t.Errorf("finans özeti: %v", got)
		}
		lines, err := projectSvc.CostControlLines(ctx, p.ID, orgA.ID)
		if err != nil || len(lines) != 1 || lines[0].ActualCost != 300 {
			t.Errorf("maliyet kırılımı gerçekleşen: %+v %v", lines, err)
		}
		cs, err := projectSvc.CostControlSummary(ctx, p.ID, orgA.ID)
		if err != nil || cs.ActualCost != 300 {
			t.Errorf("maliyet özeti gerçekleşen: %+v %v", cs, err)
		}
		cos, err := projectSvc.ListChangeOrders(ctx, p.ID, orgA.ID)
		if err != nil || len(cos) != 1 || cos[0].Profitability == nil || cos[0].Profitability.RealizedCost != 300 {
			t.Errorf("ek iş gerçekleşen maliyeti: %+v %v", cos, err)
		}
		list, err := projectSvc.List(ctx, orgA.ID, service.ProjectListFilter{Search: p.ProjectNo})
		if err != nil {
			t.Fatal(err)
		}
		found := false
		for _, row := range list.Projects {
			if row.ID == p.ID {
				found = true
				if row.TotalExpenses != 300 {
					t.Errorf("proje listesi masraf toplamı: %v", row.TotalExpenses)
				}
			}
		}
		if !found {
			t.Errorf("proje listede bulunamadı")
		}
	})

	t.Run("12_imported_history_is_pre_approved_and_silent", func(t *testing.T) {
		p := newProject(t, orgA.ID)
		before := len(notices(t, admin.ID, domain.NotificationExpensePendingApproval))
		e, err := projectSvc.CreateExpense(ctx, p.ID, orgA.ID, service.ExpenseInput{
			Category: domain.ExpenseMaterial, Description: "BYZ masrafı", Amount: 90, ExpenseDate: today, PreApproved: true,
		})
		if err != nil {
			t.Fatal(err)
		}
		if e.ApprovalStatus != domain.ExpenseApprovalApproved || totalExpenses(t, p) != 90 {
			t.Errorf("aktarılan geçmiş masraf onaylı yazılmalı: %+v", e)
		}
		if n := len(notices(t, admin.ID, domain.NotificationExpensePendingApproval)); n != before {
			t.Errorf("aktarım onaylayıcıya bildirim düşürmemeli")
		}
	})
}
