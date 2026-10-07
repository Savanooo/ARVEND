package service_test

import (
	"context"
	"errors"
	"testing"

	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

// TestCustomerDuplicatesAndSearch: aynı vergi no/telefonla ikinci müşteri
// uyarı (ErrDuplicateCustomer) üretir, "yine de kaydet" ile açılabilir;
// arama ad dışında telefon, vergi no ve e-postada da çalışır.
func TestCustomerDuplicatesAndSearch(t *testing.T) {
	dbURL := testDBURL(t)
	ctx := context.Background()
	pool, err := repository.NewPool(ctx, dbURL)
	if err != nil {
		t.Fatalf("veritabanına bağlanılamadı: %v", err)
	}
	t.Cleanup(func() { pool.Close() })
	q := sqlc.New(pool)
	orgSvc := service.NewOrganizationService(q)
	customerSvc := service.NewCustomerService(q)
	org := mustCreateOrg(t, ctx, orgSvc, pool, "Müşteri Mükerrer Test", "musteri-mukerrer-test")
	other := mustCreateOrg(t, ctx, orgSvc, pool, "Müşteri Mükerrer Test B", "musteri-mukerrer-test-b")

	base, err := customerSvc.Create(ctx, org.ID, service.CustomerInput{
		Name: "Yılmaz İnşaat", Phone: "+90 (532) 111 22 33", TaxNumber: "123 456 78-90", Email: "info@yilmaz.example",
	})
	if err != nil {
		t.Fatal(err)
	}
	if base.TaxNumber != "1234567890" {
		t.Errorf("vergi no normalize edilerek saklanmalı, gelen %q", base.TaxNumber)
	}

	t.Run("same_tax_number_different_format_is_duplicate", func(t *testing.T) {
		_, err := customerSvc.Create(ctx, org.ID, service.CustomerInput{Name: "Yilmaz Insaat Ltd", TaxNumber: "1234567890"})
		var dup *service.DuplicateCustomerError
		if !errors.Is(err, service.ErrDuplicateCustomer) || !errors.As(err, &dup) {
			t.Fatalf("vergi no çakışması yakalanmalı: %v", err)
		}
		if dup.Field != "tax_number" || dup.Existing.ID != base.ID {
			t.Errorf("çakışan kayıt/alan yanlış: %+v", dup)
		}
	})

	t.Run("same_phone_with_other_prefix_is_duplicate", func(t *testing.T) {
		_, err := customerSvc.Create(ctx, org.ID, service.CustomerInput{Name: "Başka Ad", Phone: "0532 111 2233"})
		var dup *service.DuplicateCustomerError
		if !errors.As(err, &dup) || dup.Field != "phone" || dup.Existing.Name != "Yılmaz İnşaat" {
			t.Fatalf("telefon çakışması yakalanmalı: %v", err)
		}
	})

	t.Run("allow_duplicate_creates_anyway", func(t *testing.T) {
		c, err := customerSvc.Create(ctx, org.ID, service.CustomerInput{Name: "Yılmaz İnşaat Şube 2", TaxNumber: "1234567890", AllowDuplicate: true})
		if err != nil || c.ID == base.ID {
			t.Fatalf("yine de kaydet çalışmalı: %v", err)
		}
	})

	t.Run("other_org_is_not_a_duplicate", func(t *testing.T) {
		if _, err := customerSvc.Create(ctx, other.ID, service.CustomerInput{Name: "Yılmaz İnşaat", TaxNumber: "1234567890", Phone: "05321112233"}); err != nil {
			t.Fatalf("başka firmanın müşterisi çakışma sayılmamalı: %v", err)
		}
	})

	t.Run("update_checks_only_changed_keys", func(t *testing.T) {
		// base ile "Şube 2" zaten aynı vergi no'ya sahip (bilerek açıldı):
		// base'in adresini düzenlemek uyarıya takılmamalı.
		if _, err := customerSvc.Update(ctx, base.ID, org.ID, service.CustomerInput{
			Name: base.Name, Phone: base.Phone, TaxNumber: base.TaxNumber, Email: base.Email, Address: "Yeni adres", IsActive: true,
		}); err != nil {
			t.Fatalf("değişmeyen vergi no ile düzenleme reddedilmemeli: %v", err)
		}
		c, err := customerSvc.Create(ctx, org.ID, service.CustomerInput{Name: "Ayrı Firma", TaxNumber: "9998887776"})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := customerSvc.Update(ctx, c.ID, org.ID, service.CustomerInput{Name: "Ayrı Firma", TaxNumber: "1234567890", IsActive: true}); !errors.Is(err, service.ErrDuplicateCustomer) {
			t.Errorf("başka bir müşterinin vergi no'suna değiştirmek uyarmalı: %v", err)
		}
	})

	t.Run("short_values_are_not_compared", func(t *testing.T) {
		if _, err := customerSvc.Create(ctx, org.ID, service.CustomerInput{Name: "Kısa 1", Phone: "112"}); err != nil {
			t.Fatal(err)
		}
		if _, err := customerSvc.Create(ctx, org.ID, service.CustomerInput{Name: "Kısa 2", Phone: "112"}); err != nil {
			t.Errorf("kısa numaralar çakışma sayılmamalı: %v", err)
		}
	})

	t.Run("search_by_phone_tax_email", func(t *testing.T) {
		for _, term := range []string{"0532 111", "532-111-22", "4567890", "info@yilmaz", "yılmaz"} {
			res, err := customerSvc.List(ctx, org.ID, term, nil)
			if err != nil {
				t.Fatal(err)
			}
			found := false
			for _, c := range res {
				if c.ID == base.ID {
					found = true
				}
			}
			if !found {
				t.Errorf("%q araması Yılmaz İnşaat'ı bulmalı (%d sonuç)", term, len(res))
			}
		}
		res, err := customerSvc.List(ctx, org.ID, "%", nil)
		if err != nil {
			t.Fatal(err)
		}
		if len(res) != 0 {
			t.Errorf("'%%' joker değil düz metin aranmalı: %d sonuç", len(res))
		}
	})
}
