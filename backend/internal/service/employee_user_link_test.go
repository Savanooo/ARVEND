package service_test

// User <-> Employee bağlantısı (migration 0041) — GET /tasks/mine'ın
// GERÇEK anlamının (bana ATANAN görevler) tek kaynağı. Bkz.
// list_my_tasks_test.go (ListMyTasks semantiği), bu dosya yalnızca
// EmployeeService'in bağlantı/doğrulama davranışını kapsar.

import (
	"context"
	"errors"
	"testing"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

func TestEmployeeUserLink(t *testing.T) {
	dbURL := testDBURL(t)
	ctx := context.Background()

	pool, err := repository.NewPool(ctx, dbURL)
	if err != nil {
		t.Fatalf("db: %v", err)
	}
	t.Cleanup(func() { pool.Close() })

	q := sqlc.New(pool)
	orgSvc := service.NewOrganizationService(q)
	userSvc := service.NewUserService(q)
	employeeSvc := service.NewEmployeeService(pool, q)

	orgA := mustCreateOrg(t, ctx, orgSvc, pool, "EmpLink A", "emplink-a")
	orgB := mustCreateOrg(t, ctx, orgSvc, pool, "EmpLink B", "emplink-b")

	t.Run("1_link_and_read_back", func(t *testing.T) {
		u, err := userSvc.Create(ctx, orgA.ID, "emplink_u1", "GeciciSifre123!", "Test U1", domain.RoleKullanici, "")
		if err != nil {
			t.Fatalf("user: %v", err)
		}
		uid := u.ID
		e, err := employeeSvc.Create(ctx, orgA.ID, service.EmployeeInput{FullName: "Personel 1", IsActive: true, UserID: &uid})
		if err != nil {
			t.Fatalf("create: %v", err)
		}
		if e.UserID == nil || *e.UserID != uid {
			t.Fatalf("bağlantı kaydedilmedi, beklenen %s geldi %v", uid, e.UserID)
		}
		got, err := employeeSvc.Get(ctx, e.ID, orgA.ID)
		if err != nil {
			t.Fatalf("get: %v", err)
		}
		if got.UserID == nil || *got.UserID != uid {
			t.Fatalf("okuma geri bağlantıyı korumadı: %v", got.UserID)
		}
	})

	t.Run("2_cross_org_link_rejected", func(t *testing.T) {
		uB, err := userSvc.Create(ctx, orgB.ID, "emplink_ub", "GeciciSifre123!", "Org B Kullanıcı", domain.RoleKullanici, "")
		if err != nil {
			t.Fatalf("user: %v", err)
		}
		uid := uB.ID
		// orgA'da bir personel, orgB'nin kullanıcısına bağlanmaya ÇALIŞIR.
		_, err = employeeSvc.Create(ctx, orgA.ID, service.EmployeeInput{FullName: "Çapraz Org Denemesi", IsActive: true, UserID: &uid})
		if !errors.Is(err, service.ErrEmployeeUserCrossOrg) {
			t.Fatalf("çapraz-org bağlantı REDDEDİLMELİ, geldi: %v", err)
		}
	})

	t.Run("3_duplicate_active_link_rejected", func(t *testing.T) {
		u, err := userSvc.Create(ctx, orgA.ID, "emplink_dup", "GeciciSifre123!", "Dup Kullanıcı", domain.RoleKullanici, "")
		if err != nil {
			t.Fatalf("user: %v", err)
		}
		uid := u.ID
		if _, err := employeeSvc.Create(ctx, orgA.ID, service.EmployeeInput{FullName: "Personel Dup 1", IsActive: true, UserID: &uid}); err != nil {
			t.Fatalf("first link: %v", err)
		}
		_, err = employeeSvc.Create(ctx, orgA.ID, service.EmployeeInput{FullName: "Personel Dup 2", IsActive: true, UserID: &uid})
		if !errors.Is(err, service.ErrEmployeeUserAlreadyLinked) {
			t.Fatalf("AYNI kullanıcı İKİNCİ bir personele bağlanmaya çalışılırsa REDDEDİLMELİ, geldi: %v", err)
		}
	})

	t.Run("4_unlink_via_update", func(t *testing.T) {
		u, err := userSvc.Create(ctx, orgA.ID, "emplink_unlink", "GeciciSifre123!", "Unlink Kullanıcı", domain.RoleKullanici, "")
		if err != nil {
			t.Fatalf("user: %v", err)
		}
		uid := u.ID
		e, err := employeeSvc.Create(ctx, orgA.ID, service.EmployeeInput{FullName: "Personel Unlink", IsActive: true, UserID: &uid})
		if err != nil {
			t.Fatalf("create: %v", err)
		}
		empty := ""
		updated, err := employeeSvc.Update(ctx, e.ID, orgA.ID, service.EmployeeInput{FullName: "Personel Unlink", IsActive: true, UserID: &empty})
		if err != nil {
			t.Fatalf("update: %v", err)
		}
		if updated.UserID != nil {
			t.Fatalf("boş string gönderilince bağlantı KALDIRILMALI, geldi: %v", *updated.UserID)
		}
		// Bağlantı kaldırıldıktan SONRA, AYNI kullanıcı BAŞKA bir personele
		// bağlanabilmeli (unique index yalnızca AKTİF bağlantıları sayar).
		e2, err := employeeSvc.Create(ctx, orgA.ID, service.EmployeeInput{FullName: "Personel Unlink 2", IsActive: true, UserID: &uid})
		if err != nil {
			t.Fatalf("kaldırılan bağlantının kullanıcısı YENİDEN bağlanabilmeli: %v", err)
		}
		if e2.UserID == nil || *e2.UserID != uid {
			t.Fatalf("yeniden bağlantı kaydedilmedi")
		}
	})

	t.Run("5_existing_employees_and_users_remain_valid", func(t *testing.T) {
		// Bağlantısız (mevcut, migration ÖNCESİ senaryosunu temsil eden)
		// bir personel, bağlantı alanı hiç gönderilmeden normal şekilde
		// oluşturulabilir/okunabilir olmaya devam etmeli.
		e, err := employeeSvc.Create(ctx, orgA.ID, service.EmployeeInput{FullName: "Bağlantısız Personel", IsActive: true})
		if err != nil {
			t.Fatalf("create: %v", err)
		}
		if e.UserID != nil {
			t.Fatalf("UserID göndermeyince bağlantı OLUŞMAMALI, geldi: %v", *e.UserID)
		}
	})
}
