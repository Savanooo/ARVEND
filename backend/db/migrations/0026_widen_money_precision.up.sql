-- Faz 6/7 denetim düzeltmesi.
--
-- 1) PARA KOLONLARINI GENİŞLET: numeric(12,2) -> numeric(18,2).
--    numeric(12,2) azami ±9.999.999.999,99 taşır. SaaS'ın ileride büyük
--    ölçekli (çoklu firma, çok yıllı, yüksek enflasyonlu TL) inşaat
--    projelerinde kullanılacağı düşünülürse bu sınır dar kalabilir; ayrıca
--    GetProjectFinancialSummary ve ListProjects gibi sorgular BİRDEN
--    FAZLA numeric(12,2) alanı toplayıp sonucu yine ::numeric(12,2)'ye
--    cast ediyor (bkz. project_finance.sql, projects.sql) -- her bir satır
--    sınır içinde kalsa bile TOPLAM sınırı aşabilir ve "numeric field
--    overflow" ile 500 üretir. numeric(18,2) (azami
--    ±999.999.999.999.999,99) bu riski pratikte ortadan kaldırır.
--    quantity/percentage/vat_rate gibi TUTAR OLMAYAN numeric kolonlara
--    bilinçli olarak DOKUNULMADI.
ALTER TABLE products ALTER COLUMN unit_price TYPE numeric(18, 2);
ALTER TABLE products ALTER COLUMN source_price TYPE numeric(18, 2);
ALTER TABLE product_price_history ALTER COLUMN old_price TYPE numeric(18, 2);
ALTER TABLE product_price_history ALTER COLUMN new_price TYPE numeric(18, 2);

-- NOT: "offers" tablosu Faz 3'ten (0018_migrate_offers_to_revisions)
-- beri para kolonu TAŞIMAZ -- subtotal/vat_amount/grand_total ve
-- "offer_items" tablosunun tamamı o migration'da offer_revisions /
-- offer_revision_items'a taşındı. Güncel para kolonları aşağıdadır.

ALTER TABLE employees ALTER COLUMN salary TYPE numeric(18, 2);
ALTER TABLE employees ALTER COLUMN daily_wage TYPE numeric(18, 2);

ALTER TABLE offer_revisions ALTER COLUMN subtotal TYPE numeric(18, 2);
ALTER TABLE offer_revisions ALTER COLUMN discount_value TYPE numeric(18, 2);
ALTER TABLE offer_revisions ALTER COLUMN discount_amount TYPE numeric(18, 2);
ALTER TABLE offer_revisions ALTER COLUMN vat_amount TYPE numeric(18, 2);
ALTER TABLE offer_revisions ALTER COLUMN grand_total TYPE numeric(18, 2);
ALTER TABLE offer_revision_items ALTER COLUMN unit_price TYPE numeric(18, 2);
ALTER TABLE offer_revision_items ALTER COLUMN discount_value TYPE numeric(18, 2);
ALTER TABLE offer_revision_items ALTER COLUMN line_total TYPE numeric(18, 2);

ALTER TABLE projects ALTER COLUMN contract_amount TYPE numeric(18, 2);

ALTER TABLE project_payment_plan_items ALTER COLUMN planned_amount TYPE numeric(18, 2);
ALTER TABLE project_collections ALTER COLUMN amount TYPE numeric(18, 2);
ALTER TABLE project_expenses ALTER COLUMN amount TYPE numeric(18, 2);
ALTER TABLE project_subcontractors ALTER COLUMN contract_amount TYPE numeric(18, 2);
ALTER TABLE project_subcontractor_payments ALTER COLUMN amount TYPE numeric(18, 2);
ALTER TABLE project_invoices ALTER COLUMN amount TYPE numeric(18, 2);

-- 2) MASRAFLARA IDEMPOTENCY ANAHTARI EKLE: tahsilat ve taşeron ödemesi
--    çift-tıkla/network-retry korumasına zaten sahipti (idempotency_key +
--    kısmi UNIQUE indeks); masraf unutulmuştu -- aynı masraf iki kez
--    gönderilirse iki satır oluşuyordu. Simetrik olarak eklenir.
ALTER TABLE project_expenses ADD COLUMN idempotency_key varchar(64);
CREATE UNIQUE INDEX idx_expenses_idempotency
    ON project_expenses (project_id, idempotency_key)
    WHERE idempotency_key IS NOT NULL;

-- 3) TAŞERON ÖDEMESİ IDEMPOTENCY KAPSAMINI TAŞERON BAZINA İNDİR: eski
--    indeks (project_id, idempotency_key) idi. Aynı projede FARKLI iki
--    taşerona, istemci hatasıyla (örn. ağ zaman aşımı sonrası formun
--    başka bir taşeron için tekrar gönderilmesi) AYNI anahtar gönderilirse
--    ikinci ödeme veritabanına hiç yazılmadan, "idempotent tekrar" sanılıp
--    BİRİNCİ taşeronun kaydı 201 ile dönüyordu -- ikinci ödeme sessizce
--    kayboluyordu. Anahtarı taşeron bazına indirmek bu çakışmayı yapısal
--    olarak imkânsız kılar (bkz. denetim bulgusu).
DROP INDEX idx_sub_payments_idempotency;
CREATE UNIQUE INDEX idx_sub_payments_idempotency
    ON project_subcontractor_payments (subcontractor_id, idempotency_key)
    WHERE idempotency_key IS NOT NULL;
