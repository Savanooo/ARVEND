package service_test

// Masrafı herkes girer, yalnızca en üst yönetim onaylar (migration 0066,
// ürün sahibi kararı 2026-10-07) -- gerçek bir PostgreSQL bağlantısı
// gerektirir. Servis katmanı: OwnOnly (finance.manage taşımayan kişi)
// kuralları, kendi masrafına karar yasağı (Sahip hariç), bildirim alıcıları
// ve hedefleri, ana sayfa gündemi. İzin kapıları (kimin hangi uca girdiği)
// HTTP katmanında: middleware/expense_approval_security_test.go.

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

func TestExpenseOwnEntry(t *testing.T) {
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
	dashSvc := service.NewDashboardService(pool, q)
	platformSvc := service.NewPlatformService(pool, q, userSvc, service.NewCalcService(q), service.NewProductService(q))

	mustCreateReadyOrg := func(t *testing.T, slug string) *service.CreateOrganizationResult {
		t.Helper()
		var existingID string
		if err := pool.QueryRow(ctx, "SELECT id FROM organizations WHERE slug = $1", slug).Scan(&existingID); err == nil {
			cleanupOrganization(t, pool, existingID)
		}
		res, err := platformSvc.CreateOrganizationWithOwner(ctx, service.CreateOrganizationInput{
			Name: "Masraf Herkes " + slug, Slug: slug,
			OwnerUsername: "owner_" + slug, OwnerPassword: "GeciciSifre123!", OwnerFullName: "Firma Sahibi",
		})
		if err != nil {
			t.Fatalf("firma oluşturulamadı: %v", err)
		}
		t.Cleanup(func() { cleanupOrganization(t, pool, res.Organization.ID) })
		return res
	}
	orgARes := mustCreateReadyOrg(t, "masraf-herkes-a")
	orgA := orgARes.Organization
	owner := &orgARes.Owner
	orgBRes := mustCreateReadyOrg(t, "masraf-herkes-b")
	orgB := orgBRes.Organization

	roleUser := func(t *testing.T, orgID, username, roleCode string) *domain.User {
		t.Helper()
		u, err := userSvc.Create(ctx, orgID, username, "GeciciSifre123!", username, domain.RoleKullanici, "")
		if err != nil {
			t.Fatalf("%s oluşturulamadı: %v", username, err)
		}
		if _, err := authzSvc.SetUserOrganizationRole(ctx, u.ID, orgID, "", roleCode); err != nil {
			t.Fatalf("%s rolü atanamadı: %v", username, err)
		}
		return u
	}
	admin := roleUser(t, orgA.ID, "own_admin", domain.OrgRoleAdmin)
	admin2 := roleUser(t, orgA.ID, "own_admin2", domain.OrgRoleAdmin)
	// Saha: masraf girer (0066), finans göremez, onaylayamaz.
	field := roleUser(t, orgA.ID, "own_field", domain.OrgRoleField)
	field2 := roleUser(t, orgA.ID, "own_field2", domain.OrgRoleField)
	// Eski Sistem kullanıcısı: finance.read + finance.manage (tam yetki).
	clerk := roleUser(t, orgA.ID, "own_clerk", domain.OrgRoleLegacyUser)
	fieldB := roleUser(t, orgB.ID, "own_field_b", domain.OrgRoleField)

	newProject := func(t *testing.T, orgID string, members ...*domain.User) *domain.Project {
		t.Helper()
		o, err := offerSvc.Create(ctx, service.CreateOfferInput{
			OrganizationID: orgID, CustomerName: "Masraf Herkes Müşteri", VatRate: ptrFloat(0),
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
		p, err := projectSvc.CreateFromOffer(ctx, o.ID, orgID, service.CreateProjectInput{Name: "Masraf Herkes Projesi"})
		if err != nil {
			t.Fatalf("proje: %v", err)
		}
		for _, u := range members {
			if _, err := authzSvc.AddProjectUser(ctx, p.ID, orgID, service.ProjectUserInput{
				UserID: u.ID, ProjectRole: domain.ProjectRoleMember, CreatedBy: "",
			}); err != nil {
				t.Fatalf("proje erişimi: %v", err)
			}
		}
		return p
	}

	today := time.Now()
	// basic: sahadakinin formu -- yalnızca temel alanlar. OwnOnly'yi HTTP
	// katmanı finance.manage yoksa doldurur; burada elle verilir.
	basic := func(by *domain.User, amount float64) service.ExpenseInput {
		return service.ExpenseInput{
			Category: domain.ExpenseMaterial, Description: "Hırdavat", Amount: amount, Currency: "TRY",
			ExpenseDate: today, SupplierName: "Usta Ali", InvoiceNo: "F-1", Notes: "fiş ekte",
			VATRate: ptrFloat(20), UserID: by.ID, OwnOnly: true,
		}
	}
	create := func(t *testing.T, p *domain.Project, in service.ExpenseInput) *domain.Expense {
		t.Helper()
		e, err := projectSvc.CreateExpense(ctx, p.ID, orgA.ID, in)
		if err != nil {
			t.Fatalf("masraf girilemedi: %v", err)
		}
		return e
	}
	full := func(by *domain.User, amount float64) service.ExpenseInput {
		in := basic(by, amount)
		in.OwnOnly = false
		return in
	}
	notices := func(t *testing.T, orgID, userID, notifType string) []domain.Notification {
		t.Helper()
		res, err := notifSvc.List(ctx, userID, orgID, 1, 100)
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
	noticeFor := func(t *testing.T, userID, notifType, expenseID string) *domain.Notification {
		t.Helper()
		for _, n := range notices(t, orgA.ID, userID, notifType) {
			if n.EntityID != nil && *n.EntityID == expenseID {
				return &n
			}
		}
		return nil
	}
	mine := func(t *testing.T, orgID string, u *domain.User, projectID string, restricted bool) []domain.MyExpense {
		t.Helper()
		restrict := ""
		if restricted {
			restrict = u.ID
		}
		rows, err := projectSvc.ListMyExpenses(ctx, orgID, u.ID, projectID, restrict)
		if err != nil {
			t.Fatalf("Masraflarım: %v", err)
		}
		return rows
	}

	t.Run("01_field_user_creates_pending_expense_with_basic_fields", func(t *testing.T) {
		p := newProject(t, orgA.ID, field)
		e := create(t, p, basic(field, 1200))
		if e.ApprovalStatus != domain.ExpenseApprovalPending || e.CreatedBy == nil || *e.CreatedBy != field.ID {
			t.Fatalf("sahadakinin masrafı onay bekleyerek doğmalı: %+v", e)
		}
		if e.VATRate == nil || *e.VATRate != 20 || e.VATAmount == nil || *e.VATAmount != 200 ||
			e.SupplierName != "Usta Ali" || e.InvoiceNo != "F-1" || e.Notes != "fiş ekte" {
			t.Errorf("temel alanlar (KDV, kime ödendi, fiş no, not) yazılmalı: %+v", e)
		}
		s, err := projectSvc.FinancialSummary(ctx, p.ID, orgA.ID)
		if err != nil || s.TotalExpenses != 0 {
			t.Errorf("onay bekleyen masraf toplama girmemeli: %+v %v", s, err)
		}
	})

	t.Run("02_field_user_cannot_link_change_order_budget_line_or_cost_code", func(t *testing.T) {
		p := newProject(t, orgA.ID, field)
		cc, err := costCodeSvc.Create(ctx, orgA.ID, service.CostCodeInput{Code: "OWN-" + p.ID[:8], Name: "Saha", Category: "Malzeme"})
		if err != nil {
			t.Fatal(err)
		}
		line, err := projectSvc.CreateBudgetLine(ctx, p.ID, orgA.ID, service.BudgetLineInput{CostCodeID: cc.ID, Description: "Kalem", OriginalAmount: 1000})
		if err != nil {
			t.Fatal(err)
		}
		co, err := projectSvc.CreateChangeOrder(ctx, p.ID, orgA.ID, service.ChangeOrderInput{
			ChangeType: domain.ChangeOrderAddition, Title: "Ek iş",
			Items: []service.ChangeOrderItemInput{{Description: "Kalem", Quantity: 1, Unit: "adet", UnitPrice: 500}},
		})
		if err != nil {
			t.Fatal(err)
		}
		for name, mutate := range map[string]func(*service.ExpenseInput){
			"ek iş":        func(in *service.ExpenseInput) { in.ChangeOrderID = co.ID },
			"bütçe kalemi": func(in *service.ExpenseInput) { in.BudgetLineID = line.ID },
			"maliyet kodu": func(in *service.ExpenseInput) { in.CostCodeID = cc.ID },
		} {
			in := basic(field, 100)
			mutate(&in)
			if _, err := projectSvc.CreateExpense(ctx, p.ID, orgA.ID, in); !errors.Is(err, service.ErrExpenseFinanceLinkForbidden) {
				t.Errorf("%s bağlanabildi: %v", name, err)
			}
		}
		if n := len(mine(t, orgA.ID, field, p.ID, true)); n != 0 {
			t.Errorf("reddedilen istek kayıt bırakmamalı: %d", n)
		}
		// Finans yetkilisi (OwnOnly=false) bağlar -- bugünkü hak.
		in := full(clerk, 100)
		in.BudgetLineID, in.ChangeOrderID = line.ID, co.ID
		if e := create(t, p, in); e.BudgetLineID == nil || e.CostCodeID == nil || *e.CostCodeID != cc.ID || e.ChangeOrderID == nil {
			t.Errorf("finans yetkilisi bağları yazabilmeli: %+v", e)
		}
	})

	t.Run("03_field_user_edits_own_pending_and_rejected", func(t *testing.T) {
		p := newProject(t, orgA.ID, field)
		e := create(t, p, basic(field, 500))
		edit := basic(field, 550)
		edit.Description = "Hırdavat (düzeltildi)"
		got, err := projectSvc.UpdateExpense(ctx, p.ID, e.ID, orgA.ID, edit)
		if err != nil || got.Amount != 550 || got.ApprovalStatus != domain.ExpenseApprovalPending {
			t.Fatalf("kendi bekleyen masrafını düzeltebilmeli: %+v %v", got, err)
		}
		if _, err := projectSvc.RejectExpense(ctx, p.ID, e.ID, orgA.ID, admin.ID, "Fiş okunmuyor"); err != nil {
			t.Fatal(err)
		}
		edit.Amount = 540
		got, err = projectSvc.UpdateExpense(ctx, p.ID, e.ID, orgA.ID, edit)
		if err != nil || got.ApprovalStatus != domain.ExpenseApprovalPending || got.DecisionNote != "" || got.DecidedBy != nil {
			t.Fatalf("reddedilen masraf düzeltilince yeniden onaya düşmeli: %+v %v", got, err)
		}
		if n := noticeFor(t, field.ID, domain.NotificationExpensePendingApproval, e.ID); n != nil {
			t.Errorf("giren kişi kendi masrafı için onay bildirimi almamalı: %+v", n)
		}
		if n := noticeFor(t, owner.ID, domain.NotificationExpensePendingApproval, e.ID); n == nil {
			t.Errorf("Sahip onay bildirimi almalı")
		}
	})

	t.Run("04_field_user_cannot_touch_approved_voided_or_others_expense", func(t *testing.T) {
		p := newProject(t, orgA.ID, field, field2)
		approved := create(t, p, basic(field, 300))
		if _, err := projectSvc.ApproveExpense(ctx, p.ID, approved.ID, orgA.ID, admin.ID); err != nil {
			t.Fatal(err)
		}
		if _, err := projectSvc.UpdateExpense(ctx, p.ID, approved.ID, orgA.ID, basic(field, 1)); !errors.Is(err, service.ErrExpenseApprovedLocked) {
			t.Errorf("onaylı masraf düzeltilebildi: %v", err)
		}
		if _, err := projectSvc.WithdrawOwnExpense(ctx, p.ID, approved.ID, orgA.ID, field.ID, ""); !errors.Is(err, service.ErrExpenseApprovedLocked) {
			t.Errorf("onaylı masraf geri çekilebildi: %v", err)
		}
		others := create(t, p, basic(field2, 400))
		if _, err := projectSvc.UpdateExpense(ctx, p.ID, others.ID, orgA.ID, basic(field, 1)); !errors.Is(err, service.ErrExpenseNotOwn) {
			t.Errorf("başkasının masrafı düzeltilebildi: %v", err)
		}
		if _, err := projectSvc.WithdrawOwnExpense(ctx, p.ID, others.ID, orgA.ID, field.ID, ""); !errors.Is(err, service.ErrExpenseNotOwn) {
			t.Errorf("başkasının masrafı geri çekilebildi: %v", err)
		}
		// Finansın girdiği (created_by başka) masraf da sahadakinin değil.
		byClerk := create(t, p, full(clerk, 50))
		if _, err := projectSvc.UpdateExpense(ctx, p.ID, byClerk.ID, orgA.ID, basic(field, 1)); !errors.Is(err, service.ErrExpenseNotOwn) {
			t.Errorf("finansın masrafı düzeltilebildi: %v", err)
		}
		withdrawn := create(t, p, basic(field, 20))
		if _, err := projectSvc.WithdrawOwnExpense(ctx, p.ID, withdrawn.ID, orgA.ID, field.ID, ""); err != nil {
			t.Fatal(err)
		}
		if _, err := projectSvc.UpdateExpense(ctx, p.ID, withdrawn.ID, orgA.ID, basic(field, 1)); !errors.Is(err, service.ErrAlreadyVoided) {
			t.Errorf("geri çekilmiş masraf düzeltilebildi: %v", err)
		}
		if _, err := projectSvc.WithdrawOwnExpense(ctx, p.ID, withdrawn.ID, orgA.ID, field.ID, ""); !errors.Is(err, service.ErrAlreadyVoided) {
			t.Errorf("ikinci geri çekme: %v", err)
		}
		// Yanlış proje URL'si / bilinmeyen kimlik: 404.
		other := newProject(t, orgA.ID, field)
		if _, err := projectSvc.UpdateExpense(ctx, other.ID, others.ID, orgA.ID, basic(field, 1)); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("başka projenin URL'siyle: %v", err)
		}
		// Kayıtlar değişmedi.
		list, err := projectSvc.ListExpenses(ctx, p.ID, orgA.ID)
		if err != nil {
			t.Fatal(err)
		}
		for _, e := range list {
			if e.ID == approved.ID && (e.Amount != 300 || e.ApprovalStatus != domain.ExpenseApprovalApproved || e.VoidedAt != nil) {
				t.Errorf("onaylı masraf değişti: %+v", e)
			}
			if e.ID == others.ID && (e.Amount != 400 || e.VoidedAt != nil) {
				t.Errorf("başkasının masrafı değişti: %+v", e)
			}
		}
	})

	t.Run("05_finance_links_survive_field_users_correction", func(t *testing.T) {
		p := newProject(t, orgA.ID, field)
		cc, err := costCodeSvc.Create(ctx, orgA.ID, service.CostCodeInput{Code: "KEEP-" + p.ID[:8], Name: "Kalsın", Category: "Malzeme"})
		if err != nil {
			t.Fatal(err)
		}
		cc2, err := costCodeSvc.Create(ctx, orgA.ID, service.CostCodeInput{Code: "OTHER-" + p.ID[:8], Name: "Başka", Category: "Malzeme"})
		if err != nil {
			t.Fatal(err)
		}
		e := create(t, p, basic(field, 700))
		// Finans yetkilisi masrafı maliyet koduna bağlar (yeniden onaya düşer),
		// yönetici tutar yüzünden reddeder.
		tag := full(clerk, 700)
		tag.CostCodeID = cc.ID
		if _, err := projectSvc.UpdateExpense(ctx, p.ID, e.ID, orgA.ID, tag); err != nil {
			t.Fatal(err)
		}
		if _, err := projectSvc.RejectExpense(ctx, p.ID, e.ID, orgA.ID, admin.ID, "Tutar yanlış"); err != nil {
			t.Fatal(err)
		}
		// Sahadaki bağı göremez, boş gönderir: bağ korunur.
		got, err := projectSvc.UpdateExpense(ctx, p.ID, e.ID, orgA.ID, basic(field, 650))
		if err != nil || got.CostCodeID == nil || *got.CostCodeID != cc.ID {
			t.Fatalf("boş gönderilen bağ kayıttakini silmemeli: %+v %v", got, err)
		}
		// Okuduğunu aynen geri gönderebilir.
		same := basic(field, 640)
		same.CostCodeID = cc.ID
		if got, err := projectSvc.UpdateExpense(ctx, p.ID, e.ID, orgA.ID, same); err != nil || *got.CostCodeID != cc.ID {
			t.Errorf("aynı bağ geri gönderilebilmeli: %+v %v", got, err)
		}
		// Değiştiremez.
		changed := basic(field, 630)
		changed.CostCodeID = cc2.ID
		if _, err := projectSvc.UpdateExpense(ctx, p.ID, e.ID, orgA.ID, changed); !errors.Is(err, service.ErrExpenseFinanceLinkForbidden) {
			t.Errorf("sahadaki bağı değiştirebildi: %v", err)
		}
	})

	t.Run("06_field_user_withdraws_own_pending_and_rejected", func(t *testing.T) {
		p := newProject(t, orgA.ID, field)
		pending := create(t, p, basic(field, 80))
		rejected := create(t, p, basic(field, 90))
		if _, err := projectSvc.RejectExpense(ctx, p.ID, rejected.ID, orgA.ID, admin.ID, "Mükerrer"); err != nil {
			t.Fatal(err)
		}
		for _, e := range []*domain.Expense{pending, rejected} {
			got, err := projectSvc.WithdrawOwnExpense(ctx, p.ID, e.ID, orgA.ID, field.ID, "  yanlış proje  ")
			if err != nil {
				t.Fatalf("%s masraf geri çekilemedi: %v", e.ApprovalStatus, err)
			}
			if got.VoidedAt == nil || got.VoidedBy == nil || *got.VoidedBy != field.ID || got.VoidReason != "yanlış proje" {
				t.Errorf("geri çekme izi (voided_by = giren): %+v", got)
			}
		}
		// Onay bekleyen artık karara açık değil.
		if _, err := projectSvc.ApproveExpense(ctx, p.ID, pending.ID, orgA.ID, admin.ID); !errors.Is(err, service.ErrAlreadyVoided) {
			t.Errorf("geri çekilen masraf onaylanabildi: %v", err)
		}
		// Kapalı projede geri çekilemez (finans kilidi).
		closed := newProject(t, orgA.ID, field)
		e := create(t, closed, basic(field, 10))
		if _, err := projectSvc.Update(ctx, closed.ID, orgA.ID, service.UpdateProjectInput{Name: closed.Name, Status: domain.ProjectStatusCancelled}); err != nil {
			t.Fatal(err)
		}
		if _, err := projectSvc.WithdrawOwnExpense(ctx, closed.ID, e.ID, orgA.ID, field.ID, ""); !errors.Is(err, service.ErrProjectLocked) {
			t.Errorf("kapalı projede geri çekme: %v", err)
		}
		if _, err := projectSvc.UpdateExpense(ctx, closed.ID, e.ID, orgA.ID, basic(field, 11)); !errors.Is(err, service.ErrProjectLocked) {
			t.Errorf("kapalı projede düzeltme: %v", err)
		}
	})

	t.Run("07_my_expenses_lists_only_own_with_status_and_access", func(t *testing.T) {
		p1 := newProject(t, orgA.ID, field, field2)
		p2 := newProject(t, orgA.ID, field)
		a := create(t, p1, basic(field, 100))
		b := create(t, p2, basic(field, 200))
		create(t, p1, basic(field2, 300))
		create(t, p1, full(clerk, 400))
		if _, err := projectSvc.RejectExpense(ctx, p1.ID, a.ID, orgA.ID, admin.ID, "Fiş yok"); err != nil {
			t.Fatal(err)
		}

		rows := mine(t, orgA.ID, field, "", true)
		byID := map[string]domain.MyExpense{}
		for _, r := range rows {
			if r.CreatedBy == nil || *r.CreatedBy != field.ID {
				t.Fatalf("Masraflarım başkasının masrafını döndürdü: %+v", r)
			}
			byID[r.ID] = r
		}
		ra, okA := byID[a.ID]
		rb, okB := byID[b.ID]
		if !okA || !okB {
			t.Fatalf("iki projedeki kendi masrafları dönmeli: %d satır", len(rows))
		}
		if ra.ApprovalStatus != domain.ExpenseApprovalRejected || ra.DecisionNote != "Fiş yok" || ra.ProjectID != p1.ID ||
			ra.ProjectName != p1.Name || ra.ProjectNo != p1.ProjectNo || ra.ProjectStatus != p1.Status || ra.VATAmount == nil {
			t.Errorf("satır durum/ret nedeni/proje/KDV taşımalı: %+v", ra)
		}
		if rb.ApprovalStatus != domain.ExpenseApprovalPending {
			t.Errorf("bekleyen: %+v", rb)
		}
		if len(rows) > 1 && rows[0].CreatedAt.Before(rows[len(rows)-1].CreatedAt) {
			t.Errorf("en yeni giriş önce gelmeli")
		}

		// Proje süzgeci.
		only := mine(t, orgA.ID, field, p2.ID, true)
		if len(only) != 1 || only[0].ID != b.ID {
			t.Errorf("proje süzgeci: %+v", only)
		}
		// Projeden çıkarılan kişi o projedeki kaydını da görmez.
		if err := authzSvc.RemoveProjectUser(ctx, p2.ID, field.ID, orgA.ID); err != nil {
			t.Fatal(err)
		}
		for _, r := range mine(t, orgA.ID, field, "", true) {
			if r.ProjectID == p2.ID {
				t.Errorf("erişimi kalkan projenin masrafı listelendi: %+v", r)
			}
		}
		// Üyelikten muaf rol (Yönetici) kendi masraflarını her projede görür.
		own := create(t, p2, full(admin, 50))
		found := false
		for _, r := range mine(t, orgA.ID, admin, "", false) {
			if r.CreatedBy == nil || *r.CreatedBy != admin.ID {
				t.Fatalf("Yönetici'nin listesine başkası karıştı: %+v", r)
			}
			found = found || r.ID == own.ID
		}
		if !found {
			t.Errorf("Yönetici kendi masrafını görmeli")
		}
		// Firma izolasyonu: başka firmanın bağlamıyla hiçbir şey dönmez.
		if rows := mine(t, orgB.ID, field, "", true); len(rows) != 0 {
			t.Errorf("başka firma bağlamında satır döndü: %d", len(rows))
		}
		if rows := mine(t, orgA.ID, fieldB, "", true); len(rows) != 0 {
			t.Errorf("B firmasının kullanıcısı A'nın masrafını gördü: %d", len(rows))
		}
	})

	t.Run("08_finance_manager_keeps_full_rights_over_every_expense", func(t *testing.T) {
		p := newProject(t, orgA.ID, field)
		e := create(t, p, basic(field, 1000))
		if _, err := projectSvc.ApproveExpense(ctx, p.ID, e.ID, orgA.ID, admin.ID); err != nil {
			t.Fatal(err)
		}
		got, err := projectSvc.UpdateExpense(ctx, p.ID, e.ID, orgA.ID, full(clerk, 900))
		if err != nil || got.ApprovalStatus != domain.ExpenseApprovalPending || got.Amount != 900 {
			t.Fatalf("finans yetkilisi başkasının onaylı masrafını düzeltebilmeli: %+v %v", got, err)
		}
		if _, err := projectSvc.VoidExpense(ctx, p.ID, e.ID, orgA.ID, clerk.ID, "hatalı"); err != nil {
			t.Errorf("finans yetkilisi iptal edebilmeli: %v", err)
		}
	})

	t.Run("09_nobody_decides_own_expense_except_owner", func(t *testing.T) {
		p := newProject(t, orgA.ID)
		mineAdmin := create(t, p, full(admin, 100))
		if _, err := projectSvc.ApproveExpense(ctx, p.ID, mineAdmin.ID, orgA.ID, admin.ID); !errors.Is(err, service.ErrOwnExpenseDecision) {
			t.Errorf("Yönetici kendi masrafını onaylayabildi: %v", err)
		}
		if _, err := projectSvc.RejectExpense(ctx, p.ID, mineAdmin.ID, orgA.ID, admin.ID, "x"); !errors.Is(err, service.ErrOwnExpenseDecision) {
			t.Errorf("Yönetici kendi masrafını reddedebildi: %v", err)
		}
		got, err := projectSvc.ApproveExpense(ctx, p.ID, mineAdmin.ID, orgA.ID, admin2.ID)
		if err != nil || got.ApprovalStatus != domain.ExpenseApprovalApproved {
			t.Fatalf("başka bir Yönetici onaylayabilmeli: %+v %v", got, err)
		}
		// Karar verilmiş masrafta önce durum söylenir (bütçe revizyonuyla aynı).
		if _, err := projectSvc.ApproveExpense(ctx, p.ID, mineAdmin.ID, orgA.ID, admin.ID); !errors.Is(err, service.ErrExpenseNotPending) {
			t.Errorf("karar verilmiş kendi masrafı: %v", err)
		}
		// Sahip'in üstünde kimse yok: kendi masrafına karar verebilir.
		ownerExp := create(t, p, full(owner, 70))
		if got, err := projectSvc.RejectExpense(ctx, p.ID, ownerExp.ID, orgA.ID, owner.ID, "Yanlış girdim"); err != nil ||
			got.ApprovalStatus != domain.ExpenseApprovalRejected {
			t.Errorf("Sahip kendi masrafını reddedebilmeli: %+v %v", got, err)
		}
		ownerExp2 := create(t, p, full(owner, 75))
		if _, err := projectSvc.ApproveExpense(ctx, p.ID, ownerExp2.ID, orgA.ID, owner.ID); err != nil {
			t.Errorf("Sahip kendi masrafını onaylayabilmeli: %v", err)
		}
	})

	t.Run("10_notices_skip_the_creator_and_lead_field_users_to_their_list", func(t *testing.T) {
		p := newProject(t, orgA.ID, field)
		e := create(t, p, full(admin, 300))
		// Başka bir Yönetici düzeltir: yeniden onaya düşer; giren (onaylayıcı
		// olsa da) "onay bekliyor" almaz -- ne girişte ne bu düzeltmede.
		// Diğer onaylayıcılar (Sahip, girişte admin2) alır.
		if _, err := projectSvc.UpdateExpense(ctx, p.ID, e.ID, orgA.ID, full(admin2, 310)); err != nil {
			t.Fatal(err)
		}
		if n := noticeFor(t, admin.ID, domain.NotificationExpensePendingApproval, e.ID); n != nil {
			t.Errorf("giren kişi kendi masrafı için onay bildirimi almamalı: %+v", n)
		}
		if n := noticeFor(t, owner.ID, domain.NotificationExpensePendingApproval, e.ID); n == nil {
			t.Errorf("Sahip bildirim almalı")
		}
		if n := noticeFor(t, admin2.ID, domain.NotificationExpensePendingApproval, e.ID); n == nil {
			t.Errorf("diğer Yönetici girişte bildirim almalı")
		}
		// Onaylayıcı olmayanlar (Saha) almaz.
		if n := len(notices(t, orgA.ID, field.ID, domain.NotificationExpensePendingApproval)); n != 0 {
			t.Errorf("Saha onay bildirimi almamalı: %d", n)
		}

		// Karar bildirimi: finans göremeyen Saha'yı Masraflarım'a götürür.
		fe := create(t, p, basic(field, 40))
		if _, err := projectSvc.RejectExpense(ctx, p.ID, fe.ID, orgA.ID, admin.ID, "Fiş yok"); err != nil {
			t.Fatal(err)
		}
		n := noticeFor(t, field.ID, domain.NotificationExpenseRejected, fe.ID)
		if n == nil || n.ActionTarget != "/diger/masraflarim?masraf="+fe.ID {
			t.Errorf("Saha'nın ret bildirimi Masraflarım'ı açmalı: %+v", n)
		}
		// Finans okuyabilen giren ise bugünkü gibi Finans görünümüne gider.
		ce := create(t, p, full(clerk, 45))
		if _, err := projectSvc.ApproveExpense(ctx, p.ID, ce.ID, orgA.ID, admin.ID); err != nil {
			t.Fatal(err)
		}
		n = noticeFor(t, clerk.ID, domain.NotificationExpenseApproved, ce.ID)
		if n == nil || n.ActionTarget != "/projeler/"+p.ID+"?grup=finans&alt=finans" {
			t.Errorf("finans okuyabilenin bildirimi Finans'ı açmalı: %+v", n)
		}
	})

	t.Run("11_dashboard_agenda_skips_own_pending_expenses_except_owner", func(t *testing.T) {
		p := newProject(t, orgA.ID)
		// Bu firmadaki önceki alt testlerin bekleyenleri de sayılır; yalnızca
		// izleyicinin KENDİ masrafının farkı ölçülür.
		count := func(t *testing.T, u *domain.User) int {
			t.Helper()
			authz, err := authzSvc.LoadAuthzContext(ctx, u.ID, orgA.ID)
			if err != nil {
				t.Fatal(err)
			}
			d, err := dashSvc.Get(ctx, service.DashboardInput{
				OrganizationID: orgA.ID, UserID: u.ID, CoarseRole: domain.RoleAdmin, Authz: authz, Now: time.Now(),
			})
			if err != nil {
				t.Fatal(err)
			}
			for _, g := range d.Agenda.Groups {
				if g.Code == domain.AttnExpenseApproval {
					return g.Count
				}
			}
			return 0
		}
		adminBefore, admin2Before, ownerBefore := count(t, admin), count(t, admin2), count(t, owner)
		create(t, p, full(admin, 25))
		if got := count(t, admin); got != adminBefore {
			t.Errorf("Yönetici'nin kendi bekleyen masrafı gündemine düşmemeli: önce %d, sonra %d", adminBefore, got)
		}
		if got := count(t, admin2); got != admin2Before+1 {
			t.Errorf("diğer Yönetici'nin gündemine düşmeli: önce %d, sonra %d", admin2Before, got)
		}
		create(t, p, full(owner, 26))
		if got := count(t, owner); got != ownerBefore+2 {
			t.Errorf("Sahip kendi masrafına da karar verebilir, gündeminde görmeli: önce %d, sonra %d", ownerBefore, got)
		}
	})

	t.Run("12_idempotency_key_never_returns_someone_elses_expense", func(t *testing.T) {
		// Aynı anahtarla tekrar, YALNIZCA aynı kişinin tekrarıdır. Başkasının
		// anahtarını gönderen sahadaki kişi (finans okuma izni yok) o masrafı
		// -- tutar, kime ödendi, fiş no, not -- cevap olarak almamalı.
		p := newProject(t, orgA.ID, field, field2)
		in := basic(field2, 4321)
		in.IdempotencyKey = "exp-ortak-anahtar-" + p.ID[:8]
		theirs := create(t, p, in)

		again := basic(field2, 4321)
		again.IdempotencyKey = in.IdempotencyKey
		if e := create(t, p, again); e.ID != theirs.ID {
			t.Fatalf("aynı kişinin tekrarı aynı kaydı dönmeli: %s != %s", e.ID, theirs.ID)
		}

		mineIn := basic(field, 10)
		mineIn.IdempotencyKey = in.IdempotencyKey
		e, err := projectSvc.CreateExpense(ctx, p.ID, orgA.ID, mineIn)
		if e != nil && e.ID == theirs.ID {
			t.Fatalf("başkasının masrafı anahtar tekrarıyla okundu: %+v", e)
		}
		if !errors.Is(err, service.ErrExpenseIdempotencyKeyInUse) {
			t.Fatalf("err = %v, want ErrExpenseIdempotencyKeyInUse", err)
		}
	})
}
