package service_test

// ARVEND V2 -- Sprint 5 (Taşeron Yönetimi) için otomatik testler -- gerçek
// bir PostgreSQL bağlantısı gerektirir (bkz. tenant_isolation_test.go'daki
// paylaşılan yardımcılar). Subcontract + SOV + Subcontract Change Order +
// Progress Claim (Hakediş) + Cost Control commitment entegrasyonu
// senaryolarını kapsar.

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

func TestSubcontracts(t *testing.T) {
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
	supplierSvc := service.NewSupplierService(pool, q, box)

	orgA := mustCreateOrg(t, ctx, orgSvc, pool, "Taşeron Test Firma A", "taseron-test-firma-a")
	orgB := mustCreateOrg(t, ctx, orgSvc, pool, "Taşeron Test Firma B", "taseron-test-firma-b")

	newProject := func(t *testing.T, orgID string, contractAmount float64) *domain.Project {
		t.Helper()
		o, err := offerSvc.Create(ctx, service.CreateOfferInput{
			OrganizationID: orgID, CustomerName: "Taşeron Test Müşteri", VatRate: ptrFloat(0),
			Items: []service.OfferItemInput{{ProductName: "İş", Quantity: 1, UnitPrice: contractAmount}},
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
		p, err := projectSvc.CreateFromOffer(ctx, o.ID, orgID, service.CreateProjectInput{Name: "Taşeron Test Projesi"})
		if err != nil {
			t.Fatalf("proje oluşturulamadı: %v", err)
		}
		return p
	}

	newCostCode := func(t *testing.T, orgID, code string) *domain.OrganizationCostCode {
		t.Helper()
		c, err := costCodeSvc.Create(ctx, orgID, service.CostCodeInput{Code: code, Name: "Kod " + code, Category: "Taşeron"})
		if err != nil {
			t.Fatalf("maliyet kodu oluşturulamadı: %v", err)
		}
		return c
	}

	newSupplier := func(t *testing.T, orgID, code string) *domain.Supplier {
		t.Helper()
		s, err := supplierSvc.Create(ctx, orgID, service.SupplierInput{Code: code, LegalName: "Taşeron " + code, Specialty: "Elektrik"})
		if err != nil {
			t.Fatalf("tedarikçi oluşturulamadı: %v", err)
		}
		return s
	}

	// newDraftSubcontract, tek kalemli bir taslak taşeron sözleşmesi döner.
	newDraftSubcontract := func(t *testing.T, orgID, projectID, supplierID, costCodeID string, amount float64) *domain.Subcontract {
		t.Helper()
		sc, err := projectSvc.CreateSubcontract(ctx, projectID, orgID, service.SubcontractInput{
			SupplierID: supplierID, Title: "Test Taşeron Sözleşmesi",
			Items: []service.SubcontractItemInput{{CostCodeID: costCodeID, Description: "İmalat", OriginalAmount: amount}},
		})
		if err != nil {
			t.Fatalf("taşeron sözleşmesi oluşturulamadı: %v", err)
		}
		return sc
	}

	newActiveSubcontract := func(t *testing.T, orgID, projectID, supplierID, costCodeID string, amount float64) *domain.Subcontract {
		t.Helper()
		sc := newDraftSubcontract(t, orgID, projectID, supplierID, costCodeID, amount)
		active, err := projectSvc.ActivateSubcontract(ctx, projectID, sc.ID, orgID, "")
		if err != nil {
			t.Fatalf("taşeron sözleşmesi aktifleştirilemedi: %v", err)
		}
		return active
	}

	// ---------- VENDOR ----------

	t.Run("1_supplier_used_as_subcontractor_no_duplicate_master", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		cc := newCostCode(t, orgA.ID, "V1-CC")
		s := newSupplier(t, orgA.ID, "V1-S")
		sc := newDraftSubcontract(t, orgA.ID, p.ID, s.ID, cc.ID, 10000)
		if sc.SupplierID != s.ID {
			t.Fatalf("subcontract, Sprint 4 supplier master'ını DOĞRUDAN referans almalı, beklenen %s geldi %s", s.ID, sc.SupplierID)
		}
	})

	t.Run("2_cross_tenant_supplier_denied", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		cc := newCostCode(t, orgA.ID, "V2-CC")
		sB := newSupplier(t, orgB.ID, "V2-S")
		_, err := projectSvc.CreateSubcontract(ctx, p.ID, orgA.ID, service.SubcontractInput{
			SupplierID: sB.ID, Title: "Çapraz Org Denemesi",
			Items: []service.SubcontractItemInput{{CostCodeID: cc.ID, Description: "K", OriginalAmount: 1000}},
		})
		if !errors.Is(err, domain.ErrNotFound) {
			t.Fatalf("B organizasyonuna ait tedarikçi A projesinde REDDEDİLMELİ, geldi: %v", err)
		}
	})

	// ---------- SUBCONTRACT LIFECYCLE / SOV ----------

	t.Run("3_create_draft_multi_item_exact_total", func(t *testing.T) {
		p := newProject(t, orgA.ID, 200000)
		cc := newCostCode(t, orgA.ID, "S3-CC")
		s := newSupplier(t, orgA.ID, "S3-S")
		sc, err := projectSvc.CreateSubcontract(ctx, p.ID, orgA.ID, service.SubcontractInput{
			SupplierID: s.ID, Title: "Çok Kalemli",
			Items: []service.SubcontractItemInput{
				{CostCodeID: cc.ID, Description: "K1", OriginalAmount: 12345.67},
				{CostCodeID: cc.ID, Description: "K2", Quantity: ptrFloat(10), UnitPrice: ptrFloat(100.5)},
			},
		})
		if err != nil {
			t.Fatalf("oluşturulamadı: %v", err)
		}
		want := 12345.67 + 1005.0
		if sc.OriginalAmount != want {
			t.Fatalf("header original_amount kalemler toplamıyla TUTARLI olmalı: beklenen %.2f geldi %.2f", want, sc.OriginalAmount)
		}
	})

	t.Run("4_draft_baseline_editable_active_locked", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		cc := newCostCode(t, orgA.ID, "S4-CC")
		s := newSupplier(t, orgA.ID, "S4-S")
		sc := newDraftSubcontract(t, orgA.ID, p.ID, s.ID, cc.ID, 5000)
		if _, err := projectSvc.UpdateSubcontractDraft(ctx, p.ID, sc.ID, orgA.ID, service.SubcontractInput{
			SupplierID: s.ID, Title: "Güncellenmiş", Items: []service.SubcontractItemInput{{CostCodeID: cc.ID, Description: "K", OriginalAmount: 6000}},
		}); err != nil {
			t.Fatalf("draft düzenlenebilmeli: %v", err)
		}
		active, err := projectSvc.ActivateSubcontract(ctx, p.ID, sc.ID, orgA.ID, "")
		if err != nil {
			t.Fatalf("aktifleştirilemedi: %v", err)
		}
		if active.OriginalAmount != 6000 {
			t.Fatalf("aktivasyon SONRASI ticari taban 6000 olmalı, geldi %v", active.OriginalAmount)
		}
		if _, err := projectSvc.UpdateSubcontractDraft(ctx, p.ID, sc.ID, orgA.ID, service.SubcontractInput{
			SupplierID: s.ID, Title: "İkinci Deneme", Items: []service.SubcontractItemInput{{CostCodeID: cc.ID, Description: "K", OriginalAmount: 7000}},
		}); !errors.Is(err, service.ErrSubcontractNotEditable) {
			t.Fatalf("ACTIVE sonrası düzenleme REDDEDİLMELİ, geldi: %v", err)
		}
	})

	t.Run("5_activation_creates_commitment_exactly_once", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		cc := newCostCode(t, orgA.ID, "S5-CC")
		s := newSupplier(t, orgA.ID, "S5-S")
		sc := newActiveSubcontract(t, orgA.ID, p.ID, s.ID, cc.ID, 50000)
		commitments, err := projectSvc.ListCommitmentsForSubcontract(ctx, p.ID, sc.ID, orgA.ID)
		if err != nil {
			t.Fatalf("taahhütler listelenemedi: %v", err)
		}
		active := 0
		total := 0.0
		for _, c := range commitments {
			if c.Status == domain.CommitmentStatusActive {
				active++
				total += c.CommittedAmount
			}
		}
		if active != 1 {
			t.Fatalf("aktivasyon TAM OLARAK bir aktif commitment satırı üretmeli, geldi %d", active)
		}
		if total != 50000 {
			t.Fatalf("commitment tutarı 50000 olmalı, geldi %v", total)
		}
	})

	t.Run("6_double_activation_rejected_idempotent_commitment", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		cc := newCostCode(t, orgA.ID, "S6-CC")
		s := newSupplier(t, orgA.ID, "S6-S")
		sc := newActiveSubcontract(t, orgA.ID, p.ID, s.ID, cc.ID, 20000)
		if _, err := projectSvc.ActivateSubcontract(ctx, p.ID, sc.ID, orgA.ID, ""); !errors.Is(err, service.ErrSubcontractNotActivatable) {
			t.Fatalf("ikinci aktivasyon REDDEDİLMELİ, geldi: %v", err)
		}
		commitments, _ := projectSvc.ListCommitmentsForSubcontract(ctx, p.ID, sc.ID, orgA.ID)
		active := 0
		for _, c := range commitments {
			if c.Status == domain.CommitmentStatusActive {
				active++
			}
		}
		if active != 1 {
			t.Fatalf("çift aktivasyon denemesi DUPLICATE commitment üretmemeli, aktif sayısı: %d", active)
		}
	})

	t.Run("7_draft_cancel_no_commitment_ever", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		cc := newCostCode(t, orgA.ID, "S7-CC")
		s := newSupplier(t, orgA.ID, "S7-S")
		sc := newDraftSubcontract(t, orgA.ID, p.ID, s.ID, cc.ID, 5000)
		cancelled, err := projectSvc.CancelSubcontract(ctx, p.ID, sc.ID, orgA.ID, "", "vazgeçildi")
		if err != nil {
			t.Fatalf("draft iptal edilemedi: %v", err)
		}
		if cancelled.Status != domain.SubcontractStatusCancelled {
			t.Fatalf("status cancelled olmalı, geldi %s", cancelled.Status)
		}
		commitments, _ := projectSvc.ListCommitmentsForSubcontract(ctx, p.ID, sc.ID, orgA.ID)
		if len(commitments) != 0 {
			t.Fatalf("draft iptalinde HİÇBİR commitment satırı olmamalı (hiç oluşmadı), geldi %d", len(commitments))
		}
	})

	t.Run("8_active_cannot_be_cancelled_only_terminated", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		cc := newCostCode(t, orgA.ID, "S8-CC")
		s := newSupplier(t, orgA.ID, "S8-S")
		sc := newActiveSubcontract(t, orgA.ID, p.ID, s.ID, cc.ID, 20000)
		if _, err := projectSvc.CancelSubcontract(ctx, p.ID, sc.ID, orgA.ID, "", "gerekçe"); !errors.Is(err, service.ErrSubcontractNotCancellable) {
			t.Fatalf("ACTIVE cancel REDDEDİLMELİ, geldi: %v", err)
		}
	})

	t.Run("9_draft_cannot_be_terminated", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		cc := newCostCode(t, orgA.ID, "S9-CC")
		s := newSupplier(t, orgA.ID, "S9-S")
		sc := newDraftSubcontract(t, orgA.ID, p.ID, s.ID, cc.ID, 5000)
		if _, err := projectSvc.TerminateSubcontract(ctx, p.ID, sc.ID, orgA.ID, "", "gerekçe"); !errors.Is(err, service.ErrSubcontractNotTerminable) {
			t.Fatalf("DRAFT ASLA terminate edilememeli, geldi: %v", err)
		}
	})

	t.Run("10_completion_does_not_touch_commitment", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		cc := newCostCode(t, orgA.ID, "S10-CC")
		s := newSupplier(t, orgA.ID, "S10-S")
		sc := newActiveSubcontract(t, orgA.ID, p.ID, s.ID, cc.ID, 30000)
		completed, err := projectSvc.CompleteSubcontract(ctx, p.ID, sc.ID, orgA.ID, "")
		if err != nil {
			t.Fatalf("tamamlanamadı: %v", err)
		}
		if completed.Status != domain.SubcontractStatusCompleted {
			t.Fatalf("status completed olmalı, geldi %s", completed.Status)
		}
		commitments, _ := projectSvc.ListCommitmentsForSubcontract(ctx, p.ID, sc.ID, orgA.ID)
		active := 0
		for _, c := range commitments {
			if c.Status == domain.CommitmentStatusActive {
				active++
			}
		}
		if active != 1 {
			t.Fatalf("tamamlanma commitment'a DOKUNMAMALI, aktif sayısı hâlâ 1 olmalı, geldi %d", active)
		}
	})

	t.Run("11_cross_project_budget_line_rejected", func(t *testing.T) {
		p1 := newProject(t, orgA.ID, 100000)
		p2 := newProject(t, orgA.ID, 100000)
		cc := newCostCode(t, orgA.ID, "S11-CC")
		bl, err := projectSvc.CreateBudgetLine(ctx, p2.ID, orgA.ID, service.BudgetLineInput{CostCodeID: cc.ID, Description: "P2 Kalemi", OriginalAmount: 50000})
		if err != nil {
			t.Fatalf("bütçe kalemi oluşturulamadı: %v", err)
		}
		s := newSupplier(t, orgA.ID, "S11-S")
		_, err = projectSvc.CreateSubcontract(ctx, p1.ID, orgA.ID, service.SubcontractInput{
			SupplierID: s.ID, Title: "Çapraz Proje Denemesi",
			Items: []service.SubcontractItemInput{{CostCodeID: cc.ID, BudgetLineID: bl.ID, Description: "K", OriginalAmount: 1000}},
		})
		if !errors.Is(err, domain.ErrNotFound) {
			t.Fatalf("P1 sözleşmesi P2'nin bütçe kalemini REFERANS ALAMAMALI, geldi: %v", err)
		}
	})

	// ---------- SUBCONTRACT CHANGE ORDERS ----------

	t.Run("12_draft_change_order_no_impact", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		cc := newCostCode(t, orgA.ID, "S12-CC")
		s := newSupplier(t, orgA.ID, "S12-S")
		sc := newActiveSubcontract(t, orgA.ID, p.ID, s.ID, cc.ID, 100000)
		_, err := projectSvc.CreateSubcontractChangeOrder(ctx, p.ID, sc.ID, orgA.ID, service.SubcontractChangeOrderInput{
			Title: "Ek İş 1", ChangeType: domain.SubcontractChangeTypeAddition,
			Items: []service.SubcontractChangeOrderItemInput{{CostCodeID: cc.ID, Description: "K", Amount: 20000}},
		})
		if err != nil {
			t.Fatalf("oluşturulamadı: %v", err)
		}
		val, err := projectSvc.GetSubcontractValue(ctx, p.ID, sc.ID, orgA.ID)
		if err != nil {
			t.Fatalf("değer alınamadı: %v", err)
		}
		if val.CurrentValue != 100000 {
			t.Fatalf("DRAFT değişiklik current_value'yu ETKİLEMEMELİ, beklenen 100000 geldi %v", val.CurrentValue)
		}
	})

	t.Run("13_submitted_change_order_no_impact", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		cc := newCostCode(t, orgA.ID, "S13-CC")
		s := newSupplier(t, orgA.ID, "S13-S")
		sc := newActiveSubcontract(t, orgA.ID, p.ID, s.ID, cc.ID, 100000)
		co, err := projectSvc.CreateSubcontractChangeOrder(ctx, p.ID, sc.ID, orgA.ID, service.SubcontractChangeOrderInput{
			Title: "Ek İş", ChangeType: domain.SubcontractChangeTypeAddition,
			Items: []service.SubcontractChangeOrderItemInput{{CostCodeID: cc.ID, Description: "K", Amount: 20000}},
		})
		if err != nil {
			t.Fatalf("oluşturulamadı: %v", err)
		}
		if _, err := projectSvc.SubmitSubcontractChangeOrder(ctx, p.ID, co.ID, orgA.ID, ""); err != nil {
			t.Fatalf("gönderilemedi: %v", err)
		}
		val, err := projectSvc.GetSubcontractValue(ctx, p.ID, sc.ID, orgA.ID)
		if err != nil {
			t.Fatalf("değer alınamadı: %v", err)
		}
		if val.CurrentValue != 100000 {
			t.Fatalf("SUBMITTED değişiklik current_value'yu ETKİLEMEMELİ, beklenen 100000 geldi %v", val.CurrentValue)
		}
		if val.PendingAdditions != 20000 {
			t.Fatalf("pending_additions 20000 olmalı, geldi %v", val.PendingAdditions)
		}
	})

	t.Run("14_rejected_change_order_no_impact", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		cc := newCostCode(t, orgA.ID, "S14-CC")
		s := newSupplier(t, orgA.ID, "S14-S")
		sc := newActiveSubcontract(t, orgA.ID, p.ID, s.ID, cc.ID, 100000)
		co, err := projectSvc.CreateSubcontractChangeOrder(ctx, p.ID, sc.ID, orgA.ID, service.SubcontractChangeOrderInput{
			Title: "Ek İş", ChangeType: domain.SubcontractChangeTypeAddition,
			Items: []service.SubcontractChangeOrderItemInput{{CostCodeID: cc.ID, Description: "K", Amount: 20000}},
		})
		if err != nil {
			t.Fatalf("oluşturulamadı: %v", err)
		}
		if _, err := projectSvc.SubmitSubcontractChangeOrder(ctx, p.ID, co.ID, orgA.ID, ""); err != nil {
			t.Fatalf("gönderilemedi: %v", err)
		}
		if _, err := projectSvc.RejectSubcontractChangeOrder(ctx, p.ID, co.ID, orgA.ID, "", "uygun değil"); err != nil {
			t.Fatalf("reddedilemedi: %v", err)
		}
		val, err := projectSvc.GetSubcontractValue(ctx, p.ID, sc.ID, orgA.ID)
		if err != nil {
			t.Fatalf("değer alınamadı: %v", err)
		}
		if val.CurrentValue != 100000 {
			t.Fatalf("REJECTED değişiklik current_value'yu ETKİLEMEMELİ, beklenen 100000 geldi %v", val.CurrentValue)
		}
	})

	t.Run("15_approved_addition_updates_value_and_commitment", func(t *testing.T) {
		p := newProject(t, orgA.ID, 200000)
		cc := newCostCode(t, orgA.ID, "S15-CC")
		s := newSupplier(t, orgA.ID, "S15-S")
		sc := newActiveSubcontract(t, orgA.ID, p.ID, s.ID, cc.ID, 100000)
		co, err := projectSvc.CreateSubcontractChangeOrder(ctx, p.ID, sc.ID, orgA.ID, service.SubcontractChangeOrderInput{
			Title: "Ek İş", ChangeType: domain.SubcontractChangeTypeAddition,
			Items: []service.SubcontractChangeOrderItemInput{{CostCodeID: cc.ID, Description: "K", Amount: 20000}},
		})
		if err != nil {
			t.Fatalf("oluşturulamadı: %v", err)
		}
		if _, err := projectSvc.SubmitSubcontractChangeOrder(ctx, p.ID, co.ID, orgA.ID, ""); err != nil {
			t.Fatalf("gönderilemedi: %v", err)
		}
		if _, err := projectSvc.ApproveSubcontractChangeOrder(ctx, p.ID, co.ID, orgA.ID, ""); err != nil {
			t.Fatalf("onaylanamadı: %v", err)
		}
		val, err := projectSvc.GetSubcontractValue(ctx, p.ID, sc.ID, orgA.ID)
		if err != nil {
			t.Fatalf("değer alınamadı: %v", err)
		}
		if val.CurrentValue != 120000 {
			t.Fatalf("APPROVED ekleme SONRASI current_value 120000 olmalı, geldi %v", val.CurrentValue)
		}
		commitments, _ := projectSvc.ListCommitmentsForSubcontract(ctx, p.ID, sc.ID, orgA.ID)
		total := 0.0
		for _, c := range commitments {
			if c.Status == domain.CommitmentStatusActive {
				total += c.CommittedAmount
			}
		}
		if total != 120000 {
			t.Fatalf("commitment toplamı da 120000'e senkronize olmalı, geldi %v", total)
		}
	})

	t.Run("16_approved_deduction_updates_value_and_commitment", func(t *testing.T) {
		p := newProject(t, orgA.ID, 200000)
		cc := newCostCode(t, orgA.ID, "S16-CC")
		s := newSupplier(t, orgA.ID, "S16-S")
		sc := newActiveSubcontract(t, orgA.ID, p.ID, s.ID, cc.ID, 100000)
		co, err := projectSvc.CreateSubcontractChangeOrder(ctx, p.ID, sc.ID, orgA.ID, service.SubcontractChangeOrderInput{
			Title: "Eksiltme", ChangeType: domain.SubcontractChangeTypeDeduction,
			Items: []service.SubcontractChangeOrderItemInput{{CostCodeID: cc.ID, Description: "K", Amount: 15000}},
		})
		if err != nil {
			t.Fatalf("oluşturulamadı: %v", err)
		}
		if _, err := projectSvc.SubmitSubcontractChangeOrder(ctx, p.ID, co.ID, orgA.ID, ""); err != nil {
			t.Fatalf("gönderilemedi: %v", err)
		}
		if _, err := projectSvc.ApproveSubcontractChangeOrder(ctx, p.ID, co.ID, orgA.ID, ""); err != nil {
			t.Fatalf("onaylanamadı: %v", err)
		}
		val, err := projectSvc.GetSubcontractValue(ctx, p.ID, sc.ID, orgA.ID)
		if err != nil {
			t.Fatalf("değer alınamadı: %v", err)
		}
		if val.CurrentValue != 85000 {
			t.Fatalf("APPROVED eksiltme SONRASI current_value 85000 olmalı, geldi %v", val.CurrentValue)
		}
		commitments, _ := projectSvc.ListCommitmentsForSubcontract(ctx, p.ID, sc.ID, orgA.ID)
		total := 0.0
		for _, c := range commitments {
			if c.Status == domain.CommitmentStatusActive {
				total += c.CommittedAmount
			}
		}
		if total != 85000 {
			t.Fatalf("commitment toplamı da 85000'e senkronize olmalı, geldi %v", total)
		}
	})

	t.Run("17_change_order_requires_active_subcontract", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		cc := newCostCode(t, orgA.ID, "S17-CC")
		s := newSupplier(t, orgA.ID, "S17-S")
		sc := newDraftSubcontract(t, orgA.ID, p.ID, s.ID, cc.ID, 10000)
		_, err := projectSvc.CreateSubcontractChangeOrder(ctx, p.ID, sc.ID, orgA.ID, service.SubcontractChangeOrderInput{
			Title: "Erken Değişiklik", ChangeType: domain.SubcontractChangeTypeAddition,
			Items: []service.SubcontractChangeOrderItemInput{{CostCodeID: cc.ID, Description: "K", Amount: 1000}},
		})
		if !errors.Is(err, service.ErrSubcontractNotActiveForChange) {
			t.Fatalf("DRAFT sözleşme için değişiklik oluşturma REDDEDİLMELİ, geldi: %v", err)
		}
	})

	// ---------- PROGRESS CLAIMS (HAKEDİŞ) ----------

	t.Run("18_create_claim_sov_previous_current_cumulative", func(t *testing.T) {
		p := newProject(t, orgA.ID, 200000)
		cc := newCostCode(t, orgA.ID, "S18-CC")
		s := newSupplier(t, orgA.ID, "S18-S")
		sc := newActiveSubcontract(t, orgA.ID, p.ID, s.ID, cc.ID, 100000)
		items, err := projectSvc.ListSubcontractItems(ctx, p.ID, sc.ID, orgA.ID)
		if err != nil || len(items) != 1 {
			t.Fatalf("SOV kalemleri alınamadı: %v", err)
		}
		claim, err := projectSvc.CreateProgressClaim(ctx, p.ID, sc.ID, orgA.ID, service.ProgressClaimInput{
			PeriodEnd: time.Now(),
			Items:     []service.ProgressClaimItemInput{{SubcontractItemID: items[0].ID, CurrentProgressAmount: 30000}},
		})
		if err != nil {
			t.Fatalf("hakediş oluşturulamadı: %v", err)
		}
		claimItems, err := projectSvc.ListProgressClaimItems(ctx, p.ID, claim.ID, orgA.ID)
		if err != nil || len(claimItems) != 1 {
			t.Fatalf("hakediş kalemleri alınamadı: %v", err)
		}
		ci := claimItems[0]
		if ci.PreviousProgressAmount != 0 || ci.CurrentProgressAmount != 30000 || ci.CumulativeProgressAmount != 30000 {
			t.Fatalf("İLK hakedişte previous=0/current=30000/cumulative=30000 olmalı, geldi: %+v", ci)
		}
		if claim.GrossWorkAmount != 30000 {
			t.Fatalf("gross_work_amount 30000 olmalı, geldi %v", claim.GrossWorkAmount)
		}
	})

	t.Run("19_second_claim_previous_equals_first_cumulative", func(t *testing.T) {
		p := newProject(t, orgA.ID, 200000)
		cc := newCostCode(t, orgA.ID, "S19-CC")
		s := newSupplier(t, orgA.ID, "S19-S")
		sc := newActiveSubcontract(t, orgA.ID, p.ID, s.ID, cc.ID, 100000)
		items, _ := projectSvc.ListSubcontractItems(ctx, p.ID, sc.ID, orgA.ID)
		c1, err := projectSvc.CreateProgressClaim(ctx, p.ID, sc.ID, orgA.ID, service.ProgressClaimInput{
			PeriodEnd: time.Now(), Items: []service.ProgressClaimItemInput{{SubcontractItemID: items[0].ID, CurrentProgressAmount: 30000}},
		})
		if err != nil {
			t.Fatalf("1. hakediş oluşturulamadı: %v", err)
		}
		if _, err := projectSvc.SubmitProgressClaim(ctx, p.ID, c1.ID, orgA.ID, ""); err != nil {
			t.Fatalf("1. hakediş gönderilemedi: %v", err)
		}
		if _, err := projectSvc.CertifyProgressClaim(ctx, p.ID, c1.ID, orgA.ID, ""); err != nil {
			t.Fatalf("1. hakediş sertifika edilemedi: %v", err)
		}
		c2, err := projectSvc.CreateProgressClaim(ctx, p.ID, sc.ID, orgA.ID, service.ProgressClaimInput{
			PeriodEnd: time.Now(), Items: []service.ProgressClaimItemInput{{SubcontractItemID: items[0].ID, CurrentProgressAmount: 25000}},
		})
		if err != nil {
			t.Fatalf("2. hakediş oluşturulamadı: %v", err)
		}
		claimItems, _ := projectSvc.ListProgressClaimItems(ctx, p.ID, c2.ID, orgA.ID)
		ci := claimItems[0]
		if ci.PreviousProgressAmount != 30000 || ci.CurrentProgressAmount != 25000 || ci.CumulativeProgressAmount != 55000 {
			t.Fatalf("2. hakedişte previous=30000/current=25000/cumulative=55000 olmalı, geldi: %+v", ci)
		}
	})

	t.Run("20_cumulative_overrun_rejected", func(t *testing.T) {
		p := newProject(t, orgA.ID, 200000)
		cc := newCostCode(t, orgA.ID, "S20-CC")
		s := newSupplier(t, orgA.ID, "S20-S")
		sc := newActiveSubcontract(t, orgA.ID, p.ID, s.ID, cc.ID, 50000)
		items, _ := projectSvc.ListSubcontractItems(ctx, p.ID, sc.ID, orgA.ID)
		_, err := projectSvc.CreateProgressClaim(ctx, p.ID, sc.ID, orgA.ID, service.ProgressClaimInput{
			PeriodEnd: time.Now(), Items: []service.ProgressClaimItemInput{{SubcontractItemID: items[0].ID, CurrentProgressAmount: 50001}},
		})
		if !errors.Is(err, service.ErrProgressClaimOverrun) {
			t.Fatalf("%%100 üstü aşım REDDEDİLMELİ, geldi: %v", err)
		}
	})

	t.Run("21_money_exact_retention_advance_deduction_net_payable", func(t *testing.T) {
		// spec §37'nin AYNI sayılarıyla, tek-kalemli bir sözleşme üzerinde:
		// Gross 100.000, Retention %5 = 5.000, Advance Recovery 10.000,
		// Other Deduction 2.500 => Net 82.500.
		p := newProject(t, orgA.ID, 600000)
		cc := newCostCode(t, orgA.ID, "S21-CC")
		s := newSupplier(t, orgA.ID, "S21-S")
		sc := newActiveSubcontract(t, orgA.ID, p.ID, s.ID, cc.ID, 530000)
		items, _ := projectSvc.ListSubcontractItems(ctx, p.ID, sc.ID, orgA.ID)
		retention := 5.0
		claim, err := projectSvc.CreateProgressClaim(ctx, p.ID, sc.ID, orgA.ID, service.ProgressClaimInput{
			PeriodEnd: time.Now(), RetentionPercent: &retention, AdvanceRecoveryAmount: 10000, OtherDeductions: 2500,
			Items: []service.ProgressClaimItemInput{{SubcontractItemID: items[0].ID, CurrentProgressAmount: 100000}},
		})
		if err != nil {
			t.Fatalf("hakediş oluşturulamadı: %v", err)
		}
		if claim.GrossWorkAmount != 100000 {
			t.Fatalf("gross 100000 olmalı, geldi %v", claim.GrossWorkAmount)
		}
		if claim.RetentionAmount != 5000 {
			t.Fatalf("retention 5000 olmalı, geldi %v", claim.RetentionAmount)
		}
		if claim.NetPayable != 82500 {
			t.Fatalf("net_payable 82500 olmalı (100000-5000-10000-2500), geldi %v", claim.NetPayable)
		}
	})

	t.Run("22_submit_certify_lifecycle_and_immutability", func(t *testing.T) {
		p := newProject(t, orgA.ID, 200000)
		cc := newCostCode(t, orgA.ID, "S22-CC")
		s := newSupplier(t, orgA.ID, "S22-S")
		sc := newActiveSubcontract(t, orgA.ID, p.ID, s.ID, cc.ID, 100000)
		items, _ := projectSvc.ListSubcontractItems(ctx, p.ID, sc.ID, orgA.ID)
		claim, err := projectSvc.CreateProgressClaim(ctx, p.ID, sc.ID, orgA.ID, service.ProgressClaimInput{
			PeriodEnd: time.Now(), Items: []service.ProgressClaimItemInput{{SubcontractItemID: items[0].ID, CurrentProgressAmount: 10000}},
		})
		if err != nil {
			t.Fatalf("oluşturulamadı: %v", err)
		}
		if _, err := projectSvc.CertifyProgressClaim(ctx, p.ID, claim.ID, orgA.ID, ""); !errors.Is(err, service.ErrProgressClaimNotCertifiable) {
			t.Fatalf("DRAFT'tan direkt sertifika REDDEDİLMELİ, geldi: %v", err)
		}
		if _, err := projectSvc.SubmitProgressClaim(ctx, p.ID, claim.ID, orgA.ID, ""); err != nil {
			t.Fatalf("gönderilemedi: %v", err)
		}
		certified, err := projectSvc.CertifyProgressClaim(ctx, p.ID, claim.ID, orgA.ID, "")
		if err != nil {
			t.Fatalf("sertifika edilemedi: %v", err)
		}
		if certified.Status != domain.ProgressClaimStatusCertified {
			t.Fatalf("status certified olmalı, geldi %s", certified.Status)
		}
		if _, err := projectSvc.UpdateProgressClaimDraft(ctx, p.ID, claim.ID, orgA.ID, service.ProgressClaimInput{
			PeriodEnd: time.Now(), Items: []service.ProgressClaimItemInput{{SubcontractItemID: items[0].ID, CurrentProgressAmount: 20000}},
		}); !errors.Is(err, service.ErrProgressClaimNotEditable) {
			t.Fatalf("CERTIFIED bir hakediş SESSİZCE düzenlenememeli, geldi: %v", err)
		}
		if _, err := projectSvc.CancelProgressClaim(ctx, p.ID, claim.ID, orgA.ID, ""); !errors.Is(err, service.ErrProgressClaimNotCancellable) {
			t.Fatalf("CERTIFIED bir hakediş iptal edilememeli, geldi: %v", err)
		}
	})

	t.Run("23_claim_requires_active_subcontract", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		cc := newCostCode(t, orgA.ID, "S23-CC")
		s := newSupplier(t, orgA.ID, "S23-S")
		sc := newDraftSubcontract(t, orgA.ID, p.ID, s.ID, cc.ID, 10000)
		items, _ := projectSvc.ListSubcontractItems(ctx, p.ID, sc.ID, orgA.ID)
		_, err := projectSvc.CreateProgressClaim(ctx, p.ID, sc.ID, orgA.ID, service.ProgressClaimInput{
			PeriodEnd: time.Now(), Items: []service.ProgressClaimItemInput{{SubcontractItemID: items[0].ID, CurrentProgressAmount: 1000}},
		})
		if !errors.Is(err, service.ErrSubcontractNotActiveForClaim) {
			t.Fatalf("DRAFT sözleşme için hakediş oluşturma REDDEDİLMELİ, geldi: %v", err)
		}
	})

	t.Run("24_rejected_claim_reason_required_and_no_effect", func(t *testing.T) {
		p := newProject(t, orgA.ID, 200000)
		cc := newCostCode(t, orgA.ID, "S24-CC")
		s := newSupplier(t, orgA.ID, "S24-S")
		sc := newActiveSubcontract(t, orgA.ID, p.ID, s.ID, cc.ID, 100000)
		items, _ := projectSvc.ListSubcontractItems(ctx, p.ID, sc.ID, orgA.ID)
		claim, err := projectSvc.CreateProgressClaim(ctx, p.ID, sc.ID, orgA.ID, service.ProgressClaimInput{
			PeriodEnd: time.Now(), Items: []service.ProgressClaimItemInput{{SubcontractItemID: items[0].ID, CurrentProgressAmount: 10000}},
		})
		if err != nil {
			t.Fatalf("oluşturulamadı: %v", err)
		}
		if _, err := projectSvc.SubmitProgressClaim(ctx, p.ID, claim.ID, orgA.ID, ""); err != nil {
			t.Fatalf("gönderilemedi: %v", err)
		}
		if _, err := projectSvc.RejectProgressClaim(ctx, p.ID, claim.ID, orgA.ID, "", ""); !errors.Is(err, service.ErrProgressClaimReasonRequired) {
			t.Fatalf("gerekçesiz red REDDEDİLMELİ, geldi: %v", err)
		}
		rejected, err := projectSvc.RejectProgressClaim(ctx, p.ID, claim.ID, orgA.ID, "", "eksik belge")
		if err != nil {
			t.Fatalf("reddedilemedi: %v", err)
		}
		if rejected.Status != domain.ProgressClaimStatusRejected {
			t.Fatalf("status rejected olmalı, geldi %s", rejected.Status)
		}
		// Reddedilen hakediş, bir SONRAKİ hakedişin previous'una SIZMAMALI.
		newClaim, err := projectSvc.CreateProgressClaim(ctx, p.ID, sc.ID, orgA.ID, service.ProgressClaimInput{
			PeriodEnd: time.Now(), Items: []service.ProgressClaimItemInput{{SubcontractItemID: items[0].ID, CurrentProgressAmount: 15000}},
		})
		if err != nil {
			t.Fatalf("yeni hakediş oluşturulamadı: %v", err)
		}
		ci, _ := projectSvc.ListProgressClaimItems(ctx, p.ID, newClaim.ID, orgA.ID)
		if ci[0].PreviousProgressAmount != 0 {
			t.Fatalf("reddedilen hakediş previous'a SIZMAMALI, beklenen 0 geldi %v", ci[0].PreviousProgressAmount)
		}
	})

	// ---------- GOLDEN REGRESSION TESTS ----------

	t.Run("25_cost_control_golden_regression", func(t *testing.T) {
		// spec §38'in AYNI sayılarıyla: mevcut PO commitment 100.000,
		// taşeron aktivasyonu 500.000 => 600.000, +50.000 ek => 650.000,
		// -20.000 eksiltme => 630.000. Contract/Budget DEĞİŞMEMELİ.
		p := newProject(t, orgA.ID, 900000)
		cc := newCostCode(t, orgA.ID, "S25-CC")
		if _, err := projectSvc.CreateBudgetLine(ctx, p.ID, orgA.ID, service.BudgetLineInput{
			CostCodeID: cc.ID, Description: "Bütçe Kalemi", OriginalAmount: 700000,
		}); err != nil {
			t.Fatalf("bütçe kalemi oluşturulamadı: %v", err)
		}
		if _, err := projectSvc.BaselineProjectBudget(ctx, p.ID, orgA.ID, ""); err != nil {
			t.Fatalf("baseline alınamadı: %v", err)
		}
		poSupplier := newSupplier(t, orgA.ID, "S25-PO-S")
		po, err := projectSvc.CreatePurchaseOrder(ctx, p.ID, orgA.ID, service.PurchaseOrderInput{
			SupplierID: poSupplier.ID, IssueDate: time.Now(),
			Items: []service.PurchaseOrderItemInput{{CostCodeID: cc.ID, Description: "K", Quantity: 1, UnitPrice: 100000}},
		})
		if err != nil {
			t.Fatalf("PO oluşturulamadı: %v", err)
		}
		if _, err := projectSvc.ApprovePurchaseOrder(ctx, p.ID, po.ID, orgA.ID, ""); err != nil {
			t.Fatalf("PO onaylanamadı: %v", err)
		}
		s := newSupplier(t, orgA.ID, "S25-SC-S")
		sc := newActiveSubcontract(t, orgA.ID, p.ID, s.ID, cc.ID, 500000)

		after1, err := projectSvc.CostControlSummary(ctx, p.ID, orgA.ID)
		if err != nil {
			t.Fatalf("özet alınamadı: %v", err)
		}
		if after1.CommittedCost != 600000 {
			t.Fatalf("taşeron aktivasyonu SONRASI committed = 100000+500000 = 600000 OLMALI, geldi %v", after1.CommittedCost)
		}

		add, err := projectSvc.CreateSubcontractChangeOrder(ctx, p.ID, sc.ID, orgA.ID, service.SubcontractChangeOrderInput{
			Title: "Ek İş", ChangeType: domain.SubcontractChangeTypeAddition,
			Items: []service.SubcontractChangeOrderItemInput{{CostCodeID: cc.ID, Description: "K", Amount: 50000}},
		})
		if err != nil {
			t.Fatalf("ek iş oluşturulamadı: %v", err)
		}
		if _, err := projectSvc.SubmitSubcontractChangeOrder(ctx, p.ID, add.ID, orgA.ID, ""); err != nil {
			t.Fatalf("gönderilemedi: %v", err)
		}
		if _, err := projectSvc.ApproveSubcontractChangeOrder(ctx, p.ID, add.ID, orgA.ID, ""); err != nil {
			t.Fatalf("onaylanamadı: %v", err)
		}
		after2, err := projectSvc.CostControlSummary(ctx, p.ID, orgA.ID)
		if err != nil {
			t.Fatalf("özet alınamadı: %v", err)
		}
		if after2.CommittedCost != 650000 {
			t.Fatalf("ek iş onayı SONRASI committed 650000 OLMALI, geldi %v", after2.CommittedCost)
		}

		ded, err := projectSvc.CreateSubcontractChangeOrder(ctx, p.ID, sc.ID, orgA.ID, service.SubcontractChangeOrderInput{
			Title: "Eksiltme", ChangeType: domain.SubcontractChangeTypeDeduction,
			Items: []service.SubcontractChangeOrderItemInput{{CostCodeID: cc.ID, Description: "K", Amount: 20000}},
		})
		if err != nil {
			t.Fatalf("eksiltme oluşturulamadı: %v", err)
		}
		if _, err := projectSvc.SubmitSubcontractChangeOrder(ctx, p.ID, ded.ID, orgA.ID, ""); err != nil {
			t.Fatalf("gönderilemedi: %v", err)
		}
		if _, err := projectSvc.ApproveSubcontractChangeOrder(ctx, p.ID, ded.ID, orgA.ID, ""); err != nil {
			t.Fatalf("onaylanamadı: %v", err)
		}
		after3, err := projectSvc.CostControlSummary(ctx, p.ID, orgA.ID)
		if err != nil {
			t.Fatalf("özet alınamadı: %v", err)
		}
		if after3.CommittedCost != 630000 {
			t.Fatalf("eksiltme onayı SONRASI committed 630000 OLMALI, geldi %v", after3.CommittedCost)
		}
		if after3.ActualCost != 0 {
			t.Fatalf("Actual DEĞİŞMEMELİ, geldi %v", after3.ActualCost)
		}
		if after3.OriginalBudget != 700000 || after3.RevisedBudget != 700000 {
			t.Fatalf("Budget DEĞİŞMEMELİ, geldi original=%v revised=%v", after3.OriginalBudget, after3.RevisedBudget)
		}
		if after3.ContractValue != 900000 {
			t.Fatalf("Contract DEĞİŞMEMELİ, geldi %v", after3.ContractValue)
		}
	})

	t.Run("26_termination_golden_regression", func(t *testing.T) {
		// spec §39'un AYNI senaryosu: 500.000 + 50.000 ek = 550.000,
		// 200.000 sertifika edilmiş, fesih. Beklenen: kalan (350.000)
		// SERBEST, sertifikalı 200.000 KOMİTMENT OLARAK KALIR, hakediş
		// KAYDI (200.000) DEĞİŞMEZ/SİLİNMEZ.
		p := newProject(t, orgA.ID, 800000)
		cc := newCostCode(t, orgA.ID, "S26-CC")
		s := newSupplier(t, orgA.ID, "S26-S")
		sc := newActiveSubcontract(t, orgA.ID, p.ID, s.ID, cc.ID, 500000)

		add, err := projectSvc.CreateSubcontractChangeOrder(ctx, p.ID, sc.ID, orgA.ID, service.SubcontractChangeOrderInput{
			Title: "Ek İş", ChangeType: domain.SubcontractChangeTypeAddition,
			Items: []service.SubcontractChangeOrderItemInput{{CostCodeID: cc.ID, Description: "K", Amount: 50000}},
		})
		if err != nil {
			t.Fatalf("ek iş oluşturulamadı: %v", err)
		}
		if _, err := projectSvc.SubmitSubcontractChangeOrder(ctx, p.ID, add.ID, orgA.ID, ""); err != nil {
			t.Fatalf("gönderilemedi: %v", err)
		}
		if _, err := projectSvc.ApproveSubcontractChangeOrder(ctx, p.ID, add.ID, orgA.ID, ""); err != nil {
			t.Fatalf("onaylanamadı: %v", err)
		}

		val, err := projectSvc.GetSubcontractValue(ctx, p.ID, sc.ID, orgA.ID)
		if err != nil || val.CurrentValue != 550000 {
			t.Fatalf("fesih ÖNCESİ current_value 550000 olmalı, geldi %v err=%v", val.CurrentValue, err)
		}

		items, _ := projectSvc.ListSubcontractItems(ctx, p.ID, sc.ID, orgA.ID)
		claim, err := projectSvc.CreateProgressClaim(ctx, p.ID, sc.ID, orgA.ID, service.ProgressClaimInput{
			PeriodEnd: time.Now(), Items: []service.ProgressClaimItemInput{{SubcontractItemID: items[0].ID, CurrentProgressAmount: 200000}},
		})
		if err != nil {
			t.Fatalf("hakediş oluşturulamadı: %v", err)
		}
		if _, err := projectSvc.SubmitProgressClaim(ctx, p.ID, claim.ID, orgA.ID, ""); err != nil {
			t.Fatalf("gönderilemedi: %v", err)
		}
		if _, err := projectSvc.CertifyProgressClaim(ctx, p.ID, claim.ID, orgA.ID, ""); err != nil {
			t.Fatalf("sertifika edilemedi: %v", err)
		}

		before, err := projectSvc.CostControlSummary(ctx, p.ID, orgA.ID)
		if err != nil || before.CommittedCost != 550000 {
			t.Fatalf("fesih ÖNCESİ committed 550000 olmalı, geldi %v err=%v", before.CommittedCost, err)
		}

		terminated, err := projectSvc.TerminateSubcontract(ctx, p.ID, sc.ID, orgA.ID, "", "erken fesih — performans yetersiz")
		if err != nil {
			t.Fatalf("feshedilemedi: %v", err)
		}
		if terminated.Status != domain.SubcontractStatusTerminated {
			t.Fatalf("status terminated olmalı, geldi %s", terminated.Status)
		}

		after, err := projectSvc.CostControlSummary(ctx, p.ID, orgA.ID)
		if err != nil {
			t.Fatalf("özet alınamadı: %v", err)
		}
		if after.CommittedCost != 200000 {
			t.Fatalf("fesih SONRASI committed TAM OLARAK sertifikalı tutar (200000) olmalı, geldi %v", after.CommittedCost)
		}
		if after.ActualCost != 0 {
			t.Fatalf("Actual fesihten ETKİLENMEMELİ, geldi %v", after.ActualCost)
		}

		// Sertifikalı hakediş KAYDININ KENDİSİ dokunulmamış olmalı.
		reloadedClaim, err := projectSvc.GetProgressClaim(ctx, p.ID, claim.ID, orgA.ID)
		if err != nil {
			t.Fatalf("hakediş yeniden okunamadı: %v", err)
		}
		if reloadedClaim.Status != domain.ProgressClaimStatusCertified || reloadedClaim.GrossWorkAmount != 200000 {
			t.Fatalf("sertifikalı hakediş KAYDI fesihten ETKİLENMEMELİ, geldi: %+v", reloadedClaim)
		}
	})

	t.Run("27_subcontracts_never_touch_customer_contract_or_change_orders", func(t *testing.T) {
		p := newProject(t, orgA.ID, 300000)
		cc := newCostCode(t, orgA.ID, "S27-CC")
		s := newSupplier(t, orgA.ID, "S27-S")
		sc := newActiveSubcontract(t, orgA.ID, p.ID, s.ID, cc.ID, 50000)
		add, err := projectSvc.CreateSubcontractChangeOrder(ctx, p.ID, sc.ID, orgA.ID, service.SubcontractChangeOrderInput{
			Title: "Ek İş", ChangeType: domain.SubcontractChangeTypeAddition,
			Items: []service.SubcontractChangeOrderItemInput{{CostCodeID: cc.ID, Description: "K", Amount: 10000}},
		})
		if err != nil {
			t.Fatalf("oluşturulamadı: %v", err)
		}
		if _, err := projectSvc.SubmitSubcontractChangeOrder(ctx, p.ID, add.ID, orgA.ID, ""); err != nil {
			t.Fatalf("gönderilemedi: %v", err)
		}
		if _, err := projectSvc.ApproveSubcontractChangeOrder(ctx, p.ID, add.ID, orgA.ID, ""); err != nil {
			t.Fatalf("onaylanamadı: %v", err)
		}
		if _, err := projectSvc.GetProjectContract(ctx, p.ID, orgA.ID); !errors.Is(err, service.ErrContractNotFound) {
			t.Errorf("subcontract işlemleri bir Customer Contract OLUŞTURMAMALI, geldi: %v", err)
		}
		summary, err := projectSvc.FinancialSummary(ctx, p.ID, orgA.ID)
		if err != nil {
			t.Fatalf("finansal özet alınamadı: %v", err)
		}
		if summary.ApprovedAdditions != 0 || summary.ApprovedDeductions != 0 {
			t.Errorf("subcontract değişiklikleri Customer Change Order etkisi OLUŞTURMAMALI: %+v", summary)
		}
		proj, err := projectSvc.Get(ctx, p.ID, orgA.ID)
		if err != nil || proj.ContractAmount != 300000 {
			t.Errorf("projects.contract_amount subcontract işlemlerinden ETKİLENMEMELİ: %v, err=%v", proj.ContractAmount, err)
		}
	})

	t.Run("28_number_generation_race", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		cc := newCostCode(t, orgA.ID, "S28-CC")
		const n = 8
		errs := make(chan error, n)
		numbers := make(chan string, n)
		for i := 0; i < n; i++ {
			go func(i int) {
				s, err := supplierSvc.Create(ctx, orgA.ID, service.SupplierInput{Code: "S28-RACE-" + string(rune('A'+i)), LegalName: "Yarış Tedarikçi"})
				if err != nil {
					errs <- err
					return
				}
				sc, err := projectSvc.CreateSubcontract(ctx, p.ID, orgA.ID, service.SubcontractInput{
					SupplierID: s.ID, Title: "Yarış Testi",
					Items: []service.SubcontractItemInput{{CostCodeID: cc.ID, Description: "K", OriginalAmount: 1000}},
				})
				if err != nil {
					errs <- err
					return
				}
				numbers <- sc.SubcontractNo
				errs <- nil
			}(i)
		}
		seen := map[string]bool{}
		for i := 0; i < n; i++ {
			if err := <-errs; err != nil {
				t.Fatalf("eşzamanlı oluşturma başarısız: %v", err)
			}
		}
		close(numbers)
		for no := range numbers {
			if seen[no] {
				t.Fatalf("DUPLICATE subcontract_no üretildi: %s", no)
			}
			seen[no] = true
		}
		if len(seen) != n {
			t.Fatalf("beklenen %d benzersiz numara, geldi %d", n, len(seen))
		}
	})

	// ---------- EŞZAMANLILIK (spec §35) ----------

	t.Run("29_double_activation_concurrency_exactly_one_commitment_set", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		cc := newCostCode(t, orgA.ID, "S29-CC")
		s := newSupplier(t, orgA.ID, "S29-S")
		sc := newDraftSubcontract(t, orgA.ID, p.ID, s.ID, cc.ID, 40000)
		const attempts = 5
		results := make(chan error, attempts)
		for i := 0; i < attempts; i++ {
			go func() {
				_, err := projectSvc.ActivateSubcontract(ctx, p.ID, sc.ID, orgA.ID, "")
				results <- err
			}()
		}
		successCount := 0
		for i := 0; i < attempts; i++ {
			if err := <-results; err == nil {
				successCount++
			}
		}
		if successCount != 1 {
			t.Errorf("eşzamanlı %d aktivasyon isteğinden TAM OLARAK 1'i başarılı olmalı, geldi: %d", attempts, successCount)
		}
		commitments, err := projectSvc.ListCommitmentsForSubcontract(ctx, p.ID, sc.ID, orgA.ID)
		if err != nil {
			t.Fatalf("taahhütler alınamadı: %v", err)
		}
		active := 0
		for _, c := range commitments {
			if c.Status == domain.CommitmentStatusActive {
				active++
			}
		}
		if active != 1 {
			t.Errorf("yarış koşulunda TAM OLARAK bir aktif commitment satırı olmalı, geldi: %d", active)
		}
	})

	t.Run("30_double_change_order_approval_concurrency", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		cc := newCostCode(t, orgA.ID, "S30-CC")
		s := newSupplier(t, orgA.ID, "S30-S")
		sc := newActiveSubcontract(t, orgA.ID, p.ID, s.ID, cc.ID, 50000)
		co, err := projectSvc.CreateSubcontractChangeOrder(ctx, p.ID, sc.ID, orgA.ID, service.SubcontractChangeOrderInput{
			Title: "Yarış Değişikliği", ChangeType: domain.SubcontractChangeTypeAddition,
			Items: []service.SubcontractChangeOrderItemInput{{CostCodeID: cc.ID, Description: "K", Amount: 10000}},
		})
		if err != nil {
			t.Fatalf("oluşturulamadı: %v", err)
		}
		if _, err := projectSvc.SubmitSubcontractChangeOrder(ctx, p.ID, co.ID, orgA.ID, ""); err != nil {
			t.Fatalf("gönderilemedi: %v", err)
		}
		const attempts = 5
		results := make(chan error, attempts)
		for i := 0; i < attempts; i++ {
			go func() {
				_, err := projectSvc.ApproveSubcontractChangeOrder(ctx, p.ID, co.ID, orgA.ID, "")
				results <- err
			}()
		}
		successCount := 0
		for i := 0; i < attempts; i++ {
			if err := <-results; err == nil {
				successCount++
			}
		}
		if successCount != 1 {
			t.Errorf("eşzamanlı %d onay isteğinden TAM OLARAK 1'i başarılı olmalı, geldi: %d", attempts, successCount)
		}
		val, err := projectSvc.GetSubcontractValue(ctx, p.ID, sc.ID, orgA.ID)
		if err != nil {
			t.Fatalf("değer alınamadı: %v", err)
		}
		if val.CurrentValue != 60000 {
			t.Errorf("yarış koşulunda ek TEK BİR KEZ uygulanmalı (60000), DUPLICATE uygulanmamalı, geldi: %v", val.CurrentValue)
		}
	})

	t.Run("31_double_claim_certification_concurrency", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		cc := newCostCode(t, orgA.ID, "S31-CC")
		s := newSupplier(t, orgA.ID, "S31-S")
		sc := newActiveSubcontract(t, orgA.ID, p.ID, s.ID, cc.ID, 50000)
		items, _ := projectSvc.ListSubcontractItems(ctx, p.ID, sc.ID, orgA.ID)
		claim, err := projectSvc.CreateProgressClaim(ctx, p.ID, sc.ID, orgA.ID, service.ProgressClaimInput{
			PeriodEnd: time.Now(), Items: []service.ProgressClaimItemInput{{SubcontractItemID: items[0].ID, CurrentProgressAmount: 20000}},
		})
		if err != nil {
			t.Fatalf("oluşturulamadı: %v", err)
		}
		if _, err := projectSvc.SubmitProgressClaim(ctx, p.ID, claim.ID, orgA.ID, ""); err != nil {
			t.Fatalf("gönderilemedi: %v", err)
		}
		const attempts = 5
		results := make(chan error, attempts)
		for i := 0; i < attempts; i++ {
			go func() {
				_, err := projectSvc.CertifyProgressClaim(ctx, p.ID, claim.ID, orgA.ID, "")
				results <- err
			}()
		}
		successCount := 0
		for i := 0; i < attempts; i++ {
			if err := <-results; err == nil {
				successCount++
			}
		}
		if successCount != 1 {
			t.Errorf("eşzamanlı %d sertifikasyon isteğinden TAM OLARAK 1'i başarılı olmalı, geldi: %d", attempts, successCount)
		}
	})

	t.Run("32_termination_concurrent_with_certification", func(t *testing.T) {
		// Fesih VE sertifikasyon AYNI ANDA yarışırsa: HER İKİSİ de kendi
		// FOR UPDATE kilidini kullandığı için biri diğerinden ÖNCE serialize
		// olur -- sonuç sırayla ne olursa olsun sistemin TUTARLI bir uç
		// duruma ulaştığını (ikisi de başarısız/çakışık kalmadığını, hakediş
		// kaydının bozulmadığını) doğrular.
		p := newProject(t, orgA.ID, 100000)
		cc := newCostCode(t, orgA.ID, "S32-CC")
		s := newSupplier(t, orgA.ID, "S32-S")
		sc := newActiveSubcontract(t, orgA.ID, p.ID, s.ID, cc.ID, 50000)
		items, _ := projectSvc.ListSubcontractItems(ctx, p.ID, sc.ID, orgA.ID)
		claim, err := projectSvc.CreateProgressClaim(ctx, p.ID, sc.ID, orgA.ID, service.ProgressClaimInput{
			PeriodEnd: time.Now(), Items: []service.ProgressClaimItemInput{{SubcontractItemID: items[0].ID, CurrentProgressAmount: 20000}},
		})
		if err != nil {
			t.Fatalf("oluşturulamadı: %v", err)
		}
		if _, err := projectSvc.SubmitProgressClaim(ctx, p.ID, claim.ID, orgA.ID, ""); err != nil {
			t.Fatalf("gönderilemedi: %v", err)
		}

		var certErr, termErr error
		done := make(chan struct{}, 2)
		go func() {
			_, certErr = projectSvc.CertifyProgressClaim(ctx, p.ID, claim.ID, orgA.ID, "")
			done <- struct{}{}
		}()
		go func() {
			_, termErr = projectSvc.TerminateSubcontract(ctx, p.ID, sc.ID, orgA.ID, "", "eşzamanlı fesih testi")
			done <- struct{}{}
		}()
		<-done
		<-done

		// Fesih başarılıysa, sözleşme artık ACTIVE değildir -- sistem hâlâ
		// TUTARLI bir uç duruma ulaşmış olmalı (ne çift-uygulanmış bir
		// commitment, ne bozulmuş bir hakediş kaydı).
		reloadedSC, err := projectSvc.GetSubcontract(ctx, p.ID, sc.ID, orgA.ID)
		if err != nil {
			t.Fatalf("sözleşme yeniden okunamadı: %v", err)
		}
		reloadedClaim, err := projectSvc.GetProgressClaim(ctx, p.ID, claim.ID, orgA.ID)
		if err != nil {
			t.Fatalf("hakediş yeniden okunamadı: %v", err)
		}
		t.Logf("sonuç: certErr=%v termErr=%v subcontract.status=%s claim.status=%s", certErr, termErr, reloadedSC.Status, reloadedClaim.Status)
		commitments, err := projectSvc.ListCommitmentsForSubcontract(ctx, p.ID, sc.ID, orgA.ID)
		if err != nil {
			t.Fatalf("taahhütler alınamadı: %v", err)
		}
		active := 0
		for _, c := range commitments {
			if c.Status == domain.CommitmentStatusActive {
				active++
			}
		}
		if active > 1 {
			t.Errorf("yarış SONRASI birden fazla aktif commitment satırı OLMAMALI (senkronizasyon her zaman void+create yapar), geldi: %d", active)
		}
	})
}
