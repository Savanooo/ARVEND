package service_test

// ARVEND V2 -- Sprint 4 (Procurement Foundation) için otomatik testler --
// gerçek bir PostgreSQL bağlantısı gerektirir (bkz. tenant_isolation_
// test.go'daki paylaşılan yardımcılar). Suppliers + Purchase Request +
// RFQ + Supplier Quotation + Bid Comparison + Award + Purchase Order +
// Cost Control entegrasyonu senaryolarını kapsar.

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

func TestProcurement(t *testing.T) {
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

	orgA := mustCreateOrg(t, ctx, orgSvc, pool, "Satınalma Test Firma A", "satinalma-test-firma-a")
	orgB := mustCreateOrg(t, ctx, orgSvc, pool, "Satınalma Test Firma B", "satinalma-test-firma-b")

	newProject := func(t *testing.T, orgID string, contractAmount float64) *domain.Project {
		t.Helper()
		o, err := offerSvc.Create(ctx, service.CreateOfferInput{
			OrganizationID: orgID, CustomerName: "Satınalma Test Müşteri", VatRate: ptrFloat(0),
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
		p, err := projectSvc.CreateFromOffer(ctx, o.ID, orgID, service.CreateProjectInput{Name: "Satınalma Test Projesi"})
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

	newSupplier := func(t *testing.T, orgID, code string) *domain.Supplier {
		t.Helper()
		s, err := supplierSvc.Create(ctx, orgID, service.SupplierInput{Code: code, LegalName: "Tedarikçi " + code})
		if err != nil {
			t.Fatalf("tedarikçi oluşturulamadı: %v", err)
		}
		return s
	}

	// newApprovedPR, tek kalemli, ONAYLI bir Purchase Request döner --
	// RFQ oluşturma testlerinin ortak kurulumu.
	newApprovedPR := func(t *testing.T, orgID, projectID, costCodeID string) *domain.PurchaseRequest {
		t.Helper()
		pr, err := projectSvc.CreatePurchaseRequest(ctx, projectID, orgID, service.PurchaseRequestInput{
			Title: "Test Talebi",
			Items: []service.PurchaseRequestItemInput{
				{CostCodeID: costCodeID, Description: "Çimento", Quantity: 100, Unit: "torba", EstimatedUnitCost: ptrFloat(50)},
			},
		})
		if err != nil {
			t.Fatalf("PR oluşturulamadı: %v", err)
		}
		if _, err := projectSvc.SubmitPurchaseRequest(ctx, projectID, pr.ID, orgID, ""); err != nil {
			t.Fatalf("PR gönderilemedi: %v", err)
		}
		approved, err := projectSvc.ApprovePurchaseRequest(ctx, projectID, pr.ID, orgID, "")
		if err != nil {
			t.Fatalf("PR onaylanamadı: %v", err)
		}
		return approved
	}

	// newIssuedRFQ, PR'dan snapshot alınmış, İKİ tedarikçiye açılmış
	// (issued) bir RFQ döner -- Quotation/Comparison/Award testlerinin
	// ortak kurulumu.
	newIssuedRFQ := func(t *testing.T, orgID, projectID string, pr *domain.PurchaseRequest, supplierIDs []string) *domain.RFQ {
		t.Helper()
		rfq, err := projectSvc.CreateRFQ(ctx, projectID, orgID, service.RFQInput{
			Title: "Test RFQ", PurchaseRequestID: pr.ID, IssueDate: time.Now(), SupplierIDs: supplierIDs,
		})
		if err != nil {
			t.Fatalf("RFQ oluşturulamadı: %v", err)
		}
		issued, err := projectSvc.IssueRFQ(ctx, projectID, rfq.ID, orgID, "")
		if err != nil {
			t.Fatalf("RFQ gönderilemedi: %v", err)
		}
		return issued
	}

	// ---------- Tedarikçiler ----------

	t.Run("1_supplier_create", func(t *testing.T) {
		s := newSupplier(t, orgA.ID, "TED-001")
		if s.Code != "TED-001" || !s.IsActive {
			t.Errorf("beklenmedik tedarikçi: %+v", s)
		}
	})

	t.Run("2_supplier_duplicate_code_rejected", func(t *testing.T) {
		newSupplier(t, orgA.ID, "TED-DUP")
		_, err := supplierSvc.Create(ctx, orgA.ID, service.SupplierInput{Code: "TED-DUP", LegalName: "İkinci"})
		if !errors.Is(err, service.ErrDuplicateSupplierCode) {
			t.Errorf("beklenen ErrDuplicateSupplierCode, geldi: %v", err)
		}
	})

	t.Run("3_supplier_cross_tenant_get_denied", func(t *testing.T) {
		s := newSupplier(t, orgA.ID, "TED-XT")
		if _, err := supplierSvc.Get(ctx, s.ID, orgB.ID); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("beklenen ErrNotFound (çapraz kiracı), geldi: %v", err)
		}
	})

	t.Run("4_supplier_archive_and_reactivate", func(t *testing.T) {
		s := newSupplier(t, orgA.ID, "TED-ARC")
		if err := supplierSvc.Archive(ctx, s.ID, orgA.ID, ""); err != nil {
			t.Fatalf("arşivlenemedi: %v", err)
		}
		got, err := supplierSvc.Get(ctx, s.ID, orgA.ID)
		if err != nil || got.IsActive {
			t.Errorf("arşivlenmiş olmalı: %+v, err=%v", got, err)
		}
		if err := supplierSvc.Reactivate(ctx, s.ID, orgA.ID, ""); err != nil {
			t.Fatalf("yeniden aktive edilemedi: %v", err)
		}
		got, _ = supplierSvc.Get(ctx, s.ID, orgA.ID)
		if !got.IsActive {
			t.Errorf("yeniden aktif olmalı: %+v", got)
		}
	})

	// ---------- Purchase Request ----------

	t.Run("5_pr_create_with_items_computes_estimated_total", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		cc := newCostCode(t, orgA.ID, "PR-CC-1")
		pr, err := projectSvc.CreatePurchaseRequest(ctx, p.ID, orgA.ID, service.PurchaseRequestInput{
			Title: "Malzeme Talebi",
			Items: []service.PurchaseRequestItemInput{
				{CostCodeID: cc.ID, Description: "Demir", Quantity: 10, Unit: "ton", EstimatedUnitCost: ptrFloat(15000)},
			},
		})
		if err != nil {
			t.Fatalf("PR oluşturulamadı: %v", err)
		}
		if pr.EstimatedTotal != 150000 {
			t.Errorf("beklenen 150000 (10x15000), geldi: %v", pr.EstimatedTotal)
		}
	})

	t.Run("6_pr_submit_requires_items", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		pr, err := projectSvc.CreatePurchaseRequest(ctx, p.ID, orgA.ID, service.PurchaseRequestInput{Title: "Boş Talep"})
		if err != nil {
			t.Fatalf("PR oluşturulamadı: %v", err)
		}
		_, err = projectSvc.SubmitPurchaseRequest(ctx, p.ID, pr.ID, orgA.ID, "")
		if !errors.Is(err, service.ErrPurchaseRequestItemsRequired) {
			t.Errorf("beklenen ErrPurchaseRequestItemsRequired, geldi: %v", err)
		}
	})

	t.Run("7_pr_submit_to_approve", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		cc := newCostCode(t, orgA.ID, "PR-CC-2")
		approved := newApprovedPR(t, orgA.ID, p.ID, cc.ID)
		if approved.Status != domain.PurchaseRequestStatusApproved {
			t.Errorf("beklenen approved, geldi: %s", approved.Status)
		}
	})

	t.Run("8_pr_reject_requires_reason", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		cc := newCostCode(t, orgA.ID, "PR-CC-3")
		pr, _ := projectSvc.CreatePurchaseRequest(ctx, p.ID, orgA.ID, service.PurchaseRequestInput{
			Title: "Red Testi", Items: []service.PurchaseRequestItemInput{{CostCodeID: cc.ID, Description: "K", Quantity: 1, EstimatedTotal: 10}},
		})
		if _, err := projectSvc.SubmitPurchaseRequest(ctx, p.ID, pr.ID, orgA.ID, ""); err != nil {
			t.Fatalf("gönderilemedi: %v", err)
		}
		if _, err := projectSvc.RejectPurchaseRequest(ctx, p.ID, pr.ID, orgA.ID, "", ""); !errors.Is(err, service.ErrPurchaseRequestReasonRequired) {
			t.Errorf("beklenen ErrPurchaseRequestReasonRequired, geldi: %v", err)
		}
		rejected, err := projectSvc.RejectPurchaseRequest(ctx, p.ID, pr.ID, orgA.ID, "", "bütçe yetersiz")
		if err != nil {
			t.Fatalf("reddedilemedi: %v", err)
		}
		if rejected.Status != domain.PurchaseRequestStatusRejected {
			t.Errorf("beklenen rejected, geldi: %s", rejected.Status)
		}
	})

	t.Run("9_pr_withdraw_submitted_to_draft", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		cc := newCostCode(t, orgA.ID, "PR-CC-4")
		pr, _ := projectSvc.CreatePurchaseRequest(ctx, p.ID, orgA.ID, service.PurchaseRequestInput{
			Title: "Geri Çek", Items: []service.PurchaseRequestItemInput{{CostCodeID: cc.ID, Description: "K", Quantity: 1, EstimatedTotal: 10}},
		})
		if _, err := projectSvc.SubmitPurchaseRequest(ctx, p.ID, pr.ID, orgA.ID, ""); err != nil {
			t.Fatalf("gönderilemedi: %v", err)
		}
		withdrawn, err := projectSvc.WithdrawPurchaseRequest(ctx, p.ID, pr.ID, orgA.ID, "")
		if err != nil {
			t.Fatalf("geri çekilemedi: %v", err)
		}
		if withdrawn.Status != domain.PurchaseRequestStatusDraft {
			t.Errorf("beklenen draft, geldi: %s", withdrawn.Status)
		}
	})

	t.Run("10_pr_cancel_from_approved_requires_reason", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		cc := newCostCode(t, orgA.ID, "PR-CC-5")
		approved := newApprovedPR(t, orgA.ID, p.ID, cc.ID)
		if _, err := projectSvc.CancelPurchaseRequest(ctx, p.ID, approved.ID, orgA.ID, "", ""); !errors.Is(err, service.ErrPurchaseRequestReasonRequired) {
			t.Errorf("beklenen ErrPurchaseRequestReasonRequired, geldi: %v", err)
		}
		cancelled, err := projectSvc.CancelPurchaseRequest(ctx, p.ID, approved.ID, orgA.ID, "", "proje durduruldu")
		if err != nil {
			t.Fatalf("iptal edilemedi: %v", err)
		}
		if cancelled.Status != domain.PurchaseRequestStatusCancelled {
			t.Errorf("beklenen cancelled, geldi: %s", cancelled.Status)
		}
	})

	t.Run("11_pr_cross_project_get_denied", func(t *testing.T) {
		pA := newProject(t, orgA.ID, 100000)
		pB := newProject(t, orgA.ID, 100000)
		cc := newCostCode(t, orgA.ID, "PR-CC-6")
		pr, _ := projectSvc.CreatePurchaseRequest(ctx, pA.ID, orgA.ID, service.PurchaseRequestInput{
			Title: "IDOR", Items: []service.PurchaseRequestItemInput{{CostCodeID: cc.ID, Description: "K", Quantity: 1, EstimatedTotal: 10}},
		})
		if _, err := projectSvc.GetPurchaseRequest(ctx, pB.ID, pr.ID, orgA.ID); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("beklenen ErrNotFound (çapraz proje), geldi: %v", err)
		}
	})

	t.Run("12_pr_cross_tenant_get_denied", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		cc := newCostCode(t, orgA.ID, "PR-CC-7")
		pr, _ := projectSvc.CreatePurchaseRequest(ctx, p.ID, orgA.ID, service.PurchaseRequestInput{
			Title: "IDOR2", Items: []service.PurchaseRequestItemInput{{CostCodeID: cc.ID, Description: "K", Quantity: 1, EstimatedTotal: 10}},
		})
		if _, err := projectSvc.GetPurchaseRequest(ctx, p.ID, pr.ID, orgB.ID); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("beklenen ErrNotFound (çapraz kiracı), geldi: %v", err)
		}
	})

	// ---------- RFQ ----------

	t.Run("13_rfq_create_from_approved_pr_snapshots_items", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		cc := newCostCode(t, orgA.ID, "RFQ-CC-1")
		pr := newApprovedPR(t, orgA.ID, p.ID, cc.ID)
		s1 := newSupplier(t, orgA.ID, "RFQ-S1")
		rfq, err := projectSvc.CreateRFQ(ctx, p.ID, orgA.ID, service.RFQInput{
			Title: "Çimento RFQ", PurchaseRequestID: pr.ID, IssueDate: time.Now(), SupplierIDs: []string{s1.ID},
		})
		if err != nil {
			t.Fatalf("RFQ oluşturulamadı: %v", err)
		}
		items, err := projectSvc.ListRFQItems(ctx, p.ID, rfq.ID, orgA.ID)
		if err != nil || len(items) != 1 || items[0].Description != "Çimento" || items[0].Quantity != 100 {
			t.Fatalf("PR kaleminden snapshot alınmalı: %+v, err=%v", items, err)
		}
	})

	t.Run("14_rfq_snapshot_immune_to_later_pr_changes", func(t *testing.T) {
		// KRİTİK: RFQ issued olduktan sonra, kaynak PR'nin kalemleri
		// (teorik olarak) değişse bile RFQ kalemleri MUTLAKA sabit kalır --
		// snapshot CANLI bir JOIN değildir (bkz. migration §4 gerekçesi).
		// PR onaylandıktan sonra kalemleri servis katmanında zaten
		// düzenlenemez (yalnızca draft'ta), bu yüzden bu test RFQ
		// kalemlerinin PR'den TAMAMEN BAĞIMSIZ, kendi satırları olduğunu
		// (source_pr_item_id yalnızca iz sürme amaçlı) doğrular.
		p := newProject(t, orgA.ID, 100000)
		cc := newCostCode(t, orgA.ID, "RFQ-CC-2")
		pr := newApprovedPR(t, orgA.ID, p.ID, cc.ID)
		s1 := newSupplier(t, orgA.ID, "RFQ-S2")
		rfq, err := projectSvc.CreateRFQ(ctx, p.ID, orgA.ID, service.RFQInput{
			Title: "Snapshot RFQ", PurchaseRequestID: pr.ID, IssueDate: time.Now(), SupplierIDs: []string{s1.ID},
		})
		if err != nil {
			t.Fatalf("RFQ oluşturulamadı: %v", err)
		}
		items, _ := projectSvc.ListRFQItems(ctx, p.ID, rfq.ID, orgA.ID)
		if len(items) != 1 || items[0].SourcePRItemID == nil {
			t.Fatalf("kaynak PR kalemine iz sürme referansı olmalı: %+v", items)
		}
	})

	t.Run("15_rfq_issue_requires_items_and_suppliers", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		rfq, err := projectSvc.CreateRFQ(ctx, p.ID, orgA.ID, service.RFQInput{Title: "Boş RFQ", IssueDate: time.Now()})
		if err != nil {
			t.Fatalf("RFQ oluşturulamadı: %v", err)
		}
		if _, err := projectSvc.IssueRFQ(ctx, p.ID, rfq.ID, orgA.ID, ""); !errors.Is(err, service.ErrRFQItemsRequired) {
			t.Errorf("beklenen ErrRFQItemsRequired, geldi: %v", err)
		}
		cc := newCostCode(t, orgA.ID, "RFQ-CC-3")
		_, err = projectSvc.UpdateRFQDraft(ctx, p.ID, rfq.ID, orgA.ID, service.RFQInput{
			Title: "Boş RFQ", IssueDate: time.Now(),
			Items: []service.RFQItemInput{{CostCodeID: cc.ID, Description: "K", Quantity: 1, Unit: "adet"}},
		})
		if err != nil {
			t.Fatalf("RFQ güncellenemedi: %v", err)
		}
		if _, err := projectSvc.IssueRFQ(ctx, p.ID, rfq.ID, orgA.ID, ""); !errors.Is(err, service.ErrRFQSuppliersRequired) {
			t.Errorf("beklenen ErrRFQSuppliersRequired, geldi: %v", err)
		}
	})

	t.Run("16_rfq_from_unapproved_pr_rejected", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		cc := newCostCode(t, orgA.ID, "RFQ-CC-4")
		pr, _ := projectSvc.CreatePurchaseRequest(ctx, p.ID, orgA.ID, service.PurchaseRequestInput{
			Title: "Taslak PR", Items: []service.PurchaseRequestItemInput{{CostCodeID: cc.ID, Description: "K", Quantity: 1, EstimatedTotal: 10}},
		})
		_, err := projectSvc.CreateRFQ(ctx, p.ID, orgA.ID, service.RFQInput{Title: "Erken RFQ", PurchaseRequestID: pr.ID, IssueDate: time.Now()})
		if !errors.Is(err, service.ErrPurchaseRequestNotApprovedForRFQ) {
			t.Errorf("beklenen ErrPurchaseRequestNotApprovedForRFQ, geldi: %v", err)
		}
	})

	t.Run("17_rfq_cross_project_get_denied", func(t *testing.T) {
		pA := newProject(t, orgA.ID, 100000)
		pB := newProject(t, orgA.ID, 100000)
		rfq, err := projectSvc.CreateRFQ(ctx, pA.ID, orgA.ID, service.RFQInput{Title: "IDOR RFQ", IssueDate: time.Now()})
		if err != nil {
			t.Fatalf("RFQ oluşturulamadı: %v", err)
		}
		if _, err := projectSvc.GetRFQ(ctx, pB.ID, rfq.ID, orgA.ID); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("beklenen ErrNotFound (çapraz proje), geldi: %v", err)
		}
	})

	t.Run("18_rfq_cross_tenant_get_denied", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		rfq, err := projectSvc.CreateRFQ(ctx, p.ID, orgA.ID, service.RFQInput{Title: "IDOR RFQ 2", IssueDate: time.Now()})
		if err != nil {
			t.Fatalf("RFQ oluşturulamadı: %v", err)
		}
		if _, err := projectSvc.GetRFQ(ctx, p.ID, rfq.ID, orgB.ID); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("beklenen ErrNotFound (çapraz kiracı), geldi: %v", err)
		}
	})

	// ---------- Tedarikçi Teklifleri (Quotations) ----------

	t.Run("19_quotation_create_exact_totals", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		cc := newCostCode(t, orgA.ID, "Q-CC-1")
		pr := newApprovedPR(t, orgA.ID, p.ID, cc.ID)
		s1 := newSupplier(t, orgA.ID, "Q-S1")
		rfq := newIssuedRFQ(t, orgA.ID, p.ID, pr, []string{s1.ID})
		items, _ := projectSvc.ListRFQItems(ctx, p.ID, rfq.ID, orgA.ID)

		q, err := projectSvc.CreateQuotation(ctx, p.ID, rfq.ID, orgA.ID, service.QuotationInput{
			SupplierID: s1.ID, QuotationDate: time.Now(), TaxRate: 20,
			Items: []service.QuotationItemInput{{RFQItemID: items[0].ID, Quantity: 100, UnitPrice: 55}},
		})
		if err != nil {
			t.Fatalf("teklif oluşturulamadı: %v", err)
		}
		// subtotal=5500, tax=round(5500*20/100,2)=1100, total=6600
		if q.Subtotal != 5500 || q.Tax != 1100 || q.Total != 6600 {
			t.Errorf("beklenmedik toplamlar: subtotal=%v tax=%v total=%v", q.Subtotal, q.Tax, q.Total)
		}
	})

	t.Run("20_quotation_supplier_not_invited_rejected", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		cc := newCostCode(t, orgA.ID, "Q-CC-2")
		pr := newApprovedPR(t, orgA.ID, p.ID, cc.ID)
		s1 := newSupplier(t, orgA.ID, "Q-S2")
		sOutsider := newSupplier(t, orgA.ID, "Q-S2-OUT")
		rfq := newIssuedRFQ(t, orgA.ID, p.ID, pr, []string{s1.ID})
		items, _ := projectSvc.ListRFQItems(ctx, p.ID, rfq.ID, orgA.ID)
		_, err := projectSvc.CreateQuotation(ctx, p.ID, rfq.ID, orgA.ID, service.QuotationInput{
			SupplierID: sOutsider.ID, QuotationDate: time.Now(),
			Items: []service.QuotationItemInput{{RFQItemID: items[0].ID, Quantity: 100, UnitPrice: 50}},
		})
		if !errors.Is(err, service.ErrQuotationSupplierNotInvited) {
			t.Errorf("beklenen ErrQuotationSupplierNotInvited, geldi: %v", err)
		}
	})

	t.Run("21_quotation_rejected_after_rfq_closed", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		cc := newCostCode(t, orgA.ID, "Q-CC-3")
		pr := newApprovedPR(t, orgA.ID, p.ID, cc.ID)
		s1 := newSupplier(t, orgA.ID, "Q-S3")
		rfq := newIssuedRFQ(t, orgA.ID, p.ID, pr, []string{s1.ID})
		items, _ := projectSvc.ListRFQItems(ctx, p.ID, rfq.ID, orgA.ID)
		if _, err := projectSvc.CloseRFQ(ctx, p.ID, rfq.ID, orgA.ID, ""); err != nil {
			t.Fatalf("RFQ kapatılamadı: %v", err)
		}
		_, err := projectSvc.CreateQuotation(ctx, p.ID, rfq.ID, orgA.ID, service.QuotationInput{
			SupplierID: s1.ID, QuotationDate: time.Now(),
			Items: []service.QuotationItemInput{{RFQItemID: items[0].ID, Quantity: 100, UnitPrice: 50}},
		})
		if !errors.Is(err, service.ErrQuotationRFQNotOpen) {
			t.Errorf("beklenen ErrQuotationRFQNotOpen, geldi: %v", err)
		}
	})

	// ---------- Teklif Karşılaştırma + Award ----------

	t.Run("22_bid_comparison_deterministic", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		cc := newCostCode(t, orgA.ID, "CMP-CC-1")
		pr := newApprovedPR(t, orgA.ID, p.ID, cc.ID)
		sA := newSupplier(t, orgA.ID, "CMP-SA")
		sB := newSupplier(t, orgA.ID, "CMP-SB")
		rfq := newIssuedRFQ(t, orgA.ID, p.ID, pr, []string{sA.ID, sB.ID})
		items, _ := projectSvc.ListRFQItems(ctx, p.ID, rfq.ID, orgA.ID)

		if _, err := projectSvc.CreateQuotation(ctx, p.ID, rfq.ID, orgA.ID, service.QuotationInput{
			SupplierID: sA.ID, QuotationDate: time.Now(),
			Items: []service.QuotationItemInput{{RFQItemID: items[0].ID, Quantity: 100, UnitPrice: 125.50}},
		}); err != nil {
			t.Fatalf("A teklifi oluşturulamadı: %v", err)
		}
		if _, err := projectSvc.CreateQuotation(ctx, p.ID, rfq.ID, orgA.ID, service.QuotationInput{
			SupplierID: sB.ID, QuotationDate: time.Now(),
			Items: []service.QuotationItemInput{{RFQItemID: items[0].ID, Quantity: 100, UnitPrice: 123.75}},
		}); err != nil {
			t.Fatalf("B teklifi oluşturulamadı: %v", err)
		}

		cmp, err := projectSvc.GetBidComparison(ctx, p.ID, rfq.ID, orgA.ID)
		if err != nil {
			t.Fatalf("karşılaştırma alınamadı: %v", err)
		}
		if len(cmp.Rows) != 1 || len(cmp.Rows[0].Cells) != 2 {
			t.Fatalf("beklenen 1 satır x 2 tedarikçi, geldi: %+v", cmp.Rows)
		}
		cellA := cmp.Rows[0].Cells[sA.ID]
		cellB := cmp.Rows[0].Cells[sB.ID]
		if cellA.LineTotal != 12550 || cellB.LineTotal != 12375 {
			t.Errorf("beklenmedik hücre toplamları: A=%v B=%v", cellA.LineTotal, cellB.LineTotal)
		}

		invited, err := projectSvc.ListRFQSuppliers(ctx, p.ID, rfq.ID, orgA.ID)
		if err != nil {
			t.Fatalf("davetliler alınamadı: %v", err)
		}
		for _, is := range invited {
			if is.ResponseStatus != domain.RFQSupplierResponseResponded {
				t.Errorf("teklif verdikten sonra response_status='responded' olmalı: %+v", is)
			}
		}
	})

	t.Run("23_award_authorized_closes_rfq", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		cc := newCostCode(t, orgA.ID, "AWD-CC-1")
		pr := newApprovedPR(t, orgA.ID, p.ID, cc.ID)
		sA := newSupplier(t, orgA.ID, "AWD-SA")
		rfq := newIssuedRFQ(t, orgA.ID, p.ID, pr, []string{sA.ID})
		items, _ := projectSvc.ListRFQItems(ctx, p.ID, rfq.ID, orgA.ID)
		q, err := projectSvc.CreateQuotation(ctx, p.ID, rfq.ID, orgA.ID, service.QuotationInput{
			SupplierID: sA.ID, QuotationDate: time.Now(),
			Items: []service.QuotationItemInput{{RFQItemID: items[0].ID, Quantity: 100, UnitPrice: 50}},
		})
		if err != nil {
			t.Fatalf("teklif oluşturulamadı: %v", err)
		}
		awarded, err := projectSvc.AwardRFQ(ctx, p.ID, rfq.ID, orgA.ID, "", q.ID, "en uygun teklif")
		if err != nil {
			t.Fatalf("ödül verilemedi: %v", err)
		}
		if awarded.Status != domain.RFQStatusClosed || awarded.AwardedQuotationID == nil || *awarded.AwardedQuotationID != q.ID {
			t.Errorf("beklenmedik award sonucu: %+v", awarded)
		}
		// Award TEK BAŞINA hiçbir commitment/actual cost OLUŞTURMAMALI.
		summary, err := projectSvc.CostControlSummary(ctx, p.ID, orgA.ID)
		if err != nil {
			t.Fatalf("özet alınamadı: %v", err)
		}
		if summary.CommittedCost != 0 || summary.ActualCost != 0 {
			t.Errorf("award commitment/actual OLUŞTURMAMALI: committed=%v actual=%v", summary.CommittedCost, summary.ActualCost)
		}
	})

	t.Run("24_award_quotation_mismatch_rejected", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		cc := newCostCode(t, orgA.ID, "AWD-CC-2")
		pr1 := newApprovedPR(t, orgA.ID, p.ID, cc.ID)
		pr2 := newApprovedPR(t, orgA.ID, p.ID, cc.ID)
		sA := newSupplier(t, orgA.ID, "AWD-SA2")
		rfq1 := newIssuedRFQ(t, orgA.ID, p.ID, pr1, []string{sA.ID})
		rfq2 := newIssuedRFQ(t, orgA.ID, p.ID, pr2, []string{sA.ID})
		items2, _ := projectSvc.ListRFQItems(ctx, p.ID, rfq2.ID, orgA.ID)
		q2, err := projectSvc.CreateQuotation(ctx, p.ID, rfq2.ID, orgA.ID, service.QuotationInput{
			SupplierID: sA.ID, QuotationDate: time.Now(),
			Items: []service.QuotationItemInput{{RFQItemID: items2[0].ID, Quantity: 100, UnitPrice: 50}},
		})
		if err != nil {
			t.Fatalf("teklif oluşturulamadı: %v", err)
		}
		// rfq1'i, rfq2'nin teklifiyle ödüllendirmeye çalış -- çapraz-RFQ
		// award İMKANSIZ olmalı.
		if _, err := projectSvc.AwardRFQ(ctx, p.ID, rfq1.ID, orgA.ID, "", q2.ID, ""); !errors.Is(err, service.ErrAwardQuotationMismatch) {
			t.Errorf("beklenen ErrAwardQuotationMismatch, geldi: %v", err)
		}
	})

	// ---------- Purchase Order + Cost Control Entegrasyonu ----------

	t.Run("25_po_create_requires_items", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		s := newSupplier(t, orgA.ID, "PO-S1")
		_, err := projectSvc.CreatePurchaseOrder(ctx, p.ID, orgA.ID, service.PurchaseOrderInput{SupplierID: s.ID, IssueDate: time.Now()})
		if !errors.Is(err, service.ErrPurchaseOrderItemsRequired) {
			t.Errorf("beklenen ErrPurchaseOrderItemsRequired, geldi: %v", err)
		}
	})

	t.Run("26_po_create_requires_cost_code_on_every_item", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		s := newSupplier(t, orgA.ID, "PO-S2")
		_, err := projectSvc.CreatePurchaseOrder(ctx, p.ID, orgA.ID, service.PurchaseOrderInput{
			SupplierID: s.ID, IssueDate: time.Now(),
			Items: []service.PurchaseOrderItemInput{{Description: "Kodu yok", Quantity: 1, UnitPrice: 100}},
		})
		if !errors.Is(err, service.ErrInvalidBudgetLineCostCode) {
			t.Errorf("beklenen ErrInvalidBudgetLineCostCode, geldi: %v", err)
		}
	})

	t.Run("27_po_approve_creates_commitment_matching_item_totals_exactly", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		cc := newCostCode(t, orgA.ID, "PO-CC-1")
		s := newSupplier(t, orgA.ID, "PO-S3")
		po, err := projectSvc.CreatePurchaseOrder(ctx, p.ID, orgA.ID, service.PurchaseOrderInput{
			SupplierID: s.ID, IssueDate: time.Now(), TaxRate: 20,
			Items: []service.PurchaseOrderItemInput{
				{CostCodeID: cc.ID, Description: "Demir", Quantity: 10, Unit: "ton", UnitPrice: 15000},
			},
		})
		if err != nil {
			t.Fatalf("PO oluşturulamadı: %v", err)
		}
		if po.Subtotal != 150000 || po.Tax != 30000 || po.Total != 180000 {
			t.Fatalf("beklenmedik PO toplamları: %+v", po)
		}
		approved, err := projectSvc.ApprovePurchaseOrder(ctx, p.ID, po.ID, orgA.ID, "")
		if err != nil {
			t.Fatalf("PO onaylanamadı: %v", err)
		}
		if approved.Status != domain.PurchaseOrderStatusApproved {
			t.Errorf("beklenen approved, geldi: %s", approved.Status)
		}
		commitments, err := projectSvc.ListCommitmentsForPurchaseOrder(ctx, p.ID, po.ID, orgA.ID)
		if err != nil {
			t.Fatalf("taahhütler alınamadı: %v", err)
		}
		if len(commitments) != 1 || commitments[0].CommittedAmount != 150000 {
			t.Fatalf("commitment tutarı KALEM SUBTOTAL'i (line_total) İLE BİREBİR eşleşmeli (KDV hariç): %+v", commitments)
		}
		if commitments[0].SourceType != domain.CommitmentSourcePurchaseOrder {
			t.Errorf("beklenen source_type=purchase_order, geldi: %s", commitments[0].SourceType)
		}
	})

	t.Run("28_po_approved_baseline_locked_no_further_edit", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		cc := newCostCode(t, orgA.ID, "PO-CC-2")
		s := newSupplier(t, orgA.ID, "PO-S4")
		po, _ := projectSvc.CreatePurchaseOrder(ctx, p.ID, orgA.ID, service.PurchaseOrderInput{
			SupplierID: s.ID, IssueDate: time.Now(),
			Items: []service.PurchaseOrderItemInput{{CostCodeID: cc.ID, Description: "K", Quantity: 1, UnitPrice: 100}},
		})
		if _, err := projectSvc.ApprovePurchaseOrder(ctx, p.ID, po.ID, orgA.ID, ""); err != nil {
			t.Fatalf("onaylanamadı: %v", err)
		}
		_, err := projectSvc.UpdatePurchaseOrderDraft(ctx, p.ID, po.ID, orgA.ID, service.PurchaseOrderInput{
			SupplierID: s.ID, IssueDate: time.Now(),
			Items: []service.PurchaseOrderItemInput{{CostCodeID: cc.ID, Description: "Değişmemeli", Quantity: 1, UnitPrice: 999}},
		})
		if !errors.Is(err, service.ErrPurchaseOrderNotEditable) {
			t.Errorf("beklenen ErrPurchaseOrderNotEditable, geldi: %v", err)
		}
	})

	t.Run("29_po_cancel_from_draft_no_commitment_impact", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		cc := newCostCode(t, orgA.ID, "PO-CC-3")
		s := newSupplier(t, orgA.ID, "PO-S5")
		po, _ := projectSvc.CreatePurchaseOrder(ctx, p.ID, orgA.ID, service.PurchaseOrderInput{
			SupplierID: s.ID, IssueDate: time.Now(),
			Items: []service.PurchaseOrderItemInput{{CostCodeID: cc.ID, Description: "K", Quantity: 1, UnitPrice: 100}},
		})
		cancelled, err := projectSvc.CancelPurchaseOrder(ctx, p.ID, po.ID, orgA.ID, "", "vazgeçildi")
		if err != nil {
			t.Fatalf("iptal edilemedi: %v", err)
		}
		if cancelled.Status != domain.PurchaseOrderStatusCancelled {
			t.Errorf("beklenen cancelled, geldi: %s", cancelled.Status)
		}
		commitments, _ := projectSvc.ListCommitmentsForPurchaseOrder(ctx, p.ID, po.ID, orgA.ID)
		if len(commitments) != 0 {
			t.Errorf("draft'tan iptalde hiç commitment OLUŞMAMALIYDI: %+v", commitments)
		}
	})

	t.Run("30_po_cancel_from_approved_releases_commitment", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		cc := newCostCode(t, orgA.ID, "PO-CC-4")
		s := newSupplier(t, orgA.ID, "PO-S6")
		po, _ := projectSvc.CreatePurchaseOrder(ctx, p.ID, orgA.ID, service.PurchaseOrderInput{
			SupplierID: s.ID, IssueDate: time.Now(),
			Items: []service.PurchaseOrderItemInput{{CostCodeID: cc.ID, Description: "K", Quantity: 1, UnitPrice: 5000}},
		})
		if _, err := projectSvc.ApprovePurchaseOrder(ctx, p.ID, po.ID, orgA.ID, ""); err != nil {
			t.Fatalf("onaylanamadı: %v", err)
		}
		if _, err := projectSvc.CancelPurchaseOrder(ctx, p.ID, po.ID, orgA.ID, "", ""); !errors.Is(err, service.ErrPurchaseOrderReasonRequired) {
			t.Errorf("beklenen ErrPurchaseOrderReasonRequired, geldi: %v", err)
		}
		if _, err := projectSvc.CancelPurchaseOrder(ctx, p.ID, po.ID, orgA.ID, "", "iş iptal"); err != nil {
			t.Fatalf("iptal edilemedi: %v", err)
		}
		commitments, err := projectSvc.ListCommitmentsForPurchaseOrder(ctx, p.ID, po.ID, orgA.ID)
		if err != nil {
			t.Fatalf("taahhütler alınamadı: %v", err)
		}
		if len(commitments) != 1 || commitments[0].Status != domain.CommitmentStatusVoided {
			t.Fatalf("approved'tan iptalde BAĞLI commitment voided olmalı: %+v", commitments)
		}
	})

	t.Run("31_po_close_does_not_touch_commitment", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		cc := newCostCode(t, orgA.ID, "PO-CC-5")
		s := newSupplier(t, orgA.ID, "PO-S7")
		po, _ := projectSvc.CreatePurchaseOrder(ctx, p.ID, orgA.ID, service.PurchaseOrderInput{
			SupplierID: s.ID, IssueDate: time.Now(),
			Items: []service.PurchaseOrderItemInput{{CostCodeID: cc.ID, Description: "K", Quantity: 1, UnitPrice: 5000}},
		})
		if _, err := projectSvc.ApprovePurchaseOrder(ctx, p.ID, po.ID, orgA.ID, ""); err != nil {
			t.Fatalf("onaylanamadı: %v", err)
		}
		closed, err := projectSvc.ClosePurchaseOrder(ctx, p.ID, po.ID, orgA.ID, "")
		if err != nil {
			t.Fatalf("kapatılamadı: %v", err)
		}
		if closed.Status != domain.PurchaseOrderStatusClosed {
			t.Errorf("beklenen closed, geldi: %s", closed.Status)
		}
		commitments, _ := projectSvc.ListCommitmentsForPurchaseOrder(ctx, p.ID, po.ID, orgA.ID)
		if len(commitments) != 1 || commitments[0].Status != domain.CommitmentStatusActive {
			t.Fatalf("close, commitment'a DOKUNMAMALI (hâlâ active kalmalı): %+v", commitments)
		}
	})

	t.Run("32_po_cross_project_get_denied", func(t *testing.T) {
		pA := newProject(t, orgA.ID, 100000)
		pB := newProject(t, orgA.ID, 100000)
		cc := newCostCode(t, orgA.ID, "PO-CC-6")
		s := newSupplier(t, orgA.ID, "PO-S8")
		po, _ := projectSvc.CreatePurchaseOrder(ctx, pA.ID, orgA.ID, service.PurchaseOrderInput{
			SupplierID: s.ID, IssueDate: time.Now(),
			Items: []service.PurchaseOrderItemInput{{CostCodeID: cc.ID, Description: "K", Quantity: 1, UnitPrice: 100}},
		})
		if _, err := projectSvc.GetPurchaseOrder(ctx, pB.ID, po.ID, orgA.ID); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("beklenen ErrNotFound (çapraz proje), geldi: %v", err)
		}
	})

	t.Run("33_po_cross_tenant_get_denied", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		cc := newCostCode(t, orgA.ID, "PO-CC-7")
		s := newSupplier(t, orgA.ID, "PO-S9")
		po, _ := projectSvc.CreatePurchaseOrder(ctx, p.ID, orgA.ID, service.PurchaseOrderInput{
			SupplierID: s.ID, IssueDate: time.Now(),
			Items: []service.PurchaseOrderItemInput{{CostCodeID: cc.ID, Description: "K", Quantity: 1, UnitPrice: 100}},
		})
		if _, err := projectSvc.GetPurchaseOrder(ctx, p.ID, po.ID, orgB.ID); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("beklenen ErrNotFound (çapraz kiracı), geldi: %v", err)
		}
	})

	t.Run("34_po_cross_tenant_supplier_rejected", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		sOther := newSupplier(t, orgB.ID, "PO-XT")
		_, err := projectSvc.CreatePurchaseOrder(ctx, p.ID, orgA.ID, service.PurchaseOrderInput{
			SupplierID: sOther.ID, IssueDate: time.Now(),
			Items: []service.PurchaseOrderItemInput{{CostCodeID: "", Description: "K", Quantity: 1, UnitPrice: 100}},
		})
		if !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("Org B'nin tedarikçisiyle Org A'da PO açılması İMKANSIZ olmalı, beklenen ErrNotFound, geldi: %v", err)
		}
	})

	t.Run("35_po_duplicate_approval_concurrency", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		cc := newCostCode(t, orgA.ID, "PO-CC-RACE")
		s := newSupplier(t, orgA.ID, "PO-SRACE")
		po, _ := projectSvc.CreatePurchaseOrder(ctx, p.ID, orgA.ID, service.PurchaseOrderInput{
			SupplierID: s.ID, IssueDate: time.Now(),
			Items: []service.PurchaseOrderItemInput{{CostCodeID: cc.ID, Description: "K", Quantity: 1, UnitPrice: 1000}},
		})
		const attempts = 5
		results := make(chan error, attempts)
		for i := 0; i < attempts; i++ {
			go func() {
				_, err := projectSvc.ApprovePurchaseOrder(ctx, p.ID, po.ID, orgA.ID, "")
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
		commitments, err := projectSvc.ListCommitmentsForPurchaseOrder(ctx, p.ID, po.ID, orgA.ID)
		if err != nil {
			t.Fatalf("taahhütler alınamadı: %v", err)
		}
		if len(commitments) != 1 {
			t.Errorf("yarış koşulunda commitment TAM OLARAK BİR KERE oluşmalı, geldi: %d adet", len(commitments))
		}
	})

	t.Run("36_money_test_award_lowest_bid_exact_po_total", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		cc := newCostCode(t, orgA.ID, "MNY-CC")
		pr := newApprovedPR(t, orgA.ID, p.ID, cc.ID)
		sA := newSupplier(t, orgA.ID, "MNY-SA")
		sB := newSupplier(t, orgA.ID, "MNY-SB")
		rfq := newIssuedRFQ(t, orgA.ID, p.ID, pr, []string{sA.ID, sB.ID})
		items, _ := projectSvc.ListRFQItems(ctx, p.ID, rfq.ID, orgA.ID)

		if _, err := projectSvc.CreateQuotation(ctx, p.ID, rfq.ID, orgA.ID, service.QuotationInput{
			SupplierID: sA.ID, QuotationDate: time.Now(), TaxRate: 20,
			Items: []service.QuotationItemInput{{RFQItemID: items[0].ID, Quantity: 100, UnitPrice: 125.50}},
		}); err != nil {
			t.Fatalf("A teklifi: %v", err)
		}
		qB, err := projectSvc.CreateQuotation(ctx, p.ID, rfq.ID, orgA.ID, service.QuotationInput{
			SupplierID: sB.ID, QuotationDate: time.Now(), TaxRate: 20,
			Items: []service.QuotationItemInput{{RFQItemID: items[0].ID, Quantity: 100, UnitPrice: 123.75}},
		})
		if err != nil {
			t.Fatalf("B teklifi: %v", err)
		}
		if qB.Total != 14850 { // subtotal=12375, KDV %20 = 2475, total=14850
			t.Fatalf("beklenen B teklifi toplamı 14850, geldi: %v", qB.Total)
		}
		if _, err := projectSvc.AwardRFQ(ctx, p.ID, rfq.ID, orgA.ID, "", qB.ID, "en düşük teklif"); err != nil {
			t.Fatalf("ödül verilemedi: %v", err)
		}

		po, err := projectSvc.CreatePurchaseOrder(ctx, p.ID, orgA.ID, service.PurchaseOrderInput{
			SupplierID: sB.ID, SourceRFQID: rfq.ID, SourceQuotationID: qB.ID, IssueDate: time.Now(), TaxRate: 20,
			Items: []service.PurchaseOrderItemInput{{CostCodeID: cc.ID, Description: "Çimento", Quantity: 100, Unit: "torba", UnitPrice: 123.75}},
		})
		if err != nil {
			t.Fatalf("PO oluşturulamadı: %v", err)
		}
		if po.Subtotal != 12375 || po.Total != 14850 {
			t.Fatalf("beklenen PO subtotal=12375 total=14850, geldi: subtotal=%v total=%v", po.Subtotal, po.Total)
		}
		approved, err := projectSvc.ApprovePurchaseOrder(ctx, p.ID, po.ID, orgA.ID, "")
		if err != nil {
			t.Fatalf("PO onaylanamadı: %v", err)
		}
		commitments, err := projectSvc.ListCommitmentsForPurchaseOrder(ctx, p.ID, approved.ID, orgA.ID)
		if err != nil || len(commitments) != 1 || commitments[0].CommittedAmount != 12375 {
			t.Fatalf("commitment tutarı KDV HARİÇ kalem toplamıyla (12375) BİREBİR eşleşmeli: %+v, err=%v", commitments, err)
		}
	})

	t.Run("37_po_source_quotation_rfq_mismatch_rejected", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		cc := newCostCode(t, orgA.ID, "MIS-CC")
		pr1 := newApprovedPR(t, orgA.ID, p.ID, cc.ID)
		pr2 := newApprovedPR(t, orgA.ID, p.ID, cc.ID)
		s := newSupplier(t, orgA.ID, "MIS-S")
		rfq1 := newIssuedRFQ(t, orgA.ID, p.ID, pr1, []string{s.ID})
		rfq2 := newIssuedRFQ(t, orgA.ID, p.ID, pr2, []string{s.ID})
		items2, _ := projectSvc.ListRFQItems(ctx, p.ID, rfq2.ID, orgA.ID)
		q2, err := projectSvc.CreateQuotation(ctx, p.ID, rfq2.ID, orgA.ID, service.QuotationInput{
			SupplierID: s.ID, QuotationDate: time.Now(),
			Items: []service.QuotationItemInput{{RFQItemID: items2[0].ID, Quantity: 100, UnitPrice: 50}},
		})
		if err != nil {
			t.Fatalf("teklif oluşturulamadı: %v", err)
		}
		_, err = projectSvc.CreatePurchaseOrder(ctx, p.ID, orgA.ID, service.PurchaseOrderInput{
			SupplierID: s.ID, SourceRFQID: rfq1.ID, SourceQuotationID: q2.ID, IssueDate: time.Now(),
			Items: []service.PurchaseOrderItemInput{{CostCodeID: cc.ID, Description: "K", Quantity: 1, UnitPrice: 100}},
		})
		if !errors.Is(err, service.ErrAwardQuotationMismatch) {
			t.Errorf("beklenen ErrAwardQuotationMismatch (çapraz RFQ kaynak referansı), geldi: %v", err)
		}
	})

	// ---------- 38: Cost Control Golden Regresyon (spec §27) ----------

	t.Run("38_cost_control_golden_regression", func(t *testing.T) {
		p := newProject(t, orgA.ID, 500000)
		cc := newCostCode(t, orgA.ID, "GOLD-CC")
		if _, err := projectSvc.CreateBudgetLine(ctx, p.ID, orgA.ID, service.BudgetLineInput{
			CostCodeID: cc.ID, Description: "Bütçe Kalemi", OriginalAmount: 100000,
		}); err != nil {
			t.Fatalf("bütçe kalemi oluşturulamadı: %v", err)
		}
		if _, err := projectSvc.BaselineProjectBudget(ctx, p.ID, orgA.ID, ""); err != nil {
			t.Fatalf("baseline alınamadı: %v", err)
		}
		// Mevcut (manuel) taahhüt: 10.000.
		if _, err := projectSvc.CreateCommitment(ctx, p.ID, orgA.ID, service.CommitmentInput{
			CostCodeID: cc.ID, Description: "Mevcut manuel taahhüt", CommittedAmount: 10000, CommittedAt: time.Now(),
		}); err != nil {
			t.Fatalf("manuel taahhüt oluşturulamadı: %v", err)
		}
		before, err := projectSvc.CostControlSummary(ctx, p.ID, orgA.ID)
		if err != nil {
			t.Fatalf("özet alınamadı: %v", err)
		}
		if before.CommittedCost != 10000 || before.ActualCost != 0 || before.OriginalBudget != 100000 || before.ContractValue != 500000 {
			t.Fatalf("golden test başlangıç durumu beklenmedik: %+v", before)
		}

		// Onaylı PO: 30.000 (KDV hariç -- committed HER ZAMAN KDV hariç
		// kalem toplamıdır, tıpkı manuel taahhüt gibi).
		s := newSupplier(t, orgA.ID, "GOLD-S")
		po, err := projectSvc.CreatePurchaseOrder(ctx, p.ID, orgA.ID, service.PurchaseOrderInput{
			SupplierID: s.ID, IssueDate: time.Now(),
			Items: []service.PurchaseOrderItemInput{{CostCodeID: cc.ID, Description: "PO Kalemi", Quantity: 1, UnitPrice: 30000}},
		})
		if err != nil {
			t.Fatalf("PO oluşturulamadı: %v", err)
		}
		if _, err := projectSvc.ApprovePurchaseOrder(ctx, p.ID, po.ID, orgA.ID, ""); err != nil {
			t.Fatalf("PO onaylanamadı: %v", err)
		}

		afterApprove, err := projectSvc.CostControlSummary(ctx, p.ID, orgA.ID)
		if err != nil {
			t.Fatalf("özet alınamadı: %v", err)
		}
		if afterApprove.CommittedCost != 40000 {
			t.Fatalf("PO onayı SONRASI committed = 10000+30000 = 40000 OLMALI, geldi: %v", afterApprove.CommittedCost)
		}
		if afterApprove.ActualCost != 0 {
			t.Fatalf("Actual DEĞİŞMEMELİ, geldi: %v", afterApprove.ActualCost)
		}
		if afterApprove.OriginalBudget != 100000 || afterApprove.RevisedBudget != 100000 {
			t.Fatalf("Budget DEĞİŞMEMELİ, geldi original=%v revised=%v", afterApprove.OriginalBudget, afterApprove.RevisedBudget)
		}
		if afterApprove.ContractValue != 500000 {
			t.Fatalf("Contract/proje bedeli DEĞİŞMEMELİ, geldi: %v", afterApprove.ContractValue)
		}
		projAfterApprove, err := projectSvc.Get(ctx, p.ID, orgA.ID)
		if err != nil || projAfterApprove.ContractAmount != 500000 {
			t.Fatalf("projects.contract_amount PO onayından ASLA etkilenmemeli: %v, err=%v", projAfterApprove.ContractAmount, err)
		}

		// PO iptal edilir: committed 10.000'e GERİ DÖNMELİ.
		if _, err := projectSvc.CancelPurchaseOrder(ctx, p.ID, po.ID, orgA.ID, "", "tedarikçi vazgeçti"); err != nil {
			t.Fatalf("PO iptal edilemedi: %v", err)
		}
		afterCancel, err := projectSvc.CostControlSummary(ctx, p.ID, orgA.ID)
		if err != nil {
			t.Fatalf("özet alınamadı: %v", err)
		}
		if afterCancel.CommittedCost != 10000 {
			t.Fatalf("PO iptali SONRASI committed = 10000'E GERİ DÖNMELİ, geldi: %v", afterCancel.CommittedCost)
		}
		if afterCancel.ActualCost != 0 || afterCancel.OriginalBudget != 100000 || afterCancel.ContractValue != 500000 {
			t.Fatalf("Actual/Budget/Contract PO iptalinden de ETKİLENMEMELİ: %+v", afterCancel)
		}
		projAfterCancel, err := projectSvc.Get(ctx, p.ID, orgA.ID)
		if err != nil || projAfterCancel.ContractAmount != 500000 {
			t.Fatalf("projects.contract_amount PO iptalinden de ASLA etkilenmemeli: %v, err=%v", projAfterCancel.ContractAmount, err)
		}
	})

	// ---------- 39: Contract/Change Order Regresyon (spec §28) ----------

	t.Run("39_procurement_never_touches_contract_or_change_orders", func(t *testing.T) {
		p := newProject(t, orgA.ID, 200000)
		cc := newCostCode(t, orgA.ID, "CTR-CC")
		s := newSupplier(t, orgA.ID, "CTR-S")
		po, err := projectSvc.CreatePurchaseOrder(ctx, p.ID, orgA.ID, service.PurchaseOrderInput{
			SupplierID: s.ID, IssueDate: time.Now(),
			Items: []service.PurchaseOrderItemInput{{CostCodeID: cc.ID, Description: "K", Quantity: 1, UnitPrice: 50000}},
		})
		if err != nil {
			t.Fatalf("PO oluşturulamadı: %v", err)
		}
		if _, err := projectSvc.ApprovePurchaseOrder(ctx, p.ID, po.ID, orgA.ID, ""); err != nil {
			t.Fatalf("PO onaylanamadı: %v", err)
		}
		// PO onayı: (a) project_contracts satırı OLUŞTURMAMALI (Contract
		// hâlâ hiç var olmamalı, Sprint 4'ün "otomatik oluşturma yok"
		// kararıyla AYNI ilke), (b) hiçbir project_change_orders satırı
		// OLUŞTURMAMALI.
		if _, err := projectSvc.GetProjectContract(ctx, p.ID, orgA.ID); !errors.Is(err, service.ErrContractNotFound) {
			t.Errorf("PO onayı bir Contract OLUŞTURMAMALI, beklenen ErrContractNotFound, geldi: %v", err)
		}
		summary, err := projectSvc.FinancialSummary(ctx, p.ID, orgA.ID)
		if err != nil {
			t.Fatalf("finansal özet alınamadı: %v", err)
		}
		if summary.ApprovedAdditions != 0 || summary.ApprovedDeductions != 0 {
			t.Errorf("PO onayı Ek İş (Change Order) etkisi OLUŞTURMAMALI: %+v", summary)
		}
		proj, err := projectSvc.Get(ctx, p.ID, orgA.ID)
		if err != nil || proj.ContractAmount != 200000 {
			t.Errorf("projects.contract_amount PO onayından ETKİLENMEMELİ: %v, err=%v", proj.ContractAmount, err)
		}
	})

	// ---------- 40+: 2026-10 denetim düzeltmeleri ----------

	t.Run("40_po_from_quotation_requires_awarded_matching_supplier_single_po", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		cc := newCostCode(t, orgA.ID, "PQA-CC")
		pr := newApprovedPR(t, orgA.ID, p.ID, cc.ID)
		sA := newSupplier(t, orgA.ID, "PQA-SA")
		sB := newSupplier(t, orgA.ID, "PQA-SB")
		rfq := newIssuedRFQ(t, orgA.ID, p.ID, pr, []string{sA.ID, sB.ID})
		items, _ := projectSvc.ListRFQItems(ctx, p.ID, rfq.ID, orgA.ID)
		qA, err := projectSvc.CreateQuotation(ctx, p.ID, rfq.ID, orgA.ID, service.QuotationInput{
			SupplierID: sA.ID, QuotationDate: time.Now(),
			Items: []service.QuotationItemInput{{RFQItemID: items[0].ID, Quantity: 100, UnitPrice: 130}},
		})
		if err != nil {
			t.Fatal(err)
		}
		qB, err := projectSvc.CreateQuotation(ctx, p.ID, rfq.ID, orgA.ID, service.QuotationInput{
			SupplierID: sB.ID, QuotationDate: time.Now(),
			Items: []service.QuotationItemInput{{RFQItemID: items[0].ID, Quantity: 100, UnitPrice: 120}},
		})
		if err != nil {
			t.Fatal(err)
		}
		poInput := func(supplierID, quotationID string) service.PurchaseOrderInput {
			return service.PurchaseOrderInput{
				SupplierID: supplierID, SourceQuotationID: quotationID, IssueDate: time.Now(),
				Items: []service.PurchaseOrderItemInput{{CostCodeID: cc.ID, Description: "Çimento", Quantity: 100, UnitPrice: 120}},
			}
		}
		// Henüz ödül yok.
		if _, err := projectSvc.CreatePurchaseOrder(ctx, p.ID, orgA.ID, poInput(sB.ID, qB.ID)); !errors.Is(err, service.ErrPurchaseOrderQuotationNotAwarded) {
			t.Fatalf("ödül verilmemiş tekliften sipariş REDDEDİLMELİ, geldi: %v", err)
		}
		if _, err := projectSvc.AwardRFQ(ctx, p.ID, rfq.ID, orgA.ID, "", qB.ID, "en düşük"); err != nil {
			t.Fatal(err)
		}
		// Kaybeden tekliften.
		if _, err := projectSvc.CreatePurchaseOrder(ctx, p.ID, orgA.ID, poInput(sA.ID, qA.ID)); !errors.Is(err, service.ErrPurchaseOrderQuotationNotAwarded) {
			t.Fatalf("kaybeden tekliften sipariş REDDEDİLMELİ, geldi: %v", err)
		}
		// Kazanan teklif ama başka tedarikçiye.
		if _, err := projectSvc.CreatePurchaseOrder(ctx, p.ID, orgA.ID, poInput(sA.ID, qB.ID)); !errors.Is(err, service.ErrPurchaseOrderSupplierMismatch) {
			t.Fatalf("teklifi vermeyen tedarikçiye sipariş REDDEDİLMELİ, geldi: %v", err)
		}
		po, err := projectSvc.CreatePurchaseOrder(ctx, p.ID, orgA.ID, poInput(sB.ID, qB.ID))
		if err != nil {
			t.Fatalf("kazanan tekliften sipariş açılabilmeli: %v", err)
		}
		if po.SourceRFQID == nil || *po.SourceRFQID != rfq.ID {
			t.Errorf("kaynak RFQ tekliften doldurulmalı, geldi: %v", po.SourceRFQID)
		}
		if _, err := projectSvc.CreatePurchaseOrder(ctx, p.ID, orgA.ID, poInput(sB.ID, qB.ID)); !errors.Is(err, service.ErrPurchaseOrderQuotationAlreadyOrdered) {
			t.Fatalf("aynı tekliften ikinci sipariş REDDEDİLMELİ, geldi: %v", err)
		}
		// İptal edilen siparişin yerine yenisi açılabilir.
		if _, err := projectSvc.CancelPurchaseOrder(ctx, p.ID, po.ID, orgA.ID, "", "yanlış adres"); err != nil {
			t.Fatal(err)
		}
		if _, err := projectSvc.CreatePurchaseOrder(ctx, p.ID, orgA.ID, poInput(sB.ID, qB.ID)); err != nil {
			t.Fatalf("iptal edilen siparişin yerine yenisi açılabilmeli: %v", err)
		}

		// Eşzamanlı iki istekten yalnızca biri sipariş açar.
		pr2 := newApprovedPR(t, orgA.ID, p.ID, cc.ID)
		rfq2 := newIssuedRFQ(t, orgA.ID, p.ID, pr2, []string{sB.ID})
		items2, _ := projectSvc.ListRFQItems(ctx, p.ID, rfq2.ID, orgA.ID)
		q2, err := projectSvc.CreateQuotation(ctx, p.ID, rfq2.ID, orgA.ID, service.QuotationInput{
			SupplierID: sB.ID, QuotationDate: time.Now(),
			Items: []service.QuotationItemInput{{RFQItemID: items2[0].ID, Quantity: 100, UnitPrice: 120}},
		})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := projectSvc.AwardRFQ(ctx, p.ID, rfq2.ID, orgA.ID, "", q2.ID, ""); err != nil {
			t.Fatal(err)
		}
		const attempts = 5
		results := make(chan error, attempts)
		for i := 0; i < attempts; i++ {
			go func() {
				_, err := projectSvc.CreatePurchaseOrder(ctx, p.ID, orgA.ID, poInput(sB.ID, q2.ID))
				results <- err
			}()
		}
		ok := 0
		for i := 0; i < attempts; i++ {
			if err := <-results; err == nil {
				ok++
			} else if !errors.Is(err, service.ErrPurchaseOrderQuotationAlreadyOrdered) {
				t.Errorf("beklenmeyen hata: %v", err)
			}
		}
		if ok != 1 {
			t.Errorf("eşzamanlı isteklerden TAM OLARAK biri sipariş açmalı, geldi %d", ok)
		}
	})

	t.Run("41_po_generated_commitment_cannot_be_voided_by_hand", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		cc := newCostCode(t, orgA.ID, "VOID-CC")
		s := newSupplier(t, orgA.ID, "VOID-S")
		po, err := projectSvc.CreatePurchaseOrder(ctx, p.ID, orgA.ID, service.PurchaseOrderInput{
			SupplierID: s.ID, IssueDate: time.Now(),
			Items: []service.PurchaseOrderItemInput{{CostCodeID: cc.ID, Description: "K", Quantity: 1, UnitPrice: 5000}},
		})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := projectSvc.ApprovePurchaseOrder(ctx, p.ID, po.ID, orgA.ID, ""); err != nil {
			t.Fatal(err)
		}
		commitments, err := projectSvc.ListCommitmentsForPurchaseOrder(ctx, p.ID, po.ID, orgA.ID)
		if err != nil || len(commitments) != 1 {
			t.Fatalf("PO taahhüdü bulunamadı: %v", err)
		}
		if _, err := projectSvc.VoidCommitment(ctx, p.ID, commitments[0].ID, orgA.ID, "", "elle"); !errors.Is(err, service.ErrCommitmentNotManual) {
			t.Fatalf("PO'dan doğan taahhüt elle iptal EDİLEMEMELİ, geldi: %v", err)
		}
		again, _ := projectSvc.ListCommitmentsForPurchaseOrder(ctx, p.ID, po.ID, orgA.ID)
		if again[0].Status != domain.CommitmentStatusActive {
			t.Fatalf("taahhüt aktif kalmalı, geldi %s", again[0].Status)
		}
		manual, err := projectSvc.CreateCommitment(ctx, p.ID, orgA.ID, service.CommitmentInput{
			CostCodeID: cc.ID, Description: "Manuel", CommittedAmount: 100, CommittedAt: time.Now(),
		})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := projectSvc.VoidCommitment(ctx, p.ID, manual.ID, orgA.ID, "", "elle"); err != nil {
			t.Fatalf("manuel taahhüt elle iptal edilebilmeli: %v", err)
		}
	})

	t.Run("42_quotations_not_readable_through_another_project", func(t *testing.T) {
		pA := newProject(t, orgA.ID, 100000)
		pB := newProject(t, orgA.ID, 100000)
		cc := newCostCode(t, orgA.ID, "XPQ-CC")
		pr := newApprovedPR(t, orgA.ID, pB.ID, cc.ID)
		s := newSupplier(t, orgA.ID, "XPQ-S")
		rfq := newIssuedRFQ(t, orgA.ID, pB.ID, pr, []string{s.ID})
		items, _ := projectSvc.ListRFQItems(ctx, pB.ID, rfq.ID, orgA.ID)
		if _, err := projectSvc.CreateQuotation(ctx, pB.ID, rfq.ID, orgA.ID, service.QuotationInput{
			SupplierID: s.ID, QuotationDate: time.Now(),
			Items: []service.QuotationItemInput{{RFQItemID: items[0].ID, Quantity: 10, UnitPrice: 99}},
		}); err != nil {
			t.Fatal(err)
		}
		if list, err := projectSvc.ListQuotations(ctx, pB.ID, rfq.ID, orgA.ID); err != nil || len(list) != 1 {
			t.Fatalf("kendi projesinden teklif okunabilmeli: %v / %d", err, len(list))
		}
		if list, err := projectSvc.ListQuotations(ctx, pA.ID, rfq.ID, orgA.ID); !errors.Is(err, domain.ErrNotFound) {
			t.Fatalf("Proje A URL'sinden B'nin teklifleri okunamamalı (ErrNotFound), geldi: %v / %d kayıt", err, len(list))
		}
		if _, err := projectSvc.GetBidComparison(ctx, pA.ID, rfq.ID, orgA.ID); !errors.Is(err, domain.ErrNotFound) {
			t.Fatalf("Proje A URL'sinden B'nin karşılaştırması okunamamalı, geldi: %v", err)
		}
	})

	t.Run("43_specific_validation_errors", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		cc := newCostCode(t, orgA.ID, "VAL-CC")
		if _, err := projectSvc.CreatePurchaseRequest(ctx, p.ID, orgA.ID, service.PurchaseRequestInput{Title: "  "}); !errors.Is(err, service.ErrTitleRequired) {
			t.Errorf("boş PR başlığı ErrTitleRequired dönmeli, geldi: %v", err)
		}
		if _, err := projectSvc.CreateRFQ(ctx, p.ID, orgA.ID, service.RFQInput{Title: "", IssueDate: time.Now()}); !errors.Is(err, service.ErrTitleRequired) {
			t.Errorf("boş RFQ başlığı ErrTitleRequired dönmeli, geldi: %v", err)
		}
		s := newSupplier(t, orgA.ID, "VAL-S")
		poItems := func(qty, price float64, desc string) []service.PurchaseOrderItemInput {
			return []service.PurchaseOrderItemInput{{CostCodeID: cc.ID, Description: desc, Quantity: qty, UnitPrice: price}}
		}
		if _, err := projectSvc.CreatePurchaseOrder(ctx, p.ID, orgA.ID, service.PurchaseOrderInput{SupplierID: s.ID, IssueDate: time.Now(), Items: poItems(0, 10, "K")}); !errors.Is(err, service.ErrInvalidQuantity) {
			t.Errorf("sıfır miktar ErrInvalidQuantity dönmeli, geldi: %v", err)
		}
		if _, err := projectSvc.CreatePurchaseOrder(ctx, p.ID, orgA.ID, service.PurchaseOrderInput{SupplierID: s.ID, IssueDate: time.Now(), Items: poItems(1, 10, "")}); !errors.Is(err, service.ErrItemDescriptionRequired) {
			t.Errorf("boş açıklama ErrItemDescriptionRequired dönmeli, geldi: %v", err)
		}
		if _, err := projectSvc.CreatePurchaseOrder(ctx, p.ID, orgA.ID, service.PurchaseOrderInput{SupplierID: s.ID, IssueDate: time.Now(), TaxRate: -1, Items: poItems(1, 10, "K")}); !errors.Is(err, service.ErrInvalidTaxRate) {
			t.Errorf("negatif KDV 500 yerine ErrInvalidTaxRate dönmeli, geldi: %v", err)
		}
		pr := newApprovedPR(t, orgA.ID, p.ID, cc.ID)
		rfq := newIssuedRFQ(t, orgA.ID, p.ID, pr, []string{s.ID})
		items, _ := projectSvc.ListRFQItems(ctx, p.ID, rfq.ID, orgA.ID)
		qItems := []service.QuotationItemInput{{RFQItemID: items[0].ID, Quantity: 1, UnitPrice: 10}}
		if _, err := projectSvc.CreateQuotation(ctx, p.ID, rfq.ID, orgA.ID, service.QuotationInput{SupplierID: s.ID, QuotationDate: time.Now(), Discount: -5, Items: qItems}); !errors.Is(err, service.ErrNegativeDiscount) {
			t.Errorf("negatif indirim 500 yerine ErrNegativeDiscount dönmeli, geldi: %v", err)
		}
		if _, err := projectSvc.CreateQuotation(ctx, p.ID, rfq.ID, orgA.ID, service.QuotationInput{SupplierID: s.ID, QuotationDate: time.Now(), TaxRate: -20, Items: qItems}); !errors.Is(err, service.ErrInvalidTaxRate) {
			t.Errorf("negatif KDV 500 yerine ErrInvalidTaxRate dönmeli, geldi: %v", err)
		}
		if _, err := projectSvc.CreateQuotation(ctx, p.ID, rfq.ID, orgA.ID, service.QuotationInput{SupplierID: s.ID, QuotationDate: time.Now(), Items: append(qItems, qItems[0])}); !errors.Is(err, service.ErrQuotationDuplicateItem) {
			t.Errorf("aynı RFQ kalemi iki kez 500 yerine ErrQuotationDuplicateItem dönmeli, geldi: %v", err)
		}
		// Başka bir RFQ'nun kalemi.
		pr2 := newApprovedPR(t, orgA.ID, p.ID, cc.ID)
		rfq2 := newIssuedRFQ(t, orgA.ID, p.ID, pr2, []string{s.ID})
		items2, _ := projectSvc.ListRFQItems(ctx, p.ID, rfq2.ID, orgA.ID)
		if _, err := projectSvc.CreateQuotation(ctx, p.ID, rfq.ID, orgA.ID, service.QuotationInput{
			SupplierID: s.ID, QuotationDate: time.Now(), Items: []service.QuotationItemInput{{RFQItemID: items2[0].ID, Quantity: 1, UnitPrice: 10}},
		}); !errors.Is(err, domain.ErrNotFound) || !strings.Contains(err.Error(), "RFQ kalemi") {
			t.Errorf("başka RFQ'nun kalemi 500 yerine 404 'RFQ kalemi' dönmeli, geldi: %v", err)
		}
		if _, err := projectSvc.CreateCommitment(ctx, p.ID, orgA.ID, service.CommitmentInput{
			CostCodeID: cc.ID, BudgetLineID: "00000000-0000-0000-0000-000000000000", CommittedAmount: 1, CommittedAt: time.Now(),
		}); !errors.Is(err, domain.ErrNotFound) || !strings.Contains(err.Error(), "bütçe kalemi") {
			t.Errorf("geçersiz bütçe kalemi 404 + 'bütçe kalemi' demeli, geldi: %v", err)
		}
	})
}
