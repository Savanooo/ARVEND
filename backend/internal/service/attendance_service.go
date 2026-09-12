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

type AttendanceService struct {
	q *sqlc.Queries
}

func NewAttendanceService(q *sqlc.Queries) *AttendanceService {
	return &AttendanceService{q: q}
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

func (s *AttendanceService) ListByMonth(ctx context.Context, month time.Time) ([]domain.AttendanceLog, error) {
	rows, err := s.q.ListAttendanceByMonth(ctx, repository.TimeToDate(month))
	if err != nil {
		return nil, err
	}
	out := make([]domain.AttendanceLog, len(rows))
	for i, r := range rows {
		out[i] = repository.ToDomainAttendanceRow(r)
	}
	return out, nil
}

func (s *AttendanceService) Get(ctx context.Context, id string) (*domain.AttendanceLog, error) {
	uid, err := repository.StringToUUID(id)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	row, err := s.q.GetAttendanceByID(ctx, uid)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	a := repository.ToDomainAttendance(row)
	return &a, nil
}

func (s *AttendanceService) Create(ctx context.Context, in AttendanceInput) (*domain.AttendanceLog, error) {
	if !domain.ValidAttendanceStatus(in.Status) {
		return nil, errors.New("geçersiz mesai durumu")
	}
	empID, err := repository.StringToUUID(in.EmployeeID)
	if err != nil {
		return nil, errors.New("geçersiz personel")
	}
	row, err := s.q.CreateAttendance(ctx, sqlc.CreateAttendanceParams{
		EmployeeID: empID,
		Date:       repository.TimeToDate(in.Date),
		CheckIn:    strings.TrimSpace(in.CheckIn),
		CheckOut:   strings.TrimSpace(in.CheckOut),
		WorkHours:  repository.Float64ToNumeric(in.WorkHours),
		Status:     in.Status,
		Note:       strings.TrimSpace(in.Note),
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

func (s *AttendanceService) Update(ctx context.Context, id string, in AttendanceInput) (*domain.AttendanceLog, error) {
	if !domain.ValidAttendanceStatus(in.Status) {
		return nil, errors.New("geçersiz mesai durumu")
	}
	uid, err := repository.StringToUUID(id)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	row, err := s.q.UpdateAttendance(ctx, sqlc.UpdateAttendanceParams{
		ID:        uid,
		CheckIn:   strings.TrimSpace(in.CheckIn),
		CheckOut:  strings.TrimSpace(in.CheckOut),
		WorkHours: repository.Float64ToNumeric(in.WorkHours),
		Status:    in.Status,
		Note:      strings.TrimSpace(in.Note),
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

func (s *AttendanceService) Delete(ctx context.Context, id string) error {
	uid, err := repository.StringToUUID(id)
	if err != nil {
		return domain.ErrNotFound
	}
	return s.q.DeleteAttendance(ctx, uid)
}
