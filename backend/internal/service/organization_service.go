package service

import (
	"context"
	"errors"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

type OrganizationService struct {
	q *sqlc.Queries
}

func NewOrganizationService(q *sqlc.Queries) *OrganizationService {
	return &OrganizationService{q: q}
}

func (s *OrganizationService) Create(ctx context.Context, name, slug string) (*domain.Organization, error) {
	name = strings.TrimSpace(name)
	slug = strings.TrimSpace(slug)
	if name == "" || slug == "" {
		return nil, errors.New("firma adı ve slug zorunludur")
	}
	row, err := s.q.CreateOrganization(ctx, sqlc.CreateOrganizationParams{Name: name, Slug: slug})
	if err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" {
			return nil, errors.New("bu slug zaten kullanılıyor")
		}
		return nil, err
	}
	o := repository.ToDomainOrganization(row)
	return &o, nil
}

func (s *OrganizationService) Get(ctx context.Context, id string) (*domain.Organization, error) {
	uid, err := repository.StringToUUID(id)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	row, err := s.q.GetOrganizationByID(ctx, uid)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	o := repository.ToDomainOrganization(row)
	return &o, nil
}

func (s *OrganizationService) List(ctx context.Context) ([]domain.Organization, error) {
	rows, err := s.q.ListOrganizations(ctx)
	if err != nil {
		return nil, err
	}
	out := make([]domain.Organization, len(rows))
	for i, r := range rows {
		out[i] = repository.ToDomainOrganization(r)
	}
	return out, nil
}
