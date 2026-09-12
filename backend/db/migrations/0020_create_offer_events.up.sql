-- offer_events, bir teklifin başından sonuna tüm önemli olaylarının
-- değişmez (immutable) denetim (audit) kaydıdır -- "Aktivite / Zaman
-- Çizelgesi" bu tablodan okunur, görüntülenme istatistikleri (ilk/son/
-- toplam) bu tablodaki customer_viewed satırlarından aggregate edilir.
-- revision_id NULL olabilir (örn. offer_cancelled gibi revizyondan bağımsız
-- olaylar için); user_id NULL olabilir (public/müşteri olayları için --
-- müşterinin sistemde bir kullanıcı kaydı yoktur).
--
-- Kayıtlar normal uygulama akışından ASLA update edilmez -- bunu yalnızca
-- bir yorumla değil, aşağıdaki trigger'la veritabanı seviyesinde de
-- zorunlu kılıyoruz. DELETE bilinçli olarak engellenmez: tek silinme yolu
-- offer_id ON DELETE CASCADE'dir (teklifin kendisi tamamen silinirken tüm
-- geçmişiyle birlikte gider, ki bu offer_revisions/offer_share_links için
-- de zaten geçerli tutarlı bir davranıştır) -- uygulama hiçbir zaman
-- doğrudan bu tablodan DELETE çalıştırmaz.
CREATE TABLE offer_events (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES organizations(id),
    offer_id        uuid NOT NULL REFERENCES offers(id) ON DELETE CASCADE,
    revision_id     uuid REFERENCES offer_revisions(id) ON DELETE SET NULL,
    event_type      varchar(40) NOT NULL,
    user_id         uuid REFERENCES users(id) ON DELETE SET NULL,
    metadata        jsonb NOT NULL DEFAULT '{}',
    ip_address      varchar(45) NOT NULL DEFAULT '',
    user_agent      varchar(500) NOT NULL DEFAULT '',
    created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_offer_events_offer_id ON offer_events (offer_id, created_at DESC);
CREATE INDEX idx_offer_events_organization_id ON offer_events (organization_id);

CREATE FUNCTION offer_events_prevent_mutation() RETURNS trigger AS $$
BEGIN
    RAISE EXCEPTION 'offer_events kayıtları değiştirilemez veya silinemez (audit log immutable)';
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_offer_events_no_update
    BEFORE UPDATE ON offer_events
    FOR EACH ROW EXECUTE FUNCTION offer_events_prevent_mutation();
