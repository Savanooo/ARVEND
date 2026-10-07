package service_test

// Müşterinin paylaşım linkindeki hareketleri firmaya bildirim olarak düşer
// (ürün sahibi 2026-10: "müşteri onaylayınca bize bildirim gelsin"):
// teklif kabul/red, teklifin ilk açılışı, ek iş onay/red -- ve personelin
// aynı kararı kendisinin kaydetmesi. Alıcı kuralları için bkz.
// customer_link_notify.go. Gerçek PostgreSQL gerektirir.

import (
	"context"
	"fmt"
	"strings"
	"sync"
	"testing"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

func TestCustomerLinkNotifications(t *testing.T) {
	dbURL := testDBURL(t)
	box := testSecretBox(t)
	ctx := context.Background()

	pool, err := repository.NewPool(ctx, dbURL)
	if err != nil {
		t.Fatalf("veritabanına bağlanılamadı: %v", err)
	}
	t.Cleanup(func() { pool.Close() })

	q := sqlc.New(pool)
	userSvc := service.NewUserService(pool, q)
	authzSvc := service.NewAuthorizationService(pool, q)
	settingsSvc := service.NewSettingsService(q, box)
	offerSvc := service.NewOfferService(pool, q, settingsSvc, "http://localhost:3000")
	projectSvc := service.NewProjectService(pool, q, mustTestStore(t), settingsSvc, "http://localhost:3000")
	notifSvc := service.NewNotificationService(q)
	platformSvc := service.NewPlatformService(pool, q, userSvc, service.NewCalcService(q), service.NewProductService(q))

	const slug = "musteri-link-bildirim-test"
	var existing string
	if pool.QueryRow(ctx, "SELECT id FROM organizations WHERE slug = $1", slug).Scan(&existing) == nil {
		cleanupOrganization(t, pool, existing)
	}
	created, err := platformSvc.CreateOrganizationWithOwner(ctx, service.CreateOrganizationInput{
		Name: "Müşteri Link Bildirim", Slug: slug,
		OwnerUsername: "owner_" + slug, OwnerPassword: "GeciciSifre123!", OwnerFullName: "Firma Sahibi",
	})
	if err != nil {
		t.Fatalf("firma+sahip oluşturulamadı: %v", err)
	}
	t.Cleanup(func() { cleanupOrganization(t, pool, created.Organization.ID) })
	orgID := created.Organization.ID
	owner := &created.Owner

	roleUser := func(t *testing.T, username, roleCode string, extraPerms ...string) *domain.User {
		t.Helper()
		u, err := userSvc.Create(ctx, orgID, username, "GeciciSifre123!", username, domain.RoleKullanici, "")
		if err != nil {
			t.Fatalf("%s oluşturulamadı: %v", username, err)
		}
		if _, err := authzSvc.SetUserOrganizationRole(ctx, u.ID, orgID, "", roleCode); err != nil {
			t.Fatalf("%s rolü atanamadı: %v", username, err)
		}
		if len(extraPerms) > 0 {
			detail, err := authzSvc.GetUserPermissionDetail(ctx, u.ID, orgID)
			if err != nil {
				t.Fatalf("%s izinleri okunamadı: %v", username, err)
			}
			if _, err := authzSvc.SetUserPermissions(ctx, u.ID, orgID, owner.ID, append(detail.Effective, extraPerms...)); err != nil {
				t.Fatalf("%s için kişiye özel izin verilemedi: %v", username, err)
			}
		}
		return u
	}
	admin := roleUser(t, "mlb_admin", domain.OrgRoleAdmin)
	// Özel "satış" kişisi: Sahip/Yönetici değil, teklif düzenleme yetkisi
	// kişiye özel verilmiş.
	sales := roleUser(t, "mlb_sales", domain.OrgRoleProjectManager, domain.PermOffersRead, domain.PermOffersUpdate)
	legacyCreator := roleUser(t, "mlb_legacy_creator", domain.OrgRoleLegacyUser)
	legacyOther := roleUser(t, "mlb_legacy_other", domain.OrgRoleLegacyUser)
	field := roleUser(t, "mlb_field", domain.OrgRoleField)
	finance := roleUser(t, "mlb_finance", domain.OrgRoleFinance)

	// notices: kullanıcının bu kayda ait, bu türdeki bildirimleri.
	notices := func(t *testing.T, userID, notifType, entityID string) []domain.Notification {
		t.Helper()
		res, err := notifSvc.List(ctx, userID, orgID, 1, 100)
		if err != nil {
			t.Fatalf("bildirimler alınamadı: %v", err)
		}
		var out []domain.Notification
		for _, n := range res.Notifications {
			if n.Type == notifType && n.EntityID != nil && *n.EntityID == entityID {
				out = append(out, n)
			}
		}
		return out
	}
	// expectCount: her kullanıcı için beklenen bildirim sayısı.
	expectCount := func(t *testing.T, notifType, entityID string, want map[*domain.User]int) {
		t.Helper()
		for u, n := range want {
			if got := len(notices(t, u.ID, notifType, entityID)); got != n {
				t.Errorf("%s: %s bildirimi %d kez, beklenen %d", u.Username, notifType, got, n)
			}
		}
	}
	// only: kullanıcının bu kayda ait TEK bildirimi.
	only := func(t *testing.T, u *domain.User, notifType, entityID string) domain.Notification {
		t.Helper()
		list := notices(t, u.ID, notifType, entityID)
		if len(list) != 1 {
			t.Fatalf("%s: %s bildirimi %d kez, beklenen 1", u.Username, notifType, len(list))
		}
		return list[0]
	}

	newOffer := func(t *testing.T, creatorID string) *domain.Offer {
		t.Helper()
		o, err := offerSvc.Create(ctx, service.CreateOfferInput{
			OrganizationID: orgID, UserID: creatorID, CustomerName: "Ahmet Yılmaz", VatRate: ptrFloat(0),
			Items: []service.OfferItemInput{{ProductName: "Çatı yenileme", Quantity: 1, UnitPrice: 1250000}},
		})
		if err != nil {
			t.Fatalf("teklif oluşturulamadı: %v", err)
		}
		return o
	}
	send := func(t *testing.T, o *domain.Offer, actorID string) string {
		t.Helper()
		if _, err := offerSvc.UpdateStatus(ctx, o.ID, orgID, domain.OfferStatusGonderildi, actorID); err != nil {
			t.Fatalf("gönderilemedi: %v", err)
		}
		link, err := offerSvc.CreateShareLink(ctx, o.ID, orgID, actorID, nil)
		if err != nil {
			t.Fatalf("link oluşturulamadı: %v", err)
		}
		return link.Token
	}
	view := func(t *testing.T, token string) {
		t.Helper()
		if _, err := offerSvc.GetPublicView(ctx, token, "", "node"); err != nil {
			t.Fatalf("link açılamadı: %v", err)
		}
	}
	offerBody := func(o *domain.Offer) string { return o.OfferNo + " · Ahmet Yılmaz · 1.250.000 TL" }

	// ---------- Teklif kararı ----------

	t.Run("offer_accepted_by_customer_reaches_creator_managers_and_sales_once", func(t *testing.T) {
		o := newOffer(t, legacyCreator.ID)
		token := send(t, o, legacyCreator.ID)
		if _, err := offerSvc.RespondByShareLinkToken(ctx, token, domain.OfferStatusKabulEdildi, "1.2.3.4", "test"); err != nil {
			t.Fatalf("kabul edilemedi: %v", err)
		}
		// Eski Sistem kullanıcısı teklifi kendisi hazırladıysa alır; diğer
		// Eski Sistem kullanıcıları almaz (taşınan firmada herkes bu rolde).
		expectCount(t, domain.NotificationOfferAccepted, o.ID, map[*domain.User]int{
			legacyCreator: 1, owner: 1, admin: 1, sales: 1,
			legacyOther: 0, field: 0, finance: 0,
		})
		n := only(t, legacyCreator, domain.NotificationOfferAccepted, o.ID)
		if n.Title != "Müşteri teklifi kabul etti" || n.Body != offerBody(o) {
			t.Errorf("metin: %q / %q", n.Title, n.Body)
		}
		if n.ActionTarget != "/teklifler/"+o.ID || n.EntityType != domain.NotificationEntityOffer || n.ProjectID != nil {
			t.Errorf("hedef: %q %q %v", n.ActionTarget, n.EntityType, n.ProjectID)
		}
	})

	t.Run("offer_rejected_by_customer_creator_who_is_also_manager_gets_one", func(t *testing.T) {
		o := newOffer(t, admin.ID)
		token := send(t, o, admin.ID)
		if _, err := offerSvc.RespondByShareLinkToken(ctx, token, domain.OfferStatusReddedildi, "", ""); err != nil {
			t.Fatalf("reddedilemedi: %v", err)
		}
		expectCount(t, domain.NotificationOfferRejected, o.ID, map[*domain.User]int{
			admin: 1, owner: 1, sales: 1, legacyOther: 0, field: 0,
		})
		if n := only(t, admin, domain.NotificationOfferRejected, o.ID); n.Title != "Müşteri teklifi reddetti" || n.Body != offerBody(o) {
			t.Errorf("metin: %q / %q", n.Title, n.Body)
		}
	})

	t.Run("offer_without_creator_still_reaches_managers", func(t *testing.T) {
		// BYZ'den gelen tekliflerde oluşturan yok -- eskiden kimse duymuyordu.
		o := newOffer(t, "")
		token := send(t, o, "")
		if _, err := offerSvc.RespondByShareLinkToken(ctx, token, domain.OfferStatusKabulEdildi, "", ""); err != nil {
			t.Fatalf("kabul edilemedi: %v", err)
		}
		expectCount(t, domain.NotificationOfferAccepted, o.ID, map[*domain.User]int{
			owner: 1, admin: 1, sales: 1, legacyCreator: 0, legacyOther: 0,
		})
	})

	t.Run("staff_status_change_skips_the_actor_and_names_the_recorder", func(t *testing.T) {
		o := newOffer(t, sales.ID)
		send(t, o, sales.ID)
		if _, err := offerSvc.UpdateStatus(ctx, o.ID, orgID, domain.OfferStatusKabulEdildi, admin.ID); err != nil {
			t.Fatalf("kabul edilemedi: %v", err)
		}
		expectCount(t, domain.NotificationOfferAccepted, o.ID, map[*domain.User]int{
			admin: 0, sales: 1, owner: 1,
		})
		n := only(t, sales, domain.NotificationOfferAccepted, o.ID)
		if n.Title != "Teklif kabul edildi" || n.Body != offerBody(o)+" · Kaydeden: mlb_admin" {
			t.Errorf("metin: %q / %q", n.Title, n.Body)
		}

		// Kendi teklifini işaretleyen kendine bildirim almaz.
		o2 := newOffer(t, sales.ID)
		send(t, o2, sales.ID)
		if _, err := offerSvc.UpdateStatus(ctx, o2.ID, orgID, domain.OfferStatusReddedildi, sales.ID); err != nil {
			t.Fatalf("reddedilemedi: %v", err)
		}
		expectCount(t, domain.NotificationOfferRejected, o2.ID, map[*domain.User]int{sales: 0, owner: 1, admin: 1})
		// Aynı durumu yeniden kaydetmek ikinci bildirim üretmez.
		if _, err := offerSvc.UpdateStatus(ctx, o2.ID, orgID, domain.OfferStatusReddedildi, owner.ID); err != nil {
			t.Fatalf("yeniden reddedilemedi: %v", err)
		}
		expectCount(t, domain.NotificationOfferRejected, o2.ID, map[*domain.User]int{owner: 1, admin: 1})
	})

	// ---------- Teklifin ilk açılışı ----------

	t.Run("first_open_notifies_the_creator_once_per_revision", func(t *testing.T) {
		o := newOffer(t, sales.ID)
		token := send(t, o, sales.ID)

		view(t, token)
		n := only(t, sales, domain.NotificationOfferViewed, o.ID)
		if n.Title != "Müşteri teklifi açtı" || n.Body != offerBody(o) || n.ActionTarget != "/teklifler/"+o.ID {
			t.Errorf("metin/hedef: %q / %q / %q", n.Title, n.Body, n.ActionTarget)
		}
		// Yalnızca hazırlayana -- yöneticilere değil.
		expectCount(t, domain.NotificationOfferViewed, o.ID, map[*domain.User]int{owner: 0, admin: 0})

		// Yenileme ve aynı revizyonun ikinci linki yeni bildirim üretmez.
		view(t, token)
		view(t, token)
		second, err := offerSvc.CreateShareLink(ctx, o.ID, orgID, sales.ID, nil)
		if err != nil {
			t.Fatalf("ikinci link oluşturulamadı: %v", err)
		}
		view(t, second.Token)
		expectCount(t, domain.NotificationOfferViewed, o.ID, map[*domain.User]int{sales: 1})

		events, err := offerSvc.ListEvents(ctx, o.ID, orgID)
		if err != nil {
			t.Fatalf("olaylar alınamadı: %v", err)
		}
		views, firsts := 0, 0
		for _, e := range events {
			if e.EventType == domain.EventCustomerViewed {
				views++
				if e.Metadata["first_open"] == true {
					firsts++
				}
			}
		}
		if views != 4 || firsts != 1 {
			t.Errorf("görüntülenme=%d (4 bekleniyor), ilk açılış işareti=%d (1 bekleniyor)", views, firsts)
		}

		// Yeni revizyon gönderilince onun ilk açılışı yeniden bildirilir.
		if _, err := offerSvc.Revise(ctx, o.ID, orgID, sales.ID); err != nil {
			t.Fatalf("revize edilemedi: %v", err)
		}
		view(t, send(t, o, sales.ID))
		list := notices(t, sales.ID, domain.NotificationOfferViewed, o.ID)
		if len(list) != 2 {
			t.Fatalf("revizyondan sonra %d açılış bildirimi, beklenen 2", len(list))
		}
		if !strings.Contains(list[0].Body, o.OfferNo+" (Revizyon 1)") {
			t.Errorf("yeni revizyonun bildirimi revizyonu söylemeli: %q", list[0].Body)
		}

		// Karar verildikten sonra açılış haber değildir.
		latest, err := offerSvc.ListShareLinks(ctx, o.ID, orgID)
		if err != nil || len(latest) == 0 {
			t.Fatalf("linkler alınamadı: %v", err)
		}
		if _, err := offerSvc.RespondByShareLinkToken(ctx, latest[0].Token, domain.OfferStatusKabulEdildi, "", ""); err != nil {
			t.Fatalf("kabul edilemedi: %v", err)
		}
		view(t, latest[0].Token)
		expectCount(t, domain.NotificationOfferViewed, o.ID, map[*domain.User]int{sales: 2})
	})

	t.Run("concurrent_first_opens_notify_once", func(t *testing.T) {
		o := newOffer(t, sales.ID)
		token := send(t, o, sales.ID)
		var wg sync.WaitGroup
		errs := make(chan error, 30)
		for i := 0; i < 30; i++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				if _, err := offerSvc.GetPublicView(ctx, token, "", "node"); err != nil {
					errs <- err
				}
			}()
		}
		wg.Wait()
		close(errs)
		for err := range errs {
			t.Fatalf("eşzamanlı açılış hata verdi: %v", err)
		}
		expectCount(t, domain.NotificationOfferViewed, o.ID, map[*domain.User]int{sales: 1})
	})

	t.Run("draft_preview_does_not_use_up_the_first_open", func(t *testing.T) {
		o := newOffer(t, sales.ID)
		draftLink, err := offerSvc.CreateShareLink(ctx, o.ID, orgID, sales.ID, nil)
		if err != nil {
			t.Fatalf("link oluşturulamadı: %v", err)
		}
		view(t, draftLink.Token) // personelin taslak önizlemesi
		expectCount(t, domain.NotificationOfferViewed, o.ID, map[*domain.User]int{sales: 0})
		if _, err := offerSvc.UpdateStatus(ctx, o.ID, orgID, domain.OfferStatusGonderildi, sales.ID); err != nil {
			t.Fatalf("gönderilemedi: %v", err)
		}
		view(t, draftLink.Token) // müşteri
		expectCount(t, domain.NotificationOfferViewed, o.ID, map[*domain.User]int{sales: 1})
	})

	t.Run("first_open_without_a_reachable_creator_goes_to_managers", func(t *testing.T) {
		o := newOffer(t, "")
		view(t, send(t, o, ""))
		expectCount(t, domain.NotificationOfferViewed, o.ID, map[*domain.User]int{
			owner: 1, admin: 1, sales: 0, legacyOther: 0,
		})

		// Oluşturan artık teklifleri göremiyorsa (rolü değişti) de yöneticilere.
		gone := roleUser(t, "mlb_gone_creator", domain.OrgRoleLegacyUser)
		o2 := newOffer(t, gone.ID)
		token := send(t, o2, gone.ID)
		if _, err := authzSvc.SetUserOrganizationRole(ctx, gone.ID, orgID, owner.ID, domain.OrgRoleField); err != nil {
			t.Fatalf("rol değiştirilemedi: %v", err)
		}
		view(t, token)
		expectCount(t, domain.NotificationOfferViewed, o2.ID, map[*domain.User]int{gone: 0, owner: 1, admin: 1})
	})

	// ---------- Ek iş kararı ----------

	newProject := func(t *testing.T, name string) *domain.Project {
		t.Helper()
		o := newOffer(t, owner.ID)
		token := send(t, o, owner.ID)
		if _, err := offerSvc.RespondByShareLinkToken(ctx, token, domain.OfferStatusKabulEdildi, "", ""); err != nil {
			t.Fatalf("kabul edilemedi: %v", err)
		}
		p, err := projectSvc.CreateFromOffer(ctx, o.ID, orgID, service.CreateProjectInput{Name: name, UserID: owner.ID})
		if err != nil {
			t.Fatalf("proje oluşturulamadı: %v", err)
		}
		return p
	}
	grantAccess := func(t *testing.T, projectID, userID string) {
		t.Helper()
		if _, err := authzSvc.AddProjectUser(ctx, projectID, orgID, service.ProjectUserInput{UserID: userID, ProjectRole: "member", CreatedBy: owner.ID}); err != nil {
			t.Fatalf("proje erişimi verilemedi: %v", err)
		}
	}
	newSentCO := func(t *testing.T, projectID, creatorID, changeType, title string, amount float64) *domain.ChangeOrder {
		t.Helper()
		co, err := projectSvc.CreateChangeOrder(ctx, projectID, orgID, service.ChangeOrderInput{
			ChangeType: changeType, Title: title, UserID: creatorID,
			Items: []service.ChangeOrderItemInput{{Description: "Kalem", Quantity: 1, Unit: "adet", UnitPrice: amount}},
		})
		if err != nil {
			t.Fatalf("ek iş oluşturulamadı: %v", err)
		}
		sent, err := projectSvc.SendChangeOrder(ctx, projectID, co.ID, orgID, creatorID)
		if err != nil {
			t.Fatalf("ek iş gönderilemedi: %v", err)
		}
		return sent
	}
	coToken := func(t *testing.T, changeOrderID string) string {
		t.Helper()
		var token string
		if err := pool.QueryRow(ctx, `SELECT token::text FROM project_change_order_share_links
			WHERE change_order_id = $1 AND revoked_at IS NULL ORDER BY created_at DESC LIMIT 1`, changeOrderID).Scan(&token); err != nil {
			t.Fatalf("aktif link bulunamadı: %v", err)
		}
		return token
	}

	coCreator := roleUser(t, "mlb_co_creator", domain.OrgRoleFinance)
	approverIn := roleUser(t, "mlb_co_approver_in", domain.OrgRoleProjectManager, domain.PermProjectsFinanceRead, domain.PermProjectsChangeOrdersApprove)
	approverOut := roleUser(t, "mlb_co_approver_out", domain.OrgRoleProjectManager, domain.PermProjectsFinanceRead, domain.PermProjectsChangeOrdersApprove)

	t.Run("change_order_approved_by_customer_reaches_creator_managers_and_project_approvers", func(t *testing.T) {
		p := newProject(t, "Villa Projesi")
		grantAccess(t, p.ID, coCreator.ID)
		grantAccess(t, p.ID, approverIn.ID)
		co := newSentCO(t, p.ID, coCreator.ID, domain.ChangeOrderAddition, "Ek kat merdiveni", 15000)
		if _, err := projectSvc.RespondChangeOrderByShareLinkToken(ctx, coToken(t, co.ID), domain.ChangeOrderApproved, "1.2.3.4", "test"); err != nil {
			t.Fatalf("onaylanamadı: %v", err)
		}
		// approverOut onay iznini taşıyor ama projenin Erişim listesinde
		// değil; Eski Sistem finans okuyabilir ama ne oluşturan ne onaylayıcı.
		expectCount(t, domain.NotificationChangeOrderApproved, co.ID, map[*domain.User]int{
			coCreator: 1, owner: 1, admin: 1, approverIn: 1,
			approverOut: 0, legacyOther: 0, field: 0, finance: 0,
		})
		n := only(t, coCreator, domain.NotificationChangeOrderApproved, co.ID)
		wantBody := fmt.Sprintf("EK-%03d Ek kat merdiveni · Villa Projesi · +15.000 TL", co.SequenceNo)
		if n.Title != "Müşteri ek işi onayladı" || n.Body != wantBody {
			t.Errorf("metin: %q / %q (beklenen gövde %q)", n.Title, n.Body, wantBody)
		}
		if n.ActionTarget != "/projeler/"+p.ID+"/ek-isler/"+co.ID || n.EntityType != domain.NotificationEntityChangeOrder ||
			n.ProjectID == nil || *n.ProjectID != p.ID {
			t.Errorf("hedef: %q %q %v", n.ActionTarget, n.EntityType, n.ProjectID)
		}
	})

	t.Run("change_order_deduction_rejected_by_customer", func(t *testing.T) {
		p := newProject(t, "Eksiltme Projesi")
		grantAccess(t, p.ID, coCreator.ID)
		co := newSentCO(t, p.ID, coCreator.ID, domain.ChangeOrderDeduction, "Peyzaj iptali", 5000)
		if _, err := projectSvc.RespondChangeOrderByShareLinkToken(ctx, coToken(t, co.ID), domain.ChangeOrderRejected, "", ""); err != nil {
			t.Fatalf("reddedilemedi: %v", err)
		}
		n := only(t, coCreator, domain.NotificationChangeOrderRejected, co.ID)
		wantBody := fmt.Sprintf("EK-%03d Peyzaj iptali · Eksiltme Projesi · -5.000 TL", co.SequenceNo)
		if n.Title != "Müşteri ek işi reddetti" || n.Body != wantBody {
			t.Errorf("metin: %q / %q (beklenen gövde %q)", n.Title, n.Body, wantBody)
		}
		expectCount(t, domain.NotificationChangeOrderRejected, co.ID, map[*domain.User]int{owner: 1, admin: 1})
	})

	t.Run("staff_recorded_decision_skips_the_actor_and_names_the_recorder", func(t *testing.T) {
		p := newProject(t, "Telefon Onayı Projesi")
		grantAccess(t, p.ID, coCreator.ID)
		grantAccess(t, p.ID, approverIn.ID)
		co := newSentCO(t, p.ID, coCreator.ID, domain.ChangeOrderAddition, "Ek pencere", 2500.5)
		if _, err := projectSvc.RecordChangeOrderDecision(ctx, p.ID, co.ID, orgID, admin.ID, domain.ChangeOrderApproved, "telefonla"); err != nil {
			t.Fatalf("karar kaydedilemedi: %v", err)
		}
		expectCount(t, domain.NotificationChangeOrderApproved, co.ID, map[*domain.User]int{
			admin: 0, owner: 1, coCreator: 1, approverIn: 1, approverOut: 0,
		})
		n := only(t, owner, domain.NotificationChangeOrderApproved, co.ID)
		wantBody := fmt.Sprintf("EK-%03d Ek pencere · Telefon Onayı Projesi · +2.500,50 TL · Kaydeden: mlb_admin", co.SequenceNo)
		if n.Title != "Ek iş onaylandı" || n.Body != wantBody {
			t.Errorf("metin: %q / %q (beklenen gövde %q)", n.Title, n.Body, wantBody)
		}

		co2 := newSentCO(t, p.ID, coCreator.ID, domain.ChangeOrderAddition, "Ek kapı", 1000)
		if _, err := projectSvc.RecordChangeOrderDecision(ctx, p.ID, co2.ID, orgID, approverIn.ID, domain.ChangeOrderRejected, ""); err != nil {
			t.Fatalf("karar kaydedilemedi: %v", err)
		}
		expectCount(t, domain.NotificationChangeOrderRejected, co2.ID, map[*domain.User]int{
			approverIn: 0, owner: 1, admin: 1, coCreator: 1,
		})
		if n := only(t, coCreator, domain.NotificationChangeOrderRejected, co2.ID); n.Title != "Ek iş reddedildi" {
			t.Errorf("başlık: %q", n.Title)
		}
	})

	t.Run("change_order_creator_without_project_access_is_not_notified", func(t *testing.T) {
		p := newProject(t, "Erişim Projesi")
		leaver := roleUser(t, "mlb_co_leaver", domain.OrgRoleFinance)
		grantAccess(t, p.ID, leaver.ID)
		co := newSentCO(t, p.ID, leaver.ID, domain.ChangeOrderAddition, "Ek duvar", 3000)
		if err := authzSvc.RemoveProjectUser(ctx, p.ID, leaver.ID, orgID); err != nil {
			t.Fatalf("erişim kaldırılamadı: %v", err)
		}
		if _, err := projectSvc.RespondChangeOrderByShareLinkToken(ctx, coToken(t, co.ID), domain.ChangeOrderApproved, "", ""); err != nil {
			t.Fatalf("onaylanamadı: %v", err)
		}
		expectCount(t, domain.NotificationChangeOrderApproved, co.ID, map[*domain.User]int{leaver: 0, owner: 1, admin: 1})
	})
}
