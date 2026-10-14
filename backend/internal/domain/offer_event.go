package domain

import "time"

// Olay tipleri -- "Aktivite / Zaman Çizelgesi" bu değerler üzerinden
// Türkçe bir şablona çevrilir (frontend'de EVENT_LABELS sözlüğü).
const (
	EventOfferCreated     = "offer_created"
	EventOfferUpdated     = "offer_updated"
	EventRevisionCreated  = "revision_created"
	EventRevisionSent     = "revision_sent"
	EventShareLinkCreated = "share_link_created"
	EventShareLinkRevoked = "share_link_revoked"
	EventCustomerViewed   = "customer_viewed"
	EventCustomerAccepted = "customer_accepted"
	EventCustomerRejected = "customer_rejected"
	EventEmailSent        = "email_sent"
	EventEmailFailed      = "email_failed"
	EventOfferCancelled   = "offer_cancelled"
	// EventOfferReactivated, arşivdeki (pasif) teklif arşivden
	// çıkarıldığında yazılır; arşive giriş EventOfferCancelled'dır.
	EventOfferReactivated = "offer_reactivated"
	// EventProjectCreated, kabul edilen revizyon bir projeye
	// dönüştürüldüğünde teklifin zaman çizelgesine yazılır (bkz.
	// ProjectService.CreateFromOffer).
	EventProjectCreated = "project_created"
	// Silme talebi (migration 0067): silme izni olmayan kişi talep açar,
	// offers.delete sahibi reddeder ya da onaylar (onayda teklif silinir,
	// olay kaydı da onunla gider). Talep eden geri çekebilir.
	EventOfferDeleteRequested = "offer_delete_requested"
	EventOfferDeleteRejected  = "offer_delete_rejected"
	EventOfferDeleteWithdrawn = "offer_delete_withdrawn"
)

// OfferEvent, bir teklifle ilgili değişmez bir denetim (audit) kaydıdır.
// RevisionID, olay belirli bir revizyonla ilgiliyse doludur (örn.
// customer_viewed); UserID, olay iç bir kullanıcı eylemiyse doludur --
// müşterinin (public link üzerinden) eylemlerinde her ikisi de olabilir
// farklı kombinasyonlarda (RevisionID dolu, UserID boş).
type OfferEvent struct {
	ID             string
	OrganizationID string
	OfferID        string
	RevisionID     *string
	EventType      string
	UserID         *string
	Metadata       map[string]any
	IPAddress      string
	UserAgent      string
	CreatedAt      time.Time
}
