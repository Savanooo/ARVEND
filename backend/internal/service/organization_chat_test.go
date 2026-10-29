package service_test

// Firma Grubu (migration 0077) -- gerçek bir PostgreSQL bağlantısı ve
// SETTINGS_ENCRYPTION_KEY gerektirir (taşeron girişi şifreli ayarlarla
// açılır). Uç güvenliği: middleware/organization_chat_security_test.go ve
// subcontractor_portal_security_test.go (taşeron hesabı bütün rotalarda 403).

import (
	"bytes"
	"context"
	"errors"
	"io"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

// tinyPNG: 1x1 piksel geçerli PNG (içerikten tür tespiti için yeterli).
var tinyPNG = []byte{
	0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
	0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4,
	0x89, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0xf8, 0xcf, 0xc0, 0x00,
	0x00, 0x03, 0x01, 0x01, 0x00, 0xc9, 0xfe, 0x92, 0xef, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e,
	0x44, 0xae, 0x42, 0x60, 0x82,
}

type chatNotif struct {
	ID, Title, Body, Target, EntityID string
	GroupCount                        int
	Read, Pushed                      bool
}

func TestOrganizationChat(t *testing.T) {
	dbURL := testDBURL(t)
	box := testSecretBox(t)
	ctx := context.Background()
	pool, err := repository.NewPool(ctx, dbURL)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { pool.Close() })
	q := sqlc.New(pool)
	userSvc := service.NewUserService(pool, q)
	authzSvc := service.NewAuthorizationService(pool, q)
	supplierSvc := service.NewSupplierService(pool, q, box)
	platformSvc := service.NewPlatformService(pool, q, userSvc, service.NewCalcService(q), service.NewProductService(q))
	store := mustTestStore(t)
	chat := service.NewOrganizationChatService(pool, q, store)
	// Sayfalama/gruplama çok mesaj yazar; sınır testi kendi sınırını kurar.
	service.SetChatRateLimitForTest(chat, 1000)

	mkOrg := func(slug string) *service.CreateOrganizationResult {
		t.Helper()
		var existing string
		if pool.QueryRow(ctx, "SELECT id FROM organizations WHERE slug = $1", slug).Scan(&existing) == nil {
			cleanupOrganization(t, pool, existing)
		}
		res, err := platformSvc.CreateOrganizationWithOwner(ctx, service.CreateOrganizationInput{
			Name: "Grup " + slug, Slug: slug,
			OwnerUsername: "owner_" + slug, OwnerPassword: "GeciciSifre123!", OwnerFullName: "Ayşe Sahip",
		})
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { cleanupOrganization(t, pool, res.Organization.ID) })
		return res
	}
	mkUser := func(orgID, username, fullName, roleCode string) *domain.User {
		t.Helper()
		u, err := userSvc.Create(ctx, orgID, username, "GeciciSifre123!", fullName, domain.RoleKullanici, "")
		if err != nil {
			t.Fatal(err)
		}
		if _, err := authzSvc.SetUserOrganizationRole(ctx, u.ID, orgID, "", roleCode); err != nil {
			t.Fatal(err)
		}
		return u
	}
	send := func(orgID, userID, text string) domain.ChatMessage {
		t.Helper()
		res, err := chat.Send(ctx, service.ChatSendInput{OrganizationID: orgID, UserID: userID, Text: text})
		if err != nil {
			t.Fatalf("mesaj gönderilemedi (%q): %v", text, err)
		}
		return res.Message
	}
	unread := func(orgID, userID string) int64 {
		t.Helper()
		st, err := chat.Status(ctx, orgID, userID)
		if err != nil {
			t.Fatal(err)
		}
		return st.UnreadCount
	}
	chatNotifs := func(userID string) []chatNotif {
		t.Helper()
		rows, err := pool.Query(ctx, `SELECT id::text, title, body, action_target, COALESCE(entity_id::text, ''), group_count,
		                                     read_at IS NOT NULL, pushed_at IS NOT NULL
		                              FROM notifications WHERE user_id = $1 AND type = 'organization_chat' ORDER BY created_at`, userID)
		if err != nil {
			t.Fatal(err)
		}
		defer rows.Close()
		var out []chatNotif
		for rows.Next() {
			var n chatNotif
			if err := rows.Scan(&n.ID, &n.Title, &n.Body, &n.Target, &n.EntityID, &n.GroupCount, &n.Read, &n.Pushed); err != nil {
				t.Fatal(err)
			}
			out = append(out, n)
		}
		return out
	}
	unreadChatNotifs := func(userID string) []chatNotif {
		t.Helper()
		var out []chatNotif
		for _, n := range chatNotifs(userID) {
			if !n.Read {
				out = append(out, n)
			}
		}
		return out
	}
	markAllRead := func(orgID, userID string) {
		t.Helper()
		if _, err := chat.MarkRead(ctx, orgID, userID, 1<<40); err != nil {
			t.Fatal(err)
		}
	}

	a := mkOrg("firma-grubu-a")
	b := mkOrg("firma-grubu-b")
	orgA, orgB := a.Organization.ID, b.Organization.ID
	owner := a.Owner
	admin := mkUser(orgA, "grup_yonetici", "Yusuf Yönetici", domain.OrgRoleAdmin)
	ahmet := mkUser(orgA, "grup_ahmet", "Ahmet Saha", domain.OrgRoleField)
	mehmet := mkUser(orgA, "grup_mehmet", "Mehmet Finans", domain.OrgRoleFinance)
	ownerB := b.Owner

	card, err := supplierSvc.CreateSubcontractorCard(ctx, orgA, service.SupplierInput{LegalName: "Grup Taşeron Elektrik"})
	if err != nil {
		t.Fatal(err)
	}
	portal, err := supplierSvc.CreatePortalUser(ctx, orgA, card.ID, service.PortalUserInput{
		FullName: "Taşeron Hasan", Username: "grup_taseron_hasan", TemporaryPassword: "GeciciSifre123!",
	})
	if err != nil {
		t.Fatal(err)
	}

	t.Run("1_permission_seeded_except_subcontractor", func(t *testing.T) {
		// Yeni firmanın (seed fonksiyonu) her rolünde var, Taşeron'da yok.
		rows, err := pool.Query(ctx, `SELECT r.code, EXISTS (SELECT 1 FROM role_permissions rp
		                                 WHERE rp.organization_role_id = r.id AND rp.permission_code = $2)
		                              FROM organization_roles r WHERE r.organization_id = $1`, orgA, domain.PermOrganizationChatUse)
		if err != nil {
			t.Fatal(err)
		}
		defer rows.Close()
		seen := 0
		for rows.Next() {
			var code string
			var has bool
			if err := rows.Scan(&code, &has); err != nil {
				t.Fatal(err)
			}
			seen++
			if want := code != domain.OrgRoleSubcontractor; has != want {
				t.Errorf("rol %s: organization.chat.use = %v, beklenen %v", code, has, want)
			}
		}
		if seen < 7 {
			t.Fatalf("sistem rolleri eksik: %d", seen)
		}
		for _, u := range []*domain.User{ahmet, mehmet, admin} {
			detail, err := authzSvc.GetUserPermissionDetail(ctx, u.ID, orgA)
			if err != nil {
				t.Fatal(err)
			}
			if !containsString(detail.Effective, domain.PermOrganizationChatUse) {
				t.Errorf("%s grubu kullanamıyor", u.Username)
			}
		}
		perms, err := q.GetUserPermissions(ctx, sqlc.GetUserPermissionsParams{ID: mustUUID(t, portal.ID), OrganizationID: mustUUID(t, orgA)})
		if err != nil {
			t.Fatal(err)
		}
		if containsString(perms, domain.PermOrganizationChatUse) {
			t.Error("taşeron hesabı Firma Grubu iznini almamalı")
		}
	})

	t.Run("2_send_list_and_text_rules", func(t *testing.T) {
		m1 := send(orgA, owner.ID, "  Günaydın, yarın beton dökümü var.  ")
		m2 := send(orgA, ahmet.ID, "Tamam\r\nşantiyedeyim\x00")
		if m1.Seq != 1 || m2.Seq != 2 {
			t.Fatalf("firma içi numaralar 1,2 olmalı: %d, %d", m1.Seq, m2.Seq)
		}
		if m1.Body != "Günaydın, yarın beton dökümü var." || m2.Body != "Tamam\nşantiyedeyim" {
			t.Errorf("metin temizlenmedi: %q / %q", m1.Body, m2.Body)
		}
		if m2.AuthorName != "Ahmet Saha" || m2.AuthorID == nil || *m2.AuthorID != ahmet.ID {
			t.Errorf("yazar: %+v", m2)
		}
		res, err := chat.List(ctx, orgA, mehmet.ID, service.ChatListQuery{})
		if err != nil {
			t.Fatal(err)
		}
		if len(res.Messages) != 2 || res.Messages[0].ID != m2.ID || res.Messages[1].ID != m1.ID || res.HasMore {
			t.Fatalf("en yeni sayfa yeniden eskiye olmalı: %+v", res.Messages)
		}
		if res.CanModerate {
			t.Error("Finans herkesin mesajını silememeli")
		}
		if res, _ := chat.List(ctx, orgA, admin.ID, service.ChatListQuery{}); !res.CanModerate {
			t.Error("Yönetici herkesin mesajını silebilmeli")
		}
		for _, text := range []string{"", "   \n\t  ", "\x00\x01"} {
			if _, err := chat.Send(ctx, service.ChatSendInput{OrganizationID: orgA, UserID: ahmet.ID, Text: text}); !errors.Is(err, service.ErrChatEmpty) {
				t.Errorf("boş mesaj (%q) reddedilmeli: %v", text, err)
			}
		}
		long := strings.Repeat("ş", domain.ChatMaxBodyRunes+1)
		if _, err := chat.Send(ctx, service.ChatSendInput{OrganizationID: orgA, UserID: ahmet.ID, Text: long}); !errors.Is(err, service.ErrChatTooLong) {
			t.Errorf("4000 karakteri aşan mesaj reddedilmeli: %v", err)
		}
		if _, err := chat.Send(ctx, service.ChatSendInput{OrganizationID: orgA, UserID: ahmet.ID, Text: strings.Repeat("ş", domain.ChatMaxBodyRunes)}); err != nil {
			t.Errorf("tam 4000 karakter kabul edilmeli: %v", err)
		}
		if _, err := chat.Send(ctx, service.ChatSendInput{OrganizationID: orgA, UserID: ahmet.ID, Text: "x", ClientID: "uuid-değil"}); !errors.Is(err, service.ErrChatInvalidClientID) {
			t.Errorf("geçersiz client_id 400 olmalı: %v", err)
		}
	})

	t.Run("3_tenant_isolation", func(t *testing.T) {
		resB, err := chat.List(ctx, orgB, ownerB.ID, service.ChatListQuery{})
		if err != nil {
			t.Fatal(err)
		}
		if len(resB.Messages) != 0 {
			t.Fatalf("B firması A'nın mesajlarını görmemeli: %d", len(resB.Messages))
		}
		resA, _ := chat.List(ctx, orgA, owner.ID, service.ChatListQuery{Limit: 1})
		aMsg := resA.Messages[0]
		if _, err := chat.Delete(ctx, orgB, ownerB.ID, aMsg.ID); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("başka firmanın mesajı silinememeli (404): %v", err)
		}
		// A'nın kullanıcısı B'nin bağlamında hiçbir şey yazamaz.
		if _, err := chat.Send(ctx, service.ChatSendInput{OrganizationID: orgB, UserID: ahmet.ID, Text: "sızma"}); !errors.Is(err, service.ErrChatNotMember) {
			t.Errorf("başka firmaya mesaj yazılamamalı: %v", err)
		}
		mB := send(orgB, ownerB.ID, "B firmasının ilk mesajı")
		if mB.Seq != 1 {
			t.Errorf("numara firmaya özel olmalı (B'de 1): %d", mB.Seq)
		}
		if _, _, err := chat.OpenPhoto(ctx, orgA, mB.ID); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("başka firmanın mesajı açılamamalı: %v", err)
		}
		// Mehmet A'da üç mesajı (sahip + Ahmet'in ikisi) okumadı; B'deki mesaj
		// ona sayılmaz.
		if n := unread(orgA, mehmet.ID); n != 3 {
			t.Fatalf("A'da 3 okunmamış olmalı: %d", n)
		}
		// Başka firmanın grubunda durum satırı açılamaz.
		if _, err := chat.MarkRead(ctx, orgB, mehmet.ID, 1); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("başka firmanın grubu okundu işaretlenemez: %v", err)
		}
		if _, err := chat.SetMuted(ctx, orgB, mehmet.ID, true); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("başka firmanın grubu sessize alınamaz: %v", err)
		}
		var rows int
		if err := pool.QueryRow(ctx, "SELECT count(*) FROM organization_chat_members WHERE organization_id = $1 AND user_id = $2", orgB, mehmet.ID).Scan(&rows); err != nil || rows != 0 {
			t.Errorf("B'de A'nın kişisine satır açılmamalı: %d %v", rows, err)
		}
		if n := unread(orgA, mehmet.ID); n != 3 {
			t.Errorf("A'daki okunmamış değişmemeli: %d", n)
		}
		if got := unread(orgB, ownerB.ID); got != 0 {
			t.Errorf("B sahibi kendi mesajını okunmamış saymamalı: %d", got)
		}
		for _, n := range chatNotifs(ownerB.ID) {
			if n.EntityID == aMsg.ID {
				t.Error("A'nın mesajı B'ye bildirim olarak düşmemeli")
			}
		}
	})

	t.Run("4_subcontractor_and_inactive_excluded", func(t *testing.T) {
		if _, err := chat.Send(ctx, service.ChatSendInput{OrganizationID: orgA, UserID: portal.ID, Text: "merhaba"}); !errors.Is(err, service.ErrChatNotMember) {
			t.Errorf("taşeron hesabı yazamamalı: %v", err)
		}
		if _, err := chat.Delete(ctx, orgA, portal.ID, uuid.NewString()); !errors.Is(err, service.ErrChatNotMember) {
			t.Errorf("taşeron hesabı silememeli: %v", err)
		}
		pasif := mkUser(orgA, "grup_pasif", "Pasif Kişi", domain.OrgRoleField)
		if err := userSvc.Deactivate(ctx, pasif.ID, orgA, owner.ID); err != nil {
			t.Fatal(err)
		}
		send(orgA, owner.ID, "Herkese duyuru")
		if n := chatNotifs(portal.ID); len(n) != 0 {
			t.Errorf("taşeron hesabına Firma Grubu bildirimi gitmemeli: %+v", n)
		}
		if n := chatNotifs(pasif.ID); len(n) != 0 {
			t.Errorf("pasif hesaba bildirim gitmemeli: %+v", n)
		}
		if _, err := chat.Send(ctx, service.ChatSendInput{OrganizationID: orgA, UserID: pasif.ID, Text: "x"}); !errors.Is(err, service.ErrChatNotMember) {
			t.Errorf("pasif hesap yazamamalı: %v", err)
		}
		if len(unreadChatNotifs(ahmet.ID)) != 1 {
			t.Errorf("üyeye bildirim gitmeli: %+v", chatNotifs(ahmet.ID))
		}
	})

	t.Run("5_permission_revoked", func(t *testing.T) {
		kisi := mkUser(orgA, "grup_izinsiz", "İzni Alınan", domain.OrgRoleField)
		detail, err := authzSvc.GetUserPermissionDetail(ctx, kisi.ID, orgA)
		if err != nil {
			t.Fatal(err)
		}
		var keep []string
		for _, p := range detail.Effective {
			if p != domain.PermOrganizationChatUse {
				keep = append(keep, p)
			}
		}
		if _, err := authzSvc.SetUserPermissions(ctx, kisi.ID, orgA, owner.ID, keep); err != nil {
			t.Fatal(err)
		}
		if _, err := chat.Send(ctx, service.ChatSendInput{OrganizationID: orgA, UserID: kisi.ID, Text: "x"}); !errors.Is(err, service.ErrChatNotMember) {
			t.Errorf("izni alınan kişi yazamamalı: %v", err)
		}
		send(orgA, owner.ID, "İzinsize gitmeyecek")
		if n := chatNotifs(kisi.ID); len(n) != 0 {
			t.Errorf("izni alınan kişiye bildirim gitmemeli: %+v", n)
		}
	})

	t.Run("6_notification_grouping_and_push", func(t *testing.T) {
		markAllRead(orgA, ahmet.ID)
		if n := unreadChatNotifs(ahmet.ID); len(n) != 0 {
			t.Fatalf("okuyunca zildeki bildirim de kapanmalı: %+v", n)
		}
		before := len(chatNotifs(ahmet.ID))
		send(orgA, owner.ID, "Birinci")
		send(orgA, admin.ID, "İkinci")
		last := send(orgA, owner.ID, "Üçüncü\nsatır  satır")
		all := chatNotifs(ahmet.ID)
		open := unreadChatNotifs(ahmet.ID)
		if len(all) != before+1 || len(open) != 1 {
			t.Fatalf("üç mesaj tek bildirimde toplanmalı: toplam %d (önce %d), açık %+v", len(all), before, open)
		}
		n := open[0]
		if n.Title != "Firma Grubu: 3 yeni mesaj" || n.Body != "Son: Ayşe Sahip: Üçüncü satır satır" ||
			n.GroupCount != 3 || n.EntityID != last.ID || n.Target != domain.ChatActionTarget || n.Pushed {
			t.Fatalf("gruplu bildirim: %+v", n)
		}
		for _, n := range unreadChatNotifs(owner.ID) {
			if n.EntityID == last.ID {
				t.Error("yazar kendi mesajı için bildirim almamalı")
			}
		}

		// Telefon: sabit etiket ve collapse key -- tek kart.
		sender := &fakeSender{}
		pushSvc := service.NewPushService(q, sender)
		if err := pushSvc.RegisterDevice(ctx, orgA, ahmet.ID, "grup-ahmet-telefon-anahtari-0001", "android", "1.5.22"); err != nil {
			t.Fatal(err)
		}
		if _, err := pushSvc.DispatchOnce(ctx); err != nil {
			t.Fatal(err)
		}
		var mine []string
		for _, m := range sender.take() {
			if m.Token != "grup-ahmet-telefon-anahtari-0001" {
				continue
			}
			mine = append(mine, m.Title)
			if m.Tag != domain.ChatPushTag || m.CollapseKey != domain.ChatPushTag || m.Data["action_target"] != domain.ChatActionTarget ||
				m.Data["type"] != domain.NotificationOrganizationChat {
				t.Errorf("Firma Grubu push'u tek kartta toplanmalı: %+v", m)
			}
		}
		// Önceki (okunmuş, henüz gönderilmemiş) Firma Grubu bildirimi telefonu
		// çaldırmaz -- yalnızca açık olan tek kart gider.
		if len(mine) != 1 || mine[0] != "Firma Grubu: 3 yeni mesaj" {
			t.Errorf("telefona tek bildirim gitmeli: %v", mine)
		}

		// Bildirimin gösterdiği son mesajdan ÖNCESİNE kadar okumak onu kapatmaz.
		if _, err := chat.MarkRead(ctx, orgA, ahmet.ID, last.Seq-1); err != nil {
			t.Fatal(err)
		}
		if len(unreadChatNotifs(ahmet.ID)) != 1 {
			t.Error("son mesaj okunmadan bildirim kapanmamalı")
		}
		if _, err := chat.MarkRead(ctx, orgA, ahmet.ID, last.Seq); err != nil {
			t.Fatal(err)
		}
		if len(unreadChatNotifs(ahmet.ID)) != 0 {
			t.Error("son mesaja kadar okuyunca bildirim kapanmalı")
		}
		// Okunduktan sonraki mesaj yeni bir tekil bildirim açar.
		fresh := send(orgA, mehmet.ID, "Yeni konu")
		open = unreadChatNotifs(ahmet.ID)
		if len(open) != 1 || open[0].Title != "Firma Grubu" || open[0].Body != "Mehmet Finans: Yeni konu" || open[0].GroupCount != 1 || open[0].EntityID != fresh.ID {
			t.Fatalf("okunduktan sonra yeni bildirim: %+v", open)
		}
	})

	t.Run("7_mute", func(t *testing.T) {
		markAllRead(orgA, mehmet.ID)
		st, err := chat.SetMuted(ctx, orgA, mehmet.ID, true)
		if err != nil || !st.Muted {
			t.Fatalf("sessize alınamadı: %v %+v", err, st)
		}
		send(orgA, owner.ID, "Sessizdekine bildirim yok")
		if n := unreadChatNotifs(mehmet.ID); len(n) != 0 {
			t.Errorf("sessizdeki kişiye bildirim gitmemeli: %+v", n)
		}
		if got := unread(orgA, mehmet.ID); got != 1 {
			t.Errorf("sessizde de okunmamış sayısı görünmeli: %d", got)
		}
		if res, _ := chat.List(ctx, orgA, mehmet.ID, service.ChatListQuery{Limit: 1}); !res.Muted {
			t.Error("liste sessiz durumunu döndürmeli")
		}
		if st, err := chat.SetMuted(ctx, orgA, mehmet.ID, false); err != nil || st.Muted {
			t.Fatalf("sessizden çıkarılamadı: %v", err)
		}
		send(orgA, owner.ID, "Artık bildirim var")
		if n := unreadChatNotifs(mehmet.ID); len(n) != 1 {
			t.Errorf("sessizden çıkınca bildirim gelmeli: %+v", n)
		}
	})

	t.Run("8_unread_counts", func(t *testing.T) {
		markAllRead(orgA, ahmet.ID)
		if got := unread(orgA, ahmet.ID); got != 0 {
			t.Fatalf("hepsi okununca 0: %d", got)
		}
		send(orgA, ahmet.ID, "kendi mesajım sayılmaz")
		if got := unread(orgA, ahmet.ID); got != 0 {
			t.Errorf("kendi mesajı okunmamış sayılmamalı: %d", got)
		}
		m1 := send(orgA, owner.ID, "bir")
		send(orgA, owner.ID, "iki")
		if got := unread(orgA, ahmet.ID); got != 2 {
			t.Errorf("iki okunmamış: %d", got)
		}
		st, err := chat.MarkRead(ctx, orgA, ahmet.ID, m1.Seq)
		if err != nil || st.UnreadCount != 1 || st.LastReadSeq != m1.Seq {
			t.Fatalf("birine kadar okundu: %v %+v", err, st)
		}
		// Geri gitmez.
		if st, _ := chat.MarkRead(ctx, orgA, ahmet.ID, 1); st.LastReadSeq != m1.Seq {
			t.Errorf("okuma geri gitmemeli: %d", st.LastReadSeq)
		}
		// En büyük numarayla sınırlanır: sonradan gelen mesaj yine okunmamış.
		markAllRead(orgA, ahmet.ID)
		send(orgA, owner.ID, "sonradan")
		if got := unread(orgA, ahmet.ID); got != 1 {
			t.Errorf("ileri tarihli okuma sonraki mesajı yutmamalı: %d", got)
		}
		// Silinen mesaj okunmamış sayılmaz.
		res, _ := chat.List(ctx, orgA, owner.ID, service.ChatListQuery{Limit: 1})
		if _, err := chat.Delete(ctx, orgA, owner.ID, res.Messages[0].ID); err != nil {
			t.Fatal(err)
		}
		if got := unread(orgA, ahmet.ID); got != 0 {
			t.Errorf("silinen mesaj sayılmamalı: %d", got)
		}
		// Yeni gelen çalışan eski geçmişi okunmamış saymaz.
		if _, err := pool.Exec(ctx, "UPDATE organization_chat_messages SET created_at = created_at - interval '1 hour' WHERE organization_id = $1", orgA); err != nil {
			t.Fatal(err)
		}
		yeni := mkUser(orgA, "grup_yeni_gelen", "Yeni Gelen", domain.OrgRoleField)
		if got := unread(orgA, yeni.ID); got != 0 {
			t.Errorf("yeni çalışana eski geçmiş okunmamış düşmemeli: %d", got)
		}
		send(orgA, owner.ID, "hoş geldin")
		if got := unread(orgA, yeni.ID); got != 1 {
			t.Errorf("katıldıktan sonraki mesaj sayılmalı: %d", got)
		}
		if res, _ := chat.List(ctx, orgA, yeni.ID, service.ChatListQuery{}); len(res.Messages) < 10 {
			t.Errorf("yeni çalışan geçmişi okuyabilmeli: %d", len(res.Messages))
		}
	})

	t.Run("9_delete_rules", func(t *testing.T) {
		mine := send(orgA, ahmet.ID, "yanlış yazdım")
		boss := send(orgA, owner.ID, "patronun mesajı")
		if _, err := chat.Delete(ctx, orgA, ahmet.ID, boss.ID); !errors.Is(err, service.ErrChatDeleteNotAllowed) {
			t.Errorf("saha başkasının mesajını silememeli: %v", err)
		}
		if _, err := chat.Delete(ctx, orgA, mehmet.ID, mine.ID); !errors.Is(err, service.ErrChatDeleteNotAllowed) {
			t.Errorf("finans başkasının mesajını silememeli: %v", err)
		}
		d, err := chat.Delete(ctx, orgA, ahmet.ID, mine.ID)
		if err != nil || !d.Deleted || d.Body != "" {
			t.Fatalf("kendi mesajını silebilmeli: %v %+v", err, d)
		}
		// İkinci kez silmek hata değil.
		if d, err := chat.Delete(ctx, orgA, ahmet.ID, mine.ID); err != nil || !d.Deleted {
			t.Errorf("tekrar silme: %v", err)
		}
		// Yönetici herkesinkini siler; listede "Mesaj silindi" (içerik boş).
		target := send(orgA, mehmet.ID, "yönetici silecek")
		if _, err := chat.Delete(ctx, orgA, admin.ID, target.ID); err != nil {
			t.Fatalf("yönetici silebilmeli: %v", err)
		}
		res, _ := chat.List(ctx, orgA, ahmet.ID, service.ChatListQuery{Limit: 5})
		found := 0
		for _, m := range res.Messages {
			if m.ID == target.ID || m.ID == mine.ID {
				found++
				if !m.Deleted || m.Body != "" || m.Photo != nil || m.AuthorName == "" {
					t.Errorf("silinen mesaj içeriksiz ama yazarlı dönmeli: %+v", m)
				}
			}
		}
		if found != 2 {
			t.Errorf("silinen mesajlar listede yer tutmalı: %d", found)
		}
		// Zildeki bildirimin gövdesi de silinir.
		for _, n := range chatNotifs(ahmet.ID) {
			if n.EntityID == target.ID && n.Body != "Mehmet Finans: Mesaj silindi" && n.Body != "Son: Mehmet Finans: Mesaj silindi" {
				t.Errorf("bildirim gövdesi silinmeli: %+v", n)
			}
		}
		if _, err := chat.Delete(ctx, orgA, owner.ID, uuid.NewString()); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("olmayan mesaj 404: %v", err)
		}
	})

	t.Run("10_photo", func(t *testing.T) {
		res, err := chat.SendPhoto(ctx, service.ChatSendInput{
			OrganizationID: orgA, UserID: ahmet.ID, Photo: bytes.NewReader(tinyPNG), Text: "Kolon donatısı",
		})
		if err != nil {
			t.Fatal(err)
		}
		m := res.Message
		if m.Photo == nil || m.Photo.MIMEType != "image/png" || m.Photo.SizeBytes != int64(len(tinyPNG)) || m.Body != "Kolon donatısı" {
			t.Fatalf("fotoğraf mesajı: %+v", m)
		}
		photo, rc, err := chat.OpenPhoto(ctx, orgA, m.ID)
		if err != nil {
			t.Fatal(err)
		}
		got, _ := io.ReadAll(rc)
		rc.Close()
		if !bytes.Equal(got, tinyPNG) || photo.MIMEType != "image/png" {
			t.Error("fotoğraf içeriği aynen dönmeli")
		}
		open := unreadChatNotifs(owner.ID)
		if len(open) != 1 || !strings.HasSuffix(open[0].Body, "Ahmet Saha: Fotoğraf · Kolon donatısı") {
			t.Errorf("fotoğraf bildirimi: %+v", open)
		}
		if _, err := chat.SendPhoto(ctx, service.ChatSendInput{OrganizationID: orgA, UserID: ahmet.ID, Photo: strings.NewReader("<html>değil</html>")}); !errors.Is(err, service.ErrChatPhotoType) {
			t.Errorf("fotoğraf olmayan içerik reddedilmeli: %v", err)
		}
		if _, err := chat.SendPhoto(ctx, service.ChatSendInput{OrganizationID: orgA, UserID: ahmet.ID, Photo: bytes.NewReader(nil)}); !errors.Is(err, service.ErrEmptyFile) {
			t.Errorf("boş dosya reddedilmeli: %v", err)
		}
		if _, err := chat.SendPhoto(ctx, service.ChatSendInput{OrganizationID: orgA, UserID: portal.ID, Photo: bytes.NewReader(tinyPNG)}); !errors.Is(err, service.ErrChatNotMember) {
			t.Errorf("taşeron fotoğraf gönderememeli: %v", err)
		}
		if _, err := chat.Delete(ctx, orgA, ahmet.ID, m.ID); err != nil {
			t.Fatal(err)
		}
		if _, _, err := chat.OpenPhoto(ctx, orgA, m.ID); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("silinen mesajın fotoğrafı açılmamalı: %v", err)
		}
		text := send(orgA, ahmet.ID, "fotoğrafsız")
		if _, _, err := chat.OpenPhoto(ctx, orgA, text.ID); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("fotoğrafsız mesajda 404: %v", err)
		}
	})

	t.Run("11_idempotent_retry", func(t *testing.T) {
		cid := uuid.NewString()
		first, err := chat.Send(ctx, service.ChatSendInput{OrganizationID: orgA, UserID: ahmet.ID, Text: "bir kez", ClientID: cid})
		if err != nil || !first.Created {
			t.Fatalf("ilk gönderim: %v", err)
		}
		again, err := chat.Send(ctx, service.ChatSendInput{OrganizationID: orgA, UserID: ahmet.ID, Text: "bir kez", ClientID: cid})
		if err != nil || again.Created || again.Message.ID != first.Message.ID {
			t.Fatalf("aynı client_id aynı mesajı dönmeli: %v %+v", err, again)
		}
		photoAgain, err := chat.SendPhoto(ctx, service.ChatSendInput{OrganizationID: orgA, UserID: ahmet.ID, ClientID: cid, Photo: bytes.NewReader(tinyPNG)})
		if err != nil || photoAgain.Message.ID != first.Message.ID {
			t.Fatalf("fotoğrafta da tekrar deneme yeni mesaj açmamalı: %v", err)
		}
		var n int
		if err := pool.QueryRow(ctx, "SELECT count(*) FROM organization_chat_messages WHERE client_id = $1", cid).Scan(&n); err != nil || n != 1 {
			t.Fatalf("tek satır olmalı: %d %v", n, err)
		}
		// Aynı kimliği başka biri kullanırsa onun kendi mesajıdır.
		other, err := chat.Send(ctx, service.ChatSendInput{OrganizationID: orgA, UserID: mehmet.ID, Text: "başkası", ClientID: cid})
		if err != nil || !other.Created || other.Message.ID == first.Message.ID {
			t.Fatalf("client_id kişiye özel olmalı: %v", err)
		}
	})

	t.Run("12_paging_and_after_cursor", func(t *testing.T) {
		c := mkOrg("firma-grubu-c")
		orgC, ownerC := c.Organization.ID, c.Owner
		saha := mkUser(orgC, "grup_c_saha", "Saha C", domain.OrgRoleField)
		var msgs []domain.ChatMessage
		for i := 1; i <= 7; i++ {
			msgs = append(msgs, send(orgC, ownerC.ID, "mesaj "+string(rune('0'+i))))
		}
		seqs := func(ms []domain.ChatMessage) []int64 {
			out := make([]int64, len(ms))
			for i, m := range ms {
				out[i] = m.Seq
			}
			return out
		}
		eq := func(got []int64, want ...int64) bool {
			if len(got) != len(want) {
				return false
			}
			for i := range got {
				if got[i] != want[i] {
					return false
				}
			}
			return true
		}
		p1, _ := chat.List(ctx, orgC, saha.ID, service.ChatListQuery{Limit: 3})
		if !eq(seqs(p1.Messages), 7, 6, 5) || !p1.HasMore {
			t.Fatalf("en yeni sayfa: %v %v", seqs(p1.Messages), p1.HasMore)
		}
		p2, _ := chat.List(ctx, orgC, saha.ID, service.ChatListQuery{Limit: 3, Before: 5})
		if !eq(seqs(p2.Messages), 4, 3, 2) || !p2.HasMore {
			t.Fatalf("eski sayfa: %v %v", seqs(p2.Messages), p2.HasMore)
		}
		p3, _ := chat.List(ctx, orgC, saha.ID, service.ChatListQuery{Limit: 3, Before: 2})
		if !eq(seqs(p3.Messages), 1) || p3.HasMore {
			t.Fatalf("son sayfa: %v %v", seqs(p3.Messages), p3.HasMore)
		}
		after := int64(4)
		a1, _ := chat.List(ctx, orgC, saha.ID, service.ChatListQuery{Limit: 2, After: &after})
		if !eq(seqs(a1.Messages), 6, 5) || !a1.HasMore {
			t.Fatalf("yoklama (after=4): %v %v", seqs(a1.Messages), a1.HasMore)
		}
		after = 6
		a2, _ := chat.List(ctx, orgC, saha.ID, service.ChatListQuery{Limit: 2, After: &after})
		if !eq(seqs(a2.Messages), 7) || a2.HasMore {
			t.Fatalf("yoklama (after=6): %v %v", seqs(a2.Messages), a2.HasMore)
		}
		after = 7
		polledAt := a2.ServerTime
		empty, _ := chat.List(ctx, orgC, saha.ID, service.ChatListQuery{After: &after, ChangedSince: &polledAt})
		if len(empty.Messages) != 0 || empty.HasMore || len(empty.Updated) != 0 {
			t.Fatalf("yeni mesaj yokken boş: %+v", empty)
		}
		// Yoklamalar arasında silinen mesaj "updated" ile döner.
		if _, err := chat.Delete(ctx, orgC, ownerC.ID, msgs[2].ID); err != nil {
			t.Fatal(err)
		}
		polledAt = empty.ServerTime
		changed, _ := chat.List(ctx, orgC, saha.ID, service.ChatListQuery{After: &after, ChangedSince: &polledAt})
		if len(changed.Updated) != 1 || changed.Updated[0].ID != msgs[2].ID || !changed.Updated[0].Deleted || changed.Updated[0].Body != "" {
			t.Fatalf("silinen mesaj yoklamada gelmeli: %+v", changed.Updated)
		}
		// İstemcinin elinde olmayan aralık (after'dan büyük) "updated"a girmez.
		low := int64(2)
		long := time.Now().Add(-time.Hour)
		lowRes, _ := chat.List(ctx, orgC, saha.ID, service.ChatListQuery{After: &low, ChangedSince: &long, Limit: 100})
		if len(lowRes.Updated) != 0 {
			t.Errorf("after'dan sonraki silinmiş mesaj zaten messages içinde: %+v", lowRes.Updated)
		}
		bad := int64(-1)
		if _, err := chat.List(ctx, orgC, saha.ID, service.ChatListQuery{After: &bad}); !errors.Is(err, service.ErrChatInvalidCursor) {
			t.Errorf("eksi imleç reddedilmeli: %v", err)
		}
		if _, err := chat.List(ctx, orgC, saha.ID, service.ChatListQuery{After: &after, Before: 3}); !errors.Is(err, service.ErrChatInvalidCursor) {
			t.Errorf("before+after birlikte reddedilmeli: %v", err)
		}
	})

	t.Run("13_rate_limit", func(t *testing.T) {
		d := mkOrg("firma-grubu-d")
		limited := service.NewOrganizationChatService(pool, q, store)
		service.SetChatRateLimitForTest(limited, 3)
		for i := 0; i < 3; i++ {
			if _, err := limited.Send(ctx, service.ChatSendInput{OrganizationID: d.Organization.ID, UserID: d.Owner.ID, Text: "hızlı"}); err != nil {
				t.Fatalf("%d. mesaj sınır içinde: %v", i+1, err)
			}
		}
		if _, err := limited.Send(ctx, service.ChatSendInput{OrganizationID: d.Organization.ID, UserID: d.Owner.ID, Text: "fazla"}); !errors.Is(err, service.ErrChatRateLimited) {
			t.Fatalf("sınırı aşan mesaj reddedilmeli: %v", err)
		}
		if _, err := limited.SendPhoto(ctx, service.ChatSendInput{OrganizationID: d.Organization.ID, UserID: d.Owner.ID, Photo: bytes.NewReader(tinyPNG)}); !errors.Is(err, service.ErrChatRateLimited) {
			t.Fatalf("fotoğraf da sınıra tabi: %v", err)
		}
		// Reddedilen gönderim numara harcamaz.
		var last int64
		if err := pool.QueryRow(ctx, "SELECT last_seq FROM organization_chats WHERE organization_id = $1", d.Organization.ID).Scan(&last); err != nil || last != 3 {
			t.Errorf("sayaç geri alınmalı: %d %v", last, err)
		}
		// Sınır kişiye özeldir: aynı firmada başkası yazabilir.
		other := mkUser(d.Organization.ID, "grup_d_saha", "Saha D", domain.OrgRoleField)
		if _, err := limited.Send(ctx, service.ChatSendInput{OrganizationID: d.Organization.ID, UserID: other.ID, Text: "ben yazabilirim"}); err != nil {
			t.Errorf("sınır kişiye özel olmalı: %v", err)
		}
		// Pencere geçince yeniden yazılır.
		if _, err := pool.Exec(ctx, "UPDATE organization_chat_messages SET created_at = created_at - interval '2 minutes' WHERE organization_id = $1", d.Organization.ID); err != nil {
			t.Fatal(err)
		}
		if _, err := limited.Send(ctx, service.ChatSendInput{OrganizationID: d.Organization.ID, UserID: d.Owner.ID, Text: "bir dakika sonra"}); err != nil {
			t.Errorf("pencere geçince yazılabilmeli: %v", err)
		}
	})
}

func containsString(list []string, s string) bool {
	for _, v := range list {
		if v == s {
			return true
		}
	}
	return false
}
