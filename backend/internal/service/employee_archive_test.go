package service_test

import (
	"context"
	"testing"

	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

// TestEmployeeArchivedFollowsActive: archived_at (ana sayfa buna bakar)
// is_active ile birlikte değişir -- "Pasifleştir"den sonra formdan yeniden
// aktif yapılan personel arşivli kalmamalı, formdan pasife alınan da
// arşivlenmeli.
func TestEmployeeArchivedFollowsActive(t *testing.T) {
	dbURL := testDBURL(t)
	ctx := context.Background()
	pool, err := repository.NewPool(ctx, dbURL)
	if err != nil {
		t.Fatalf("db: %v", err)
	}
	t.Cleanup(func() { pool.Close() })
	q := sqlc.New(pool)
	orgSvc := service.NewOrganizationService(q)
	svc := service.NewEmployeeService(pool, q)
	org := mustCreateOrg(t, ctx, orgSvc, pool, "Arşiv Test", "arsiv-test")

	archived := func(id string) bool {
		t.Helper()
		var ok bool
		if err := pool.QueryRow(ctx, `SELECT archived_at IS NOT NULL FROM employees WHERE id = $1`, id).Scan(&ok); err != nil {
			t.Fatal(err)
		}
		return ok
	}

	e, err := svc.Create(ctx, org.ID, service.EmployeeInput{FullName: "Dönen Usta", IsActive: true})
	if err != nil {
		t.Fatal(err)
	}
	if err := svc.Archive(ctx, e.ID, org.ID); err != nil {
		t.Fatal(err)
	}
	if !archived(e.ID) {
		t.Fatal("Pasifleştir arşivlemeli")
	}
	if _, err := svc.Update(ctx, e.ID, org.ID, service.EmployeeInput{FullName: "Dönen Usta", IsActive: true}); err != nil {
		t.Fatal(err)
	}
	if archived(e.ID) {
		t.Error("yeniden aktif yapılan personelin arşivi kalkmalı")
	}
	if _, err := svc.Update(ctx, e.ID, org.ID, service.EmployeeInput{FullName: "Dönen Usta", IsActive: false}); err != nil {
		t.Fatal(err)
	}
	if !archived(e.ID) {
		t.Error("formdan pasife alınan personel arşivlenmeli")
	}
}
