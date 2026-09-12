package service

import (
	"context"
	"errors"
	"strings"

	"github.com/jackc/pgx/v5"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

type CustomerService struct {
	q *sqlc.Queries
}

func NewCustomerService(q *sqlc.Queries) *CustomerService {
	return &CustomerService{q: q}
}

type CustomerInput struct {
	Name      string
	Phone     string
	Email     string
	Address   string
	TaxOffice string
	TaxNumber string
	Notes     string
	IsActive  bool
}

func (s *CustomerService) List(ctx context.Context, organizationID, search string, activeOnly *bool) ([]domain.Customer, error) {
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	rows, err := s.q.ListCustomers(ctx, sqlc.ListCustomersParams{
		OrganizationID: orgID,
		Column2:        strings.TrimSpace(search),
		IsActive:       activeOnly,
	})
	if err != nil {
		return nil, err
	}
	out := make([]domain.Customer, len(rows))
	for i, r := range rows {
		out[i] = repository.ToDomainCustomer(r)
	}
	return out, nil
}

func (s *CustomerService) Get(ctx context.Context, id, organizationID string) (*domain.Customer, error) {
	uid, err := repository.StringToUUID(id)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	row, err := s.q.GetCustomerByID(ctx, sqlc.GetCustomerByIDParams{ID: uid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	c := repository.ToDomainCustomer(row)
	return &c, nil
}

func (s *CustomerService) Create(ctx context.Context, organizationID string, in CustomerInput) (*domain.Customer, error) {
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	in.Name = strings.TrimSpace(in.Name)
	if in.Name == "" {
		return nil, errors.New("müşteri adı zorunludur")
	}
	row, err := s.q.CreateCustomer(ctx, sqlc.CreateCustomerParams{
		OrganizationID: orgID,
		Name:           in.Name,
		Phone:          strings.TrimSpace(in.Phone),
		Email:          strings.TrimSpace(in.Email),
		Address:        strings.TrimSpace(in.Address),
		TaxOffice:      strings.TrimSpace(in.TaxOffice),
		TaxNumber:      strings.TrimSpace(in.TaxNumber),
		Notes:          strings.TrimSpace(in.Notes),
	})
	if err != nil {
		return nil, err
	}
	c := repository.ToDomainCustomer(row)
	return &c, nil
}

func (s *CustomerService) Update(ctx context.Context, id, organizationID string, in CustomerInput) (*domain.Customer, error) {
	uid, err := repository.StringToUUID(id)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	in.Name = strings.TrimSpace(in.Name)
	if in.Name == "" {
		return nil, errors.New("müşteri adı zorunludur")
	}
	row, err := s.q.UpdateCustomer(ctx, sqlc.UpdateCustomerParams{
		ID:             uid,
		OrganizationID: orgID,
		Name:           in.Name,
		Phone:          strings.TrimSpace(in.Phone),
		Email:          strings.TrimSpace(in.Email),
		Address:        strings.TrimSpace(in.Address),
		TaxOffice:      strings.TrimSpace(in.TaxOffice),
		TaxNumber:      strings.TrimSpace(in.TaxNumber),
		Notes:          strings.TrimSpace(in.Notes),
		IsActive:       in.IsActive,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	c := repository.ToDomainCustomer(row)
	return &c, nil
}

// Archive, diğer modüllerdeki desenle tutarlı: müşteri hard-delete
// edilmez (geçmiş tekliflerin customer_id'si referans verebilir),
// yalnızca pasifleştirilir.
func (s *CustomerService) Archive(ctx context.Context, id, organizationID string) error {
	uid, err := repository.StringToUUID(id)
	if err != nil {
		return domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return domain.ErrNotFound
	}
	rows, err := s.q.ArchiveCustomer(ctx, sqlc.ArchiveCustomerParams{ID: uid, OrganizationID: orgID})
	if err != nil {
		return err
	}
	if rows == 0 {
		return domain.ErrNotFound
	}
	return nil
}
