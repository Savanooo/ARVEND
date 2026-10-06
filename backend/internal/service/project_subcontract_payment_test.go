package service_test

// ARVEND V2 -- Sprint 5 follow-up (Taşeron Ödemeleri, bkz. migration 0039)
// için otomatik testler -- gerçek bir PostgreSQL bağlantısı gerektirir (bkz.
// tenant_isolation_test.go'daki paylaşılan yardımcılar). subcontract_test.go
// İLE AYNI fixture desenini kullanır.

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

func TestSubcontractPayments(t *testing.T) {
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

	orgA := mustCreateOrg(t, ctx, orgSvc, pool, "Taşeron Ödeme Test Firma A", "taseron-odeme-test-firma-a")
	orgB := mustCreateOrg(t, ctx, orgSvc, pool, "Taşeron Ödeme Test Firma B", "taseron-odeme-test-firma-b")

	newProject := func(t *testing.T, orgID string, contractAmount float64) *domain.Project {
		t.Helper()
		o, err := offerSvc.Create(ctx, service.CreateOfferInput{
			OrganizationID: orgID, CustomerName: "Taşeron Ödeme Test Müşteri", VatRate: ptrFloat(0),
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
		p, err := projectSvc.CreateFromOffer(ctx, o.ID, orgID, service.CreateProjectInput{Name: "Taşeron Ödeme Test Projesi"})
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

	basicPayment := func(orgID, projectID, subcontractID string, amount float64) service.SubcontractPaymentInput {
		return service.SubcontractPaymentInput{
			Amount: amount, Currency: "TRY", PaidDate: time.Now(), PaymentMethod: "Havale", UserID: "",
		}
	}

	t.Run("1_happy_path_paid_to_date_and_remaining_payable", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		cc := newCostCode(t, orgA.ID, "P1-CC")
		s := newSupplier(t, orgA.ID, "P1-S")
		sc := newActiveSubcontract(t, orgA.ID, p.ID, s.ID, cc.ID, 50000)

		pay, err := projectSvc.CreateSubcontractPayment(ctx, p.ID, sc.ID, orgA.ID, basicPayment(orgA.ID, p.ID, sc.ID, 20000))
		if err != nil {
			t.Fatalf("ödeme oluşturulamadı: %v", err)
		}
		if pay.Amount != 20000 {
			t.Fatalf("ödeme tutarı 20000 olmalı, geldi %v", pay.Amount)
		}

		val, err := projectSvc.GetSubcontractValue(ctx, p.ID, sc.ID, orgA.ID)
		if err != nil {
			t.Fatalf("değer özeti alınamadı: %v", err)
		}
		if val.PaidToDate != 20000 {
			t.Fatalf("PaidToDate 20000 olmalı, geldi %v", val.PaidToDate)
		}
		// Hiç hakediş sertifika edilmedi -- CertifiedToDate 0, RemainingPayable
		// = 0 - 20000 = -20000 (avans imzası, KESİNLİKLE 0'a kelepçelenmez).
		if val.CertifiedToDate != 0 {
			t.Fatalf("hiç hakediş yokken CertifiedToDate 0 olmalı, geldi %v", val.CertifiedToDate)
		}
		if val.RemainingPayable != -20000 {
			t.Fatalf("RemainingPayable = CertifiedToDate - PaidToDate = -20000 olmalı (avans sinyali), geldi %v", val.RemainingPayable)
		}
		// RemainingCommitment (CurrentValue - CertifiedToDate) ödemeden
		// KESİNLİKLE ETKİLENMEMELİ -- iki eksen bağımsızdır.
		if val.RemainingCommitment != 50000 {
			t.Fatalf("RemainingCommitment ödemeden ETKİLENMEMELİ (50000 kalmalı), geldi %v", val.RemainingCommitment)
		}
	})

	t.Run("2_invalid_amount_rejected", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		cc := newCostCode(t, orgA.ID, "P2-CC")
		s := newSupplier(t, orgA.ID, "P2-S")
		sc := newActiveSubcontract(t, orgA.ID, p.ID, s.ID, cc.ID, 10000)
		if _, err := projectSvc.CreateSubcontractPayment(ctx, p.ID, sc.ID, orgA.ID, basicPayment(orgA.ID, p.ID, sc.ID, 0)); !errors.Is(err, service.ErrInvalidAmount) {
			t.Fatalf("sıfır tutar REDDEDİLMELİ, geldi: %v", err)
		}
		if _, err := projectSvc.CreateSubcontractPayment(ctx, p.ID, sc.ID, orgA.ID, basicPayment(orgA.ID, p.ID, sc.ID, -100)); !errors.Is(err, service.ErrInvalidAmount) {
			t.Fatalf("negatif tutar REDDEDİLMELİ, geldi: %v", err)
		}
	})

	t.Run("3_draft_and_cancelled_subcontract_not_payable", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		cc := newCostCode(t, orgA.ID, "P3-CC")
		s := newSupplier(t, orgA.ID, "P3-S")
		draft := newDraftSubcontract(t, orgA.ID, p.ID, s.ID, cc.ID, 10000)
		if _, err := projectSvc.CreateSubcontractPayment(ctx, p.ID, draft.ID, orgA.ID, basicPayment(orgA.ID, p.ID, draft.ID, 1000)); !errors.Is(err, service.ErrSubcontractNotPayable) {
			t.Fatalf("DRAFT sözleşmeye ödeme REDDEDİLMELİ, geldi: %v", err)
		}

		draft2 := newDraftSubcontract(t, orgA.ID, p.ID, s.ID, cc.ID, 10000)
		cancelled, err := projectSvc.CancelSubcontract(ctx, p.ID, draft2.ID, orgA.ID, "", "test iptali")
		if err != nil {
			t.Fatalf("iptal edilemedi: %v", err)
		}
		if _, err := projectSvc.CreateSubcontractPayment(ctx, p.ID, cancelled.ID, orgA.ID, basicPayment(orgA.ID, p.ID, cancelled.ID, 1000)); !errors.Is(err, service.ErrSubcontractNotPayable) {
			t.Fatalf("CANCELLED sözleşmeye ödeme REDDEDİLMELİ, geldi: %v", err)
		}
	})

	t.Run("4_completed_and_terminated_subcontract_still_payable", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		cc := newCostCode(t, orgA.ID, "P4-CC")
		s := newSupplier(t, orgA.ID, "P4-S")
		sc := newActiveSubcontract(t, orgA.ID, p.ID, s.ID, cc.ID, 10000)
		completed, err := projectSvc.CompleteSubcontract(ctx, p.ID, sc.ID, orgA.ID, "")
		if err != nil {
			t.Fatalf("tamamlanamadı: %v", err)
		}
		if _, err := projectSvc.CreateSubcontractPayment(ctx, p.ID, completed.ID, orgA.ID, basicPayment(orgA.ID, p.ID, completed.ID, 1000)); err != nil {
			t.Fatalf("COMPLETED sözleşmeye ödeme İZİN VERİLMELİ (final ödemeler), geldi: %v", err)
		}

		sc2 := newActiveSubcontract(t, orgA.ID, p.ID, s.ID, cc.ID, 10000)
		terminated, err := projectSvc.TerminateSubcontract(ctx, p.ID, sc2.ID, orgA.ID, "", "test feshi")
		if err != nil {
			t.Fatalf("feshedilemedi: %v", err)
		}
		if _, err := projectSvc.CreateSubcontractPayment(ctx, p.ID, terminated.ID, orgA.ID, basicPayment(orgA.ID, p.ID, terminated.ID, 1000)); err != nil {
			t.Fatalf("TERMINATED sözleşmeye ödeme İZİN VERİLMELİ (sertifikalı kısım ödenmeli), geldi: %v", err)
		}
	})

	t.Run("5_idempotency_key_dedupes_within_subcontract", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		cc := newCostCode(t, orgA.ID, "P5-CC")
		s := newSupplier(t, orgA.ID, "P5-S")
		sc := newActiveSubcontract(t, orgA.ID, p.ID, s.ID, cc.ID, 10000)
		in := basicPayment(orgA.ID, p.ID, sc.ID, 5000)
		in.IdempotencyKey = "sabit-anahtar-5"
		first, err := projectSvc.CreateSubcontractPayment(ctx, p.ID, sc.ID, orgA.ID, in)
		if err != nil {
			t.Fatalf("ilk ödeme oluşturulamadı: %v", err)
		}
		second, err := projectSvc.CreateSubcontractPayment(ctx, p.ID, sc.ID, orgA.ID, in)
		if err != nil {
			t.Fatalf("ikinci (aynı anahtarlı) çağrı hata VERMEMELİ: %v", err)
		}
		if first.ID != second.ID {
			t.Fatalf("aynı idempotency_key AYNI kaydı döndürmeli, farklı ID'ler geldi: %s vs %s", first.ID, second.ID)
		}
		val, err := projectSvc.GetSubcontractValue(ctx, p.ID, sc.ID, orgA.ID)
		if err != nil {
			t.Fatalf("değer özeti alınamadı: %v", err)
		}
		if val.PaidToDate != 5000 {
			t.Fatalf("tekrarlı istek İKİNCİ bir ödeme YARATMAMALI, PaidToDate 5000 olmalı, geldi %v", val.PaidToDate)
		}
	})

	t.Run("6_void_then_double_void", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		cc := newCostCode(t, orgA.ID, "P6-CC")
		s := newSupplier(t, orgA.ID, "P6-S")
		sc := newActiveSubcontract(t, orgA.ID, p.ID, s.ID, cc.ID, 10000)
		pay, err := projectSvc.CreateSubcontractPayment(ctx, p.ID, sc.ID, orgA.ID, basicPayment(orgA.ID, p.ID, sc.ID, 3000))
		if err != nil {
			t.Fatalf("ödeme oluşturulamadı: %v", err)
		}
		if _, err := projectSvc.VoidSubcontractPayment(ctx, p.ID, pay.ID, orgA.ID, "", "hatalı kayıt"); err != nil {
			t.Fatalf("iptal edilemedi: %v", err)
		}
		val, err := projectSvc.GetSubcontractValue(ctx, p.ID, sc.ID, orgA.ID)
		if err != nil {
			t.Fatalf("değer özeti alınamadı: %v", err)
		}
		if val.PaidToDate != 0 {
			t.Fatalf("iptal edilen ödeme PaidToDate'e DAHİL EDİLMEMELİ, geldi %v", val.PaidToDate)
		}
		if _, err := projectSvc.VoidSubcontractPayment(ctx, p.ID, pay.ID, orgA.ID, "", "tekrar"); !errors.Is(err, service.ErrAlreadyVoided) {
			t.Fatalf("ikinci iptal ErrAlreadyVoided DÖNMELİ, geldi: %v", err)
		}
		if _, err := projectSvc.VoidSubcontractPayment(ctx, p.ID, "00000000-0000-0000-0000-000000000000", orgA.ID, "", "yok"); !errors.Is(err, domain.ErrNotFound) {
			t.Fatalf("olmayan bir ödeme ErrNotFound DÖNMELİ, geldi: %v", err)
		}
	})

	t.Run("7_progress_claim_link_must_belong_to_same_subcontract_and_be_certified", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		cc := newCostCode(t, orgA.ID, "P7-CC")
		s := newSupplier(t, orgA.ID, "P7-S")
		sc := newActiveSubcontract(t, orgA.ID, p.ID, s.ID, cc.ID, 10000)
		otherSc := newActiveSubcontract(t, orgA.ID, p.ID, s.ID, cc.ID, 10000)

		items, err := projectSvc.ListSubcontractItems(ctx, p.ID, sc.ID, orgA.ID)
		if err != nil || len(items) == 0 {
			t.Fatalf("SOV kalemleri alınamadı: %v", err)
		}
		otherItems, err := projectSvc.ListSubcontractItems(ctx, p.ID, otherSc.ID, orgA.ID)
		if err != nil || len(otherItems) == 0 {
			t.Fatalf("diğer sözleşmenin SOV kalemleri alınamadı: %v", err)
		}

		draftClaim, err := projectSvc.CreateProgressClaim(ctx, p.ID, sc.ID, orgA.ID, service.ProgressClaimInput{
			PeriodEnd: time.Now(), UserID: "",
			Items: []service.ProgressClaimItemInput{{SubcontractItemID: items[0].ID, CurrentProgressAmount: 1000}},
		})
		if err != nil {
			t.Fatalf("hakediş oluşturulamadı: %v", err)
		}
		in := basicPayment(orgA.ID, p.ID, sc.ID, 1000)
		in.ProgressClaimID = draftClaim.ID
		if _, err := projectSvc.CreateSubcontractPayment(ctx, p.ID, sc.ID, orgA.ID, in); !errors.Is(err, service.ErrSubcontractPaymentClaimInvalid) {
			t.Fatalf("DRAFT (henüz sertifika edilmemiş) bir hakedişe bağlı ödeme REDDEDİLMELİ, geldi: %v", err)
		}

		otherClaim, err := projectSvc.CreateProgressClaim(ctx, p.ID, otherSc.ID, orgA.ID, service.ProgressClaimInput{
			PeriodEnd: time.Now(), UserID: "",
			Items: []service.ProgressClaimItemInput{{SubcontractItemID: otherItems[0].ID, CurrentProgressAmount: 1000}},
		})
		if err != nil {
			t.Fatalf("diğer sözleşmenin hakedişi oluşturulamadı: %v", err)
		}
		in2 := basicPayment(orgA.ID, p.ID, sc.ID, 1000)
		in2.ProgressClaimID = otherClaim.ID
		if _, err := projectSvc.CreateSubcontractPayment(ctx, p.ID, sc.ID, orgA.ID, in2); !errors.Is(err, service.ErrSubcontractPaymentClaimInvalid) {
			t.Fatalf("BAŞKA bir sözleşmenin hakedişine bağlı ödeme REDDEDİLMELİ, geldi: %v", err)
		}
	})

	t.Run("9_total_payments_cannot_exceed_current_contract_value", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		cc := newCostCode(t, orgA.ID, "P9-CC")
		s := newSupplier(t, orgA.ID, "P9-S")
		sc := newActiveSubcontract(t, orgA.ID, p.ID, s.ID, cc.ID, 1000)

		_, err := projectSvc.CreateSubcontractPayment(ctx, p.ID, sc.ID, orgA.ID, basicPayment(orgA.ID, p.ID, sc.ID, 21000))
		if !errors.Is(err, service.ErrPaymentExceedsContract) {
			t.Fatalf("sözleşme bedelini aşan ödeme reddedilmeli, geldi %v", err)
		}
		if !strings.Contains(err.Error(), "taşeron değişikliği") {
			t.Errorf("mesaj fazlası için ne yapılacağını söylemeli: %q", err.Error())
		}
		if _, err := projectSvc.CreateSubcontractPayment(ctx, p.ID, sc.ID, orgA.ID, basicPayment(orgA.ID, p.ID, sc.ID, 1000)); err != nil {
			t.Fatalf("tam bedel ödenebilir: %v", err)
		}

		// Onaylı ek (değişiklik emri) sınırı yükseltir.
		co, err := projectSvc.CreateSubcontractChangeOrder(ctx, p.ID, sc.ID, orgA.ID, service.SubcontractChangeOrderInput{
			Title: "Ek iş", ChangeType: "addition", Reason: "Ek kat",
			Items: []service.SubcontractChangeOrderItemInput{{CostCodeID: cc.ID, Description: "Ek", Amount: 500}},
		})
		if err != nil {
			t.Fatalf("değişiklik oluşturulamadı: %v", err)
		}
		if _, err := projectSvc.SubmitSubcontractChangeOrder(ctx, p.ID, co.ID, orgA.ID, ""); err != nil {
			t.Fatal(err)
		}
		if _, err := projectSvc.CreateSubcontractPayment(ctx, p.ID, sc.ID, orgA.ID, basicPayment(orgA.ID, p.ID, sc.ID, 500)); !errors.Is(err, service.ErrPaymentExceedsContract) {
			t.Errorf("onaylanmamış ek sınırı yükseltmez: %v", err)
		}
		if _, err := projectSvc.ApproveSubcontractChangeOrder(ctx, p.ID, co.ID, orgA.ID, ""); err != nil {
			t.Fatal(err)
		}
		if _, err := projectSvc.CreateSubcontractPayment(ctx, p.ID, sc.ID, orgA.ID, basicPayment(orgA.ID, p.ID, sc.ID, 500)); err != nil {
			t.Errorf("onaylı ekten sonra ödenebilir: %v", err)
		}
	})

	t.Run("10_claim_linked_payment_capped_at_claim_net_payable", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		cc := newCostCode(t, orgA.ID, "P10-CC")
		s := newSupplier(t, orgA.ID, "P10-S")
		sc := newActiveSubcontract(t, orgA.ID, p.ID, s.ID, cc.ID, 100000)
		items, err := projectSvc.ListSubcontractItems(ctx, p.ID, sc.ID, orgA.ID)
		if err != nil || len(items) == 0 {
			t.Fatalf("SOV kalemleri alınamadı: %v", err)
		}
		// Gross 10.000,10 -- %5 teminat (500,01) => net 9.500,09.
		retention := 5.0
		claim, err := projectSvc.CreateProgressClaim(ctx, p.ID, sc.ID, orgA.ID, service.ProgressClaimInput{
			PeriodEnd: time.Now(), RetentionPercent: &retention,
			Items: []service.ProgressClaimItemInput{{SubcontractItemID: items[0].ID, CurrentProgressAmount: 10000.10}},
		})
		if err != nil {
			t.Fatalf("hakediş oluşturulamadı: %v", err)
		}
		if _, err := projectSvc.SubmitProgressClaim(ctx, p.ID, claim.ID, orgA.ID, ""); err != nil {
			t.Fatal(err)
		}
		certified, err := projectSvc.CertifyProgressClaim(ctx, p.ID, claim.ID, orgA.ID, "")
		if err != nil {
			t.Fatal(err)
		}
		if certified.NetPayable != 9500.09 {
			t.Fatalf("net ödenecek 9500.09 olmalı, geldi %v", certified.NetPayable)
		}

		over := basicPayment(orgA.ID, p.ID, sc.ID, 50000)
		over.ProgressClaimID = claim.ID
		_, err = projectSvc.CreateSubcontractPayment(ctx, p.ID, sc.ID, orgA.ID, over)
		if !errors.Is(err, service.ErrPaymentExceedsClaim) {
			t.Fatalf("hakedişin net tutarını aşan bağlı ödeme reddedilmeli, geldi %v", err)
		}
		if !strings.Contains(err.Error(), claim.ClaimNumber) {
			t.Errorf("mesaj hakedişi adıyla anmalı: %q", err.Error())
		}

		first := basicPayment(orgA.ID, p.ID, sc.ID, 9000)
		first.ProgressClaimID = claim.ID
		if _, err := projectSvc.CreateSubcontractPayment(ctx, p.ID, sc.ID, orgA.ID, first); err != nil {
			t.Fatalf("net tutarın altındaki bağlı ödeme kabul edilmeli: %v", err)
		}
		// Kalan 500,09; 500,10 bir kuruş fazla.
		tooMuch := basicPayment(orgA.ID, p.ID, sc.ID, 500.10)
		tooMuch.ProgressClaimID = claim.ID
		if _, err := projectSvc.CreateSubcontractPayment(ctx, p.ID, sc.ID, orgA.ID, tooMuch); !errors.Is(err, service.ErrPaymentExceedsClaim) {
			t.Fatalf("bir kuruş fazlası da reddedilmeli, geldi %v", err)
		}
		exact := basicPayment(orgA.ID, p.ID, sc.ID, 500.09)
		exact.ProgressClaimID = claim.ID
		pay, err := projectSvc.CreateSubcontractPayment(ctx, p.ID, sc.ID, orgA.ID, exact)
		if err != nil {
			t.Fatalf("kalan tutarın tamamı ödenebilmeli: %v", err)
		}
		// İptal edilen ödeme sınırdan düşer.
		if _, err := projectSvc.VoidSubcontractPayment(ctx, p.ID, pay.ID, orgA.ID, "", "hatalı"); err != nil {
			t.Fatal(err)
		}
		if _, err := projectSvc.CreateSubcontractPayment(ctx, p.ID, sc.ID, orgA.ID, exact); err != nil {
			t.Fatalf("iptal edilen ödemenin yeri yeniden kullanılabilmeli: %v", err)
		}
		// Hakedişe bağlı OLMAYAN (avans) ödeme bu sınıra takılmaz, yalnızca
		// sözleşme bedeline takılır.
		if _, err := projectSvc.CreateSubcontractPayment(ctx, p.ID, sc.ID, orgA.ID, basicPayment(orgA.ID, p.ID, sc.ID, 20000)); err != nil {
			t.Fatalf("bağımsız avans ödemesi kabul edilmeli: %v", err)
		}
	})

	t.Run("8_cross_tenant_isolation", func(t *testing.T) {
		p := newProject(t, orgA.ID, 100000)
		cc := newCostCode(t, orgA.ID, "P8-CC")
		s := newSupplier(t, orgA.ID, "P8-S")
		sc := newActiveSubcontract(t, orgA.ID, p.ID, s.ID, cc.ID, 10000)

		// Org B, Org A'nın proje/sözleşme kimliklerini BİLSE bile hiçbir
		// şey göremez/değiştiremez.
		if _, err := projectSvc.CreateSubcontractPayment(ctx, p.ID, sc.ID, orgB.ID, basicPayment(orgB.ID, p.ID, sc.ID, 1000)); !errors.Is(err, domain.ErrNotFound) {
			t.Fatalf("çapraz-org ödeme oluşturma ErrNotFound DÖNMELİ, geldi: %v", err)
		}
		if _, err := projectSvc.ListSubcontractPayments(ctx, p.ID, sc.ID, orgB.ID); err != nil {
			t.Fatalf("çapraz-org listeleme hata VERMEMELİ, boş dönmeli: %v", err)
		} else if list, _ := projectSvc.ListSubcontractPayments(ctx, p.ID, sc.ID, orgB.ID); len(list) != 0 {
			t.Fatalf("çapraz-org listeleme BOŞ dönmeli, %d kayıt geldi", len(list))
		}

		pay, err := projectSvc.CreateSubcontractPayment(ctx, p.ID, sc.ID, orgA.ID, basicPayment(orgA.ID, p.ID, sc.ID, 1000))
		if err != nil {
			t.Fatalf("A org ödeme oluşturamadı: %v", err)
		}
		if _, err := projectSvc.VoidSubcontractPayment(ctx, p.ID, pay.ID, orgB.ID, "", "çapraz-org"); !errors.Is(err, domain.ErrNotFound) {
			t.Fatalf("çapraz-org iptal ErrNotFound DÖNMELİ, geldi: %v", err)
		}
	})
}
