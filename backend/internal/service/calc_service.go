package service

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/shopspring/decimal"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

// CalcService, Metraj Hesaplama modülünün DB orkestrasyonudur.
//
// KRİTİK: Run (hesaplama çağrısı) SALT OKURDUR -- hiçbir INSERT/UPDATE
// içermez. BYZ'nin _resolve_recipe_products'ı (okuma yolunda ürün
// yaratma/fiyat onarımı) BİLİNÇLİ OLARAK taşınmadı (bkz.
// docs/byz-teknik-metraj-*.md ve migration dosyasındaki yorum): eksik/
// 0 TL ürün yalnızca warnings[] üretir, hiçbir yazma tetiklemez.
type CalcService struct {
	q *sqlc.Queries
}

func NewCalcService(q *sqlc.Queries) *CalcService {
	return &CalcService{q: q}
}

// ---------- Gruplar ----------

// ListGroups: includeInactive yalnızca yönetim ekranları içindir (pasif
// grubu görüp yeniden aktifleştirebilmek); Metraj Hesapla akışı yalnızca
// aktifleri görür.
func (s *CalcService) ListGroups(ctx context.Context, organizationID string, includeInactive bool) ([]domain.CalcGroup, error) {
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	var rows []sqlc.CalcGroup
	if includeInactive {
		rows, err = s.q.ListCalcGroupsAdmin(ctx, orgID)
	} else {
		rows, err = s.q.ListCalcGroups(ctx, orgID)
	}
	if err != nil {
		return nil, err
	}
	out := make([]domain.CalcGroup, len(rows))
	for i, r := range rows {
		out[i] = repository.ToDomainCalcGroup(r)
	}
	return out, nil
}

type CalcGroupInput struct {
	Slug        string
	Name        string
	Description string
	SortOrder   int
}

func (in CalcGroupInput) validate() error {
	if strings.TrimSpace(in.Slug) == "" {
		return errors.New("slug zorunludur")
	}
	if strings.TrimSpace(in.Name) == "" {
		return errors.New("ad zorunludur")
	}
	return nil
}

func (s *CalcService) CreateGroup(ctx context.Context, organizationID string, in CalcGroupInput) (*domain.CalcGroup, error) {
	if err := in.validate(); err != nil {
		return nil, err
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	row, err := s.q.CreateCalcGroup(ctx, sqlc.CreateCalcGroupParams{
		OrganizationID: orgID, Slug: strings.TrimSpace(in.Slug), Name: strings.TrimSpace(in.Name),
		Description: in.Description, SortOrder: int32(in.SortOrder),
	})
	if err != nil {
		return nil, mapCalcWriteError(err, "bu slug ile bir grup zaten var")
	}
	g := repository.ToDomainCalcGroup(row)
	return &g, nil
}

func (s *CalcService) UpdateGroup(ctx context.Context, id, organizationID string, in CalcGroupInput, isActive bool) (*domain.CalcGroup, error) {
	if err := in.validate(); err != nil {
		return nil, err
	}
	uid, orgID, err := twoUUIDs(id, organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	row, err := s.q.UpdateCalcGroup(ctx, sqlc.UpdateCalcGroupParams{
		ID: uid, OrganizationID: orgID, Slug: strings.TrimSpace(in.Slug), Name: strings.TrimSpace(in.Name),
		Description: in.Description, SortOrder: int32(in.SortOrder), IsActive: isActive,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, mapCalcWriteError(err, "bu slug ile bir grup zaten var")
	}
	g := repository.ToDomainCalcGroup(row)
	return &g, nil
}

// ---------- Kategoriler ----------

// ListCategoriesForOrg, "grup seç -> kategori seç" kaskadı için TÜM
// aktif grupların aktif kategorilerini tek sorguda döner (BYZ
// get_calculation_categories_grouped ile aynı fikir, N+1 yok).
func (s *CalcService) ListCategoriesForOrg(ctx context.Context, organizationID string) ([]domain.CalcCategory, error) {
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	rows, err := s.q.ListActiveCalcCategoriesForOrg(ctx, orgID)
	if err != nil {
		return nil, err
	}
	out := make([]domain.CalcCategory, len(rows))
	for i, r := range rows {
		out[i] = repository.ToDomainCalcCategoryListRow(r)
	}
	return out, nil
}

func (s *CalcService) ListCategoriesByGroup(ctx context.Context, groupID, organizationID string, includeInactive bool) ([]domain.CalcCategory, error) {
	gid, orgID, err := twoUUIDs(groupID, organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	var rows []sqlc.CalcCategory
	if includeInactive {
		rows, err = s.q.ListCalcCategoriesByGroupAdmin(ctx, sqlc.ListCalcCategoriesByGroupAdminParams{GroupID: gid, OrganizationID: orgID})
	} else {
		rows, err = s.q.ListCalcCategoriesByGroup(ctx, sqlc.ListCalcCategoriesByGroupParams{GroupID: gid, OrganizationID: orgID})
	}
	if err != nil {
		return nil, err
	}
	out := make([]domain.CalcCategory, len(rows))
	for i, r := range rows {
		out[i] = repository.ToDomainCalcCategory(r)
	}
	return out, nil
}

func (s *CalcService) GetCategory(ctx context.Context, id, organizationID string) (*domain.CalcCategory, error) {
	uid, orgID, err := twoUUIDs(id, organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	row, err := s.q.GetCalcCategoryByID(ctx, sqlc.GetCalcCategoryByIDParams{ID: uid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	c := repository.ToDomainCalcCategory(row)
	return &c, nil
}

type CalcCategoryInput struct {
	GroupID     string
	Slug        string
	Name        string
	Description string
	ImageFileID *string
	SortOrder   int
}

func (in CalcCategoryInput) validate() error {
	if strings.TrimSpace(in.GroupID) == "" {
		return errors.New("group_id zorunludur")
	}
	if strings.TrimSpace(in.Slug) == "" {
		return errors.New("slug zorunludur")
	}
	if strings.TrimSpace(in.Name) == "" {
		return errors.New("ad zorunludur")
	}
	return nil
}

func (s *CalcService) CreateCategory(ctx context.Context, organizationID string, in CalcCategoryInput) (*domain.CalcCategory, error) {
	if err := in.validate(); err != nil {
		return nil, err
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	groupID, err := repository.StringToUUID(in.GroupID)
	if err != nil {
		return nil, fmt.Errorf("geçersiz group_id")
	}
	// Grup gerçekten bu organizasyona ait mi -- yoksa başka bir firmanın
	// grup id'sine kategori asmak mümkün olurdu.
	if _, err := s.q.GetCalcGroupByID(ctx, sqlc.GetCalcGroupByIDParams{ID: groupID, OrganizationID: orgID}); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, fmt.Errorf("group_id bu organizasyona ait değil")
		}
		return nil, err
	}
	row, err := s.q.CreateCalcCategory(ctx, sqlc.CreateCalcCategoryParams{
		OrganizationID: orgID, GroupID: groupID, Slug: strings.TrimSpace(in.Slug), Name: strings.TrimSpace(in.Name),
		Description: in.Description, ImageFileID: optionalUUID(in.ImageFileID), SortOrder: int32(in.SortOrder),
	})
	if err != nil {
		return nil, mapCalcWriteError(err, "bu slug ile bir kategori zaten var")
	}
	c := repository.ToDomainCalcCategory(row)
	return &c, nil
}

func (s *CalcService) UpdateCategory(ctx context.Context, id, organizationID string, in CalcCategoryInput, isActive bool) (*domain.CalcCategory, error) {
	if err := in.validate(); err != nil {
		return nil, err
	}
	uid, orgID, err := twoUUIDs(id, organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	groupID, err := repository.StringToUUID(in.GroupID)
	if err != nil {
		return nil, fmt.Errorf("geçersiz group_id")
	}
	if _, err := s.q.GetCalcGroupByID(ctx, sqlc.GetCalcGroupByIDParams{ID: groupID, OrganizationID: orgID}); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, fmt.Errorf("group_id bu organizasyona ait değil")
		}
		return nil, err
	}
	row, err := s.q.UpdateCalcCategory(ctx, sqlc.UpdateCalcCategoryParams{
		ID: uid, OrganizationID: orgID, GroupID: groupID, Slug: strings.TrimSpace(in.Slug), Name: strings.TrimSpace(in.Name),
		Description: in.Description, ImageFileID: optionalUUID(in.ImageFileID), SortOrder: int32(in.SortOrder), IsActive: isActive,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, mapCalcWriteError(err, "bu slug ile bir kategori zaten var")
	}
	c := repository.ToDomainCalcCategory(row)
	return &c, nil
}

// ---------- Reçete Kalemleri (admin) ----------

func (s *CalcService) ListRecipeItemsAdmin(ctx context.Context, categoryID, organizationID string) ([]domain.CalcRecipeItem, error) {
	cid, orgID, err := twoUUIDs(categoryID, organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	rows, err := s.q.ListCalcRecipeItemsAdmin(ctx, sqlc.ListCalcRecipeItemsAdminParams{CategoryID: cid, OrganizationID: orgID})
	if err != nil {
		return nil, err
	}
	out := make([]domain.CalcRecipeItem, len(rows))
	for i, r := range rows {
		out[i] = repository.ToDomainCalcRecipeItem(r)
	}
	return out, nil
}

type CalcRecipeItemInput struct {
	CategoryID         string
	ProductID          *string
	MaterialName       string
	Unit               string
	CalculationType    string
	QuantityPerM2      decimal.Decimal
	QuantityPerMeter   decimal.Decimal
	FixedQuantity      decimal.Decimal
	WastePercent       decimal.Decimal
	RoundingType       string
	MinQuantity        *decimal.Decimal
	PackageSize        *decimal.Decimal
	ReferenceUnitPrice decimal.Decimal
	GroupName          string
	SortOrder          int
	Notes              *string
}

// normalize, isteğe bağlı-ama-varsayılanlı alanları doldurur -- ör.
// rounding_type boş bırakılırsa DB kolonunun kendi varsayılanıyla (none)
// aynı davranışı sağlar; çağıran her seferinde açıkça "none" yazmak
// zorunda kalmaz.
func (in CalcRecipeItemInput) normalize() CalcRecipeItemInput {
	if strings.TrimSpace(in.RoundingType) == "" {
		in.RoundingType = domain.RoundingNone
	}
	return in
}

func (in CalcRecipeItemInput) validate() error {
	if strings.TrimSpace(in.MaterialName) == "" {
		return errors.New("material_name zorunludur")
	}
	if strings.TrimSpace(in.Unit) == "" {
		return errors.New("unit zorunludur")
	}
	if !domain.ValidCalcType(in.CalculationType) {
		return fmt.Errorf("geçersiz calculation_type: %q (area_based | perimeter_based | fixed olmalı)", in.CalculationType)
	}
	if !domain.ValidRoundingType(in.RoundingType) {
		return fmt.Errorf("geçersiz rounding_type: %q (none | ceil | round olmalı)", in.RoundingType)
	}
	// Negatif katsayı/fiyat DB CHECK kısıtlarıyla zaten engellenir (bkz.
	// migration), ama burada erken ve anlaşılır bir mesajla reddetmek
	// ham Postgres hatasının handler'a sızmasını önler.
	for name, v := range map[string]decimal.Decimal{
		"quantity_per_m2": in.QuantityPerM2, "quantity_per_meter": in.QuantityPerMeter,
		"fixed_quantity": in.FixedQuantity, "waste_percent": in.WastePercent,
		"reference_unit_price": in.ReferenceUnitPrice,
	} {
		if v.IsNegative() {
			return fmt.Errorf("%s negatif olamaz", name)
		}
	}
	if in.MinQuantity != nil && in.MinQuantity.IsNegative() {
		return errors.New("min_quantity negatif olamaz")
	}
	if in.PackageSize != nil && !in.PackageSize.IsPositive() {
		return errors.New("package_size verilmişse 0'dan büyük olmalı")
	}
	return nil
}

// CreateRecipeItem, product_id verilmişse ürünün AYNI organizasyona ait
// olduğunu doğrular (kullanıcı talimatı: "product_id aynı organization'daki
// products kaydına bağlı olsun") ve ürün yoksa/başka firmaya aitse
// YARATMAZ -- açık bir validation hatası döner.
func (s *CalcService) CreateRecipeItem(ctx context.Context, organizationID string, in CalcRecipeItemInput) (*domain.CalcRecipeItem, error) {
	in = in.normalize()
	if err := in.validate(); err != nil {
		return nil, err
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	categoryID, err := repository.StringToUUID(in.CategoryID)
	if err != nil {
		return nil, fmt.Errorf("geçersiz category_id")
	}
	if _, err := s.q.GetCalcCategoryByID(ctx, sqlc.GetCalcCategoryByIDParams{ID: categoryID, OrganizationID: orgID}); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, fmt.Errorf("category_id bu organizasyona ait değil")
		}
		return nil, err
	}
	productUUID, err := s.resolveOwnedProductID(ctx, in.ProductID, orgID)
	if err != nil {
		return nil, err
	}
	row, err := s.q.CreateCalcRecipeItem(ctx, sqlc.CreateCalcRecipeItemParams{
		OrganizationID: orgID, CategoryID: categoryID, ProductID: productUUID,
		MaterialName: strings.TrimSpace(in.MaterialName), Unit: strings.TrimSpace(in.Unit),
		CalculationType:    in.CalculationType,
		QuantityPerM2:      repository.DecimalToNumeric(in.QuantityPerM2),
		QuantityPerMeter:   repository.DecimalToNumeric(in.QuantityPerMeter),
		FixedQuantity:      repository.DecimalToNumeric(in.FixedQuantity),
		WastePercent:       repository.DecimalToNumeric(in.WastePercent),
		RoundingType:       in.RoundingType,
		MinQuantity:        repository.DecimalPtrToNumeric(in.MinQuantity),
		PackageSize:        repository.DecimalPtrToNumeric(in.PackageSize),
		ReferenceUnitPrice: repository.DecimalToNumeric(in.ReferenceUnitPrice),
		GroupName:          in.GroupName, SortOrder: int32(in.SortOrder), Notes: in.Notes,
	})
	if err != nil {
		return nil, mapCalcWriteError(err, "bu kategoride aynı malzeme adı+birim zaten kayıtlı")
	}
	item := repository.ToDomainCalcRecipeItem(row)
	return &item, nil
}

func (s *CalcService) UpdateRecipeItem(ctx context.Context, id, organizationID string, in CalcRecipeItemInput, isActive bool) (*domain.CalcRecipeItem, error) {
	in = in.normalize()
	if err := in.validate(); err != nil {
		return nil, err
	}
	uid, orgID, err := twoUUIDs(id, organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	productUUID, err := s.resolveOwnedProductID(ctx, in.ProductID, orgID)
	if err != nil {
		return nil, err
	}
	row, err := s.q.UpdateCalcRecipeItem(ctx, sqlc.UpdateCalcRecipeItemParams{
		ID: uid, OrganizationID: orgID, ProductID: productUUID,
		MaterialName: strings.TrimSpace(in.MaterialName), Unit: strings.TrimSpace(in.Unit),
		CalculationType:    in.CalculationType,
		QuantityPerM2:      repository.DecimalToNumeric(in.QuantityPerM2),
		QuantityPerMeter:   repository.DecimalToNumeric(in.QuantityPerMeter),
		FixedQuantity:      repository.DecimalToNumeric(in.FixedQuantity),
		WastePercent:       repository.DecimalToNumeric(in.WastePercent),
		RoundingType:       in.RoundingType,
		MinQuantity:        repository.DecimalPtrToNumeric(in.MinQuantity),
		PackageSize:        repository.DecimalPtrToNumeric(in.PackageSize),
		ReferenceUnitPrice: repository.DecimalToNumeric(in.ReferenceUnitPrice),
		GroupName:          in.GroupName, SortOrder: int32(in.SortOrder), IsActive: isActive, Notes: in.Notes,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, mapCalcWriteError(err, "bu kategoride aynı malzeme adı+birim zaten kayıtlı")
	}
	item := repository.ToDomainCalcRecipeItem(row)
	return &item, nil
}

func (s *CalcService) DeleteRecipeItem(ctx context.Context, id, organizationID string) error {
	uid, orgID, err := twoUUIDs(id, organizationID)
	if err != nil {
		return domain.ErrNotFound
	}
	rows, err := s.q.DeleteCalcRecipeItem(ctx, sqlc.DeleteCalcRecipeItemParams{ID: uid, OrganizationID: orgID})
	if err != nil {
		return err
	}
	if rows == 0 {
		return domain.ErrNotFound
	}
	return nil
}

// resolveOwnedProductID, product_id boşsa NULL pgtype.UUID döner;
// doluysa ürünün AYNI organizasyona ait olduğunu doğrular -- doğrulama
// olmadan reçete kalemi başka bir firmanın ürününe bağlanabilirdi.
func (s *CalcService) resolveOwnedProductID(ctx context.Context, productID *string, orgID pgtype.UUID) (pgtype.UUID, error) {
	if productID == nil || strings.TrimSpace(*productID) == "" {
		return pgtype.UUID{}, nil
	}
	pid, err := repository.StringToUUID(*productID)
	if err != nil {
		return pgtype.UUID{}, fmt.Errorf("geçersiz product_id")
	}
	if _, err := s.q.GetProductByID(ctx, sqlc.GetProductByIDParams{ID: pid, OrganizationID: orgID}); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return pgtype.UUID{}, fmt.Errorf("product_id bu organizasyona ait değil")
		}
		return pgtype.UUID{}, err
	}
	return pid, nil
}

// ---------- Hesaplama (salt-okur) ----------

// CalcRunInput, /calculations/run isteğinin ayrıştırılmış girdisidir.
type CalcRunInput struct {
	CategoryID string
	domain.CalcInput
}

// Run, TEK bir kategori için malzeme listesini hesaplar. Hiçbir yazma
// yapmaz (yorum: package doc). Adımlar: kategori + aktif reçete
// kalemlerini oku -> ürünleri TEK toplu sorguda çöz -> geometri türet
// (sunucuda, istemciye güvenmeden) -> her kalem için domain motorunu
// çağır -> zaten yuvarlanmış satırların toplamını al.
func (s *CalcService) Run(ctx context.Context, organizationID string, in CalcRunInput) (*domain.CalcResult, error) {
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	categoryID, err := repository.StringToUUID(in.CategoryID)
	if err != nil {
		return nil, domain.ErrNotFound
	}

	categoryRow, err := s.q.GetCalcCategoryByID(ctx, sqlc.GetCalcCategoryByIDParams{ID: categoryID, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	category := repository.ToDomainCalcCategory(categoryRow)

	itemRows, err := s.q.ListCalcRecipeItems(ctx, sqlc.ListCalcRecipeItemsParams{CategoryID: categoryID, OrganizationID: orgID})
	if err != nil {
		return nil, err
	}
	if len(itemRows) == 0 {
		return nil, fmt.Errorf("bu kategori için malzeme reçetesi tanımlanmamış")
	}
	items := make([]domain.CalcRecipeItem, len(itemRows))
	for i, r := range itemRows {
		items[i] = repository.ToDomainCalcRecipeItem(r)
	}

	geo, err := domain.ComputeGeometry(in.CalcInput)
	if err != nil {
		return nil, err
	}

	// Ürünleri TEK toplu sorguda çöz (N+1 yok) -- yalnızca product_id'si
	// olan kalemler için.
	var productIDs []pgtype.UUID
	for _, it := range items {
		if it.ProductID != nil {
			pid, err := repository.StringToUUID(*it.ProductID)
			if err == nil {
				productIDs = append(productIDs, pid)
			}
		}
	}
	productsByID := map[string]sqlc.Product{}
	if len(productIDs) > 0 {
		rows, err := s.q.ResolveRecipeProducts(ctx, sqlc.ResolveRecipeProductsParams{Ids: productIDs, OrganizationID: orgID})
		if err != nil {
			return nil, err
		}
		for _, p := range rows {
			productsByID[p.ID.String()] = p
		}
	}

	result := &domain.CalcResult{Category: category, Geometry: geo}
	total := decimal.Zero
	for _, item := range items {
		qty, warn := domain.ComputeRecipeQuantity(item, geo)
		if warn != nil {
			result.Warnings = append(result.Warnings, *warn)
		}

		var unitPrice decimal.Decimal
		var resolvedProductID *string
		if item.ProductID != nil {
			if p, ok := productsByID[*item.ProductID]; ok {
				unitPrice = repository.NumericToDecimal(p.UnitPrice)
				id := p.ID.String()
				resolvedProductID = &id
			} else {
				result.Warnings = append(result.Warnings, domain.CalcWarning{
					ItemID: item.ID, Code: "product_missing",
					Message: fmt.Sprintf("%q için bağlı ürün bulunamadı (silinmiş olabilir); birim fiyat 0 kabul edildi.", item.MaterialName),
				})
			}
		} else {
			result.Warnings = append(result.Warnings, domain.CalcWarning{
				ItemID: item.ID, Code: "product_missing",
				Message: fmt.Sprintf("%q bir ürüne bağlı değil; birim fiyat 0 kabul edildi.", item.MaterialName),
			})
		}
		if resolvedProductID != nil && unitPrice.IsZero() {
			result.Warnings = append(result.Warnings, domain.CalcWarning{
				ItemID: item.ID, Code: "product_zero_price",
				Message: fmt.Sprintf("%q için ürün fiyatı 0 TL.", item.MaterialName),
			})
		}

		lineTotal := qty.Mul(unitPrice).Round(2)
		total = total.Add(lineTotal) // zaten yuvarlanmış satırların toplamı -- BYZ'nin ±0.01 hatası tekrarlanmaz

		var factor decimal.Decimal
		switch item.CalculationType {
		case domain.CalcTypePerimeterBased:
			factor = item.QuantityPerMeter
		case domain.CalcTypeFixed:
			factor = item.FixedQuantity
		default:
			factor = item.QuantityPerM2
		}

		result.Items = append(result.Items, domain.CalcResultItem{
			RecipeItemID: item.ID, MaterialName: item.MaterialName, Unit: item.Unit,
			Quantity: qty, ProductID: resolvedProductID, UnitPrice: unitPrice, LineTotal: lineTotal,
			GroupName: item.GroupName, CalculationType: item.CalculationType, Factor: factor,
			WastePercent: item.WastePercent, RoundingType: item.RoundingType,
		})
	}
	result.TotalCost = total.Round(2)
	return result, nil
}

// ---------- Yardımcılar ----------

func twoUUIDs(a, b string) (pgtype.UUID, pgtype.UUID, error) {
	ua, err := repository.StringToUUID(a)
	if err != nil {
		return pgtype.UUID{}, pgtype.UUID{}, err
	}
	ub, err := repository.StringToUUID(b)
	if err != nil {
		return pgtype.UUID{}, pgtype.UUID{}, err
	}
	return ua, ub, nil
}

func optionalUUID(s *string) pgtype.UUID {
	if s == nil || strings.TrimSpace(*s) == "" {
		return pgtype.UUID{}
	}
	u, err := repository.StringToUUID(*s)
	if err != nil {
		return pgtype.UUID{}
	}
	return u
}

// mapCalcWriteError, UNIQUE/CHECK kısıtı ihlallerini (ör. slug ya da
// material_name+unit çakışması) kullanıcıya anlamlı bir mesajla döner;
// diğer hatalar olduğu gibi geçer.
func mapCalcWriteError(err error, duplicateMessage string) error {
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && pgErr.Code == "23505" {
		return errors.New(duplicateMessage)
	}
	return err
}
