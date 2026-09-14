package repository

import (
	"math/big"

	"github.com/jackc/pgx/v5/pgtype"
	"github.com/shopspring/decimal"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

// NumericToDecimal / DecimalToNumeric, pgtype.Numeric <-> decimal.Decimal
// arasında KAYIPSIZ dönüşüm yapar -- ikisi de aynı iç temsili kullanır
// (katsayı *big.Int + üs int32), bu yüzden ondalık bir sayının string'e
// yazılıp geri okunması gibi bir ara adım YOKTUR (bkz. internal/domain/calc.go
// paket yorumu). Geçersiz (NULL) numeric -> decimal.Zero.
func NumericToDecimal(n pgtype.Numeric) decimal.Decimal {
	if !n.Valid || n.Int == nil {
		return decimal.Zero
	}
	return decimal.NewFromBigInt(n.Int, n.Exp)
}

func DecimalToNumeric(d decimal.Decimal) pgtype.Numeric {
	return pgtype.Numeric{Int: new(big.Int).Set(d.Coefficient()), Exp: d.Exponent(), Valid: true}
}

// NumericToDecimalPtr / DecimalPtrToNumeric, nullable numeric kolonları
// (min_quantity, package_size) için -- NumericToFloat64Ptr ile aynı desen.
func NumericToDecimalPtr(n pgtype.Numeric) *decimal.Decimal {
	if !n.Valid {
		return nil
	}
	v := NumericToDecimal(n)
	return &v
}

func DecimalPtrToNumeric(d *decimal.Decimal) pgtype.Numeric {
	if d == nil {
		return pgtype.Numeric{}
	}
	return DecimalToNumeric(*d)
}

func ToDomainCalcGroup(g sqlc.CalcGroup) domain.CalcGroup {
	return domain.CalcGroup{
		ID:             g.ID.String(),
		OrganizationID: g.OrganizationID.String(),
		Slug:           g.Slug,
		Name:           g.Name,
		Description:    g.Description,
		SortOrder:      int(g.SortOrder),
		IsActive:       g.IsActive,
		CreatedAt:      g.CreatedAt.Time,
		UpdatedAt:      g.UpdatedAt.Time,
	}
}

func ToDomainCalcCategory(c sqlc.CalcCategory) domain.CalcCategory {
	dc := domain.CalcCategory{
		ID:             c.ID.String(),
		OrganizationID: c.OrganizationID.String(),
		GroupID:        c.GroupID.String(),
		Slug:           c.Slug,
		Name:           c.Name,
		Description:    c.Description,
		SortOrder:      int(c.SortOrder),
		IsActive:       c.IsActive,
		CreatedAt:      c.CreatedAt.Time,
		UpdatedAt:      c.UpdatedAt.Time,
	}
	if c.ImageFileID.Valid {
		s := c.ImageFileID.String()
		dc.ImageFileID = &s
	}
	return dc
}

// ToDomainCalcCategoryListRow, ListActiveCalcCategoriesForOrg'un JOIN'li
// satırını (kategori + grup slug/ad/sıra) domain nesnesine çevirir.
func ToDomainCalcCategoryListRow(r sqlc.ListActiveCalcCategoriesForOrgRow) domain.CalcCategory {
	dc := ToDomainCalcCategory(sqlc.CalcCategory{
		ID: r.ID, OrganizationID: r.OrganizationID, GroupID: r.GroupID, Slug: r.Slug,
		Name: r.Name, Description: r.Description, ImageFileID: r.ImageFileID,
		SortOrder: r.SortOrder, IsActive: r.IsActive, CreatedAt: r.CreatedAt, UpdatedAt: r.UpdatedAt,
	})
	dc.GroupSlug = r.GroupSlug
	dc.GroupLabel = r.GroupNameLabel
	dc.GroupSortOrder = int(r.GroupSortOrder)
	return dc
}

func ToDomainCalcRecipeItem(i sqlc.CalcRecipeItem) domain.CalcRecipeItem {
	di := domain.CalcRecipeItem{
		ID:                 i.ID.String(),
		OrganizationID:     i.OrganizationID.String(),
		CategoryID:         i.CategoryID.String(),
		MaterialName:       i.MaterialName,
		Unit:               i.Unit,
		CalculationType:    i.CalculationType,
		QuantityPerM2:      NumericToDecimal(i.QuantityPerM2),
		QuantityPerMeter:   NumericToDecimal(i.QuantityPerMeter),
		FixedQuantity:      NumericToDecimal(i.FixedQuantity),
		WastePercent:       NumericToDecimal(i.WastePercent),
		RoundingType:       i.RoundingType,
		MinQuantity:        NumericToDecimalPtr(i.MinQuantity),
		PackageSize:        NumericToDecimalPtr(i.PackageSize),
		ReferenceUnitPrice: NumericToDecimal(i.ReferenceUnitPrice),
		GroupName:          i.GroupName,
		SortOrder:          int(i.SortOrder),
		IsActive:           i.IsActive,
		Notes:              i.Notes,
		CreatedAt:          i.CreatedAt.Time,
		UpdatedAt:          i.UpdatedAt.Time,
	}
	if i.ProductID.Valid {
		s := i.ProductID.String()
		di.ProductID = &s
	}
	return di
}
