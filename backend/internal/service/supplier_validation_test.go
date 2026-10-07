package service_test

import (
	"context"
	"errors"
	"testing"

	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

// TestSupplierValidation: güncellemede unvan boş bırakılamaz; aynı firmada
// aynı vergi numarasıyla ikinci tedarikçi açılamaz (biçim farkı önemsiz).
func TestSupplierValidation(t *testing.T) {
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
	supplierSvc := service.NewSupplierService(pool, q, box)
	org := mustCreateOrg(t, ctx, orgSvc, pool, "Tedarikçi Doğrulama Test", "tedarikci-dogrulama-test")
	other := mustCreateOrg(t, ctx, orgSvc, pool, "Tedarikçi Doğrulama Test B", "tedarikci-dogrulama-test-b")

	s1, err := supplierSvc.Create(ctx, org.ID, service.SupplierInput{Code: "T1", LegalName: "Demir A.Ş.", TaxNumber: "111 222 33-44"})
	if err != nil {
		t.Fatal(err)
	}
	if s1.TaxNumber != "1112223344" {
		t.Errorf("vergi no normalize edilerek saklanmalı: %q", s1.TaxNumber)
	}

	t.Run("update_rejects_empty_legal_name", func(t *testing.T) {
		if _, err := supplierSvc.Update(ctx, s1.ID, org.ID, service.SupplierInput{LegalName: "   ", TaxNumber: s1.TaxNumber}); !errors.Is(err, service.ErrSupplierLegalNameRequired) {
			t.Fatalf("boş unvan reddedilmeli: %v", err)
		}
		got, err := supplierSvc.Get(ctx, s1.ID, org.ID)
		if err != nil || got.LegalName != "Demir A.Ş." {
			t.Errorf("unvan değişmemeli: %+v err=%v", got, err)
		}
	})

	t.Run("duplicate_tax_number_rejected", func(t *testing.T) {
		_, err := supplierSvc.Create(ctx, org.ID, service.SupplierInput{Code: "T2", LegalName: "Demir Anonim", TaxNumber: "1112223344"})
		var dup *service.DuplicateSupplierTaxNumberError
		if !errors.Is(err, service.ErrDuplicateSupplierTaxNumber) || !errors.As(err, &dup) || dup.Existing.ID != s1.ID {
			t.Fatalf("aynı vergi no reddedilmeli: %v", err)
		}
		s2, err := supplierSvc.Create(ctx, org.ID, service.SupplierInput{Code: "T3", LegalName: "Başka Ltd", TaxNumber: "9998887776"})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := supplierSvc.Update(ctx, s2.ID, org.ID, service.SupplierInput{LegalName: "Başka Ltd", TaxNumber: "111-222-3344"}); !errors.Is(err, service.ErrDuplicateSupplierTaxNumber) {
			t.Errorf("güncellemede başka tedarikçinin vergi no'su reddedilmeli: %v", err)
		}
		// Kendi (değişmeyen) vergi numarasıyla düzenleme serbest.
		if _, err := supplierSvc.Update(ctx, s1.ID, org.ID, service.SupplierInput{LegalName: "Demir A.Ş. (Merkez)", TaxNumber: "1112223344"}); err != nil {
			t.Errorf("kendi vergi no'suyla düzenleme reddedilmemeli: %v", err)
		}
		// Vergi numarasız tedarikçiler çakışmaz; başka firma çakışmaz.
		for i, code := range []string{"N1", "N2"} {
			if _, err := supplierSvc.Create(ctx, org.ID, service.SupplierInput{Code: code, LegalName: "Vergisiz " + code}); err != nil {
				t.Errorf("vergi no'suz tedarikçi %d açılamadı: %v", i, err)
			}
		}
		if _, err := supplierSvc.Create(ctx, other.ID, service.SupplierInput{Code: "T1", LegalName: "Demir A.Ş.", TaxNumber: "1112223344"}); err != nil {
			t.Errorf("başka firmada aynı vergi no serbest olmalı: %v", err)
		}
	})
}
