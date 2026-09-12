-- offer_share_links, müşteriye gönderilen her paylaşım bağlantısını AYRI
-- bir kayıt olarak tutar ve daima belirli bir revision_id'ye bağlanır --
-- eskiden offers.share_token tekliflik başına TEK bir bağlantı tutuyordu,
-- bu da "Revize Et" sonrası hangi revizyonun gösterildiğini/karar
-- verilebildiğini ayırt etmeyi imkansız kılıyordu (bkz. 0020 için
-- customer_viewed/customer_accepted event'leri, 0021 için mail logları).
-- Bir bağlantı iptal edilmiş (revoked_at) veya süresi dolmuşsa (expires_at)
-- artık ne görüntülenebilir ne de karar verilebilir -- bkz. servis
-- katmanındaki resolveActiveShareLink.
CREATE TABLE offer_share_links (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES organizations(id),
    offer_id        uuid NOT NULL REFERENCES offers(id) ON DELETE CASCADE,
    revision_id     uuid NOT NULL REFERENCES offer_revisions(id) ON DELETE CASCADE,
    token           uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
    created_by      uuid REFERENCES users(id) ON DELETE SET NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    expires_at      timestamptz,
    revoked_at      timestamptz
);

CREATE INDEX idx_offer_share_links_offer_id ON offer_share_links (offer_id);
CREATE INDEX idx_offer_share_links_revision_id ON offer_share_links (revision_id);
CREATE INDEX idx_offer_share_links_organization_id ON offer_share_links (organization_id);
