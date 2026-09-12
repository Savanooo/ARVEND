package domain

import "time"

// OfferShareLink, müşteriye gönderilen tek bir paylaşım bağlantısıdır --
// her zaman belirli bir RevisionID'ye bağlıdır (bkz. offer.go'daki
// Offer/OfferRevision ayrımı). Bir teklifin ömrü boyunca birden fazla
// bağlantısı olabilir (her "Revize Et" + gönderim için ayrı).
type OfferShareLink struct {
	ID             string
	OrganizationID string
	OfferID        string
	RevisionID     string
	Token          string
	CreatedBy      *string
	CreatedAt      time.Time
	ExpiresAt      *time.Time
	RevokedAt      *time.Time
}

// IsActive, bağlantının hâlâ görüntüleme/karar için kullanılabilir olup
// olmadığını söyler -- iptal edilmiş ya da süresi dolmuş bir bağlantı
// artık aktif değildir.
func (l OfferShareLink) IsActive(now time.Time) bool {
	if l.RevokedAt != nil {
		return false
	}
	if l.ExpiresAt != nil && now.After(*l.ExpiresAt) {
		return false
	}
	return true
}
