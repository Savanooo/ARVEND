-- name: GetOrganizationProfile :one
SELECT * FROM organization_profile WHERE organization_id = $1;

-- name: UpsertOrganizationProfile :one
INSERT INTO organization_profile (
    organization_id, authorized_person, phone, email, website, logo_object_key,
    legal_name, tax_office, tax_number, invoice_address, city, district, country, business_type
) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14)
ON CONFLICT (organization_id) DO UPDATE SET
    authorized_person = $2, phone = $3, email = $4, website = $5, logo_object_key = $6,
    legal_name = $7, tax_office = $8, tax_number = $9, invoice_address = $10,
    city = $11, district = $12, country = $13, business_type = $14
RETURNING *;

-- name: GetOrganizationCommercialSettings :one
SELECT * FROM organization_commercial_settings WHERE organization_id = $1;

-- name: UpsertOrganizationCommercialSettings :one
INSERT INTO organization_commercial_settings (
    organization_id, default_currency, default_vat_rate, offer_prefix, offer_validity_days,
    default_offer_footer, default_payment_terms, default_delivery_terms,
    bank_name, account_holder, iban_enc, payment_due_days
) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)
ON CONFLICT (organization_id) DO UPDATE SET
    default_currency = $2, default_vat_rate = $3, offer_prefix = $4, offer_validity_days = $5,
    default_offer_footer = $6, default_payment_terms = $7, default_delivery_terms = $8,
    bank_name = $9, account_holder = $10, iban_enc = $11, payment_due_days = $12
RETURNING *;

-- name: GetOfferPrefix :one
-- generateOfferNo'nun kullandığı hafif sorgu -- satır yoksa sqlc.ErrNoRows,
-- servis katmanı bunu "TKF" varsayılanına düşürür.
SELECT offer_prefix FROM organization_commercial_settings WHERE organization_id = $1;
