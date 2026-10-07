package service_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

// TestOfferDefaultsFromCompanySettings: onboarding'in "Teklif" adımında
// kaydedilen KDV/para birimi/geçerlilik süresi yeni tekliflerde kullanılır;
// istekte açıkça gönderilen değerler (0 KDV, "süresiz" dahil) korunur.
// Eskiden bu ayarlar kaydediliyor ama teklifler %20 / TRY / süresiz
// açılıyordu.
func TestOfferDefaultsFromCompanySettings(t *testing.T) {
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
	offerSvc := service.NewOfferService(pool, q, service.NewSettingsService(q, box), "http://localhost:3000")

	items := []service.OfferItemInput{{ProductName: "Alçıpan", Quantity: 2, UnitPrice: 100}}
	istDay := func(offsetDays int) string {
		n := time.Now().In(service.IstanbulLocation())
		return time.Date(n.Year(), n.Month(), n.Day()+offsetDays, 0, 0, 0, 0, time.UTC).Format("2006-01-02")
	}
	day := func(p *time.Time) string {
		if p == nil {
			return "<yok>"
		}
		return p.Format("2006-01-02")
	}
	f64 := func(v float64) *float64 { return &v }
	str := func(s string) *string { return &s }

	t.Run("ayar_yoksa_yuzde20_TRY_suresiz", func(t *testing.T) {
		org := mustCreateOrg(t, ctx, orgSvc, pool, "Varsayılan Yok", "teklif-varsayilan-yok")
		d, err := offerSvc.OfferDefaults(ctx, org.ID)
		if err != nil {
			t.Fatal(err)
		}
		if d.VATRate != 20 || d.Currency != "TRY" || d.ValidityDays != nil {
			t.Fatalf("ayar yokken 20/TRY/nil bekleniyordu: %+v", d)
		}
		o, err := offerSvc.Create(ctx, service.CreateOfferInput{OrganizationID: org.ID, CustomerName: "M", Items: items})
		if err != nil {
			t.Fatal(err)
		}
		if o.VatRate != 20 || o.Currency != "TRY" || o.ValidUntil != nil {
			t.Fatalf("teklif 20/TRY/süresiz açılmalı: vat=%v cur=%q until=%s", o.VatRate, o.Currency, day(o.ValidUntil))
		}
	})

	org := mustCreateOrg(t, ctx, orgSvc, pool, "Varsayılan Var", "teklif-varsayilan-var")
	if _, err := onboardingSvc.SaveOffersStep(ctx, org.ID, service.OffersStepInput{
		DefaultCurrency: "usd", DefaultVATRate: 10, OfferValidityDays: 45,
		DefaultPaymentTerms: "%50 peşin", DefaultDeliveryTerms: "2 hafta", DefaultOfferFooter: "Teşekkürler",
	}); err != nil {
		t.Fatalf("teklif ayarları kaydedilemedi: %v", err)
	}

	t.Run("uc_firma_ayarini_doner", func(t *testing.T) {
		d, err := offerSvc.OfferDefaults(ctx, org.ID)
		if err != nil {
			t.Fatal(err)
		}
		if d.VATRate != 10 || d.Currency != "USD" || d.ValidityDays == nil || *d.ValidityDays != 45 {
			t.Fatalf("firma ayarı dönmeli: %+v", d)
		}
		if d.PaymentTerms != "%50 peşin" || d.DeliveryTerms != "2 hafta" || d.Footer != "Teşekkürler" {
			t.Fatalf("koşullar dönmeli: %+v", d)
		}
	})

	t.Run("gonderilmeyen_alanlar_firma_ayarindan", func(t *testing.T) {
		o, err := offerSvc.Create(ctx, service.CreateOfferInput{OrganizationID: org.ID, CustomerName: "M", Items: items})
		if err != nil {
			t.Fatal(err)
		}
		if o.VatRate != 10 || o.VatAmount != 20 || o.GrandTotal != 220 {
			t.Errorf("KDV %%10 uygulanmalı: oran=%v kdv=%v toplam=%v", o.VatRate, o.VatAmount, o.GrandTotal)
		}
		if o.Currency != "USD" {
			t.Errorf("para birimi USD olmalı: %q", o.Currency)
		}
		if got, want := day(o.ValidUntil), istDay(45); got != want {
			t.Errorf("geçerlilik bugün+45 olmalı: %s, istenen %s", got, want)
		}
		// Kalıcı mı: tekrar okununca da aynı.
		got, err := offerSvc.Get(ctx, o.ID, org.ID)
		if err != nil {
			t.Fatal(err)
		}
		if got.Currency != "USD" || day(got.ValidUntil) != istDay(45) {
			t.Errorf("okunan teklif: cur=%q until=%s", got.Currency, day(got.ValidUntil))
		}
	})

	t.Run("gonderilen_degerler_korunur", func(t *testing.T) {
		explicit := time.Now().In(service.IstanbulLocation()).AddDate(0, 0, 7)
		o, err := offerSvc.Create(ctx, service.CreateOfferInput{
			OrganizationID: org.ID, CustomerName: "M", Items: items,
			VatRate: f64(0), Currency: str("eur"), ValidUntil: &explicit, ValidUntilProvided: true,
		})
		if err != nil {
			t.Fatal(err)
		}
		if o.VatRate != 0 || o.VatAmount != 0 {
			t.Errorf("açıkça 0 gönderilen KDV korunmalı: %v", o.VatRate)
		}
		if o.Currency != "EUR" {
			t.Errorf("gönderilen para birimi korunmalı: %q", o.Currency)
		}
		if day(o.ValidUntil) != istDay(7) {
			t.Errorf("gönderilen tarih korunmalı: %s", day(o.ValidUntil))
		}

		open, err := offerSvc.Create(ctx, service.CreateOfferInput{
			OrganizationID: org.ID, CustomerName: "M", Items: items, ValidUntilProvided: true,
		})
		if err != nil {
			t.Fatal(err)
		}
		if open.ValidUntil != nil {
			t.Errorf("bilerek boş gönderilen tarih süresiz kalmalı: %s", day(open.ValidUntil))
		}
	})

	t.Run("gecersiz_para_birimi_reddedilir", func(t *testing.T) {
		_, err := offerSvc.Create(ctx, service.CreateOfferInput{
			OrganizationID: org.ID, CustomerName: "M", Items: items, Currency: str("EURO"),
		})
		if !errors.Is(err, service.ErrInvalidOfferCurrency) {
			t.Fatalf("ErrInvalidOfferCurrency bekleniyordu: %v", err)
		}
	})

	t.Run("duzenlemede_gonderilmeyen_KDV_korunur", func(t *testing.T) {
		o, err := offerSvc.Create(ctx, service.CreateOfferInput{
			OrganizationID: org.ID, CustomerName: "M", Items: items, VatRate: f64(18),
		})
		if err != nil {
			t.Fatal(err)
		}
		updated, err := offerSvc.Update(ctx, o.ID, org.ID, service.UpdateOfferInput{CustomerName: "M", Items: items})
		if err != nil {
			t.Fatal(err)
		}
		if updated.VatRate != 18 {
			t.Errorf("KDV gönderilmeyince mevcut oran (18) korunmalı, gelen %v", updated.VatRate)
		}
	})

	t.Run("bozuk_kayitli_deger_guvenli_varsayilana_duser", func(t *testing.T) {
		bad := mustCreateOrg(t, ctx, orgSvc, pool, "Bozuk Ayar", "teklif-varsayilan-bozuk")
		if _, err := pool.Exec(ctx, `INSERT INTO organization_commercial_settings
			(organization_id, default_currency, default_vat_rate, offer_validity_days)
			VALUES ($1, 'tl', 150, 0)`, bad.ID); err != nil {
			t.Fatal(err)
		}
		d, err := offerSvc.OfferDefaults(ctx, bad.ID)
		if err != nil {
			t.Fatal(err)
		}
		if d.VATRate != 20 || d.Currency != "TRY" || d.ValidityDays != nil {
			t.Fatalf("aralık dışı KDV %%20'ye, 'tl' TRY'ye, 0 gün süresize düşmeli: %+v", d)
		}
		if _, err := offerSvc.Create(ctx, service.CreateOfferInput{OrganizationID: bad.ID, CustomerName: "M", Items: items}); err != nil {
			t.Fatalf("bozuk ayar teklif oluşturmayı engellememeli: %v", err)
		}
	})
}
