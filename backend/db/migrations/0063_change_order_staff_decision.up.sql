-- Ek işte müşteri kararını personelin kaydetmesi (ürün sahibi kararı,
-- 2026-10-07).
--
-- Ek işin 'approved' olmasının tek yolu müşterinin paylaşım linkiydi;
-- telefonla/kâğıt üzerinde onaylanan bir ek iş hiçbir zaman sözleşme
-- bedeline yansımıyordu. Personel artık gönderilmiş bir ek işi "Müşteri
-- onayladı/reddetti" olarak işaretleyebilir -- paylaşım linkiyle AYNI kod
-- yolundan geçer (bkz. project_change_order_service.go
-- applyChangeOrderDecision), yalnızca kimin işaretlediği ve isteğe bağlı
-- bir not ("telefonla onay") ayrıca saklanır. Ne zaman: mevcut
-- responded_at/approved_at/rejected_at.
--
-- decision_recorded_by NULL = karar müşterinin kendi linkinden geldi (ya da
-- henüz karar yok). Mevcut satırlara dokunulmaz: eklenen iki kolon da
-- boş/varsayılan değerle gelir (PG11+ DEFAULT'lu ADD COLUMN tabloyu yeniden
-- yazmaz).
ALTER TABLE project_change_orders
    ADD COLUMN decision_recorded_by uuid REFERENCES users(id) ON DELETE SET NULL,
    ADD COLUMN decision_note varchar(500) NOT NULL DEFAULT '';

-- İzin: finance.manage'den AYRI -- ek işi hazırlayıp gönderebilen herkes
-- müşteri adına "onayladı" diyememeli (sözleşme bedelini doğrudan değiştirir).
-- Varsayılan: Sahip + Yönetici. seed_system_roles_for_org bu ikisine zaten
-- "SELECT code FROM permissions" ile her izni verdiği için yeni firmalar
-- kendiliğinden alır; fonksiyonu yeniden tanımlamaya gerek YOK (0048 ile
-- aynı durum).
INSERT INTO permissions (code, description, category) VALUES
    ('projects.change_orders.approve', 'Ek işte müşteri onayını/reddini kaydetme (telefon/yazılı onay)', 'Finans')
ON CONFLICT (code) DO NOTHING;

INSERT INTO role_permissions (organization_role_id, permission_code)
SELECT orole.id, 'projects.change_orders.approve'
FROM organization_roles orole
WHERE orole.is_system AND orole.code IN ('owner', 'admin')
ON CONFLICT (organization_role_id, permission_code) DO NOTHING;
