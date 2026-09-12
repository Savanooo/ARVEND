// Package repository, sqlc'nin ürettiği kodu (repository/sqlc) domain
// katmanına bağlar: pgx havuzunu kurar ve sqlc modellerini domain
// nesnelerine çevirir (pgtype.UUID/Timestamptz gibi veritabanı detaylarının
// servis/handler katmanına sızmaması için).
package repository

import (
	"context"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

func NewPool(ctx context.Context, databaseURL string) (*pgxpool.Pool, error) {
	return pgxpool.New(ctx, databaseURL)
}

func ToDomainUser(u sqlc.User) domain.User {
	du := domain.User{
		ID:           u.ID.String(),
		Username:     u.Username,
		PasswordHash: u.PasswordHash,
		FullName:     u.FullName,
		Role:         domain.Role(u.Role),
		IsActive:     u.IsActive,
		CreatedAt:    u.CreatedAt.Time,
		UpdatedAt:    u.UpdatedAt.Time,
	}
	if u.LastLoginAt.Valid {
		t := u.LastLoginAt.Time
		du.LastLoginAt = &t
	}
	return du
}

func StringToUUID(s string) (pgtype.UUID, error) {
	var id pgtype.UUID
	err := id.Scan(s)
	return id, err
}

func ToDomainProduct(p sqlc.Product) domain.Product {
	dp := domain.Product{
		ID:             p.ID.String(),
		Name:           p.Name,
		NormalizedName: p.NormalizedName,
		Unit:           p.Unit,
		UnitPrice:      NumericToFloat64(p.UnitPrice),
		Description:    p.Description,
		Category:       p.Category,
		CreatedAt:      p.CreatedAt.Time,
		UpdatedAt:      p.UpdatedAt.Time,
	}
	if p.Source != nil {
		dp.Source = *p.Source
	}
	if p.SourcePrice.Valid {
		v := NumericToFloat64(p.SourcePrice)
		dp.SourcePrice = &v
	}
	return dp
}

func NumericToFloat64(n pgtype.Numeric) float64 {
	f, err := n.Float64Value()
	if err != nil || !f.Valid {
		return 0
	}
	return f.Float64
}

func Float64ToNumeric(f float64) pgtype.Numeric {
	var n pgtype.Numeric
	_ = n.Scan(strconv.FormatFloat(f, 'f', 2, 64))
	return n
}

func ToDomainOffer(o sqlc.Offer) domain.Offer {
	do := domain.Offer{
		ID:              o.ID.String(),
		OfferNo:         o.OfferNo,
		CustomerName:    o.CustomerName,
		CustomerPhone:   o.CustomerPhone,
		CustomerEmail:   o.CustomerEmail,
		CustomerAddress: o.CustomerAddress,
		OfferDate:       o.OfferDate.Time,
		Subtotal:        NumericToFloat64(o.Subtotal),
		VatRate:         NumericToFloat64(o.VatRate),
		VatAmount:       NumericToFloat64(o.VatAmount),
		GrandTotal:      NumericToFloat64(o.GrandTotal),
		Notes:           o.Notes,
		Status:          o.Status,
		IsPassive:       o.IsPassive,
		CreatedAt:       o.CreatedAt.Time,
		UpdatedAt:       o.UpdatedAt.Time,
	}
	if o.ValidUntil.Valid {
		t := o.ValidUntil.Time
		do.ValidUntil = &t
	}
	if o.CreatedBy.Valid {
		s := o.CreatedBy.String()
		do.CreatedBy = &s
	}
	return do
}

func ToDomainOfferItem(i sqlc.OfferItem) domain.OfferItem {
	di := domain.OfferItem{
		ID:          i.ID.String(),
		ProductName: i.ProductName,
		Quantity:    NumericToFloat64(i.Quantity),
		UnitPrice:   NumericToFloat64(i.UnitPrice),
		LineTotal:   NumericToFloat64(i.LineTotal),
		SortOrder:   int(i.SortOrder),
	}
	if i.ProductID.Valid {
		s := i.ProductID.String()
		di.ProductID = &s
	}
	return di
}

func TimeToDate(t time.Time) pgtype.Date {
	return pgtype.Date{Time: t, Valid: true}
}
