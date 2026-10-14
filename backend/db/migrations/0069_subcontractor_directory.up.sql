-- Taşeronlar (2026-10, ürün sahibinin isteği): "taşeron menüsünden taşeronu
-- oluşturalım, hem projede hem orada kullanalım; projeden ve proje dışı
-- yaptığım ödemeler tek yerde dursun, alakasız girmeyeyim."
--
-- Taşeron kartı = firmanın tedarikçi kataloğundaki (suppliers) kayıt,
-- is_subcontractor = true. Yeni taşeron sözleşmeleri (project_subcontracts)
-- zaten suppliers'a bağlıydı; projedeki basit "Taşeron Ödemeleri"
-- (project_subcontractors) ise adı her projede elle yazdırıyordu -- aynı
-- kişi farklı yazılınca ödemeleri dağılıyordu. Artık onlar da karta bağlanır
-- (supplier_id) ve proje dışı ödemeler subcontractor_direct_payments'a
-- yazılır; taşeronun sayfası üç kaynağı tek listede toplar.

ALTER TABLE suppliers ADD COLUMN is_subcontractor boolean NOT NULL DEFAULT false;

-- Sözleşmeli taşeron olarak kullanılmış tedarikçiler taşerondur.
UPDATE suppliers s SET is_subcontractor = true
WHERE EXISTS (SELECT 1 FROM project_subcontracts ps WHERE ps.supplier_id = s.id);

ALTER TABLE project_subcontractors ADD COLUMN supplier_id uuid REFERENCES suppliers(id);
CREATE INDEX idx_subcontractors_supplier ON project_subcontractors (supplier_id) WHERE supplier_id IS NOT NULL;

-- Mevcut elle yazılmış taşeronlar karta bağlanır: firma içinde aynı ad
-- (büyük/küçük harf ve fazla boşluk farkı yok sayılarak) tek kart olur.
-- Aynı adlı bir tedarikçi zaten varsa ona bağlanır; yoksa kart açılır
-- (kod TSR-0001, TSR-0002 ... firmada boş olan ilk numara).
DO $$
DECLARE
    rec record;
    sup_id uuid;
    n int;
    new_code text;
BEGIN
    FOR rec IN
        SELECT DISTINCT ON (organization_id, norm)
               organization_id, norm, name, company_name, phone, email
        FROM (
            SELECT organization_id, name, company_name, phone, email, created_at,
                   lower(btrim(regexp_replace(name, '\s+', ' ', 'g'))) AS norm
            FROM project_subcontractors
            WHERE supplier_id IS NULL AND btrim(name) <> ''
        ) x
        ORDER BY organization_id, norm, created_at
    LOOP
        SELECT s.id INTO sup_id
        FROM suppliers s
        WHERE s.organization_id = rec.organization_id
          AND (lower(btrim(regexp_replace(s.legal_name, '\s+', ' ', 'g'))) = rec.norm
               OR lower(btrim(regexp_replace(s.trade_name, '\s+', ' ', 'g'))) = rec.norm)
        ORDER BY s.created_at
        LIMIT 1;

        IF sup_id IS NULL THEN
            n := 1;
            LOOP
                new_code := 'TSR-' || lpad(n::text, 4, '0');
                EXIT WHEN NOT EXISTS (
                    SELECT 1 FROM suppliers WHERE organization_id = rec.organization_id AND code = new_code);
                n := n + 1;
            END LOOP;
            INSERT INTO suppliers (organization_id, code, legal_name, trade_name, phone, email, is_subcontractor)
            VALUES (rec.organization_id, new_code, btrim(regexp_replace(rec.name, '\s+', ' ', 'g')),
                    btrim(rec.company_name), btrim(rec.phone), btrim(rec.email), true)
            RETURNING id INTO sup_id;
        ELSE
            UPDATE suppliers SET is_subcontractor = true WHERE id = sup_id;
        END IF;

        UPDATE project_subcontractors
        SET supplier_id = sup_id
        WHERE organization_id = rec.organization_id AND supplier_id IS NULL
          AND lower(btrim(regexp_replace(name, '\s+', ' ', 'g'))) = rec.norm;

        sup_id := NULL;
    END LOOP;
END $$;

-- Proje dışı taşeron ödemesi: bir projeye ait olmayan iş için yapılan
-- ödeme. Projeli ödemeler (project_subcontractor_payments,
-- subcontract_payments) olduğu gibi kalır.
CREATE TABLE subcontractor_direct_payments (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid NOT NULL REFERENCES organizations(id),
    supplier_id      uuid NOT NULL REFERENCES suppliers(id),
    amount           numeric(18, 2) NOT NULL CHECK (amount > 0),
    currency         varchar(3) NOT NULL,
    paid_date        date NOT NULL,
    description      varchar(500) NOT NULL DEFAULT '',
    idempotency_key  varchar(64),
    created_by       uuid REFERENCES users(id) ON DELETE SET NULL,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    voided_at        timestamptz,
    voided_by        uuid REFERENCES users(id) ON DELETE SET NULL,
    void_reason      varchar(500) NOT NULL DEFAULT ''
);

CREATE INDEX idx_direct_payments_supplier ON subcontractor_direct_payments (supplier_id);
CREATE INDEX idx_direct_payments_org ON subcontractor_direct_payments (organization_id);
CREATE UNIQUE INDEX idx_direct_payments_idempotency
    ON subcontractor_direct_payments (organization_id, idempotency_key)
    WHERE idempotency_key IS NOT NULL;

CREATE TRIGGER direct_payments_set_updated_at BEFORE UPDATE ON subcontractor_direct_payments
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
