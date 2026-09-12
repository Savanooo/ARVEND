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

type ProductService struct {
	q *sqlc.Queries
}

func NewProductService(q *sqlc.Queries) *ProductService {
	return &ProductService{q: q}
}

type ProductListResult struct {
	Products []domain.Product
	Total    int64
}

func (s *ProductService) List(ctx context.Context, search string, page, limit int) (*ProductListResult, error) {
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	if page <= 0 {
		page = 1
	}
	norm := domain.NormalizeName(search)
	rows, err := s.q.ListProducts(ctx, sqlc.ListProductsParams{
		Limit:   int32(limit),
		Offset:  int32((page - 1) * limit),
		Column3: norm,
	})
	if err != nil {
		return nil, err
	}
	total, err := s.q.CountProducts(ctx, norm)
	if err != nil {
		return nil, err
	}
	products := make([]domain.Product, len(rows))
	for i, r := range rows {
		products[i] = repository.ToDomainProduct(r)
	}
	return &ProductListResult{Products: products, Total: total}, nil
}

func (s *ProductService) Get(ctx context.Context, id string) (*domain.Product, error) {
	uid, err := repository.StringToUUID(id)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	row, err := s.q.GetProductByID(ctx, uid)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	p := repository.ToDomainProduct(row)
	return &p, nil
}

func (s *ProductService) Create(ctx context.Context, name, unit string, unitPrice float64, description, category string) (*domain.Product, error) {
	name = strings.TrimSpace(name)
	if name == "" {
		return nil, errors.New("ürün adı zorunludur")
	}
	if unit = strings.TrimSpace(unit); unit == "" {
		unit = "adet"
	}
	row, err := s.q.CreateProduct(ctx, sqlc.CreateProductParams{
		Name:           name,
		NormalizedName: domain.NormalizeName(name),
		Unit:           unit,
		UnitPrice:      repository.Float64ToNumeric(unitPrice),
		Description:    strings.TrimSpace(description),
		Category:       strings.TrimSpace(category),
	})
	if err != nil {
		return nil, err
	}
	p := repository.ToDomainProduct(row)
	return &p, nil
}

// Update, ürünü günceller. Fiyat değişirse product_price_history'e otomatik
// bir kayıt düşer -- BYZ'deki embedded (son 50 ile sınırlı) listenin
// yerine, sınırsız ve ayrı sorgulanabilir bir tabloda.
func (s *ProductService) Update(ctx context.Context, id, name, unit string, unitPrice float64, description, category string) (*domain.Product, error) {
	uid, err := repository.StringToUUID(id)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	existing, err := s.q.GetProductByID(ctx, uid)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}

	name = strings.TrimSpace(name)
	if name == "" {
		return nil, errors.New("ürün adı zorunludur")
	}

	row, err := s.q.UpdateProduct(ctx, sqlc.UpdateProductParams{
		ID:             uid,
		Name:           name,
		NormalizedName: domain.NormalizeName(name),
		Unit:           unit,
		UnitPrice:      repository.Float64ToNumeric(unitPrice),
		Description:    strings.TrimSpace(description),
		Category:       strings.TrimSpace(category),
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}

	oldPrice := repository.NumericToFloat64(existing.UnitPrice)
	if oldPrice != unitPrice {
		_ = s.q.CreatePriceHistory(ctx, sqlc.CreatePriceHistoryParams{
			ProductID: uid,
			OldPrice:  existing.UnitPrice,
			NewPrice:  repository.Float64ToNumeric(unitPrice),
		})
	}

	p := repository.ToDomainProduct(row)
	return &p, nil
}

func (s *ProductService) Delete(ctx context.Context, id string) error {
	uid, err := repository.StringToUUID(id)
	if err != nil {
		return domain.ErrNotFound
	}
	return s.q.DeleteProduct(ctx, uid)
}

func (s *ProductService) PriceHistory(ctx context.Context, id string) ([]domain.PriceHistoryEntry, error) {
	uid, err := repository.StringToUUID(id)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	rows, err := s.q.ListPriceHistory(ctx, uid)
	if err != nil {
		return nil, err
	}
	out := make([]domain.PriceHistoryEntry, len(rows))
	for i, r := range rows {
		out[i] = domain.PriceHistoryEntry{
			ID:        r.ID.String(),
			ProductID: r.ProductID.String(),
			OldPrice:  repository.NumericToFloat64(r.OldPrice),
			NewPrice:  repository.NumericToFloat64(r.NewPrice),
			Note:      r.Note,
			ChangedAt: r.ChangedAt.Time,
		}
	}
	return out, nil
}
