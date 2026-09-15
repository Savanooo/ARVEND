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

// Organization, User.OrganizationID nil olan (Super Admin) oturumlar için
// nil'dir -- web/mobil bunu "onboarding/must-change-password kontrolü
// uygulanamaz" anlamında okur.
type Session struct {
	User         domain.User
	Organization *domain.Organization
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
	org, err := s.loadOrgForAccess(ctx, user)
	if err != nil {
		return nil, err
	}
	session, err := s.issueSession(ctx, user, org)
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
	org, err := s.loadOrgForAccess(ctx, user)
	if err != nil {
		return nil, err
	}

	if err := s.q.RevokeRefreshToken(ctx, hash); err != nil {
		return nil, err
	}
	return s.issueSession(ctx, user, org)
}

func (s *AuthService) Logout(ctx context.Context, rawRefreshToken string) error {
	return s.q.RevokeRefreshToken(ctx, auth.HashRefreshToken(rawRefreshToken))
}

// Me, /auth/me için mevcut oturumun kullanıcısını VE (varsa) organizasyonunu
// döner -- web/mobil, her sayfa yüklemesinde must_change_password/onboarding
// durumunu buradan okur (ayrı bir round-trip yerine).
func (s *AuthService) Me(ctx context.Context, userID string) (*Session, error) {
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
	user := repository.ToDomainUser(row)
	var org *domain.Organization
	if user.OrganizationID != nil {
		orgUUID, err := repository.StringToUUID(*user.OrganizationID)
		if err != nil {
			return nil, err
		}
		orgRow, err := s.q.GetOrganizationByID(ctx, orgUUID)
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return nil, domain.ErrNotFound
			}
			return nil, err
		}
		o := repository.ToDomainOrganization(orgRow)
		org = &o
	}
	return &Session{User: user, Organization: org}, nil
}

// loadOrgForAccess, giriş/refresh anında kullanıcının organizasyonunu yükler
// ve status'unün erişime izin verip vermediğini kontrol eder (Super Admin'in
// organization_id'si nil olduğu için bu kontrolden muaftır ve nil, nil
// döner). Mid-session (zaten geçerli access token'la gelen istekler) için
// AYNI status kontrolü RequireAuth middleware'inde tekrarlanır -- burada
// olması yalnızca "askıya alınmış firma yeniden login/refresh olamaz"
// durumunu erken keser VE dönen Organization, issueSession'ın response'a
// koyacağı onboarding/plan bilgisini taşır.
func (s *AuthService) loadOrgForAccess(ctx context.Context, user domain.User) (*domain.Organization, error) {
	if user.OrganizationID == nil {
		return nil, nil
	}
	orgID, err := repository.StringToUUID(*user.OrganizationID)
	if err != nil {
		return nil, err
	}
	row, err := s.q.GetOrganizationByID(ctx, orgID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrOrganizationSuspended
		}
		return nil, err
	}
	org := repository.ToDomainOrganization(row)
	if !org.Status.AllowsAccess() {
		return nil, domain.ErrOrganizationSuspended
	}
	return &org, nil
}

func (s *AuthService) issueSession(ctx context.Context, user domain.User, org *domain.Organization) (*Session, error) {
	orgID := ""
	if user.OrganizationID != nil {
		orgID = *user.OrganizationID
	}
	access, err := s.jwt.IssueAccessToken(user.ID, user.Role, orgID)
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
	return &Session{User: user, Organization: org, AccessToken: access, RefreshToken: rawRefresh}, nil
}
