package service_test

// Bu dosya, OnboardingService'in server-authoritative, forward-only
// (asla geriletmeyen) adım ilerlemesini VE tamamlama idempotentliğini
// gerçek bir PostgreSQL bağlantısına karşı doğrular (DB_URL yoksa atlanır).

import (
	"context"
	"testing"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

func strPtr(s string) *string { return &s }

func TestOnboardingService_ResumeAndIdempotentComplete(t *testing.T) {
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
	onboardingSvc := service.NewOnboardingService(q, box)

	org := mustCreateOrg(t, ctx, orgSvc, pool, "Onboarding Test Firma", "onboarding-test-firma")

	// --- Taze bir organizasyon: adım 'company', tamamlanmamış ---
	st, err := onboardingSvc.GetState(ctx, org.ID)
	if err != nil {
		t.Fatalf("GetState başarısız: %v", err)
	}
	if st.OnboardingCompleted {
		t.Fatalf("taze organizasyon zaten tamamlanmış görünüyor")
	}
	if st.OnboardingStep != domain.OnboardingStepCompany {
		t.Fatalf("onboarding_step = %q, want company", st.OnboardingStep)
	}
	if st.Profile.AuthorizedPerson != "" {
		t.Fatalf("taze organizasyonun profili boş değil: %+v", st.Profile)
	}

	// --- Adım 1: Firma ---
	st, err = onboardingSvc.SaveCompanyStep(ctx, org.ID, service.CompanyStepInput{
		AuthorizedPerson: "Ayşe Yılmaz", Phone: "5551234567", City: "İstanbul",
	})
	if err != nil {
		t.Fatalf("SaveCompanyStep başarısız: %v", err)
	}
	if st.OnboardingStep != domain.OnboardingStepBilling {
		t.Fatalf("company sonrası onboarding_step = %q, want billing", st.OnboardingStep)
	}

	// --- RESUME: yeni bir GetState çağrısı (ör. sayfa yenilendi) AYNI
	// durumu döner -- ayrı bir web/mobil state yok.
	resumed, err := onboardingSvc.GetState(ctx, org.ID)
	if err != nil {
		t.Fatalf("resume GetState başarısız: %v", err)
	}
	if resumed.OnboardingStep != domain.OnboardingStepBilling || resumed.Profile.AuthorizedPerson != "Ayşe Yılmaz" {
		t.Fatalf("resume edilen durum beklenenle uyuşmuyor: %+v", resumed)
	}

	// --- Adım 1'i TEKRAR gönder (kullanıcı geri gidip düzenledi) ---
	// onboarding_step GERİLEMEMELİ (hâlâ billing, company'ye dönmemeli).
	st, err = onboardingSvc.SaveCompanyStep(ctx, org.ID, service.CompanyStepInput{
		AuthorizedPerson: "Ayşe Yılmaz (güncellendi)", Phone: "5551234567", City: "Ankara",
	})
	if err != nil {
		t.Fatalf("SaveCompanyStep (tekrar) başarısız: %v", err)
	}
	if st.OnboardingStep != domain.OnboardingStepBilling {
		t.Fatalf("company adımını tekrar düzenlemek onboarding_step'i geriletti: %q, want billing", st.OnboardingStep)
	}
	if st.Profile.City != "Ankara" {
		t.Fatalf("company adımının verisi güncellenmedi: city=%q", st.Profile.City)
	}

	// --- Adım 2: Resmi/Fatura ---
	st, err = onboardingSvc.SaveBillingStep(ctx, org.ID, service.BillingStepInput{
		LegalName: "Test Firma Ltd. Şti.", TaxOffice: "Kadıköy", TaxNumber: "1234567890", InvoiceAddress: "Test Mah. Test Sok. No:1",
	})
	if err != nil {
		t.Fatalf("SaveBillingStep başarısız: %v", err)
	}
	if st.OnboardingStep != domain.OnboardingStepOffers {
		t.Fatalf("billing sonrası onboarding_step = %q, want offers", st.OnboardingStep)
	}
	// Adım 1'in verisi, adım 2 kaydedilirken KAYBOLMAMALI.
	if st.Profile.AuthorizedPerson != "Ayşe Yılmaz (güncellendi)" {
		t.Fatalf("billing adımı, company adımının verisini sildi: %+v", st.Profile)
	}

	// --- Adım 3: Teklif ---
	st, err = onboardingSvc.SaveOffersStep(ctx, org.ID, service.OffersStepInput{
		OfferPrefix: "ABC", OfferValidityDays: 45, DefaultVATRate: 18,
	})
	if err != nil {
		t.Fatalf("SaveOffersStep başarısız: %v", err)
	}
	if st.OnboardingStep != domain.OnboardingStepFinance {
		t.Fatalf("offers sonrası onboarding_step = %q, want finance", st.OnboardingStep)
	}
	if st.Commercial.OfferPrefix != "ABC" || st.Commercial.OfferValidityDays != 45 {
		t.Fatalf("offers adımının verisi yanlış kaydedildi: %+v", st.Commercial)
	}

	// --- Adım 4: Finans (IBAN şifrelenmeli, yanıtta ASLA plaintext dönmemeli) ---
	st, err = onboardingSvc.SaveFinanceStep(ctx, org.ID, service.FinanceStepInput{
		BankName: "Test Bank", AccountHolder: "Test Firma", IBAN: strPtr("TR330006100519786457841326"),
	})
	if err != nil {
		t.Fatalf("SaveFinanceStep başarısız: %v", err)
	}
	if st.OnboardingStep != domain.OnboardingStepBusiness {
		t.Fatalf("finance sonrası onboarding_step = %q, want business", st.OnboardingStep)
	}
	if !st.Commercial.IBANSet {
		t.Fatalf("IBANSet = false, want true")
	}
	if st.Commercial.IBAN != "" {
		t.Fatalf("GetState/SaveFinanceStep yanıtında plaintext IBAN sızdı: %q", st.Commercial.IBAN)
	}
	// offer_prefix (adım 3), finans adımı kaydedilirken KAYBOLMAMALI.
	if st.Commercial.OfferPrefix != "ABC" {
		t.Fatalf("finance adımı, offers adımının verisini sildi: %+v", st.Commercial)
	}

	// --- Adım 5: İşletme + TAMAMLAMA ---
	st, err = onboardingSvc.SaveBusinessStep(ctx, org.ID, service.BusinessStepInput{BusinessType: "insaat_taahhut"})
	if err != nil {
		t.Fatalf("SaveBusinessStep başarısız: %v", err)
	}
	if !st.OnboardingCompleted {
		t.Fatalf("business adımından sonra onboarding_completed = false, want true")
	}
	if st.OnboardingStep != domain.OnboardingStepCompleted {
		t.Fatalf("onboarding_step = %q, want completed", st.OnboardingStep)
	}

	// --- İDEMPOTENT TAMAMLAMA: adım 5'i TEKRAR göndermek (ör. kullanıcı
	// onboarding sonrası "Firma Ayarları"ndan business_type'ı değiştirir)
	// zararsız olmalı -- hata YOK, hâlâ tamamlanmış.
	st, err = onboardingSvc.SaveBusinessStep(ctx, org.ID, service.BusinessStepInput{BusinessType: "diger"})
	if err != nil {
		t.Fatalf("idempotent SaveBusinessStep (tekrar tamamlama) başarısız: %v", err)
	}
	if !st.OnboardingCompleted || st.OnboardingStep != domain.OnboardingStepCompleted {
		t.Fatalf("tekrar tamamlama sonrası durum bozuldu: completed=%v step=%q", st.OnboardingCompleted, st.OnboardingStep)
	}
	if st.Profile.BusinessType != "diger" {
		t.Fatalf("tekrar tamamlama, business_type'ı güncellemedi: %q", st.Profile.BusinessType)
	}

	t.Run("invalid business_type rejected", func(t *testing.T) {
		if _, err := onboardingSvc.SaveBusinessStep(ctx, org.ID, service.BusinessStepInput{BusinessType: "gecersiz-tur"}); err == nil {
			t.Errorf("geçersiz business_type kabul edildi, hata bekleniyordu")
		}
	})

	t.Cleanup(func() { cleanupOrganization(t, pool, org.ID) })
}

// TestOnboardingService_ResumeFromPartialState, "resume" gereksinimini
// açıkça iki AYRI adımdan sonra bırakılmış bir organizasyon üzerinde test
// eder -- GetState, kaldığı adımı VE o ana kadar girilen kısmi veriyi doğru
// döndürmeli.
func TestOnboardingService_ResumeFromPartialState(t *testing.T) {
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
	onboardingSvc := service.NewOnboardingService(q, box)

	org := mustCreateOrg(t, ctx, orgSvc, pool, "Onboarding Resume Test Firma", "onboarding-resume-test-firma")
	t.Cleanup(func() { cleanupOrganization(t, pool, org.ID) })

	if _, err := onboardingSvc.SaveCompanyStep(ctx, org.ID, service.CompanyStepInput{AuthorizedPerson: "Kaldığı Yer Testi"}); err != nil {
		t.Fatalf("SaveCompanyStep başarısız: %v", err)
	}
	if _, err := onboardingSvc.SaveBillingStep(ctx, org.ID, service.BillingStepInput{LegalName: "X Ltd.", TaxNumber: "999"}); err != nil {
		t.Fatalf("SaveBillingStep başarısız: %v", err)
	}

	// Burada "oturum kapandı", yeni bir istek (ör. mobil uygulama yeniden
	// açıldı) yalnızca GetState çağırır.
	st, err := onboardingSvc.GetState(ctx, org.ID)
	if err != nil {
		t.Fatalf("GetState başarısız: %v", err)
	}
	if st.OnboardingStep != domain.OnboardingStepOffers {
		t.Fatalf("kaldığı adım = %q, want offers (2 adım tamamlandı)", st.OnboardingStep)
	}
	if st.Profile.AuthorizedPerson != "Kaldığı Yer Testi" || st.Profile.LegalName != "X Ltd." {
		t.Fatalf("kısmi veri korunmadı: %+v", st.Profile)
	}
	if st.OnboardingCompleted {
		t.Fatalf("2 adımlık kısmi ilerleme yanlışlıkla 'tamamlanmış' işaretlenmiş")
	}
}
