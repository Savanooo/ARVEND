package service_test

import (
	"context"
	"strings"
	"sync"
	"testing"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/platform/fcm"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

type fakeSender struct {
	mu   sync.Mutex
	sent []fcm.Message
}

func (f *fakeSender) Send(_ context.Context, m fcm.Message) error {
	if strings.HasPrefix(m.Token, "olu-") {
		return fcm.ErrUnregistered
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	f.sent = append(f.sent, m)
	return nil
}

func (f *fakeSender) take() []fcm.Message {
	f.mu.Lock()
	defer f.mu.Unlock()
	out := f.sent
	f.sent = nil
	return out
}

func TestPushAndAnnouncements(t *testing.T) {
	dbURL := testDBURL(t)
	ctx := context.Background()
	pool, err := repository.NewPool(ctx, dbURL)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { pool.Close() })
	q := sqlc.New(pool)
	userSvc := service.NewUserService(pool, q)
	authzSvc := service.NewAuthorizationService(pool, q)
	notifSvc := service.NewNotificationService(q)
	platformSvc := service.NewPlatformService(pool, q, userSvc, service.NewCalcService(q), service.NewProductService(q))
	sender := &fakeSender{}
	pushSvc := service.NewPushService(q, sender)

	mkOrg := func(slug string) *service.CreateOrganizationResult {
		t.Helper()
		var existing string
		if pool.QueryRow(ctx, "SELECT id FROM organizations WHERE slug = $1", slug).Scan(&existing) == nil {
			cleanupOrganization(t, pool, existing)
		}
		res, err := platformSvc.CreateOrganizationWithOwner(ctx, service.CreateOrganizationInput{
			Name: "Push " + slug, Slug: slug,
			OwnerUsername: "owner_" + slug, OwnerPassword: "GeciciSifre123!", OwnerFullName: "Push Owner",
		})
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { cleanupOrganization(t, pool, res.Organization.ID) })
		return res
	}
	mkUser := func(orgID, username string) *domain.User {
		t.Helper()
		u, err := userSvc.Create(ctx, orgID, username, "GeciciSifre123!", "Kişi "+username, domain.RoleKullanici, "")
		if err != nil {
			t.Fatal(err)
		}
		if _, err := authzSvc.SetUserOrganizationRole(ctx, u.ID, orgID, "", domain.OrgRoleField); err != nil {
			t.Fatal(err)
		}
		return u
	}
	unread := func(userID, orgID string) []domain.Notification {
		t.Helper()
		res, err := notifSvc.List(ctx, userID, orgID, 1, 50)
		if err != nil {
			t.Fatal(err)
		}
		return res.Notifications
	}

	a := mkOrg("push-test-a")
	b := mkOrg("push-test-b")
	ali := mkUser(a.Organization.ID, "push_ali")
	veli := mkUser(a.Organization.ID, "push_veli")
	pasif := mkUser(a.Organization.ID, "push_pasif")
	if _, err := pool.Exec(ctx, "UPDATE users SET is_active = false WHERE id = $1", pasif.ID); err != nil {
		t.Fatal(err)
	}
	bUser := mkUser(b.Organization.ID, "push_b")

	tokAli := "fcm-token-ali-" + strings.Repeat("x", 30)
	tokVeli := "fcm-token-veli-" + strings.Repeat("y", 30)
	for _, d := range []struct{ org, user, tok string }{
		{a.Organization.ID, ali.ID, tokAli},
		{a.Organization.ID, veli.ID, tokVeli},
		{a.Organization.ID, veli.ID, "olu-" + strings.Repeat("z", 30)},
	} {
		if err := pushSvc.RegisterDevice(ctx, d.org, d.user, d.tok, "android", "1.5.7"); err != nil {
			t.Fatal(err)
		}
	}
	if err := pushSvc.RegisterDevice(ctx, a.Organization.ID, ali.ID, "kısa", "android", ""); err == nil {
		t.Error("kısa token reddedilmeli")
	}
	_, _ = pushSvc.DispatchOnce(ctx) // bu test öncesinden kalanlar

	t.Run("firma duyurusu: aktif ekip, gönderen hariç, telefonlara gider", func(t *testing.T) {
		n, err := pushSvc.SendAnnouncement(ctx, service.AnnouncementInput{
			Title: "Yarın şantiye kapalı", Body: "Yağmur nedeniyle çalışma yok.",
			OrganizationIDs: []string{a.Organization.ID}, SenderID: a.Owner.ID,
		})
		if err != nil {
			t.Fatal(err)
		}
		if n != 2 { // ali + veli; owner gönderen, pasif hariç
			t.Fatalf("alıcı sayısı 2 olmalı: %d", n)
		}
		if got := unread(ali.ID, a.Organization.ID); len(got) != 1 || got[0].Type != "announcement" || got[0].ActionTarget != "/diger/bildirimler" {
			t.Errorf("ali duyuruyu zilde görmeli: %+v", got)
		}
		if got := unread(pasif.ID, a.Organization.ID); len(got) != 0 {
			t.Errorf("pasif kullanıcıya gitmemeli")
		}
		if got := unread(bUser.ID, b.Organization.ID); len(got) != 0 {
			t.Errorf("başka firmaya gitmemeli")
		}

		sentCount, err := pushSvc.DispatchOnce(ctx)
		if err != nil {
			t.Fatal(err)
		}
		msgs := sender.take()
		if sentCount != 2 || len(msgs) != 2 {
			t.Fatalf("iki telefona gitmeli (ölü cihaz hariç): %d %+v", sentCount, msgs)
		}
		for _, m := range msgs {
			if m.Title != "Yarın şantiye kapalı" || m.Data["action_target"] != "/diger/bildirimler" || m.Tag == "" {
				t.Errorf("mesaj: %+v", m)
			}
		}
		// Ölü cihaz silindi; ikinci tur bir şey göndermez.
		var dead int
		_ = pool.QueryRow(ctx, "SELECT count(*) FROM push_devices WHERE token LIKE 'olu-%'").Scan(&dead)
		if dead != 0 {
			t.Errorf("geçersiz cihaz silinmeli")
		}
		if n, _ := pushSvc.DispatchOnce(ctx); n != 0 {
			t.Errorf("aynı bildirim iki kez gönderilmemeli: %d", n)
		}
	})

	t.Run("platform duyurusu: boş liste tüm firmalar", func(t *testing.T) {
		n, err := pushSvc.SendAnnouncement(ctx, service.AnnouncementInput{
			Title: "Bakım", Body: "Bu gece 23:00'te kısa bakım.", SenderID: a.Owner.ID,
		})
		if err != nil {
			t.Fatal(err)
		}
		if n < 3 { // en az a'nın ali+veli'si ve b'nin iki kullanıcısı (diğer test firmaları da sayılabilir)
			t.Errorf("tüm firmalara gitmeli: %d", n)
		}
		if got := unread(bUser.ID, b.Organization.ID); len(got) != 1 {
			t.Errorf("b firması da almalı: %+v", got)
		}
		_, _ = pushSvc.DispatchOnce(ctx)
		sender.take()
		if _, err := pushSvc.SendAnnouncement(ctx, service.AnnouncementInput{Title: " ", Body: "x", SenderID: a.Owner.ID}); err == nil {
			t.Error("boş başlık reddedilmeli")
		}
	})

	t.Run("öneri: her kullanıcı yazar, platform listesinde firma adıyla görünür", func(t *testing.T) {
		fb := service.NewFeedbackService(q)
		if err := fb.Submit(ctx, a.Organization.ID, ali.ID, "", "  ", ""); err == nil {
			t.Error("boş öneri reddedilmeli")
		}
		if err := fb.Submit(ctx, a.Organization.ID, ali.ID, "rüşvet", "x", ""); err == nil {
			t.Error("bilinmeyen tür reddedilmeli")
		}
		if err := fb.Submit(ctx, a.Organization.ID, ali.ID, "hata", "Mesai ekranında tarih kayıyor", "1.5.7+13"); err != nil {
			t.Fatal(err)
		}
		list, err := fb.List(ctx, true, 1, 100)
		if err != nil {
			t.Fatal(err)
		}
		var mine *service.FeedbackMessage
		for i := range list.Messages {
			if list.Messages[i].Body == "Mesai ekranında tarih kayıyor" {
				mine = &list.Messages[i]
			}
		}
		if mine == nil || mine.OrganizationName != "Push push-test-a" || mine.UserName != "Kişi push_ali" || mine.Category != "hata" || mine.AppVersion != "1.5.7+13" {
			t.Fatalf("öneri listede firma ve kişiyle görünmeli: %+v", mine)
		}
		if err := fb.MarkRead(ctx, mine.ID); err != nil {
			t.Fatal(err)
		}
		again, _ := fb.List(ctx, true, 1, 100)
		for _, m := range again.Messages {
			if m.ID == mine.ID {
				t.Error("okunan öneri 'okunmamış' listesinde kalmamalı")
			}
		}
		if err := fb.MarkRead(ctx, mine.ID); err != nil {
			t.Errorf("ikinci kez okundu işareti hata vermemeli: %v", err)
		}
	})

	t.Run("eski bildirim telefona yağmaz, token kullanıcı değiştirir, çıkış siler", func(t *testing.T) {
		if _, err := pushSvc.SendAnnouncement(ctx, service.AnnouncementInput{
			Title: "Eski", Body: "eski", OrganizationIDs: []string{a.Organization.ID}, SenderID: a.Owner.ID,
		}); err != nil {
			t.Fatal(err)
		}
		if _, err := pool.Exec(ctx, "UPDATE notifications SET created_at = now() - interval '1 hour' WHERE title = 'Eski' AND pushed_at IS NULL"); err != nil {
			t.Fatal(err)
		}
		if n, _ := pushSvc.DispatchOnce(ctx); n != 0 {
			t.Errorf("15 dakikadan eski bildirim gönderilmemeli: %d", n)
		}
		// Ali'nin telefonunda Veli oturum açtı.
		if err := pushSvc.RegisterDevice(ctx, a.Organization.ID, veli.ID, tokAli, "android", "1.5.7"); err != nil {
			t.Fatal(err)
		}
		if _, err := pushSvc.SendAnnouncement(ctx, service.AnnouncementInput{
			Title: "Yeni", Body: "yeni", OrganizationIDs: []string{a.Organization.ID}, SenderID: a.Owner.ID,
		}); err != nil {
			t.Fatal(err)
		}
		_, _ = pushSvc.DispatchOnce(ctx)
		msgs := sender.take()
		// Ali'nin artık telefonu yok; Veli'nin iki telefonu var.
		if len(msgs) != 2 {
			t.Fatalf("yalnızca Veli'nin iki telefonu: %+v", msgs)
		}
		if err := pushSvc.UnregisterDevice(ctx, veli.ID, tokAli); err != nil {
			t.Fatal(err)
		}
		var c int
		_ = pool.QueryRow(ctx, "SELECT count(*) FROM push_devices WHERE token = $1", tokAli).Scan(&c)
		if c != 0 {
			t.Errorf("çıkışta cihaz silinmeli")
		}
	})
}
