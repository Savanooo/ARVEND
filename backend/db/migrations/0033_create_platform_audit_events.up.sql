-- Platform seviyesinde hassas hareketlerin değişmez denetim kaydı --
-- offer_events/project_events ile AYNI desen (immutable-via-trigger, own
-- table, own FK'ler) ama farklı bir eksende: tek bir entity'ye değil,
-- Super Admin'in bir organization veya user üzerinde yaptığı platform
-- işlemlerine bağlı. Genel/paylaşılan bir audit_log tablosu YOK -- repo
-- genelinde böyle bir emsal bulunmadı (her domain kendi *_events tablosunu
-- kullanıyor), bu yüzden burada da o deseni tekrarlıyoruz.
--
-- actor_user_id: işlemi yapan Super Admin (nullable -- kullanıcı silinirse
-- kayıt kaybolmasın). target_organization_id/target_user_id: işlemin
-- hedefi (ikisi de nullable, action'a göre biri veya diğeri dolu olur).
-- Password/token/cookie/secret ASLA metadata'ya yazılmaz (bkz.
-- internal/service/platform_service.go -- audit metadata inşa eden kod).
CREATE TABLE platform_audit_events (
    id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    actor_user_id           uuid REFERENCES users(id) ON DELETE SET NULL,
    action                  varchar(50) NOT NULL,
    target_organization_id  uuid REFERENCES organizations(id) ON DELETE SET NULL,
    target_user_id          uuid REFERENCES users(id) ON DELETE SET NULL,
    metadata                jsonb NOT NULL DEFAULT '{}',
    created_at              timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_platform_audit_events_org ON platform_audit_events (target_organization_id, created_at DESC);
CREATE INDEX idx_platform_audit_events_actor ON platform_audit_events (actor_user_id, created_at DESC);

-- actor_user_id/target_organization_id/target_user_id, kullanıcı/organizasyon
-- silinirse ON DELETE SET NULL ile otomatik NULL'a düşer (kaydın kendisi
-- kaybolmasın diye) -- bu, veritabanının ürettiği MEŞRU bir UPDATE'tir ve
-- engellenmemeli. Yalnızca bir uygulama katmanının action/metadata/vb.
-- değiştirmeye çalıştığı GERÇEK bir mutasyon, ya da bir FK kolonunu NULL
-- DIŞINDA bir değere "diriltme" girişimi engellenir.
CREATE FUNCTION platform_audit_events_prevent_mutation() RETURNS trigger AS $$
BEGIN
    IF NEW.id = OLD.id
       AND NEW.action = OLD.action
       AND NEW.metadata = OLD.metadata
       AND NEW.created_at = OLD.created_at
       AND (NEW.actor_user_id IS NOT DISTINCT FROM OLD.actor_user_id OR NEW.actor_user_id IS NULL)
       AND (NEW.target_organization_id IS NOT DISTINCT FROM OLD.target_organization_id OR NEW.target_organization_id IS NULL)
       AND (NEW.target_user_id IS NOT DISTINCT FROM OLD.target_user_id OR NEW.target_user_id IS NULL)
    THEN
        RETURN NEW;
    END IF;
    RAISE EXCEPTION 'platform_audit_events kayıtları değiştirilemez veya silinemez (audit log immutable)';
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_platform_audit_events_no_update
    BEFORE UPDATE ON platform_audit_events
    FOR EACH ROW EXECUTE FUNCTION platform_audit_events_prevent_mutation();
