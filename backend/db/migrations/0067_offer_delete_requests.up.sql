-- Teklif silme talebi (2026-10, ürün sahibinin kararı): "Yönetici direkt
-- silebilir ama alt roller silince onaya düşsün". offers.delete taşıyan
-- (Sahip, Yönetici, Kullanıcı (Eski Sistem)) bugünkü gibi direkt siler;
-- teklifi düzenleyebilen/oluşturabilen ama silme izni olmayan kişi silme
-- talebi açar, offers.delete sahibi onaylar (teklif silinir) ya da reddeder.
--
-- Onaylanan talep satırı teklifle birlikte gider (ON DELETE CASCADE):
-- teklifin kendisi kalıcı olarak silinir, ayrıca saklanacak bir şey yok.
-- Kalıcı durumlar yalnızca pending | rejected | withdrawn. Bir teklifte aynı
-- anda tek bekleyen talep olur.
CREATE TABLE offer_delete_requests (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid NOT NULL REFERENCES organizations(id),
    offer_id         uuid NOT NULL REFERENCES offers(id) ON DELETE CASCADE,
    requested_by     uuid REFERENCES users(id) ON DELETE SET NULL,
    reason           varchar(500) NOT NULL DEFAULT '',
    status           varchar(20) NOT NULL DEFAULT 'pending'
                     CHECK (status IN ('pending', 'rejected', 'withdrawn')),
    decided_by       uuid REFERENCES users(id) ON DELETE SET NULL,
    decided_at       timestamptz,
    decision_note    varchar(500) NOT NULL DEFAULT '',
    created_at       timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX offer_delete_requests_one_pending
    ON offer_delete_requests (offer_id) WHERE status = 'pending';
CREATE INDEX idx_offer_delete_requests_org_pending
    ON offer_delete_requests (organization_id, created_at) WHERE status = 'pending';
