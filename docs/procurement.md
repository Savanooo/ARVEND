# Satın Alma (Procurement Foundation) — Sprint 4

Bu doküman, Sprint 4'te eklenen satın alma zincirini kapsar: **Tedarikçi
(Supplier) → Satın Alma Talebi (Purchase Request) → Teklif Talebi (RFQ) →
Tedarikçi Teklifi (Supplier Quotation) → Teklif Karşılaştırma → Ödül
(Award) → Sipariş (Purchase Order) → Maliyet Kontrolü Entegrasyonu**.

İlgili diğer dokümanlar: [`docs/cost-control.md`](cost-control.md) (Bütçe
+ Maliyet Kontrolü, Sprint 2), [`docs/contracts.md`](contracts.md) (Proje
Sözleşmesi + Ek İş, Sprint 3).

## 0. Kavramsal Ayrım — Tekrar Karıştırılmaması Gereken Kavramlar

Bu sprint boyunca kasıtlı olarak korunan sınırlar:

- **Supplier ≠ Customer.** Tedarikçi (organizasyon-seviyeli, tedarikçiyle
  yapılan alım ilişkisi) ile Müşteri (proje geliriyle ilişkili) tamamen
  ayrı, düz tablolardır — ortak bir Person/Company soyutlaması yoktur
  (repo genelinde `customers` ve `project_subcontractors` de birbirinden
  bağımsızdır, burada da böyle bir soyutlama icat edilmedi).
- **Purchase Request ≠ RFQ.** PR, projenin dahili ihtiyaç talebidir
  (henüz hiçbir tedarikçiyle temas yok). RFQ, bir veya daha fazla
  tedarikçiye gönderilen somut teklif talebidir.
- **RFQ ≠ Quotation.** RFQ istek, Quotation yanıttır (tedarikçi başına).
- **Quotation ≠ Purchase Order.** Teklif, ticari bir taahhüt DEĞİLDİR —
  yalnızca PO ile ticari taahhüt (ve Cost Control commitment'ı) oluşur.
- **Purchase Order ≠ Expense / Payment / Inventory Receipt / Subcontract.**
  PO, tedarikçiye "bu malzemeyi/hizmeti bu şartlarla alacağız" der.
  Ödeme, mal kabul (goods receipt), envanter ve taşeron sözleşmeleri bu
  sprintin kapsamı DIŞINDADIR (bkz. §10).
- **Committed ≠ Actual.** PO onayı yalnızca **Committed** (taahhüt
  edilen) maliyeti değiştirir. **Actual** (gerçekleşen) maliyet, gelecekte
  Tedarikçi Faturası/Mal Kabul/Masraf kaydından gelecektir — bu sprintte
  YOKTUR (bkz. §5).
- **Procurement (maliyet/gider tarafı) ≠ Contract/Change Order (gelir
  tarafı, Sprint 3).** İki zincir arasında HİÇBİR otomatik bağlantı
  yoktur ve olmamalıdır (bkz. §9, regresyon testi
  `39_procurement_never_touches_contract_or_change_orders`).

## 1. Zincir ve Durum Makineleri

```
Supplier (organizasyon-seviyeli katalog, durum makinesi yok — yalnızca
  is_active / arşivlenmiş)
    │
    ▼
Purchase Request (proje-seviyeli)
  draft ──submit──▶ submitted ──approve──▶ approved (terminal)
    │                   │
    │                   └──reject (gerekçe zorunlu)──▶ rejected (terminal)
    │
    └──withdraw (submitted→draft) / cancel (draft→cancelled, terminal)
    │
    ▼ (opsiyonel kaynak — PR'sız doğrudan RFQ da mümkün)
RFQ (proje-seviyeli, bir veya daha fazla tedarikçiye davet)
  draft ──issue──▶ issued ──close──▶ closed (terminal)
    │                   │
    │                   └──award(quotation)──▶ (issued kalır, awarded_quotation_id set edilir)
    │
    └──cancel (draft/issued → cancelled, terminal)
    │
    ▼
Supplier Quotation (RFQ başına, tedarikçi başına — KENDİ status alanı YOK,
  bkz. §3)
    │
    ▼ (award sonrası, opsiyonel — kullanıcı manuel PO oluşturur)
Purchase Order (proje-seviyeli)
  draft ──approve──▶ approved (Cost Control commitment OLUŞTURUR) ──close──▶ closed (terminal)
    │                     │
    └──cancel (gerekçe)   └──cancel (gerekçe, BAĞLI commitment'ları voider)
         ▼                     ▼
      cancelled (terminal)  cancelled (terminal)
```

Tüm geçişler backend-enforced, izin-kontrollü ve denetimlidir (`project_events`).
Frontend buton görünürlüğüne GÜVENİLMEZ — her geçiş backend'de bağımsız
olarak `WHERE status='<beklenen>'` guard'ıyla da reddedilir (Sprint 2/3
ile aynı `SELECT ... FOR UPDATE` + guard'lı `UPDATE` eşzamanlılık deseni,
bkz. §7).

### 1.1 Purchase Request

- `draft` → `submitted` → `approved` | `rejected` (gerekçe zorunlu).
- `submitted` → `draft` (withdraw, talep sahibi geri çeker).
- `draft` → `cancelled` (terminal).
- `approved`/`rejected`/`cancelled` üçü de terminal — Sprint 4'te hiçbir
  geri dönüş/yeniden açma yok.
- Yalnızca `draft` durumundaki bir PR'ın alanları/kalemleri düzenlenebilir.

### 1.2 RFQ

- `draft` → `issued` → `closed` (terminal).
- `draft`/`issued` → `cancelled` (terminal).
- Yalnızca `draft` durumundaki bir RFQ'nun alanları/kalemleri/davet
  edilen tedarikçi listesi düzenlenebilir.
- **Award, bir durum geçişi DEĞİLDİR** — `issued` durumundaki bir RFQ'da
  `awarded_quotation_id` set edilir, RFQ `issued` durumunda KALIR (henüz
  `closed` olmayabilir — kullanıcı award sonrası ayrıca kapatabilir).
  Award edilen teklifin `rfq_id`'si, award edilen RFQ ile eşleşmiyorsa
  (çapraz-RFQ hatası) reddedilir.

### 1.3 Purchase Order

- `draft` → `approved` (Cost Control commitment'ı OLUŞTURUR, bkz. §5) →
  `closed` (terminal).
- `draft`/`approved` → `cancelled` (terminal, gerekçe zorunlu).
  `approved`'tan cancel, BAĞLI aktif commitment'ları voider (§5).
- Boş kalemli (`items.length == 0`) bir PO ASLA approve edilemez.
- `approved` sonrası ticari alanlar (tedarikçi, kalemler, tutarlar,
  vergi oranı) backend tarafından KİLİTLENİR — `UpdatePurchaseOrderDraft`
  yalnızca `draft` durumunda çalışır (Sprint 3'ün Contract baseline-lock
  ilkesiyle aynı).
- `closed`, yalnızca `approved`'tan ulaşılabilen TERMİNAL bir arşiv
  işaretidir — **commitment'a DOKUNMAZ** (bkz. §5.3, bu kasıtlı bir
  tasarım kararıdır).

## 2. Tedarikçi (Supplier)

Organizasyon-seviyeli (proje-bağımsız), `organization_cost_codes` ile
AYNI kardinalitede tek bir paylaşılan katalog. Şema:

```
id, organization_id, code (org içinde benzersiz, oluşturulduktan sonra
  değiştirilemez), legal_name, trade_name, tax_number, tax_office,
  contact_name, email, phone, address, city, country, iban_enc,
  is_active, notes, created_at, updated_at
```

- **Durum makinesi yoktur** — yalnızca `is_active` (arşivle/etkinleştir).
- **IBAN**, `internal/platform/crypto.SecretBox` (AES-256-GCM) ile
  şifrelenir, plaintext ASLA HTTP yanıtına taşınmaz — yalnızca
  `iban_set: boolean` döner. Güncelleme 3 durumlu: alan gövdede yoksa
  (nil) mevcut değer DEĞİŞMEZ, `""` gönderilirse şifreli değer TEMİZLENİR,
  dolu string gönderilirse yeniden şifrelenir.
- **VKN (vergi kimlik no) doğrulaması YAPILMAZ** — `tax_number` serbest
  metin olarak saklanır, resmi bir VKN algoritma doğrulaması iddia
  edilmez/uygulanmaz (bilinçli kapsam dışı, bkz. §10).
- **Tedarikçi puanlama, sigorta, ön-yeterlilik, taşeron uygunluk takibi**
  bu sprintin KAPSAMI DIŞINDADIR — gelecekteki bir Taşeron (Subcontract)
  sprintine bırakılmıştır.
- Arşivlenmiş bir tedarikçi YENİ PR/RFQ/PO'larda seçilemez ama MEVCUT
  kayıtlarda (geçmiş PO'lar vb.) görünmeye devam eder.
- **Kiracı izolasyonu**: bir organizasyona ait tedarikçi başka bir
  organizasyonun projesinde PO'da KULLANILAMAZ (backend'de doğrulanır,
  bkz. §8 IDOR testleri).

## 3. Purchase Request → RFQ → Quotation

### 3.1 Purchase Request (PR)

Proje-seviyeli. Şema: `id, organization_id, project_id, pr_no, title,
description, needed_by, status, estimated_total, requested_by,
submitted_at, approved_at/by, rejected_at/by/rejection_reason,
cancelled_at/by/cancel_reason, created_at, updated_at` + kalemler
(`purchase_request_items`: `wbs_node_id?, cost_code_id?, budget_line_id?,
description, quantity, unit, estimated_unit_cost?, estimated_total,
notes, sort_order`).

`estimated_total` (PR) ve kalem `estimated_total`'ları **SQL'de
hesaplanır** (Go'da DEĞİL) — bu, migration/kod denetiminde
`change_order_items` (SQL-hesaplı) ile `budget_lines` (Go-hesaplı)
arasında bulunan mevcut bir tutarsızlığın bilinçli olarak SQL tarafında
çözülmesidir; Sprint 4'ün tüm yeni parasal alanları (PR kalemleri,
quotation kalemleri, PO kalemleri) AYNI SQL-hesaplı deseni izler.

Minimal, genel bir "workflow engine" YOKTUR — yukarıdaki sabit durum
makinesi dışında hiçbir yapılandırılabilir onay zinciri yoktur.

### 3.2 RFQ

Proje-seviyeli. `purchase_request_id` **opsiyoneldir** — "PR olmadan
doğrudan RFQ" desteklenir (ör. acil/küçük bir alım için PR süreci
atlanabilir).

Şema: `id, organization_id, project_id, rfq_no, purchase_request_id?,
title, issue_date, due_date?, status, notes, awarded_quotation_id?,
awarded_at?, awarded_by?, award_notes, created_by, created_at,
updated_at` + `rfq_suppliers` (davet edilen tedarikçiler, `response_status`
takibi: pending/responded/declined — bilgilendirme amaçlı, e-posta
gönderimi YOK) + `rfq_items`.

**Kritik tasarım kararı — RFQ kalemleri PR'dan SNAPSHOT alır, LIVE JOIN
DEĞİL.** Bir RFQ, bir PR'dan oluşturulduğunda, PR kalemleri o ANKİ
haliyle `rfq_items`'a KOPYALANIR (`source_pr_item_id`, yalnızca izlenebilirlik
amaçlı bir referanstır — asla canlı bir join için kullanılmaz). Bu sayede,
RFQ tedarikçilere gönderildikten (`issued`) SONRA kaynak PR değişse (veya
iptal edilse) bile, zaten gönderilmiş olan ticari talep AYNEN korunur.
Doğrulandı: `14_rfq_snapshot_immune_to_later_pr_changes` testi.

RFQ manuel kalemlerle (PR'sız) de oluşturulabilir — bu durumda
`source_pr_item_id` boştur.

### 3.3 Supplier Quotation

RFQ başına, tedarikçi başına manuel girilen teklif — **tedarikçi
portalı/girişi YOKTUR**, teklif her zaman personel tarafından elle
girilir (telefon/e-posta/PDF üzerinden alınan teklifin sisteme
kaydedilmesi).

Şema: `id, organization_id, project_id, rfq_id, supplier_id,
quotation_number, quotation_date, valid_until?, currency, subtotal,
discount, tax_rate, tax, total, delivery_days?, payment_terms, notes,
created_by, created_at, updated_at` + `quotation_items`
(`rfq_item_id, quantity, unit_price, line_total, notes`).

**Kasıtlı olarak KENDİ bir `status` alanı YOKTUR.** "Kazanan teklif"
bilgisinin TEK doğruluk kaynağı `rfqs.awarded_quotation_id`'dir (Sprint
3'ün Contract/Change Order tasarımındaki "tek doğruluk kaynağı" ilkesiyle
birebir tutarlı — teklif nesnesinin kendisi asla "won"/"lost" gibi bir
durum taşımaz).

Tüm toplamlar **backend-authoritative**'dir (kullanıcı arayüzünden
gönderilen toplamlar değil, backend'in kendi hesapladığı toplamlar
kaydedilir) — ondalık hata payı YOKTUR (bkz. §6 Para Testi).

### 3.4 Teklif Karşılaştırma (Bid Comparison)

Gerçek bir web UI: satırlar RFQ kalemleri, sütunlar tedarikçiler
(`GetBidComparison` → `BidComparison{Rows: [{Item, Cells: [{SupplierID,
UnitPrice, LineTotal, ...}]}]}`). **Sistem ASLA otomatik bir "kazanan"
seçmez** — bu ekran tamamen bilgilendiricidir, karar HER ZAMAN kullanıcı
tarafından verilir (Award, ayrı ve açık bir eylemdir, bkz. §3.5).

### 3.5 Award (Ödül)

Denetimli bir eylem: `AwardRFQ(rfqID, quotationID, actor, notes)` →
`rfqs.awarded_quotation_id/awarded_at/awarded_by/award_notes` set edilir,
`ProjectEventRFQAwarded` olayı loglanır. **Award, TEK BAŞINA hiçbir
gerçek maliyet oluşturmaz** — yalnızca "bu teklif seçildi" kaydıdır. Bir
PO, award edilmiş bir quotation'dan (opsiyonel olarak `source_rfq_id` /
`source_quotation_id` alanlarıyla iz sürülerek) SONRADAN, AYRI bir
kullanıcı eylemiyle oluşturulur.

## 4. Purchase Order (PO)

Proje-seviyeli. Şema:

```
purchase_orders: id, organization_id, project_id, po_no, supplier_id,
  source_rfq_id?, source_quotation_id?, currency, status, issue_date,
  expected_delivery_date?, payment_terms, delivery_address, notes,
  subtotal, tax_rate, tax, total, created_by, approved_by?, approved_at?,
  cancelled_by?/cancelled_at?/cancel_reason, closed_by?/closed_at?,
  created_at, updated_at

purchase_order_items: id, purchase_order_id, project_id, wbs_node_id?,
  cost_code_id (ZORUNLU — nullable DEĞİL), budget_line_id?, description,
  quantity, unit, unit_price, line_total, sort_order
```

- PO oluşturulurken tedarikçinin `is_active=true` olması ZORUNLUDUR.
- `source_rfq_id`/`source_quotation_id` verilirse, quotation'ın gerçekten
  o RFQ'ya ait olduğu doğrulanır (çapraz-RFQ/quotation uyuşmazlığı
  reddedilir) — ama bu alanlar **opsiyoneldir**, bir PO doğrudan da
  (RFQ/Quotation zinciri olmadan) oluşturulabilir.
- **PO kalemi → Bütçe Kalemi (budget_line) eşlemesi mümkün olan yerde
  yapılır ama ZORUNLU DEĞİLDİR** (`budget_line_id` nullable). Eşleme
  yoksa, commitment "bütçe dışı" (unbudgeted) olarak Cost Control'de
  görünür (mevcut Sprint 2 unbudgeted satır mekanizmasıyla AYNI, bkz.
  `docs/cost-control.md`).
- **Çapraz-proje bütçe kalemi eşlemesi KESİNLİKLE YASAKTIR** — A projesinin
  bir PO'su B projesinin bir bütçe kalemine referans veremez (backend
  reddeder).
- Bütçe uygunluğu (availability) UI'da GÖSTERİLEBİLİR ama bu sprintte
  SERT bir blok DEĞİLDİR — bütçe-üstü bir PO yalnızca UYARI gösterebilir,
  onayı engellemez.

### 4.1 Vergi (KDV) ve Para Birimi

- Tam bir Türk muhasebe/vergi motoru bu sprintte YOKTUR. `subtotal` +
  `tax_rate` + `tax` + `total` yeterlidir (PO ve Quotation'da aynı
  desen). Tevkifat, e-Fatura, e-İrsaliye entegrasyonları gelecekteki bir
  finans/entegrasyon sprintine bırakılmıştır.
- Tedarikçi teklifi ve PO'nun para birimi (`currency`) AÇIKÇA takip
  edilir. **Tam bir döviz kuru (FX) motoru YOKTUR.** Cost Control'ün
  proje taban para birimiyle (`project_budgets.currency`) farklı bir
  PO/quotation para birimi, desteklenmeyen/bilinen bir sınır olarak ele
  alınır — **YANLIŞ bir dönüşüm ASLA uydurulmaz/hesaplanmaz.** (Bu
  sprintte tüm test senaryoları ve örnek akışlar aynı para birimi
  içinde kalır; çapraz para birimi desteği gelecekteki bir finans
  sprintine bırakılmıştır.)

## 5. Cost Control Entegrasyonu — EN KRİTİK BÖLÜM

Sprint 4, **Sprint 2'nin mevcut `project_commitments` genel taahhüt
sistemini YENİDEN KULLANIR** — procurement'a özel PARALEL bir ikinci
taahhüt/ledger tablosu OLUŞTURULMADI.

### 5.1 Kural: "PO APPROVED = COMMITTED"

Bir PO'nun `approve` edilmesi, TAM OLARAK şu anlama gelir:

> **Committed Amount = onaylanan PO'nun maliyet tutarı.**

Bu, kullanıcının kendi kelimeleriyle verdiği, sprint boyunca değiştirilmeyen
kuraldır. **"PO PAID" diye bir kavram bu sprintte İCAT EDİLMEMİŞTİR** —
ödeme, tamamen ayrı ve gelecekteki bir kapsamdır (bkz. §10).

- PO onayı **Actual (gerçekleşen) maliyeti ASLA değiştirmez** — Actual,
  gelecekte Tedarikçi Faturası/Mal Kabul/Masraf kaydından gelecektir
  (bu sprintin kapsamı dışında, bkz. §10).
- PO onayı **Bütçeyi (Budget) ASLA değiştirmez.**
- PO onayı **müşteri Sözleşme değerini (Contract value) ASLA değiştirmez**
  (bkz. §9).

### 5.2 Granülerlik — PO-KALEMİ seviyesinde, PO seviyesinde DEĞİL

`project_commitments` şeması **tek bir satırda tek bir maliyet
kodu/bütçe kalemi** taşır — bir PO'nun farklı kalemleri farklı maliyet
kodlarına/bütçe kalemlerine eşlenebileceğinden (tıpkı bir masraf
kaleminin tek bir cost_code'a bağlanması gibi), entegrasyon **PO-kalemi
granülerliğinde** yapılır:

```
source_type = 'purchase_order'
source_id   = purchase_order_items.id   (PO'nun kendisi DEĞİL, her kalem
                                          KENDİ commitment satırını üretir)
```

`ApprovePurchaseOrder`, onaylanan PO'nun HER kalemi için AYRI bir
`CreateCommitmentFromSource` çağrısı yapar (tek transaction içinde,
`committed_amount = kalemin line_total'ı`, `cost_code_id`/`budget_line_id`
kalemden miras alınır).

### 5.3 İptal ve Kapatma Semantiği

- **PO İptal (`cancel`)**: Eğer PO daha önce `approved` idiyse (yani
  commitment zaten oluşturulmuşsa), o PO'nun kalemlerinden doğan TÜM
  AKTİF commitment'lar tek bir `VoidCommitmentsBySourcePOItems` sorgusuyla
  `status='voided'` yapılır (idempotent — zaten voided olanlar
  etkilenmez, aynı iptal işlemi iki kez tetiklense bile zararsız).
  `draft` durumundaki bir PO'nun iptalinde (henüz commitment
  oluşmadığından) voidlenecek bir şey yoktur.
- **PO Kapatma (`close`)**: yalnızca `approved` durumundan ulaşılabilen
  TERMİNAL bir arşiv işaretidir. **Commitment'a KESİNLİKLE DOKUNMAZ** —
  "kapatıldı" (mal teslim alındı/süreç bitti anlamında) demek, ticari
  taahhüdün geçersiz olduğu anlamına GELMEZ; taahhüt Cost Control'de
  aktif kalmaya devam eder (nihayetinde bir Actual kayda — gelecekteki
  Mal Kabul/Fatura sprintine — dönüşene kadar). Bu kasıtlı bir tasarım
  kararıdır: "closed" bir "cancelled" değildir, taahhüdü SİLMEZ.

### 5.4 Altın Regresyon Senaryosu (doğrulandı, `38_cost_control_golden_regression`)

```
Proje Bütçesi:         100.000
Mevcut taahhüt:          10.000
Onaylanan PO:             30.000
Taahhüt Toplamı:          40.000   (10.000 + 30.000)
PO iptal edildi
Taahhüt Toplamı tekrar:   10.000   (30.000'lik commitment voided)
Actual:                  DEĞİŞMEDİ
Bütçe:                   DEĞİŞMEDİ
Sözleşme değeri:         DEĞİŞMEDİ
```

Bu senaryo, backend'de gerçek veritabanına karşı BİREBİR bu sayılarla
test edilmiştir — yaklaşık/toleranslı bir karşılaştırma DEĞİL.

### 5.5 Bilinen Dokümantasyon Düzeltmesi (Sprint 5'te uygulandı)

Bu sprintin denetim aşamasında, `docs/cost-control.md`'nin "Committed
Cost = commitments ∪ taşeron sözleşmeleri (subcontractor contracts)"
şeklindeki iddiasının **gerçek kodla UYUŞMADIĞI** tespit edildi — gerçek
davranış YALNIZCA `project_commitments` toplamını kullanır, taşeron
sözleşmeleri birleşime dahil EDİLMEZ. Sprint 4'ün altın regresyon testi
(§5.4), bu DOĞRULANMIŞ gerçek davranışa karşı yazılmıştır (yanlış
dokümante edilmiş davranışa karşı DEĞİL). Bu sprintte (Sprint 4) düzeltme
kapsam dışı bırakılmış, yalnızca burada not edilmişti.

**Güncelleme — Sprint 5:** `docs/cost-control.md` §5/§9 artık düzeltilmiş
haldedir (tek kaynak: `Σ(project_commitments WHERE status='active')`).
Sprint 5 ayrıca `project_commitments.source_type='subcontract'`'ı
(Sprint 2'den beri rezerve edilmiş ama hiç kullanılmamış bir değer)
gerçekten yazan ilk kod yolunu ekledi — bkz. [docs/subcontracts.md](subcontracts.md).
Detay: `docs/cost-control.md` bu düzeltmenin yanında, proje genel bakış
sayfasının kullandığı TAMAMEN AYRI ve BAĞIMSIZ `GetProjectFinancialSummary`
hesaplamasını (ki bu HÂLÂ `project_subcontractors`/
`project_subcontractor_payments`'ı toplar) da netleştirir — bu iki
sistem kasıtlı olarak birleştirilmemiştir, bkz. `docs/subcontracts.md`
"Legacy Taşeron Sistemi" bölümü.

## 6. Para Testi (doğrulandı, ondalık hatasız)

```
RFQ miktarı: 100
Tedarikçi A: birim 125,50 → toplam 12.550,00
Tedarikçi B: birim 123,75 → toplam 12.375,00
Award: B (daha düşük teklif — sistem ÖNERMEDİ, kullanıcı seçti)
PO: 12.375,00 + KDV (modellenen orana göre) = 14.850,00 (%20 KDV örneğiyle)
Cost Control commitment: PO kalem toplamlarıyla TAM eşleşir (KDV hariç,
  §5.2'deki gibi kalem line_total'ı üzerinden)
Float hatası: YOK (Go float64 + PostgreSQL numeric, backend-authoritative
  hesaplama — kullanıcı girdisi toplamları asla doğrudan güvenilmez)
```

## 7. Numaralandırma

`PR-YYYY-NNNN`, `RFQ-YYYY-NNNN`, `PO-YYYY-NNNN` — hiçbir zaman sabit
kodlanmış string DEĞİLDİR; mevcut **organizasyon+yıl kapsamlı sayaç**
altyapısı (offers/projects ile AYNI desen — change-order'ların
proje-başına saydığı desenden FARKLI, çünkü PR/RFQ/PO "organizasyonel
olarak anlamlı finansal belge" kategorisindedir) yeniden kullanılır:

```sql
INSERT INTO purchase_request_counters (organization_id, year, seq)
VALUES ($1, $2, 1)
ON CONFLICT (organization_id, year)
DO UPDATE SET seq = purchase_request_counters.seq + 1
RETURNING seq;
```

`SELECT MAX(...) + 1` deseni KULLANILMAMIŞTIR (yarış durumuna açık) —
yukarıdaki atomik `INSERT ... ON CONFLICT DO UPDATE ... RETURNING`
deseni, `rfq_counters`/`purchase_order_counters` için de birebir
tekrarlanır. Eşzamanlı numaralandırma yarışı, `25_po_number_generation_race`
gibi testlerle doğrulanmıştır.

## 8. İzinler

Sprint 1'in mevcut izin kayıt defteri (registry) yeniden kullanılır,
`<domain>.<subresource>.<action>` formatı korunur. Sprint 4, **Contract'ın
`lifecycle` izniyle AYNI ilkeyi izleyen ama ondan BAĞIMSIZ, üçüncü bir
fiil olan `approve`** ekler — bu, "her sprint kendi fiilini seçer, fiil
evrensel bir sabit değildir" ilkesinin bilinçli bir uygulamasıdır:

| İzin | Anlamı |
|---|---|
| `organization.suppliers.read` | Tedarikçi kataloğunu görüntüleme |
| `organization.suppliers.manage` | Tedarikçi oluşturma/düzenleme/arşivleme |
| `projects.procurement.read` | PR/RFQ/Teklif/Karşılaştırma/PO görüntüleme |
| `projects.procurement.manage` | PR/RFQ/Teklif taslağı oluşturma/düzenleme, PO taslağı oluşturma/düzenleme |
| `projects.procurement.approve` | PR onay/red, RFQ award, PO onay/iptal/kapatma |

### Rol Matrisi

| Rol | suppliers.read | suppliers.manage | procurement.read | procurement.manage | procurement.approve |
|---|:-:|:-:|:-:|:-:|:-:|
| Owner / Admin | ✓ | ✓ | ✓ | ✓ | ✓ |
| Finance | ✓ | ✓ | ✓ | ✓ | ✓ |
| **Project Manager** | ✓ | — | ✓ | ✓ | **—** |
| **Legacy User** | ✓ | — | ✓ | ✓ | **—** (asla otomatik verilmez) |
| Field | — | — | — | — | — |

- **Project Manager**, taslak PR/RFQ/PO oluşturabilir/düzenleyebilir
  (`manage`) ama onay/award/iptal/kapatma (`approve`) YAPAMAZ — Sprint
  3'ün Contract izin modeliyle AYNI, kasıtlı bir "manage ≠ approve"
  ayrımıdır.
- **Legacy User**, geriye dönük uyumluluk gerekçesiyle `read`+`manage`
  alır (migration öncesi tam yetkili "kullanıcı" rolünün doğal
  genişlemesi) ama **`approve` KESİNLİKLE otomatik verilmez** — bu yeni
  bir eylem sınıfıdır, eski rolün bu izne karşılık gelen bir geçmişi
  yoktur, o yüzden miras alınmaz. Kritik regresyon testiyle doğrulanmıştır.
- **Field**, hiçbir satın alma izni ALMAZ (bu sprintte saha personeli
  için bir "talep oluştur" akışı DEĞERLENDİRİLDİ ama kapsam büyümesini
  önlemek için ERTELENDİ — bkz. §10).
- Süper Admin, Sprint 1'den beri var olan koşulsuz bypass'a sahiptir
  (procurement'a özgü yeni bir risk DEĞİL, mevcut sistem davranışı).

## 9. Güvenlik

- **Kiracı izolasyonu zorunludur** — her yeni kaynak türü (Supplier, PR,
  RFQ, Quotation, PO) organizasyon-scoped'dur.
- **Proje üyeliği tabanlı erişim** (Sprint 1) — PR/RFQ/Quotation/PO
  erişimi projeye üyeliğe bağlıdır.
- **IDOR testleri** her yeni kaynak türü için yazılmıştır: A projesinin
  URL'i + B projesinin PR/RFQ/Quotation/PO UUID'i → reddedilir.
  Organizasyonlar arası tedarikçi erişimi reddedilir — A organizasyonuna
  ait bir tedarikçi, B organizasyonunun bir projesinin PO'sunda
  KULLANILAMAZ (backend'de doğrulanır).
- **Eşzamanlılık** — PR çift onay, RFQ çift issue, PO çift onay, PO
  duplicate commitment, numara üretim yarışı, aynı quotation'ın iki kez
  award edilmesi, PO iptal idempotency'si — hepsi test edilmiştir.
  Commitment oluşturma **tam olarak bir kez** (exactly-once) garantilidir
  (`35_po_duplicate_approval_concurrency`).
- **Denetim** — yeni bir paralel audit sistemi İNŞA EDİLMEMİŞTİR; mevcut
  per-domain `project_events`/`organization_events` altyapısı kullanılır.
  Sprint 2'de keşfedilen `AuthorizationService`'in audit olayı ÜRETMEDİĞİ
  bilinen boşluğu, bu sprintte yeni bir paralel sistem inşa etmek için
  gerekçe olarak KULLANILMAMIŞTIR (kullanıcının açık talimatı).

## 10. Kapsam Dışı (Bu Sprintte Bilinçli Olarak Yapılmadı)

- **Mal Kabul / Teslimat Takibi (Goods Receipt)** — kullanıcının kendi
  kararına bırakılmıştı ("bu sprintte minimal bir Goods Receipt inşa et,
  ya da ayrı bir 'Sprint 4B'ye böl"). **Karar: Sprint 4B'ye ERTELENDİ.**
  Gerekçe: Sprint 4'ün kapsamı (7 yeni varlık: Supplier/PR/RFQ/Quotation/
  Comparison/Award/PO + tam Cost Control entegrasyonu + izin matrisi +
  mobil + 58 test senaryosu) zaten büyük; Goods Receipt'in DOĞRU
  modellenmesi (kısmi teslimat, teslimat toleransları, PO kalemi başına
  teslim durumu, "Actual" maliyetin NE ZAMAN/NASIL tetikleneceği kararı)
  kendi başına ayrı ve dikkatli bir tasarım gerektirir — bu sprintin
  "PO approved = Committed, Actual bu sprintte YOK" net sınırını
  bulandırmadan doğru yapılamazdı. Mal Kabul, PO'nun "Actual"a
  dönüştüğü doğal gelecek adımdır (bkz. aşağıdaki Gelecek Yol Haritası).
- Tedarikçi puanlama/sigorta/ön-yeterlilik/taşeron uygunluk takibi
  (Taşeron sprintine bırakıldı).
- Taşeron sözleşmeleri/hakediş (progress claims).
- Tedarikçi Faturası / Borç (AP), Müşteri Faturası / Alacak (AR).
- Ödemeler yeniden tasarımı.
- Envanter değerleme, Depo sistemi.
- e-Fatura / e-Arşiv / e-İrsaliye entegrasyonu, tam vergi motoru.
- Gantt, RFI, Submittal, Doküman Kontrolü, CRM, AI, genel amaçlı
  workflow engine.
- Tedarikçi portalı, e-imza.
- Saha personeli (Field rolü) için basit bir "talep oluştur" akışı
  DEĞERLENDİRİLDİ ama kapsam büyümesi riski nedeniyle ERTELENDİ.
- **Production deploy YOK, production migration YOK.**

## 11. Gelecek Yol Haritası — Tedarikçi Faturası / Mal Kabul Yolu

Bu sprint, "Committed" tarafını tamamlar ama "Actual" tarafını kasıtlı
olarak açık bırakır. Doğal bir sonraki adım (Sprint 4B veya sonrası):

1. **Goods Receipt** (Mal Kabul) — bir PO kalemi için kısmi/tam teslimat
   kaydı, PO kalemi başına teslim durumu.
2. **Tedarikçi Faturası (Supplier Invoice)** — bir PO'ya (ve/veya Mal
   Kabul kaydına) bağlı, gerçek tedarikçi faturasının girilmesi — bu,
   **Actual maliyetin TETİKLEYİCİSİ** olacaktır (bugünkü `project_expenses`
   ile aynı ilkede: Actual, yalnızca gerçek bir mali olaydan doğar,
   PO onayından DEĞİL).
3. Bu ikisi birlikte, `docs/cost-control.md`'nin EAC (Estimate at
   Completion) hesaplamasına PO-kaynaklı gerçek Actual verisini
   besleyecektir (bugün yalnızca `project_expenses`'ten geliyor).

Mobil tarafta bu sprintte YALNIZCA okuma görünürlüğü vardır (PR ve PO
liste/detay) — RFQ oluşturma, teklif karşılaştırma, tedarikçi yönetimi,
PO onayı, karmaşık düzenleme mobilde bu sprintte YOKTUR (web-first ilkesi,
Sprint 2/3 ile aynı).
