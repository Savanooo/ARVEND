package domain

import "time"

const (
	EmailLogStatusSent   = "sent"
	EmailLogStatusFailed = "failed"
)

// OfferEmailLog, bir tekliften gönderilmeye çalışılan HER e-postanın
// (başarılı ya da başarısız) kalıcı kaydıdır.
type OfferEmailLog struct {
	ID             string
	OrganizationID string
	OfferID        string
	RevisionID     string
	ShareLinkID    string
	Recipient      string
	Subject        string
	Status         string
	ErrorMessage   string
	SentBy         *string
	SentAt         time.Time
}
