package service_test

// Kişiye özel yetkiler (migration 0044): etkin izin = (rol izinleri −
// kişiye özel revoke) ∪ kişiye özel grant; Sahip bu ayarlardan etkilenmez.
// Bu testler kuralın TEK kaynağı olan GetUserPermissions sorgusunu (yetki
// kontrolü + /auth/me) ve bildirimlerin ters aramasını (ListUsersWith
// Permission) gerçek veritabanına karşı doğrular.

import (
	"context"
	"errors"
	"slices"
	"testing"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

func TestUserPermissionOverrides(t *testing.T) {
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
	authzSvc := service.NewAuthorizationService(pool, q)

	seededOrg := func(name, slug string) domain.Organization {
		org := mustCreateOrg(t, ctx, orgSvc, pool, name, slug)
		orgUUID, err := repository.StringToUUID(org.ID)
		if err != nil {
			t.Fatalf("org id: %v", err)
		}
		if err := q.SeedSystemRolesForOrg(ctx, orgUUID); err != nil {
			t.Fatalf("rol seed: %v", err)
		}
		return org
	}
	orgA := seededOrg("UserPermOverrides A", "userperm-overrides-a")
	orgB := seededOrg("UserPermOverrides B", "userperm-overrides-b")

	newUser := func(org domain.Organization, username, roleCode string) *domain.User {
		u, err := userSvc.Create(ctx, org.ID, username, "GeciciSifre123!", username, "", roleCode)
		if err != nil {
			t.Fatalf("%s oluşturulamadı: %v", username, err)
		}
		return u
	}
	effective := func(userID, orgID string) []string {
		d, err := authzSvc.GetUserPermissionDetail(ctx, userID, orgID)
		if err != nil {
			t.Fatalf("detay: %v", err)
		}
		return d.Effective
	}
	has := func(userID, orgID, code string) bool {
		a, err := authzSvc.LoadAuthzContext(ctx, userID, orgID)
		if err != nil {
			t.Fatalf("authz: %v", err)
		}
		return a.HasPermission(code)
	}
	without := func(codes []string, drop string) []string {
		out := []string{}
		for _, c := range codes {
			if c != drop {
				out = append(out, c)
			}
		}
		return out
	}

	field := newUser(orgA, "userperm_field", domain.OrgRoleField)
	otherField := newUser(orgA, "userperm_field2", domain.OrgRoleField)
	owner := newUser(orgA, "userperm_owner", domain.OrgRoleOwner)
	foreign := newUser(orgB, "userperm_foreign", domain.OrgRoleField)

	base, err := authzSvc.GetUserPermissionDetail(ctx, field.ID, orgA.ID)
	if err != nil {
		t.Fatalf("başlangıç detayı: %v", err)
	}
	if !base.Editable || !slices.Equal(base.Effective, base.RolePermissions) || len(base.Granted)+len(base.Revoked) != 0 {
		t.Fatalf("yeni kullanıcı ayarsız başlamalı ve etkin = rol olmalı: %+v", base)
	}
	if !slices.Contains(base.RolePermissions, "attendance.read") || slices.Contains(base.RolePermissions, "offers.read") {
		t.Fatalf("test varsayımı bozuk: Saha rolü attendance.read içermeli, offers.read içermemeli: %v", base.RolePermissions)
	}

	t.Run("revoke: rolden gelen izin yalnızca bu kişiden kalkar", func(t *testing.T) {
		d, err := authzSvc.SetUserPermissions(ctx, field.ID, orgA.ID, owner.ID, without(base.RolePermissions, "attendance.read"))
		if err != nil {
			t.Fatalf("kaydedilemedi: %v", err)
		}
		if !slices.Equal(d.Revoked, []string{"attendance.read"}) || len(d.Granted) != 0 {
			t.Fatalf("revoke listesi yanlış: %+v", d)
		}
		if has(field.ID, orgA.ID, "attendance.read") {
			t.Fatal("revoke edilen izin yetki kontrolünde hâlâ geçerli")
		}
		if !has(otherField.ID, orgA.ID, "attendance.read") {
			t.Fatal("aynı roldeki BAŞKA kullanıcı etkilenmemeli")
		}
	})

	t.Run("grant: rolde olmayan izin yalnızca bu kişiye eklenir", func(t *testing.T) {
		desired := append(without(base.RolePermissions, "attendance.read"), "offers.read")
		d, err := authzSvc.SetUserPermissions(ctx, field.ID, orgA.ID, owner.ID, desired)
		if err != nil {
			t.Fatalf("kaydedilemedi: %v", err)
		}
		if !slices.Equal(d.Granted, []string{"offers.read"}) || !slices.Equal(d.Revoked, []string{"attendance.read"}) {
			t.Fatalf("grant/revoke yanlış: %+v", d)
		}
		if !has(field.ID, orgA.ID, "offers.read") || has(otherField.ID, orgA.ID, "offers.read") {
			t.Fatal("grant yalnızca hedef kullanıcıya uygulanmalı")
		}
	})

	t.Run("bildirim ters araması aynı etkin kuralı kullanır", func(t *testing.T) {
		orgUUID, _ := repository.StringToUUID(orgA.ID)
		ids := func(code string) []string {
			rows, err := q.ListUsersWithPermission(ctx, sqlc.ListUsersWithPermissionParams{OrganizationID: orgUUID, PermissionCode: code})
			if err != nil {
				t.Fatalf("ters arama: %v", err)
			}
			out := []string{}
			for _, r := range rows {
				out = append(out, r.ID.String())
			}
			return out
		}
		if !slices.Contains(ids("offers.read"), field.ID) {
			t.Fatal("grant edilen izin bildirim alıcılarına yansımalı")
		}
		att := ids("attendance.read")
		if slices.Contains(att, field.ID) || !slices.Contains(att, otherField.ID) {
			t.Fatalf("revoke bildirim alıcılarına yansımalı, diğer Saha etkilenmemeli: %v", att)
		}
	})

	t.Run("rolle aynı küme kaydedilince tüm kişiye özel ayarlar temizlenir", func(t *testing.T) {
		d, err := authzSvc.SetUserPermissions(ctx, field.ID, orgA.ID, owner.ID, base.RolePermissions)
		if err != nil {
			t.Fatalf("kaydedilemedi: %v", err)
		}
		if len(d.Granted)+len(d.Revoked) != 0 || !slices.Equal(d.Effective, base.RolePermissions) {
			t.Fatalf("ayarlar temizlenmedi: %+v", d)
		}
	})

	t.Run("boş küme: Sahip dışındaki kullanıcının tüm izinleri kaldırılabilir", func(t *testing.T) {
		d, err := authzSvc.SetUserPermissions(ctx, field.ID, orgA.ID, owner.ID, []string{})
		if err != nil {
			t.Fatalf("kaydedilemedi: %v", err)
		}
		if len(d.Effective) != 0 || len(effective(field.ID, orgA.ID)) != 0 {
			t.Fatalf("etkin küme boş olmalı: %v", d.Effective)
		}
	})

	t.Run("rol değişince kişiye özel ayarlar sıfırlanır, aynı rol yeniden seçilince korunur", func(t *testing.T) {
		if _, err := authzSvc.SetUserPermissions(ctx, field.ID, orgA.ID, owner.ID, append(slices.Clone(base.RolePermissions), "offers.read")); err != nil {
			t.Fatalf("kaydedilemedi: %v", err)
		}
		if _, err := authzSvc.SetUserOrganizationRole(ctx, field.ID, orgA.ID, "", domain.OrgRoleField); err != nil {
			t.Fatalf("aynı rol: %v", err)
		}
		if !has(field.ID, orgA.ID, "offers.read") {
			t.Fatal("aynı rol yeniden seçilince ayarlar korunmalı")
		}
		if _, err := authzSvc.SetUserOrganizationRole(ctx, field.ID, orgA.ID, "", domain.OrgRoleFinance); err != nil {
			t.Fatalf("rol değişimi: %v", err)
		}
		d, err := authzSvc.GetUserPermissionDetail(ctx, field.ID, orgA.ID)
		if err != nil {
			t.Fatalf("detay: %v", err)
		}
		if d.RoleCode != domain.OrgRoleFinance || len(d.Granted)+len(d.Revoked) != 0 || !slices.Equal(d.Effective, d.RolePermissions) {
			t.Fatalf("rol değişiminde ayarlar sıfırlanmalı: %+v", d)
		}
	})

	t.Run("Sahip: kişiye özel ayar reddedilir ve DB'de kalmış bir ayar bile uygulanmaz", func(t *testing.T) {
		if _, err := authzSvc.SetUserPermissions(ctx, owner.ID, orgA.ID, owner.ID, []string{}); !errors.Is(err, domain.ErrOwnerPermissionsFixed) {
			t.Fatalf("Sahip için ErrOwnerPermissionsFixed bekleniyordu, geldi: %v", err)
		}
		// Kilitlenme koruması sorgu seviyesinde: servis katmanını atlayan bir
		// revoke satırı olsa bile Sahip'in etkin izinlerine dokunmamalı.
		if _, err := pool.Exec(ctx,
			"INSERT INTO user_permission_overrides (user_id, organization_id, permission_code, effect) VALUES ($1, $2, 'organization.roles.manage', 'revoke')",
			owner.ID, orgA.ID); err != nil {
			t.Fatalf("ham satır eklenemedi: %v", err)
		}
		if !has(owner.ID, orgA.ID, "organization.roles.manage") {
			t.Fatal("Sahip kişiye özel revoke ile kilitlenmemeli")
		}
		d, err := authzSvc.GetUserPermissionDetail(ctx, owner.ID, orgA.ID)
		if err != nil {
			t.Fatalf("detay: %v", err)
		}
		if d.Editable || len(d.Revoked) != 0 {
			t.Fatalf("Sahip düzenlenemez görünmeli ve uygulanmayan ayar raporlanmamalı: %+v", d)
		}
	})

	t.Run("Sahip rolünün izinleri değiştirilemez; kısılmış rol satırları bile Sahip'i kilitlemez", func(t *testing.T) {
		roles, err := authzSvc.ListOrganizationRoles(ctx, orgA.ID, false)
		if err != nil {
			t.Fatalf("roller: %v", err)
		}
		var ownerRoleID string
		for _, r := range roles {
			if r.Code == domain.OrgRoleOwner {
				ownerRoleID = r.ID
			}
		}
		if ownerRoleID == "" {
			t.Fatal("Sahip rolü bulunamadı")
		}
		if _, err := authzSvc.SetRolePermissions(ctx, ownerRoleID, orgA.ID, []string{"projects.read"}); !errors.Is(err, domain.ErrOwnerRoleLocked) {
			t.Fatalf("ErrOwnerRoleLocked bekleniyordu, geldi: %v", err)
		}
		// Kilit öncesi webden kısılmış bir Sahip rolü: etkin izinler yine tam.
		if _, err := pool.Exec(ctx, "DELETE FROM role_permissions WHERE organization_role_id = $1 AND permission_code = 'organization.roles.manage'", ownerRoleID); err != nil {
			t.Fatalf("ham silme: %v", err)
		}
		if !has(owner.ID, orgA.ID, "organization.roles.manage") {
			t.Fatal("Sahip, rol satırı eksik olsa da tüm izinlere sahip olmalı")
		}
	})

	t.Run("tanımsız izin kodu reddedilir", func(t *testing.T) {
		if _, err := authzSvc.SetUserPermissions(ctx, otherField.ID, orgA.ID, owner.ID, []string{"boyle.bir.izin.yok"}); !errors.Is(err, domain.ErrUnknownPermission) {
			t.Fatalf("ErrUnknownPermission bekleniyordu, geldi: %v", err)
		}
	})

	t.Run("Yönetici'ye kilitli izinler Sahip/Yönetici dışındakilere eklenemez, Yönetici'den çıkarılabilir", func(t *testing.T) {
		before := effective(otherField.ID, orgA.ID)
		for _, code := range []string{"organization.users.read", "organization.roles.manage", "organization.settings.read"} {
			if _, err := authzSvc.SetUserPermissions(ctx, otherField.ID, orgA.ID, owner.ID, append(slices.Clone(before), code)); !errors.Is(err, domain.ErrPermissionNeedsAdminRole) {
				t.Fatalf("%s için ErrPermissionNeedsAdminRole bekleniyordu, geldi: %v", code, err)
			}
		}
		if !slices.Equal(effective(otherField.ID, orgA.ID), before) {
			t.Fatal("reddedilen istek kişinin izinlerini değiştirmemeli")
		}

		admin := newUser(orgA, "userperm_admin", domain.OrgRoleAdmin)
		adminBase := effective(admin.ID, orgA.ID)
		d, err := authzSvc.SetUserPermissions(ctx, admin.ID, orgA.ID, owner.ID, without(adminBase, "organization.users.read"))
		if err != nil {
			t.Fatalf("Yönetici'den kullanıcı görüntüleme izni çıkarılabilmeli: %v", err)
		}
		if !slices.Equal(d.Revoked, []string{"organization.users.read"}) || has(admin.ID, orgA.ID, "organization.users.read") {
			t.Fatalf("Yönetici revoke'u uygulanmadı: %+v", d)
		}
		if _, err := authzSvc.SetUserPermissions(ctx, admin.ID, orgA.ID, owner.ID, adminBase); err != nil {
			t.Fatalf("Yönetici rolünde olan izin geri verilebilmeli (grant değil, rol varsayılanı): %v", err)
		}
	})

	t.Run("başka firmanın kullanıcısına erişilemez", func(t *testing.T) {
		if _, err := authzSvc.SetUserPermissions(ctx, foreign.ID, orgA.ID, owner.ID, []string{}); !errors.Is(err, domain.ErrNotFound) {
			t.Fatalf("çapraz firma için ErrNotFound bekleniyordu, geldi: %v", err)
		}
		if _, err := authzSvc.GetUserPermissionDetail(ctx, foreign.ID, orgA.ID); !errors.Is(err, domain.ErrNotFound) {
			t.Fatalf("çapraz firma okuma için ErrNotFound bekleniyordu, geldi: %v", err)
		}
	})

	t.Run("silinmiş kullanıcıya ayar yapılamaz", func(t *testing.T) {
		if _, err := pool.Exec(ctx, "UPDATE users SET deleted_at = now(), is_active = false WHERE id = $1", otherField.ID); err != nil {
			t.Fatalf("silme: %v", err)
		}
		if _, err := authzSvc.SetUserPermissions(ctx, otherField.ID, orgA.ID, owner.ID, []string{}); !errors.Is(err, domain.ErrUserDeleted) {
			t.Fatalf("ErrUserDeleted bekleniyordu, geldi: %v", err)
		}
	})
}
