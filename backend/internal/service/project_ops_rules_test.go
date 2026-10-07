package service_test

// Proje operasyonu kuralları (2026-10 denetimi): atanacak kişinin proje
// erişimi, operasyon bildirimlerinin alıcıları, düzenleme ekranından
// tamamlama/yeniden atama bildirimleri, kapalı proje mesajı, proje olay
// yazarı, alan uzunlukları, mükerrer yükleme ve WBS arşiv kuralları.
// Gerçek PostgreSQL gerektirir (bkz. tenant_isolation_test.go).

import (
	"bytes"
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

func TestProjectOpsRules(t *testing.T) {
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
	employeeSvc := service.NewEmployeeService(pool, q)
	authzSvc := service.NewAuthorizationService(pool, q)
	settingsSvc := service.NewSettingsService(q, box)
	offerSvc := service.NewOfferService(pool, q, settingsSvc, "http://localhost:3000")
	projectSvc := service.NewProjectService(pool, q, mustTestStore(t), settingsSvc, "http://localhost:3000")
	costCodeSvc := service.NewCostCodeService(pool, q)
	notifSvc := service.NewNotificationService(q)
	platformSvc := service.NewPlatformService(pool, q, userSvc, service.NewCalcService(q), service.NewProductService(q))

	const slug = "ops-kural-test"
	var existing string
	if pool.QueryRow(ctx, "SELECT id FROM organizations WHERE slug = $1", slug).Scan(&existing) == nil {
		cleanupOrganization(t, pool, existing)
	}
	created, err := platformSvc.CreateOrganizationWithOwner(ctx, service.CreateOrganizationInput{
		Name: "Operasyon Kural Test", Slug: slug,
		OwnerUsername: "owner_" + slug, OwnerPassword: "GeciciSifre123!", OwnerFullName: "Kural Owner",
	})
	if err != nil {
		t.Fatalf("organizasyon: %v", err)
	}
	t.Cleanup(func() { cleanupOrganization(t, pool, created.Organization.ID) })
	org := created.Organization

	roleUser := func(t *testing.T, username, roleCode string) *domain.User {
		t.Helper()
		u, err := userSvc.Create(ctx, org.ID, username, "GeciciSifre123!", username, domain.RoleKullanici, "")
		if err != nil {
			t.Fatalf("%s: %v", username, err)
		}
		if _, err := authzSvc.SetUserOrganizationRole(ctx, u.ID, org.ID, created.Owner.ID, roleCode); err != nil {
			t.Fatalf("%s rol: %v", username, err)
		}
		return u
	}
	linkedEmployee := func(t *testing.T, fullName, userID string) *domain.Employee {
		t.Helper()
		var uid *string
		if userID != "" {
			uid = &userID
		}
		e, err := employeeSvc.Create(ctx, org.ID, service.EmployeeInput{FullName: fullName, IsActive: true, UserID: uid})
		if err != nil {
			t.Fatalf("personel: %v", err)
		}
		return e
	}
	grant := func(t *testing.T, projectID, userID, by string) {
		t.Helper()
		if _, err := authzSvc.AddProjectUser(ctx, projectID, org.ID, service.ProjectUserInput{UserID: userID, ProjectRole: "member", CreatedBy: by}); err != nil {
			t.Fatalf("erişim: %v", err)
		}
	}
	newProject := func(t *testing.T, creatorID string) *domain.Project {
		t.Helper()
		o, err := offerSvc.Create(ctx, service.CreateOfferInput{
			OrganizationID: org.ID, UserID: creatorID, CustomerName: "Kural Müşteri", VatRate: ptrFloat(0),
			Items: []service.OfferItemInput{{ProductName: "İş", Quantity: 1, UnitPrice: 1000}},
		})
		if err != nil {
			t.Fatalf("teklif: %v", err)
		}
		if _, err := offerSvc.UpdateStatus(ctx, o.ID, org.ID, domain.OfferStatusGonderildi, creatorID); err != nil {
			t.Fatalf("gönder: %v", err)
		}
		link, err := offerSvc.CreateShareLink(ctx, o.ID, org.ID, creatorID, nil)
		if err != nil {
			t.Fatalf("link: %v", err)
		}
		if _, err := offerSvc.RespondByShareLinkToken(ctx, link.Token, domain.OfferStatusKabulEdildi, "", ""); err != nil {
			t.Fatalf("kabul: %v", err)
		}
		p, err := projectSvc.CreateFromOffer(ctx, o.ID, org.ID, service.CreateProjectInput{Name: "Kural Projesi", UserID: creatorID})
		if err != nil {
			t.Fatalf("proje: %v", err)
		}
		return p
	}
	setStatus := func(t *testing.T, projectID, status string) {
		t.Helper()
		if _, err := pool.Exec(ctx, "UPDATE projects SET status = $2 WHERE id = $1", projectID, status); err != nil {
			t.Fatal(err)
		}
	}
	countOf := func(t *testing.T, userID, typ, entityID string) int {
		t.Helper()
		res, err := notifSvc.List(ctx, userID, org.ID, 1, 100)
		if err != nil {
			t.Fatal(err)
		}
		n := 0
		for _, x := range res.Notifications {
			if x.Type == typ && (entityID == "" || (x.EntityID != nil && *x.EntityID == entityID)) {
				n++
			}
		}
		return n
	}
	newTask := func(t *testing.T, projectID, title string, empID *string, by string) *domain.ProjectTask {
		t.Helper()
		task, err := projectSvc.CreateTask(ctx, projectID, org.ID, service.TaskInput{
			Title: title, Priority: domain.TaskPriorityNormal, Status: domain.TaskStatusTodo,
			AssignedEmployeeID: empID, UserID: by,
		})
		if err != nil {
			t.Fatalf("görev (%s): %v", title, err)
		}
		return task
	}

	owner := roleUser(t, "kural_owner", domain.OrgRoleOwner)

	t.Run("1_assignee_must_be_able_to_open_the_project", func(t *testing.T) {
		p := newProject(t, owner.ID)
		outsider := roleUser(t, "kural_saha_disari", domain.OrgRoleField)
		insider := roleUser(t, "kural_saha_iceri", domain.OrgRoleField)
		admin := roleUser(t, "kural_yonetici", domain.OrgRoleAdmin)
		grant(t, p.ID, insider.ID, owner.ID)
		empOut := linkedEmployee(t, "Dışarıdaki Usta", outsider.ID)
		empIn := linkedEmployee(t, "İçerideki Usta", insider.ID)
		empAdmin := linkedEmployee(t, "Yönetici Personel", admin.ID)
		empNoApp := linkedEmployee(t, "Hesapsız İşçi", "")

		// Erişimi olmayan hesaba görev: 400 (adıyla), bildirim gitmez.
		_, err := projectSvc.CreateTask(ctx, p.ID, org.ID, service.TaskInput{
			Title: "Kalıp", AssignedEmployeeID: &empOut.ID, UserID: owner.ID,
		})
		if !errors.Is(err, service.ErrAssigneeNoProjectAccess) || !strings.Contains(err.Error(), "Dışarıdaki Usta") {
			t.Fatalf("erişimsiz kişiye görev reddedilmeli: %v", err)
		}
		if n := countOf(t, outsider.ID, domain.NotificationTaskAssigned, ""); n != 0 {
			t.Errorf("reddedilen atama bildirim üretmemeli: %d", n)
		}
		if _, err := projectSvc.CreateScheduleItem(ctx, p.ID, org.ID, service.ScheduleItemInput{
			Name: "Kaba", UserID: owner.ID, AssigneeSet: true, AssignedEmployeeID: empOut.ID,
		}); !errors.Is(err, service.ErrAssigneeNoProjectAccess) {
			t.Errorf("erişimsiz kişiye plan reddedilmeli: %v", err)
		}

		// Erişimi olan, bypass rolündeki ve hesabı olmayan personel atanabilir.
		for _, e := range []*domain.Employee{empIn, empAdmin, empNoApp} {
			newTask(t, p.ID, "Görev "+e.FullName, &e.ID, owner.ID)
		}

		// Seçici bunu gösterir (ücret alanı yok).
		as, err := projectSvc.ListAssignees(ctx, p.ID, org.ID)
		if err != nil {
			t.Fatal(err)
		}
		want := map[string][2]bool{
			empOut.ID: {true, false}, empIn.ID: {true, true}, empAdmin.ID: {true, true}, empNoApp.ID: {false, false},
		}
		seen := 0
		for _, a := range as {
			if w, ok := want[a.ID]; ok {
				seen++
				if a.HasAccount != w[0] || a.HasProjectAccess != w[1] {
					t.Errorf("%s: has_account=%v has_project_access=%v, beklenen %v", a.FullName, a.HasAccount, a.HasProjectAccess, w)
				}
			}
		}
		if seen != len(want) {
			t.Errorf("seçicide %d/%d personel", seen, len(want))
		}

		// Ekibe eklemek erişim VERMEZ (İK roster'ı) -- kişi yine atanamaz.
		if _, err := projectSvc.AssignMember(ctx, p.ID, org.ID, service.ProjectMemberInput{EmployeeID: empOut.ID, UserID: owner.ID}); err != nil {
			t.Fatalf("ekibe ekleme: %v", err)
		}
		if _, err := projectSvc.CreateTask(ctx, p.ID, org.ID, service.TaskInput{
			Title: "Kalıp 2", AssignedEmployeeID: &empOut.ID, UserID: owner.ID,
		}); !errors.Is(err, service.ErrAssigneeNoProjectAccess) {
			t.Errorf("ekip üyeliği erişim vermemeli: %v", err)
		}

		// Erişimi SONRADAN kaldırılan kişinin mevcut görevi başka alanlar
		// için düzenlenebilir; yalnızca ona YENİDEN atamak reddedilir.
		task := newTask(t, p.ID, "Sıva", &empIn.ID, owner.ID)
		if err := authzSvc.RemoveProjectUser(ctx, p.ID, insider.ID, org.ID); err != nil {
			t.Fatal(err)
		}
		if _, err := projectSvc.UpdateTask(ctx, p.ID, task.ID, org.ID, service.TaskInput{
			Title: "Sıva (2. kat)", Priority: domain.TaskPriorityHigh, Status: domain.TaskStatusTodo,
			AssignedEmployeeID: &empIn.ID, UserID: owner.ID,
		}); err != nil {
			t.Errorf("değişmeyen atama düzenlemeyi engellememeli: %v", err)
		}
		other := newTask(t, p.ID, "Boya", &empNoApp.ID, owner.ID)
		if _, err := projectSvc.UpdateTask(ctx, p.ID, other.ID, org.ID, service.TaskInput{
			Title: "Boya", Priority: domain.TaskPriorityNormal, Status: domain.TaskStatusTodo,
			AssignedEmployeeID: &empIn.ID, UserID: owner.ID,
		}); !errors.Is(err, service.ErrAssigneeNoProjectAccess) {
			t.Errorf("erişimi kaldırılmış kişiye yeniden atama reddedilmeli: %v", err)
		}
	})

	t.Run("2_task_and_upload_notices_go_to_firm_managers_explicit_members_and_parties", func(t *testing.T) {
		// Proje sahibi (owner) projeyi oluşturdu ama Erişim listesinde değil:
		// firmanın Sahip/Yönetici'leri yine de alır, "Eski Sistem" kullanıcısı
		// yalnızca listede açıkça varsa.
		p := newProject(t, owner.ID)
		ownerOut := roleUser(t, "kural_owner_disari", domain.OrgRoleOwner)
		legacy := roleUser(t, "kural_eski", domain.OrgRoleLegacyUser)
		pm := roleUser(t, "kural_pm", domain.OrgRoleProjectManager)
		worker := roleUser(t, "kural_isci", domain.OrgRoleField)
		grant(t, p.ID, pm.ID, owner.ID)
		grant(t, p.ID, worker.ID, owner.ID)
		emp := linkedEmployee(t, "Not Yazan İşçi", worker.ID)
		task := newTask(t, p.ID, "Duvar", &emp.ID, pm.ID)

		if _, _, err := projectSvc.AddTaskUpdate(ctx, p.ID, task.ID, org.ID, worker.ID, "Yarısı bitti", ""); err != nil {
			t.Fatal(err)
		}
		if countOf(t, pm.ID, domain.NotificationTaskUpdated, task.ID) != 1 {
			t.Errorf("görevi veren (Erişim'deki proje yöneticisi) not bildirimi almalı")
		}
		for _, u := range []*domain.User{owner, ownerOut} {
			if n := countOf(t, u.ID, domain.NotificationTaskUpdated, task.ID); n != 1 {
				t.Errorf("%s firma Sahibi: Erişim listesinde olmasa da not bildirimi almalı (%d)", u.Username, n)
			}
		}
		if n := countOf(t, legacy.ID, domain.NotificationTaskUpdated, task.ID); n != 0 {
			t.Errorf("Eski Sistem kullanıcısı Erişim listesinde değil: bildirim almamalı (%d)", n)
		}

		png := append([]byte{0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A}, []byte("kural-foto")...)
		if _, err := projectSvc.UploadPhoto(ctx, p.ID, org.ID, service.UploadInput{
			OriginalName: "f.png", Reader: bytes.NewReader(png), UserID: worker.ID,
		}); err != nil {
			t.Fatal(err)
		}
		if countOf(t, pm.ID, domain.NotificationPhotoUploaded, "") != 1 {
			t.Errorf("Erişim'deki yönetici yükleme bildirimi almalı")
		}
		for _, u := range []*domain.User{owner, ownerOut} {
			if n := countOf(t, u.ID, domain.NotificationPhotoUploaded, ""); n != 1 {
				t.Errorf("%s firma Sahibi yükleme bildirimi almalı (%d)", u.Username, n)
			}
		}
		if n := countOf(t, legacy.ID, domain.NotificationPhotoUploaded, ""); n != 0 {
			t.Errorf("Eski Sistem kullanıcısı yükleme bildirimi almamalı (%d)", n)
		}

		// Eski Sistem kullanıcısı Erişim listesine açıkça eklenince alır.
		grant(t, p.ID, legacy.ID, owner.ID)
		if _, _, err := projectSvc.AddTaskUpdate(ctx, p.ID, task.ID, org.ID, worker.ID, "Bitmek üzere", ""); err != nil {
			t.Fatal(err)
		}
		if countOf(t, legacy.ID, domain.NotificationTaskUpdated, task.ID) != 1 {
			t.Errorf("Erişim listesindeki Eski Sistem kullanıcısı görev notu bildirimi almalı")
		}

		// Aynı içerik ikinci kez: 409, hangi fotoğrafla çakıştığıyla.
		_, err := projectSvc.UploadPhoto(ctx, p.ID, org.ID, service.UploadInput{
			OriginalName: "f-kopya.png", Reader: bytes.NewReader(png), UserID: worker.ID,
		})
		if !errors.Is(err, service.ErrDuplicateContent) || !strings.Contains(err.Error(), "f.png") {
			t.Errorf("mükerrer fotoğraf 409 olmalı: %v", err)
		}
	})

	t.Run("3_completing_from_edit_screen_notifies_and_reassignment_is_independent", func(t *testing.T) {
		p := newProject(t, owner.ID)
		w1 := roleUser(t, "kural_w1", domain.OrgRoleField)
		w2 := roleUser(t, "kural_w2", domain.OrgRoleField)
		pm := roleUser(t, "kural_pm3", domain.OrgRoleProjectManager)
		for _, u := range []*domain.User{w1, w2, pm} {
			grant(t, p.ID, u.ID, owner.ID)
		}
		e1 := linkedEmployee(t, "İşçi Bir", w1.ID)
		e2 := linkedEmployee(t, "İşçi İki", w2.ID)

		// Düzenleme ekranından "tamamlandı": görevi veren ve atanan haber alır.
		task := newTask(t, p.ID, "Kalıp söküm", &e1.ID, owner.ID)
		if _, err := projectSvc.UpdateTask(ctx, p.ID, task.ID, org.ID, service.TaskInput{
			Title: task.Title, Priority: task.Priority, Status: domain.TaskStatusCompleted,
			AssignedEmployeeID: &e1.ID, UserID: pm.ID,
		}); err != nil {
			t.Fatal(err)
		}
		if countOf(t, owner.ID, domain.NotificationTaskCompleted, task.ID) != 1 || countOf(t, w1.ID, domain.NotificationTaskCompleted, task.ID) != 1 {
			t.Errorf("düzenleme ekranından tamamlama /complete gibi bildirmeli")
		}
		if countOf(t, pm.ID, domain.NotificationTaskCompleted, task.ID) != 0 {
			t.Errorf("tamamlayan kendine bildirim almamalı")
		}

		// Aynı kayıtta hem tamamla hem başkasına ata: yeni sahibi "atandı" alır.
		task2 := newTask(t, p.ID, "Demir bağlama", &e1.ID, owner.ID)
		if _, err := projectSvc.UpdateTask(ctx, p.ID, task2.ID, org.ID, service.TaskInput{
			Title: task2.Title, Priority: task2.Priority, Status: domain.TaskStatusCompleted,
			AssignedEmployeeID: &e2.ID, UserID: owner.ID,
		}); err != nil {
			t.Fatal(err)
		}
		if countOf(t, w2.ID, domain.NotificationTaskAssigned, task2.ID) != 1 {
			t.Errorf("tamamlanırken yeniden atanan kişi 'Yeni görev atandı' almalı")
		}
		if countOf(t, w1.ID, domain.NotificationTaskCompleted, task2.ID) != 1 {
			t.Errorf("görevi o ana dek yürüten kişi tamamlanma bildirimi almalı")
		}
		events, err := projectSvc.ListProjectEvents(ctx, p.ID, org.ID)
		if err != nil {
			t.Fatal(err)
		}
		var completed, assigned int
		for _, ev := range events {
			if ev.Metadata["task_id"] != task2.ID {
				continue
			}
			switch ev.EventType {
			case domain.ProjectEventTaskCompleted:
				completed++
			case domain.ProjectEventTaskAssigned:
				assigned++
			}
		}
		// assigned: oluşturma (e1) + yeniden atama (e2).
		if completed != 1 || assigned != 2 {
			t.Errorf("olaylar: completed=%d assigned=%d", completed, assigned)
		}
	})

	t.Run("4_closed_project_message_is_not_about_finance", func(t *testing.T) {
		emp := linkedEmployee(t, "Kapalı Proje Personeli", "")
		for _, tc := range []struct {
			status, want string
		}{
			{domain.ProjectStatusCompleted, "yeniden aktif"},
			{domain.ProjectStatusCancelled, "iptal"},
		} {
			p := newProject(t, owner.ID)
			setStatus(t, p.ID, tc.status)
			errs := map[string]error{}
			_, errs["görev"] = projectSvc.CreateTask(ctx, p.ID, org.ID, service.TaskInput{Title: "X"})
			_, errs["plan"] = projectSvc.CreateScheduleItem(ctx, p.ID, org.ID, service.ScheduleItemInput{Name: "X"})
			_, errs["ekip"] = projectSvc.AssignMember(ctx, p.ID, org.ID, service.ProjectMemberInput{EmployeeID: emp.ID})
			_, errs["dosya"] = projectSvc.UploadFile(ctx, p.ID, org.ID, service.UploadInput{OriginalName: "a.pdf", Reader: strings.NewReader("%PDF-1.4\nx\n")})
			_, errs["wbs"] = projectSvc.CreateWBSNode(ctx, p.ID, org.ID, service.WBSNodeInput{Code: "1", Name: "X"})
			for what, err := range errs {
				if !errors.Is(err, service.ErrProjectLocked) {
					t.Errorf("%s/%s: kapalı projede reddedilmeli: %v", tc.status, what, err)
					continue
				}
				if strings.Contains(err.Error(), "finans") || !strings.Contains(err.Error(), tc.want) {
					t.Errorf("%s/%s: beklenmeyen mesaj: %q", tc.status, what, err.Error())
				}
			}
		}
	})

	t.Run("5_project_update_records_its_author", func(t *testing.T) {
		p := newProject(t, owner.ID)
		if _, err := projectSvc.Update(ctx, p.ID, org.ID, service.UpdateProjectInput{
			Name: p.Name, Status: domain.ProjectStatusActive, UserID: owner.ID,
		}); err != nil {
			t.Fatal(err)
		}
		if _, err := projectSvc.Update(ctx, p.ID, org.ID, service.UpdateProjectInput{
			Name: p.Name + " (rev)", Status: domain.ProjectStatusActive, UserID: owner.ID,
		}); err != nil {
			t.Fatal(err)
		}
		events, err := projectSvc.ListProjectEvents(ctx, p.ID, org.ID)
		if err != nil {
			t.Fatal(err)
		}
		found := 0
		for _, ev := range events {
			if ev.EventType == domain.ProjectEventStatusChanged || ev.EventType == domain.ProjectEventUpdated {
				found++
				if ev.UserID == nil || *ev.UserID != owner.ID {
					t.Errorf("%s olayının yazarı olmalı: %v", ev.EventType, ev.UserID)
				}
			}
		}
		if found != 2 {
			t.Errorf("iki güncelleme olayı bekleniyordu: %d", found)
		}
	})

	t.Run("6_length_limits_are_validation_errors", func(t *testing.T) {
		p := newProject(t, owner.ID)
		emp := linkedEmployee(t, "Uzunluk Personeli", "")
		long := func(n int) string { return strings.Repeat("ş", n) }

		if _, err := projectSvc.CreateTask(ctx, p.ID, org.ID, service.TaskInput{Title: long(201)}); !errors.Is(err, service.ErrProjectFieldTooLong) || !strings.Contains(err.Error(), "200") {
			t.Errorf("görev başlığı > 200: %v", err)
		}
		if _, err := projectSvc.CreateTask(ctx, p.ID, org.ID, service.TaskInput{Title: long(200)}); err != nil {
			t.Errorf("tam 200 karakter kabul edilmeli: %v", err)
		}
		if _, err := projectSvc.CreateScheduleItem(ctx, p.ID, org.ID, service.ScheduleItemInput{Name: long(201)}); !errors.Is(err, service.ErrProjectFieldTooLong) {
			t.Errorf("aşama adı > 200: %v", err)
		}
		if _, err := projectSvc.AssignMember(ctx, p.ID, org.ID, service.ProjectMemberInput{EmployeeID: emp.ID, RoleTitle: long(121)}); !errors.Is(err, service.ErrProjectFieldTooLong) {
			t.Errorf("görev/rol > 120: %v", err)
		}
		if _, err := projectSvc.UploadFile(ctx, p.ID, org.ID, service.UploadInput{
			OriginalName: "uzun.pdf", Reader: strings.NewReader("%PDF-1.4\nuzun\n"), Description: long(501),
		}); !errors.Is(err, service.ErrProjectFieldTooLong) || !strings.Contains(err.Error(), "Açıklama") {
			t.Errorf("açıklama > 500: %v", err)
		}
		if files, _ := projectSvc.ListFiles(ctx, p.ID, org.ID); len(files) != 0 {
			t.Errorf("reddedilen yükleme kayıt bırakmamalı: %d", len(files))
		}
		if _, err := projectSvc.Update(ctx, p.ID, org.ID, service.UpdateProjectInput{Name: long(201)}); !errors.Is(err, service.ErrProjectFieldTooLong) {
			t.Errorf("proje adı > 200: %v", err)
		}
	})

	t.Run("7_archived_wbs_nodes_are_not_parents_or_budget_targets", func(t *testing.T) {
		p := newProject(t, owner.ID)
		root, err := projectSvc.CreateWBSNode(ctx, p.ID, org.ID, service.WBSNodeInput{Code: "1", Name: "Kaba"})
		if err != nil {
			t.Fatal(err)
		}
		child, err := projectSvc.CreateWBSNode(ctx, p.ID, org.ID, service.WBSNodeInput{ParentID: root.ID, Code: "1.1", Name: "Temel"})
		if err != nil {
			t.Fatal(err)
		}
		if err := projectSvc.ArchiveWBSNode(ctx, p.ID, root.ID, org.ID, owner.ID); !errors.Is(err, service.ErrWBSHasActiveChildren) {
			t.Fatalf("aktif alt düğümü olan düğüm arşivlenmemeli: %v", err)
		}
		if err := projectSvc.ArchiveWBSNode(ctx, p.ID, child.ID, org.ID, owner.ID); err != nil {
			t.Fatal(err)
		}
		if _, err := projectSvc.CreateWBSNode(ctx, p.ID, org.ID, service.WBSNodeInput{ParentID: child.ID, Code: "1.1.1", Name: "Grobeton"}); !errors.Is(err, service.ErrArchivedWBSParent) {
			t.Errorf("arşivlenmiş düğümün altına ekleme reddedilmeli: %v", err)
		}

		// Projeye dönüştürme taslak bütçeyi zaten açıyor olabilir.
		if _, err := projectSvc.CreateProjectBudget(ctx, p.ID, org.ID, owner.ID); err != nil && !errors.Is(err, service.ErrBudgetAlreadyExists) {
			t.Fatal(err)
		}
		cc, err := costCodeSvc.Create(ctx, org.ID, service.CostCodeInput{Code: "KURAL-CC", Name: "Kural Kodu", Category: "Malzeme"})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := projectSvc.CreateBudgetLine(ctx, p.ID, org.ID, service.BudgetLineInput{
			WBSNodeID: child.ID, CostCodeID: cc.ID, Description: "Beton", OriginalAmount: 100,
		}); !errors.Is(err, service.ErrArchivedWBSNodeRef) {
			t.Errorf("arşivlenmiş düğüme bütçe kalemi reddedilmeli: %v", err)
		}
		if _, err := projectSvc.CreateBudgetLine(ctx, p.ID, org.ID, service.BudgetLineInput{
			WBSNodeID: "00000000-0000-0000-0000-000000000000", CostCodeID: cc.ID, Description: "Beton", OriginalAmount: 100,
		}); !errors.Is(err, service.ErrInvalidWBSNodeRef) || strings.Contains(err.Error(), "üst") {
			t.Errorf("olmayan düğüm 'üst düğüm' demeden reddedilmeli: %v", err)
		}
		line, err := projectSvc.CreateBudgetLine(ctx, p.ID, org.ID, service.BudgetLineInput{
			WBSNodeID: root.ID, CostCodeID: cc.ID, Description: "Kalıp", OriginalAmount: 100,
		})
		if err != nil {
			t.Fatal(err)
		}
		// Kalemin bağlı olduğu düğüm sonradan arşivlenirse kalem yine de
		// (aynı düğümle) düzenlenebilir.
		if err := projectSvc.ArchiveWBSNode(ctx, p.ID, root.ID, org.ID, owner.ID); err != nil {
			t.Fatalf("alt düğümleri arşivli kök arşivlenebilmeli: %v", err)
		}
		if _, err := projectSvc.UpdateBudgetLine(ctx, p.ID, line.ID, org.ID, service.BudgetLineInput{
			WBSNodeID: root.ID, CostCodeID: cc.ID, Description: "Kalıp (rev)", OriginalAmount: 120,
		}); err != nil {
			t.Errorf("mevcut (arşivlenmiş) düğümle düzenleme engellenmemeli: %v", err)
		}
	})
}

// TestClosedProjectTasksRule: kapalı (tamamlanmış/iptal) projenin açık
// görevleri ne "Görevlerim/Ekip" açık listesinde ne de ana sayfa
// sayaçlarında görünür -- iki yüzey aynı sayıyı verir.
func TestClosedProjectTasksRule(t *testing.T) {
	e := newDashTestEnv(t, "dash-kapali-gorev")
	u, authz := e.owner(t, "kapali_gorev_owner")
	empID := e.scalar(t, `INSERT INTO employees (organization_id, full_name, is_active, user_id)
		VALUES ($1, 'Kapalı Görev Personeli', true, $2) RETURNING id::text`, e.org.ID, u.ID)
	overdue := e.day(-3)
	for _, status := range []string{domain.ProjectStatusActive, domain.ProjectStatusCompleted, domain.ProjectStatusCancelled} {
		p := e.project(t, "Proje "+status, status, "TRY", 1000)
		e.exec(t, `INSERT INTO project_tasks (organization_id, project_id, title, assigned_employee_id, assigned_name, status, due_date)
			VALUES ($1, $2, $3, $4, 'Kapalı Görev Personeli', 'todo', $5)`, e.org.ID, p.ID, "Görev "+status, empID, overdue)
	}

	mine, err := e.projectSvc.ListMyTasks(e.ctx, e.org.ID, "open", u.ID, "")
	if err != nil {
		t.Fatal(err)
	}
	if len(mine) != 1 || mine[0].ProjectStatus != domain.ProjectStatusActive {
		t.Fatalf("'open' yalnızca açık projenin görevini dönmeli: %+v", mine)
	}
	all, err := e.projectSvc.ListMyTasks(e.ctx, e.org.ID, "all", u.ID, "")
	if err != nil {
		t.Fatal(err)
	}
	closed := 0
	for _, tk := range all {
		if tk.ProjectClosed() {
			closed++
		}
	}
	if len(all) != 3 || closed != 2 {
		t.Errorf("'all' kapalı projelerin görevlerini işaretli göstermeli: %d görev, %d kapalı", len(all), closed)
	}
	team, total, err := e.projectSvc.ListTeamTasks(e.ctx, e.org.ID, "open", "", "")
	if err != nil {
		t.Fatal(err)
	}
	if len(team) != 1 || total != 1 {
		t.Errorf("ekip 'open': %d görev, toplam %d", len(team), total)
	}

	d := e.get(t, authz, domain.RoleAdmin)
	if d.Sections.Tasks == nil {
		t.Fatal("görev bölümü yok")
	}
	if d.Sections.Tasks.Mine.Open != len(mine) || d.Sections.Tasks.Mine.Overdue != 1 {
		t.Errorf("ana sayfa (benim) Görevlerim ile ayrışmamalı: open=%d overdue=%d, liste=%d", d.Sections.Tasks.Mine.Open, d.Sections.Tasks.Mine.Overdue, len(mine))
	}
	if d.Sections.Tasks.Team.Open != int(total) || d.Sections.Tasks.Team.Overdue != 1 {
		t.Errorf("ana sayfa (ekip) Ekip listesiyle ayrışmamalı: open=%d overdue=%d, liste=%d", d.Sections.Tasks.Team.Open, d.Sections.Tasks.Team.Overdue, total)
	}
}
