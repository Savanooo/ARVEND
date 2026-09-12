package service

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

type EmployeeService struct {
	q *sqlc.Queries
}

func NewEmployeeService(q *sqlc.Queries) *EmployeeService {
	return &EmployeeService{q: q}
}

type EmployeeInput struct {
	FullName    string
	Phone       string
	Position    string
	Salary      *float64
	DailyWage   *float64
	StartDate   *time.Time
	Description string
	IsActive    bool
}

func (s *EmployeeService) List(ctx context.Context, organizationID string, activeOnly *bool) ([]domain.Employee, error) {
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	rows, err := s.q.ListEmployees(ctx, sqlc.ListEmployeesParams{OrganizationID: orgID, IsActive: activeOnly})
	if err != nil {
		return nil, err
	}
	out := make([]domain.Employee, len(rows))
	for i, r := range rows {
		out[i] = repository.ToDomainEmployee(r)
	}
	return out, nil
}

func (s *EmployeeService) Get(ctx context.Context, id, organizationID string) (*domain.Employee, error) {
	uid, err := repository.StringToUUID(id)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	row, err := s.q.GetEmployeeByID(ctx, sqlc.GetEmployeeByIDParams{ID: uid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	e := repository.ToDomainEmployee(row)
	return &e, nil
}

func (s *EmployeeService) Create(ctx context.Context, organizationID string, in EmployeeInput) (*domain.Employee, error) {
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	in.FullName = strings.TrimSpace(in.FullName)
	if in.FullName == "" {
		return nil, errors.New("ad soyad zorunludur")
	}
	row, err := s.q.CreateEmployee(ctx, sqlc.CreateEmployeeParams{
		OrganizationID: orgID,
		FullName:       in.FullName,
		Phone:          strings.TrimSpace(in.Phone),
		Position:       strings.TrimSpace(in.Position),
		Salary:         repository.FloatPtrToNumeric(in.Salary),
		DailyWage:      repository.FloatPtrToNumeric(in.DailyWage),
		StartDate:      repository.TimePtrToDate(in.StartDate),
		Description:    strings.TrimSpace(in.Description),
	})
	if err != nil {
		return nil, err
	}
	e := repository.ToDomainEmployee(row)
	return &e, nil
}

func (s *EmployeeService) Update(ctx context.Context, id, organizationID string, in EmployeeInput) (*domain.Employee, error) {
	uid, err := repository.StringToUUID(id)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	in.FullName = strings.TrimSpace(in.FullName)
	if in.FullName == "" {
		return nil, errors.New("ad soyad zorunludur")
	}
	row, err := s.q.UpdateEmployee(ctx, sqlc.UpdateEmployeeParams{
		ID:             uid,
		OrganizationID: orgID,
		FullName:       in.FullName,
		Phone:          strings.TrimSpace(in.Phone),
		Position:       strings.TrimSpace(in.Position),
		Salary:         repository.FloatPtrToNumeric(in.Salary),
		DailyWage:      repository.FloatPtrToNumeric(in.DailyWage),
		StartDate:      repository.TimePtrToDate(in.StartDate),
		Description:    strings.TrimSpace(in.Description),
		IsActive:       in.IsActive,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	e := repository.ToDomainEmployee(row)
	return &e, nil
}

// Archive, BYZ'deki kuralı korur: personel hard-delete edilmez (mesai/
// atama geçmişi referans verir), yalnızca pasifleştirilir.
func (s *EmployeeService) Archive(ctx context.Context, id, organizationID string) error {
	uid, err := repository.StringToUUID(id)
	if err != nil {
		return domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return domain.ErrNotFound
	}
	return s.q.ArchiveEmployee(ctx, sqlc.ArchiveEmployeeParams{ID: uid, OrganizationID: orgID})
}
