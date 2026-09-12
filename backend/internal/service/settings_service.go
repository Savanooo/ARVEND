package service

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/platform/crypto"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

type SettingsService struct {
	q   *sqlc.Queries
	box *crypto.SecretBox
}

func NewSettingsService(q *sqlc.Queries, box *crypto.SecretBox) *SettingsService {
	return &SettingsService{q: q, box: box}
}

// GetSmtp, gönderim için gereken çözülmüş (plaintext) şifreyle birlikte
// ayarları döner -- bu değer asla HTTP response'a yazılmamalı, sadece mail
// gönderiminde kullanılmalı.
func (s *SettingsService) GetSmtp(ctx context.Context, organizationID string) (*domain.SmtpSettings, error) {
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	row, err := s.q.GetSmtpSettings(ctx, orgID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return &domain.SmtpSettings{OrganizationID: organizationID}, nil
		}
		return nil, err
	}
	password := ""
	if row.PasswordEnc != "" {
		password, err = s.box.Decrypt(row.PasswordEnc)
		if err != nil {
			return nil, err
		}
	}
	return &domain.SmtpSettings{
		OrganizationID: organizationID,
		Host:           row.Host,
		Port:           int(row.Port),
		Username:       row.Username,
		Password:       password,
		PasswordSet:    row.PasswordEnc != "",
		FromEmail:      row.FromEmail,
		FromName:       row.FromName,
		UseTLS:         row.UseTls,
		Configured:     row.Host != "" && row.FromEmail != "",
	}, nil
}

type UpdateSmtpInput struct {
	Host      string
	Port      int
	Username  string
	Password  *string // nil = mevcut şifre korunur
	FromEmail string
	FromName  string
	UseTLS    bool
}

func (s *SettingsService) UpdateSmtp(ctx context.Context, organizationID string, in UpdateSmtpInput) (*domain.SmtpSettings, error) {
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	passwordEnc := ""
	if in.Password != nil && *in.Password != "" {
		enc, err := s.box.Encrypt(*in.Password)
		if err != nil {
			return nil, err
		}
		passwordEnc = enc
	} else {
		existing, err := s.q.GetSmtpSettings(ctx, orgID)
		if err == nil {
			passwordEnc = existing.PasswordEnc
		} else if !errors.Is(err, pgx.ErrNoRows) {
			return nil, err
		}
	}

	row, err := s.q.UpsertSmtpSettings(ctx, sqlc.UpsertSmtpSettingsParams{
		OrganizationID: orgID,
		Host:           in.Host,
		Port:           int32(in.Port),
		Username:       in.Username,
		PasswordEnc:    passwordEnc,
		FromEmail:      in.FromEmail,
		FromName:       in.FromName,
		UseTls:         in.UseTLS,
	})
	if err != nil {
		return nil, err
	}
	return &domain.SmtpSettings{
		OrganizationID: organizationID,
		Host:           row.Host,
		Port:           int(row.Port),
		Username:       row.Username,
		PasswordSet:    row.PasswordEnc != "",
		FromEmail:      row.FromEmail,
		FromName:       row.FromName,
		UseTLS:         row.UseTls,
		Configured:     row.Host != "" && row.FromEmail != "",
	}, nil
}
