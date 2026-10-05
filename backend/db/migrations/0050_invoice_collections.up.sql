-- Satış faturası "ödendi" yapılınca tahsilat (sahada 2026-10: "fatura
-- kestim, ödendi yaptım ama özette ne kâr ne veri var").
--
-- Proje özetindeki tahsil edilen ve kâr YALNIZCA tahsilat kayıtlarından
-- hesaplanır; faturanın durumu para girişi sayılmaz. Fatura "ödendi"
-- yapılırken kullanıcı isterse fatura tutarında bir tahsilat oluşturulur
-- ve faturaya bağlanır. Bağ, aynı paranın iki kez sayılmasını önler:
-- fatura başına en çok bir GEÇERLİ (iptal edilmemiş) bağlı tahsilat; fatura
-- "ödendi"den çıkarılırsa bağlı tahsilat iptal edilir (bkz.
-- ProjectService.UpdateInvoiceStatus).
ALTER TABLE project_collections
    ADD COLUMN invoice_id uuid REFERENCES project_invoices(id) ON DELETE SET NULL;

CREATE UNIQUE INDEX idx_collections_one_per_invoice
    ON project_collections (invoice_id)
    WHERE invoice_id IS NOT NULL AND voided_at IS NULL;
