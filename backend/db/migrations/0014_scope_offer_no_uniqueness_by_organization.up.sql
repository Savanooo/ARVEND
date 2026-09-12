-- offer_no artık firma+yıl bazlı bağımsız sayaçtan üretiliyor (0013), bu
-- yüzden iki farklı firma aynı "TKF-2026-0001" değerine sahip olabilir --
-- eski global UNIQUE kısıtı bunu engelliyordu. Benzersizlik artık
-- (organization_id, offer_no) çiftinde.
ALTER TABLE offers DROP CONSTRAINT offers_offer_no_key;
ALTER TABLE offers ADD CONSTRAINT offers_organization_id_offer_no_key UNIQUE (organization_id, offer_no);
