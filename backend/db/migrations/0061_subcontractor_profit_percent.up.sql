-- Taşeron kâr payı: taşerona ödenen sözleşme bedelinin üstüne müşteriye
-- yansıtılan yüzde (ürün sahibi kararı, 2026-10-06). Boş = girilmemiş.
-- Müşteriye yansıyan tutar ve kârımız bu yüzdeden hesaplanır, saklanmaz.
ALTER TABLE project_subcontractors
    ADD COLUMN profit_percent numeric(6,2)
        CHECK (profit_percent IS NULL OR (profit_percent >= 0 AND profit_percent <= 1000));
