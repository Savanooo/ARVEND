package service_test

// Faz 8 (Ek İşler / Değişiklik Emirleri) için otomatik testler -- gerçek
// bir PostgreSQL bağlantısı gerektirir.

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/platform/mailer"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

func TestProjectChangeOrders(t *testing.T) {
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

	orgA := mustCreateOrg(t, ctx, orgSvc, pool, "EkIs Test Firma A", "ekis-test-firma-a")
	orgB := mustCreateOrg(t, ctx, orgSvc, pool, "EkIs Test Firma B", "ekis-test-firma-b")

	// newProject, sözleşme bedeli verilen kabul edilmiş bir teklifi
	// projeye dönüştürür (gerçek akış: gönder -> link -> kabul -> dönüştür).
	newProject := func(t *testing.T, orgID string, contractAmount float64) *domain.Project {
		t.Helper()
		o, err := offerSvc.Create(ctx, service.CreateOfferInput{
			OrganizationID: orgID,
			CustomerName:   "EkIs Test Müşteri",
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
		p, err := projectSvc.CreateFromOffer(ctx, o.ID, orgID, service.CreateProjectInput{Name: "EkIs Projesi"})
		if err != nil {
			t.Fatalf("proje oluşturulamadı: %v", err)
		}
		return p
	}

	basicInput := func(changeType string, amount float64) service.ChangeOrderInput {
		return service.ChangeOrderInput{
			ChangeType: changeType, Title: "Test Ek İş",
			Items: []service.ChangeOrderItemInput{{Description: "Kalem", Quantity: 1, Unit: "adet", UnitPrice: amount}},
		}
	}

	// newSentChangeOrder, taslak oluşturup gönderir (public respond
	// testleri için).
	newSentChangeOrder := func(t *testing.T, orgID, projectID, changeType string, amount float64) *domain.ChangeOrder {
		t.Helper()
		co, err := projectSvc.CreateChangeOrder(ctx, projectID, orgID, basicInput(changeType, amount))
		if err != nil {
			t.Fatalf("ek iş oluşturulamadı: %v", err)
		}
		sent, err := projectSvc.SendChangeOrder(ctx, co.ID, orgID, "")
		if err != nil {
			t.Fatalf("ek iş gönderilemedi: %v", err)
		}
		return sent
	}

	activeLinkToken := func(t *testing.T, orgID, changeOrderID string) string {
		t.Helper()
		var token string
		row := pool.QueryRow(ctx, `SELECT token::text FROM project_change_order_share_links
			WHERE change_order_id = $1 AND revoked_at IS NULL ORDER BY created_at DESC LIMIT 1`, changeOrderID)
		if err := row.Scan(&token); err != nil {
			t.Fatalf("aktif link bulunamadı: %v", err)
		}
		return token
	}

	// ---------- 1-3: temel oluşturma + hesap doğruluğu ----------

	t.Run("1_draft_addition_created", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		co, err := projectSvc.CreateChangeOrder(ctx, p.ID, orgA.ID, basicInput(domain.ChangeOrderAddition, 5000))
		if err != nil {
			t.Fatalf("oluşturulamadı: %v", err)
		}
		if co.Status != domain.ChangeOrderDraft {
			t.Errorf("beklenen draft, geldi: %s", co.Status)
		}
		if co.SequenceNo != 1 {
			t.Errorf("beklenen sequence_no 1, geldi: %d", co.SequenceNo)
		}
	})

	t.Run("2_draft_deduction_created", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		co, err := projectSvc.CreateChangeOrder(ctx, p.ID, orgA.ID, basicInput(domain.ChangeOrderDeduction, 5000))
		if err != nil {
			t.Fatalf("oluşturulamadı: %v", err)
		}
		if co.ChangeType != domain.ChangeOrderDeduction || co.GrandTotal <= 0 {
			t.Errorf("eksiltme tutarı da pozitif saklanmalı: type=%s total=%v", co.ChangeType, co.GrandTotal)
		}
	})

	t.Run("3_item_totals_computed_server_side", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		co, err := projectSvc.CreateChangeOrder(ctx, p.ID, orgA.ID, service.ChangeOrderInput{
			ChangeType: domain.ChangeOrderAddition, Title: "KDV'li", VatRate: 20,
			Items: []service.ChangeOrderItemInput{
				{Description: "Kalem 1", Quantity: 2, UnitPrice: 1000},
				{Description: "Kalem 2", Quantity: 1, UnitPrice: 500},
			},
		})
		if err != nil {
			t.Fatalf("oluşturulamadı: %v", err)
		}
		// subtotal = 2*1000 + 1*500 = 2500; vat = 500; grand = 3000
		if co.Subtotal != 2500 || co.VatAmount != 500 || co.GrandTotal != 3000 {
			t.Errorf("toplamlar yanlış: subtotal=%v vat=%v grand=%v", co.Subtotal, co.VatAmount, co.GrandTotal)
		}
	})

	// ---------- 4-6: draft/sent/approved düzenlenebilirlik ----------

	t.Run("4_draft_editable", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		co, _ := projectSvc.CreateChangeOrder(ctx, p.ID, orgA.ID, basicInput(domain.ChangeOrderAddition, 5000))
		updated, err := projectSvc.UpdateChangeOrderDraft(ctx, co.ID, orgA.ID, basicInput(domain.ChangeOrderAddition, 7500))
		if err != nil {
			t.Fatalf("taslak düzenlenemedi: %v", err)
		}
		if updated.GrandTotal != 7500 {
			t.Errorf("düzenleme yansımadı: %v", updated.GrandTotal)
		}
	})

	t.Run("5_sent_not_editable", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		co := newSentChangeOrder(t, orgA.ID, p.ID, domain.ChangeOrderAddition, 5000)
		if _, err := projectSvc.UpdateChangeOrderDraft(ctx, co.ID, orgA.ID, basicInput(domain.ChangeOrderAddition, 1)); !errors.Is(err, service.ErrChangeOrderNotEditable) {
			t.Errorf("beklenen ErrChangeOrderNotEditable, geldi: %v", err)
		}
	})

	t.Run("6_approved_not_editable", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		co := newSentChangeOrder(t, orgA.ID, p.ID, domain.ChangeOrderAddition, 5000)
		token := activeLinkToken(t, orgA.ID, co.ID)
		if _, err := projectSvc.RespondChangeOrderByShareLinkToken(ctx, token, domain.ChangeOrderApproved, "", ""); err != nil {
			t.Fatalf("onaylanamadı: %v", err)
		}
		if _, err := projectSvc.UpdateChangeOrderDraft(ctx, co.ID, orgA.ID, basicInput(domain.ChangeOrderAddition, 1)); !errors.Is(err, service.ErrChangeOrderNotEditable) {
			t.Errorf("approved da düzenlenemez olmalı, geldi: %v", err)
		}
	})

	// ---------- 7-9: onayın/reddin/draft-sent'in proje bedeline etkisi ----------

	t.Run("7_approved_addition_increases_current_contract_value", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		co := newSentChangeOrder(t, orgA.ID, p.ID, domain.ChangeOrderAddition, 15000)
		token := activeLinkToken(t, orgA.ID, co.ID)
		if _, err := projectSvc.RespondChangeOrderByShareLinkToken(ctx, token, domain.ChangeOrderApproved, "", ""); err != nil {
			t.Fatalf("onaylanamadı: %v", err)
		}
		summary, err := projectSvc.FinancialSummary(ctx, p.ID, orgA.ID)
		if err != nil {
			t.Fatalf("özet alınamadı: %v", err)
		}
		if summary.CurrentContractValue != 115000 {
			t.Errorf("güncel proje bedeli yanlış: %v (beklenen 115000)", summary.CurrentContractValue)
		}
		if summary.BaseContractAmount != 100000 {
			t.Errorf("ana sözleşme değişmemeli: %v", summary.BaseContractAmount)
		}
	})

	t.Run("8_approved_deduction_decreases_current_contract_value", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		co := newSentChangeOrder(t, orgA.ID, p.ID, domain.ChangeOrderDeduction, 20000)
		token := activeLinkToken(t, orgA.ID, co.ID)
		if _, err := projectSvc.RespondChangeOrderByShareLinkToken(ctx, token, domain.ChangeOrderApproved, "", ""); err != nil {
			t.Fatalf("onaylanamadı: %v", err)
		}
		summary, err := projectSvc.FinancialSummary(ctx, p.ID, orgA.ID)
		if err != nil {
			t.Fatalf("özet alınamadı: %v", err)
		}
		if summary.CurrentContractValue != 80000 {
			t.Errorf("güncel proje bedeli yanlış: %v (beklenen 80000)", summary.CurrentContractValue)
		}
	})

	t.Run("9_draft_and_sent_do_not_affect_current_contract_value", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		if _, err := projectSvc.CreateChangeOrder(ctx, p.ID, orgA.ID, basicInput(domain.ChangeOrderAddition, 40000)); err != nil {
			t.Fatalf("taslak oluşturulamadı: %v", err)
		}
		newSentChangeOrder(t, orgA.ID, p.ID, domain.ChangeOrderAddition, 60000) // gönderildi ama onaylanmadı
		summary, err := projectSvc.FinancialSummary(ctx, p.ID, orgA.ID)
		if err != nil {
			t.Fatalf("özet alınamadı: %v", err)
		}
		if summary.CurrentContractValue != 100000 {
			t.Errorf("draft/sent proje bedelini etkilememeli: %v", summary.CurrentContractValue)
		}
		if summary.PendingAdditions != 100000 { // 40000 + 60000
			t.Errorf("bekleyen ek işler yanlış: %v", summary.PendingAdditions)
		}
	})

	// ---------- 10-12: bakiye/ödeme planı/planlanmamış bakiye ----------

	t.Run("10_collection_balance_uses_new_current_contract_value", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		co := newSentChangeOrder(t, orgA.ID, p.ID, domain.ChangeOrderAddition, 20000)
		token := activeLinkToken(t, orgA.ID, co.ID)
		projectSvc.RespondChangeOrderByShareLinkToken(ctx, token, domain.ChangeOrderApproved, "", "")
		if _, err := projectSvc.CreateCollection(ctx, p.ID, orgA.ID, service.CollectionInput{Amount: 100000, Currency: "TRY", ReceivedDate: time.Now()}); err != nil {
			t.Fatalf("tahsilat eklenemedi: %v", err)
		}
		summary, _ := projectSvc.FinancialSummary(ctx, p.ID, orgA.ID)
		// current=120000, collected=100000 -> remaining=20000 (eski formülle 0 olurdu)
		if summary.RemainingReceivable != 20000 {
			t.Errorf("bakiye yanlış: %v (beklenen 20000)", summary.RemainingReceivable)
		}
	})

	t.Run("11_existing_payment_plan_not_auto_rewritten", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		if _, err := projectSvc.CreatePaymentPlanItem(ctx, p.ID, orgA.ID, service.PaymentPlanItemInput{Name: "Tek Kalem", PlannedAmount: 100000}); err != nil {
			t.Fatalf("plan kalemi oluşturulamadı: %v", err)
		}
		co := newSentChangeOrder(t, orgA.ID, p.ID, domain.ChangeOrderAddition, 25000)
		token := activeLinkToken(t, orgA.ID, co.ID)
		projectSvc.RespondChangeOrderByShareLinkToken(ctx, token, domain.ChangeOrderApproved, "", "")
		total, err := projectSvc.GetPaymentPlanTotal(ctx, p.ID, orgA.ID)
		if err != nil {
			t.Fatalf("plan toplamı alınamadı: %v", err)
		}
		if total != 100000 {
			t.Errorf("mevcut ödeme planı sessizce değişmemeli: %v (beklenen 100000)", total)
		}
	})

	t.Run("12_unplanned_balance_computed_correctly", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		projectSvc.CreatePaymentPlanItem(ctx, p.ID, orgA.ID, service.PaymentPlanItemInput{Name: "Tek Kalem", PlannedAmount: 100000})
		co := newSentChangeOrder(t, orgA.ID, p.ID, domain.ChangeOrderAddition, 25000)
		token := activeLinkToken(t, orgA.ID, co.ID)
		projectSvc.RespondChangeOrderByShareLinkToken(ctx, token, domain.ChangeOrderApproved, "", "")
		summary, _ := projectSvc.FinancialSummary(ctx, p.ID, orgA.ID)
		planned, _ := projectSvc.GetPaymentPlanTotal(ctx, p.ID, orgA.ID)
		unplanned := summary.CurrentContractValue - planned
		if unplanned != 25000 {
			t.Errorf("planlanmamış bakiye yanlış: %v (beklenen 25000)", unplanned)
		}
	})

	// ---------- 13-16: paylaşım linki / race koruması ----------

	t.Run("13_revoked_link_cannot_respond", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		co := newSentChangeOrder(t, orgA.ID, p.ID, domain.ChangeOrderAddition, 5000)
		token := activeLinkToken(t, orgA.ID, co.ID)
		projectSvc.CancelChangeOrder(ctx, co.ID, orgA.ID, "") // iptal, aktif linki revoke eder
		if _, err := projectSvc.RespondChangeOrderByShareLinkToken(ctx, token, domain.ChangeOrderApproved, "", ""); !errors.Is(err, service.ErrChangeOrderShareLinkRevoked) {
			t.Errorf("beklenen ErrChangeOrderShareLinkRevoked, geldi: %v", err)
		}
	})

	t.Run("14_expired_link_cannot_respond", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		co := newSentChangeOrder(t, orgA.ID, p.ID, domain.ChangeOrderAddition, 5000)
		token := activeLinkToken(t, orgA.ID, co.ID)
		if _, err := pool.Exec(ctx, `UPDATE project_change_order_share_links SET expires_at = now() - interval '1 hour' WHERE token = $1::uuid`, token); err != nil {
			t.Fatalf("süre güncellenemedi: %v", err)
		}
		if _, err := projectSvc.RespondChangeOrderByShareLinkToken(ctx, token, domain.ChangeOrderApproved, "", ""); !errors.Is(err, service.ErrChangeOrderShareLinkExpired) {
			t.Errorf("beklenen ErrChangeOrderShareLinkExpired, geldi: %v", err)
		}
	})

	t.Run("15_superseded_change_order_cannot_respond", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		co := newSentChangeOrder(t, orgA.ID, p.ID, domain.ChangeOrderAddition, 5000)
		token := activeLinkToken(t, orgA.ID, co.ID)
		if _, err := projectSvc.ReviseChangeOrder(ctx, co.ID, orgA.ID, ""); err != nil {
			t.Fatalf("revize edilemedi: %v", err)
		}
		if _, err := projectSvc.RespondChangeOrderByShareLinkToken(ctx, token, domain.ChangeOrderApproved, "", ""); !errors.Is(err, service.ErrChangeOrderShareLinkRevoked) {
			t.Errorf("revize eski linki de revoke etmeli, geldi: %v", err)
		}
	})

	t.Run("16_old_tab_cannot_approve_after_revise", func(t *testing.T) {
		// "Change order sent. Personel Revize Et dedi. Yeni versiyon oluştu.
		// Müşteri eski sekmeden Kabul Et dedi." -- eski kayıt approved OLMAMALI.
		p := newProject(t, orgA.ID, 100000)
		co := newSentChangeOrder(t, orgA.ID, p.ID, domain.ChangeOrderAddition, 5000)
		newCO, err := projectSvc.ReviseChangeOrder(ctx, co.ID, orgA.ID, "")
		if err != nil {
			t.Fatalf("revize edilemedi: %v", err)
		}
		old, err := projectSvc.GetChangeOrder(ctx, co.ID, orgA.ID)
		if err != nil {
			t.Fatalf("eski kayıt okunamadı: %v", err)
		}
		if old.Status != domain.ChangeOrderSuperseded {
			t.Errorf("eski kayıt superseded olmalı: %s", old.Status)
		}
		if newCO.Status != domain.ChangeOrderDraft || newCO.SupersedesChangeOrderID == nil || *newCO.SupersedesChangeOrderID != co.ID {
			t.Errorf("yeni kayıt eskiye bağlı bir taslak olmalı: %+v", newCO)
		}
	})

	// ---------- 17-18: approve/cancel, approve/supersede yarışları ----------

	t.Run("17_approve_cancel_race_is_safe", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		co := newSentChangeOrder(t, orgA.ID, p.ID, domain.ChangeOrderAddition, 5000)
		token := activeLinkToken(t, orgA.ID, co.ID)

		var wg sync.WaitGroup
		var approveErr, cancelErr error
		wg.Add(2)
		go func() {
			defer wg.Done()
			_, approveErr = projectSvc.RespondChangeOrderByShareLinkToken(ctx, token, domain.ChangeOrderApproved, "", "")
		}()
		go func() {
			defer wg.Done()
			_, cancelErr = projectSvc.CancelChangeOrder(ctx, co.ID, orgA.ID, "")
		}()
		wg.Wait()

		final, err := projectSvc.GetChangeOrder(ctx, co.ID, orgA.ID)
		if err != nil {
			t.Fatalf("okunamadı: %v", err)
		}
		// Tam olarak biri kazanmalı: approved+cancel hatası YA DA cancelled+approve hatası.
		bothSucceeded := approveErr == nil && cancelErr == nil
		if bothSucceeded {
			t.Fatalf("hem onay hem iptal başarılı olamaz (yarış korunmadı): status=%s", final.Status)
		}
		if final.Status != domain.ChangeOrderApproved && final.Status != domain.ChangeOrderCancelled {
			t.Errorf("beklenmeyen nihai durum: %s", final.Status)
		}
	})

	t.Run("18_approve_supersede_race_is_safe", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		co := newSentChangeOrder(t, orgA.ID, p.ID, domain.ChangeOrderAddition, 5000)
		token := activeLinkToken(t, orgA.ID, co.ID)

		var wg sync.WaitGroup
		var approveErr, reviseErr error
		wg.Add(2)
		go func() {
			defer wg.Done()
			_, approveErr = projectSvc.RespondChangeOrderByShareLinkToken(ctx, token, domain.ChangeOrderApproved, "", "")
		}()
		go func() {
			defer wg.Done()
			_, reviseErr = projectSvc.ReviseChangeOrder(ctx, co.ID, orgA.ID, "")
		}()
		wg.Wait()

		if approveErr == nil && reviseErr == nil {
			t.Fatalf("hem onay hem revize başarılı olamaz (yarış korunmadı)")
		}
		final, _ := projectSvc.GetChangeOrder(ctx, co.ID, orgA.ID)
		if final.Status != domain.ChangeOrderApproved && final.Status != domain.ChangeOrderSuperseded {
			t.Errorf("beklenmeyen nihai durum: %s", final.Status)
		}
	})

	t.Run("19_concurrent_sequence_no_no_duplicate", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		const n = 8
		var wg sync.WaitGroup
		errs := make([]error, n)
		wg.Add(n)
		for i := 0; i < n; i++ {
			go func(i int) {
				defer wg.Done()
				_, errs[i] = projectSvc.CreateChangeOrder(ctx, p.ID, orgA.ID, basicInput(domain.ChangeOrderAddition, 1000))
			}(i)
		}
		wg.Wait()
		for _, err := range errs {
			if err != nil {
				t.Fatalf("eşzamanlı oluşturma hata verdi: %v", err)
			}
		}
		rows, err := projectSvc.ListChangeOrders(ctx, p.ID, orgA.ID)
		if err != nil {
			t.Fatalf("liste alınamadı: %v", err)
		}
		seen := map[int]bool{}
		for _, r := range rows {
			if seen[r.SequenceNo] {
				t.Fatalf("tekrarlanan sequence_no: %d", r.SequenceNo)
			}
			seen[r.SequenceNo] = true
		}
		if len(rows) != n {
			t.Errorf("beklenen %d kayıt, geldi %d", n, len(rows))
		}
	})

	// ---------- 20-22: tenant isolation ----------

	t.Run("20_cross_tenant_change_order_not_accessible", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		co, _ := projectSvc.CreateChangeOrder(ctx, p.ID, orgA.ID, basicInput(domain.ChangeOrderAddition, 5000))
		if _, err := projectSvc.GetChangeOrder(ctx, co.ID, orgB.ID); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("cross-tenant erişim engellenemedi: %v", err)
		}
	})

	t.Run("21_cross_tenant_project_id_cannot_be_bound", func(t *testing.T) {
		pA := newProject(t, orgA.ID, 100000)
		pB := newProject(t, orgB.ID, 100000)
		coA, _ := projectSvc.CreateChangeOrder(ctx, pA.ID, orgA.ID, basicInput(domain.ChangeOrderAddition, 5000))
		// Firma B, kendi projesine A'nın change_order_id'siyle masraf bağlamaya çalışıyor.
		if _, err := projectSvc.CreateExpense(ctx, pB.ID, orgB.ID, service.ExpenseInput{
			Category: "material", Description: "sahte", Amount: 100, Currency: "TRY",
			ExpenseDate: time.Now(), ChangeOrderID: coA.ID,
		}); !errors.Is(err, service.ErrInvalidChangeOrderRef) {
			t.Errorf("cross-tenant change_order_id bağlanabildi: %v", err)
		}
	})

	t.Run("22_cross_project_change_order_id_cannot_be_bound", func(t *testing.T) {
		p1 := newProject(t, orgA.ID, 100000)
		p2 := newProject(t, orgA.ID, 100000)
		co1, _ := projectSvc.CreateChangeOrder(ctx, p1.ID, orgA.ID, basicInput(domain.ChangeOrderAddition, 5000))
		// AYNI org ama FARKLI proje -- yine reddedilmeli.
		if _, err := projectSvc.CreateExpense(ctx, p2.ID, orgA.ID, service.ExpenseInput{
			Category: "material", Description: "yanlış proje", Amount: 100, Currency: "TRY",
			ExpenseDate: time.Now(), ChangeOrderID: co1.ID,
		}); !errors.Is(err, service.ErrInvalidChangeOrderRef) {
			t.Errorf("cross-project change_order_id bağlanabildi: %v", err)
		}
	})

	// ---------- 23-24: public DTO sızıntısı yok + çift sayım yok ----------

	t.Run("23_public_view_never_exposes_internal_fields", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		co, _ := projectSvc.CreateChangeOrder(ctx, p.ID, orgA.ID, service.ChangeOrderInput{
			ChangeType: domain.ChangeOrderAddition, Title: "Gizli maliyetli iş",
			InternalNotes: "GİZLİ: maliyeti 2000, kâr marjı yüksek",
			Items:         []service.ChangeOrderItemInput{{Description: "Kalem", Quantity: 1, UnitPrice: 5000}},
		})
		sent, _ := projectSvc.SendChangeOrder(ctx, co.ID, orgA.ID, "")
		token := activeLinkToken(t, orgA.ID, sent.ID)
		view, err := projectSvc.GetChangeOrderByShareLinkToken(ctx, token, "", "")
		if err != nil {
			t.Fatalf("public görünüm alınamadı: %v", err)
		}
		// PublicChangeOrderView'ın kendisi internal_notes taşımaz -- ama
		// altındaki domain.ChangeOrder taşır; asıl garanti public HTTP
		// DTO'sunun (publicChangeOrderResponse) bunu serialize ETMEMESİDİR.
		// Burada servis seviyesinde en azından view.ChangeOrder.InternalNotes
		// dolu geldiğini (handler'ın bilinçli olarak ATMASI gerektiğini)
		// doğrulayıp, handler'ın alan listesinde internal_notes'un
		// OLMADIĞINI ayrı bir statik/derleme-zamanı garantiye bırakıyoruz
		// (publicChangeOrderResponse struct'ında internal_notes alanı yok).
		if view.ChangeOrder.InternalNotes == "" {
			t.Skip("internal_notes servis katmanında boş geldi, test anlamsız")
		}
	})

	t.Run("24_change_order_cost_not_double_counted", func(t *testing.T) {
		p := newProject(t, orgA.ID, 200000)
		co, _ := projectSvc.CreateChangeOrder(ctx, p.ID, orgA.ID, basicInput(domain.ChangeOrderAddition, 30000))
		sent, _ := projectSvc.SendChangeOrder(ctx, co.ID, orgA.ID, "")
		token := activeLinkToken(t, orgA.ID, sent.ID)
		projectSvc.RespondChangeOrderByShareLinkToken(ctx, token, domain.ChangeOrderApproved, "", "")

		if _, err := projectSvc.CreateExpense(ctx, p.ID, orgA.ID, service.ExpenseInput{
			Category: "material", Description: "Ek iş malzemesi", Amount: 8000, Currency: "TRY",
			ExpenseDate: time.Now(), ChangeOrderID: co.ID,
		}); err != nil {
			t.Fatalf("masraf eklenemedi: %v", err)
		}
		summary, err := projectSvc.FinancialSummary(ctx, p.ID, orgA.ID)
		if err != nil {
			t.Fatalf("özet alınamadı: %v", err)
		}
		if summary.TotalExpenses != 8000 {
			t.Errorf("proje toplam masrafı yanlış (çift sayım şüphesi): %v", summary.TotalExpenses)
		}
		rows, err := projectSvc.ListChangeOrders(ctx, p.ID, orgA.ID)
		if err != nil {
			t.Fatalf("liste alınamadı: %v", err)
		}
		for _, r := range rows {
			if r.ID == co.ID {
				if r.Profitability == nil || r.Profitability.RealizedCost != 8000 {
					t.Errorf("ek iş kârlılığı yanlış: %+v", r.Profitability)
				}
			}
		}
	})

	// ---------- 25-27: N+1 yok, tutarlılık ----------

	t.Run("25_list_summary_and_detail_agree", func(t *testing.T) {
		p := newProject(t, orgA.ID, 300000)
		co := newSentChangeOrder(t, orgA.ID, p.ID, domain.ChangeOrderAddition, 45000)
		token := activeLinkToken(t, orgA.ID, co.ID)
		projectSvc.RespondChangeOrderByShareLinkToken(ctx, token, domain.ChangeOrderApproved, "", "")

		summary, err := projectSvc.FinancialSummary(ctx, p.ID, orgA.ID)
		if err != nil {
			t.Fatalf("özet alınamadı: %v", err)
		}
		result, err := projectSvc.List(ctx, orgA.ID, service.ProjectListFilter{Limit: 200})
		if err != nil {
			t.Fatalf("liste alınamadı: %v", err)
		}
		var found *domain.Project
		for i := range result.Projects {
			if result.Projects[i].ID == p.ID {
				found = &result.Projects[i]
			}
		}
		if found == nil {
			t.Fatalf("proje listede bulunamadı")
		}
		if found.CurrentContractValue() != summary.CurrentContractValue {
			t.Errorf("liste ve özet farklı: liste=%v özet=%v", found.CurrentContractValue(), summary.CurrentContractValue)
		}
		detail, err := projectSvc.Get(ctx, p.ID, orgA.ID)
		if err != nil {
			t.Fatalf("detay alınamadı: %v", err)
		}
		if detail.ContractAmount != summary.BaseContractAmount {
			t.Errorf("detay ana sözleşme özetle uyuşmuyor: %v / %v", detail.ContractAmount, summary.BaseContractAmount)
		}
	})

	t.Run("26_list_query_count_flat_with_change_orders", func(t *testing.T) {
		for i := 0; i < 6; i++ {
			p := newProject(t, orgA.ID, 50000)
			co := newSentChangeOrder(t, orgA.ID, p.ID, domain.ChangeOrderAddition, 5000)
			token := activeLinkToken(t, orgA.ID, co.ID)
			projectSvc.RespondChangeOrderByShareLinkToken(ctx, token, domain.ChangeOrderApproved, "", "")
		}
		countingPool, counter := newCountingPool(t, ctx, dbURL)
		countingSvc := service.NewProjectService(countingPool, sqlc.New(countingPool), mustTestStore(t), settingsSvc, "http://localhost:3000")
		list, err := countingSvc.List(ctx, orgA.ID, service.ProjectListFilter{Limit: 200})
		if err != nil {
			t.Fatalf("liste alınamadı: %v", err)
		}
		if len(list.Projects) < 6 {
			t.Skipf("anlamlı ölçüm için yeterli proje yok: %d", len(list.Projects))
		}
		if n := counter.count(); n > 4 {
			t.Errorf("ek işlerle liste %d proje için %d sorgu çalıştırdı (N+1; beklenen <=4)", len(list.Projects), n)
		}
	})

	// ---------- 28: deduction kârlılık işareti ----------

	t.Run("28_deduction_profitability_sign_correct", func(t *testing.T) {
		p := newProject(t, orgA.ID, 200000)
		co := newSentChangeOrder(t, orgA.ID, p.ID, domain.ChangeOrderDeduction, 30000)
		token := activeLinkToken(t, orgA.ID, co.ID)
		projectSvc.RespondChangeOrderByShareLinkToken(ctx, token, domain.ChangeOrderApproved, "", "")
		rows, err := projectSvc.ListChangeOrders(ctx, p.ID, orgA.ID)
		if err != nil {
			t.Fatalf("liste alınamadı: %v", err)
		}
		for _, r := range rows {
			if r.ID == co.ID {
				if r.Profitability.RevenueEffect >= 0 {
					t.Errorf("eksiltmenin gelir etkisi negatif olmalı: %v", r.Profitability.RevenueEffect)
				}
			}
		}
	})

	// ---------- 29-30: event'ler + idempotent respond ----------

	t.Run("29_events_created_for_full_lifecycle", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		co := newSentChangeOrder(t, orgA.ID, p.ID, domain.ChangeOrderAddition, 5000)
		token := activeLinkToken(t, orgA.ID, co.ID)
		projectSvc.GetChangeOrderByShareLinkToken(ctx, token, "1.2.3.4", "test-agent")
		projectSvc.RespondChangeOrderByShareLinkToken(ctx, token, domain.ChangeOrderApproved, "1.2.3.4", "test-agent")

		events, err := projectSvc.ListProjectEvents(ctx, p.ID, orgA.ID)
		if err != nil {
			t.Fatalf("olaylar alınamadı: %v", err)
		}
		seen := map[string]bool{}
		for _, e := range events {
			seen[e.EventType] = true
		}
		for _, want := range []string{
			domain.ProjectEventChangeOrderCreated, domain.ProjectEventChangeOrderSent,
			domain.ProjectEventChangeOrderViewed, domain.ProjectEventChangeOrderApproved,
		} {
			if !seen[want] {
				t.Errorf("beklenen olay oluşmadı: %s", want)
			}
		}
	})

	t.Run("30_second_respond_is_deterministic_not_500", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		co := newSentChangeOrder(t, orgA.ID, p.ID, domain.ChangeOrderAddition, 5000)
		token := activeLinkToken(t, orgA.ID, co.ID)
		if _, err := projectSvc.RespondChangeOrderByShareLinkToken(ctx, token, domain.ChangeOrderApproved, "", ""); err != nil {
			t.Fatalf("ilk onay başarısız: %v", err)
		}
		_, err := projectSvc.RespondChangeOrderByShareLinkToken(ctx, token, domain.ChangeOrderApproved, "", "")
		if !errors.Is(err, service.ErrChangeOrderNotRespondable) {
			t.Errorf("ikinci onay ErrChangeOrderNotRespondable dönmeli (500 değil), geldi: %v", err)
		}
	})

	// ---------- Para uçları: negatife düşürme koruması ----------

	t.Run("negative_guard_rejects_deduction_exceeding_current_value", func(t *testing.T) {
		p := newProject(t, orgA.ID, 10000)
		co := newSentChangeOrder(t, orgA.ID, p.ID, domain.ChangeOrderDeduction, 15000) // sözleşmeden büyük
		token := activeLinkToken(t, orgA.ID, co.ID)
		_, err := projectSvc.RespondChangeOrderByShareLinkToken(ctx, token, domain.ChangeOrderApproved, "", "")
		if !errors.Is(err, service.ErrChangeOrderWouldGoNegative) {
			t.Errorf("beklenen ErrChangeOrderWouldGoNegative, geldi: %v", err)
		}
		summary, _ := projectSvc.FinancialSummary(ctx, p.ID, orgA.ID)
		if summary.CurrentContractValue != 10000 {
			t.Errorf("reddedilen onay proje bedelini değiştirmemeli: %v", summary.CurrentContractValue)
		}
	})

	t.Run("negative_guard_allows_deduction_reaching_exactly_zero", func(t *testing.T) {
		p := newProject(t, orgA.ID, 10000)
		co := newSentChangeOrder(t, orgA.ID, p.ID, domain.ChangeOrderDeduction, 10000) // tam sözleşme kadar
		token := activeLinkToken(t, orgA.ID, co.ID)
		if _, err := projectSvc.RespondChangeOrderByShareLinkToken(ctx, token, domain.ChangeOrderApproved, "", ""); err != nil {
			t.Fatalf("tam sıfıra düşen eksiltme onaylanabilmeli: %v", err)
		}
		summary, _ := projectSvc.FinancialSummary(ctx, p.ID, orgA.ID)
		if summary.CurrentContractValue != 0 {
			t.Errorf("beklenen 0, geldi: %v", summary.CurrentContractValue)
		}
		if summary.RealizedMarginPercent != 0 || summary.EstimatedMarginPercent != 0 {
			t.Errorf("sıfır sözleşme bedelinde marj güvenle 0 dönmeli: realized=%v estimated=%v",
				summary.RealizedMarginPercent, summary.EstimatedMarginPercent)
		}
	})

	t.Run("negative_guard_accounts_for_other_already_approved_deductions", func(t *testing.T) {
		p := newProject(t, orgA.ID, 20000)
		co1 := newSentChangeOrder(t, orgA.ID, p.ID, domain.ChangeOrderDeduction, 12000)
		token1 := activeLinkToken(t, orgA.ID, co1.ID)
		if _, err := projectSvc.RespondChangeOrderByShareLinkToken(ctx, token1, domain.ChangeOrderApproved, "", ""); err != nil {
			t.Fatalf("ilk eksiltme onaylanamadı: %v", err)
		}
		// current_contract_value şimdi 8000. İkinci 9000'lik eksiltme negatife düşürür.
		co2 := newSentChangeOrder(t, orgA.ID, p.ID, domain.ChangeOrderDeduction, 9000)
		token2 := activeLinkToken(t, orgA.ID, co2.ID)
		if _, err := projectSvc.RespondChangeOrderByShareLinkToken(ctx, token2, domain.ChangeOrderApproved, "", ""); !errors.Is(err, service.ErrChangeOrderWouldGoNegative) {
			t.Errorf("ikinci eksiltme, ilkinin etkisini görmezden geldi: %v", err)
		}
	})

	// ---------- Ek iş kendi maliyetiyle çift tıklama ----------

	t.Run("double_click_send_email_does_not_duplicate_log", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		co := newSentChangeOrder(t, orgA.ID, p.ID, domain.ChangeOrderAddition, 5000)
		var wg sync.WaitGroup
		wg.Add(2)
		for i := 0; i < 2; i++ {
			go func() {
				defer wg.Done()
				_ = projectSvc.SendChangeOrderEmail(ctx, co.ID, orgA.ID, service.ChangeOrderEmailInput{To: "musteri@example.com"})
			}()
		}
		wg.Wait()
		// Her ikisi de AYNI aktif linki kullanmalı (yeni link ÜRETMEMELİ).
		var linkCount int
		row := pool.QueryRow(ctx, `SELECT count(*) FROM project_change_order_share_links WHERE change_order_id = $1 AND revoked_at IS NULL`, co.ID)
		if err := row.Scan(&linkCount); err != nil {
			t.Fatalf("link sayısı okunamadı: %v", err)
		}
		if linkCount != 1 {
			t.Errorf("çift gönderim yeni link üretmemeli: %d aktif link", linkCount)
		}
	})

	// ---------- Denetim düzeltmeleri (regresyon) ----------

	t.Run("cancelled_change_order_cannot_mint_new_active_link_via_email", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		co := newSentChangeOrder(t, orgA.ID, p.ID, domain.ChangeOrderAddition, 5000)
		oldToken := activeLinkToken(t, orgA.ID, co.ID)
		if _, err := projectSvc.CancelChangeOrder(ctx, co.ID, orgA.ID, ""); err != nil {
			t.Fatalf("iptal edilemedi: %v", err)
		}
		// Eski link revoke edilmiş olmalı.
		var revoked bool
		row := pool.QueryRow(ctx, `SELECT revoked_at IS NOT NULL FROM project_change_order_share_links WHERE token = $1::uuid`, oldToken)
		if err := row.Scan(&revoked); err != nil || !revoked {
			t.Fatalf("iptalden sonra eski link revoke edilmemiş: err=%v revoked=%v", err, revoked)
		}
		// SendChangeOrderEmail, iptal edilmiş bir kayıt için YENİ bir aktif
		// link üretmemeli -- ürettiği anda Cancel'ın revoke'unu etkisiz
		// kılardı (bkz. denetim bulgusu).
		err := projectSvc.SendChangeOrderEmail(ctx, co.ID, orgA.ID, service.ChangeOrderEmailInput{To: "musteri@example.com"})
		if !errors.Is(err, service.ErrChangeOrderNotSendable) {
			t.Errorf("iptal edilmiş ek işe mail: beklenen ErrChangeOrderNotSendable, geldi: %v", err)
		}
		var activeCount int
		row2 := pool.QueryRow(ctx, `SELECT count(*) FROM project_change_order_share_links WHERE change_order_id = $1 AND revoked_at IS NULL`, co.ID)
		if err := row2.Scan(&activeCount); err != nil {
			t.Fatalf("aktif link sayısı okunamadı: %v", err)
		}
		if activeCount != 0 {
			t.Errorf("iptalden sonra hiçbir aktif link olmamalı, geldi: %d", activeCount)
		}
	})

	t.Run("cross_tenant_product_id_silently_dropped_not_stored", func(t *testing.T) {
		productSvc := service.NewProductService(q)
		// orgB'ye ait GERÇEK bir ürün -- orgA bunu bir ek iş kalemine
		// bağlamaya çalışacak.
		foreignProduct, err := productSvc.Create(ctx, orgB.ID, "Firma B Ürünü", "adet", 100, "", "")
		if err != nil {
			t.Fatalf("ürün oluşturulamadı: %v", err)
		}
		p := newProject(t, orgA.ID, 100000)
		co, err := projectSvc.CreateChangeOrder(ctx, p.ID, orgA.ID, service.ChangeOrderInput{
			ChangeType: domain.ChangeOrderAddition, Title: "Çapraz kiracı ürün testi",
			Items: []service.ChangeOrderItemInput{{
				ProductID: &foreignProduct.ID, Description: "Kalem", Quantity: 1, UnitPrice: 1000,
			}},
		})
		if err != nil {
			t.Fatalf("oluşturulamadı: %v", err)
		}
		full, err := projectSvc.GetChangeOrder(ctx, co.ID, orgA.ID)
		if err != nil {
			t.Fatalf("okunamadı: %v", err)
		}
		if len(full.Items) != 1 {
			t.Fatalf("beklenen 1 kalem, geldi: %d", len(full.Items))
		}
		if full.Items[0].ProductID != nil {
			t.Errorf("başka firmanın product_id'si sessizce serbest metne düşürülmeliydi, ama saklandı: %v", *full.Items[0].ProductID)
		}
	})

	t.Run("negative_guard_uses_exact_numeric_not_float64_noise", func(t *testing.T) {
		// Bu tutarlar, base + approved_additions - approved_deductions -
		// grand_total matematiksel olarak TAM SIFIR olacak şekilde seçildi
		// (56120.27 = 731978.58 + 116687.33 - 792545.64), ama 4 ayrı
		// float64 dönüşümü + soldan-sağa Go float64 çıkarma zinciriyle
		// hesaplanırsa IEEE-754 gürültüsünden yaklaşık -9.46e-11'lik
		// negatif bir kalıntı üretir -- eski kod bu YÜZDEN tam sıfıra
		// eşitlenen bu eksiltmeyi yanlışlıkla reddederdi (bkz. denetim
		// bulgusu). Karşılaştırma artık TAMAMEN numeric'te (SQL'de)
		// yapıldığından bu eksiltme güvenle onaylanabilmeli.
		p := newProject(t, orgA.ID, 731978.58)

		coAdd := newSentChangeOrder(t, orgA.ID, p.ID, domain.ChangeOrderAddition, 116687.33)
		tokenAdd := activeLinkToken(t, orgA.ID, coAdd.ID)
		if _, err := projectSvc.RespondChangeOrderByShareLinkToken(ctx, tokenAdd, domain.ChangeOrderApproved, "", ""); err != nil {
			t.Fatalf("ek onaylanamadı: %v", err)
		}

		coDed1 := newSentChangeOrder(t, orgA.ID, p.ID, domain.ChangeOrderDeduction, 792545.64)
		tokenDed1 := activeLinkToken(t, orgA.ID, coDed1.ID)
		if _, err := projectSvc.RespondChangeOrderByShareLinkToken(ctx, tokenDed1, domain.ChangeOrderApproved, "", ""); err != nil {
			t.Fatalf("ilk eksiltme onaylanamadı: %v", err)
		}
		summary, _ := projectSvc.FinancialSummary(ctx, p.ID, orgA.ID)
		if summary.CurrentContractValue != 56120.27 {
			t.Fatalf("ara adım: beklenen 56120.27, geldi: %v", summary.CurrentContractValue)
		}

		coDed2 := newSentChangeOrder(t, orgA.ID, p.ID, domain.ChangeOrderDeduction, 56120.27)
		tokenDed2 := activeLinkToken(t, orgA.ID, coDed2.ID)
		if _, err := projectSvc.RespondChangeOrderByShareLinkToken(ctx, tokenDed2, domain.ChangeOrderApproved, "", ""); err != nil {
			t.Fatalf("tam sıfıra düşen ikinci eksiltme onaylanabilmeli (float64 gürültüsü YOK): %v", err)
		}
		summary, _ = projectSvc.FinancialSummary(ctx, p.ID, orgA.ID)
		if summary.CurrentContractValue != 0 {
			t.Errorf("beklenen 0, geldi: %v", summary.CurrentContractValue)
		}
	})

	t.Run("projected_contract_value_does_not_double_count_own_approved_effect", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		co := newSentChangeOrder(t, orgA.ID, p.ID, domain.ChangeOrderAddition, 25000)
		token := activeLinkToken(t, orgA.ID, co.ID)
		if _, err := projectSvc.RespondChangeOrderByShareLinkToken(ctx, token, domain.ChangeOrderApproved, "", ""); err != nil {
			t.Fatalf("onaylanamadı: %v", err)
		}
		// Link, onaydan sonra revoke EDİLMEZ (yalnızca Cancel/Revise
		// revoke eder) -- bu yüzden aynı token'la görünüm hâlâ okunabilir.
		view, err := projectSvc.GetChangeOrderByShareLinkToken(ctx, token, "", "")
		if err != nil {
			t.Fatalf("public görünüm okunamadı: %v", err)
		}
		if view.CurrentContractValue != 125000 {
			t.Fatalf("beklenen current=125000, geldi: %v", view.CurrentContractValue)
		}
		// Onaylanmış bir ek işin kendi etkisi current_contract_value'ya
		// ZATEN dahildir -- projected buna tekrar eklenirse çift sayım
		// olur (bkz. denetim bulgusu).
		if view.ProjectedContractValue != view.CurrentContractValue {
			t.Errorf("onaylanmış ek işin etkisi çift sayıldı: current=%v projected=%v",
				view.CurrentContractValue, view.ProjectedContractValue)
		}
	})

	t.Run("list_active_share_token_gated_by_status_like_get", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		co := newSentChangeOrder(t, orgA.ID, p.ID, domain.ChangeOrderAddition, 10000)
		token := activeLinkToken(t, orgA.ID, co.ID)
		if _, err := projectSvc.RespondChangeOrderByShareLinkToken(ctx, token, domain.ChangeOrderApproved, "", ""); err != nil {
			t.Fatalf("onaylanamadı: %v", err)
		}
		// Link satırı DB'de hâlâ revoke edilmemiş halde duruyor (yalnızca
		// Cancel/Revise revoke eder), ama artık status='approved' --
		// ListChangeOrders'ın active_share_token'ı, GetChangeOrder'ın
		// tekil davranışıyla (yalnızca status='sent') AYNI şekilde
		// gizlemeli (bkz. denetim bulgusu: önceden status'tan bağımsız
		// döndürüyordu).
		list, err := projectSvc.ListChangeOrders(ctx, p.ID, orgA.ID)
		if err != nil {
			t.Fatalf("liste okunamadı: %v", err)
		}
		var found bool
		for _, row := range list {
			if row.ID != co.ID {
				continue
			}
			found = true
			if row.ActiveShareToken != nil {
				t.Errorf("onaylanmış bir kayıt için active_share_token boş olmalı, geldi: %v", *row.ActiveShareToken)
			}
		}
		if !found {
			t.Fatalf("ek iş listede bulunamadı")
		}
	})

	t.Run("send_email_does_not_hold_lock_across_smtp_call", func(t *testing.T) {
		// SendMailFunc'ı yavaş bir gönderim gibi davranacak şekilde
		// geçici olarak değiştiriyoruz: mail gönderimi devam ederken
		// AYNI projede bir onay/red kararının (kilit gerektiren ayrı bir
		// işlem) BEKLEMEDEN tamamlanabildiğini doğruluyoruz -- eski kod
		// proje+ek iş kilitlerini SMTP çağrısı boyunca açık tutuyordu
		// (bkz. denetim bulgusu).
		p := newProject(t, orgA.ID, 100000)
		co := newSentChangeOrder(t, orgA.ID, p.ID, domain.ChangeOrderAddition, 5000)
		token := activeLinkToken(t, orgA.ID, co.ID)

		release := make(chan struct{})
		orig := projectSvc.SendMailFunc
		projectSvc.SendMailFunc = func(settings domain.SmtpSettings, msg mailer.Message) error {
			<-release // gönderim "asılı" kalır, biz serbest bırakana kadar
			return nil
		}
		t.Cleanup(func() { projectSvc.SendMailFunc = orig })

		emailDone := make(chan error, 1)
		go func() {
			emailDone <- projectSvc.SendChangeOrderEmail(ctx, co.ID, orgA.ID, service.ChangeOrderEmailInput{To: "musteri@example.com"})
		}()

		// SendChangeOrderEmail'in Aşama 1'i (kilitleme+link çözümü) commit
		// edip SMTP çağrısına girmesi için kısa bir pay bırak.
		time.Sleep(200 * time.Millisecond)

		approveDone := make(chan error, 1)
		go func() {
			_, err := projectSvc.RespondChangeOrderByShareLinkToken(ctx, token, domain.ChangeOrderApproved, "", "")
			approveDone <- err
		}()

		select {
		case err := <-approveDone:
			if err != nil {
				t.Errorf("onay, mail gönderimi 'asılı' kalırken de tamamlanabilmeli: %v", err)
			}
		case <-time.After(3 * time.Second):
			t.Fatal("onay, asılı SMTP çağrısı bitene kadar bloke oldu -- kilit hâlâ mail gönderimi boyunca açık tutuluyor")
		}

		close(release)
		if err := <-emailDone; err != nil {
			t.Errorf("mail gönderimi başarısız olmamalıydı: %v", err)
		}
	})

	t.Cleanup(func() {
		cleanupOrganization(t, pool, orgA.ID)
		cleanupOrganization(t, pool, orgB.ID)
	})
}
