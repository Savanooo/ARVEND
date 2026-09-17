package service_test

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

	pA1 := newProject(t, orgA.ID, "Proje A1")
	pA2 := newProject(t, orgA.ID, "Proje A2")
	pB1 := newProject(t, orgB.ID, "Proje B1")

	if _, err := projectSvc.CreateTask(ctx, pA1.ID, orgA.ID, service.TaskInput{Title: "A1 open"}); err != nil {
		t.Fatalf("task a1: %v", err)
	}
	done, err := projectSvc.CreateTask(ctx, pA1.ID, orgA.ID, service.TaskInput{Title: "A1 done"})
	if err != nil {
		t.Fatalf("task done: %v", err)
	}
	if _, err := projectSvc.CompleteTask(ctx, pA1.ID, done.ID, orgA.ID, ""); err != nil {
		t.Fatalf("complete: %v", err)
	}
	if _, err := projectSvc.CreateTask(ctx, pA2.ID, orgA.ID, service.TaskInput{Title: "A2 open"}); err != nil {
		t.Fatalf("task a2: %v", err)
	}
	if _, err := projectSvc.CreateTask(ctx, pB1.ID, orgB.ID, service.TaskInput{Title: "B1 open"}); err != nil {
		t.Fatalf("task b1: %v", err)
	}

	t.Run("open_across_org_projects", func(t *testing.T) {
		rows, err := projectSvc.ListMyTasks(ctx, orgA.ID, "open", "")
		if err != nil {
			t.Fatalf("list: %v", err)
		}
		titles := map[string]bool{}
		for _, r := range rows {
			titles[r.Title] = true
			if r.ProjectName == "" {
				t.Errorf("empty project name for %s", r.Title)
			}
			if r.Status != domain.TaskStatusTodo && r.Status != domain.TaskStatusInProgress {
				t.Errorf("bad status %s", r.Status)
			}
		}
		if !titles["A1 open"] || !titles["A2 open"] {
			t.Fatalf("missing open tasks: %+v", titles)
		}
		if titles["A1 done"] {
			t.Fatalf("completed included in open")
		}
		if titles["B1 open"] {
			t.Fatalf("other org leaked")
		}
	})

	t.Run("other_org_isolation", func(t *testing.T) {
		rows, err := projectSvc.ListMyTasks(ctx, orgB.ID, "open", "")
		if err != nil {
			t.Fatalf("list: %v", err)
		}
		for _, r := range rows {
			if r.Title == "A1 open" || r.Title == "A2 open" {
				t.Fatalf("org A leaked into B")
			}
		}
	})

	t.Run("status_all_includes_completed", func(t *testing.T) {
		rows, err := projectSvc.ListMyTasks(ctx, orgA.ID, "all", "")
		if err != nil {
			t.Fatalf("list: %v", err)
		}
		found := false
		for _, r := range rows {
			if r.Title == "A1 done" {
				found = true
			}
		}
		if !found {
			t.Fatal("expected completed with status=all")
		}
	})

	t.Run("restrict_without_membership_empty", func(t *testing.T) {
		// Random UUID with no project_users rows => empty under restrict.
		rows, err := projectSvc.ListMyTasks(ctx, orgA.ID, "open", "00000000-0000-4000-8000-000000000099")
		if err != nil {
			t.Fatalf("list: %v", err)
		}
		if len(rows) != 0 {
			t.Fatalf("expected empty, got %d", len(rows))
		}
	})
}
