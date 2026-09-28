-- Ana sayfa özeti (GET /api/v1/dashboard) için yardımcı indeksler. Hepsi
-- salt-okur sorgulara yöneliktir, veri/şema davranışını DEĞİŞTİRMEZ;
-- IF NOT EXISTS ile tekrar çalıştırılabilir.

-- Son Hareketler: firmanın en yeni proje olayları (created_at DESC LIMIT 10).
CREATE INDEX IF NOT EXISTS idx_project_events_org_created
    ON project_events (organization_id, created_at DESC);

-- Son Hareketler: firmanın en yeni teklif olayları (created_at DESC LIMIT 10).
-- customer_viewed HARİÇ tutulur: her paylaşım linki açılışı (kimlik
-- doğrulamasız GET) bir satır yazar; müşteri görüntülemeleri teklif başına
-- ayrı sorguyla (idx_offer_events_offer_id) tekilleştirilir. Kısmi indeks
-- sayesinde sıralı tarama ilk 10 satırda durur ve görüntülenme satırlarının
-- üzerinden hiç geçmez (DashboardOfferActivity koşulu AYNEN içerir).
CREATE INDEX IF NOT EXISTS idx_offer_events_org_created_no_views
    ON offer_events (organization_id, created_at DESC)
    WHERE event_type <> 'customer_viewed';

-- Mesai: firmanın bugünkü ve bu ayki kayıtları.
CREATE INDEX IF NOT EXISTS idx_attendance_logs_org_date
    ON attendance_logs (organization_id, date);

-- Görevler: açık/gecikmiş/bugün sayıları.
CREATE INDEX IF NOT EXISTS idx_project_tasks_org_status_due
    ON project_tasks (organization_id, status, due_date);

-- Satın alma: onay bekleyen talepler.
CREATE INDEX IF NOT EXISTS idx_purchase_requests_org_status
    ON purchase_requests (organization_id, status);

-- Taşeron: onay bekleyen / onaylı hakedişler.
CREATE INDEX IF NOT EXISTS idx_subcontract_claims_org_status
    ON subcontract_progress_claims (organization_id, status);
