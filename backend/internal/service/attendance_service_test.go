package service_test

import (
	"context"
	"errors"
	"testing"

	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

// TestAttendanceRejectsFutureDates: ileri bir güne girilen "geldi" maaş
// tablosunda çalışılmış gün sayılıyordu. Bugün (İstanbul) ve geçmiş kabul,
// yarın ve sonrası red -- toplu giriş de her gün için aynı Create'ten geçer.
func TestAttendanceRejectsFutureDates(t *testing.T) {
	dbURL := testDBURL(t)
	ctx := context.Background()
	pool, err := repository.NewPool(ctx, dbURL)
	if err != nil {
		t.Fatalf("db: %v", err)
	}
	t.Cleanup(func() { pool.Close() })
	q := sqlc.New(pool)
	orgSvc := service.NewOrganizationService(q)
	svc := service.NewAttendanceService(q)
	org := mustCreateOrg(t, ctx, orgSvc, pool, "Mesai Tarih Test", "mesai-tarih-test")
	emp := mustCreateEmployee(t, ctx, pool, org.ID, "Tarih Usta", true)

	today := service.IstanbulToday()
	for _, c := range []struct {
		name    string
		daysAdd int
		wantErr error
	}{
		{"dün", -1, nil},
		{"bugün", 0, nil},
		{"yarın", 1, service.ErrAttendanceFutureDate},
		{"gelecek ay", 35, service.ErrAttendanceFutureDate},
	} {
		_, err := svc.Create(ctx, org.ID, service.AttendanceInput{
			EmployeeID: emp, Date: today.AddDate(0, 0, c.daysAdd), Status: "geldi", WorkHours: 9,
		})
		if !errors.Is(err, c.wantErr) {
			t.Errorf("%s: %v beklendi, %v geldi", c.name, c.wantErr, err)
		}
	}
}
