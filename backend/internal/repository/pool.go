// Package repository, sqlc'nin ürettiği kodu (repository/sqlc) domain
// katmanına bağlar: pgx havuzunu kurar ve sqlc modellerini domain
// nesnelerine çevirir (pgtype.UUID/Timestamptz gibi veritabanı detaylarının
// servis/handler katmanına sızmaması için).
package repository

import (
	"context"

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
