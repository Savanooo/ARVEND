package service_test

// Metraj Hesaplama -> Teklif entegrasyonu (Faz M2) için otomatik testler:
// calc_snapshot/unit/section_label/calc_category_id kalıcılığı, revizyon
// ("Revize Et") sırasında BİREBİR (mutasyonsuz) taşınması ve
// calc_category_id'nin de product_id ile AYNI tenant-izolasyon kuralına
// tabi olması. Gerçek bir PostgreSQL bağlantısı gerektirir.

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

// jsonEqual, iki JSON belgesini SEMANTİK olarak karşılaştırır -- jsonb
// kolonu ikili temsilden geri yazarken kanonik biçimlendirme uygular
// (ör. ":" sonrasına boşluk ekler); bu, verinin BOZULDUĞU anlamına
// gelmez, ham string karşılaştırması yanlış pozitif üretir.
func jsonEqual(t *testing.T, a, b json.RawMessage) bool {
	t.Helper()
	var va, vb any
	if err := json.Unmarshal(a, &va); err != nil {
		t.Fatalf("JSON ayrıştırılamadı (a): %v (%s)", err, a)
	}
	if err := json.Unmarshal(b, &vb); err != nil {
		t.Fatalf("JSON ayrıştırılamadı (b): %v (%s)", err, b)
	}
	na, _ := json.Marshal(va)
	nb, _ := json.Marshal(vb)
	return string(na) == string(nb)
}

func TestOfferItems_CalcSnapshot(t *testing.T) {
	dbURL := testDBURL(t)
	ctx := context.Background()

	pool, err := repository.NewPool(ctx, dbURL)
	if err != nil {
		t.Fatalf("veritabanına bağlanılamadı: %v", err)
	}
	t.Cleanup(func() { pool.Close() })

	q := sqlc.New(pool)
	orgSvc := service.NewOrganizationService(q)
	settingsSvc := service.NewSettingsService(q, testSecretBox(t))
	offerSvc := service.NewOfferService(pool, q, settingsSvc, "http://localhost:3000")
	calcSvc := service.NewCalcService(q)

	orgA := mustCreateOrg(t, ctx, orgSvc, pool, "Metraj Snapshot Test A", "metraj-snapshot-test-a")
	orgB := mustCreateOrg(t, ctx, orgSvc, pool, "Metraj Snapshot Test B", "metraj-snapshot-test-b")
	t.Cleanup(func() { cleanupOrganization(t, pool, orgA.ID); cleanupOrganization(t, pool, orgB.ID) })

	group := mustGroup(t, ctx, calcSvc, orgA.ID, "snapshot-grup")
	cat := mustCategory(t, ctx, calcSvc, orgA.ID, group.ID, "snapshot-kategori")
	otherOrgGroup := mustGroup(t, ctx, service.NewCalcService(sqlc.New(pool)), orgB.ID, "yabanci-snapshot-grup")
	otherOrgCat := mustCategory(t, ctx, service.NewCalcService(sqlc.New(pool)), orgB.ID, otherOrgGroup.ID, "yabanci-snapshot-kategori")

	snapshot := json.RawMessage(`{"area":"20","perimeter":null,"pitch_deg":null,"recipe_factor":"5","waste_percent":"0","rounding_type":"none","price_at_calc":"230.00"}`)
	sectionLabel := "Salon Tavanı"

	t.Run("calc_snapshot alanları oluşturmada kalıcı olur", func(t *testing.T) {
		o, err := offerSvc.Create(ctx, service.CreateOfferInput{
			OrganizationID: orgA.ID, CustomerName: "Snapshot Test Müşteri",
			Items: []service.OfferItemInput{{
				ProductName: "10x10 Petek Tavan", Quantity: 100, UnitPrice: 230,
				Unit: "adet", SectionLabel: &sectionLabel, CalcCategoryID: &cat.ID, CalcSnapshot: snapshot,
			}},
		})
		if err != nil {
			t.Fatalf("teklif oluşturulamadı: %v", err)
		}
		if len(o.Items) != 1 {
			t.Fatalf("1 kalem bekleniyordu, geldi: %d", len(o.Items))
		}
		item := o.Items[0]
		if item.Unit != "adet" {
			t.Errorf("unit = %q, istenen 'adet'", item.Unit)
		}
		if item.SectionLabel == nil || *item.SectionLabel != sectionLabel {
			t.Errorf("section_label = %v, istenen %q", item.SectionLabel, sectionLabel)
		}
		if item.CalcCategoryID == nil || *item.CalcCategoryID != cat.ID {
			t.Errorf("calc_category_id = %v, istenen %q", item.CalcCategoryID, cat.ID)
		}
		if !jsonEqual(t, item.CalcSnapshot, snapshot) {
			t.Errorf("calc_snapshot = %s, istenen %s", item.CalcSnapshot, snapshot)
		}

		// Get ile de aynı şekilde geri gelmeli (yalnızca Create dönüşü değil).
		fetched, err := offerSvc.Get(ctx, o.ID, orgA.ID)
		if err != nil {
			t.Fatalf("teklif alınamadı: %v", err)
		}
		if fetched.Items[0].SectionLabel == nil || *fetched.Items[0].SectionLabel != sectionLabel {
			t.Fatalf("Get() sonrası section_label kayboldu: %v", fetched.Items[0].SectionLabel)
		}
	})

	t.Run("Revize Et calc_snapshot'ı MUTASYONSUZ (birebir) klonlar", func(t *testing.T) {
		o, err := offerSvc.Create(ctx, service.CreateOfferInput{
			OrganizationID: orgA.ID, CustomerName: "Revize Snapshot Müşteri",
			Items: []service.OfferItemInput{{
				ProductName: "10x10 Petek Tavan", Quantity: 100, UnitPrice: 230,
				Unit: "adet", SectionLabel: &sectionLabel, CalcCategoryID: &cat.ID, CalcSnapshot: snapshot,
			}},
		})
		if err != nil {
			t.Fatalf("teklif oluşturulamadı: %v", err)
		}
		if _, err := offerSvc.UpdateStatus(ctx, o.ID, orgA.ID, domain.OfferStatusGonderildi, ""); err != nil {
			t.Fatalf("gönderilemedi: %v", err)
		}
		revised, err := offerSvc.Revise(ctx, o.ID, orgA.ID, "")
		if err != nil {
			t.Fatalf("revize edilemedi: %v", err)
		}
		if revised.RevisionNo != 1 {
			t.Fatalf("revision_no = %d, istenen 1", revised.RevisionNo)
		}
		item := revised.Items[0]
		if item.Unit != "adet" || item.SectionLabel == nil || *item.SectionLabel != sectionLabel {
			t.Fatalf("revize sonrası unit/section_label kaybolmuş: unit=%q section_label=%v", item.Unit, item.SectionLabel)
		}
		if item.CalcCategoryID == nil || *item.CalcCategoryID != cat.ID {
			t.Fatalf("revize sonrası calc_category_id kaybolmuş: %v", item.CalcCategoryID)
		}
		if !jsonEqual(t, item.CalcSnapshot, snapshot) {
			t.Fatalf("revize sonrası calc_snapshot DEĞİŞMİŞ (immutability ihlali): %s != %s", item.CalcSnapshot, snapshot)
		}
	})

	t.Run("başka organizasyonun calc_category_id'si sessizce NULL'a düşer (product_id ile aynı ilke)", func(t *testing.T) {
		o, err := offerSvc.Create(ctx, service.CreateOfferInput{
			OrganizationID: orgA.ID, CustomerName: "Kaçak Kategori Müşteri",
			Items: []service.OfferItemInput{{
				ProductName: "Kaçak Kalem", Quantity: 1, UnitPrice: 100,
				Unit: "adet", CalcCategoryID: &otherOrgCat.ID,
			}},
		})
		if err != nil {
			t.Fatalf("teklif oluşturulamadı: %v", err)
		}
		if o.Items[0].CalcCategoryID != nil {
			t.Fatalf("başka organizasyonun calc_category_id'si bağlanmış: %v", o.Items[0].CalcCategoryID)
		}
	})
}
