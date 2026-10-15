package service_test

// Stok Takibi (migration 0072): depolar, kartlar, giriş/çıkış/aktarım/
// fire/sayım, parti ve SKT (önce bozulacak önce, engelle/uyar), ortalama
// maliyet, fiş iptali, idempotency ve firma izolasyonu.

import (
	"context"
	"errors"
	"fmt"
	"math"
	"strings"
	"testing"
	"time"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

func TestInventory(t *testing.T) {
	dbURL := testDBURL(t)
	ctx := context.Background()
	pool, err := repository.NewPool(ctx, dbURL)
	if err != nil {
		t.Fatalf("db: %v", err)
	}
	t.Cleanup(func() { pool.Close() })
	q := sqlc.New(pool)
	orgSvc := service.NewOrganizationService(q)
	settingsSvc := service.NewSettingsService(q, testSecretBox(t))
	offerSvc := service.NewOfferService(pool, q, settingsSvc, "http://localhost:3000")
	projectSvc := service.NewProjectService(pool, q, mustTestStore(t), settingsSvc, "http://localhost:3000")
	inv := service.NewInventoryService(pool, q, mustTestStore(t))

	org := mustCreateOrg(t, ctx, orgSvc, pool, "Stok Org", "stok-test")
	other := mustCreateOrg(t, ctx, orgSvc, pool, "Başka Stok Org", "stok-test-diger")
	today := service.IstanbulToday()
	day := func(offset int) *time.Time { d := today.AddDate(0, 0, offset); return &d }
	f := func(v float64) *float64 { return &v }
	near := func(a, b float64) bool { return math.Abs(a-b) < 0.0001 }

	whs, err := inv.ListWarehouses(ctx, org.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(whs) != 1 || whs[0].Name != "Merkez Depo" {
		t.Fatalf("ilk açılışta Merkez Depo açılmalı: %+v", whs)
	}
	main := whs[0].ID
	second, err := inv.CreateWarehouse(ctx, org.ID, service.InventoryWarehouseInput{Name: "Ataşehir Depo"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := inv.CreateWarehouse(ctx, org.ID, service.InventoryWarehouseInput{Name: "ataşehir depo"}); !errors.Is(err, service.ErrInventoryDuplicateName) {
		t.Errorf("aynı adlı depo: %v", err)
	}

	profile, err := inv.CreateItem(ctx, org.ID, service.InventoryItemInput{Name: "Kutu Profil 40x40", Unit: "boy", Barcode: "8690000000011", MinStock: f(5)})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(profile.Code, "STK-") {
		t.Errorf("otomatik kod: %s", profile.Code)
	}
	if _, err := inv.CreateItem(ctx, org.ID, service.InventoryItemInput{Name: "Başka", Barcode: "8690000000011"}); !errors.Is(err, service.ErrInventoryDuplicateBarcode) {
		t.Errorf("aynı barkod: %v", err)
	}
	months := 3
	cement, err := inv.CreateItem(ctx, org.ID, service.InventoryItemInput{
		Name: "Çimento CEM I 42,5", Unit: "torba", TrackExpiry: true, ShelfLifeMonths: &months,
		ExpiryPolicy: service.InventoryPolicyBlock,
	})
	if err != nil {
		t.Fatal(err)
	}
	silicone, err := inv.CreateItem(ctx, org.ID, service.InventoryItemInput{
		Name: "Silikon", Unit: "adet", TrackExpiry: true, ExpiryPolicy: service.InventoryPolicyWarn,
	})
	if err != nil {
		t.Fatal(err)
	}
	balance := func(t *testing.T, itemID string) float64 {
		t.Helper()
		d, err := inv.GetItem(ctx, org.ID, itemID)
		if err != nil {
			t.Fatal(err)
		}
		return d.Item.Quantity
	}

	t.Run("giriş ortalama maliyeti günceller, barkodla bulunur", func(t *testing.T) {
		if _, err := inv.PostDocument(ctx, org.ID, service.InventoryDocumentInput{
			Type: service.InventoryDocReceipt, WarehouseID: main, Counterparty: "Demir Profil", ReferenceNo: "IRS-1",
			Lines: []service.InventoryLineInput{{ItemID: profile.ID, Quantity: 10, UnitCost: f(100)}},
		}); err != nil {
			t.Fatal(err)
		}
		doc, err := inv.PostDocument(ctx, org.ID, service.InventoryDocumentInput{
			Type: service.InventoryDocReceipt, WarehouseID: main,
			Lines: []service.InventoryLineInput{{ItemID: profile.ID, Quantity: 10, UnitCost: f(200)}},
		})
		if err != nil {
			t.Fatal(err)
		}
		if !strings.HasPrefix(doc.DocNo, "STK-") || len(doc.Lines) != 1 || doc.Lines[0].Quantity != 10 {
			t.Fatalf("fiş: %+v", doc)
		}
		found, err := inv.FindItemByBarcode(ctx, org.ID, "8690000000011")
		if err != nil {
			t.Fatal(err)
		}
		if !near(found.AvgUnitCost, 150) {
			t.Errorf("ortalama 150 olmalı: %v", found.AvgUnitCost)
		}
		if balance(t, profile.ID) != 20 {
			t.Errorf("bakiye 20 olmalı")
		}
	})

	t.Run("SKT: takipli malzemede tarih zorunlu, üretim tarihinden hesaplanır, önce bozulacak önce çıkar", func(t *testing.T) {
		if _, err := inv.PostDocument(ctx, org.ID, service.InventoryDocumentInput{
			Type: service.InventoryDocReceipt, WarehouseID: main,
			Lines: []service.InventoryLineInput{{ItemID: cement.ID, Quantity: 5}},
		}); !errors.Is(err, service.ErrInventoryInvalid) {
			t.Fatalf("SKT'siz giriş reddedilmeli: %v", err)
		}
		doc, err := inv.PostDocument(ctx, org.ID, service.InventoryDocumentInput{
			Type: service.InventoryDocReceipt, WarehouseID: main,
			Lines: []service.InventoryLineInput{
				{ItemID: cement.ID, Quantity: 20, LotNo: "B2", ExpiryDate: day(60)},
				{ItemID: cement.ID, Quantity: 10, LotNo: "B1", ProductionDate: day(-60)},
			},
		})
		if err != nil {
			t.Fatal(err)
		}
		wantB1 := today.AddDate(0, 0, -60).AddDate(0, 3, 0)
		if doc.Lines[1].ExpiryDate == nil || !doc.Lines[1].ExpiryDate.Equal(wantB1) {
			t.Errorf("B1'in SKT'si üretim + 3 ay olmalı: %v", doc.Lines[1].ExpiryDate)
		}
		// 15 torba çıkış: önce SKT'si yakın B1 (10), sonra B2 (5).
		out, err := inv.PostDocument(ctx, org.ID, service.InventoryDocumentInput{
			Type: service.InventoryDocIssue, WarehouseID: main, Counterparty: "Ali Usta",
			Lines: []service.InventoryLineInput{{ItemID: cement.ID, Quantity: 15}},
		})
		if err != nil {
			t.Fatal(err)
		}
		if len(out.Lines) != 2 || out.Lines[0].LotNo != "B1" || out.Lines[0].Quantity != -10 || out.Lines[1].LotNo != "B2" || out.Lines[1].Quantity != -5 {
			t.Fatalf("FEFO dağılımı: %+v", out.Lines)
		}
	})

	t.Run("SKT geçmiş parti: engelle kartında çıkamaz, fire olur; uyar kartında uyarıyla çıkar", func(t *testing.T) {
		rec, err := inv.PostDocument(ctx, org.ID, service.InventoryDocumentInput{
			Type: service.InventoryDocReceipt, WarehouseID: second.ID,
			Lines: []service.InventoryLineInput{{ItemID: cement.ID, Quantity: 4, LotNo: "ESKI", ExpiryDate: day(-1)}},
		})
		if err != nil {
			t.Fatal(err)
		}
		if len(rec.Warnings) != 1 {
			t.Errorf("SKT'si geçmiş giriş uyarmalı: %v", rec.Warnings)
		}
		if _, err := inv.PostDocument(ctx, org.ID, service.InventoryDocumentInput{
			Type: service.InventoryDocIssue, WarehouseID: second.ID,
			Lines: []service.InventoryLineInput{{ItemID: cement.ID, Quantity: 1}},
		}); !errors.Is(err, service.ErrInventoryExpiredBlocked) {
			t.Fatalf("SKT geçmiş çimento çıkmamalı: %v", err)
		}
		if _, err := inv.PostDocument(ctx, org.ID, service.InventoryDocumentInput{
			Type: service.InventoryDocWaste, WarehouseID: second.ID, Reason: "expired",
			Lines: []service.InventoryLineInput{{ItemID: cement.ID, Quantity: 4}},
		}); err != nil {
			t.Fatalf("fire olarak çıkmalı: %v", err)
		}
		if _, err := inv.PostDocument(ctx, org.ID, service.InventoryDocumentInput{
			Type: service.InventoryDocWaste, WarehouseID: second.ID,
			Lines: []service.InventoryLineInput{{ItemID: cement.ID, Quantity: 1}},
		}); !errors.Is(err, service.ErrInventoryInvalid) {
			t.Errorf("fire nedeni zorunlu: %v", err)
		}

		if _, err := inv.PostDocument(ctx, org.ID, service.InventoryDocumentInput{
			Type: service.InventoryDocReceipt, WarehouseID: main,
			Lines: []service.InventoryLineInput{{ItemID: silicone.ID, Quantity: 3, ExpiryDate: day(-5)}},
		}); err != nil {
			t.Fatal(err)
		}
		out, err := inv.PostDocument(ctx, org.ID, service.InventoryDocumentInput{
			Type: service.InventoryDocIssue, WarehouseID: main,
			Lines: []service.InventoryLineInput{{ItemID: silicone.ID, Quantity: 2}},
		})
		if err != nil {
			t.Fatal(err)
		}
		if len(out.Warnings) != 1 {
			t.Errorf("uyar kartı uyarıyla çıkmalı: %v", out.Warnings)
		}
	})

	t.Run("yetersiz stok fişi bütünüyle reddeder", func(t *testing.T) {
		before := balance(t, profile.ID)
		_, err := inv.PostDocument(ctx, org.ID, service.InventoryDocumentInput{
			Type: service.InventoryDocIssue, WarehouseID: main,
			Lines: []service.InventoryLineInput{
				{ItemID: profile.ID, Quantity: 2},
				{ItemID: profile.ID, Quantity: 500},
			},
		})
		if !errors.Is(err, service.ErrInventoryInsufficient) || !strings.Contains(err.Error(), "Merkez Depo") {
			t.Fatalf("yetersiz stok: %v", err)
		}
		if balance(t, profile.ID) != before {
			t.Error("reddedilen fiş stoğu değiştirmemeli")
		}
	})

	t.Run("aktarım partiyi korur; sayım farkı düzeltir; özet sayar", func(t *testing.T) {
		if _, err := inv.PostDocument(ctx, org.ID, service.InventoryDocumentInput{
			Type: service.InventoryDocTransfer, WarehouseID: main, TargetWarehouseID: second.ID,
			Lines: []service.InventoryLineInput{{ItemID: cement.ID, Quantity: 5}},
		}); err != nil {
			t.Fatal(err)
		}
		d, err := inv.GetItem(ctx, org.ID, cement.ID)
		if err != nil {
			t.Fatal(err)
		}
		var atSecond float64
		for _, b := range d.Balances {
			if b.WarehouseID == second.ID {
				atSecond += b.Quantity
				if b.LotNo != "B2" {
					t.Errorf("aktarılan parti B2 olmalı: %+v", b)
				}
			}
		}
		if atSecond != 5 {
			t.Errorf("ikinci depoda 5 torba olmalı: %v", atSecond)
		}
		if _, err := inv.PostDocument(ctx, org.ID, service.InventoryDocumentInput{
			Type: service.InventoryDocTransfer, WarehouseID: main, TargetWarehouseID: main,
			Lines: []service.InventoryLineInput{{ItemID: cement.ID, Quantity: 1}},
		}); !errors.Is(err, service.ErrInventoryInvalid) {
			t.Errorf("aynı depoya aktarım: %v", err)
		}

		cnt, err := inv.PostDocument(ctx, org.ID, service.InventoryDocumentInput{
			Type: service.InventoryDocCount, WarehouseID: main,
			Lines: []service.InventoryLineInput{{ItemID: profile.ID, CountedQuantity: f(18)}},
		})
		if err != nil {
			t.Fatal(err)
		}
		if len(cnt.Lines) != 1 || cnt.Lines[0].Quantity != -2 {
			t.Fatalf("sayım farkı -2 olmalı: %+v", cnt.Lines)
		}
		if balance(t, profile.ID) != 18 {
			t.Error("sayım sonrası 18")
		}
		sum, err := inv.Summary(ctx, org.ID)
		if err != nil {
			t.Fatal(err)
		}
		// Kalan: 18 profil × 150 + çimento ve silikon (fiyatsız giriş, 0).
		if sum.ItemCount != 3 || sum.ExpiredLotCount != 1 || !near(sum.StockValue, 18*150) || sum.BelowMinCount != 0 {
			t.Errorf("özet: %+v", sum)
		}
		alerts, err := inv.LotAlerts(ctx, org.ID)
		if err != nil {
			t.Fatal(err)
		}
		if len(alerts) != 1 || alerts[0].ItemID != silicone.ID || !alerts[0].Expired {
			t.Errorf("uyarılar: %+v", alerts)
		}
	})

	t.Run("günlük uyarı yönetene bir kez gider", func(t *testing.T) {
		userSvc := service.NewUserService(pool, q)
		orgUUID, _ := repository.StringToUUID(org.ID)
		if err := q.SeedSystemRolesForOrg(ctx, orgUUID); err != nil {
			t.Fatalf("rol seed: %v", err)
		}
		suffix := fmt.Sprintf("%d", time.Now().UnixNano()%1_000_000_000)
		owner, err := userSvc.Create(ctx, org.ID, "stk_owner_"+suffix, "GeciciSifre123!", "Depo Sahibi", domain.RoleAdmin, domain.OrgRoleOwner)
		if err != nil {
			t.Fatal(err)
		}
		field, err := userSvc.Create(ctx, org.ID, "stk_field_"+suffix, "GeciciSifre123!", "Saha", domain.RoleKullanici, domain.OrgRoleField)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := inv.SendDailyAlerts(ctx, time.Now()); err != nil {
			t.Fatal(err)
		}
		if _, err := inv.SendDailyAlerts(ctx, time.Now()); err != nil {
			t.Fatal(err)
		}
		notifSvc := service.NewNotificationService(q)
		count := func(userID string) (int, string) {
			res, err := notifSvc.List(ctx, userID, org.ID, 1, 50)
			if err != nil {
				t.Fatal(err)
			}
			n, body := 0, ""
			for _, x := range res.Notifications {
				if x.Type == domain.NotificationInventoryAlert {
					n++
					body = x.Body
				}
			}
			return n, body
		}
		if n, body := count(owner.ID); n != 1 || !strings.Contains(body, "SKT'si geçti") {
			t.Errorf("sahip günde bir uyarı almalı: %d %q", n, body)
		}
		if n, _ := count(field.ID); n != 0 {
			t.Errorf("salt okuyan saha uyarı almamalı: %d", n)
		}
	})

	t.Run("fiş iptali: giriş geri alınır, ortalama döner; kullanılmış giriş iptal edilemez", func(t *testing.T) {
		rec, err := inv.PostDocument(ctx, org.ID, service.InventoryDocumentInput{
			Type: service.InventoryDocReceipt, WarehouseID: main,
			Lines: []service.InventoryLineInput{{ItemID: profile.ID, Quantity: 2, UnitCost: f(300)}},
		})
		if err != nil {
			t.Fatal(err)
		}
		rev, err := inv.ReverseDocument(ctx, org.ID, rec.ID, "", "yanlış girildi")
		if err != nil {
			t.Fatal(err)
		}
		if rev.DocType != service.InventoryDocReversal || rev.ReversalOfNo != rec.DocNo || rev.Lines[0].Quantity != -2 {
			t.Fatalf("iptal fişi: %+v", rev)
		}
		item, _ := inv.FindItemByBarcode(ctx, org.ID, "8690000000011")
		if !near(item.AvgUnitCost, 150) {
			t.Errorf("iptal ortalamayı geri almalı: %v", item.AvgUnitCost)
		}
		if _, err := inv.ReverseDocument(ctx, org.ID, rec.ID, "", "tekrar"); !errors.Is(err, service.ErrInventoryAlreadyReversed) {
			t.Errorf("ikinci iptal: %v", err)
		}
		if _, err := inv.ReverseDocument(ctx, org.ID, rev.ID, "", "iptalin iptali"); !errors.Is(err, service.ErrInventoryNotReversible) {
			t.Errorf("iptal fişi iptal edilemez: %v", err)
		}
		if _, err := inv.ReverseDocument(ctx, org.ID, rec.ID, "", ""); err == nil {
			t.Error("gerekçesiz iptal reddedilmeli")
		}

		used, err := inv.PostDocument(ctx, org.ID, service.InventoryDocumentInput{
			Type: service.InventoryDocReceipt, WarehouseID: second.ID,
			Lines: []service.InventoryLineInput{{ItemID: profile.ID, Quantity: 3}},
		})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := inv.PostDocument(ctx, org.ID, service.InventoryDocumentInput{
			Type: service.InventoryDocIssue, WarehouseID: second.ID,
			Lines: []service.InventoryLineInput{{ItemID: profile.ID, Quantity: 3}},
		}); err != nil {
			t.Fatal(err)
		}
		if _, err := inv.ReverseDocument(ctx, org.ID, used.ID, "", "geri al"); !errors.Is(err, service.ErrInventoryInsufficient) {
			t.Errorf("çıkmış stoğun girişi iptal edilemez: %v", err)
		}
	})

	t.Run("idempotency anahtarı ikinci kaydı açmaz", func(t *testing.T) {
		in := service.InventoryDocumentInput{
			Type: service.InventoryDocReceipt, WarehouseID: main, IdempotencyKey: "stk-test-1",
			Lines: []service.InventoryLineInput{{ItemID: profile.ID, Quantity: 1}},
		}
		a, err := inv.PostDocument(ctx, org.ID, in)
		if err != nil {
			t.Fatal(err)
		}
		before := balance(t, profile.ID)
		b, err := inv.PostDocument(ctx, org.ID, in)
		if err != nil {
			t.Fatal(err)
		}
		if a.ID != b.ID || balance(t, profile.ID) != before {
			t.Errorf("aynı fiş dönmeli, stok artmamalı: %s %s", a.ID, b.ID)
		}
	})

	t.Run("stoklu depo ve kart arşivlenemez; arşivli kartla işlem yapılamaz", func(t *testing.T) {
		no := false
		if _, err := inv.UpdateWarehouse(ctx, org.ID, main, service.InventoryWarehouseInput{Name: "Merkez Depo", IsActive: &no}); !errors.Is(err, service.ErrInventoryWarehouseHasStock) {
			t.Errorf("stoklu depo: %v", err)
		}
		if _, err := inv.UpdateItem(ctx, org.ID, profile.ID, service.InventoryItemInput{Name: profile.Name, IsActive: &no}); !errors.Is(err, service.ErrInventoryItemHasStock) {
			t.Errorf("stoklu kart: %v", err)
		}
		empty, err := inv.CreateItem(ctx, org.ID, service.InventoryItemInput{Name: "Kullanılmayan"})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := inv.UpdateItem(ctx, org.ID, empty.ID, service.InventoryItemInput{Name: empty.Name, IsActive: &no}); err != nil {
			t.Fatal(err)
		}
		if _, err := inv.PostDocument(ctx, org.ID, service.InventoryDocumentInput{
			Type: service.InventoryDocReceipt, WarehouseID: main,
			Lines: []service.InventoryLineInput{{ItemID: empty.ID, Quantity: 1}},
		}); !errors.Is(err, service.ErrInventoryInactive) {
			t.Errorf("arşivli kart: %v", err)
		}
	})

	t.Run("çıkışta proje yalnızca bilgi; başka firmanın kaydı kullanılamaz", func(t *testing.T) {
		o, err := offerSvc.Create(ctx, service.CreateOfferInput{
			OrganizationID: org.ID, CustomerName: "Müşteri", VatRate: ptrFloat(0),
			Items: []service.OfferItemInput{{ProductName: "İş", Quantity: 1, UnitPrice: 1000}},
		})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := offerSvc.UpdateStatus(ctx, o.ID, org.ID, domain.OfferStatusGonderildi, ""); err != nil {
			t.Fatal(err)
		}
		link, err := offerSvc.CreateShareLink(ctx, o.ID, org.ID, "", nil)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := offerSvc.RespondByShareLinkToken(ctx, link.Token, domain.OfferStatusKabulEdildi, "", ""); err != nil {
			t.Fatal(err)
		}
		p, err := projectSvc.CreateFromOffer(ctx, o.ID, org.ID, service.CreateProjectInput{Name: "Stok Projesi"})
		if err != nil {
			t.Fatal(err)
		}
		out, err := inv.PostDocument(ctx, org.ID, service.InventoryDocumentInput{
			Type: service.InventoryDocIssue, WarehouseID: main, ProjectID: p.ID,
			Lines: []service.InventoryLineInput{{ItemID: profile.ID, Quantity: 1}},
		})
		if err != nil {
			t.Fatal(err)
		}
		if out.ProjectName != "Stok Projesi" {
			t.Errorf("proje adı fişte görünmeli: %q", out.ProjectName)
		}
		list, err := inv.ListDocuments(ctx, org.ID, service.InventoryDocumentFilter{ProjectID: p.ID})
		if err != nil {
			t.Fatal(err)
		}
		if len(list) != 1 {
			t.Errorf("projeye giden fişler: %d", len(list))
		}

		if _, err := inv.GetItem(ctx, other.ID, profile.ID); !errors.Is(err, service.ErrInventoryItemNotFound) {
			t.Errorf("başka firma kartı görmemeli: %v", err)
		}
		if _, err := inv.GetDocument(ctx, other.ID, out.ID); !errors.Is(err, service.ErrInventoryDocumentNotFound) {
			t.Errorf("başka firma fişi görmemeli: %v", err)
		}
		otherWh, err := inv.ListWarehouses(ctx, other.ID)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := inv.PostDocument(ctx, org.ID, service.InventoryDocumentInput{
			Type: service.InventoryDocReceipt, WarehouseID: otherWh[0].ID,
			Lines: []service.InventoryLineInput{{ItemID: profile.ID, Quantity: 1}},
		}); !errors.Is(err, service.ErrInventoryWarehouseNotFound) {
			t.Errorf("başka firmanın deposu: %v", err)
		}
		if _, err := inv.PostDocument(ctx, other.ID, service.InventoryDocumentInput{
			Type: service.InventoryDocIssue, WarehouseID: otherWh[0].ID, ProjectID: p.ID,
			Lines: []service.InventoryLineInput{{ItemID: profile.ID, Quantity: 1}},
		}); err == nil {
			t.Error("başka firmanın projesi/kartı kullanılamamalı")
		}
		if _, err := inv.PostDocument(ctx, org.ID, service.InventoryDocumentInput{
			Type: service.InventoryDocReceipt, WarehouseID: main, Date: day(1),
			Lines: []service.InventoryLineInput{{ItemID: profile.ID, Quantity: 1}},
		}); !errors.Is(err, service.ErrInventoryInvalid) {
			t.Errorf("ileri tarihli fiş: %v", err)
		}
	})
}
