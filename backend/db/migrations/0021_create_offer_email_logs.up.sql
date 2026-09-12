-- offer_email_logs, bir tekliften gönderilen HER e-postanın (başarılı ya da
-- başarısız) kaydını tutar. share_link_id NOT NULL'dur -- "e-mail her zaman
-- belirli bir revizyonun paylaşım linkini içersin" kuralı gereği, mail
-- gönderiminden önce servis katmanı o revizyon için aktif bir link bulur ya
-- da oluşturur (bkz. OfferService.SendOfferEmail); bu yüzden loglanan her
-- mailin hangi linkle/revizyonla gönderildiği her zaman bellidir.
CREATE TABLE offer_email_logs (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES organizations(id),
    offer_id        uuid NOT NULL REFERENCES offers(id) ON DELETE CASCADE,
    revision_id     uuid NOT NULL REFERENCES offer_revisions(id) ON DELETE CASCADE,
    share_link_id   uuid NOT NULL REFERENCES offer_share_links(id),
    recipient       varchar(255) NOT NULL,
    subject         varchar(300) NOT NULL,
    status          varchar(20) NOT NULL CHECK (status IN ('sent', 'failed')),
    error_message   text NOT NULL DEFAULT '',
    sent_by         uuid REFERENCES users(id) ON DELETE SET NULL,
    sent_at         timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_offer_email_logs_offer_id ON offer_email_logs (offer_id);
CREATE INDEX idx_offer_email_logs_organization_id ON offer_email_logs (organization_id);
