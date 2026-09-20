-- User ↔ Employee bağlantısı -- /tasks/mine'ın GERÇEK anlamı (giriş yapan
-- kişiye ATANAN görevler) için gerekli.
--
-- Denetim bulgusu: repo'da bugüne kadar login hesabı (users) ile personel
-- kaydı (employees) arasında HİÇBİR ilişki YOKTU -- migration 0034'ün
-- kendi yorumu bunu zaten belgeliyor ("project_members" employee_id'ye
-- bağlı ama users'la hiçbir ilişkisi yok). Bu yüzden mevcut
-- GET /tasks/mine, "bana ATANAN görevler" DEĞİL, "erişebildiğim
-- projelerdeki TÜM görevler" anlamına geliyordu (project_users üyeliği
-- üzerinden, assigned_employee_id'ye hiç bakmadan).
--
-- Bu migration EN KÜÇÜK güvenli çözümü uygular: employees.user_id,
-- nullable FK -> users.id. Mevcut employee/user kayıtları GEÇERLİ kalır
-- (hiçbiri otomatik/tahmin ile eşleştirilmez -- ad/e-posta/telefon
-- benzerliğine dayalı OTOMATİK eşleştirme KASITLI OLARAK YAPILMAZ, spec'in
-- açık talimatı). ON DELETE SET NULL -- bir kullanıcı silinirse personel
-- kaydı SİLİNMEZ, yalnızca bağlantısı kopar (employees'in KENDİSİ zaten
-- hard-delete edilmiyor, aynı "geçmişi koru" ilkesi).
ALTER TABLE employees ADD COLUMN user_id uuid REFERENCES users(id) ON DELETE SET NULL;

-- Bir kullanıcı hesabı EN FAZLA bir personel kaydına bağlanabilir
-- ("invalid duplicate active links" spec talebi) -- NULL değerler bu
-- kısıta tabi DEĞİLDİR (çoğu employee hâlâ bağlantısız kalacak).
CREATE UNIQUE INDEX idx_employees_user_id ON employees (user_id) WHERE user_id IS NOT NULL;

-- Savunma derinliği: bağlanan kullanıcı AYNI organizasyona ait olmalı
-- (spec: "same-organization validation mandatory") -- Sprint 4/5'teki
-- purchase_orders_check_consistency/project_subcontracts_check_consistency
-- İLE AYNI desen (Go seviyesinde de AYRICA doğrulanır, bkz. employee_
-- service.go).
CREATE FUNCTION employees_check_user_link_consistency() RETURNS trigger AS $$
DECLARE
    user_org uuid;
BEGIN
    IF NEW.user_id IS NOT NULL THEN
        SELECT organization_id INTO user_org FROM users WHERE id = NEW.user_id;
        IF user_org IS NULL OR user_org <> NEW.organization_id THEN
            RAISE EXCEPTION 'Personele bağlanan kullanıcı hesabı AYNI organizasyona ait olmalı';
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_employees_check_user_link_consistency
    BEFORE INSERT OR UPDATE ON employees
    FOR EACH ROW EXECUTE FUNCTION employees_check_user_link_consistency();
