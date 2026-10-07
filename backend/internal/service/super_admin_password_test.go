package service_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/Savanooo/ARVEND/backend/internal/auth"
	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

// Super Admin'in şifresi yalnızca sunucudaki CLI ile değişir
// (cmd/reset-platform-admin-password): yeni şifre geçer, eskisi geçmez, eski
// oturumlar kapanır ve araç bir firma kullanıcısının şifresine dokunamaz.
func TestResetSuperAdminPassword(t *testing.T) {
	dbURL := testDBURL(t)
	ctx := context.Background()
	pool, err := repository.NewPool(ctx, dbURL)
	if err != nil {
		t.Fatalf("db: %v", err)
	}
	t.Cleanup(func() { pool.Close() })
	q := sqlc.New(pool)
	userSvc := service.NewUserService(pool, q)
	orgSvc := service.NewOrganizationService(q)
	platformSvc := service.NewPlatformService(pool, q, userSvc, service.NewCalcService(q), service.NewProductService(q))
	authSvc := service.NewAuthService(q, auth.NewJWTIssuer("test-secret-sa-reset", 15*time.Minute), 24*time.Hour)

	const sa, tenantUser = "sa_reset_test", "sa_reset_tenant"
	cleanup := func() {
		_, _ = pool.Exec(ctx, "DELETE FROM refresh_tokens WHERE user_id IN (SELECT id FROM users WHERE username = ANY($1::text[]))", []string{sa, tenantUser})
		_, _ = pool.Exec(ctx, "DELETE FROM users WHERE username = ANY($1::text[])", []string{sa, tenantUser})
	}
	cleanup()
	t.Cleanup(cleanup)

	if _, err := platformSvc.CreateSuperAdmin(ctx, sa, "EskiSifre123!", "Platform Test"); err != nil {
		t.Fatalf("Super Admin oluşturulamadı: %v", err)
	}
	session, err := authSvc.Login(ctx, sa, "EskiSifre123!")
	if err != nil {
		t.Fatalf("eski şifreyle giriş: %v", err)
	}

	if err := platformSvc.ResetSuperAdminPassword(ctx, sa, "kisa"); !errors.Is(err, domain.ErrPasswordTooShort) {
		t.Errorf("kısa şifre reddedilmeli: %v", err)
	}
	if err := platformSvc.ResetSuperAdminPassword(ctx, sa, "YeniSifre456!"); err != nil {
		t.Fatalf("şifre değişmedi: %v", err)
	}
	if _, err := authSvc.Login(ctx, sa, "YeniSifre456!"); err != nil {
		t.Errorf("yeni şifreyle giriş olmalı: %v", err)
	}
	if _, err := authSvc.Login(ctx, sa, "EskiSifre123!"); err == nil {
		t.Error("eski şifre artık geçmemeli")
	}
	var revoked bool
	if err := pool.QueryRow(ctx, "SELECT revoked_at IS NOT NULL FROM refresh_tokens WHERE token_hash = $1",
		auth.HashRefreshToken(session.RefreshToken)).Scan(&revoked); err != nil || !revoked {
		t.Errorf("eski oturum kapanmalı: revoked=%v err=%v", revoked, err)
	}

	// Firma kullanıcısının şifresine dokunamaz.
	org := mustCreateOrg(t, ctx, orgSvc, pool, "SA Reset Firma", "sa-reset-firma")
	if _, err := userSvc.Create(ctx, org.ID, tenantUser, "FirmaSifre123!", "Firma Kullanıcısı", domain.RoleKullanici, ""); err != nil {
		t.Fatal(err)
	}
	if err := platformSvc.ResetSuperAdminPassword(ctx, tenantUser, "Degisti789!"); !errors.Is(err, domain.ErrNotFound) {
		t.Errorf("firma kullanıcısı bulunmamalı: %v", err)
	}
	if _, err := authSvc.Login(ctx, tenantUser, "FirmaSifre123!"); err != nil {
		t.Errorf("firma kullanıcısının şifresi değişmemeli: %v", err)
	}
	if err := platformSvc.ResetSuperAdminPassword(ctx, "boyle_biri_yok", "YeniSifre456!"); !errors.Is(err, domain.ErrNotFound) {
		t.Errorf("olmayan kullanıcı: %v", err)
	}
}
