package service_test

// Genel (projesiz) masraf (migration 0068): projeli masrafla aynı onay ve
// sahiplik kuralları, proje bağı yok, "Masraflar" listesi ikisini birlikte
// gösterir.

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

func TestGeneralExpense(t *testing.T) {
	dbURL := testDBURL(t)
	ctx := context.Background()
	pool, err := repository.NewPool(ctx, dbURL)
	if err != nil {
		t.Fatalf("db: %v", err)
	}
	t.Cleanup(func() { pool.Close() })
	q := sqlc.New(pool)
	orgSvc := service.NewOrganizationService(q)
	userSvc := service.NewUserService(pool, q)
	notifSvc := service.NewNotificationService(q)
	projectSvc := service.NewProjectService(pool, q, mustTestStore(t), service.NewSettingsService(q, testSecretBox(t)), "http://localhost:3000")

	org := mustCreateOrg(t, ctx, orgSvc, pool, "Genel Masraf Org", "genel-masraf-test")
	orgUUID, _ := repository.StringToUUID(org.ID)
	if err := q.SeedSystemRolesForOrg(ctx, orgUUID); err != nil {
		t.Fatalf("rol seed: %v", err)
	}
	suffix := fmt.Sprintf("%d", time.Now().UnixNano()%1_000_000_000)
	owner, err := userSvc.Create(ctx, org.ID, "gm_owner_"+suffix, "GeciciSifre123!", "Firma Sahibi", domain.RoleAdmin, domain.OrgRoleOwner)
	if err != nil {
		t.Fatal(err)
	}
	admin, err := userSvc.Create(ctx, org.ID, "gm_admin_"+suffix, "GeciciSifre123!", "Yönetici", domain.RoleAdmin, domain.OrgRoleAdmin)
	if err != nil {
		t.Fatal(err)
	}
	field, err := userSvc.Create(ctx, org.ID, "gm_saha_"+suffix, "GeciciSifre123!", "Saha Çalışanı", domain.RoleKullanici, domain.OrgRoleField)
	if err != nil {
		t.Fatal(err)
	}
	other, err := userSvc.Create(ctx, org.ID, "gm_diger_"+suffix, "GeciciSifre123!", "Başka Saha", domain.RoleKullanici, domain.OrgRoleField)
	if err != nil {
		t.Fatal(err)
	}

	input := func(userID string, ownOnly bool) service.ExpenseInput {
		return service.ExpenseInput{
			Category: "transport", Description: "Yakıt", Amount: 1200, ExpenseDate: time.Date(2026, 10, 14, 0, 0, 0, 0, time.UTC),
			SupplierName: "Akaryakıt", UserID: userID, OwnOnly: ownOnly, VATRate: ptrFloat(20),
		}
	}
	notifCount := func(t *testing.T, userID, typ string) int {
		t.Helper()
		res, err := notifSvc.List(ctx, userID, org.ID, 1, 100)
		if err != nil {
			t.Fatal(err)
		}
		n := 0
		for _, x := range res.Notifications {
			if x.Type == typ {
				n++
			}
		}
		return n
	}

	t.Run("saha girer: onay bekler, TRY, onaylayıcıya bildirim", func(t *testing.T) {
		before := notifCount(t, admin.ID, domain.NotificationExpensePendingApproval)
		e, err := projectSvc.CreateGeneralExpense(ctx, org.ID, input(field.ID, true))
		if err != nil {
			t.Fatal(err)
		}
		if e.ProjectID != "" || e.Currency != "TRY" || e.ApprovalStatus != domain.ExpenseApprovalPending {
			t.Fatalf("genel masraf alanları: proje=%q para=%q durum=%q", e.ProjectID, e.Currency, e.ApprovalStatus)
		}
		if e.VATAmount == nil || *e.VATAmount != 200 {
			t.Fatalf("KDV tutarı 200 olmalı: %v", e.VATAmount)
		}
		if notifCount(t, admin.ID, domain.NotificationExpensePendingApproval) != before+1 {
			t.Fatal("yöneticiye onay bildirimi gitmeli")
		}
		if notifCount(t, field.ID, domain.NotificationExpensePendingApproval) != 0 {
			t.Fatal("giren kendi masrafının onay bildirimini almamalı")
		}
	})

	t.Run("proje bağı ve geçersiz para birimi reddedilir", func(t *testing.T) {
		in := input(owner.ID, false)
		in.CostCodeID = "00000000-0000-0000-0000-000000000001"
		if _, err := projectSvc.CreateGeneralExpense(ctx, org.ID, in); !errors.Is(err, service.ErrGeneralExpenseProjectLink) {
			t.Fatalf("beklenen ErrGeneralExpenseProjectLink, geldi %v", err)
		}
		in = input(owner.ID, false)
		in.Currency = "TL1"
		if _, err := projectSvc.CreateGeneralExpense(ctx, org.ID, in); err == nil {
			t.Fatal("geçersiz para birimi reddedilmeli")
		}
	})

	t.Run("aynı tekrar anahtarı aynı kaydı döner, başkasınınkini döndürmez", func(t *testing.T) {
		in := input(field.ID, true)
		in.IdempotencyKey = "gm-key-" + suffix
		a, err := projectSvc.CreateGeneralExpense(ctx, org.ID, in)
		if err != nil {
			t.Fatal(err)
		}
		b, err := projectSvc.CreateGeneralExpense(ctx, org.ID, in)
		if err != nil || b.ID != a.ID {
			t.Fatalf("tekrar aynı kaydı dönmeli: %v %v", b, err)
		}
		in.UserID = other.ID
		if _, err := projectSvc.CreateGeneralExpense(ctx, org.ID, in); !errors.Is(err, service.ErrExpenseIdempotencyKeyInUse) {
			t.Fatalf("başkasının anahtarı: beklenen ErrExpenseIdempotencyKeyInUse, geldi %v", err)
		}
	})

	t.Run("sahiplik ve onay kuralları", func(t *testing.T) {
		e, err := projectSvc.CreateGeneralExpense(ctx, org.ID, input(field.ID, true))
		if err != nil {
			t.Fatal(err)
		}
		// Başka saha çalışanı düzenleyemez/geri çekemez.
		if _, err := projectSvc.UpdateGeneralExpense(ctx, e.ID, org.ID, input(other.ID, true)); !errors.Is(err, service.ErrExpenseNotOwn) {
			t.Fatalf("başkasının masrafı: beklenen ErrExpenseNotOwn, geldi %v", err)
		}
		// Giren kendi bekleyen masrafını düzeltir.
		fix := input(field.ID, true)
		fix.Amount = 1500
		updated, err := projectSvc.UpdateGeneralExpense(ctx, e.ID, org.ID, fix)
		if err != nil || updated.Amount != 1500 {
			t.Fatalf("kendi masrafını düzeltebilmeli: %v %v", updated, err)
		}
		// Ret gerekçesiz olmaz; yönetici gerekçeyle reddeder, giren bildirim alır.
		if _, err := projectSvc.RejectGeneralExpense(ctx, e.ID, org.ID, admin.ID, " "); !errors.Is(err, service.ErrExpenseRejectReasonRequired) {
			t.Fatalf("beklenen ErrExpenseRejectReasonRequired, geldi %v", err)
		}
		before := notifCount(t, field.ID, domain.NotificationExpenseRejected)
		rejected, err := projectSvc.RejectGeneralExpense(ctx, e.ID, org.ID, admin.ID, "fiş yok")
		if err != nil || rejected.ApprovalStatus != domain.ExpenseApprovalRejected {
			t.Fatalf("ret: %v %v", rejected, err)
		}
		if notifCount(t, field.ID, domain.NotificationExpenseRejected) != before+1 {
			t.Fatal("girene ret bildirimi gitmeli")
		}
		// Reddedileni düzeltir -> yeniden bekler -> yönetici onaylar.
		again, err := projectSvc.UpdateGeneralExpense(ctx, e.ID, org.ID, fix)
		if err != nil || again.ApprovalStatus != domain.ExpenseApprovalPending {
			t.Fatalf("düzeltilen masraf yeniden beklemeli: %v %v", again, err)
		}
		if _, err := projectSvc.ApproveGeneralExpense(ctx, e.ID, org.ID, admin.ID); err != nil {
			t.Fatal(err)
		}
		// Onaylanmışı giren artık değiştiremez; finans yetkilisi değiştirebilir.
		if _, err := projectSvc.UpdateGeneralExpense(ctx, e.ID, org.ID, fix); !errors.Is(err, service.ErrExpenseApprovedLocked) {
			t.Fatalf("onaylı masraf: beklenen ErrExpenseApprovedLocked, geldi %v", err)
		}
		if _, err := projectSvc.VoidGeneralExpense(ctx, e.ID, org.ID, field.ID, "", true); !errors.Is(err, service.ErrExpenseApprovedLocked) {
			t.Fatalf("onaylı masrafı geri çekememeli, geldi %v", err)
		}
		voided, err := projectSvc.VoidGeneralExpense(ctx, e.ID, org.ID, admin.ID, "mükerrer", false)
		if err != nil || voided.VoidedAt == nil {
			t.Fatalf("yönetici iptal edebilmeli: %v %v", voided, err)
		}
		if _, err := projectSvc.ApproveGeneralExpense(ctx, e.ID, org.ID, owner.ID); !errors.Is(err, service.ErrAlreadyVoided) {
			t.Fatalf("iptal edilmiş masrafa karar: beklenen ErrAlreadyVoided, geldi %v", err)
		}
	})

	t.Run("kimse kendi masrafına karar veremez, Sahip hariç", func(t *testing.T) {
		e, err := projectSvc.CreateGeneralExpense(ctx, org.ID, input(admin.ID, false))
		if err != nil {
			t.Fatal(err)
		}
		if _, err := projectSvc.ApproveGeneralExpense(ctx, e.ID, org.ID, admin.ID); !errors.Is(err, service.ErrOwnExpenseDecision) {
			t.Fatalf("beklenen ErrOwnExpenseDecision, geldi %v", err)
		}
		mine, err := projectSvc.CreateGeneralExpense(ctx, org.ID, input(owner.ID, false))
		if err != nil {
			t.Fatal(err)
		}
		if _, err := projectSvc.ApproveGeneralExpense(ctx, mine.ID, org.ID, owner.ID); err != nil {
			t.Fatalf("Sahip kendi masrafını onaylayabilmeli: %v", err)
		}
	})

	t.Run("liste: genel süzgeci, kişinin kendi masrafları, başka firma görmez", func(t *testing.T) {
		all, err := projectSvc.ListExpensesAll(ctx, org.ID, service.ExpenseListFilter{Kind: "general"})
		if err != nil {
			t.Fatal(err)
		}
		if len(all) == 0 {
			t.Fatal("genel masraflar listelenmeli")
		}
		for _, e := range all {
			if !e.IsGeneral() || e.ProjectName != "" {
				t.Fatalf("genel süzgeçte projeli satır: %+v", e)
			}
			if e.CreatedByName == "" {
				t.Fatalf("giren adı dolu olmalı: %+v", e)
			}
		}
		mine, err := projectSvc.ListExpensesAll(ctx, org.ID, service.ExpenseListFilter{OnlyCreatedBy: other.ID})
		if err != nil {
			t.Fatal(err)
		}
		for _, e := range mine {
			if e.CreatedBy == nil || *e.CreatedBy != other.ID {
				t.Fatalf("yalnızca kişinin kendi masrafları dönmeli: %+v", e)
			}
		}
		pending, err := projectSvc.ListExpensesAll(ctx, org.ID, service.ExpenseListFilter{Status: domain.ExpenseApprovalPending})
		if err != nil {
			t.Fatal(err)
		}
		for _, e := range pending {
			if e.ApprovalStatus != domain.ExpenseApprovalPending || e.VoidedAt != nil {
				t.Fatalf("bekleyen süzgecinde başka durum: %+v", e)
			}
		}
		if _, err := projectSvc.ListExpensesAll(ctx, org.ID, service.ExpenseListFilter{Kind: "x"}); !errors.Is(err, service.ErrInvalidExpenseFilter) {
			t.Fatalf("geçersiz süzgeç reddedilmeli, geldi %v", err)
		}
		otherOrg := mustCreateOrg(t, ctx, orgSvc, pool, "Başka Firma GM", "genel-masraf-test-2")
		leak, err := projectSvc.ListExpensesAll(ctx, otherOrg.ID, service.ExpenseListFilter{})
		if err != nil || len(leak) != 0 {
			t.Fatalf("başka firma masraf görmemeli: %d %v", len(leak), err)
		}
		if _, err := projectSvc.ApproveGeneralExpense(ctx, all[0].ID, otherOrg.ID, owner.ID); !errors.Is(err, service.ErrGeneralExpenseNotFound) {
			t.Fatalf("başka firmadan karar: beklenen ErrGeneralExpenseNotFound, geldi %v", err)
		}
	})
}
