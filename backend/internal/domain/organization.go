package domain

import "time"

type Organization struct {
	ID        string
	Name      string
	Slug      string
	IsActive  bool
	CreatedAt time.Time
	UpdatedAt time.Time
}

// DefaultOrganizationID, mevcut tek-firmalı veri için 0009 migration'ında
// oluşturulan sabit organizasyon kimliğidir (seedAdmin ve tek seferlik
// araçlarda referans için).
const DefaultOrganizationID = "00000000-0000-0000-0000-000000000001"
