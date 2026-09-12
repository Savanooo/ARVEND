package service

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/Savanooo/ARVEND/backend/internal/auth"
	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

type AuthService struct {
	q          *sqlc.Queries
	jwt        *auth.JWTIssuer
	refreshTTL time.Duration
}

func NewAuthService(q *sqlc.Queries, jwt *auth.JWTIssuer, refreshTTL time.Duration) *AuthService {
	return &AuthService{q: q, jwt: jwt, refreshTTL: refreshTTL}
}

type Session struct {
	User         domain.User
	AccessToken  string
	RefreshToken string
}

// Login, kullanıcı adı/şifreyi doğrular ve yeni bir oturum (access + refresh
// token çifti) üretir. Pasif kullanıcılar giriş yapamaz.
func (s *AuthService) Login(ctx context.Context, username, password string) (*Session, error) {
	row, err := s.q.GetUserByUsername(ctx, username)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrInvalidCredentials
		}
		return nil, err
	}
	if !auth.CheckPassword(row.PasswordHash, password) {
		return nil, domain.ErrInvalidCredentials
	}
	if !row.IsActive {
		return nil, domain.ErrInactiveUser
	}

	user := repository.ToDomainUser(row)
	session, err := s.issueSession(ctx, user)
	if err != nil {
		return nil, err
	}
	_ = s.q.TouchLastLogin(ctx, row.ID)
	return session, nil
}

// Refresh, geçerli bir refresh token karşılığında yeni bir çift üretir ve
// eskisini iptal eder (rotasyon — çalınmış bir refresh token'ın tekrar
// kullanılmasını zorlaştırır).
func (s *AuthService) Refresh(ctx context.Context, rawRefreshToken string) (*Session, error) {
	hash := auth.HashRefreshToken(rawRefreshToken)
	rt, err := s.q.GetValidRefreshToken(ctx, hash)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrInvalidToken
		}
		return nil, err
	}

	userRow, err := s.q.GetUserByID(ctx, rt.UserID)
	if err != nil {
		return nil, domain.ErrInvalidToken
	}
	user := repository.ToDomainUser(userRow)
	if !user.IsActive {
		return nil, domain.ErrInactiveUser
	}

	if err := s.q.RevokeRefreshToken(ctx, hash); err != nil {
		return nil, err
	}
	return s.issueSession(ctx, user)
}

func (s *AuthService) Logout(ctx context.Context, rawRefreshToken string) error {
	return s.q.RevokeRefreshToken(ctx, auth.HashRefreshToken(rawRefreshToken))
}

func (s *AuthService) Me(ctx context.Context, userID string) (*domain.User, error) {
	id, err := repository.StringToUUID(userID)
	if err != nil {
		return nil, domain.ErrInvalidToken
	}
	row, err := s.q.GetUserByID(ctx, id)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	u := repository.ToDomainUser(row)
	return &u, nil
}

func (s *AuthService) issueSession(ctx context.Context, user domain.User) (*Session, error) {
	access, err := s.jwt.IssueAccessToken(user.ID, user.Role, user.OrganizationID)
	if err != nil {
		return nil, err
	}
	rawRefresh, hash, err := auth.NewRefreshToken()
	if err != nil {
		return nil, err
	}
	uid, err := repository.StringToUUID(user.ID)
	if err != nil {
		return nil, err
	}
	if _, err := s.q.CreateRefreshToken(ctx, sqlc.CreateRefreshTokenParams{
		UserID:    uid,
		TokenHash: hash,
		ExpiresAt: pgTimestamptz(time.Now().Add(s.refreshTTL)),
	}); err != nil {
		return nil, err
	}
	return &Session{User: user, AccessToken: access, RefreshToken: rawRefresh}, nil
}
