package service_test

// "Tümünü okundu işaretle" yalnızca istemcinin GÖRDÜĞÜ listeye kadar
// işaretler: liste açıldıktan sonra gelen bildirim görülmeden okundu
// sayılmaz. Sınır göndermeyen eski istemciler eskisi gibi hepsini okur.
// Gerçek bir PostgreSQL bağlantısı gerektirir.

import (
	"context"
	"testing"
	"time"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

func TestMarkAllReadBound(t *testing.T) {
	dbURL := testDBURL(t)
	ctx := context.Background()
	pool, err := repository.NewPool(ctx, dbURL)
	if err != nil {
		t.Fatalf("veritabanına bağlanılamadı: %v", err)
	}
	t.Cleanup(func() { pool.Close() })
	q := sqlc.New(pool)
	orgSvc := service.NewOrganizationService(q)
	userSvc := service.NewUserService(pool, q)
	notifSvc := service.NewNotificationService(q)

	org := mustCreateOrg(t, ctx, orgSvc, pool, "Bildirim Sınır Test", "bildirim-sinir-test")
	_, _ = pool.Exec(ctx, "DELETE FROM users WHERE username = 'bildirim_sinir_u'")
	u, err := userSvc.Create(ctx, org.ID, "bildirim_sinir_u", "GeciciSifre123!", "Muhasebe", domain.RoleKullanici, "")
	if err != nil {
		t.Fatal(err)
	}
	orgUUID := mustUUID(t, org.ID)
	userUUID := mustUUID(t, u.ID)

	// Saat: listenin en yenisi "seen"; ondan önce ve SONRA birer bildirim.
	seenAt := time.Now().Add(-10 * time.Minute).Truncate(time.Second).Add(400 * time.Millisecond)
	create := func(t *testing.T, title string, at time.Time) string {
		t.Helper()
		n, err := q.CreateNotification(ctx, sqlc.CreateNotificationParams{
			OrganizationID: orgUUID, UserID: userUUID, Type: "task_assigned", Title: title, Body: "",
			EntityType: "task",
		})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := pool.Exec(ctx, "UPDATE notifications SET created_at = $2 WHERE id = $1", n.ID, at); err != nil {
			t.Fatal(err)
		}
		return n.ID.String()
	}
	unread := func(t *testing.T) map[string]bool {
		t.Helper()
		res, err := notifSvc.List(ctx, u.ID, org.ID, 1, 100)
		if err != nil {
			t.Fatal(err)
		}
		out := map[string]bool{}
		for _, n := range res.Notifications {
			if n.ReadAt == nil {
				out[n.Title] = true
			}
		}
		return out
	}

	create(t, "eski", seenAt.Add(-time.Hour))
	create(t, "görülen", seenAt)
	create(t, "aynı saniyede", seenAt.Add(300*time.Millisecond))
	create(t, "sonradan gelen", seenAt.Add(2*time.Second))

	// İstemci, listedeki created_at'i RFC3339 (saniye) olarak gördü.
	before, err := time.Parse(time.RFC3339, seenAt.UTC().Format(time.RFC3339))
	if err != nil {
		t.Fatal(err)
	}
	if err := notifSvc.MarkAllRead(ctx, u.ID, org.ID, &before); err != nil {
		t.Fatal(err)
	}
	got := unread(t)
	if len(got) != 1 || !got["sonradan gelen"] {
		t.Fatalf("yalnızca listeden sonra gelen okunmamış kalmalı, kalan: %v", got)
	}
	if n, _ := notifSvc.UnreadCount(ctx, u.ID, org.ID); n != 1 {
		t.Errorf("zil sayacı 1 olmalı: %d", n)
	}

	// Sınırsız (eski istemci): hepsi okunur.
	if err := notifSvc.MarkAllRead(ctx, u.ID, org.ID, nil); err != nil {
		t.Fatal(err)
	}
	if got := unread(t); len(got) != 0 {
		t.Fatalf("sınırsız çağrı hepsini okumalı, kalan: %v", got)
	}
}
