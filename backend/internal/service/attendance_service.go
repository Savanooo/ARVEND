package service

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

var ErrAttendanceExists = errors.New("bu personel için bu tarihte zaten mesai kaydı var")

// ErrAttendanceFutureDate: henüz gelmemiş bir güne "geldi" yazılırsa maaş
// tablosu o günü çalışılmış sayar ve yevmiyeli personele ödenmemiş bir
// iş için hakediş çıkar.
var ErrAttendanceFutureDate = errors.New("ileri bir tarihe mesai girilemez")

type AttendanceService struct {
	q   *sqlc.Queries
	now func() time.Time
}

func NewAttendanceService(q *sqlc.Queries) *AttendanceService {
	return &AttendanceService{q: q, now: time.Now}
}

type AttendanceInput struct {
	EmployeeID string
	Date       time.Time
	CheckIn    string
	CheckOut   string
	WorkHours  float64
	Status     string
	Note       string
}

func (s *AttendanceService) ListByMonth(ctx context.Context, organizationID string, month time.Time) ([]domain.AttendanceLog, error) {
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	rows, err := s.q.ListAttendanceByMonth(ctx, sqlc.ListAttendanceByMonthParams{
		OrganizationID: orgID,
		Column2:        repository.TimeToDate(month),
	})
	if err != nil {
		return nil, err
	}
	out := make([]domain.AttendanceLog, len(rows))
	for i, r := range rows {
		out[i] = repository.ToDomainAttendanceRow(r)
	}
	return out, nil
}

func (s *AttendanceService) Get(ctx context.Context, id, organizationID string) (*domain.AttendanceLog, error) {
	uid, err := repository.StringToUUID(id)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	row, err := s.q.GetAttendanceByID(ctx, sqlc.GetAttendanceByIDParams{ID: uid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	a := repository.ToDomainAttendance(row)
	return &a, nil
}

func (s *AttendanceService) Create(ctx context.Context, organizationID string, in AttendanceInput) (*domain.AttendanceLog, error) {
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	if !domain.ValidAttendanceStatus(in.Status) {
		return nil, errors.New("geçersiz mesai durumu")
	}
	// "Bugün" İstanbul takvimiyle (sunucu UTC'de; 00:00-03:00 arası girilen
	// bugünkü kayıt aksi hâlde "ileri tarih" sayılırdı). Mobildeki toplu
	// giriş her gün için ayrı Create çağırır -- kural ona da uygulanır.
	day := time.Date(in.Date.Year(), in.Date.Month(), in.Date.Day(), 0, 0, 0, 0, time.UTC)
	if day.After(istanbulToday(s.now())) {
		return nil, ErrAttendanceFutureDate
	}
	empID, err := repository.StringToUUID(in.EmployeeID)
	if err != nil {
		return nil, errors.New("geçersiz personel")
	}
	// Personelin gerçekten bu organizasyona ait olduğu doğrulanmadan mesai
	// kaydı oluşturulursa, başka bir firmanın employee_id'sine referans
	// veren bir kayıt açılabilir -- bu hem tenant izolasyonu ihlali hem de
	// ListAttendanceByMonth'taki JOIN üzerinden o firmanın personel adının
	// sızmasına yol açar.
	if _, err := s.q.GetEmployeeByID(ctx, sqlc.GetEmployeeByIDParams{ID: empID, OrganizationID: orgID}); err != nil {
		return nil, errors.New("geçersiz personel")
	}
	row, err := s.q.CreateAttendance(ctx, sqlc.CreateAttendanceParams{
		OrganizationID: orgID,
		EmployeeID:     empID,
		Date:           repository.TimeToDate(in.Date),
		CheckIn:        strings.TrimSpace(in.CheckIn),
		CheckOut:       strings.TrimSpace(in.CheckOut),
		WorkHours:      repository.Float64ToNumeric(in.WorkHours),
		Status:         in.Status,
		Note:           strings.TrimSpace(in.Note),
	})
	if err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" {
			return nil, ErrAttendanceExists
		}
		return nil, err
	}
	a := repository.ToDomainAttendance(row)
	return &a, nil
}

func (s *AttendanceService) Update(ctx context.Context, id, organizationID string, in AttendanceInput) (*domain.AttendanceLog, error) {
	if !domain.ValidAttendanceStatus(in.Status) {
		return nil, errors.New("geçersiz mesai durumu")
	}
	uid, err := repository.StringToUUID(id)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	row, err := s.q.UpdateAttendance(ctx, sqlc.UpdateAttendanceParams{
		ID:             uid,
		OrganizationID: orgID,
		CheckIn:        strings.TrimSpace(in.CheckIn),
		CheckOut:       strings.TrimSpace(in.CheckOut),
		WorkHours:      repository.Float64ToNumeric(in.WorkHours),
		Status:         in.Status,
		Note:           strings.TrimSpace(in.Note),
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	a := repository.ToDomainAttendance(row)
	return &a, nil
}

func (s *AttendanceService) Delete(ctx context.Context, id, organizationID string) error {
	uid, err := repository.StringToUUID(id)
	if err != nil {
		return domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return domain.ErrNotFound
	}
	rows, err := s.q.DeleteAttendance(ctx, sqlc.DeleteAttendanceParams{ID: uid, OrganizationID: orgID})
	if err != nil {
		return err
	}
	if rows == 0 {
		return domain.ErrNotFound
	}
	return nil
}
