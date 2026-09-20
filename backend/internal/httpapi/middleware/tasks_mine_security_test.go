package middleware_test

// GET /tasks/mine — migration 0041 (employees.user_id) sonrası GERÇEK
// anlamını (bana ATANAN görevler) HTTP katmanında doğrular.
// setupRBACTestRouter/rbacCleanupOrg İLE AYNI paylaşılan harness'i
// kullanır (procurement_security_test.go, subcontract_security_test.go
// İLE AYNI desen).

import (
	"context"
	"net/http"
	"testing"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

func TestTasksMineSecurity(t *testing.T) {
	d := setupRBACTestRouter(t)
	ctx := context.Background()

	org := mustCreateReadyOrg(t, ctx, d, "tasks-mine-org")
	t.Cleanup(func() { rbacCleanupOrg(t, d.pool, org.Organization.ID) })

	linkedUser, linkedToken := mustCreateRoleUser(t, ctx, d, org.Organization.ID, "tm_linked", domain.OrgRoleProjectManager)
	_, unlinkedToken := mustCreateRoleUser(t, ctx, d, org.Organization.ID, "tm_unlinked", domain.OrgRoleProjectManager)

	p := mustCreateProject(t, ctx, d, org.Organization.ID, "Tasks Mine Projesi")
	if _, err := d.authzSvc.AddProjectUser(ctx, p.ID, org.Organization.ID, service.ProjectUserInput{
		UserID: linkedUser.ID, ProjectRole: domain.ProjectRoleMember, CreatedBy: org.Owner.ID,
	}); err != nil {
		t.Fatalf("üyelik eklenemedi: %v", err)
	}

	// employees.user_id bağlantısı doğrudan SQL ile kurulur -- rbacTestDeps
	// bir EmployeeService taşımıyor (bu harness'in mevcut kapsamı dışında),
	// migration 0041'in kendisi zaten internal/service/employee_user_link_
	// test.go'da servis seviyesinde ayrıntılı test edildi; burada yalnızca
	// UÇTAN UCA HTTP davranışı doğrulanıyor.
	var employeeID string
	if err := d.pool.QueryRow(ctx,
		"INSERT INTO employees (organization_id, full_name, is_active, user_id) VALUES ($1, $2, true, $3) RETURNING id",
		org.Organization.ID, "Tasks Mine Personeli", linkedUser.ID,
	).Scan(&employeeID); err != nil {
		t.Fatalf("personel bağlantısı kurulamadı: %v", err)
	}

	taskRec, taskBody := rbacDo(t, d.router, http.MethodPost, "/api/v1/projects/"+p.ID+"/tasks", linkedToken,
		`{"title":"Bana Atanan Görev","assigned_employee_id":"`+employeeID+`"}`)
	if taskRec.Code != http.StatusCreated {
		t.Fatalf("görev oluşturulamadı: %d %v", taskRec.Code, taskBody)
	}

	t.Run("1_unauthenticated_request_rejected", func(t *testing.T) {
		rec, _ := rbacDo(t, d.router, http.MethodGet, "/api/v1/tasks/mine", "", "")
		if rec.Code != http.StatusUnauthorized {
			t.Errorf("status = %d, want 401 (token yok)", rec.Code)
		}
	})

	t.Run("2_linked_user_sees_own_assigned_task_over_http", func(t *testing.T) {
		rec, body := rbacDo(t, d.router, http.MethodGet, "/api/v1/tasks/mine", linkedToken, "")
		if rec.Code != http.StatusOK {
			t.Fatalf("status = %d, want 200, body=%v", rec.Code, body)
		}
		tasks, _ := body["tasks"].([]any)
		if len(tasks) != 1 {
			t.Fatalf("beklenen tam olarak 1 görev, geldi: %v", body)
		}
		first, _ := tasks[0].(map[string]any)
		if first["title"] != "Bana Atanan Görev" {
			t.Errorf("yanlış görev döndü: %v", first)
		}
	})

	t.Run("3_unlinked_user_gets_empty_200_over_http", func(t *testing.T) {
		rec, body := rbacDo(t, d.router, http.MethodGet, "/api/v1/tasks/mine", unlinkedToken, "")
		if rec.Code != http.StatusOK {
			t.Fatalf("status = %d, want 200 (bağlantısız kullanıcı da 200+boş almalı, hata DEĞİL), body=%v", rec.Code, body)
		}
		tasks, _ := body["tasks"].([]any)
		if len(tasks) != 0 {
			t.Errorf("bağlantısız kullanıcı BOŞ liste almalı, geldi: %v", tasks)
		}
	})
}
