package middleware_test

// GET /api/v1/dashboard ve GET /api/v1/dashboard/project-options -- GERÇEK
// router + GERÇEK PostgreSQL (spec §4.11 "Security", 12 madde). /dashboard'da
// perm() YOKTUR: görünürlük tamamen serviste, bölüm kapılarıyla verilir;
// bu dosya kapıların, üyelik kapsamının, kişiye özel izinlerin ve
// "saha rolüne para yok" kuralının HTTP ucunda gerçekten tuttuğunu
// doğrular. setupRBACTestRouter harness'ini kullanır (tasks_mine_security_
// test.go ile aynı desen).

import (
	"context"
	"encoding/json"
	"net/http"
	"slices"
	"sort"
	"testing"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

type dashBody struct {
	Viewer struct {
		AllProjects            bool   `json:"all_projects"`
		AccessibleProjectCount int    `json:"accessible_project_count"`
		OrganizationRoleCode   string `json:"organization_role_code"`
	} `json:"viewer"`
	Onboarding json.RawMessage `json:"onboarding"`
	Agenda     struct {
		Groups []struct {
			Code   string `json:"code"`
			Lane   string `json:"lane"`
			Count  int    `json:"count"`
			Module string `json:"module"`
		} `json:"groups"`
	} `json:"agenda"`
	Sections      map[string]json.RawMessage `json:"sections"`
	SectionErrors map[string]string          `json:"section_errors"`
}

func (b dashBody) keys() []string {
	out := make([]string, 0, len(b.Sections))
	for k := range b.Sections {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

func (b dashBody) group(code string) (lane string, count int, ok bool) {
	for _, g := range b.Agenda.Groups {
		if g.Code == code {
			return g.Lane, g.Count, true
		}
	}
	return "", 0, false
}

func (b dashBody) section(t *testing.T, key string, dst any) {
	t.Helper()
	raw, ok := b.Sections[key]
	if !ok {
		t.Fatalf("%q bölümü yok (bölümler: %v)", key, b.keys())
	}
	if err := json.Unmarshal(raw, dst); err != nil {
		t.Fatalf("%q çözülemedi: %v", key, err)
	}
}

func getDashboard(t *testing.T, d *rbacTestDeps, token string) (dashBody, map[string]any) {
	t.Helper()
	rec, generic := rbacDo(t, d.router, http.MethodGet, "/api/v1/dashboard", token, "")
	if rec.Code != http.StatusOK {
		t.Fatalf("GET /dashboard = %d, body=%s", rec.Code, rec.Body.String())
	}
	if cc := rec.Header().Get("Cache-Control"); cc != "no-store" {
		t.Errorf("Cache-Control = %q, beklenen no-store", cc)
	}
	var body dashBody
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("yanıt çözülemedi: %v", err)
	}
	return body, generic
}

// dashMoneyKeys: tutar taşıyan alanlar -- finans izni olmayan izleyicide
// ya hiç yoktur ya da null / boş dizidir.
var dashMoneyKeys = map[string]bool{
	"amount": true, "amounts": true, "current_value": true, "portfolio_value": true, "collected_total": true,
	"open_receivable": true, "realized_cost": true, "cash_balance": true, "paid_to_date": true,
	"committed_active": true, "approved_net_this_month": true, "by_currency": true, "approved_this_month": true,
	"contract_amount": true, "grand_total": true, "remaining": true,
}

func assertNoMoneyJSON(t *testing.T, path string, v any) {
	t.Helper()
	switch x := v.(type) {
	case map[string]any:
		for k, child := range x {
			p := path + "." + k
			if dashMoneyKeys[k] {
				switch c := child.(type) {
				case nil:
				case []any:
					if len(c) > 0 {
						t.Errorf("%s: para dizisi dolu: %v", p, c)
					}
				default:
					t.Errorf("%s: para değeri sızdı: %v", p, c)
				}
				continue
			}
			assertNoMoneyJSON(t, p, child)
		}
	case []any:
		for _, child := range x {
			assertNoMoneyJSON(t, path+"[]", child)
		}
	}
}

func TestDashboardSecurity(t *testing.T) {
	d := setupRBACTestRouter(t)
	ctx := context.Background()

	orgA := mustCreateReadyOrg(t, ctx, d, "dashboard-sec-org-a")
	t.Cleanup(func() { rbacCleanupOrg(t, d.pool, orgA.Organization.ID) })
	orgB := mustCreateReadyOrg(t, ctx, d, "dashboard-sec-org-b")
	t.Cleanup(func() { rbacCleanupOrg(t, d.pool, orgB.Organization.ID) })
	a := orgA.Organization.ID

	ownerToken, err := d.issuer.IssueAccessToken(orgA.Owner.ID, domain.RoleAdmin, a)
	if err != nil {
		t.Fatal(err)
	}
	ownerBToken, err := d.issuer.IssueAccessToken(orgB.Owner.ID, domain.RoleAdmin, orgB.Organization.ID)
	if err != nil {
		t.Fatal(err)
	}
	superToken, err := d.issuer.IssueAccessToken("00000000-0000-0000-0000-0000000000ee", domain.RoleSuperAdmin, "")
	if err != nil {
		t.Fatal(err)
	}

	field, fieldToken := mustCreateRoleUser(t, ctx, d, a, "dash_field", domain.OrgRoleField)
	field2, field2Token := mustCreateRoleUser(t, ctx, d, a, "dash_field2", domain.OrgRoleField)
	pm, pmToken := mustCreateRoleUser(t, ctx, d, a, "dash_pm", domain.OrgRoleProjectManager)
	fin, finToken := mustCreateRoleUser(t, ctx, d, a, "dash_fin", domain.OrgRoleFinance)
	fin2, fin2Token := mustCreateRoleUser(t, ctx, d, a, "dash_fin2", domain.OrgRoleFinance)
	grantee, granteeToken := mustCreateRoleUser(t, ctx, d, a, "dash_grantee", domain.OrgRoleField)
	deleted, _ := mustCreateRoleUser(t, ctx, d, a, "dash_deleted", domain.OrgRoleField)

	p1 := mustCreateProject(t, ctx, d, a, "Dashboard Üye Projesi")
	p2 := mustCreateProject(t, ctx, d, a, "Dashboard Diğer Proje")
	for _, u := range []*domain.User{field, field2, pm, fin, fin2, grantee} {
		if _, err := d.authzSvc.AddProjectUser(ctx, p1.ID, a, service.ProjectUserInput{
			UserID: u.ID, ProjectRole: domain.ProjectRoleMember, CreatedBy: orgA.Owner.ID,
		}); err != nil {
			t.Fatalf("üyelik: %v", err)
		}
	}

	exec := func(sql string, args ...any) {
		t.Helper()
		if _, err := d.pool.Exec(ctx, sql, args...); err != nil {
			t.Fatalf("SQL (%s): %v", sql, err)
		}
	}
	var fieldEmployee string
	if err := d.pool.QueryRow(ctx,
		"INSERT INTO employees (organization_id, full_name, is_active, user_id) VALUES ($1, 'Saha Personeli', true, $2) RETURNING id",
		a, field.ID).Scan(&fieldEmployee); err != nil {
		t.Fatalf("personel: %v", err)
	}
	// Görevler: P1'de sahaya atanmış gecikmiş görev; P2'de atanmamış gecikmiş görev.
	exec(`INSERT INTO project_tasks (organization_id, project_id, title, status, due_date, assigned_employee_id)
	      VALUES ($1, $2, 'P1 gecikmiş görev', 'todo', CURRENT_DATE - 1, $3)`, a, p1.ID, fieldEmployee)
	exec(`INSERT INTO project_tasks (organization_id, project_id, title, status, due_date)
	      VALUES ($1, $2, 'P2 gecikmiş görev', 'todo', CURRENT_DATE - 1)`, a, p2.ID)
	// P1: onay bekleyen satın alma talebi + vadesi geçmiş ödeme planı kalemi.
	exec(`INSERT INTO purchase_requests (organization_id, project_id, pr_no, title, status, estimated_total, submitted_at)
	      VALUES ($1, $2, 'DASH-PR-1', 'Güvenlik talebi', 'submitted', 1000, now())`, a, p1.ID)
	exec(`INSERT INTO project_payment_plan_items (organization_id, project_id, name, planned_amount, due_date, sort_order)
	      VALUES ($1, $2, 'Gecikmiş kalem', 5000, CURRENT_DATE - 3, 1)`, a, p1.ID)
	// Olaylar: P1 tahsilat (finans) + görev; P2 görev.
	exec(`INSERT INTO project_events (organization_id, project_id, event_type, metadata)
	      VALUES ($1, $2, 'collection_received', '{"amount": 5000}'), ($1, $2, 'task_created', '{}'),
	             ($1, $3, 'task_created', '{}')`, a, p1.ID, p2.ID)
	// Silinmiş kullanıcı sayılmaz; kaba admin olmayan birine
	// organization.users.read doğrudan (API'nin reddettiği yoldan) verilir.
	exec("UPDATE users SET deleted_at = now(), is_active = false WHERE id = $1", deleted.ID)
	exec(`INSERT INTO user_permission_overrides (user_id, organization_id, permission_code, effect)
	      VALUES ($1, $2, $3, 'grant')`, grantee.ID, a, domain.PermOrganizationUsersRead)

	// Firma B: A'nın hiçbir sayısını değiştirmemeli.
	mustCreateProject(t, ctx, d, orgB.Organization.ID, "B Projesi")
	mustCreateRoleUser(t, ctx, d, orgB.Organization.ID, "dash_b_user", domain.OrgRoleField)

	t.Run("1_no_token_401", func(t *testing.T) {
		for _, path := range []string{"/api/v1/dashboard", "/api/v1/dashboard/project-options"} {
			rec, _ := rbacDo(t, d.router, http.MethodGet, path, "", "")
			if rec.Code != http.StatusUnauthorized {
				t.Errorf("%s status = %d, beklenen 401", path, rec.Code)
			}
		}
	})

	t.Run("2_super_admin_403_tenant_context_required", func(t *testing.T) {
		for _, path := range []string{"/api/v1/dashboard", "/api/v1/dashboard/project-options"} {
			rec, body := rbacDo(t, d.router, http.MethodGet, path, superToken, "")
			if rec.Code != http.StatusForbidden || body["code"] != "tenant_context_required" {
				t.Errorf("%s: %d %v, beklenen 403 tenant_context_required", path, rec.Code, body)
			}
		}
	})

	t.Run("3_owner_gets_all_20_sections", func(t *testing.T) {
		body, _ := getDashboard(t, d, ownerToken)
		want := append([]string{}, domain.DashboardSectionKeys...)
		sort.Strings(want)
		if got := body.keys(); !slices.Equal(got, want) {
			t.Errorf("bölümler\n got  %v\n want %v", got, want)
		}
		if !body.Viewer.AllProjects || body.Viewer.AccessibleProjectCount != 2 || len(body.SectionErrors) != 0 {
			t.Errorf("viewer %+v, hatalar %v", body.Viewer, body.SectionErrors)
		}
		if string(body.Onboarding) != "null" {
			t.Errorf("projesi olan firmada onboarding null olmalı: %s", body.Onboarding)
		}
		if lane, _, ok := body.group(domain.AttnPurchaseRequestApproval); !ok || lane != domain.LaneMine {
			t.Errorf("Sahip onay bekleyen talebi kendi şeridinde görmeli: %q %v", lane, ok)
		}
	})

	t.Run("4_field_member_of_one_project", func(t *testing.T) {
		body, generic := getDashboard(t, d, fieldToken)
		want := []string{"activity", "attendance", "notifications", "operations", "projects", "tasks"}
		if got := body.keys(); !slices.Equal(got, want) {
			t.Errorf("saha bölümleri\n got  %v\n want %v", got, want)
		}
		for _, k := range []string{"finance", "change_orders", "offers", "procurement", "users"} {
			if _, ok := body.Sections[k]; ok {
				t.Errorf("saha rolü %q bölümünü görmemeli", k)
			}
		}
		if body.Viewer.AllProjects || body.Viewer.AccessibleProjectCount != 1 {
			t.Errorf("viewer: %+v", body.Viewer)
		}
		var projects domain.DashProjects
		body.section(t, "projects", &projects)
		if projects.Counts.Total != 1 {
			t.Errorf("projects.counts.total = %d, beklenen 1 (yalnızca üye olduğu proje)", projects.Counts.Total)
		}
		for _, row := range projects.Top {
			if row.CollectionPct != nil || row.CurrentValue != nil {
				t.Errorf("proje satırında para: %+v", row)
			}
			if row.Ref.ID != p1.ID {
				t.Errorf("üye olmadığı proje satırı sızdı: %s", row.Ref.ID)
			}
		}
		var tasks domain.DashTasks
		body.section(t, "tasks", &tasks)
		if tasks.Team.Open != 1 || tasks.Team.Overdue != 1 || tasks.Team.Unassigned != 0 {
			t.Errorf("ekip görevleri yalnızca üye projeyi saymalı: %+v", tasks.Team)
		}
		if !tasks.Mine.LinkedEmployee || tasks.Mine.Open != 1 || tasks.Mine.Overdue != 1 {
			t.Errorf("benim görevlerim: %+v", tasks.Mine)
		}
		for _, g := range body.Agenda.Groups {
			if !slices.Contains(want, g.Module) {
				t.Errorf("görünmeyen modülden dikkat kaydı: %s (%s)", g.Code, g.Module)
			}
			if g.Code == domain.AttnTeamTaskOverdue || g.Code == domain.AttnTeamTaskUnassigned {
				t.Errorf("tasks.create olmadan %s gelmemeli", g.Code)
			}
		}
		if lane, count, ok := body.group(domain.AttnMyTaskOverdue); !ok || lane != domain.LaneMine || count != 1 {
			t.Errorf("my_task_overdue: %q %d %v", lane, count, ok)
		}
		assertNoMoneyJSON(t, "field", generic)
	})

	t.Run("5_project_manager", func(t *testing.T) {
		body, _ := getDashboard(t, d, pmToken)
		for _, k := range []string{"finance", "change_orders", "offers", "attendance", "employees"} {
			if _, ok := body.Sections[k]; ok {
				t.Errorf("proje yöneticisi %q bölümünü görmemeli", k)
			}
		}
		lane, count, ok := body.group(domain.AttnPurchaseRequestApproval)
		if !ok || lane != domain.LaneWatching || count != 1 {
			t.Errorf("onay yetkisi olmayan PM talebi 'takipte' görmeli: %q %d %v", lane, count, ok)
		}
		if _, _, ok := body.group(domain.AttnPlanItemOverdue); ok {
			t.Error("finans izni olmayan PM ödeme planı kaydı görmemeli")
		}
	})

	t.Run("6_finance", func(t *testing.T) {
		body, _ := getDashboard(t, d, finToken)
		if _, ok := body.Sections["tasks"]; ok {
			t.Error("finans rolü tasks bölümünü görmemeli")
		}
		if len(body.SectionErrors) != 0 {
			t.Errorf("finans için bölüm hatası olmamalı (/tasks/mine 403 hatası tekrarlanmasın): %v", body.SectionErrors)
		}
		if lane, _, ok := body.group(domain.AttnPurchaseRequestApproval); !ok || lane != domain.LaneMine {
			t.Errorf("onay yetkili finans talebi kendi şeridinde görmeli: %q %v", lane, ok)
		}
		if lane, _, ok := body.group(domain.AttnPlanItemOverdue); !ok || lane != domain.LaneMine {
			t.Errorf("plan_item_overdue: %q %v", lane, ok)
		}
		for _, k := range []string{"finance", "change_orders", "procurement", "subcontracts", "cost_control", "contracts"} {
			if _, ok := body.Sections[k]; !ok {
				t.Errorf("finans rolü %q bölümünü görmeli", k)
			}
		}
	})

	t.Run("7_personal_overrides_change_sections", func(t *testing.T) {
		detail, err := d.authzSvc.GetUserPermissionDetail(ctx, field2.ID, a)
		if err != nil {
			t.Fatal(err)
		}
		before, _ := getDashboard(t, d, field2Token)
		if _, ok := before.Sections["offers"]; ok {
			t.Fatal("ekleme öncesi offers görünmemeli")
		}
		if _, err := d.authzSvc.SetUserPermissions(ctx, field2.ID, a, orgA.Owner.ID,
			append(append([]string{}, detail.RolePermissions...), domain.PermOffersRead)); err != nil {
			t.Fatalf("offers.read eklenemedi: %v", err)
		}
		after, _ := getDashboard(t, d, field2Token)
		if _, ok := after.Sections["offers"]; !ok {
			t.Error("kişiye özel offers.read sonrası offers bölümü gelmeli")
		}

		finDetail, err := d.authzSvc.GetUserPermissionDetail(ctx, fin2.ID, a)
		if err != nil {
			t.Fatal(err)
		}
		finBefore, _ := getDashboard(t, d, fin2Token)
		if _, _, ok := finBefore.group(domain.AttnPlanItemOverdue); !ok {
			t.Fatal("geri alma öncesi plan_item_overdue görünmeli")
		}
		var kept []string
		for _, c := range finDetail.RolePermissions {
			if c != domain.PermProjectsFinanceRead && c != domain.PermProjectsFinanceManage {
				kept = append(kept, c)
			}
		}
		if _, err := d.authzSvc.SetUserPermissions(ctx, fin2.ID, a, orgA.Owner.ID, kept); err != nil {
			t.Fatalf("finance.read geri alınamadı: %v", err)
		}
		finAfter, _ := getDashboard(t, d, fin2Token)
		for _, k := range []string{"finance", "change_orders"} {
			if _, ok := finAfter.Sections[k]; ok {
				t.Errorf("finance.read geri alındıktan sonra %q görünmemeli", k)
			}
		}
		if _, _, ok := finAfter.group(domain.AttnPlanItemOverdue); ok {
			t.Error("finance.read geri alındıktan sonra plan_item_overdue görünmemeli")
		}
		var projects domain.DashProjects
		finAfter.section(t, "projects", &projects)
		for _, row := range projects.Top {
			if row.CurrentValue != nil || row.CollectionPct != nil || slices.Contains(row.Flags, domain.ProjectFlagOverduePlan) {
				t.Errorf("finance.read yokken proje satırında finans verisi: %+v", row)
			}
		}
	})

	t.Run("8_cross_tenant_counts", func(t *testing.T) {
		body, _ := getDashboard(t, d, ownerToken)
		var projects domain.DashProjects
		body.section(t, "projects", &projects)
		if projects.Counts.Total != 2 {
			t.Errorf("A proje sayısı = %d, beklenen 2 (B'nin projesi sızmamalı)", projects.Counts.Total)
		}
		var offers domain.DashOffers
		body.section(t, "offers", &offers)
		if offers.TotalActive != 2 {
			t.Errorf("A teklif sayısı = %d, beklenen 2", offers.TotalActive)
		}
		var users domain.DashUsers
		body.section(t, "users", &users)
		// owner + 6 aktif rol kullanıcısı (silinen sayılmaz, B'ninkiler sayılmaz).
		if users.Active != 7 {
			t.Errorf("A aktif kullanıcı = %d, beklenen 7", users.Active)
		}
		bBody, _ := getDashboard(t, d, ownerBToken)
		var bProjects domain.DashProjects
		bBody.section(t, "projects", &bProjects)
		if bProjects.Counts.Total != 1 {
			t.Errorf("B proje sayısı = %d, beklenen 1", bProjects.Counts.Total)
		}
	})

	t.Run("9_section_errors_only_for_permitted_sections", func(t *testing.T) {
		d.dashboardSvc.FailSection(domain.DashSectionProcurement)
		defer d.dashboardSvc.FailSection()
		body, _ := getDashboard(t, d, ownerToken)
		if len(body.SectionErrors) != 1 || body.SectionErrors[domain.DashSectionProcurement] != domain.DashSectionFailed {
			t.Errorf("section_errors = %v, beklenen yalnızca procurement", body.SectionErrors)
		}
		if _, ok := body.Sections["procurement"]; ok {
			t.Error("hata veren bölüm sections'ta olmamalı")
		}
		if len(body.Sections) != 19 {
			t.Errorf("kalan 19 bölüm sağlam olmalı, %d geldi: %v", len(body.Sections), body.keys())
		}
		if _, _, ok := body.group(domain.AttnPurchaseRequestApproval); ok {
			t.Error("hata veren bölümün dikkat kaydı gündeme girmemeli")
		}
		fieldBody, _ := getDashboard(t, d, fieldToken)
		if len(fieldBody.SectionErrors) != 0 {
			t.Errorf("izni olmayan bölümün hatası sahaya raporlanmamalı: %v", fieldBody.SectionErrors)
		}
	})

	t.Run("10_users_section_admin_only_and_excludes_deleted", func(t *testing.T) {
		body, _ := getDashboard(t, d, ownerToken)
		var users domain.DashUsers
		body.section(t, "users", &users)
		if users.Active != 7 || users.Inactive != 0 {
			t.Errorf("silinmiş kullanıcı sayılmamalı: aktif %d, pasif %d", users.Active, users.Inactive)
		}
		authz, err := d.authzSvc.LoadAuthzContext(ctx, grantee.ID, a)
		if err != nil || !authz.HasPermission(domain.PermOrganizationUsersRead) {
			t.Fatalf("test ön koşulu: kişiye özel organization.users.read etkin olmalı (%v)", err)
		}
		gBody, _ := getDashboard(t, d, granteeToken)
		if _, ok := gBody.Sections["users"]; ok {
			t.Error("kaba admin olmayan kullanıcı, izin eklenmiş olsa da users bölümünü görmemeli")
		}
	})

	t.Run("11_activity_filters_finance_events_for_field", func(t *testing.T) {
		_, generic := getDashboard(t, d, fieldToken)
		items := generic["sections"].(map[string]any)["activity"].(map[string]any)["items"].([]any)
		sawTask := false
		for _, it := range items {
			m := it.(map[string]any)
			if m["event_type"] == domain.ProjectEventCollectionReceived {
				t.Error("saha rolü collection_received görmemeli")
			}
			ref := m["ref"].(map[string]any)
			if ref["project_id"] == p2.ID {
				t.Error("üye olmadığı projenin olayı sızdı")
			}
			if m["event_type"] == domain.ProjectEventTaskCreated {
				sawTask = true
			}
			if _, ok := m["metadata"]; ok {
				t.Error("akış metadata taşımamalı")
			}
		}
		if !sawTask {
			t.Error("üye olduğu projenin görev olayı görünmeli")
		}
		_, ownerGeneric := getDashboard(t, d, ownerToken)
		ownerItems := ownerGeneric["sections"].(map[string]any)["activity"].(map[string]any)["items"].([]any)
		sawCollection := false
		for _, it := range ownerItems {
			if it.(map[string]any)["event_type"] == domain.ProjectEventCollectionReceived {
				sawCollection = true
			}
		}
		if !sawCollection {
			t.Error("Sahip tahsilat olayını görmeli")
		}
	})

	t.Run("12_project_options_member_scoped_no_money", func(t *testing.T) {
		rec, _ := rbacDo(t, d.router, http.MethodGet, "/api/v1/dashboard/project-options", fieldToken, "")
		if rec.Code != http.StatusOK {
			t.Fatalf("status = %d", rec.Code)
		}
		var resp struct {
			Projects []map[string]any `json:"projects"`
		}
		if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
			t.Fatal(err)
		}
		if len(resp.Projects) != 1 || resp.Projects[0]["id"] != p1.ID {
			t.Fatalf("saha yalnızca üye projesini görmeli: %v", resp.Projects)
		}
		wantKeys := []string{"currency", "customer_name", "id", "name", "project_no", "status"}
		var got []string
		for k := range resp.Projects[0] {
			got = append(got, k)
		}
		sort.Strings(got)
		if !slices.Equal(got, wantKeys) {
			t.Errorf("proje seçici alanları = %v, beklenen %v (para alanı YOK)", got, wantKeys)
		}
		rec, _ = rbacDo(t, d.router, http.MethodGet, "/api/v1/dashboard/project-options", ownerToken, "")
		_ = json.Unmarshal(rec.Body.Bytes(), &resp)
		if len(resp.Projects) != 2 {
			t.Errorf("Sahip iki açık projeyi görmeli: %d", len(resp.Projects))
		}
	})
}
