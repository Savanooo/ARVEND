DROP INDEX idx_sub_payments_idempotency;
CREATE UNIQUE INDEX idx_sub_payments_idempotency
    ON project_subcontractor_payments (project_id, idempotency_key)
    WHERE idempotency_key IS NOT NULL;

DROP INDEX idx_expenses_idempotency;
ALTER TABLE project_expenses DROP COLUMN idempotency_key;

-- ÜRETİM GERİ ALMA NOTU: aşağıdaki daraltmalar (numeric(18,2) ->
-- numeric(12,2)) yalnızca TEMİZ/boş bir veritabanında güvenlidir. Var
-- olan herhangi bir satır ±9.999.999.999,99 sınırını AŞIYORSA Postgres bu
-- ALTER'ı "numeric field overflow" hatasıyla REDDEDER -- bu kasıtlıdır,
-- veri sessizce kırpılmaz. Böyle bir durumda bu down migration'ı
-- production'da ÇALIŞTIRMAYIN: doğru geri alma stratejisi bu migration'ı
-- ters çevirmek değil, sorunlu satırları önce elle/forward-fix ile
-- düzeltmek ya da genişletilmiş hâliyle devam etmektir.
ALTER TABLE project_invoices ALTER COLUMN amount TYPE numeric(12, 2);
ALTER TABLE project_subcontractor_payments ALTER COLUMN amount TYPE numeric(12, 2);
ALTER TABLE project_subcontractors ALTER COLUMN contract_amount TYPE numeric(12, 2);
ALTER TABLE project_expenses ALTER COLUMN amount TYPE numeric(12, 2);
ALTER TABLE project_collections ALTER COLUMN amount TYPE numeric(12, 2);
ALTER TABLE project_payment_plan_items ALTER COLUMN planned_amount TYPE numeric(12, 2);

ALTER TABLE projects ALTER COLUMN contract_amount TYPE numeric(12, 2);

ALTER TABLE offer_revision_items ALTER COLUMN line_total TYPE numeric(12, 2);
ALTER TABLE offer_revision_items ALTER COLUMN discount_value TYPE numeric(12, 2);
ALTER TABLE offer_revision_items ALTER COLUMN unit_price TYPE numeric(12, 2);
ALTER TABLE offer_revisions ALTER COLUMN grand_total TYPE numeric(12, 2);
ALTER TABLE offer_revisions ALTER COLUMN vat_amount TYPE numeric(12, 2);
ALTER TABLE offer_revisions ALTER COLUMN discount_amount TYPE numeric(12, 2);
ALTER TABLE offer_revisions ALTER COLUMN discount_value TYPE numeric(12, 2);
ALTER TABLE offer_revisions ALTER COLUMN subtotal TYPE numeric(12, 2);

ALTER TABLE employees ALTER COLUMN daily_wage TYPE numeric(12, 2);
ALTER TABLE employees ALTER COLUMN salary TYPE numeric(12, 2);

ALTER TABLE product_price_history ALTER COLUMN new_price TYPE numeric(12, 2);
ALTER TABLE product_price_history ALTER COLUMN old_price TYPE numeric(12, 2);
ALTER TABLE products ALTER COLUMN source_price TYPE numeric(12, 2);
ALTER TABLE products ALTER COLUMN unit_price TYPE numeric(12, 2);
