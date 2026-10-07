package service

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

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

func (s *ProductService) List(ctx context.Context, organizationID, search string, page, limit int) (*ProductListResult, error) {
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	if page <= 0 {
		page = 1
	}
	norm := domain.NormalizeName(search)
	rows, err := s.q.ListProducts(ctx, sqlc.ListProductsParams{
		OrganizationID: orgID,
		Limit:          int32(limit),
		Offset:         int32((page - 1) * limit),
		Column4:        norm,
	})
	if err != nil {
		return nil, err
	}
	total, err := s.q.CountProducts(ctx, sqlc.CountProductsParams{OrganizationID: orgID, Column2: norm})
	if err != nil {
		return nil, err
	}
	products := make([]domain.Product, len(rows))
	for i, r := range rows {
		products[i] = repository.ToDomainProduct(r)
	}
	return &ProductListResult{Products: products, Total: total}, nil
}

func (s *ProductService) Get(ctx context.Context, id, organizationID string) (*domain.Product, error) {
	uid, err := repository.StringToUUID(id)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	row, err := s.q.GetProductByID(ctx, sqlc.GetProductByIDParams{ID: uid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	p := repository.ToDomainProduct(row)
	return &p, nil
}

func (s *ProductService) Create(ctx context.Context, organizationID, name, unit string, unitPrice float64, description, category string) (*domain.Product, error) {
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	name = strings.TrimSpace(name)
	if name == "" {
		return nil, errors.New("ürün adı zorunludur")
	}
	if unit = strings.TrimSpace(unit); unit == "" {
		unit = "adet"
	}
	row, err := s.q.CreateProduct(ctx, sqlc.CreateProductParams{
		OrganizationID: orgID,
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
// bir kayıt (reason 'manual') düşer -- BYZ'deki embedded (son 50 ile
// sınırlı) listenin yerine, sınırsız ve ayrı sorgulanabilir bir tabloda.
// Güncelleme ve geçmiş kaydı TEK ifadedir (UpdateProductWithPriceHistory):
// eski fiyat satır kilitliyken okunur, eşzamanlı bir senkronla yarışmaz;
// geçmiş yazılamazsa güncelleme de olmaz.
func (s *ProductService) Update(ctx context.Context, id, organizationID, name, unit string, unitPrice float64, description, category string) (*domain.Product, error) {
	uid, err := repository.StringToUUID(id)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}

	name = strings.TrimSpace(name)
	if name == "" {
		return nil, errors.New("ürün adı zorunludur")
	}

	row, err := s.q.UpdateProductWithPriceHistory(ctx, sqlc.UpdateProductWithPriceHistoryParams{
		ID:             uid,
		OrganizationID: orgID,
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

	p := repository.ToDomainProduct(sqlc.Product(row))
	return &p, nil
}

// ErrProductInUse, kullanımdaki bir ürün silinmek istendiğinde döner
// (errors.Is ile; ayrıntı *ProductInUseError'da).
var ErrProductInUse = errors.New("bu ürün kullanımda olduğu için silinemez")

// ProductInUseError, ürünün nerede kullanıldığını söyler.
type ProductInUseError struct {
	RecipeItems      int64
	ChangeOrderItems int64
}

func (e *ProductInUseError) Error() string {
	var parts []string
	if e.RecipeItems > 0 {
		parts = append(parts, fmt.Sprintf("%d metraj reçete kaleminde", e.RecipeItems))
	}
	if e.ChangeOrderItems > 0 {
		parts = append(parts, fmt.Sprintf("%d ek iş kaleminde", e.ChangeOrderItems))
	}
	msg := "bu ürün " + strings.Join(parts, " ve ") + " kullanılıyor; silinemez"
	if e.RecipeItems > 0 {
		msg += ". Önce Metraj Hesaplama reçetelerinden kaldırın ya da başka bir ürüne bağlayın"
	}
	return msg
}

func (e *ProductInUseError) Is(target error) bool { return target == ErrProductInUse }

// Delete, ürünü kalıcı olarak siler -- ama yalnızca hiçbir metraj reçete
// kalemi ya da ek iş kalemi ona bağlı değilse. Eskiden reçete kalemleri
// (ON DELETE SET NULL) sessizce ürünsüz kalıyor, ek iş kalemleri ise ham bir
// Postgres FK hatasıyla silmeyi düşürüyordu. Teklif kalemleri engel değildir:
// ürün adı/fiyatının anlık görüntüsünü taşırlar. Kontrol ile silme arasında
// bir kayıt bağlanırsa (yarış) ek iş FK'si yine 409'a çevrilir.
func (s *ProductService) Delete(ctx context.Context, id, organizationID string) error {
	uid, err := repository.StringToUUID(id)
	if err != nil {
		return domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return domain.ErrNotFound
	}
	usage, err := s.q.GetProductUsage(ctx, sqlc.GetProductUsageParams{ID: uid, OrganizationID: orgID})
	if err != nil {
		return err
	}
	if usage.RecipeItems > 0 || usage.ChangeOrderItems > 0 {
		if _, err := s.q.GetProductByID(ctx, sqlc.GetProductByIDParams{ID: uid, OrganizationID: orgID}); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return domain.ErrNotFound
			}
			return err
		}
		return &ProductInUseError{RecipeItems: usage.RecipeItems, ChangeOrderItems: usage.ChangeOrderItems}
	}
	rows, err := s.q.DeleteProduct(ctx, sqlc.DeleteProductParams{ID: uid, OrganizationID: orgID})
	if err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23503" {
			return ErrProductInUse
		}
		return err
	}
	if rows == 0 {
		return domain.ErrNotFound
	}
	return nil
}

func (s *ProductService) PriceHistory(ctx context.Context, id, organizationID string) ([]domain.PriceHistoryEntry, error) {
	uid, err := repository.StringToUUID(id)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	// Ürünün gerçekten bu organizasyona ait olduğu doğrulanmadan geçmişi
	// listelemek, product_id bilinirse başka bir org'un fiyat geçmişini
	// sızdırabilirdi -- bu yüzden önce Get ile org sahipliği kontrol edilir.
	if _, err := s.q.GetProductByID(ctx, sqlc.GetProductByIDParams{ID: uid, OrganizationID: orgID}); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	rows, err := s.q.ListPriceHistory(ctx, uid)
	if err != nil {
		return nil, err
	}
	out := make([]domain.PriceHistoryEntry, len(rows))
	for i, r := range rows {
		out[i] = domain.PriceHistoryEntry{
			ID:             r.ID.String(),
			ProductID:      r.ProductID.String(),
			OldPrice:       repository.NumericToFloat64(r.OldPrice),
			NewPrice:       repository.NumericToFloat64(r.NewPrice),
			Note:           r.Note,
			ChangedAt:      r.ChangedAt.Time,
			Reason:         r.Reason,
			Source:         derefString(r.Source),
			OldSourcePrice: repository.NumericToFloat64Ptr(r.OldSourcePrice),
			NewSourcePrice: repository.NumericToFloat64Ptr(r.NewSourcePrice),
		}
	}
	return out, nil
}
