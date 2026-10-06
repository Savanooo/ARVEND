package service_test

// ARVEND V2 -- Sprint 2 (WBS + Cost Codes + Project Budget + Cost Control)
// için otomatik testler -- gerçek bir PostgreSQL bağlantısı gerektirir
// (bkz. tenant_isolation_test.go'daki testDBURL/testSecretBox/mustCreateOrg/
// cleanupOrganization yardımcıları, aynı pakette paylaşılır). Spec §34'ün
// 31 maddelik test matrisini VE §35'in tam sayısal (golden money) örneğini
// uygular.

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

func TestCostControl(t *testing.T) {
	dbURL := testDBURL(t)
	box := testSecretBox(t)
	ctx := context.Background()

	pool, err := repository.NewPool(ctx, dbURL)
	if err != nil {
		t.Fatalf("veritabanına bağlanılamadı: %v", err)
	}
	t.Cleanup(func() { pool.Close() })

	q := sqlc.New(pool)
	orgSvc := service.NewOrganizationService(q)
	settingsSvc := service.NewSettingsService(q, box)
	offerSvc := service.NewOfferService(pool, q, settingsSvc, "http://localhost:3000")
	projectSvc := service.NewProjectService(pool, q, mustTestStore(t), settingsSvc, "http://localhost:3000")
	costCodeSvc := service.NewCostCodeService(pool, q)

	orgA := mustCreateOrg(t, ctx, orgSvc, pool, "Maliyet Test Firma A", "maliyet-test-firma-a")
	orgB := mustCreateOrg(t, ctx, orgSvc, pool, "Maliyet Test Firma B", "maliyet-test-firma-b")

	// newProject, KDV'siz (VatRate=0) sözleşme bedeli verilen kabul edilmiş
	// bir teklifi projeye dönüştürür -- contractAmount İLE grand_total AYNI
	// olsun diye (change-order testlerindeki AYNI desen).
	newProject := func(t *testing.T, orgID string, contractAmount float64) *domain.Project {
		t.Helper()
		o, err := offerSvc.Create(ctx, service.CreateOfferInput{
			OrganizationID: orgID,
			CustomerName:   "Maliyet Test Müşteri",
			VatRate:        ptrFloat(0),
			Items:          []service.OfferItemInput{{ProductName: "İş", Quantity: 1, UnitPrice: contractAmount}},
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
		p, err := projectSvc.CreateFromOffer(ctx, o.ID, orgID, service.CreateProjectInput{Name: "Maliyet Kontrolü Projesi"})
		if err != nil {
			t.Fatalf("proje oluşturulamadı: %v", err)
		}
		return p
	}

	newCostCode := func(t *testing.T, orgID, code string) *domain.OrganizationCostCode {
		t.Helper()
		c, err := costCodeSvc.Create(ctx, orgID, service.CostCodeInput{Code: code, Name: "Kod " + code, Category: "Malzeme"})
		if err != nil {
			t.Fatalf("maliyet kodu oluşturulamadı: %v", err)
		}
		return c
	}

	// zeroOutContract, verilen projenin sözleşme bedelini TAM SIFIRA
	// düşüren onaylı bir eksiltme (deduction) ek işi oluşturur (bkz.
	// project_change_order_test.go'daki AYNI desen) -- sıfır/negatif
	// sözleşme bedelinde marjın güvenle 0 dönmesini test etmek için.
	zeroOutContract := func(t *testing.T, orgID, projectID string, amount float64) {
		t.Helper()
		co, err := projectSvc.CreateChangeOrder(ctx, projectID, orgID, service.ChangeOrderInput{
			ChangeType: domain.ChangeOrderDeduction, Title: "Sıfırlama",
			Items: []service.ChangeOrderItemInput{{Description: "Kalem", Quantity: 1, Unit: "adet", UnitPrice: amount}},
		})
		if err != nil {
			t.Fatalf("ek iş oluşturulamadı: %v", err)
		}
		sent, err := projectSvc.SendChangeOrder(ctx, projectID, co.ID, orgID, "")
		if err != nil {
			t.Fatalf("ek iş gönderilemedi: %v", err)
		}
		var token string
		row := pool.QueryRow(ctx, `SELECT token::text FROM project_change_order_share_links
			WHERE change_order_id = $1 AND revoked_at IS NULL ORDER BY created_at DESC LIMIT 1`, sent.ID)
		if err := row.Scan(&token); err != nil {
			t.Fatalf("aktif link bulunamadı: %v", err)
		}
		if _, err := projectSvc.RespondChangeOrderByShareLinkToken(ctx, token, domain.ChangeOrderApproved, "", ""); err != nil {
			t.Fatalf("ek iş onaylanamadı: %v", err)
		}
	}

	findLine := func(t *testing.T, lines []domain.CostControlLine, budgetLineID string) domain.CostControlLine {
		t.Helper()
		for _, l := range lines {
			if l.BudgetLineID != nil && *l.BudgetLineID == budgetLineID {
				return l
			}
		}
		t.Fatalf("kırılım tablosunda bütçe kalemi bulunamadı: %s", budgetLineID)
		return domain.CostControlLine{}
	}

	// ---------- 1-4: WBS ----------

	t.Run("1_wbs_creation_root_and_child", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		root, err := projectSvc.CreateWBSNode(ctx, p.ID, orgA.ID, service.WBSNodeInput{Code: "100", Name: "Kaba İnşaat"})
		if err != nil {
			t.Fatalf("kök WBS oluşturulamadı: %v", err)
		}
		child, err := projectSvc.CreateWBSNode(ctx, p.ID, orgA.ID, service.WBSNodeInput{ParentID: root.ID, Code: "110", Name: "Temel"})
		if err != nil {
			t.Fatalf("alt WBS oluşturulamadı: %v", err)
		}
		if child.ParentID == nil || *child.ParentID != root.ID {
			t.Errorf("alt düğümün parent_id'si kök olmalı: %+v", child)
		}
		nodes, err := projectSvc.ListWBSNodes(ctx, p.ID, orgA.ID)
		if err != nil || len(nodes) != 2 {
			t.Fatalf("beklenen 2 WBS düğümü, geldi: %d, err=%v", len(nodes), err)
		}
	})

	t.Run("2_wbs_cross_project_parent_rejected", func(t *testing.T) {
		p1 := newProject(t, orgA.ID, 100000)
		p2 := newProject(t, orgA.ID, 100000)
		root, err := projectSvc.CreateWBSNode(ctx, p1.ID, orgA.ID, service.WBSNodeInput{Code: "100", Name: "P1 Kök"})
		if err != nil {
			t.Fatalf("kök WBS oluşturulamadı: %v", err)
		}
		_, err = projectSvc.CreateWBSNode(ctx, p2.ID, orgA.ID, service.WBSNodeInput{ParentID: root.ID, Code: "100", Name: "P2 Çocuk"})
		if !errors.Is(err, service.ErrInvalidWBSParent) {
			t.Errorf("beklenen ErrInvalidWBSParent, geldi: %v", err)
		}
	})

	t.Run("3_wbs_cross_tenant_parent_denied", func(t *testing.T) {
		pA := newProject(t, orgA.ID, 100000)
		root, err := projectSvc.CreateWBSNode(ctx, pA.ID, orgA.ID, service.WBSNodeInput{Code: "100", Name: "A Kök"})
		if err != nil {
			t.Fatalf("kök WBS oluşturulamadı: %v", err)
		}
		pB := newProject(t, orgB.ID, 100000)
		// orgB bağlamında, orgA'nın WBS UUID'sini parent olarak denemek --
		// aynı IDOR sınıfı (bkz. resolveWBSParentRef, org+proje eşleşmesi).
		_, err = projectSvc.CreateWBSNode(ctx, pB.ID, orgB.ID, service.WBSNodeInput{ParentID: root.ID, Code: "100", Name: "B Çocuk"})
		if !errors.Is(err, service.ErrInvalidWBSParent) {
			t.Errorf("beklenen ErrInvalidWBSParent, geldi: %v", err)
		}
	})

	t.Run("4_wbs_duplicate_code_in_project_rejected", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		if _, err := projectSvc.CreateWBSNode(ctx, p.ID, orgA.ID, service.WBSNodeInput{Code: "100", Name: "İlk"}); err != nil {
			t.Fatalf("ilk WBS oluşturulamadı: %v", err)
		}
		_, err := projectSvc.CreateWBSNode(ctx, p.ID, orgA.ID, service.WBSNodeInput{Code: "100", Name: "İkinci"})
		if !errors.Is(err, service.ErrDuplicateWBSCode) {
			t.Errorf("beklenen ErrDuplicateWBSCode, geldi: %v", err)
		}
	})

	// ---------- 5-6: Maliyet Kodu ----------

	t.Run("5_cost_code_uniqueness_per_org", func(t *testing.T) {
		newCostCode(t, orgA.ID, "MLZ-UNQ")
		_, err := costCodeSvc.Create(ctx, orgA.ID, service.CostCodeInput{Code: "MLZ-UNQ", Name: "Tekrar"})
		if !errors.Is(err, service.ErrDuplicateCostCode) {
			t.Errorf("beklenen ErrDuplicateCostCode, geldi: %v", err)
		}
		// AYNI kod, FARKLI bir organizasyonda serbestçe kullanılabilmeli
		// (UNIQUE(organization_id, code) -- tenant-scoped, global DEĞİL).
		if _, err := costCodeSvc.Create(ctx, orgB.ID, service.CostCodeInput{Code: "MLZ-UNQ", Name: "Farklı Firma"}); err != nil {
			t.Errorf("farklı organizasyonda aynı kod reddedilmemeli: %v", err)
		}
	})

	t.Run("6_cost_code_archive_preserved_in_history", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		cc := newCostCode(t, orgA.ID, "MLZ-ARC")
		if err := costCodeSvc.Archive(ctx, cc.ID, orgA.ID, ""); err != nil {
			t.Fatalf("arşivlenemedi: %v", err)
		}
		got, err := costCodeSvc.Get(ctx, cc.ID, orgA.ID)
		if err != nil || got.IsActive {
			t.Fatalf("arşivlenmiş kod IsActive=false olmalı ve HÂLÂ okunabilir olmalı: %+v err=%v", got, err)
		}
		// Arşivlenmiş bir koda hâlâ yeni bir bütçe kalemi bağlanabilir
		// (spec: hard-delete YOK, yalnızca YENİ liste UI'sinde gizlenir --
		// backend seviyesinde bir engel İCAT EDİLMEZ). Bütçe zaten offer
		// dönüşümünde OTOMATİK oluşturuldu (bkz. test 8), yeniden
		// oluşturmaya GEREK yok.
		if _, err := projectSvc.CreateBudgetLine(ctx, p.ID, orgA.ID, service.BudgetLineInput{
			CostCodeID: cc.ID, Description: "Arşivli koda bağlı kalem", OriginalAmount: 1000,
		}); err != nil {
			t.Errorf("arşivlenmiş koda bağlı kalem oluşturulabilmeli: %v", err)
		}
	})

	// ---------- 7-9: Bütçe oluşturma + decimal doğruluğu ----------

	t.Run("7_draft_budget_create_and_duplicate_rejected", func(t *testing.T) {
		// newProject (offer dönüşümü), projeye OTOMATİK olarak boş bir
		// taslak bütçe oluşturur (bkz. test 8) -- bu yüzden burada
		// "oluşturma" değil, spec'in "bir projede TEK bir aktif bütçe"
		// kısıtının (UNIQUE(project_id)) İKİNCİ bir deneme ile REDDEDİLDİĞİ
		// doğrulanır.
		p := newProject(t, orgA.ID, 100000)
		b, err := projectSvc.GetProjectBudget(ctx, p.ID, orgA.ID)
		if err != nil {
			t.Fatalf("otomatik oluşan bütçe okunamadı: %v", err)
		}
		if b.Status != domain.BudgetStatusDraft {
			t.Errorf("yeni bütçe draft olmalı: %s", b.Status)
		}
		_, err = projectSvc.CreateProjectBudget(ctx, p.ID, orgA.ID, "")
		if !errors.Is(err, service.ErrBudgetAlreadyExists) {
			t.Errorf("beklenen ErrBudgetAlreadyExists, geldi: %v", err)
		}
	})

	t.Run("8_offer_conversion_auto_creates_empty_draft_budget", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		b, err := projectSvc.GetProjectBudget(ctx, p.ID, orgA.ID)
		if err != nil {
			t.Fatalf("offer dönüşümünde otomatik boş taslak bütçe oluşmalı: %v", err)
		}
		if b.Status != domain.BudgetStatusDraft {
			t.Errorf("otomatik oluşan bütçe draft olmalı: %s", b.Status)
		}
		lines, err := projectSvc.ListBudgetLines(ctx, p.ID, orgA.ID)
		if err != nil || len(lines) != 0 {
			t.Errorf("otomatik bütçe SIFIR kalemli olmalı (offer'dan asla maliyet türetilmez): %d err=%v", len(lines), err)
		}
	})

	t.Run("9_budget_line_decimal_math_exact_no_float_drift", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		cc := newCostCode(t, orgA.ID, "MLZ-DEC")
		qty := 3.0
		unitCost := 333.33
		line, err := projectSvc.CreateBudgetLine(ctx, p.ID, orgA.ID, service.BudgetLineInput{
			CostCodeID: cc.ID, Description: "Ondalık test", Quantity: &qty, UnitCost: &unitCost, Unit: "m3",
		})
		if err != nil {
			t.Fatalf("bütçe kalemi oluşturulamadı: %v", err)
		}
		if line.OriginalAmount != 999.99 {
			t.Errorf("beklenen TAM 999.99 (3 x 333.33), geldi: %v (float sürüklenmesi olmamalı)", line.OriginalAmount)
		}
		// İstemcinin GÖNDERDİĞİ (yanlış) OriginalAmount, quantity+unit_cost
		// İKİSİ de doluyken YOK SAYILMALI (spec: "backend'e ASLA güvenilmez").
		line2, err := projectSvc.CreateBudgetLine(ctx, p.ID, orgA.ID, service.BudgetLineInput{
			CostCodeID: cc.ID, Description: "İstemci güveni yok sayılmalı", Quantity: &qty, UnitCost: &unitCost,
			OriginalAmount: 5000000, // istemci bilerek yanlış/şişirilmiş bir tutar gönderiyor
		})
		if err != nil {
			t.Fatalf("bütçe kalemi oluşturulamadı: %v", err)
		}
		if line2.OriginalAmount != 999.99 {
			t.Errorf("istemcinin gönderdiği tutar yok sayılmalı, backend kendi hesabını kullanmalı: %v", line2.OriginalAmount)
		}
	})

	// ---------- 10-12: Baseline ----------

	t.Run("10_baseline_transitions_draft_to_baselined", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		b, err := projectSvc.BaselineProjectBudget(ctx, p.ID, orgA.ID, "")
		if err != nil {
			t.Fatalf("baseline alınamadı: %v", err)
		}
		if b.Status != domain.BudgetStatusBaselined {
			t.Errorf("beklenen baselined, geldi: %s", b.Status)
		}
	})

	t.Run("11_double_baseline_rejected", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		if _, err := projectSvc.BaselineProjectBudget(ctx, p.ID, orgA.ID, ""); err != nil {
			t.Fatalf("ilk baseline başarısız: %v", err)
		}
		_, err := projectSvc.BaselineProjectBudget(ctx, p.ID, orgA.ID, "")
		if !errors.Is(err, service.ErrBudgetNotBaselinable) {
			t.Errorf("beklenen ErrBudgetNotBaselinable, geldi: %v", err)
		}
	})

	t.Run("12_baseline_blocks_silent_line_edit", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		cc := newCostCode(t, orgA.ID, "MLZ-BSL")
		line, err := projectSvc.CreateBudgetLine(ctx, p.ID, orgA.ID, service.BudgetLineInput{
			CostCodeID: cc.ID, Description: "Baseline öncesi", OriginalAmount: 1000,
		})
		if err != nil {
			t.Fatalf("bütçe kalemi oluşturulamadı: %v", err)
		}
		if _, err := projectSvc.BaselineProjectBudget(ctx, p.ID, orgA.ID, ""); err != nil {
			t.Fatalf("baseline alınamadı: %v", err)
		}
		if _, err := projectSvc.UpdateBudgetLine(ctx, p.ID, line.ID, orgA.ID, service.BudgetLineInput{
			CostCodeID: cc.ID, Description: "Sessiz değişiklik", OriginalAmount: 999999,
		}); !errors.Is(err, service.ErrBudgetBaselined) {
			t.Errorf("beklenen ErrBudgetBaselined (update), geldi: %v", err)
		}
		if _, err := projectSvc.CreateBudgetLine(ctx, p.ID, orgA.ID, service.BudgetLineInput{
			CostCodeID: cc.ID, Description: "Baseline sonrası yeni kalem", OriginalAmount: 1,
		}); !errors.Is(err, service.ErrBudgetBaselined) {
			t.Errorf("beklenen ErrBudgetBaselined (create), geldi: %v", err)
		}
		if err := projectSvc.DeleteBudgetLine(ctx, p.ID, line.ID, orgA.ID, ""); !errors.Is(err, service.ErrBudgetBaselined) {
			t.Errorf("beklenen ErrBudgetBaselined (delete), geldi: %v", err)
		}
	})

	// ---------- 13-17: Bütçe Revizyonları (Adjustments) ----------

	setupBaselinedLine := func(t *testing.T, orgID string, contractAmount, originalAmount float64) (*domain.Project, *domain.BudgetLine) {
		t.Helper()
		p := newProject(t, orgID, contractAmount)
		cc := newCostCode(t, orgID, "MLZ-ADJ-"+p.ID[:8])
		line, err := projectSvc.CreateBudgetLine(ctx, p.ID, orgID, service.BudgetLineInput{
			CostCodeID: cc.ID, Description: "Revizyon testi", OriginalAmount: originalAmount,
		})
		if err != nil {
			t.Fatalf("bütçe kalemi oluşturulamadı: %v", err)
		}
		if _, err := projectSvc.BaselineProjectBudget(ctx, p.ID, orgID, ""); err != nil {
			t.Fatalf("baseline alınamadı: %v", err)
		}
		return p, line
	}

	t.Run("13_adjustment_before_baseline_rejected", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		cc := newCostCode(t, orgA.ID, "MLZ-PRE")
		line, err := projectSvc.CreateBudgetLine(ctx, p.ID, orgA.ID, service.BudgetLineInput{
			CostCodeID: cc.ID, Description: "Baseline öncesi", OriginalAmount: 1000,
		})
		if err != nil {
			t.Fatalf("bütçe kalemi oluşturulamadı: %v", err)
		}
		_, err = projectSvc.CreateBudgetAdjustment(ctx, p.ID, orgA.ID, service.BudgetAdjustmentInput{
			BudgetLineID: line.ID, Amount: 100, Reason: "Erken revizyon",
		})
		if !errors.Is(err, service.ErrBudgetNotYetBaselined) {
			t.Errorf("beklenen ErrBudgetNotYetBaselined, geldi: %v", err)
		}
	})

	t.Run("14_draft_adjustment_has_no_effect_on_revised_budget", func(t *testing.T) {
		p, line := setupBaselinedLine(t, orgA.ID, 100000, 700000)
		if _, err := projectSvc.CreateBudgetAdjustment(ctx, p.ID, orgA.ID, service.BudgetAdjustmentInput{
			BudgetLineID: line.ID, Amount: 50000, Reason: "Onaylanmamış revizyon",
		}); err != nil {
			t.Fatalf("revizyon oluşturulamadı: %v", err)
		}
		lines, err := projectSvc.CostControlLines(ctx, p.ID, orgA.ID)
		if err != nil {
			t.Fatalf("kırılım tablosu alınamadı: %v", err)
		}
		got := findLine(t, lines, line.ID)
		if got.RevisedBudget != 700000 {
			t.Errorf("draft revizyon revised_budget'ı ETKİLEMEMELİ: %v", got.RevisedBudget)
		}
	})

	t.Run("15_approved_adjustment_affects_revised_budget", func(t *testing.T) {
		p, line := setupBaselinedLine(t, orgA.ID, 100000, 700000)
		adj, err := projectSvc.CreateBudgetAdjustment(ctx, p.ID, orgA.ID, service.BudgetAdjustmentInput{
			BudgetLineID: line.ID, Amount: 50000, Reason: "Onaylı revizyon",
		})
		if err != nil {
			t.Fatalf("revizyon oluşturulamadı: %v", err)
		}
		if _, err := projectSvc.ApproveBudgetAdjustment(ctx, p.ID, adj.ID, orgA.ID, ""); err != nil {
			t.Fatalf("revizyon onaylanamadı: %v", err)
		}
		lines, err := projectSvc.CostControlLines(ctx, p.ID, orgA.ID)
		if err != nil {
			t.Fatalf("kırılım tablosu alınamadı: %v", err)
		}
		got := findLine(t, lines, line.ID)
		if got.RevisedBudget != 750000 || got.ApprovedAdjustments != 50000 {
			t.Errorf("beklenen revised=750000 approved_adj=50000, geldi: revised=%v adj=%v", got.RevisedBudget, got.ApprovedAdjustments)
		}
	})

	t.Run("16_rejected_adjustment_has_no_effect", func(t *testing.T) {
		p, line := setupBaselinedLine(t, orgA.ID, 100000, 700000)
		adj, err := projectSvc.CreateBudgetAdjustment(ctx, p.ID, orgA.ID, service.BudgetAdjustmentInput{
			BudgetLineID: line.ID, Amount: 50000, Reason: "Reddedilecek",
		})
		if err != nil {
			t.Fatalf("revizyon oluşturulamadı: %v", err)
		}
		rejected, err := projectSvc.RejectBudgetAdjustment(ctx, p.ID, adj.ID, orgA.ID, "")
		if err != nil || rejected.Status != domain.AdjustmentStatusRejected {
			t.Fatalf("revizyon reddedilemedi: %+v err=%v", rejected, err)
		}
		lines, err := projectSvc.CostControlLines(ctx, p.ID, orgA.ID)
		if err != nil {
			t.Fatalf("kırılım tablosu alınamadı: %v", err)
		}
		got := findLine(t, lines, line.ID)
		if got.RevisedBudget != 700000 {
			t.Errorf("reddedilen revizyon revised_budget'ı ETKİLEMEMELİ: %v", got.RevisedBudget)
		}
	})

	t.Run("17_negative_adjustment_reduces_revised_budget", func(t *testing.T) {
		p, line := setupBaselinedLine(t, orgA.ID, 100000, 700000)
		adj, err := projectSvc.CreateBudgetAdjustment(ctx, p.ID, orgA.ID, service.BudgetAdjustmentInput{
			BudgetLineID: line.ID, Amount: -100000, Reason: "Bütçe azaltımı",
		})
		if err != nil {
			t.Fatalf("negatif revizyon oluşturulamadı: %v", err)
		}
		if _, err := projectSvc.ApproveBudgetAdjustment(ctx, p.ID, adj.ID, orgA.ID, ""); err != nil {
			t.Fatalf("negatif revizyon onaylanamadı: %v", err)
		}
		lines, err := projectSvc.CostControlLines(ctx, p.ID, orgA.ID)
		if err != nil {
			t.Fatalf("kırılım tablosu alınamadı: %v", err)
		}
		got := findLine(t, lines, line.ID)
		if got.RevisedBudget != 600000 {
			t.Errorf("beklenen revised=600000, geldi: %v", got.RevisedBudget)
		}
	})

	t.Run("18_double_approve_rejected", func(t *testing.T) {
		p, line := setupBaselinedLine(t, orgA.ID, 100000, 700000)
		adj, err := projectSvc.CreateBudgetAdjustment(ctx, p.ID, orgA.ID, service.BudgetAdjustmentInput{
			BudgetLineID: line.ID, Amount: 10000, Reason: "Çift onay testi",
		})
		if err != nil {
			t.Fatalf("revizyon oluşturulamadı: %v", err)
		}
		if _, err := projectSvc.ApproveBudgetAdjustment(ctx, p.ID, adj.ID, orgA.ID, ""); err != nil {
			t.Fatalf("ilk onay başarısız: %v", err)
		}
		_, err = projectSvc.ApproveBudgetAdjustment(ctx, p.ID, adj.ID, orgA.ID, "")
		if !errors.Is(err, service.ErrAdjustmentNotPending) {
			t.Errorf("beklenen ErrAdjustmentNotPending, geldi: %v", err)
		}
	})

	// ---------- 19-20: Taahhüt (Commitment) ----------

	t.Run("19_manual_commitment_reflected_in_committed_cost", func(t *testing.T) {
		p, line := setupBaselinedLine(t, orgA.ID, 100000, 700000)
		cc, err := costCodeSvc.Get(ctx, line.CostCodeID, orgA.ID)
		if err != nil {
			t.Fatalf("maliyet kodu alınamadı: %v", err)
		}
		if _, err := projectSvc.CreateCommitment(ctx, p.ID, orgA.ID, service.CommitmentInput{
			CostCodeID: cc.ID, BudgetLineID: line.ID, Description: "Manuel taahhüt", CommittedAmount: 400000, CommittedAt: time.Now(),
		}); err != nil {
			t.Fatalf("taahhüt oluşturulamadı: %v", err)
		}
		lines, err := projectSvc.CostControlLines(ctx, p.ID, orgA.ID)
		if err != nil {
			t.Fatalf("kırılım tablosu alınamadı: %v", err)
		}
		got := findLine(t, lines, line.ID)
		if got.CommittedCost != 400000 {
			t.Errorf("beklenen committed_cost=400000, geldi: %v", got.CommittedCost)
		}
	})

	t.Run("20_voided_commitment_excluded_from_committed_cost", func(t *testing.T) {
		p, line := setupBaselinedLine(t, orgA.ID, 100000, 700000)
		com, err := projectSvc.CreateCommitment(ctx, p.ID, orgA.ID, service.CommitmentInput{
			CostCodeID: line.CostCodeID, BudgetLineID: line.ID, Description: "İptal edilecek", CommittedAmount: 250000, CommittedAt: time.Now(),
		})
		if err != nil {
			t.Fatalf("taahhüt oluşturulamadı: %v", err)
		}
		if _, err := projectSvc.VoidCommitment(ctx, p.ID, com.ID, orgA.ID, "", "vazgeçildi"); err != nil {
			t.Fatalf("taahhüt iptal edilemedi: %v", err)
		}
		lines, err := projectSvc.CostControlLines(ctx, p.ID, orgA.ID)
		if err != nil {
			t.Fatalf("kırılım tablosu alınamadı: %v", err)
		}
		got := findLine(t, lines, line.ID)
		if got.CommittedCost != 0 {
			t.Errorf("iptal edilen taahhüt committed_cost'tan DIŞLANMALI: %v", got.CommittedCost)
		}
	})

	// ---------- 21-22: Gerçekleşen (Expense entegrasyonu) ----------

	t.Run("21_expense_with_budget_line_reflected_in_actual_cost", func(t *testing.T) {
		p, line := setupBaselinedLine(t, orgA.ID, 100000, 700000)
		if _, err := projectSvc.CreateExpense(ctx, p.ID, orgA.ID, service.ExpenseInput{
			Category: domain.ExpenseMaterial, Description: "Çimento", Amount: 300000, ExpenseDate: time.Now(), BudgetLineID: line.ID,
		}); err != nil {
			t.Fatalf("masraf oluşturulamadı: %v", err)
		}
		lines, err := projectSvc.CostControlLines(ctx, p.ID, orgA.ID)
		if err != nil {
			t.Fatalf("kırılım tablosu alınamadı: %v", err)
		}
		got := findLine(t, lines, line.ID)
		if got.ActualCost != 300000 {
			t.Errorf("beklenen actual_cost=300000, geldi: %v", got.ActualCost)
		}
	})

	t.Run("22_voided_expense_excluded_from_actual_cost", func(t *testing.T) {
		p, line := setupBaselinedLine(t, orgA.ID, 100000, 700000)
		exp, err := projectSvc.CreateExpense(ctx, p.ID, orgA.ID, service.ExpenseInput{
			Category: domain.ExpenseMaterial, Description: "İptal edilecek masraf", Amount: 150000, ExpenseDate: time.Now(), BudgetLineID: line.ID,
		})
		if err != nil {
			t.Fatalf("masraf oluşturulamadı: %v", err)
		}
		if _, err := projectSvc.VoidExpense(ctx, p.ID, exp.ID, orgA.ID, "", "hatalı girildi"); err != nil {
			t.Fatalf("masraf iptal edilemedi: %v", err)
		}
		lines, err := projectSvc.CostControlLines(ctx, p.ID, orgA.ID)
		if err != nil {
			t.Fatalf("kırılım tablosu alınamadı: %v", err)
		}
		got := findLine(t, lines, line.ID)
		if got.ActualCost != 0 {
			t.Errorf("iptal edilen masraf actual_cost'tan DIŞLANMALI: %v", got.ActualCost)
		}
	})

	t.Run("23_cross_project_expense_to_budget_line_denied", func(t *testing.T) {
		_, lineA := setupBaselinedLine(t, orgA.ID, 100000, 700000)
		pB := newProject(t, orgA.ID, 50000)
		_, err := projectSvc.CreateExpense(ctx, pB.ID, orgA.ID, service.ExpenseInput{
			Category: domain.ExpenseMaterial, Description: "Çapraz proje IDOR denemesi", Amount: 1000, ExpenseDate: time.Now(),
			BudgetLineID: lineA.ID,
		})
		if !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("beklenen domain.ErrNotFound (çapraz proje bütçe kalemi REDDEDİLMELİ), geldi: %v", err)
		}
	})

	// ---------- 24-26: Tahmin (Forecast / ETC) ----------

	t.Run("24_default_etc_without_override_uses_remaining_budget", func(t *testing.T) {
		p, line := setupBaselinedLine(t, orgA.ID, 100000, 700000)
		if _, err := projectSvc.CreateExpense(ctx, p.ID, orgA.ID, service.ExpenseInput{
			Category: domain.ExpenseMaterial, Description: "Gerçekleşen", Amount: 200000, ExpenseDate: time.Now(), BudgetLineID: line.ID,
		}); err != nil {
			t.Fatalf("masraf oluşturulamadı: %v", err)
		}
		lines, err := projectSvc.CostControlLines(ctx, p.ID, orgA.ID)
		if err != nil {
			t.Fatalf("kırılım tablosu alınamadı: %v", err)
		}
		got := findLine(t, lines, line.ID)
		// Varsayılan ETC = GREATEST(revised - actual, 0) = 700000-200000 = 500000
		if got.ETCAmount != 500000 {
			t.Errorf("beklenen varsayılan etc=500000, geldi: %v", got.ETCAmount)
		}
		if got.EAC != 700000 {
			t.Errorf("beklenen eac=actual+etc=700000, geldi: %v", got.EAC)
		}
	})

	t.Run("25_manual_etc_override_reflected", func(t *testing.T) {
		p, line := setupBaselinedLine(t, orgA.ID, 100000, 700000)
		if _, err := projectSvc.CreateExpense(ctx, p.ID, orgA.ID, service.ExpenseInput{
			Category: domain.ExpenseMaterial, Description: "Gerçekleşen", Amount: 200000, ExpenseDate: time.Now(), BudgetLineID: line.ID,
		}); err != nil {
			t.Fatalf("masraf oluşturulamadı: %v", err)
		}
		if _, err := projectSvc.UpsertForecastETC(ctx, p.ID, line.ID, orgA.ID, 400000, "Saha tahmini gerçek kalan", ""); err != nil {
			t.Fatalf("tahmin güncellenemedi: %v", err)
		}
		lines, err := projectSvc.CostControlLines(ctx, p.ID, orgA.ID)
		if err != nil {
			t.Fatalf("kırılım tablosu alınamadı: %v", err)
		}
		got := findLine(t, lines, line.ID)
		if got.ETCAmount != 400000 {
			t.Errorf("manuel ETC override'ı YOK SAYILMAMALI: beklenen 400000, geldi: %v", got.ETCAmount)
		}
		if got.EAC != 600000 {
			t.Errorf("beklenen eac=actual(200000)+etc(400000)=600000, geldi: %v", got.EAC)
		}
	})

	t.Run("26_unbudgeted_spend_surfaces_as_separate_row", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		cc := newCostCode(t, orgA.ID, "MLZ-UBG")
		// Bu cost code'a bağlı HİÇBİR bütçe kalemi YOK -- doğrudan bir
		// masraf ekleniyor (budget_line_id BOŞ, yalnızca cost_code_id).
		if _, err := projectSvc.CreateExpense(ctx, p.ID, orgA.ID, service.ExpenseInput{
			Category: domain.ExpenseMaterial, Description: "Plansız harcama", Amount: 5000, ExpenseDate: time.Now(), CostCodeID: cc.ID,
		}); err != nil {
			t.Fatalf("masraf oluşturulamadı: %v", err)
		}
		lines, err := projectSvc.CostControlLines(ctx, p.ID, orgA.ID)
		if err != nil {
			t.Fatalf("kırılım tablosu alınamadı: %v", err)
		}
		var found *domain.CostControlLine
		for i := range lines {
			if lines[i].CostCodeID == cc.ID {
				found = &lines[i]
			}
		}
		if found == nil {
			t.Fatalf("bütçe dışı satır kırılım tablosunda GÖRÜNMELİ")
		}
		if !found.IsUnbudgeted || found.OriginalAmount != 0 || found.Variance != -5000 {
			t.Errorf("beklenen is_unbudgeted=true original=0 variance=-5000, geldi: %+v", found)
		}
	})

	// ---------- 27-29: Özet (Summary) ve marj güvenliği ----------

	t.Run("27_summary_has_budget_false_for_new_project_before_explicit_check", func(t *testing.T) {
		// NOT: offer dönüşümü artık HER ZAMAN boş bir taslak bütçe
		// oluşturuyor (bkz. test 8) -- bu yüzden HasBudget burada true
		// olmalı; "bütçesiz proje" durumu yalnızca Sprint 2 ÖNCESİ var
		// olan (migration 0035'ten önce oluşturulmuş) projeler için
		// geçerlidir ve doğrudan SQL ile simüle edilir.
		p := newProject(t, orgA.ID, 100000)
		if _, err := pool.Exec(ctx, "DELETE FROM project_budgets WHERE project_id = $1", p.ID); err != nil {
			t.Fatalf("bütçe satırı silinemedi (test kurulumu): %v", err)
		}
		summary, err := projectSvc.CostControlSummary(ctx, p.ID, orgA.ID)
		if err != nil {
			t.Fatalf("bütçesiz projede özet HATA VERMEMELİ: %v", err)
		}
		if summary.HasBudget {
			t.Errorf("bütçe silindikten sonra HasBudget=false olmalı")
		}
		if summary.ContractValue != 100000 {
			t.Errorf("bütçesiz projede bile sözleşme bedeli görünmeli: %v", summary.ContractValue)
		}
	})

	t.Run("28_project_total_matches_sum_of_line_breakdown", func(t *testing.T) {
		p, line := setupBaselinedLine(t, orgA.ID, 1000000, 700000)
		adj, err := projectSvc.CreateBudgetAdjustment(ctx, p.ID, orgA.ID, service.BudgetAdjustmentInput{
			BudgetLineID: line.ID, Amount: 50000, Reason: "Toplam tutarlılık testi",
		})
		if err != nil {
			t.Fatalf("revizyon oluşturulamadı: %v", err)
		}
		if _, err := projectSvc.ApproveBudgetAdjustment(ctx, p.ID, adj.ID, orgA.ID, ""); err != nil {
			t.Fatalf("revizyon onaylanamadı: %v", err)
		}
		if _, err := projectSvc.CreateExpense(ctx, p.ID, orgA.ID, service.ExpenseInput{
			Category: domain.ExpenseMaterial, Description: "Gerçekleşen", Amount: 300000, ExpenseDate: time.Now(), BudgetLineID: line.ID,
		}); err != nil {
			t.Fatalf("masraf oluşturulamadı: %v", err)
		}
		lines, err := projectSvc.CostControlLines(ctx, p.ID, orgA.ID)
		if err != nil {
			t.Fatalf("kırılım tablosu alınamadı: %v", err)
		}
		summary, err := projectSvc.CostControlSummary(ctx, p.ID, orgA.ID)
		if err != nil {
			t.Fatalf("özet alınamadı: %v", err)
		}
		var sumRevised, sumActual, sumEAC float64
		for _, l := range lines {
			sumRevised += l.RevisedBudget
			sumActual += l.ActualCost
			sumEAC += l.EAC
		}
		// Spec §13: proje toplamı, satır kırılımıyla AYNI KURALLA (SUM())
		// hesaplanmalı -- bağımsız bir formülle YENİDEN türetilmemeli.
		if sumRevised != summary.RevisedBudget || sumActual != summary.ActualCost || sumEAC != summary.EACTotal {
			t.Errorf("proje toplamı satır toplamlarıyla UYUŞMUYOR: satır(revised=%v,actual=%v,eac=%v) özet(revised=%v,actual=%v,eac=%v)",
				sumRevised, sumActual, sumEAC, summary.RevisedBudget, summary.ActualCost, summary.EACTotal)
		}
	})

	t.Run("29_zero_contract_value_margin_safe", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		zeroOutContract(t, orgA.ID, p.ID, 100000)
		summary, err := projectSvc.CostControlSummary(ctx, p.ID, orgA.ID)
		if err != nil {
			t.Fatalf("özet alınamadı: %v", err)
		}
		if summary.ContractValue != 0 {
			t.Fatalf("beklenen sözleşme bedeli 0, geldi: %v", summary.ContractValue)
		}
		if summary.ForecastMarginPercent != 0 {
			t.Errorf("sıfır sözleşme bedelinde marj GÜVENLE 0 dönmeli, geldi: %v", summary.ForecastMarginPercent)
		}
	})

	// ---------- 30-31: Erişim/İzin (servis katmanında IDOR sınıfı) ----------
	// NOT: rol tabanlı (finance-allowed/field-denied/owner-admin-bypass)
	// GERÇEK HTTP senaryoları internal/httpapi/middleware/cost_control_
	// security_test.go'dadır (Sprint 1'in require_permission_test.go İLE
	// AYNI desen); burada yalnızca servis katmanının kendi org+proje
	// sınırlarını (organization_id/project_id filtreleri) doğruluyoruz.

	t.Run("30_cross_tenant_budget_line_get_denied", func(t *testing.T) {
		_, lineA := setupBaselinedLine(t, orgA.ID, 100000, 700000)
		pB := newProject(t, orgB.ID, 50000)
		// orgB bağlamında, orgA'nın bütçe kalemi UUID'sine bir adjustment
		// oluşturma denemesi -- ne organizasyon ne proje eşleşiyor.
		_, err := projectSvc.CreateBudgetAdjustment(ctx, pB.ID, orgB.ID, service.BudgetAdjustmentInput{
			BudgetLineID: lineA.ID, Amount: 100, Reason: "Çapraz kiracı IDOR denemesi",
		})
		if !errors.Is(err, service.ErrBudgetNotYetBaselined) && !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("beklenen ErrBudgetNotYetBaselined ya da ErrNotFound (asla başarı), geldi: %v", err)
		}
	})

	t.Run("31_cross_project_commitment_budget_line_denied", func(t *testing.T) {
		_, lineA := setupBaselinedLine(t, orgA.ID, 100000, 700000)
		pB := newProject(t, orgA.ID, 50000)
		_, err := projectSvc.CreateCommitment(ctx, pB.ID, orgA.ID, service.CommitmentInput{
			CostCodeID: lineA.CostCodeID, BudgetLineID: lineA.ID, Description: "Çapraz proje taahhüt denemesi",
			CommittedAmount: 1000, CommittedAt: time.Now(),
		})
		if !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("beklenen domain.ErrNotFound (Proje A'nın bütçe kalemi, Proje B'den ASLA erişilemez), geldi: %v", err)
		}
	})

	// ---------- 35: Golden Money Test (spec §35, tam sayısal örnek) ----------

	t.Run("golden_money_exact_worked_example", func(t *testing.T) {
		p, line := setupBaselinedLine(t, orgA.ID, 1000000, 700000)

		adj, err := projectSvc.CreateBudgetAdjustment(ctx, p.ID, orgA.ID, service.BudgetAdjustmentInput{
			BudgetLineID: line.ID, Amount: 50000, Reason: "Golden money test",
		})
		if err != nil {
			t.Fatalf("revizyon oluşturulamadı: %v", err)
		}
		if _, err := projectSvc.ApproveBudgetAdjustment(ctx, p.ID, adj.ID, orgA.ID, ""); err != nil {
			t.Fatalf("revizyon onaylanamadı: %v", err)
		}
		if _, err := projectSvc.CreateCommitment(ctx, p.ID, orgA.ID, service.CommitmentInput{
			CostCodeID: line.CostCodeID, BudgetLineID: line.ID, Description: "Golden money taahhüt",
			CommittedAmount: 400000, CommittedAt: time.Now(),
		}); err != nil {
			t.Fatalf("taahhüt oluşturulamadı: %v", err)
		}
		if _, err := projectSvc.CreateExpense(ctx, p.ID, orgA.ID, service.ExpenseInput{
			Category: domain.ExpenseMaterial, Description: "Golden money gerçekleşen", Amount: 300000,
			ExpenseDate: time.Now(), BudgetLineID: line.ID,
		}); err != nil {
			t.Fatalf("masraf oluşturulamadı: %v", err)
		}
		if _, err := projectSvc.UpsertForecastETC(ctx, p.ID, line.ID, orgA.ID, 350000, "Golden money ETC", ""); err != nil {
			t.Fatalf("tahmin güncellenemedi: %v", err)
		}

		summary, err := projectSvc.CostControlSummary(ctx, p.ID, orgA.ID)
		if err != nil {
			t.Fatalf("özet alınamadı: %v", err)
		}
		cases := []struct {
			name string
			got  float64
			want float64
		}{
			{"contract_value", summary.ContractValue, 1000000},
			{"original_budget", summary.OriginalBudget, 700000},
			{"approved_adjustments", summary.ApprovedAdjustments, 50000},
			{"revised_budget", summary.RevisedBudget, 750000},
			{"committed_cost", summary.CommittedCost, 400000},
			{"actual_cost", summary.ActualCost, 300000},
			{"etc", summary.ETCTotal, 350000},
			{"eac", summary.EACTotal, 650000},
			{"variance", summary.Variance, 100000},
			{"forecast_profit", summary.ForecastProfit, 350000},
			{"forecast_margin_percent", summary.ForecastMarginPercent, 35},
		}
		for _, c := range cases {
			if c.got != c.want {
				t.Errorf("golden money %s: beklenen %v, geldi %v (float sürüklenmesi KABUL EDİLEMEZ)", c.name, c.want, c.got)
			}
		}

		lines, err := projectSvc.CostControlLines(ctx, p.ID, orgA.ID)
		if err != nil {
			t.Fatalf("kırılım tablosu alınamadı: %v", err)
		}
		lineGot := findLine(t, lines, line.ID)
		if lineGot.EAC != 650000 || lineGot.Variance != 100000 {
			t.Errorf("satır seviyesi golden money değerleri de AYNI olmalı: eac=%v variance=%v", lineGot.EAC, lineGot.Variance)
		}
	})

	t.Run("32_cost_code_only_expense_counts_against_its_single_budget_line", func(t *testing.T) {
		// Bütçe kalemi seçilmeden, yalnızca maliyet koduyla girilen masraf:
		// kodun TEK bütçe kalemi varsa ona sayılır. Önceden ayrı bir "bütçe
		// dışı" satıra düşüyor, kalemin ETC'si azalmadığı için EAC 130.000
		// çıkıyordu (aynı 30.000 iki kez).
		p := newProject(t, orgA.ID, 500000)
		cc := newCostCode(t, orgA.ID, "MLZ-CCO-"+p.ID[:8])
		line, err := projectSvc.CreateBudgetLine(ctx, p.ID, orgA.ID, service.BudgetLineInput{
			CostCodeID: cc.ID, Description: "Tek kalem", OriginalAmount: 100000,
		})
		if err != nil {
			t.Fatalf("bütçe kalemi oluşturulamadı: %v", err)
		}
		if _, err := projectSvc.CreateExpense(ctx, p.ID, orgA.ID, service.ExpenseInput{
			Category: domain.ExpenseMaterial, Description: "Kodlu masraf", Amount: 30000, ExpenseDate: time.Now(), CostCodeID: cc.ID,
		}); err != nil {
			t.Fatalf("masraf oluşturulamadı: %v", err)
		}
		if _, err := projectSvc.CreateCommitment(ctx, p.ID, orgA.ID, service.CommitmentInput{
			CostCodeID: cc.ID, Description: "Kodlu taahhüt", CommittedAmount: 20000, CommittedAt: time.Now(),
		}); err != nil {
			t.Fatalf("taahhüt oluşturulamadı: %v", err)
		}
		lines, err := projectSvc.CostControlLines(ctx, p.ID, orgA.ID)
		if err != nil {
			t.Fatalf("kırılım tablosu alınamadı: %v", err)
		}
		got := findLine(t, lines, line.ID)
		if got.ActualCost != 30000 || got.CommittedCost != 20000 || got.EAC != 100000 {
			t.Errorf("kalem actual=30000 committed=20000 eac=100000 olmalı, geldi: %+v", got)
		}
		for _, l := range lines {
			if l.IsUnbudgeted && l.CostCodeID == cc.ID {
				t.Errorf("kodun tek bütçe kalemi varken bütçe dışı satır OLMAMALI: %+v", l)
			}
		}
		sum, err := projectSvc.CostControlSummary(ctx, p.ID, orgA.ID)
		if err != nil {
			t.Fatalf("özet alınamadı: %v", err)
		}
		if sum.ActualCost != 30000 || sum.EACTotal != 100000 {
			t.Errorf("özet actual=30000 eac=100000 olmalı (çift sayım yok), geldi actual=%v eac=%v", sum.ActualCost, sum.EACTotal)
		}

		// Kodun İKİNCİ bir bütçe kalemi açılırsa hangi kaleme ait olduğu
		// belirsizdir: kayıt bütçe dışı satırda görünür.
		if _, err := projectSvc.CreateBudgetLine(ctx, p.ID, orgA.ID, service.BudgetLineInput{
			CostCodeID: cc.ID, Description: "İkinci kalem", OriginalAmount: 50000,
		}); err != nil {
			t.Fatalf("ikinci bütçe kalemi oluşturulamadı: %v", err)
		}
		lines, err = projectSvc.CostControlLines(ctx, p.ID, orgA.ID)
		if err != nil {
			t.Fatalf("kırılım tablosu alınamadı: %v", err)
		}
		if got := findLine(t, lines, line.ID); got.ActualCost != 0 {
			t.Errorf("belirsiz eşlemede masraf ilk kaleme sayılmamalı, geldi: %v", got.ActualCost)
		}
		found := false
		for _, l := range lines {
			if l.IsUnbudgeted && l.CostCodeID == cc.ID && l.ActualCost == 30000 {
				found = true
			}
		}
		if !found {
			t.Errorf("belirsiz eşlemede masraf bütçe dışı satırda görünmeli")
		}
	})
}
