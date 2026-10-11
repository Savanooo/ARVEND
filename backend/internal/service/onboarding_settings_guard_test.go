package service_test

// Firma Ayarları kayıt korumaları:
//   - Firmanın kendi IBAN'ı (Finans) doğrulanır: teklif PDF'inde müşteriye
//     gider ama hiçbir ekranda geri okunamaz; eskiden yazım hatası
//     kırpılıp saklanıyordu.
//   - Teklif adımında gönderilmeyen (boş) para birimi mevcut değeri korur:
//     eskiden boş değer TRY'ye dönüyordu.
//
// Gerçek bir PostgreSQL bağlantısı gerektirir (DB_URL yoksa atlanır).

import (
	"context"
	"errors"
	"testing"

	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

func TestOnboardingFinanceIBANValidation(t *testing.T) {
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

	org := mustCreateOrg(t, ctx, orgSvc, pool, "Firma IBAN Test", "firma-iban-test")

	storedIBAN := func(t *testing.T) string {
		t.Helper()
		var enc string
		if err := pool.QueryRow(ctx,
			"SELECT iban_enc FROM organization_commercial_settings WHERE organization_id = $1", org.ID,
		).Scan(&enc); err != nil {
			t.Fatal(err)
		}
		if enc == "" {
			return ""
		}
		plain, err := box.Decrypt(enc)
		if err != nil {
			t.Fatal(err)
		}
		return plain
	}

	t.Run("eksik haneli IBAN reddedilir, hiçbir alan yazılmaz", func(t *testing.T) {
		_, err := onboardingSvc.SaveFinanceStep(ctx, org.ID, service.FinanceStepInput{
			BankName: "Yanlış Banka", IBAN: strPtr("TR12 0006 1234"),
		})
		if !errors.Is(err, service.ErrOrganizationInvalidIBAN) {
			t.Fatalf("geçersiz IBAN reddedilmeli: %v", err)
		}
		st, err := onboardingSvc.GetState(ctx, org.ID)
		if err != nil {
			t.Fatal(err)
		}
		if st.Commercial.IBANSet || st.Commercial.BankName == "Yanlış Banka" {
			t.Fatalf("reddedilen kayıt yazılmamalı: %+v", st.Commercial)
		}
	})

	t.Run("boşluklu/küçük harfli geçerli IBAN normalize edilip saklanır", func(t *testing.T) {
		st, err := onboardingSvc.SaveFinanceStep(ctx, org.ID, service.FinanceStepInput{
			BankName: "Ziraat", IBAN: strPtr(" tr33 0006 1005 1978 6457 8413 26 "),
		})
		if err != nil {
			t.Fatalf("geçerli IBAN kabul edilmeli: %v", err)
		}
		if !st.Commercial.IBANSet {
			t.Fatal("IBAN kaydedilmeli")
		}
		if got := storedIBAN(t); got != "TR330006100519786457841326" {
			t.Fatalf("IBAN normalize edilmiş saklanmalı: %q", got)
		}
	})

	t.Run("kontrol basamağı tutmayan IBAN kayıtlı IBAN'ı ezmez", func(t *testing.T) {
		_, err := onboardingSvc.SaveFinanceStep(ctx, org.ID, service.FinanceStepInput{
			BankName: "Ziraat", IBAN: strPtr("TR330006100519786457841327"),
		})
		if !errors.Is(err, service.ErrOrganizationInvalidIBAN) {
			t.Fatalf("kontrol basamağı tutmayan IBAN reddedilmeli: %v", err)
		}
		if got := storedIBAN(t); got != "TR330006100519786457841326" {
			t.Fatalf("kayıtlı IBAN korunmalı: %q", got)
		}
	})

	t.Run("IBAN gönderilmezse korunur, boş metin temizler", func(t *testing.T) {
		st, err := onboardingSvc.SaveFinanceStep(ctx, org.ID, service.FinanceStepInput{BankName: "Ziraat Bankası"})
		if err != nil || !st.Commercial.IBANSet || st.Commercial.BankName != "Ziraat Bankası" {
			t.Fatalf("gönderilmeyen IBAN korunmalı: %+v err=%v", st, err)
		}
		st, err = onboardingSvc.SaveFinanceStep(ctx, org.ID, service.FinanceStepInput{BankName: "Ziraat Bankası", IBAN: strPtr("  ")})
		if err != nil || st.Commercial.IBANSet {
			t.Fatalf("boş IBAN temizlemeli: %+v err=%v", st, err)
		}
	})
}

func TestOnboardingOffersKeepsCurrency(t *testing.T) {
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

	org := mustCreateOrg(t, ctx, orgSvc, pool, "Firma Para Birimi Test", "firma-para-birimi-test")

	save := func(t *testing.T, currency, footer string) string {
		t.Helper()
		st, err := onboardingSvc.SaveOffersStep(ctx, org.ID, service.OffersStepInput{
			DefaultCurrency: currency, DefaultVATRate: 20, OfferPrefix: "TKF", OfferValidityDays: 30,
			DefaultOfferFooter: footer,
		})
		if err != nil {
			t.Fatal(err)
		}
		if st.Commercial.DefaultOfferFooter != footer {
			t.Fatalf("alt not kaydedilmeli: %q", st.Commercial.DefaultOfferFooter)
		}
		return st.Commercial.DefaultCurrency
	}

	if got := save(t, "", "ilk"); got != "TRY" {
		t.Fatalf("hiç kayıt yokken boş para birimi TRY olmalı: %q", got)
	}
	if got := save(t, "EUR", "ikinci"); got != "EUR" {
		t.Fatalf("EUR kaydedilmeli: %q", got)
	}
	// Alanı göndermeyen istemci (yalnızca alt notu değiştirdi): EUR korunur.
	if got := save(t, "  ", "üçüncü"); got != "EUR" {
		t.Fatalf("gönderilmeyen para birimi mevcut EUR'yu korumalı: %q", got)
	}
	if got := save(t, "USD", "dördüncü"); got != "USD" {
		t.Fatalf("USD kaydedilmeli: %q", got)
	}
}
