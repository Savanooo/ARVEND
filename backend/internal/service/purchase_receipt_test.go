package service_test

// Siparişten teslim alma (migration 0074) -- gerçek bir PostgreSQL bağlantısı
// gerektirir. Bitti sayılma ölçütü (yol haritası adım 1): 100 sipariş, 60
// geldi, 5 hasarlı -> 55 kabul, 5 red, 40 bekliyor görünür; kabul edilip
// maliyeti (faturası) girilmemiş tutar kaybolmaz; sipariş kapanınca gelmeyen
// kısım taahhütten çıkar, teslim alınan kalır.

import (
	"errors"
	"math"
	"testing"
	"time"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

func TestPurchaseReceipts(t *testing.T) {
	e := newDashTestEnv(t, "teslim-alma")
	ctx := e.ctx
	org := e.org.ID
	svc := e.projectSvc
	q := sqlc.New(e.pool)
	costCodeSvc := service.NewCostCodeService(e.pool, q)
	supplierSvc := service.NewSupplierService(e.pool, q, testSecretBox(t))
	today := time.Now()
	near := func(a, b float64) bool { return math.Abs(a-b) < 0.005 }

	cc, err := costCodeSvc.Create(ctx, org, service.CostCodeInput{Code: "TSL-MLZ", Name: "Malzeme", Category: "Malzeme"})
	if err != nil {
		t.Fatal(err)
	}
	sup, err := supplierSvc.Create(ctx, org, service.SupplierInput{Code: "TSL-SUP", LegalName: "Alçıpan Tedarik", Specialty: "Malzeme"})
	if err != nil {
		t.Fatal(err)
	}
	// newPO: 100 adet x 1.000 TL (%20 KDV) + 10 adet x 50 TL; approve ise onaylanır.
	newPO := func(t *testing.T, p *domain.Project, approve bool) (*domain.PurchaseOrder, []domain.PurchaseOrderItem) {
		t.Helper()
		po, err := svc.CreatePurchaseOrder(ctx, p.ID, org, service.PurchaseOrderInput{
			SupplierID: sup.ID, IssueDate: today, TaxRate: 20,
			Items: []service.PurchaseOrderItemInput{
				{CostCodeID: cc.ID, Description: "Alçıpan", Quantity: 100, Unit: "adet", UnitPrice: 1000},
				{CostCodeID: cc.ID, Description: "Vida", Quantity: 10, Unit: "paket", UnitPrice: 50},
			},
		})
		if err != nil {
			t.Fatal(err)
		}
		if approve {
			if po, err = svc.ApprovePurchaseOrder(ctx, p.ID, po.ID, org, ""); err != nil {
				t.Fatal(err)
			}
		}
		items, err := svc.ListPurchaseOrderItems(ctx, p.ID, po.ID, org)
		if err != nil {
			t.Fatal(err)
		}
		return po, items
	}
	receive := func(p *domain.Project, poID, key string, lines ...service.PurchaseReceiptItemInput) (*domain.PurchaseReceipt, error) {
		return svc.CreatePurchaseReceipt(ctx, p.ID, poID, org, service.PurchaseReceiptInput{
			ReceivedDate: today, DeliveryNoteNo: "IRS-1", Destination: domain.ReceiptDestinationSite,
			IdempotencyKey: key, Items: lines,
		})
	}
	itemReceipts := func(t *testing.T, p *domain.Project, poID string) map[string]domain.PurchaseOrderItemReceipt {
		t.Helper()
		out, err := svc.PurchaseOrderItemReceipts(ctx, p.ID, poID, org)
		if err != nil {
			t.Fatal(err)
		}
		return out
	}
	summary := func(t *testing.T, p *domain.Project, poID string) domain.PurchaseOrderReceiptSummary {
		t.Helper()
		out, err := svc.PurchaseOrderReceiptSummaries(ctx, p.ID, poID, org)
		if err != nil {
			t.Fatal(err)
		}
		return out[poID]
	}

	p := e.project(t, "Teslim Alma Projesi", domain.ProjectStatusActive, "TRY", 1000000)
	po, items := newPO(t, p, true)
	board, screws := items[0], items[1]

	t.Run("1_partial_with_rejection_shows_accepted_rejected_waiting", func(t *testing.T) {
		rc, err := receive(p, po.ID, "tsl-1", service.PurchaseReceiptItemInput{
			PurchaseOrderItemID: board.ID, AcceptedQuantity: 55, RejectedQuantity: 5, RejectionReason: "Kırık",
		})
		if err != nil {
			t.Fatal(err)
		}
		if rc.SequenceNo != 1 || len(rc.Items) != 1 || rc.Items[0].RejectionReason != "Kırık" {
			t.Fatalf("teslim: %+v", rc)
		}
		got := itemReceipts(t, p, po.ID)[board.ID]
		if got.AcceptedQuantity != 55 || got.RejectedQuantity != 5 || got.WaitingQuantity != 40 {
			t.Fatalf("55 kabul, 5 red, 40 bekleyen olmalı: %+v", got)
		}
		if w := itemReceipts(t, p, po.ID)[screws.ID]; w.WaitingQuantity != 10 {
			t.Fatalf("teslim edilmeyen kalemin hepsi bekler: %+v", w)
		}
		s := summary(t, p, po.ID)
		// 55 x 1.000 = 55.000 + %20 KDV = 66.000.
		if s.Status != domain.ReceiptStatusPartial || !near(s.AcceptedGross, 66000) || !near(s.ReceivedNotCosted, 66000) {
			t.Fatalf("özet: %+v", s)
		}
		fs, err := svc.FinancialSummary(ctx, p.ID, org)
		if err != nil {
			t.Fatal(err)
		}
		// Onaylı sipariş maliyettir (migration 0078): 100.500 + %20 = 120.600.
		// Teslim maliyeti değiştirmez; faturası girilmemiş teslim ayrıca görünür.
		if !near(fs.ReceivedNotCosted, 66000) || !near(fs.RealizedCost, 120600) || !near(fs.PurchaseCost, 120600) {
			t.Fatalf("teslim maliyet yazmaz ama faturası girilmemiş tutar görünür: %v %v", fs.ReceivedNotCosted, fs.RealizedCost)
		}
	})

	t.Run("2_acceptance_capped_by_ordered_minus_accepted", func(t *testing.T) {
		_, err := receive(p, po.ID, "", service.PurchaseReceiptItemInput{PurchaseOrderItemID: board.ID, AcceptedQuantity: 46})
		var exceeds *service.ErrReceiptExceedsOrder
		if !errors.As(err, &exceeds) || exceeds.Max.StringFixed(2) != "45.00" {
			t.Fatalf("kabul tavanı 100-55=45 olmalı, geldi %v", err)
		}
		if _, err := receive(p, po.ID, ""); !errors.Is(err, service.ErrReceiptItemsRequired) {
			t.Fatalf("boş teslim reddedilmeli: %v", err)
		}
		if _, err := receive(p, po.ID, "", service.PurchaseReceiptItemInput{PurchaseOrderItemID: board.ID, AcceptedQuantity: -1}); !errors.Is(err, service.ErrReceiptInvalidQuantity) {
			t.Fatalf("negatif miktar reddedilmeli: %v", err)
		}
		if _, err := svc.CreatePurchaseReceipt(ctx, p.ID, po.ID, org, service.PurchaseReceiptInput{
			ReceivedDate: today, Destination: domain.ReceiptDestinationWarehouse,
			Items: []service.PurchaseReceiptItemInput{{PurchaseOrderItemID: screws.ID, AcceptedQuantity: 1}},
		}); !errors.Is(err, service.ErrReceiptInvalidDestination) {
			t.Fatalf("depo seçilmeden depoya teslim reddedilmeli: %v", err)
		}
	})

	t.Run("3_idempotent_per_user", func(t *testing.T) {
		again, err := receive(p, po.ID, "tsl-1", service.PurchaseReceiptItemInput{PurchaseOrderItemID: board.ID, AcceptedQuantity: 1})
		if err != nil || again.SequenceNo != 1 {
			t.Fatalf("aynı anahtar aynı teslimi dönmeli: %v %+v", err, again)
		}
		u, _ := e.owner(t, "teslim-baskasi")
		if _, err := svc.CreatePurchaseReceipt(ctx, p.ID, po.ID, org, service.PurchaseReceiptInput{
			ReceivedDate: today, Destination: domain.ReceiptDestinationSite, IdempotencyKey: "tsl-1", UserID: u.ID,
			Items: []service.PurchaseReceiptItemInput{{PurchaseOrderItemID: board.ID, AcceptedQuantity: 1}},
		}); !errors.Is(err, service.ErrReceiptIdempotencyKeyInUse) {
			t.Fatalf("başkasının anahtarı onun teslimini dönmemeli: %v", err)
		}
	})

	t.Run("4_linked_invoice_reduces_received_not_costed", func(t *testing.T) {
		poID := po.ID
		exp, err := createApprovedExpense(ctx, svc, p.ID, org, service.ExpenseInput{
			Category: domain.ExpenseMaterial, Description: "Alçıpan faturası", Amount: 30000, Currency: "TRY",
			ExpenseDate: today, PurchaseOrderID: &poID,
		})
		if err != nil {
			t.Fatal(err)
		}
		if exp.PurchaseOrderID == nil || *exp.PurchaseOrderID != po.ID {
			t.Fatalf("masraf siparişe bağlanmalı: %+v", exp.PurchaseOrderID)
		}
		if s := summary(t, p, po.ID); !near(s.Costed, 30000) || !near(s.ReceivedNotCosted, 36000) {
			t.Fatalf("66.000 - 30.000 = 36.000 olmalı: %+v", s)
		}
		// Düzenlemede alan gönderilmezse (eski istemci) bağ korunur.
		updated, err := svc.UpdateExpense(ctx, p.ID, exp.ID, org, service.ExpenseInput{
			Category: domain.ExpenseMaterial, Description: "Alçıpan faturası (düzeltme)", Amount: 30000, Currency: "TRY", ExpenseDate: today,
		})
		if err != nil {
			t.Fatal(err)
		}
		if updated.PurchaseOrderID == nil || *updated.PurchaseOrderID != po.ID {
			t.Fatal("alanı göndermeyen düzenleme sipariş bağını silmemeli")
		}
		// Düzenlenen masraf yeniden onay bekler: o sürede maliyete girmez.
		if s := summary(t, p, po.ID); !near(s.ReceivedNotCosted, 66000) {
			t.Fatalf("onay bekleyen fatura maliyeti girilmiş sayılmaz: %+v", s)
		}
		if _, err := svc.ApproveExpense(ctx, p.ID, exp.ID, org, ""); err != nil {
			t.Fatal(err)
		}
		// Başka projenin ya da taslak siparişe bağ reddedilir.
		other := e.project(t, "Başka Proje", domain.ProjectStatusActive, "TRY", 1000)
		otherPO, _ := newPO(t, other, true)
		draft, _ := newPO(t, p, false)
		for _, bad := range []string{otherPO.ID, draft.ID, "olmayan"} {
			bad := bad
			if _, err := svc.CreateExpense(ctx, p.ID, org, service.ExpenseInput{
				Category: domain.ExpenseMaterial, Description: "x", Amount: 1, Currency: "TRY", ExpenseDate: today, PurchaseOrderID: &bad,
			}); !errors.Is(err, service.ErrInvalidPurchaseOrderRef) {
				t.Fatalf("geçersiz sipariş bağı reddedilmeli (%s): %v", bad, err)
			}
		}
		if _, err := receive(other, po.ID, "", service.PurchaseReceiptItemInput{PurchaseOrderItemID: board.ID, AcceptedQuantity: 1}); !errors.Is(err, domain.ErrNotFound) {
			t.Fatalf("başka projenin URL'siyle teslim girilemez: %v", err)
		}
	})

	t.Run("5_received_order_cannot_be_cancelled_void_restores_waiting", func(t *testing.T) {
		if _, err := svc.CancelPurchaseOrder(ctx, p.ID, po.ID, org, "", "vazgeçtik"); !errors.Is(err, service.ErrPurchaseOrderHasReceipts) {
			t.Fatalf("teslim alınmış sipariş iptal edilemez: %v", err)
		}
		rc, err := receive(p, po.ID, "", service.PurchaseReceiptItemInput{PurchaseOrderItemID: screws.ID, AcceptedQuantity: 10})
		if err != nil {
			t.Fatal(err)
		}
		if rc.SequenceNo != 2 {
			t.Fatalf("ikinci teslim 2 numara almalı: %d", rc.SequenceNo)
		}
		if _, err := svc.VoidPurchaseReceipt(ctx, p.ID, rc.ID, org, "", ""); !errors.Is(err, service.ErrReceiptReasonRequired) {
			t.Fatalf("gerekçesiz iptal reddedilmeli: %v", err)
		}
		voided, err := svc.VoidPurchaseReceipt(ctx, p.ID, rc.ID, org, "", "Yanlış irsaliye")
		if err != nil || voided.VoidedAt == nil {
			t.Fatalf("iptal: %v %+v", err, voided)
		}
		if w := itemReceipts(t, p, po.ID)[screws.ID]; w.WaitingQuantity != 10 || w.AcceptedQuantity != 0 {
			t.Fatalf("iptal edilen teslim toplamlara girmez: %+v", w)
		}
		if _, err := svc.VoidPurchaseReceipt(ctx, p.ID, rc.ID, org, "", "tekrar"); !errors.Is(err, service.ErrAlreadyVoided) {
			t.Fatalf("iki kez iptal edilemez: %v", err)
		}
	})

	t.Run("6_close_releases_unreceived_commitment_keeps_received", func(t *testing.T) {
		before, err := svc.CostControlSummary(ctx, p.ID, org)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := svc.ClosePurchaseOrder(ctx, p.ID, po.ID, org, ""); err != nil {
			t.Fatal(err)
		}
		after, err := svc.CostControlSummary(ctx, p.ID, org)
		if err != nil {
			t.Fatal(err)
		}
		// Sipariş 100.500 (KDV hariç) taahhüttü; 55.000 teslim alındı, vida hiç gelmedi.
		if !near(before.CommittedCost-after.CommittedCost, 45500) {
			t.Fatalf("gelmeyen 45.500 taahhütten çıkmalı: önce %v sonra %v", before.CommittedCost, after.CommittedCost)
		}
		commitments, err := svc.ListCommitmentsForPurchaseOrder(ctx, p.ID, po.ID, org)
		if err != nil {
			t.Fatal(err)
		}
		active := 0.0
		for _, c := range commitments {
			if c.Status == "active" {
				active += c.CommittedAmount
			}
		}
		if !near(active, 55000) {
			t.Fatalf("siparişin aktif taahhüdü teslim alınan 55.000 olmalı: %v", active)
		}
		if s := summary(t, p, po.ID); !near(s.ReceivedNotCosted, 36000) {
			t.Fatalf("kapanış teslim alınmış ama faturası girilmemiş tutarı kaybetmemeli: %+v", s)
		}
		if _, err := receive(p, po.ID, "", service.PurchaseReceiptItemInput{PurchaseOrderItemID: board.ID, AcceptedQuantity: 1}); !errors.Is(err, service.ErrPurchaseOrderNotReceivable) {
			t.Fatalf("kapatılmış siparişe teslim girilemez: %v", err)
		}
		receipts, err := svc.ListPurchaseReceipts(ctx, p.ID, po.ID, org)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := svc.VoidPurchaseReceipt(ctx, p.ID, receipts[len(receipts)-1].ID, org, "", "geç"); !errors.Is(err, service.ErrReceiptNotVoidable) {
			t.Fatalf("kapatılmış siparişin teslimi iptal edilemez: %v", err)
		}
	})

	t.Run("7_close_without_receipts_keeps_commitment", func(t *testing.T) {
		po2, _ := newPO(t, p, true)
		before, err := svc.CostControlSummary(ctx, p.ID, org)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := svc.ClosePurchaseOrder(ctx, p.ID, po2.ID, org, ""); err != nil {
			t.Fatal(err)
		}
		after, err := svc.CostControlSummary(ctx, p.ID, org)
		if err != nil {
			t.Fatal(err)
		}
		if !near(before.CommittedCost, after.CommittedCost) {
			t.Fatalf("teslim kaydı olmayan sipariş kapanınca taahhüt değişmemeli (eski davranış): %v %v", before.CommittedCost, after.CommittedCost)
		}
	})

	t.Run("8_warehouse_destination", func(t *testing.T) {
		po3, items3 := newPO(t, p, true)
		var wh, closed string
		if err := e.pool.QueryRow(ctx, `INSERT INTO inventory_warehouses (organization_id, name) VALUES ($1, 'Teslim Depo') RETURNING id::text`, org).Scan(&wh); err != nil {
			t.Fatal(err)
		}
		if err := e.pool.QueryRow(ctx, `INSERT INTO inventory_warehouses (organization_id, name, is_active) VALUES ($1, 'Kapalı Depo', false) RETURNING id::text`, org).Scan(&closed); err != nil {
			t.Fatal(err)
		}
		in := service.PurchaseReceiptInput{
			ReceivedDate: today, Destination: domain.ReceiptDestinationWarehouse, WarehouseID: closed,
			Items: []service.PurchaseReceiptItemInput{{PurchaseOrderItemID: items3[1].ID, AcceptedQuantity: 10}},
		}
		if _, err := svc.CreatePurchaseReceipt(ctx, p.ID, po3.ID, org, in); !errors.Is(err, service.ErrReceiptWarehouseInactive) {
			t.Fatalf("kapalı depoya teslim reddedilmeli: %v", err)
		}
		in.WarehouseID = wh
		rc, err := svc.CreatePurchaseReceipt(ctx, p.ID, po3.ID, org, in)
		if err != nil {
			t.Fatal(err)
		}
		if rc.WarehouseName != "Teslim Depo" || rc.WarehouseID == nil {
			t.Fatalf("depo adı dönmeli: %+v", rc)
		}
		// Bir kalem tamam, diğeri hiç gelmedi: kısmi.
		if s := summary(t, p, po3.ID); s.Status != domain.ReceiptStatusPartial {
			t.Fatalf("durum kısmi olmalı: %+v", s)
		}
		if _, err := receive(p, po3.ID, "", service.PurchaseReceiptItemInput{PurchaseOrderItemID: items3[0].ID, AcceptedQuantity: 100}); err != nil {
			t.Fatal(err)
		}
		if s := summary(t, p, po3.ID); s.Status != domain.ReceiptStatusComplete {
			t.Fatalf("her kalem tamam: teslim alındı olmalı: %+v", s)
		}
	})
}
