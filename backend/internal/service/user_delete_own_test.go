package service_test

// UserService.DeleteOwnAccount: kullanıcının kendi hesabını uygulamadan
// silmesi (App Store 5.1.1(v), KVKK). Şifre onayı, firmanın tek Sahibi
// koruması ve geri dönüşsüz anonimleştirme.

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

func TestUserServiceDeleteOwnAccount(t *testing.T) {
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

	org := mustCreateOrg(t, ctx, orgSvc, pool, "SelfDelete Org", "usersvc-selfdelete")
	orgUUID, err := repository.StringToUUID(org.ID)
	if err != nil {
		t.Fatalf("org id: %v", err)
	}
	if err := q.SeedSystemRolesForOrg(ctx, orgUUID); err != nil {
		t.Fatalf("rol seed: %v", err)
	}

	suffix := fmt.Sprintf("%d", time.Now().UnixNano()%1_000_000_000)
	const password = "GeciciSifre123!"
	owner, err := userSvc.Create(ctx, org.ID, "selfdel_owner_"+suffix, password, "Tek Sahip", domain.RoleAdmin, domain.OrgRoleOwner)
	if err != nil {
		t.Fatalf("sahip: %v", err)
	}
	member, err := userSvc.Create(ctx, org.ID, "selfdel_field_"+suffix, password, "Saha Çalışanı", domain.RoleKullanici, domain.OrgRoleField)
	if err != nil {
		t.Fatalf("saha: %v", err)
	}

	t.Run("yanlış şifreyle silinmez", func(t *testing.T) {
		err := userSvc.DeleteOwnAccount(ctx, member.ID, org.ID, "yanlis-sifre")
		if !errors.Is(err, domain.ErrInvalidCredentials) {
			t.Fatalf("beklenen ErrInvalidCredentials, geldi: %v", err)
		}
		row := mustUserRow(t, ctx, q, member.ID)
		if row.DeletedAt.Valid || !row.IsActive {
			t.Fatal("yanlış şifreden sonra hesap silinmiş/pasifleşmiş olmamalı")
		}
	})

	t.Run("firmanın tek Sahibi kendini silemez", func(t *testing.T) {
		err := userSvc.DeleteOwnAccount(ctx, owner.ID, org.ID, password)
		if !errors.Is(err, domain.ErrLastOwner) {
			t.Fatalf("beklenen ErrLastOwner, geldi: %v", err)
		}
		if row := mustUserRow(t, ctx, q, owner.ID); row.DeletedAt.Valid || !row.IsActive {
			t.Fatal("tek Sahip silinmemeli")
		}
	})

	t.Run("doğru şifreyle silinir ve kişisel bilgiler gider", func(t *testing.T) {
		if err := userSvc.DeleteOwnAccount(ctx, member.ID, org.ID, password); err != nil {
			t.Fatalf("silme: %v", err)
		}
		row := mustUserRow(t, ctx, q, member.ID)
		if !row.DeletedAt.Valid || row.IsActive {
			t.Fatalf("silinmiş ve pasif olmalı: deleted=%v active=%v", row.DeletedAt.Valid, row.IsActive)
		}
		if !strings.HasPrefix(row.Username, "silinmis-") || strings.Contains(row.Username, "selfdel_field") {
			t.Fatalf("kullanıcı adı anonimleşmeli, geldi: %q", row.Username)
		}
		if row.FullName != service.DeletedUserFullName {
			t.Fatalf("ad %q olmalı, geldi: %q", service.DeletedUserFullName, row.FullName)
		}
		// Eski şifre artık hiçbir şeyi açmaz: ikinci bir silme denemesi
		// şifreyi tutturamaz (özet rastgele bir sırla değişti).
		if err := userSvc.DeleteOwnAccount(ctx, member.ID, org.ID, password); !errors.Is(err, domain.ErrInvalidCredentials) {
			t.Fatalf("silinen hesabın eski şifresi tutmamalı, geldi: %v", err)
		}
	})

	t.Run("silinen kullanıcının adı yeniden kullanılabilir", func(t *testing.T) {
		if _, err := userSvc.Create(ctx, org.ID, "selfdel_field_"+suffix, password, "Yeni Kişi", domain.RoleKullanici, domain.OrgRoleField); err != nil {
			t.Fatalf("aynı kullanıcı adıyla yeni hesap açılabilmeli: %v", err)
		}
	})
}

func mustUserRow(t *testing.T, ctx context.Context, q *sqlc.Queries, id string) sqlc.User {
	t.Helper()
	uid, err := repository.StringToUUID(id)
	if err != nil {
		t.Fatalf("user id: %v", err)
	}
	row, err := q.GetUserByID(ctx, uid)
	if err != nil {
		t.Fatalf("kullanıcı okunamadı: %v", err)
	}
	return row
}
