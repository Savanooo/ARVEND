-- name: CreateOfferEvent :one
INSERT INTO offer_events (organization_id, offer_id, revision_id, event_type, user_id, metadata, ip_address, user_agent)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
RETURNING *;

-- name: ListOfferEvents :many
SELECT * FROM offer_events WHERE offer_id = $1 AND organization_id = $2 ORDER BY created_at ASC;

-- name: OfferRevisionFirstOpenLogged :one
-- Müşterinin bu revizyonu karar beklerken İLK açışı zaten kaydedildi mi
-- (first_open işaretli customer_viewed, bkz. OfferService.recordCustomerView).
-- idx_offer_events_offer_id ile yalnızca teklifin kendi olayları taranır.
SELECT EXISTS (
    SELECT 1 FROM offer_events
    WHERE offer_id = $1 AND revision_id = $2 AND event_type = 'customer_viewed'
      AND metadata @> '{"first_open": true}'::jsonb
)::boolean AS logged;
