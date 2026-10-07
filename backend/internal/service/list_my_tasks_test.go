package service_test

// GET /tasks/mine, migration 0041 (employees.user_id) ÖNCESİ yanlışlıkla
// "erişebildiğim projelerdeki TÜM görevler"i (project_users üyeliği
// üzerinden, assigned_employee_id'ye HİÇ bakmadan) döndürüyordu. Bu test
// dosyası DÜZELTİLMİŞ, GERÇEK anlamı ("bana ATANAN görevler") doğrular.

import (
	"context"
	"testing"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

func TestListMyTasks(t *testing.T) {
	dbURL := testDBURL(t)
	box := testSecretBox(t)
	ctx := context.Background()

	pool, err := repository.NewPool(ctx, dbURL)
	if err != nil {
		t.Fatalf("db: %v", err)
	}
	t.Cleanup(func() { pool.Close() })

	q := sqlc.New(pool)
	orgSvc := service.NewOrganizationService(q)
	settingsSvc := service.NewSettingsService(q, box)
	offerSvc := service.NewOfferService(pool, q, settingsSvc, "http://localhost:3000")
	projectSvc := service.NewProjectService(pool, q, mustTestStore(t), settingsSvc, "http://localhost:3000")
	userSvc := service.NewUserService(q)
	employeeSvc := service.NewEmployeeService(q)

	orgA := mustCreateOrg(t, ctx, orgSvc, pool, "MyTasks A", "mytasks-a")
	orgB := mustCreateOrg(t, ctx, orgSvc, pool, "MyTasks B", "mytasks-b")

	newProject := func(t *testing.T, orgID, name string) *domain.Project {
		t.Helper()
		o, err := offerSvc.Create(ctx, service.CreateOfferInput{
			OrganizationID: orgID,
			CustomerName:   "Musteri",
			Items:          []service.OfferItemInput{{ProductName: "Is", Quantity: 1, UnitPrice: 1000}},
		})
		if err != nil {
			t.Fatalf("offer: %v", err)
		}
		if _, err := offerSvc.UpdateStatus(ctx, o.ID, orgID, domain.OfferStatusGonderildi, ""); err != nil {
			t.Fatalf("send: %v", err)
		}
		link, err := offerSvc.CreateShareLink(ctx, o.ID, orgID, "", nil)
		if err != nil {
			t.Fatalf("link: %v", err)
		}
		if _, err := offerSvc.RespondByShareLinkToken(ctx, link.Token, domain.OfferStatusKabulEdildi, "", ""); err != nil {
			t.Fatalf("accept: %v", err)
		}
		p, err := projectSvc.CreateFromOffer(ctx, o.ID, orgID, service.CreateProjectInput{Name: name})
		if err != nil {
			t.Fatalf("project: %v", err)
		}
		return p
	}

	// newLinkedUser, bir kullanıcı + o kullanıcıya BAĞLI bir personel kaydı
	// oluşturur (migration 0041'in employees.user_id'si üzerinden) -- döner:
	// (userID, employeeID).
	newLinkedUser := func(t *testing.T, orgID, username string, role domain.Role) (string, string) {
		t.Helper()
		u, err := userSvc.Create(ctx, orgID, username, "GeciciSifre123!", "Test "+username, role, "")
		if err != nil {
			t.Fatalf("user: %v", err)
		}
		uid := u.ID
		e, err := employeeSvc.Create(ctx, orgID, service.EmployeeInput{FullName: "Personel " + username, IsActive: true, UserID: &uid})
		if err != nil {
			t.Fatalf("employee: %v", err)
		}
		return u.ID, e.ID
	}

	pA1 := newProject(t, orgA.ID, "Proje A1")
	pA2 := newProject(t, orgA.ID, "Proje A2")
	pB1 := newProject(t, orgB.ID, "Proje B1")

	userA1ID, empA1ID := newLinkedUser(t, orgA.ID, "mytasks_a1", domain.RoleKullanici)
	userA2ID, empA2ID := newLinkedUser(t, orgA.ID, "mytasks_a2", domain.RoleKullanici)
	ownerAID, empOwnerAID := newLinkedUser(t, orgA.ID, "mytasks_owner_a", domain.RoleAdmin)
	userB1ID, empB1ID := newLinkedUser(t, orgB.ID, "mytasks_b1", domain.RoleKullanici)

	// unlinkedUser: gerçek "bağlantısız kullanıcı" senaryosu için -- HİÇBİR
	// employee.user_id bu kullanıcıyı işaret etmiyor.
	unlinkedUser, err := userSvc.Create(ctx, orgA.ID, "mytasks_a3_unlinked", "GeciciSifre123!", "Bağlantısız Kullanıcı", domain.RoleKullanici, "")
	if err != nil {
		t.Fatalf("unlinked user: %v", err)
	}

	empA1 := &empA1ID
	empA2 := &empA2ID
	empOwnerA := &empOwnerAID
	empB1 := &empB1ID

	// Görev yalnızca projeyi görebilen hesaba atanabilir (bkz.
	// requireAssigneeProjectAccess). Bu test org'larında sistem rolleri seed
	// edilmediği için kimse bypass rolünde değil -- erişim açıkça verilir.
	grant := func(t *testing.T, projectID, orgID, userID string) {
		t.Helper()
		pid, _ := repository.StringToUUID(projectID)
		oid, _ := repository.StringToUUID(orgID)
		uid, _ := repository.StringToUUID(userID)
		if _, err := q.CreateProjectUser(ctx, sqlc.CreateProjectUserParams{
			OrganizationID: oid, ProjectID: pid, UserID: uid, ProjectRole: domain.ProjectRoleMember,
		}); err != nil {
			t.Fatalf("proje erişimi: %v", err)
		}
	}
	grant(t, pA1.ID, orgA.ID, userA1ID)
	grant(t, pA2.ID, orgA.ID, userA2ID)
	grant(t, pA1.ID, orgA.ID, ownerAID)
	grant(t, pB1.ID, orgB.ID, userB1ID)

	if _, err := projectSvc.CreateTask(ctx, pA1.ID, orgA.ID, service.TaskInput{Title: "A1 open -> emp A1", AssignedEmployeeID: empA1}); err != nil {
		t.Fatalf("task a1->a1: %v", err)
	}
	taskA1ToA1Done, err := projectSvc.CreateTask(ctx, pA1.ID, orgA.ID, service.TaskInput{Title: "A1 done -> emp A1", AssignedEmployeeID: empA1})
	if err != nil {
		t.Fatalf("task a1 done: %v", err)
	}
	if _, err := projectSvc.CompleteTask(ctx, pA1.ID, taskA1ToA1Done.ID, orgA.ID, ""); err != nil {
		t.Fatalf("complete: %v", err)
	}
	if _, err := projectSvc.CreateTask(ctx, pA2.ID, orgA.ID, service.TaskInput{Title: "A2 open -> emp A2", AssignedEmployeeID: empA2}); err != nil {
		t.Fatalf("task a2->a2: %v", err)
	}
	if _, err := projectSvc.CreateTask(ctx, pA1.ID, orgA.ID, service.TaskInput{Title: "A1 open -> owner", AssignedEmployeeID: empOwnerA}); err != nil {
		t.Fatalf("task a1->owner: %v", err)
	}
	if _, err := projectSvc.CreateTask(ctx, pA1.ID, orgA.ID, service.TaskInput{Title: "A1 unassigned"}); err != nil {
		t.Fatalf("task a1 unassigned: %v", err)
	}
	if _, err := projectSvc.CreateTask(ctx, pB1.ID, orgB.ID, service.TaskInput{Title: "B1 open -> emp B1", AssignedEmployeeID: empB1}); err != nil {
		t.Fatalf("task b1->b1: %v", err)
	}

	// Aşağıdaki testlerde restrictToUserID="" verilir -- bu, SADECE proje-
	// ERİŞİM sınırını (project_users üyeliği, ListProjects İLE AYNI, önceden
	// var olan ve zaten kanıtlanmış bir mekanizma) devre dışı bırakır ve
	// testin ODAĞINI TEK bir şeye indirger: assigned_employee_id filtresinin
	// KENDİSİ doğru çalışıyor mu. Proje-erişim sınırının assigned_employee_id
	// filtresinden BAĞIMSIZ olarak HÂLÂ çalıştığı (gerçek project_users
	// üyeliğiyle) test 8'de AYRICA doğrulanır.
	t.Run("1_linked_user_sees_own_assigned_task", func(t *testing.T) {
		rows, err := projectSvc.ListMyTasks(ctx, orgA.ID, "open", userA1ID, "")
		if err != nil {
			t.Fatalf("list: %v", err)
		}
		if len(rows) != 1 || rows[0].Title != "A1 open -> emp A1" {
			t.Fatalf("beklenen yalnızca kendi atanan görevi, geldi: %+v", rows)
		}
		if rows[0].ProjectName != pA1.Name {
			t.Errorf("proje adı hatalı: %s", rows[0].ProjectName)
		}
	})

	t.Run("2_user_does_not_see_another_employees_task", func(t *testing.T) {
		rows, err := projectSvc.ListMyTasks(ctx, orgA.ID, "all", userA1ID, "")
		if err != nil {
			t.Fatalf("list: %v", err)
		}
		for _, r := range rows {
			if r.Title == "A2 open -> emp A2" || r.Title == "A1 open -> owner" || r.Title == "A1 unassigned" {
				t.Fatalf("başka bir personele atanan/atanmamış görev SIZDI: %s", r.Title)
			}
		}
	})

	t.Run("3_owner_admin_mine_sees_only_own", func(t *testing.T) {
		// restrictToUserID="" -- owner/admin proje ERİŞİMİ bakımından
		// üyelikten muaf (BypassesProjectMembership) -- ama /mine YİNE DE
		// yalnızca KENDİ atanan görevini döndürmeli, TÜM org'un görevlerini
		// DEĞİL.
		rows, err := projectSvc.ListMyTasks(ctx, orgA.ID, "open", ownerAID, "")
		if err != nil {
			t.Fatalf("list: %v", err)
		}
		if len(rows) != 1 || rows[0].Title != "A1 open -> owner" {
			t.Fatalf("owner /mine yalnızca KENDİ görevini görmeli, geldi: %+v", rows)
		}
	})

	t.Run("4_unlinked_user_gets_empty_list", func(t *testing.T) {
		rows, err := projectSvc.ListMyTasks(ctx, orgA.ID, "all", unlinkedUser.ID, "")
		if err != nil {
			t.Fatalf("list: %v", err)
		}
		if len(rows) != 0 {
			t.Fatalf("bağlantısız kullanıcı BOŞ liste almalı (erişilebilir projelerin tüm görevlerine GERİ DÜŞMEMELİ), geldi: %+v", rows)
		}
	})

	t.Run("5_organization_isolation", func(t *testing.T) {
		rowsA, err := projectSvc.ListMyTasks(ctx, orgA.ID, "all", userA1ID, "")
		if err != nil {
			t.Fatalf("list a: %v", err)
		}
		for _, r := range rowsA {
			if r.Title == "B1 open -> emp B1" {
				t.Fatalf("org B görevi org A'ya SIZDI")
			}
		}
		rowsB, err := projectSvc.ListMyTasks(ctx, orgB.ID, "open", userB1ID, "")
		if err != nil {
			t.Fatalf("list b: %v", err)
		}
		if len(rowsB) != 1 || rowsB[0].Title != "B1 open -> emp B1" {
			t.Fatalf("org B kendi kullanıcısı kendi görevini görmeli, geldi: %+v", rowsB)
		}
	})

	t.Run("6_open_filter_returns_expected_statuses", func(t *testing.T) {
		rows, err := projectSvc.ListMyTasks(ctx, orgA.ID, "open", userA1ID, "")
		if err != nil {
			t.Fatalf("list: %v", err)
		}
		for _, r := range rows {
			if r.Status != domain.TaskStatusTodo && r.Status != domain.TaskStatusInProgress {
				t.Errorf("open filtresi yalnızca todo/in_progress döndürmeli, geldi: %s", r.Status)
			}
			if r.Title == "A1 done -> emp A1" {
				t.Fatalf("tamamlanmış görev 'open' filtresine SIZDI")
			}
		}
	})

	t.Run("7_all_filter_includes_completed", func(t *testing.T) {
		rows, err := projectSvc.ListMyTasks(ctx, orgA.ID, "all", userA1ID, "")
		if err != nil {
			t.Fatalf("list: %v", err)
		}
		found := false
		for _, r := range rows {
			if r.Title == "A1 done -> emp A1" {
				found = true
			}
		}
		if !found {
			t.Fatal("status=all tamamlanmış görevi de içermeli")
		}
	})

	t.Run("8_project_access_boundary_still_enforced_independent_of_assignment", func(t *testing.T) {
		// Proje-erişim sınırı (restrictToUserID != "" -- ListProjects İLE
		// AYNI, önceden var olan mekanizma), assigned_employee_id
		// eşleşmesinden TAMAMEN BAĞIMSIZ, AYRI bir savunma katmanıdır: bir
		// görev "bana atanmış" olsa bile, o projenin ÜYESİ DEĞİLSEM YİNE DE
		// görünmemelidir. userA1'in pA1 erişimi (görev atanırken vardı)
		// KALDIRILDIKTAN sonra, restrictToUserID dolu (üyelik-kısıtlı rol
		// simülasyonu) verilirse -- kendi atanan görevi bile GÖRÜNMEMELİDİR.
		pid, _ := repository.StringToUUID(pA1.ID)
		oid, _ := repository.StringToUUID(orgA.ID)
		uid, _ := repository.StringToUUID(userA1ID)
		if _, err := q.DeleteProjectUser(ctx, sqlc.DeleteProjectUserParams{ProjectID: pid, UserID: uid, OrganizationID: oid}); err != nil {
			t.Fatalf("erişim kaldırılamadı: %v", err)
		}
		rows, err := projectSvc.ListMyTasks(ctx, orgA.ID, "open", userA1ID, userA1ID)
		if err != nil {
			t.Fatalf("list: %v", err)
		}
		if len(rows) != 0 {
			t.Fatalf("proje üyesi OLMAYAN bir kullanıcı, kendi atanan görevini bile GÖRMEMELİ (savunma derinliği), geldi: %+v", rows)
		}
	})
}
