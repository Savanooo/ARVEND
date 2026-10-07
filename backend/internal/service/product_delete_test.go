package service_test

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

// TestProductDeleteInUse: metraj reçetesine bağlı ürün silinemez (eskiden
// reçete kalemi sessizce ürünsüz kalıyordu); bağsız ürün silinir, teklif
// kalemleri engel değildir (ürün adı/fiyatı anlık görüntü olarak kalır).
func TestProductDeleteInUse(t *testing.T) {
	dbURL := testDBURL(t)
	ctx := context.Background()
	pool, err := repository.NewPool(ctx, dbURL)
	if err != nil {
		t.Fatalf("veritabanına bağlanılamadı: %v", err)
	}
	t.Cleanup(func() { pool.Close() })
	q := sqlc.New(pool)
	orgSvc := service.NewOrganizationService(q)
	productSvc := service.NewProductService(q)
	calcSvc := service.NewCalcService(q)
	settingsSvc := service.NewSettingsService(q, testSecretBox(t))
	offerSvc := service.NewOfferService(pool, q, settingsSvc, "http://localhost:3000")
	org := mustCreateOrg(t, ctx, orgSvc, pool, "Ürün Silme Test", "urun-silme-test")

	used, err := productSvc.Create(ctx, org.ID, "Alçıpan Levha", "adet", 100, "", "")
	if err != nil {
		t.Fatal(err)
	}
	g := mustGroup(t, ctx, calcSvc, org.ID, "silme-grup")
	cat := mustCategory(t, ctx, calcSvc, org.ID, g.ID, "silme-kategori")
	if _, err := calcSvc.CreateRecipeItem(ctx, org.ID, service.CalcRecipeItemInput{
		CategoryID: cat.ID, ProductID: &used.ID, MaterialName: "Alçıpan", Unit: "adet",
		CalculationType: domain.CalcTypeFixed, FixedQuantity: d("1"),
	}); err != nil {
		t.Fatal(err)
	}

	err = productSvc.Delete(ctx, used.ID, org.ID)
	var inUse *service.ProductInUseError
	if !errors.Is(err, service.ErrProductInUse) || !errors.As(err, &inUse) || inUse.RecipeItems != 1 {
		t.Fatalf("reçetede kullanılan ürün silinmemeli: %v", err)
	}
	if !strings.Contains(err.Error(), "1 metraj reçete kaleminde") {
		t.Errorf("mesaj kullanımı söylemeli: %q", err.Error())
	}
	if _, err := productSvc.Get(ctx, used.ID, org.ID); err != nil {
		t.Errorf("ürün hâlâ durmalı: %v", err)
	}
	items, err := calcSvc.ListRecipeItemsAdmin(ctx, cat.ID, org.ID)
	if err != nil || len(items) != 1 || items[0].ProductID == nil {
		t.Errorf("reçete kalemi ürüne bağlı kalmalı: %+v err=%v", items, err)
	}

	free, err := productSvc.Create(ctx, org.ID, "Serbest Ürün", "adet", 50, "", "")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := offerSvc.Create(ctx, service.CreateOfferInput{
		OrganizationID: org.ID, CustomerName: "Müşteri",
		Items: []service.OfferItemInput{{ProductID: &free.ID, ProductName: "Serbest Ürün", Quantity: 1, UnitPrice: 50}},
	}); err != nil {
		t.Fatal(err)
	}
	if err := productSvc.Delete(ctx, free.ID, org.ID); err != nil {
		t.Fatalf("yalnızca teklifte geçen ürün silinebilmeli: %v", err)
	}
	if err := productSvc.Delete(ctx, free.ID, org.ID); !errors.Is(err, domain.ErrNotFound) {
		t.Errorf("silinmiş ürün ikinci kez ErrNotFound dönmeli: %v", err)
	}
}
