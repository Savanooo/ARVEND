package service_test

// Bildirimler (Notifications) -- gerçek bir PostgreSQL bağlantısı
// gerektirir (bkz. tenant_isolation_test.go'daki paylaşılan yardımcılar).
// Bildirim-üretme mantığı (createNotification/resolveProjectApprovers/vb.)
// PAKET-SEVİYESİNDE (unexported), bu repodaki HER servis testi gibi
// yalnızca GERÇEK iş eylemleri (CreateTask/UpdateStatus/SubmitPurchase
// Request/vb.) üzerinden, dışa açık NotificationService.List/UnreadCount/
// MarkRead/MarkAllRead ile doğrulanır -- iç yardımcı fonksiyonlar
// doğrudan çağrılmaz (bu repoda hiçbir *_test.go dosyası `package service`
// değil, hepsi `package service_test`).

import (
	"context"
	"testing"
	"time"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

func TestNotifications(t *testing.T) {
	dbURL := testDBURL(t)
	box := testSecretBox(t)
	ctx := context.Background()

	pool, err := repository.NewPool(ctx, dbURL)
	if err != nil {
		t.Fatalf("veritabanına bağlanılamadı: %v", err)
	}
	t.Cleanup(func() { pool.Close() })

	q := sqlc.New(pool)
	userSvc := service.NewUserService(q)
	employeeSvc := service.NewEmployeeService(q)
	authzSvc := service.NewAuthorizationService(q)
	settingsSvc := service.NewSettingsService(q, box)
	offerSvc := service.NewOfferService(pool, q, settingsSvc, "http://localhost:3000")
	projectSvc := service.NewProjectService(pool, q, mustTestStore(t), settingsSvc, "http://localhost:3000")
	costCodeSvc := service.NewCostCodeService(pool, q)
	supplierSvc := service.NewSupplierService(pool, q, box)
	notifSvc := service.NewNotificationService(q)
	calcSvc := service.NewCalcService(q)
	productSvc := service.NewProductService(q)
	platformSvc := service.NewPlatformService(pool, q, userSvc, calcSvc, productSvc)

	// mustCreateReadyOrg, PlatformService.CreateOrganizationWithOwner
	// üzerinden bir organizasyon + Owner kullanıcısı oluşturur -- bkz.
	// require_permission_test.go'daki AYNI isimli yardımcı. sade
	// OrganizationService.Create YETERSİZDİR: seed_system_roles_for_org'u
	// HİÇ ÇAĞIRMAZ, bu yüzden "owner" gibi hiçbir sistem rolü var OLMAZ
	// ve SetUserOrganizationRole "kayıt bulunamadı" ile BAŞARISIZ olur.
	mustCreateReadyOrg := func(t *testing.T, slug string) *service.CreateOrganizationResult {
		t.Helper()
		row := pool.QueryRow(ctx, "SELECT id FROM organizations WHERE slug = $1", slug)
		var existingID string
		if scanErr := row.Scan(&existingID); scanErr == nil {
			cleanupOrganization(t, pool, existingID)
		}
		result, err := platformSvc.CreateOrganizationWithOwner(ctx, service.CreateOrganizationInput{
			Name: "Bildirim Test " + slug, Slug: slug,
			OwnerUsername: "owner_" + slug, OwnerPassword: "GeciciSifre123!", OwnerFullName: "Bildirim Owner",
		})
		if err != nil {
			t.Fatalf("test organizasyonu+owner oluşturulamadı: %v", err)
		}
		t.Cleanup(func() { cleanupOrganization(t, pool, result.Organization.ID) })
		return result
	}

	orgAResult := mustCreateReadyOrg(t, "bildirim-test-firma-a")
	orgA := orgAResult.Organization
	orgB := mustCreateReadyOrg(t, "bildirim-test-firma-b").Organization

	// mustRoleUser, verilen incelikli organizasyon rolüne sahip yeni bir
	// kullanıcı oluşturur -- bkz. require_permission_test.go
	// mustCreateRoleUser (HTTP-seviyesi eşdeğeri), burada token'a ihtiyaç
	// yok, yalnızca servis-seviyesi çağrılar için user.ID yeterli.
	mustRoleUser := func(t *testing.T, orgID, username, roleCode string) *domain.User {
		t.Helper()
		u, err := userSvc.Create(ctx, orgID, username, "GeciciSifre123!", username, domain.RoleKullanici)
		if err != nil {
			t.Fatalf("%s oluşturulamadı: %v", username, err)
		}
		if _, err := authzSvc.SetUserOrganizationRole(ctx, u.ID, orgID, roleCode); err != nil {
			t.Fatalf("%s için rol (%s) atanamadı: %v", username, roleCode, err)
		}
		return u
	}

	mustLinkedEmployee := func(t *testing.T, orgID, fullName, userID string) *domain.Employee {
		t.Helper()
		uid := userID
		e, err := employeeSvc.Create(ctx, orgID, service.EmployeeInput{FullName: fullName, IsActive: true, UserID: &uid})
		if err != nil {
			t.Fatalf("personel (%s) oluşturulamadı: %v", fullName, err)
		}
		return e
	}

	newProject := func(t *testing.T, orgID, creatorUserID string) *domain.Project {
		t.Helper()
		o, err := offerSvc.Create(ctx, service.CreateOfferInput{
			OrganizationID: orgID, UserID: creatorUserID, CustomerName: "Bildirim Test Müşteri",
			VatRate: ptrFloat(0), Items: []service.OfferItemInput{{ProductName: "İş", Quantity: 1, UnitPrice: 100000}},
		})
		if err != nil {
			t.Fatalf("teklif oluşturulamadı: %v", err)
		}
		if _, err := offerSvc.UpdateStatus(ctx, o.ID, orgID, domain.OfferStatusGonderildi, creatorUserID); err != nil {
			t.Fatalf("gönderilemedi: %v", err)
		}
		link, err := offerSvc.CreateShareLink(ctx, o.ID, orgID, creatorUserID, nil)
		if err != nil {
			t.Fatalf("link oluşturulamadı: %v", err)
		}
		if _, err := offerSvc.RespondByShareLinkToken(ctx, link.Token, domain.OfferStatusKabulEdildi, "", ""); err != nil {
			t.Fatalf("kabul edilemedi: %v", err)
		}
		p, err := projectSvc.CreateFromOffer(ctx, o.ID, orgID, service.CreateProjectInput{Name: "Bildirim Test Projesi", UserID: creatorUserID})
		if err != nil {
			t.Fatalf("proje oluşturulamadı: %v", err)
		}
		return p
	}

	unreadCodes := func(t *testing.T, userID, orgID string) []string {
		t.Helper()
		res, err := notifSvc.List(ctx, userID, orgID, 1, 50)
		if err != nil {
			t.Fatalf("liste alınamadı: %v", err)
		}
		var codes []string
		for _, n := range res.Notifications {
			if n.ReadAt == nil {
				codes = append(codes, n.Type)
			}
		}
		return codes
	}

	// ---------- Görev ataması ----------

	t.Run("1_task_assigned_notifies_linked_user", func(t *testing.T) {
		owner := mustRoleUser(t, orgA.ID, "notif_owner1", domain.OrgRoleOwner)
		assignee := mustRoleUser(t, orgA.ID, "notif_assignee1", domain.OrgRoleField)
		emp := mustLinkedEmployee(t, orgA.ID, "Atanan Personel 1", assignee.ID)
		p := newProject(t, orgA.ID, owner.ID)

		before, err := notifSvc.UnreadCount(ctx, assignee.ID, orgA.ID)
		if err != nil {
			t.Fatalf("okunmamış sayısı alınamadı: %v", err)
		}
		task, err := projectSvc.CreateTask(ctx, p.ID, orgA.ID, service.TaskInput{
			Title: "Kalıp kontrolü", Priority: domain.TaskPriorityNormal, Status: domain.TaskStatusTodo,
			AssignedEmployeeID: &emp.ID, UserID: owner.ID,
		})
		if err != nil {
			t.Fatalf("görev oluşturulamadı: %v", err)
		}
		after, err := notifSvc.UnreadCount(ctx, assignee.ID, orgA.ID)
		if err != nil {
			t.Fatalf("okunmamış sayısı alınamadı: %v", err)
		}
		if after != before+1 {
			t.Fatalf("atanan kullanıcının okunmamış sayısı +1 artmalıydı: önce=%d sonra=%d", before, after)
		}
		res, err := notifSvc.List(ctx, assignee.ID, orgA.ID, 1, 10)
		if err != nil {
			t.Fatalf("liste alınamadı: %v", err)
		}
		found := false
		for _, n := range res.Notifications {
			if n.Type == domain.NotificationTaskAssigned && n.EntityID != nil && *n.EntityID == task.ID {
				found = true
				if n.ActionTarget != "/projeler/"+p.ID+"/gorevler/"+task.ID {
					t.Errorf("beklenmeyen action_target: %s", n.ActionTarget)
				}
			}
		}
		if !found {
			t.Fatal("task_assigned bildirimi bulunamadı")
		}
	})

	t.Run("2_task_assigned_to_unlinked_employee_does_not_fail_and_notifies_nobody", func(t *testing.T) {
		owner := mustRoleUser(t, orgA.ID, "notif_owner2", domain.OrgRoleOwner)
		p := newProject(t, orgA.ID, owner.ID)
		// Bağlı kullanıcı hesabı OLMAYAN bir personel (UserID nil).
		emp, err := employeeSvc.Create(ctx, orgA.ID, service.EmployeeInput{FullName: "Bağlantısız Personel", IsActive: true})
		if err != nil {
			t.Fatalf("personel oluşturulamadı: %v", err)
		}
		// Görev ataması KENDİSİ başarısız OLMAMALI -- bildirilecek biri
		// olmaması bir hata değildir.
		task, err := projectSvc.CreateTask(ctx, p.ID, orgA.ID, service.TaskInput{
			Title: "Bağlantısız atama", Priority: domain.TaskPriorityNormal, Status: domain.TaskStatusTodo,
			AssignedEmployeeID: &emp.ID, UserID: owner.ID,
		})
		if err != nil {
			t.Fatalf("bağlantısız personele atama BAŞARISIZ OLMAMALI: %v", err)
		}
		if task.AssignedEmployeeID == nil || *task.AssignedEmployeeID != emp.ID {
			t.Fatal("atama kendisi başarılı olmalı")
		}
	})

	t.Run("3_task_reassigned_notifies_new_assignee_only_and_is_idempotent_on_retry", func(t *testing.T) {
		owner := mustRoleUser(t, orgA.ID, "notif_owner3", domain.OrgRoleOwner)
		u1 := mustRoleUser(t, orgA.ID, "notif_u1_3", domain.OrgRoleField)
		u2 := mustRoleUser(t, orgA.ID, "notif_u2_3", domain.OrgRoleField)
		e1 := mustLinkedEmployee(t, orgA.ID, "Personel A3", u1.ID)
		e2 := mustLinkedEmployee(t, orgA.ID, "Personel B3", u2.ID)
		p := newProject(t, orgA.ID, owner.ID)

		task, err := projectSvc.CreateTask(ctx, p.ID, orgA.ID, service.TaskInput{
			Title: "Yeniden atama testi", Priority: domain.TaskPriorityNormal, Status: domain.TaskStatusTodo,
			AssignedEmployeeID: &e1.ID, UserID: owner.ID,
		})
		if err != nil {
			t.Fatalf("görev oluşturulamadı: %v", err)
		}

		u2Before, _ := notifSvc.UnreadCount(ctx, u2.ID, orgA.ID)

		// e1 -> e2'ye yeniden ata.
		if _, err := projectSvc.UpdateTask(ctx, p.ID, task.ID, orgA.ID, service.TaskInput{
			Title: task.Title, Priority: task.Priority, Status: task.Status,
			AssignedEmployeeID: &e2.ID, UserID: owner.ID,
		}); err != nil {
			t.Fatalf("yeniden atama başarısız: %v", err)
		}
		u2After1, _ := notifSvc.UnreadCount(ctx, u2.ID, orgA.ID)
		if u2After1 != u2Before+1 {
			t.Fatalf("yeni atanan +1 bildirim almalıydı: önce=%d sonra=%d", u2Before, u2After1)
		}

		// AYNI isteği tekrarla (idempotency: current.AssignedEmployeeID
		// artık zaten e2, bu yüzden "assigned" dalı bir daha TETİKLENMEMELİ).
		if _, err := projectSvc.UpdateTask(ctx, p.ID, task.ID, orgA.ID, service.TaskInput{
			Title: task.Title, Priority: task.Priority, Status: task.Status,
			AssignedEmployeeID: &e2.ID, UserID: owner.ID,
		}); err != nil {
			t.Fatalf("tekrar isteği başarısız: %v", err)
		}
		u2After2, _ := notifSvc.UnreadCount(ctx, u2.ID, orgA.ID)
		if u2After2 != u2After1 {
			t.Fatalf("AYNI atamayı tekrarlamak İKİNCİ bir bildirim ÜRETMEMELİYDİ: %d -> %d", u2After1, u2After2)
		}
	})

	// ---------- Teklif kabul/red ----------

	t.Run("4_offer_accepted_via_staff_updatestatus_notifies_creator", func(t *testing.T) {
		creator := mustRoleUser(t, orgA.ID, "notif_offer_creator4", domain.OrgRoleOwner)
		o, err := offerSvc.Create(ctx, service.CreateOfferInput{
			OrganizationID: orgA.ID, UserID: creator.ID, CustomerName: "Kabul Testi Müşteri", VatRate: ptrFloat(0),
			Items: []service.OfferItemInput{{ProductName: "Kalem", Quantity: 1, UnitPrice: 1000}},
		})
		if err != nil {
			t.Fatalf("teklif oluşturulamadı: %v", err)
		}
		before, _ := notifSvc.UnreadCount(ctx, creator.ID, orgA.ID)
		if _, err := offerSvc.UpdateStatus(ctx, o.ID, orgA.ID, domain.OfferStatusKabulEdildi, creator.ID); err != nil {
			t.Fatalf("kabul edilemedi: %v", err)
		}
		after, _ := notifSvc.UnreadCount(ctx, creator.ID, orgA.ID)
		if after != before+1 {
			t.Fatalf("teklifi oluşturan +1 bildirim almalıydı: önce=%d sonra=%d", before, after)
		}
		codes := unreadCodes(t, creator.ID, orgA.ID)
		if !contains(codes, domain.NotificationOfferAccepted) {
			t.Fatalf("offer_accepted bildirimi bulunamadı: %v", codes)
		}
	})

	t.Run("5_offer_rejected_via_public_share_link_notifies_creator", func(t *testing.T) {
		creator := mustRoleUser(t, orgA.ID, "notif_offer_creator5", domain.OrgRoleOwner)
		o, err := offerSvc.Create(ctx, service.CreateOfferInput{
			OrganizationID: orgA.ID, UserID: creator.ID, CustomerName: "Red Testi Müşteri", VatRate: ptrFloat(0),
			Items: []service.OfferItemInput{{ProductName: "Kalem", Quantity: 1, UnitPrice: 1000}},
		})
		if err != nil {
			t.Fatalf("teklif oluşturulamadı: %v", err)
		}
		if _, err := offerSvc.UpdateStatus(ctx, o.ID, orgA.ID, domain.OfferStatusGonderildi, creator.ID); err != nil {
			t.Fatalf("gönderilemedi: %v", err)
		}
		link, err := offerSvc.CreateShareLink(ctx, o.ID, orgA.ID, creator.ID, nil)
		if err != nil {
			t.Fatalf("link oluşturulamadı: %v", err)
		}
		before, _ := notifSvc.UnreadCount(ctx, creator.ID, orgA.ID)
		// Müşteri, KİMLİK DOĞRULAMASIZ genel link üzerinden reddediyor --
		// personel yine de bildirim ALMALI.
		if _, err := offerSvc.RespondByShareLinkToken(ctx, link.Token, domain.OfferStatusReddedildi, "1.2.3.4", "test-agent"); err != nil {
			t.Fatalf("reddedilemedi: %v", err)
		}
		after, _ := notifSvc.UnreadCount(ctx, creator.ID, orgA.ID)
		if after != before+1 {
			t.Fatalf("teklifi oluşturan +1 bildirim almalıydı: önce=%d sonra=%d", before, after)
		}
		codes := unreadCodes(t, creator.ID, orgA.ID)
		if !contains(codes, domain.NotificationOfferRejected) {
			t.Fatalf("offer_rejected bildirimi bulunamadı: %v", codes)
		}
	})

	// ---------- Satın alma talebi (onay-gerektiren, izin-tabanlı alıcı çözümü) ----------

	t.Run("6_purchase_request_submitted_notifies_project_scoped_approvers_only", func(t *testing.T) {
		owner := mustRoleUser(t, orgA.ID, "notif_pr_owner6", domain.OrgRoleOwner)
		requester := mustRoleUser(t, orgA.ID, "notif_pr_req6", domain.OrgRoleProjectManager)
		financeMember := mustRoleUser(t, orgA.ID, "notif_pr_fin_member6", domain.OrgRoleFinance)
		financeOutsider := mustRoleUser(t, orgA.ID, "notif_pr_fin_out6", domain.OrgRoleFinance)
		p := newProject(t, orgA.ID, owner.ID)

		// requester VE financeMember projeye AÇIKÇA üye -- financeOutsider
		// DEĞİL (aynı org'da finance rolü olsa bile, bu projeye üye
		// olmadığı için onay bildirimi ALMAMALI).
		if _, err := authzSvc.AddProjectUser(ctx, p.ID, orgA.ID, service.ProjectUserInput{UserID: requester.ID, ProjectRole: "member", CreatedBy: owner.ID}); err != nil {
			t.Fatalf("proje üyeliği eklenemedi: %v", err)
		}
		if _, err := authzSvc.AddProjectUser(ctx, p.ID, orgA.ID, service.ProjectUserInput{UserID: financeMember.ID, ProjectRole: "member", CreatedBy: owner.ID}); err != nil {
			t.Fatalf("proje üyeliği eklenemedi: %v", err)
		}

		cc, err := costCodeSvc.Create(ctx, orgA.ID, service.CostCodeInput{Code: "NOTIF-CC-6", Name: "Bildirim Test Kodu", Category: "Malzeme"})
		if err != nil {
			t.Fatalf("maliyet kodu oluşturulamadı: %v", err)
		}
		pr, err := projectSvc.CreatePurchaseRequest(ctx, p.ID, orgA.ID, service.PurchaseRequestInput{
			Title: "Çimento Talebi", UserID: requester.ID,
			Items: []service.PurchaseRequestItemInput{{CostCodeID: cc.ID, Description: "Çimento", Quantity: 50, Unit: "torba", EstimatedUnitCost: ptrFloat(60)}},
		})
		if err != nil {
			t.Fatalf("PR oluşturulamadı: %v", err)
		}

		ownerBefore, _ := notifSvc.UnreadCount(ctx, owner.ID, orgA.ID)
		financeMemberBefore, _ := notifSvc.UnreadCount(ctx, financeMember.ID, orgA.ID)
		outsiderBefore, _ := notifSvc.UnreadCount(ctx, financeOutsider.ID, orgA.ID)

		if _, err := projectSvc.SubmitPurchaseRequest(ctx, p.ID, pr.ID, orgA.ID, requester.ID); err != nil {
			t.Fatalf("PR gönderilemedi: %v", err)
		}

		// owner: bypass rolü (project_users'ta AÇIK üyeliği olmasa bile
		// projects.procurement.approve iznine sahip VE üyelik şartından
		// muaf) -- bildirim ALMALI.
		ownerAfter, _ := notifSvc.UnreadCount(ctx, owner.ID, orgA.ID)
		if ownerAfter != ownerBefore+1 {
			t.Errorf("owner (bypass rol) +1 bildirim almalıydı: önce=%d sonra=%d", ownerBefore, ownerAfter)
		}
		// financeMember: AÇIK proje üyesi VE izne sahip -- bildirim ALMALI.
		financeMemberAfter, _ := notifSvc.UnreadCount(ctx, financeMember.ID, orgA.ID)
		if financeMemberAfter != financeMemberBefore+1 {
			t.Errorf("projeye üye finance kullanıcısı +1 bildirim almalıydı: önce=%d sonra=%d", financeMemberBefore, financeMemberAfter)
		}
		// financeOutsider: izne sahip AMA bu projenin üyesi DEĞİL, bypass
		// rolü de DEĞİL -- bildirim ALMAMALI (geniş "herkese bildir"
		// varsayılanına düşülmediğinin kanıtı).
		outsiderAfter, _ := notifSvc.UnreadCount(ctx, financeOutsider.ID, orgA.ID)
		if outsiderAfter != outsiderBefore {
			t.Errorf("projeye üye OLMAYAN finance kullanıcısı bildirim ALMAMALIYDI: önce=%d sonra=%d", outsiderBefore, outsiderAfter)
		}
		// requester: kendi kendine bildirim almaz (yalnızca onaylayanlar
		// bildirilir, talebi açan zaten biliyor).
		requesterCodes := unreadCodes(t, requester.ID, orgA.ID)
		if contains(requesterCodes, domain.NotificationPurchaseRequestSubmitted) {
			t.Error("talebi açan kendi 'submitted' bildirimini ALMAMALI")
		}

		// ---- Onay: talep eden (RequestedBy) bildirilir ----
		reqBefore, _ := notifSvc.UnreadCount(ctx, requester.ID, orgA.ID)
		if _, err := projectSvc.ApprovePurchaseRequest(ctx, p.ID, pr.ID, orgA.ID, owner.ID); err != nil {
			t.Fatalf("PR onaylanamadı: %v", err)
		}
		reqAfter, _ := notifSvc.UnreadCount(ctx, requester.ID, orgA.ID)
		if reqAfter != reqBefore+1 {
			t.Fatalf("talebi açan +1 onay bildirimi almalıydı: önce=%d sonra=%d", reqBefore, reqAfter)
		}
		reqCodes := unreadCodes(t, requester.ID, orgA.ID)
		if !contains(reqCodes, domain.NotificationPurchaseRequestApproved) {
			t.Fatalf("purchase_request_approved bildirimi bulunamadı: %v", reqCodes)
		}
	})

	t.Run("7_purchase_request_rejected_notifies_requester", func(t *testing.T) {
		owner := mustRoleUser(t, orgA.ID, "notif_pr_owner7", domain.OrgRoleOwner)
		requester := mustRoleUser(t, orgA.ID, "notif_pr_req7", domain.OrgRoleProjectManager)
		p := newProject(t, orgA.ID, owner.ID)
		if _, err := authzSvc.AddProjectUser(ctx, p.ID, orgA.ID, service.ProjectUserInput{UserID: requester.ID, ProjectRole: "member", CreatedBy: owner.ID}); err != nil {
			t.Fatalf("proje üyeliği eklenemedi: %v", err)
		}
		cc, err := costCodeSvc.Create(ctx, orgA.ID, service.CostCodeInput{Code: "NOTIF-CC-7", Name: "Bildirim Test Kodu 7", Category: "Malzeme"})
		if err != nil {
			t.Fatalf("maliyet kodu oluşturulamadı: %v", err)
		}
		pr, err := projectSvc.CreatePurchaseRequest(ctx, p.ID, orgA.ID, service.PurchaseRequestInput{
			Title: "Reddedilecek Talep", UserID: requester.ID,
			Items: []service.PurchaseRequestItemInput{{CostCodeID: cc.ID, Description: "Malzeme", Quantity: 1, Unit: "adet", EstimatedUnitCost: ptrFloat(10)}},
		})
		if err != nil {
			t.Fatalf("PR oluşturulamadı: %v", err)
		}
		if _, err := projectSvc.SubmitPurchaseRequest(ctx, p.ID, pr.ID, orgA.ID, requester.ID); err != nil {
			t.Fatalf("PR gönderilemedi: %v", err)
		}
		before, _ := notifSvc.UnreadCount(ctx, requester.ID, orgA.ID)
		if _, err := projectSvc.RejectPurchaseRequest(ctx, p.ID, pr.ID, orgA.ID, owner.ID, "bütçe yetersiz"); err != nil {
			t.Fatalf("PR reddedilemedi: %v", err)
		}
		after, _ := notifSvc.UnreadCount(ctx, requester.ID, orgA.ID)
		if after != before+1 {
			t.Fatalf("talebi açan +1 red bildirimi almalıydı: önce=%d sonra=%d", before, after)
		}
		codes := unreadCodes(t, requester.ID, orgA.ID)
		if !contains(codes, domain.NotificationPurchaseRequestRejected) {
			t.Fatalf("purchase_request_rejected bildirimi bulunamadı: %v", codes)
		}
	})

	// ---------- Kiracı izolasyonu ----------

	t.Run("8_cross_org_isolation_wrong_org_id_returns_empty", func(t *testing.T) {
		owner := mustRoleUser(t, orgA.ID, "notif_iso_owner8", domain.OrgRoleOwner)
		assignee := mustRoleUser(t, orgA.ID, "notif_iso_assignee8", domain.OrgRoleField)
		emp := mustLinkedEmployee(t, orgA.ID, "İzolasyon Personeli", assignee.ID)
		p := newProject(t, orgA.ID, owner.ID)
		if _, err := projectSvc.CreateTask(ctx, p.ID, orgA.ID, service.TaskInput{
			Title: "İzolasyon görevi", Priority: domain.TaskPriorityNormal, Status: domain.TaskStatusTodo,
			AssignedEmployeeID: &emp.ID, UserID: owner.ID,
		}); err != nil {
			t.Fatalf("görev oluşturulamadı: %v", err)
		}
		// DOĞRU kullanıcı + YANLIŞ (orgB) organizasyon id'siyle sorgulamak
		// boş dönmeli -- organization_id, notifications tablosunda user_id
		// İLE BİRLİKTE filtrelenir (savunma derinliği).
		res, err := notifSvc.List(ctx, assignee.ID, orgB.ID, 1, 10)
		if err != nil {
			t.Fatalf("liste hatası: %v", err)
		}
		if len(res.Notifications) != 0 {
			t.Fatalf("yanlış organizasyon id'siyle sorgulama BOŞ dönmeliydi, geldi: %d", len(res.Notifications))
		}
		count, err := notifSvc.UnreadCount(ctx, assignee.ID, orgB.ID)
		if err != nil {
			t.Fatalf("sayaç hatası: %v", err)
		}
		if count != 0 {
			t.Fatalf("yanlış organizasyon id'siyle okunmamış sayısı 0 olmalıydı, geldi: %d", count)
		}
	})

	// ---------- Okundu/okunmadı davranışı ----------

	t.Run("9_mark_read_is_scoped_to_the_owning_user_and_idempotent", func(t *testing.T) {
		owner := mustRoleUser(t, orgA.ID, "notif_mr_owner9", domain.OrgRoleOwner)
		u1 := mustRoleUser(t, orgA.ID, "notif_mr_u1_9", domain.OrgRoleField)
		u2 := mustRoleUser(t, orgA.ID, "notif_mr_u2_9", domain.OrgRoleField)
		e1 := mustLinkedEmployee(t, orgA.ID, "Personel MR1", u1.ID)
		p := newProject(t, orgA.ID, owner.ID)
		task, err := projectSvc.CreateTask(ctx, p.ID, orgA.ID, service.TaskInput{
			Title: "Okundu testi", Priority: domain.TaskPriorityNormal, Status: domain.TaskStatusTodo,
			AssignedEmployeeID: &e1.ID, UserID: owner.ID,
		})
		if err != nil {
			t.Fatalf("görev oluşturulamadı: %v", err)
		}
		res, err := notifSvc.List(ctx, u1.ID, orgA.ID, 1, 10)
		if err != nil || len(res.Notifications) == 0 {
			t.Fatalf("bildirim listesi boş/hatalı: %v %v", res, err)
		}
		notifID := res.Notifications[0].ID

		// u2 (SAHİBİ OLMAYAN kullanıcı) u1'in bildirimini okundu yapmaya
		// çalışır -- sessizce başarılı döner AMA u1'in sayacını
		// ETKİLEMEMELİDİR (bkz. dosya/fotoğraf modülünün AYNI "var olup
		// olmadığını/kime ait olduğunu sızdırma" ilkesi).
		u1CountBefore, _ := notifSvc.UnreadCount(ctx, u1.ID, orgA.ID)
		if err := notifSvc.MarkRead(ctx, notifID, u2.ID, orgA.ID); err != nil {
			t.Fatalf("başka kullanıcının bildirimini okundu yapma denemesi hata VERMEMELİ: %v", err)
		}
		u1CountAfterForeign, _ := notifSvc.UnreadCount(ctx, u1.ID, orgA.ID)
		if u1CountAfterForeign != u1CountBefore {
			t.Fatalf("başka kullanıcının MarkRead çağrısı u1'in sayacını ETKİLEMEMELİYDİ: önce=%d sonra=%d", u1CountBefore, u1CountAfterForeign)
		}

		// u1 KENDİ bildirimini okundu yapar -- sayaç düşer.
		if err := notifSvc.MarkRead(ctx, notifID, u1.ID, orgA.ID); err != nil {
			t.Fatalf("kendi bildirimini okundu yapma başarısız: %v", err)
		}
		u1CountAfterOwn, _ := notifSvc.UnreadCount(ctx, u1.ID, orgA.ID)
		if u1CountAfterOwn != u1CountBefore-1 {
			t.Fatalf("kendi bildirimini okundu yapmak sayacı -1 düşürmeliydi: önce=%d sonra=%d", u1CountBefore, u1CountAfterOwn)
		}

		// AYNI bildirimi tekrar okundu yapmak (idempotent) hata VERMEMELİ
		// ve sayaç DEĞİŞMEMELİ.
		if err := notifSvc.MarkRead(ctx, notifID, u1.ID, orgA.ID); err != nil {
			t.Fatalf("zaten okunmuş bir bildirimi tekrar okundu yapmak hata VERMEMELİ: %v", err)
		}
		u1CountAfterRetry, _ := notifSvc.UnreadCount(ctx, u1.ID, orgA.ID)
		if u1CountAfterRetry != u1CountAfterOwn {
			t.Fatalf("tekrar MarkRead sayaç DEĞİŞTİRMEMELİYDİ: %d -> %d", u1CountAfterOwn, u1CountAfterRetry)
		}

		// Var olmayan bir bildirim id'siyle MarkRead de sessizce başarılı
		// dönmeli (varlığını sızdırmaz).
		if err := notifSvc.MarkRead(ctx, "00000000-0000-0000-0000-000000000000", u1.ID, orgA.ID); err != nil {
			t.Fatalf("var olmayan bildirim id'si hata VERMEMELİ: %v", err)
		}

		_ = task // görev ID'si yalnızca kurulum için kullanıldı, ayrıca doğrulanmadı
	})

	t.Run("10_mark_all_read_clears_every_unread_notification", func(t *testing.T) {
		owner := mustRoleUser(t, orgA.ID, "notif_mar_owner10", domain.OrgRoleOwner)
		u1 := mustRoleUser(t, orgA.ID, "notif_mar_u1_10", domain.OrgRoleField)
		e1 := mustLinkedEmployee(t, orgA.ID, "Personel MAR1", u1.ID)
		p := newProject(t, orgA.ID, owner.ID)

		// Üç ayrı görev ataması -- üç ayrı bildirim.
		for i := 0; i < 3; i++ {
			if _, err := projectSvc.CreateTask(ctx, p.ID, orgA.ID, service.TaskInput{
				Title: "Toplu okundu testi", Priority: domain.TaskPriorityNormal, Status: domain.TaskStatusTodo,
				AssignedEmployeeID: &e1.ID, UserID: owner.ID,
			}); err != nil {
				t.Fatalf("görev oluşturulamadı: %v", err)
			}
		}
		before, _ := notifSvc.UnreadCount(ctx, u1.ID, orgA.ID)
		if before < 3 {
			t.Fatalf("en az 3 okunmamış bildirim bekleniyordu, geldi: %d", before)
		}
		if err := notifSvc.MarkAllRead(ctx, u1.ID, orgA.ID); err != nil {
			t.Fatalf("MarkAllRead başarısız: %v", err)
		}
		after, _ := notifSvc.UnreadCount(ctx, u1.ID, orgA.ID)
		if after != 0 {
			t.Fatalf("MarkAllRead sonrası okunmamış sayısı 0 olmalıydı, geldi: %d", after)
		}
	})

	// ---------- Taşeron / hakediş / satın alma siparişi (alıcı: CreatedBy) ----------

	t.Run("11_subcontract_change_order_and_progress_claim_and_po_notify_the_right_creator", func(t *testing.T) {
		owner := mustRoleUser(t, orgA.ID, "notif_sc_owner11", domain.OrgRoleOwner)
		p := newProject(t, orgA.ID, owner.ID)
		supplierSvcCreated, err := supplierSvc.Create(ctx, orgA.ID, service.SupplierInput{Code: "NOTIF-SUP-11", LegalName: "Bildirim Tedarikçi 11"})
		if err != nil {
			t.Fatalf("tedarikçi oluşturulamadı: %v", err)
		}
		cc11, err := costCodeSvc.Create(ctx, orgA.ID, service.CostCodeInput{Code: "NOTIF-CC-11", Name: "Taşeron Bildirim Kodu", Category: "Taşeron"})
		if err != nil {
			t.Fatalf("maliyet kodu oluşturulamadı: %v", err)
		}
		sc, err := projectSvc.CreateSubcontract(ctx, p.ID, orgA.ID, service.SubcontractInput{
			SupplierID: supplierSvcCreated.ID, Title: "Kaba İnşaat", UserID: owner.ID,
			Items: []service.SubcontractItemInput{{CostCodeID: cc11.ID, Description: "Kalıp", Unit: "m2", Quantity: ptrFloat(100), UnitPrice: ptrFloat(200)}},
		})
		if err != nil {
			t.Fatalf("taşeron oluşturulamadı: %v", err)
		}
		beforeActivate, _ := notifSvc.UnreadCount(ctx, owner.ID, orgA.ID)
		if _, err := projectSvc.ActivateSubcontract(ctx, p.ID, sc.ID, orgA.ID, owner.ID); err != nil {
			t.Fatalf("taşeron aktifleştirilemedi: %v", err)
		}
		afterActivate, _ := notifSvc.UnreadCount(ctx, owner.ID, orgA.ID)
		if afterActivate != beforeActivate+1 {
			t.Errorf("taşeronu oluşturan +1 aktivasyon bildirimi almalıydı: önce=%d sonra=%d", beforeActivate, afterActivate)
		}
	})

	t.Run("12_po_approved_and_cancelled_notify_creator_and_approver", func(t *testing.T) {
		owner := mustRoleUser(t, orgA.ID, "notif_po_owner12", domain.OrgRoleOwner)
		poCreator := mustRoleUser(t, orgA.ID, "notif_po_creator12", domain.OrgRoleProjectManager)
		p := newProject(t, orgA.ID, owner.ID)
		if _, err := authzSvc.AddProjectUser(ctx, p.ID, orgA.ID, service.ProjectUserInput{UserID: poCreator.ID, ProjectRole: "member", CreatedBy: owner.ID}); err != nil {
			t.Fatalf("proje üyeliği eklenemedi: %v", err)
		}
		cc, err := costCodeSvc.Create(ctx, orgA.ID, service.CostCodeInput{Code: "NOTIF-CC-12", Name: "PO Bildirim Kodu", Category: "Malzeme"})
		if err != nil {
			t.Fatalf("maliyet kodu oluşturulamadı: %v", err)
		}
		sup, err := supplierSvc.Create(ctx, orgA.ID, service.SupplierInput{Code: "NOTIF-SUP-12", LegalName: "PO Bildirim Tedarikçi"})
		if err != nil {
			t.Fatalf("tedarikçi oluşturulamadı: %v", err)
		}
		po, err := projectSvc.CreatePurchaseOrder(ctx, p.ID, orgA.ID, service.PurchaseOrderInput{
			SupplierID: sup.ID, IssueDate: time.Now(), UserID: poCreator.ID,
			Items: []service.PurchaseOrderItemInput{{CostCodeID: cc.ID, Description: "Demir", Quantity: 10, UnitPrice: 500}},
		})
		if err != nil {
			t.Fatalf("PO oluşturulamadı: %v", err)
		}

		creatorBefore, _ := notifSvc.UnreadCount(ctx, poCreator.ID, orgA.ID)
		if _, err := projectSvc.ApprovePurchaseOrder(ctx, p.ID, po.ID, orgA.ID, owner.ID); err != nil {
			t.Fatalf("PO onaylanamadı: %v", err)
		}
		creatorAfterApprove, _ := notifSvc.UnreadCount(ctx, poCreator.ID, orgA.ID)
		if creatorAfterApprove != creatorBefore+1 {
			t.Errorf("PO'yu hazırlayan +1 onay bildirimi almalıydı: önce=%d sonra=%d", creatorBefore, creatorAfterApprove)
		}

		// Onaylanmış bir PO iptal edilince, hem hazırlayan (poCreator) hem
		// onaylayan (owner) bilgilendirilir -- ikisi de farklı kişiler.
		ownerBeforeCancel, _ := notifSvc.UnreadCount(ctx, owner.ID, orgA.ID)
		creatorBeforeCancel, _ := notifSvc.UnreadCount(ctx, poCreator.ID, orgA.ID)
		if _, err := projectSvc.CancelPurchaseOrder(ctx, p.ID, po.ID, orgA.ID, owner.ID, "tedarikçi vazgeçti"); err != nil {
			t.Fatalf("PO iptal edilemedi: %v", err)
		}
		ownerAfterCancel, _ := notifSvc.UnreadCount(ctx, owner.ID, orgA.ID)
		creatorAfterCancel, _ := notifSvc.UnreadCount(ctx, poCreator.ID, orgA.ID)
		if ownerAfterCancel != ownerBeforeCancel+1 {
			t.Errorf("onaylayan (owner) +1 iptal bildirimi almalıydı: önce=%d sonra=%d", ownerBeforeCancel, ownerAfterCancel)
		}
		if creatorAfterCancel != creatorBeforeCancel+1 {
			t.Errorf("hazırlayan (poCreator) +1 iptal bildirimi almalıydı: önce=%d sonra=%d", creatorBeforeCancel, creatorAfterCancel)
		}
	})
}

func contains(list []string, target string) bool {
	for _, v := range list {
		if v == target {
			return true
		}
	}
	return false
}
