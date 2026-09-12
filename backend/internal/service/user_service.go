package service

import (
	"context"
	"errors"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/Savanooo/ARVEND/backend/internal/auth"
	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

type UserService struct {
	q *sqlc.Queries
}

func NewUserService(q *sqlc.Queries) *UserService {
	return &UserService{q: q}
}

type ListResult struct {
	Users []domain.User
	Total int64
}

func (s *UserService) List(ctx context.Context, page, limit int) (*ListResult, error) {
	if limit <= 0 || limit > 100 {
		limit = 20
	}
	if page <= 0 {
		page = 1
	}
	rows, err := s.q.ListUsers(ctx, sqlc.ListUsersParams{
		Limit:  int32(limit),
		Offset: int32((page - 1) * limit),
	})
	if err != nil {
		return nil, err
	}
	total, err := s.q.CountUsers(ctx)
	if err != nil {
		return nil, err
	}
	users := make([]domain.User, len(rows))
	for i, r := range rows {
		users[i] = repository.ToDomainUser(r)
	}
	return &ListResult{Users: users, Total: total}, nil
}

func (s *UserService) Get(ctx context.Context, id string) (*domain.User, error) {
	uid, err := repository.StringToUUID(id)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	row, err := s.q.GetUserByID(ctx, uid)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	u := repository.ToDomainUser(row)
	return &u, nil
}

func (s *UserService) Create(ctx context.Context, username, password, fullName string, role domain.Role) (*domain.User, error) {
	username = strings.TrimSpace(username)
	if username == "" || password == "" || strings.TrimSpace(fullName) == "" {
		return nil, errors.New("kullanıcı adı, şifre ve ad soyad zorunludur")
	}
	if !role.Valid() {
		role = domain.RoleKullanici
	}
	hash, err := auth.HashPassword(password)
	if err != nil {
		return nil, err
	}
	row, err := s.q.CreateUser(ctx, sqlc.CreateUserParams{
		Username:     username,
		PasswordHash: hash,
		FullName:     strings.TrimSpace(fullName),
		Role:         string(role),
	})
	if err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" { // unique_violation
			return nil, domain.ErrDuplicateUsername
		}
		return nil, err
	}
	u := repository.ToDomainUser(row)
	return &u, nil
}

func (s *UserService) Update(ctx context.Context, id, fullName string, role domain.Role, isActive bool) (*domain.User, error) {
	uid, err := repository.StringToUUID(id)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	if !role.Valid() {
		return nil, errors.New("geçersiz rol")
	}
	row, err := s.q.UpdateUser(ctx, sqlc.UpdateUserParams{
		ID:       uid,
		FullName: strings.TrimSpace(fullName),
		Role:     string(role),
		IsActive: isActive,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	u := repository.ToDomainUser(row)
	return &u, nil
}

// ChangeOwnPassword, kullanıcının kendi şifresini değiştirmesi için mevcut
// şifreyi doğrular (admin resetinden farkı budur).
func (s *UserService) ChangeOwnPassword(ctx context.Context, id, currentPassword, newPassword string) error {
	uid, err := repository.StringToUUID(id)
	if err != nil {
		return domain.ErrNotFound
	}
	row, err := s.q.GetUserByID(ctx, uid)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return domain.ErrNotFound
		}
		return err
	}
	if !auth.CheckPassword(row.PasswordHash, currentPassword) {
		return domain.ErrInvalidCredentials
	}
	return s.setPassword(ctx, uid, newPassword)
}

// AdminResetPassword, mevcut şifre istemeden bir kullanıcının şifresini
// değiştirir — yalnız RequireRole("admin") arkasında çağrılmalıdır.
func (s *UserService) AdminResetPassword(ctx context.Context, id, newPassword string) error {
	uid, err := repository.StringToUUID(id)
	if err != nil {
		return domain.ErrNotFound
	}
	return s.setPassword(ctx, uid, newPassword)
}

func (s *UserService) setPassword(ctx context.Context, uid pgtype.UUID, newPassword string) error {
	if len(newPassword) < 8 {
		return errors.New("yeni şifre en az 8 karakter olmalı")
	}
	hash, err := auth.HashPassword(newPassword)
	if err != nil {
		return err
	}
	return s.q.UpdateUserPassword(ctx, sqlc.UpdateUserPasswordParams{ID: uid, PasswordHash: hash})
}

func (s *UserService) Deactivate(ctx context.Context, id string) error {
	uid, err := repository.StringToUUID(id)
	if err != nil {
		return domain.ErrNotFound
	}
	return s.q.DeactivateUser(ctx, uid)
}
