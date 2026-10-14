-- Genel (projesiz) masraf (2026-10, ürün sahibinin isteği): "masraf
-- girerken illa proje seçmeyeyim, normal masraf da gireyim; masraflar tek
-- bir yerde olsun". Ofis kirası, yakıt, yemek gibi firmanın genel
-- giderleri project_expenses'e project_id NULL olarak yazılır: kategori,
-- KDV, onay akışı, iptal ve tekrar anahtarı projeli masrafla AYNI kalır,
-- "Masraflar" ekranı ikisini tek listede gösterir.
--
-- Proje toplamlarına (finans özeti, maliyet kontrolü, ana sayfa) girmez:
-- o sorguların hepsi project_id = $x ya da projeler tablosuyla JOIN ile
-- süzer; NULL satır hiçbirine eşleşmez.
--
-- Proje bağları (ek iş, maliyet kodu, bütçe kalemi) projeye aittir --
-- genel masrafta boş olmak zorunda.
ALTER TABLE project_expenses ALTER COLUMN project_id DROP NOT NULL;

ALTER TABLE project_expenses
    ADD CONSTRAINT project_expenses_general_no_project_links
    CHECK (project_id IS NOT NULL OR (change_order_id IS NULL AND cost_code_id IS NULL AND budget_line_id IS NULL));

-- Tekrar anahtarı projeli masrafta (project_id, key) ile tekildir; NULL
-- proje o indekste birbirine eşit sayılmaz, genel masrafa ayrı indeks.
CREATE UNIQUE INDEX idx_general_expenses_idempotency
    ON project_expenses (organization_id, idempotency_key)
    WHERE project_id IS NULL AND idempotency_key IS NOT NULL;

CREATE INDEX idx_expenses_general
    ON project_expenses (organization_id, expense_date)
    WHERE project_id IS NULL;
