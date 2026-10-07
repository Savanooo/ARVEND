package service_test

// Refresh token rotasyonunun kısa toleransı: iki sekme aynı token'la aynı
// anda yenileyince ikisi de oturumda kalmalı; ama tolerans süresi, çıkış ve
// pasifleştirmeden sonra eski token hiçbir şey açmamalı.

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/Savanooo/ARVEND/backend/internal/auth"
	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

func TestRefreshRotationGrace(t *testing.T) {
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
	authSvc := service.NewAuthService(q, auth.NewJWTIssuer("test-secret-refresh-grace", 15*time.Minute), 24*time.Hour)

	org := mustCreateOrg(t, ctx, orgSvc, pool, "Refresh Grace", "refresh-grace")
	_, _ = pool.Exec(ctx, "DELETE FROM users WHERE username = 'refresh_grace_u'")
	u, err := userSvc.Create(ctx, org.ID, "refresh_grace_u", "GeciciSifre123!", "Sekmeli Kullanıcı", domain.RoleKullanici, "")
	if err != nil {
		t.Fatal(err)
	}
	login := func(t *testing.T) string {
		t.Helper()
		s, err := authSvc.Login(ctx, "refresh_grace_u", "GeciciSifre123!")
		if err != nil {
			t.Fatal(err)
		}
		return s.RefreshToken
	}
	ageRotation := func(t *testing.T, raw string, by time.Duration) {
		t.Helper()
		if _, err := pool.Exec(ctx, `UPDATE refresh_tokens SET rotated_at = rotated_at - $2::interval WHERE token_hash = $1`,
			auth.HashRefreshToken(raw), by.String()); err != nil {
			t.Fatal(err)
		}
	}

	t.Run("aynı token'la eşzamanlı iki yenileme ikisi de başarılı", func(t *testing.T) {
		tok := login(t)
		var wg sync.WaitGroup
		errs := make([]error, 2)
		sessions := make([]*service.Session, 2)
		start := make(chan struct{})
		for i := range 2 {
			wg.Add(1)
			go func() {
				defer wg.Done()
				<-start
				sessions[i], errs[i] = authSvc.Refresh(ctx, tok)
			}()
		}
		close(start)
		wg.Wait()
		for i, e := range errs {
			if e != nil {
				t.Fatalf("yenileme %d düştü: %v", i, e)
			}
		}
		// İki yeni token da geçerli ve birbirinden farklı.
		if sessions[0].RefreshToken == sessions[1].RefreshToken {
			t.Error("iki ayrı token beklendi")
		}
		for i, s := range sessions {
			if _, err := authSvc.Refresh(ctx, s.RefreshToken); err != nil {
				t.Errorf("yeni token %d kullanılabilmeli: %v", i, err)
			}
		}
	})

	t.Run("tolerans süresi geçince eski token reddedilir", func(t *testing.T) {
		tok := login(t)
		if _, err := authSvc.Refresh(ctx, tok); err != nil {
			t.Fatal(err)
		}
		ageRotation(t, tok, time.Minute)
		if _, err := authSvc.Refresh(ctx, tok); !errors.Is(err, domain.ErrInvalidToken) {
			t.Errorf("süresi geçmiş tolerans: ErrInvalidToken beklendi, %v", err)
		}
	})

	t.Run("çıkıştan sonra önceki token toleransla oturum açamaz", func(t *testing.T) {
		tok := login(t)
		s, err := authSvc.Refresh(ctx, tok)
		if err != nil {
			t.Fatal(err)
		}
		if err := authSvc.Logout(ctx, s.RefreshToken); err != nil {
			t.Fatal(err)
		}
		if _, err := authSvc.Refresh(ctx, tok); !errors.Is(err, domain.ErrInvalidToken) {
			t.Errorf("çıkış sonrası: ErrInvalidToken beklendi, %v", err)
		}
		if _, err := authSvc.Refresh(ctx, s.RefreshToken); !errors.Is(err, domain.ErrInvalidToken) {
			t.Errorf("çıkış yapılan token: ErrInvalidToken beklendi, %v", err)
		}
	})

	t.Run("pasifleştirilen kullanıcı toleransla geri dönemez", func(t *testing.T) {
		tok := login(t)
		if _, err := authSvc.Refresh(ctx, tok); err != nil {
			t.Fatal(err)
		}
		if err := userSvc.Deactivate(ctx, u.ID, org.ID, ""); err != nil {
			t.Fatal(err)
		}
		if _, err := authSvc.Refresh(ctx, tok); err == nil {
			t.Error("pasif kullanıcıya tolerans yoluyla oturum verilmemeli")
		}
	})
}
