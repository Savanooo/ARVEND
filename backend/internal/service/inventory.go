package service

import (
	"context"
	"errors"
	"fmt"
	"math"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/platform/storage"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

// Stok Takibi (migration 0072): projelerden bağımsız depolar, malzeme
// kartları, parti/SKT ve fişler. Kurallar migration başlığında; özetle:
// çıkıştaki proje yalnızca bilgidir (maliyete yazılmaz), fiş değişmez
// (iptal ters fişle), bakiye eksiye düşmez, maliyet hareketli ağırlıklı
// ortalama (KDV hariç). İzinler router'da: inventory.read / .manage /
// .adjust.

const (
	InventoryPolicyWarn  = "warn"
	InventoryPolicyBlock = "block"

	inventoryItemCodeFormat   = "STK-%04d"
	inventoryDefaultWarehouse = "Merkez Depo"
	inventoryMaxLines         = 100
	inventoryMaxQuantity      = 99_999_999_999.0
)

var (
	ErrInventoryWarehouseNotFound error = &NotFoundError{What: "depo"}
	ErrInventoryItemNotFound      error = &NotFoundError{What: "malzeme"}
	ErrInventoryDocumentNotFound  error = &NotFoundError{What: "stok fişi"}
	ErrInventoryLotNotFound       error = &NotFoundError{What: "parti"}

	ErrInventoryInvalid           = errors.New("geçersiz stok bilgisi")
	ErrInventoryDuplicateCode     = errors.New("bu kodla bir malzeme zaten var")
	ErrInventoryDuplicateBarcode  = errors.New("bu barkod başka bir malzemede kayıtlı")
	ErrInventoryDuplicateName     = errors.New("bu adla bir depo zaten var")
	ErrInventoryWarehouseHasStock = errors.New("depoda stok var; önce stoğu başka depoya aktarın ya da çıkış yapın")
	ErrInventoryItemHasStock      = errors.New("malzemenin stoğu var; arşivlemeden önce stoğu sıfırlayın")
	ErrInventoryInactive          = errors.New("arşivlenmiş depo ya da malzemeyle işlem yapılamaz")
	ErrInventoryInsufficient      = errors.New("yetersiz stok")
	ErrInventoryExpiredBlocked    = errors.New("son kullanma tarihi geçmiş parti çıkamaz")
	ErrInventoryAlreadyReversed   = errors.New("bu fiş zaten iptal edilmiş")
	ErrInventoryNotReversible     = errors.New("iptal fişi yeniden iptal edilemez")
)

// inventoryRuleError: kullanıcıya ne olduğunu söyleyen kural hatası;
// errors.Is ile kategorisine (yetersiz stok, SKT engeli) eşlenir.
type inventoryRuleError struct {
	kind error
	msg  string
}

func (e *inventoryRuleError) Error() string        { return e.msg }
func (e *inventoryRuleError) Is(target error) bool { return target == e.kind }

type InventoryService struct {
	pool  *pgxpool.Pool
	q     *sqlc.Queries
	store storage.Store
}

func NewInventoryService(pool *pgxpool.Pool, q *sqlc.Queries, store storage.Store) *InventoryService {
	return &InventoryService{pool: pool, q: q, store: store}
}

// ---------- Tipler ----------

type InventoryWarehouse struct {
	ID        string
	Name      string
	Address   string
	Notes     string
	IsActive  bool
	ItemCount int
	CreatedAt time.Time
}

type InventoryWarehouseInput struct {
	Name     string
	Address  string
	Notes    string
	IsActive *bool
	UserID   string
}

type InventoryItem struct {
	ID              string
	Code            string
	Name            string
	Barcode         string
	Unit            string
	Category        string
	ProductID       string
	MinStock        *float64
	TrackExpiry     bool
	ShelfLifeMonths *int
	ExpiryPolicy    string
	ExpiryAlertDays int
	AvgUnitCost     float64
	Notes           string
	IsActive        bool
	CreatedAt       time.Time

	// Listede: (seçili depodaki) stok durumu.
	Quantity         float64
	NearestExpiry    *time.Time
	ExpiredQuantity  float64
	ExpiringQuantity float64
}

// BelowMin: minimum stok tanımlı ve miktar altında.
func (i InventoryItem) BelowMin() bool { return i.MinStock != nil && i.Quantity < *i.MinStock }

type InventoryItemInput struct {
	Code            string
	Name            string
	Barcode         string
	Unit            string
	Category        string
	ProductID       string
	MinStock        *float64
	TrackExpiry     bool
	ShelfLifeMonths *int
	ExpiryPolicy    string
	ExpiryAlertDays *int
	Notes           string
	IsActive        *bool
	UserID          string
}

type InventoryBalance struct {
	WarehouseID    string
	WarehouseName  string
	LotID          string
	LotNo          string
	ExpiryDate     *time.Time
	ProductionDate *time.Time
	Quantity       float64
}

type InventoryItemDetail struct {
	Item      InventoryItem
	Balances  []InventoryBalance
	Documents []InventoryDocumentSummary
}

type InventorySummary struct {
	ItemCount        int
	StockValue       float64
	ExpiredLotCount  int
	ExpiringLotCount int
	BelowMinCount    int
}

type InventoryLotAlert struct {
	ItemID        string
	ItemCode      string
	ItemName      string
	Unit          string
	ExpiryPolicy  string
	WarehouseID   string
	WarehouseName string
	LotID         string
	LotNo         string
	ExpiryDate    time.Time
	Quantity      float64
	Expired       bool
}

// ---------- Sayı yardımcıları ----------

// roundQty: miktar 3 ondalık (kg, metre); numeric(14,3) ile birebir.
func roundQty(f float64) float64 { return math.Round(f*1000) / 1000 }

func qtyNumeric(f float64) pgtype.Numeric {
	var n pgtype.Numeric
	_ = n.Scan(strconv.FormatFloat(roundQty(f), 'f', 3, 64))
	return n
}

func costNumeric(f float64) pgtype.Numeric {
	var n pgtype.Numeric
	_ = n.Scan(strconv.FormatFloat(f, 'f', 4, 64))
	return n
}

func numF(n pgtype.Numeric) float64 { return repository.NumericToFloat64(n) }

func numPtr(n pgtype.Numeric) *float64 {
	if !n.Valid {
		return nil
	}
	f := numF(n)
	return &f
}

func datePtr(d pgtype.Date) *time.Time {
	if !d.Valid {
		return nil
	}
	t := d.Time
	return &t
}

func int32Ptr(p *int) *int32 {
	if p == nil {
		return nil
	}
	v := int32(*p)
	return &v
}

func intFrom32(p *int32) *int {
	if p == nil {
		return nil
	}
	v := int(*p)
	return &v
}

func optUUID(s string) (pgtype.UUID, error) {
	if strings.TrimSpace(s) == "" {
		return pgtype.UUID{}, nil
	}
	return repository.StringToUUID(s)
}

func trimLen(field, s string, max int) (string, error) {
	s = strings.TrimSpace(s)
	if utf8.RuneCountInString(s) > max {
		return "", fmt.Errorf("%w: %s en fazla %d karakter", ErrInventoryInvalid, field, max)
	}
	return s, nil
}

func (s *InventoryService) org(organizationID string) (pgtype.UUID, error) {
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return pgtype.UUID{}, domain.ErrNotFound
	}
	return orgID, nil
}

// ---------- Depolar ----------

func toInventoryWarehouse(w sqlc.InventoryWarehouse, itemCount int) InventoryWarehouse {
	return InventoryWarehouse{
		ID: w.ID.String(), Name: w.Name, Address: w.Address, Notes: w.Notes, IsActive: w.IsActive,
		ItemCount: itemCount, CreatedAt: w.CreatedAt.Time,
	}
}

// ListWarehouses: firmanın depoları; hiç depo yoksa "Merkez Depo" açılır.
func (s *InventoryService) ListWarehouses(ctx context.Context, organizationID string) ([]InventoryWarehouse, error) {
	orgID, err := s.org(organizationID)
	if err != nil {
		return nil, err
	}
	if err := s.ensureDefaultWarehouse(ctx, orgID); err != nil {
		return nil, err
	}
	rows, err := s.q.ListInventoryWarehouses(ctx, orgID)
	if err != nil {
		return nil, err
	}
	out := make([]InventoryWarehouse, len(rows))
	for i, r := range rows {
		out[i] = toInventoryWarehouse(sqlc.InventoryWarehouse{
			ID: r.ID, OrganizationID: r.OrganizationID, Name: r.Name, Address: r.Address, Notes: r.Notes,
			IsActive: r.IsActive, CreatedBy: r.CreatedBy, CreatedAt: r.CreatedAt, UpdatedAt: r.UpdatedAt,
		}, int(r.ItemCount))
	}
	return out, nil
}

func (s *InventoryService) ensureDefaultWarehouse(ctx context.Context, orgID pgtype.UUID) error {
	n, err := s.q.CountInventoryWarehouses(ctx, orgID)
	if err != nil || n > 0 {
		return err
	}
	if _, err := s.q.CreateInventoryWarehouse(ctx, sqlc.CreateInventoryWarehouseParams{
		OrganizationID: orgID, Name: inventoryDefaultWarehouse,
	}); err != nil && !isUniqueViolation(err) {
		return err
	}
	return nil
}

func validateWarehouse(in *InventoryWarehouseInput) error {
	var err error
	if in.Name, err = trimLen("Depo adı", in.Name, 120); err != nil {
		return err
	}
	if in.Name == "" {
		return fmt.Errorf("%w: depo adı zorunlu", ErrInventoryInvalid)
	}
	if in.Address, err = trimLen("Adres", in.Address, 300); err != nil {
		return err
	}
	in.Notes, err = trimLen("Not", in.Notes, 500)
	return err
}

func (s *InventoryService) CreateWarehouse(ctx context.Context, organizationID string, in InventoryWarehouseInput) (*InventoryWarehouse, error) {
	orgID, err := s.org(organizationID)
	if err != nil {
		return nil, err
	}
	if err := validateWarehouse(&in); err != nil {
		return nil, err
	}
	row, err := s.q.CreateInventoryWarehouse(ctx, sqlc.CreateInventoryWarehouseParams{
		OrganizationID: orgID, Name: in.Name, Address: in.Address, Notes: in.Notes, CreatedBy: actorUUID(in.UserID),
	})
	if err != nil {
		if isUniqueViolation(err) {
			return nil, ErrInventoryDuplicateName
		}
		return nil, err
	}
	out := toInventoryWarehouse(row, 0)
	return &out, nil
}

// UpdateWarehouse: ad/adres/not ve arşiv. Stoğu olan depo arşivlenemez.
func (s *InventoryService) UpdateWarehouse(ctx context.Context, organizationID, warehouseID string, in InventoryWarehouseInput) (*InventoryWarehouse, error) {
	orgID, err := s.org(organizationID)
	if err != nil {
		return nil, err
	}
	wid, err := repository.StringToUUID(warehouseID)
	if err != nil {
		return nil, ErrInventoryWarehouseNotFound
	}
	if err := validateWarehouse(&in); err != nil {
		return nil, err
	}
	current, err := s.q.GetInventoryWarehouse(ctx, sqlc.GetInventoryWarehouseParams{ID: wid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrInventoryWarehouseNotFound
		}
		return nil, err
	}
	active := current.IsActive
	if in.IsActive != nil {
		active = *in.IsActive
	}
	if current.IsActive && !active {
		has, err := s.q.InventoryWarehouseHasStock(ctx, wid)
		if err != nil {
			return nil, err
		}
		if has {
			return nil, ErrInventoryWarehouseHasStock
		}
	}
	row, err := s.q.UpdateInventoryWarehouse(ctx, sqlc.UpdateInventoryWarehouseParams{
		Name: in.Name, Address: in.Address, Notes: in.Notes, IsActive: active, ID: wid, OrganizationID: orgID,
	})
	if err != nil {
		if isUniqueViolation(err) {
			return nil, ErrInventoryDuplicateName
		}
		return nil, err
	}
	out := toInventoryWarehouse(row, 0)
	return &out, nil
}

// ---------- Malzeme kartları ----------

func toInventoryItem(i sqlc.InventoryItem) InventoryItem {
	out := InventoryItem{
		ID: i.ID.String(), Code: i.Code, Name: i.Name, Barcode: i.Barcode, Unit: i.Unit, Category: i.Category,
		MinStock: numPtr(i.MinStock), TrackExpiry: i.TrackExpiry, ShelfLifeMonths: intFrom32(i.ShelfLifeMonths),
		ExpiryPolicy: i.ExpiryPolicy, ExpiryAlertDays: int(i.ExpiryAlertDays), AvgUnitCost: numF(i.AvgUnitCost),
		Notes: i.Notes, IsActive: i.IsActive, CreatedAt: i.CreatedAt.Time,
	}
	if i.ProductID.Valid {
		out.ProductID = i.ProductID.String()
	}
	return out
}

func validateInventoryItem(in *InventoryItemInput) error {
	var err error
	if in.Code, err = trimLen("Kod", in.Code, 40); err != nil {
		return err
	}
	if in.Name, err = trimLen("Ad", in.Name, 200); err != nil {
		return err
	}
	if in.Name == "" {
		return fmt.Errorf("%w: malzeme adı zorunlu", ErrInventoryInvalid)
	}
	if in.Barcode, err = trimLen("Barkod", in.Barcode, 64); err != nil {
		return err
	}
	if in.Unit, err = trimLen("Birim", in.Unit, 20); err != nil {
		return err
	}
	if in.Unit == "" {
		in.Unit = "adet"
	}
	if in.Category, err = trimLen("Kategori", in.Category, 100); err != nil {
		return err
	}
	if in.Notes, err = trimLen("Not", in.Notes, 1000); err != nil {
		return err
	}
	if in.MinStock != nil {
		v := roundQty(*in.MinStock)
		if v < 0 || v > inventoryMaxQuantity {
			return fmt.Errorf("%w: minimum stok", ErrInventoryInvalid)
		}
		in.MinStock = &v
	}
	if in.ShelfLifeMonths != nil && (*in.ShelfLifeMonths < 1 || *in.ShelfLifeMonths > 120) {
		return fmt.Errorf("%w: raf ömrü 1-120 ay arasında olmalı", ErrInventoryInvalid)
	}
	if in.ExpiryPolicy == "" {
		in.ExpiryPolicy = InventoryPolicyWarn
	}
	if in.ExpiryPolicy != InventoryPolicyWarn && in.ExpiryPolicy != InventoryPolicyBlock {
		return fmt.Errorf("%w: SKT davranışı", ErrInventoryInvalid)
	}
	if in.ExpiryAlertDays == nil {
		d := 30
		in.ExpiryAlertDays = &d
	}
	if *in.ExpiryAlertDays < 0 || *in.ExpiryAlertDays > 365 {
		return fmt.Errorf("%w: uyarı günü 0-365 arasında olmalı", ErrInventoryInvalid)
	}
	return nil
}

func (s *InventoryService) productRef(ctx context.Context, orgID pgtype.UUID, productID string) (pgtype.UUID, error) {
	pid, err := optUUID(productID)
	if err != nil {
		return pgtype.UUID{}, &NotFoundError{What: "ürün"}
	}
	if !pid.Valid {
		return pid, nil
	}
	if _, err := s.q.GetProductByID(ctx, sqlc.GetProductByIDParams{ID: pid, OrganizationID: orgID}); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return pgtype.UUID{}, &NotFoundError{What: "ürün"}
		}
		return pgtype.UUID{}, err
	}
	return pid, nil
}

func mapInventoryItemWriteErr(err error) error {
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && pgErr.Code == "23505" {
		if strings.Contains(pgErr.ConstraintName, "barcode") {
			return ErrInventoryDuplicateBarcode
		}
		return ErrInventoryDuplicateCode
	}
	return err
}

// CreateItem: yeni kart; kod boşsa STK-NNNN verilir.
func (s *InventoryService) CreateItem(ctx context.Context, organizationID string, in InventoryItemInput) (*InventoryItem, error) {
	orgID, err := s.org(organizationID)
	if err != nil {
		return nil, err
	}
	if err := validateInventoryItem(&in); err != nil {
		return nil, err
	}
	productID, err := s.productRef(ctx, orgID, in.ProductID)
	if err != nil {
		return nil, err
	}
	generated := in.Code == ""
	var row sqlc.InventoryItem
	for attempt := 0; attempt < 5; attempt++ {
		code := in.Code
		if generated {
			n, err := s.q.NextInventoryItemCodeNumber(ctx, orgID)
			if err != nil {
				return nil, err
			}
			code = fmt.Sprintf(inventoryItemCodeFormat, int(n)+attempt)
		}
		var minStock pgtype.Numeric
		if in.MinStock != nil {
			minStock = qtyNumeric(*in.MinStock)
		}
		row, err = s.q.CreateInventoryItem(ctx, sqlc.CreateInventoryItemParams{
			OrganizationID: orgID, Code: code, Name: in.Name, Barcode: in.Barcode, Unit: in.Unit,
			Category: in.Category, ProductID: productID, MinStock: minStock, TrackExpiry: in.TrackExpiry,
			ShelfLifeMonths: int32Ptr(in.ShelfLifeMonths), ExpiryPolicy: in.ExpiryPolicy,
			ExpiryAlertDays: int32(*in.ExpiryAlertDays), Notes: in.Notes, CreatedBy: actorUUID(in.UserID),
		})
		err = mapInventoryItemWriteErr(err)
		if err == nil || !generated || !errors.Is(err, ErrInventoryDuplicateCode) {
			break
		}
	}
	if err != nil {
		return nil, err
	}
	out := toInventoryItem(row)
	return &out, nil
}

// UpdateItem: kartı düzenler. Stoğu olan kart arşivlenemez.
func (s *InventoryService) UpdateItem(ctx context.Context, organizationID, itemID string, in InventoryItemInput) (*InventoryItem, error) {
	orgID, err := s.org(organizationID)
	if err != nil {
		return nil, err
	}
	iid, err := repository.StringToUUID(itemID)
	if err != nil {
		return nil, ErrInventoryItemNotFound
	}
	if err := validateInventoryItem(&in); err != nil {
		return nil, err
	}
	current, err := s.q.GetInventoryItem(ctx, sqlc.GetInventoryItemParams{ID: iid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrInventoryItemNotFound
		}
		return nil, err
	}
	if in.Code == "" {
		in.Code = current.Code
	}
	productID, err := s.productRef(ctx, orgID, in.ProductID)
	if err != nil {
		return nil, err
	}
	active := current.IsActive
	if in.IsActive != nil {
		active = *in.IsActive
	}
	if current.IsActive && !active {
		total, err := s.q.InventoryItemTotalQuantity(ctx, iid)
		if err != nil {
			return nil, err
		}
		if numF(total) > 0 {
			return nil, ErrInventoryItemHasStock
		}
	}
	var minStock pgtype.Numeric
	if in.MinStock != nil {
		minStock = qtyNumeric(*in.MinStock)
	}
	row, err := s.q.UpdateInventoryItem(ctx, sqlc.UpdateInventoryItemParams{
		Code: in.Code, Name: in.Name, Barcode: in.Barcode, Unit: in.Unit, Category: in.Category,
		ProductID: productID, MinStock: minStock, TrackExpiry: in.TrackExpiry,
		ShelfLifeMonths: int32Ptr(in.ShelfLifeMonths), ExpiryPolicy: in.ExpiryPolicy,
		ExpiryAlertDays: int32(*in.ExpiryAlertDays), Notes: in.Notes, IsActive: active,
		ID: iid, OrganizationID: orgID,
	})
	if err != nil {
		return nil, mapInventoryItemWriteErr(err)
	}
	out := toInventoryItem(row)
	return &out, nil
}

// ListItems: kartlar ve stok durumları (warehouseID boşsa bütün depolar).
func (s *InventoryService) ListItems(ctx context.Context, organizationID, warehouseID string, includeInactive bool) ([]InventoryItem, error) {
	orgID, err := s.org(organizationID)
	if err != nil {
		return nil, err
	}
	wid, err := optUUID(warehouseID)
	if err != nil {
		return nil, ErrInventoryWarehouseNotFound
	}
	rows, err := s.q.ListInventoryItems(ctx, sqlc.ListInventoryItemsParams{
		OrganizationID: orgID, IncludeInactive: includeInactive,
		Today: repository.TimeToDate(IstanbulToday()), WarehouseID: wid,
	})
	if err != nil {
		return nil, err
	}
	out := make([]InventoryItem, len(rows))
	for i, r := range rows {
		item := toInventoryItem(sqlc.InventoryItem{
			ID: r.ID, OrganizationID: r.OrganizationID, Code: r.Code, Name: r.Name, Barcode: r.Barcode,
			Unit: r.Unit, Category: r.Category, ProductID: r.ProductID, MinStock: r.MinStock,
			TrackExpiry: r.TrackExpiry, ShelfLifeMonths: r.ShelfLifeMonths, ExpiryPolicy: r.ExpiryPolicy,
			ExpiryAlertDays: r.ExpiryAlertDays, AvgUnitCost: r.AvgUnitCost, Notes: r.Notes,
			IsActive: r.IsActive, CreatedAt: r.CreatedAt,
		})
		item.Quantity = numF(r.Quantity)
		item.NearestExpiry = datePtr(r.NearestExpiry)
		item.ExpiredQuantity = numF(r.ExpiredQuantity)
		item.ExpiringQuantity = numF(r.ExpiringQuantity)
		out[i] = item
	}
	return out, nil
}

// GetItem: kart, depo/parti bakiyeleri ve malzemenin son fişleri.
func (s *InventoryService) GetItem(ctx context.Context, organizationID, itemID string) (*InventoryItemDetail, error) {
	orgID, err := s.org(organizationID)
	if err != nil {
		return nil, err
	}
	iid, err := repository.StringToUUID(itemID)
	if err != nil {
		return nil, ErrInventoryItemNotFound
	}
	row, err := s.q.GetInventoryItem(ctx, sqlc.GetInventoryItemParams{ID: iid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrInventoryItemNotFound
		}
		return nil, err
	}
	out := &InventoryItemDetail{Item: toInventoryItem(row)}
	bals, err := s.q.ListInventoryItemBalances(ctx, sqlc.ListInventoryItemBalancesParams{ItemID: iid, OrganizationID: orgID})
	if err != nil {
		return nil, err
	}
	today := IstanbulToday()
	for _, b := range bals {
		bal := InventoryBalance{
			WarehouseID: b.WarehouseID.String(), WarehouseName: b.WarehouseName, LotNo: b.LotNo,
			ExpiryDate: datePtr(b.ExpiryDate), ProductionDate: datePtr(b.ProductionDate), Quantity: numF(b.Quantity),
		}
		if b.LotID.Valid {
			bal.LotID = b.LotID.String()
		}
		out.Item.Quantity += bal.Quantity
		if bal.ExpiryDate != nil {
			if bal.ExpiryDate.Before(today) {
				out.Item.ExpiredQuantity += bal.Quantity
			} else if !bal.ExpiryDate.After(today.AddDate(0, 0, out.Item.ExpiryAlertDays)) {
				out.Item.ExpiringQuantity += bal.Quantity
			}
			if out.Item.NearestExpiry == nil || bal.ExpiryDate.Before(*out.Item.NearestExpiry) {
				t := *bal.ExpiryDate
				out.Item.NearestExpiry = &t
			}
		}
		out.Balances = append(out.Balances, bal)
	}
	docs, err := s.ListDocuments(ctx, organizationID, InventoryDocumentFilter{ItemID: itemID, Limit: 50})
	if err != nil {
		return nil, err
	}
	out.Documents = docs
	return out, nil
}

// FindItemByBarcode: barkod/QR okutunca kart.
func (s *InventoryService) FindItemByBarcode(ctx context.Context, organizationID, barcode string) (*InventoryItem, error) {
	orgID, err := s.org(organizationID)
	if err != nil {
		return nil, err
	}
	barcode = strings.TrimSpace(barcode)
	if barcode == "" {
		return nil, ErrInventoryItemNotFound
	}
	row, err := s.q.GetInventoryItemByBarcode(ctx, sqlc.GetInventoryItemByBarcodeParams{OrganizationID: orgID, Barcode: barcode})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrInventoryItemNotFound
		}
		return nil, err
	}
	out := toInventoryItem(row)
	return &out, nil
}

// Summary: menü başlığı ve Ana Sayfa için sayılar.
func (s *InventoryService) Summary(ctx context.Context, organizationID string) (*InventorySummary, error) {
	orgID, err := s.org(organizationID)
	if err != nil {
		return nil, err
	}
	r, err := s.q.InventorySummary(ctx, sqlc.InventorySummaryParams{OrgID: orgID, Today: repository.TimeToDate(IstanbulToday())})
	if err != nil {
		return nil, err
	}
	return &InventorySummary{
		ItemCount: int(r.ItemCount), StockValue: numF(r.StockValue), ExpiredLotCount: int(r.ExpiredLotCount),
		ExpiringLotCount: int(r.ExpiringLotCount), BelowMinCount: int(r.BelowMinCount),
	}, nil
}

// LotAlerts: SKT'si geçmiş ya da yaklaşan, bakiyesi olan partiler.
func (s *InventoryService) LotAlerts(ctx context.Context, organizationID string) ([]InventoryLotAlert, error) {
	orgID, err := s.org(organizationID)
	if err != nil {
		return nil, err
	}
	today := IstanbulToday()
	rows, err := s.q.ListInventoryLotAlerts(ctx, sqlc.ListInventoryLotAlertsParams{
		OrganizationID: orgID, Today: repository.TimeToDate(today),
	})
	if err != nil {
		return nil, err
	}
	out := make([]InventoryLotAlert, len(rows))
	for i, r := range rows {
		out[i] = InventoryLotAlert{
			ItemID: r.ItemID.String(), ItemCode: r.ItemCode, ItemName: r.ItemName, Unit: r.Unit,
			ExpiryPolicy: r.ExpiryPolicy, WarehouseID: r.WarehouseID.String(), WarehouseName: r.WarehouseName,
			LotID: r.LotID.String(), LotNo: r.LotNo, ExpiryDate: r.ExpiryDate.Time, Quantity: numF(r.Quantity),
			Expired: r.ExpiryDate.Time.Before(today),
		}
	}
	return out, nil
}

// WarehouseBalance: sayım ekranının satırı (depodaki bir malzeme/parti).
type WarehouseBalance struct {
	ItemID     string
	ItemCode   string
	ItemName   string
	Unit       string
	LotID      string
	LotNo      string
	ExpiryDate *time.Time
	Quantity   float64
}

// WarehouseBalances: deponun bakiyesi olan bütün malzeme/parti satırları.
func (s *InventoryService) WarehouseBalances(ctx context.Context, organizationID, warehouseID string) ([]WarehouseBalance, error) {
	orgID, err := s.org(organizationID)
	if err != nil {
		return nil, err
	}
	wid, err := repository.StringToUUID(warehouseID)
	if err != nil {
		return nil, ErrInventoryWarehouseNotFound
	}
	if _, err := s.q.GetInventoryWarehouse(ctx, sqlc.GetInventoryWarehouseParams{ID: wid, OrganizationID: orgID}); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrInventoryWarehouseNotFound
		}
		return nil, err
	}
	rows, err := s.q.ListInventoryWarehouseBalances(ctx, sqlc.ListInventoryWarehouseBalancesParams{WarehouseID: wid, OrganizationID: orgID})
	if err != nil {
		return nil, err
	}
	out := make([]WarehouseBalance, len(rows))
	for i, r := range rows {
		out[i] = WarehouseBalance{
			ItemID: r.ItemID.String(), ItemCode: r.ItemCode, ItemName: r.ItemName, Unit: r.Unit, LotNo: r.LotNo,
			ExpiryDate: datePtr(r.ExpiryDate), Quantity: numF(r.Quantity),
		}
		if r.LotID.Valid {
			out[i].LotID = r.LotID.String()
		}
	}
	return out, nil
}
