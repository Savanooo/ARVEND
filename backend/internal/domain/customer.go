package domain

import "time"

type Customer struct {
	ID             string
	OrganizationID string
	Name           string
	Phone          string
	Email          string
	Address        string
	TaxOffice      string
	TaxNumber      string
	Notes          string
	IsActive       bool
	CreatedAt      time.Time
	UpdatedAt      time.Time
}
