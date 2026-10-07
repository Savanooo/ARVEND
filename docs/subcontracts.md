# Taşeron Yönetimi (Subcontractor Management) — Sprint 5

Bu doküman, Sprint 5'te eklenen taşeron yönetimi zincirini kapsar:
**Tedarikçi (Sprint 4, yeniden kullanılır) → Taşeron Sözleşmesi (Subcontract)
→ SOV (Schedule of Values) → Aktivasyon/Fesih → Taşeron Değişiklik Emri
(Subcontract Change Order) → Taşeron Hakedişi (Progress Claim) →
Retention/Avans/Kesinti → Cost Control Commitment Entegrasyonu**.

İlgili diğer dokümanlar: [`docs/cost-control.md`](cost-control.md) (Bütçe +
Maliyet Kontrolü, Sprint 2), [`docs/contracts.md`](contracts.md) (Müşteri
Sözleşmesi + Ek İş, Sprint 3), [`docs/procurement.md`](procurement.md)
(Satın Alma / Purchase Order, Sprint 4).

## 0. KRİTİK — Legacy Taşeron Sistemi (mutlaka okuyun)

Sprint 5'in denetim aşamasında, migration `0024_create_project_finance`'ten
kalma (Sprint 1'den ÖNCE var olan), **bugün hâlâ canlı ve çalışan** bir
taşeron sistemi keşfedildi:

- **`project_subcontractors`** — proje başına düz bir taşeron kaydı (ad,
  şirket, telefon, e-posta, TEK bir `contract_amount`, basit
  `planned/active/completed/cancelled` durumu). Web'de proje "Finans"
  sekmesinde **"Taşeron Ödemeleri"** bölümü olarak (Sprint 5 öncesi adıyla
  "Taşeronlar" — bkz. §0.2) gerçekten kullanılıyor.
- **`project_subcontractor_payments`** — o taşerona GERÇEKTEN ödenen
  tutarlar (voidable, idempotent). `GetProjectFinancialSummary`'nin
  (proje genel bakış sayfasının kullandığı, Cost Control'den TAMAMEN
  AYRI ve daha ESKİ bir hesaplama) `realized_cost`/`committed_cost`
  metriklerine GİRİYOR.

**Bu sprint bu sisteme DOKUNMAMIŞTIR.** Şema, servis, handler, rotalar,
web UI'ı (`SubcontractorsSection`, `FinanceSections.tsx`) — hepsi AYNEN
korunmuştur. Gerekçe:

1. Gerçek, çalışan bir özelliktir — taşerona yapılan GERÇEK ödemeleri
   kaydeder (Sprint 5'in kapsamında olmayan bir "Payment" kavramı zaten
   burada var). Dokunmak, çalışan bir özelliği bozma riski taşır.
2. Finansal ödeme kayıtlarına açık kullanıcı talimatı olmadan veri
   göçü/birleştirme yapmak uygun değildir.
3. Kullanıcının spec'i, Cost Control'ün Committed hesabının **yalnızca
   `project_commitments`** olmasını istiyordu (bkz. §1) — bu zaten
   `project_subcontractors`'a HİÇ dokunmadan sağlanabiliyordu.

### 0.1 İki sistem nasıl ayırt edilir

| | Legacy (`project_subcontractors`) | Yeni (`project_subcontracts`) |
|---|---|---|
| Tablo adı | **subcontractor**s (çoğul, "taşeron kaydı") | **subcontract**s (tekil kavram, "iş sözleşmesi") |
| Vendor kimliği | Kendi gömülü ad/telefon/e-posta alanları (Sprint 4 `suppliers`'tan BAĞIMSIZ, ayrı bir mini-kayıt) | `supplier_id` → Sprint 4 `suppliers` (TEK vendor master, yeniden kullanılır) |
| Yaşam döngüsü | `planned/active/completed/cancelled` (basit) | `draft/active/completed/cancelled/terminated` (tam, baseline-kilitleme) |
| Kalem/SOV | Yok — tek `contract_amount` | `subcontract_items` (Schedule of Values, cost-code/WBS/budget-line bağlı) |
| Değişiklik emri | Yok (yalnızca `change_order_id` etiketi, Sprint 3'ün CUSTOMER change order'ına) | `subcontract_change_orders` (kendi, MALİYET tarafı domaini) |
| Hakediş | Yok — yalnızca düz ödeme kaydı (`project_subcontractor_payments`) | `subcontract_progress_claims` (retention/avans/kesinti, SOV bazlı) |
| Cost Control | `GetProjectFinancialSummary`'ye (Cost Control DIŞI, proje genel bakış) girer | `project_commitments`'e girer (Cost Control'ün TEK kaynağı) |
| Gerçek ödeme | VAR (`project_subcontractor_payments`) | YOK (bu sprintte — bkz. §10 Actual Cost Kararı) |

### 0.2 Web'de yapılan TEK değişiklik

Legacy Finans-sekmesi bölümünün başlığı **"Taşeronlar"dan "Taşeron
Ödemeleri"ne** yeniden adlandırıldı (yalnızca görünen metin — hiçbir
veri modeli/mantık/endpoint DEĞİŞMEDİ) — yeni, çok daha kapsamlı proje
workspace sekmesi de "Taşeronlar" adını taşıdığı için, iki alan arasında
literal isim çakışmasını önlemek amacıyla. Kullanıcı bu adlandırma
kararını isterse geri alabilir/değiştirebilir.

### 0.3 Birleştirme (unification) bu sprintin kapsamında DEĞİLDİR

Bir proje, teorik olarak HEM eski `project_subcontractors` HEM yeni
`project_subcontracts` altında aynı gerçek-dünya taşeronu için ayrı
kayıtlara sahip olabilir — sistem açısından bunlar TAMAMEN BAĞIMSIZ
kayıtlardır. Bu, bilinen ve belgelenmiş bir sınırdır (bkz. §14 Bilinen
Boşluklar). Gelecekte birleştirme/göç kararı ayrı bir kullanıcı kararı
gerektirir.

## 1. Kavramsal Ayrım — Karıştırılmaması Gereken Kavramlar

- **Taşeron Hakedişi ≠ Müşteri Hakedişi.** Müşteri/gelir tarafı hakedişi
  Sprint 6'ya bırakılmıştır — bu sprintte YOKTUR, aynı tabloya
  doldurulmamıştır.
- **Subcontract ≠ Customer Contract (Sprint 3).** Subcontract MALİYET
  (taşeronla) tarafıdır; Contract GELİR (müşteriyle) tarafıdır. Customer
  Change Order taşeron sözleşmesini DEĞİŞTİRMEZ; Subcontract Change Order
  müşteri sözleşmesini DEĞİŞTİRMEZ (test: `27_subcontracts_never_touch_
  customer_contract_or_change_orders`).
- **Subcontract Change Order ≠ Customer Change Order.** Ayrı tablolar
  (`subcontract_change_orders` vs `project_change_orders`), ayrı domain
  struct'ları, ayrı durum makineleri.
- **Certified Claim ≠ Payment.** Sertifikalı bir hakediş, "bu iş
  YAPILDI ve ÖDENECEK" der — "ÖDENDİ" demez. Gerçek ödeme (Supplier
  Invoice/AP) bu sprintin kapsamı DIŞINDADIR (bkz. §10).
- **Purchase Order (Sprint 4) ≠ Subcontract.** PO bir malzeme/hizmet
  siparişidir (genelde tek seferlik, item-seviyesi kalıcı commitment).
  Subcontract süregelen bir iş sözleşmesidir (değişebilir, hakedişli,
  sözleşme-seviyesi yeniden-senkronize edilen commitment). İkisi de AYNI
  `project_commitments` defterine yazar ama FARKLI business entity'lerdir
  (bkz. §5).
- **Committed ≠ Actual.** Bu ayrım Sprint 5'te de KORUNUR — bkz. §10.

## 2. Vendor Modeli — Supplier vs Subcontractor (spec §3)

Sprint 4'ün `suppliers` (organizasyon-seviyeli, paylaşılan vendor master)
tablosu **YENİDEN KULLANILIR** — `project_subcontracts.supplier_id →
suppliers.id`. **Yeni bir taşeron/vendor master tablosu İCAT EDİLMEDİ.**

Herhangi bir AKTİF supplier, hiçbir "capability"/"type" bayrağı
gerekmeksizin bir subcontract'ta `supplier_id` olarak kullanılabilir —
bugüne kadar PO/RFQ/PR ile Subcontract arasında supplier
kullanılabilirliği açısından hiçbir davranış farkı yoktur, bu yüzden
normalize edilmiş bir "tip" alanı GEREKMEDİ (spec'in kendi önerdiği
`supplier_type`/`capabilities` şeması, mevcut şemaya bu kadar basit bir
çözüm varken GEREKSİZ karmaşıklık olurdu).

Tek somut ek: `suppliers.specialty` (branş/uzmanlık alanı, ör.
"Elektrik", "Sıhhi Tesisat") — isteğe bağlı, boş bırakılabilir, salt
bilgilendirici. Sigorta/yeterlilik/uygunluk belgesi metadata'sı (spec
§4'ün "isteğe bağlı" saydığı genişletmeler) BİLİNÇLİ OLARAK bu sprintte
eklenmedi — "devasa vendor prequalification sistemi kurma" talimatına
uyularak.

## 3. Subcontract Şeması ve Yaşam Döngüsü

```
project_subcontracts: id, organization_id, project_id, subcontract_no,
  supplier_id, title, scope_summary, original_amount (items'tan
  TÜRETİLİR — bkz. §4), currency, status, effective_date, start_date,
  planned_completion_date, retention_percent, advance_amount,
  payment_terms, notes, created_by/at, activated_at/by, completed_at/by,
  cancelled_at/by/reason, terminated_at/by/reason
```

Durum makinesi (Sprint 3 Contract'ın AYNI ilkesi, cost-side için
doğrulandı):

```
draft ──activate──▶ active ──complete──▶ completed (terminal)
  │                     │
  │                     └──terminate (gerekçe zorunlu)──▶ terminated (terminal)
  │
  └──cancel (terminal, commitment hiç yok — no-op)
```

- **DRAFT**: SOV kalemleri serbestçe eklenir/düzenlenir/silinir
  (`UpdateSubcontractDraft`, `WHERE status='draft'` korumalı).
- **ACTIVE**: ticari taban (`original_amount` ve SOV) KİLİTLENİR, her
  SOV kalemi Cost Control commitment'ına YANSITILIR (bkz. §5). Sonraki
  ticari değişiklik SADECE Subcontract Change Order üzerinden yapılır.
- **COMPLETED**: normal tamamlanma — commitment'a DOKUNMAZ (bkz. §5.3,
  PO'nun "closed" durumuyla AYNI ilke).
- **CANCELLED**: yalnızca DRAFT'tan (spec §7/§15 — "DRAFT cancelled:
  commitment hiç oluşmamış olmalı", trivially doğru çünkü commitment
  yalnızca aktivasyonda oluşur).
- **TERMINATED**: yalnızca ACTIVE'ten, gerekçe zorunlu — bkz. §7.

`current_subcontract_value = original_amount + Σ(onaylı ekler) −
Σ(onaylı eksiltmeler)` — Contract'ın `current_contract_value`'sunun
AYNI ilkesi, HER ZAMAN canlı türetilir (`GetSubcontractCurrentValue`),
asla stored bir kolon DEĞİLDİR.

## 4. Schedule of Values (SOV)

```
subcontract_items: id, organization_id, project_id, subcontract_id,
  wbs_node_id?, cost_code_id (ZORUNLU), budget_line_id?, description,
  quantity?, unit?, unit_price?, original_amount, sort_order
```

`quantity`/`unit`/`unit_price` ÜÇÜ de opsiyoneldir — bazı SOV kalemleri
toplu/lump-sum olabilir (ör. "Genel Temizlik Hizmeti — 5.000 TL",
anlamlı bir miktar/birim-fiyat kırılımı olmadan). `original_amount` HER
ZAMAN zorunludur: ikisi de (`quantity`+`unit_price`) doluysa SQL'de
`round(quantity×unit_price,2)` olarak yeniden hesaplanır, aksi halde
istemcinin gönderdiği değer OLDUĞU GİBİ kullanılır
(`project_budget_lines`/PR kalemleriyle AYNI "kısmi doluluk" kuralı,
bkz. `docs/cost-control.md` §6).

`cost_code_id` ZORUNLUDUR (PO kalemleriyle AYNI gerekçe — bu tablo
commitment'ın DOLAYLI kaynağıdır, bkz. §5).

**Tek source-of-truth politikası (spec §9'un açık talebi):** SOV
kalemleri TEK doğruluk kaynağıdır. `project_subcontracts.original_amount`
her zaman `RecomputeSubcontractTotal` ile kalemlerden YENİDEN
HESAPLANIR — asla bağımsız/doğrudan yazılabilir bir alan değildir.

## 5. Cost Control Commitment Entegrasyonu — EN KRİTİK BÖLÜM

Sprint 2'nin mevcut `project_commitments` genel taahhüt sistemi
YENİDEN KULLANILIR — Sprint 5'e özel paralel bir ikinci ledger
OLUŞTURULMADI. `project_commitments.source_type='subcontract'`,
Sprint 2'den beri (migration 0035) CHECK constraint'inde rezerve
edilmiş ama Sprint 5'e kadar HİÇBİR kod yolunun yazmadığı bir değerdi —
bu sprint onu GERÇEKTEN yazan ilk kod yoludur.

### 5.1 Granülerlik kararı — PO'dan BİLİNÇLİ SAPMA

Sprint 4'ün Purchase Order'ı **İTEM seviyesinde, KALICI/tek seferlik**
bir commitment modeli kullanır (`source_id = purchase_order_items.id`,
onaydan sonra asla değişmez — yalnızca PO iptalinde toptan voidlenir).

Bir Subcontract'ın taahhüdü ise **YAŞAM BOYU DEĞİŞEBİLİR** (değişiklik
emirleri onaylanabilir, sözleşme feshedilebilir) — bu yüzden Subcontract
**SÖZLEŞME seviyesinde** (`source_id = project_subcontracts.id`) bir
model kullanır ve her ticari olayda (aktivasyon / değişiklik onayı /
fesih) **tam bir yeniden senkronizasyon** yapılır:

```
syncSubcontractCommitments(subcontractID, targets):
  1. Bu sözleşmeden doğan TÜM aktif commitment'ları VOIDLE
     (source_type='subcontract' AND source_id=subcontractID AND status='active')
     — idempotent (zaten voided olanlar status='active' koşuluyla dışlanır).
  2. targets'taki HER (cost_code_id, budget_line_id) grubu için (yalnızca
     pozitif net tutarlı gruplar) TEK bir YENİ commitment satırı oluştur.
```

`targets`, çağıran bağlama göre HESAPLANIR:

| Olay | targets kaynağı |
|---|---|
| Aktivasyon | SOV kalemleri, maliyet-kodu/bütçe-kalemi başına toplanmış |
| Değişiklik onayı | SOV kalemleri + TÜM onaylı değişiklik kalemleri, NETLENMİŞ (ekleme +, eksiltme −) |
| Fesih | SOV kalemleri YERİNE, her SOV kaleminin en son SERTİFİKALI hakedişteki kümülatif tutarı (bkz. §7) |

Bu tasarım, negatif/kısmi commitment mutasyonu İCAT ETMEDEN (schema
`committed_amount > 0` CHECK'ini asla ihlal etmeden) yalnızca var olan
void+create desenini (PO'nun `CancelPurchaseOrder`'ı İLE AYNI idiom)
tekrar kullanır. Kaybedilen tek şey PO'nun item-seviyesi izlenebilirliği
(`project_commitments`'tan hangi SOV kaleminin/değişikliğin katkı
verdiğini DOĞRUDAN okuyamazsınız) — ama bu bilgi zaten Subcontract'ın
KENDİ detay ekranında (SOV + değişiklik listesi) ayrıca görünür
durumdadır, Cost Control yalnızca (maliyet-kodu, bütçe-kalemi,
tutar) üçlüsüyle ilgilenir.

### 5.2 Aktivasyon

`ActivateSubcontract`: `draft→active` (guard'lı UPDATE) → SOV
kalemlerinden `targets` hesaplanır → `syncSubcontractCommitments`
çağrılır. Test: `5_activation_creates_commitment_exactly_once`,
`6_double_activation_rejected_idempotent_commitment`,
`29_double_activation_concurrency_exactly_one_commitment_set`.

### 5.3 Tamamlanma (Completion)

`CompleteSubcontract`: commitment'a **KESİNLİKLE DOKUNMAZ** (PO'nun
`ClosePurchaseOrder`'ıyla AYNI ilke) — tam güncel değer, gerçek bir
Tedarikçi Faturası/AP kaydı yerini alana kadar taahhüt olarak kalır.
Test: `10_completion_does_not_touch_commitment`.

### 5.4 Değişiklik Onayı

`ApproveSubcontractChangeOrder`: yalnızca SUBMITTED→APPROVED geçişinde
(ve sözleşme HÂLÂ ACTIVE ise, FOR UPDATE kilitli) `targets` yeniden
hesaplanır (SOV + tüm onaylı değişiklikler, NETLENMİŞ) ve
`syncSubcontractCommitments` çağrılır. DRAFT/SUBMITTED/REJECTED bir
değişikliğin HİÇBİR etkisi yoktur. Test: `12`–`17`, `25`, `30`.

### 5.5 Fesih (Termination) — spec §15/§39'un tam uygulanışı

> "earned/certified amount korunur, remaining unperformed commitment
> release edilir"

`TerminateSubcontract`: ACTIVE→TERMINATED (gerekçe zorunlu) →
`GetSubcontractTerminationTargets` (her SOV kaleminin en son
SERTİFİKALI hakedişteki `cumulative_progress_amount`'ı, maliyet-kodu/
bütçe-kalemi başına NETLENMİŞ) → `syncSubcontractCommitments`.

**Sonuç**: henüz sertifika edilmemiş (performe edilmemiş) kısım
TAMAMEN SERBEST BIRAKILIR; şu ana kadar sertifikalı kısım TEK bir yeni
commitment olarak KALIR (gerçek bir kalan yükümlülük — taşerona zaten
yapılmış işin karşılığı hâlâ ödenecektir). Sertifikalı hakediş
KAYITLARININ KENDİSİ (`subcontract_progress_claims`) bu işlemden HİÇ
ETKİLENMEZ — yalnızca `project_commitments` senkronize edilir, tarihi
kayıtlar dokunulmadan kalır.

**Altın regresyon testi** (`26_termination_golden_regression`, spec
§39'un AYNI sayılarıyla):

```
Subcontract:              500.000
Onaylı ek:                +50.000
Fesih ÖNCESİ current:      550.000
Sertifikalı (certified):   200.000
Fesih.
Fesih SONRASI Committed:   200.000  (= yalnızca sertifikalı kısım)
Actual:                    DEĞİŞMEDİ
Hakediş kaydı (200.000):   DEĞİŞMEDİ/SİLİNMEDİ
```

## 6. Subcontract Change Order (spec §12-14)

Customer Change Order (Sprint 3) tablosu **ASLA yeniden kullanılmaz** —
MALİYET tarafı için tamamen ayrı, bağımsız bir domain:

```
subcontract_change_orders: id, organization_id, project_id,
  subcontract_id, number, title, description, change_type
  (addition|deduction), amount (items'tan TÜRETİLİR), status
  (draft|submitted|approved|rejected|cancelled), reason,
  requested_at, approved_at/by, rejected_at/by/reason, cancelled_at/by,
  created_by/at

subcontract_change_order_items: id, ..., change_order_id, wbs_node_id?,
  cost_code_id (ZORUNLU), budget_line_id?, description, amount
```

Satır bazlı etki desteklenir (spec §13) — header `amount`, kalemlerden
`RecomputeSubcontractChangeOrderTotal` ile TÜRETİLİR. Yalnızca `APPROVED`
durumu `current_subcontract_value` VE commitment'ları etkiler (bkz. §5.4)
— değişiklik yalnızca sözleşme ACTIVE iken oluşturulabilir/onaylanabilir
(`ErrSubcontractNotActiveForChange`).

## 7. Progress Claim (Taşeron Hakedişi) — spec §16-22

Müşteri hakedişi DEĞİLDİR (Sprint 6'ya bırakıldı), Supplier Invoice
DEĞİLDİR, Payment DEĞİLDİR (bkz. §10).

```
subcontract_progress_claims: id, organization_id, project_id,
  subcontract_id, claim_number, period_start?, period_end, status
  (draft|submitted|certified|rejected|cancelled), gross_work_amount,
  retention_percent_snapshot, retention_amount, advance_recovery_amount,
  other_deductions, previous_certified_amount, current_certified_amount,
  net_payable, submitted_at, certified_at/by, rejected_at/by/reason,
  cancelled_at/by, notes, created_by/at

subcontract_progress_claim_items: id, ..., progress_claim_id,
  subcontract_item_id, scheduled_value (SNAPSHOT), previous_progress_
  amount, current_progress_amount, cumulative_progress_amount
  (previous+current, backend hesaplı), sort_order
```

### 7.1 Snapshot ilkesi

`scheduled_value` (kalem) ve `retention_percent_snapshot` (header),
hakediş OLUŞTURULDUĞU ANDAKİ SOV kalemi tutarının/sözleşme retention
oranının KOPYASIdır. Sonradan bir değişiklik emri o SOV kalemini
etkilerse veya sözleşmenin retention oranı değişirse, GEÇMİŞ hakedişler
SESSİZCE MUTATE OLMAZ (spec §19'un açık talebi).

### 7.2 Previous/Current/Cumulative

`previous_progress_amount`, o SOV kalemi için en son **SERTİFİKALI**
hakedişteki kümülatif tutardan OTOMATİK doldurulur (draft/submitted/
rejected/cancelled hiçbir hakedişin rakamı "previous" zincirine
SIZMAZ — test `24_rejected_claim_reason_required_and_no_effect`).
`cumulative_progress_amount = previous + current`, backend'de
hesaplanır. **DB CHECK** (`cumulative_progress_amount <= scheduled_
value`) %100 üstü aşımı hem Go hem DB seviyesinde engeller (test
`20_cumulative_overrun_rejected`).

**Onaylı değişiklikler ve sınırlar (2026-10).** Değişiklik emri kalemleri
bir SOV kalemine değil (maliyet kodu, bütçe kalemi) grubuna bağlıdır; bu
yüzden sınırlar o grup üzerinden uygulanır (`subcontract_claim_caps.go`):
kalem kümülatifi ≤ kalem tutarı + grubun onaylı net eki (`scheduled_value`
snapshot'ı budur); grubun kümülatif toplamı ≤ grubun SOV toplamı + grubun
onaylı net değişikliği; tüm kalemlerin toplamı ≤ güncel sözleşme tutarı.
Ek iş böylece hakedişe girilebilir, eksiltme sınırı düşürür. Sertifika
anında sınırlar sözleşme satırı kilitliyken yeniden kontrol edilir. Bir
eksiltme, sözleşmeyi (veya dokunduğu grubu) sertifikalı ya da ödenmiş
tutarın altına indiriyorsa onaylanamaz. Aynı SOV kalemi bir hakedişte
yalnızca bir kez yer alabilir.

### 7.3 Retention / Avans / Kesinti — Net Payable Formülü (spec §22)

```
Net Payable = Gross Certified Work − Retention − Advance Recovery − Other Deductions
Retention   = round(Gross × retention_percent_snapshot / 100, 2)
```

Tamamı backend-authoritative (`RecomputeSubcontractProgressClaimTotals`,
her zaman SQL'de hesaplanır — istemcinin gönderdiği hiçbir toplam
GÜVENİLMEZ). Örnek (test `21_money_exact_retention_advance_deduction_
net_payable`, spec §37'nin AYNI sayılarıyla):

```
Gross:            100.000,00
Retention (%5):     5.000,00
Advance Recovery:  10.000,00
Other Deduction:    2.500,00
Net Payable:       82.500,00
```

### 7.4 Yaşam Döngüsü ve Eşzamanlılık

```
draft ──submit──▶ submitted ──certify──▶ certified (terminal, İMMUTABLE)
                       │
                       └──reject (gerekçe zorunlu)──▶ rejected (terminal)
{draft,submitted} ──cancel──▶ cancelled (terminal)
```

**Certified bir hakediş SESSİZCE düzenlenemez/iptal edilemez** (test
`22_submit_certify_lifecycle_and_immutability`). Düzeltme gerekiyorsa
yeni bir hakediş (revizyon/ters kayıt) oluşturulmalıdır — bu sprintte
resmi bir "reversal" mekanizması İNŞA EDİLMEDİ, ileride ayrı bir karar
olarak bırakıldı.

**Eşzamanlılık koruması** (`CertifyProgressClaim`): sertifika ETMEDEN
ÖNCE, hakedişin HER kalemi için `previous_progress_amount`'ın HÂLÂ
doğru olduğu (aradan başka bir hakediş sertifika edilip taban
KAYMADIĞI) yeniden doğrulanır — kaymışsa `ErrProgressClaimStale` ile
REDDEDİLİR (sessizce yanlış rakam üretmek yerine, kullanıcıdan hakedişi
güncelleyip tekrar denemesi istenir). Bu, "iki hakediş aynı SOV kalemi
için yarışırsa" senaryosunun TEK doğru çözümüdür. Test:
`31_double_claim_certification_concurrency`,
`32_termination_concurrent_with_certification`.

## 8. Cost Code / Budget Line / WBS Eşleme (spec §10)

Her subcontract kalemi (SOV, değişiklik kalemi) mümkün olan yerde WBS/
Cost Code/Budget Line ile ilişkilendirilir. `cost_code_id` ZORUNLUDUR
(commitment'ın doğrudan kaynağı). Çapraz-proje bütçe kalemi eşlemesi
KESİNLİKLE YASAKTIR — mevcut `resolveCostCodeRef`/`resolveBudgetLineRef`/
`resolveWBSParentRef` yardımcıları (Sprint 2'den, PO/PR'ın da kullandığı)
DOĞRUDAN yeniden kullanıldı, hiçbir yeni Go doğrulama mantığı İCAT
EDİLMEDİ. Test: `11_cross_project_budget_line_rejected`.

## 9. Numaralandırma (spec §33)

`SC-YYYY-NNNN` (Subcontract), `SCO-YYYY-NNNN` (Change Order),
`SPC-YYYY-NNNN` (Progress Claim) — Sprint 4'ün PR/RFQ/PO ile AYNI
organizasyon+yıl kapsamlı, atomik `INSERT...ON CONFLICT DO UPDATE
SET seq=seq+1 RETURNING seq` deseni. `SELECT MAX+1` KULLANILMADI. Test:
`28_number_generation_race`.

## 10. Actual Cost Kararı (spec §23 — zorunlu açıklama)

**Soru: Sertifikalı (certified) bir taşeron hakedişi Cost Control'ün
Actual'ına giriyor mu?**

**Cevap: HAYIR, bu sprintte girmiyor.**

### Gerekçe

1. `project_expenses` tablosunun KENDİ migration yorumu (0024, Sprint
   1'den önce) şunu AÇIKÇA belirtir: taşerona ödenen para TEK bir
   kapıdan (`project_subcontractor_payments`) geçmelidir, aksi halde
   aynı ödeme HEM expense HEM subcontractor-payment olarak iki kez
   sayılabilir ("tek finansal kaynak" ilkesi). Bu, Sprint 5'in şu anda
   değerlendirdiği SENARYONUN AYNISI için repo'nun KENDİ, önceden var
   olan koruma ilkesidir.
2. Sprint 5 açıkça Supplier Invoice/AP/Payment'ı KAPSAM DIŞI bırakır
   (spec §26-27). Bu demektir ki, yeni sistemde henüz "gerçek ödeme"
   diye bir olay YOKTUR — sertifikalı bir hakediş, "iş yapıldı ve
   ÖDENECEK" der, "ÖDENDİ" demez.
3. `project_commitments.source_type='subcontract'` zaten mevcut, doğru
   genişletme noktasıdır (Committed tarafı için) — Actual için ayrı,
   Sprint 6+'da inşa edilecek bir yol (Supplier Invoice) gereklidir.

### Sonuç: Sertifikalı hakediş NE etkiler, NE etkilemez

| | Etkiler mi? |
|---|---|
| `current_subcontract_value` | HAYIR — yalnızca onaylı Change Order etkiler |
| Cost Control **Committed** (normal operasyon) | HAYIR — sözleşme ACTIVE olduğu sürece TAM güncel değer commitment olarak kalır (PO'nun felsefesiyle AYNI: "kapanana kadar tam taahhüt") |
| Cost Control **Committed** (FESİH sırasında) | EVET, dolaylı olarak — bkz. §5.5 (yalnızca fesihte, kalan/sertifikalı ayrımı devreye girer) |
| Cost Control **Actual** | **HAYIR, hiçbir zaman bu sprintte** |
| Subcontract'ın KENDİ "Remaining Commitment" metriği | EVET — bkz. §11 |

### Ne zaman Actual'a girecek?

**Gelecek yol haritası** (Sprint 6+): bir Supplier Invoice/AP modülü
inşa edildiğinde, sertifikalı bir hakediş bu faturanın TETİKLEYİCİSİ
olmalı (veya doğrudan bir faturaya dönüştürülebilir olmalı) — ve o
FATURA (hakedişin kendisi DEĞİL) `project_expenses`'in "tek gerçek
kaynak" ilkesini koruyarak Actual'ı besleyecektir — `project_expenses`
şu an nasıl "gerçek kaydedilmiş işlem" temsil ediyorsa, aynı ilkeyle.

## 11. Remaining Commitment (spec §24)

Subcontract detay ekranında gösterilen, Cost Control'ün Committed/
Actual'ından AYRI, bilgilendirici bir metrik:

```
Remaining Commitment = current_subcontract_value − Certified To Date
Certified To Date    = Σ (her SOV kaleminin en son SERTİFİKALI hakedişteki cumulative_progress_amount'ı)
```

`GetSubcontractValue` servis metodu ile hesaplanır
(`GetSubcontractCurrentValue` + `GetSubcontractCertifiedToDate` SQL
sorgularının birleşimi). **Bu, Cost Control'ün Committed'i İLE
KARIŞTIRILMAMALI** — normal operasyonda Committed HER ZAMAN tam güncel
değerdir (§10), Remaining Commitment ise yalnızca bu EKRANA özgü,
"ne kadarı henüz sertifika edilmedi" sorusuna cevap veren ayrı bir
görünümdür.

## 12. İzinler (spec §28)

```
projects.subcontracts.read / .manage / .approve
projects.subcontract_claims.read / .manage / .certify
```

İKİ ayrı üçlü — hakediş sertifikasyonu sözleşme onayından farklı bir
karar anı olabileceği için ayrı izinlerle modellendi (spec'in kendi
önerisi).

| Rol | subcontracts | subcontract_claims |
|---|:-:|:-:|
| Owner / Admin | read+manage+approve | read+manage+certify |
| Finance | read+manage+approve | read+manage+certify |
| **Project Manager** | read+manage (**approve YOK**) | read+manage (**certify YOK**) |
| **Legacy User** | read+manage (**approve YOK**) | read+manage (**certify YOK**) |
| Field | — (hiçbiri) | — (hiçbiri) |

PM/Legacy'nin `approve`/`certify` alamaması, Contract'taki "lifecycle
asla otomatik miras alınmaz" kararıyla BİREBİR AYNI ilkedir — bunlar
YENİ eylem sınıflarıdır, eski rolün bunlara karşılık gelen bir geçmişi
yoktur. Test: `TestSubcontractSecurityMatrix` (14 senaryo).

## 13. Güvenlik

- **Kiracı izolasyonu**: her yeni kaynak türü (Subcontract, SOV kalemi,
  Change Order, Progress Claim) organizasyon-scoped'dur.
- **Proje üyeliği**: Sprint 1'in mevcut modeli uygulanır.
- **Çapraz-org tedarikçi**: bir organizasyona ait tedarikçi başka bir
  organizasyonun projesinde subcontract'ta KULLANILAMAZ (test
  `2_cross_tenant_supplier_denied`).
- **IDOR**: Project A URL'i + Project B'nin Subcontract/Change-Order/
  Claim UUID'i → 404 (test `11`-`13`, `TestSubcontractSecurityMatrix`).
- **Eşzamanlılık**: aktivasyon, değişiklik onayı, sertifikasyon,
  numaralandırma, fesih-vs-sertifikasyon yarışları — hepsi test edildi
  (bkz. §5.2, §5.5, §7.4, §9).

## 14. Kapsam Dışı / Bilinen Boşluklar

- Müşteri (customer) hakedişi — Sprint 6.
- Supplier Invoice / Accounts Payable / gerçek Payment — Sprint 6+
  (bkz. §10 Gelecek Yol Haritası).
- Legacy `project_subcontractors` sisteminin yeni sistemle
  BİRLEŞTİRİLMESİ — bilinçli olarak yapılmadı (bkz. §0.3).
- Tam Türk vergi/tevkifat/e-Fatura entegrasyonu — yok.
- Tam döviz kuru (FX) motoru — yok; subcontract kendi para birimini
  (proje para biriminden türetilmiş) takip eder, yanlış bir dönüşüm
  ASLA hesaplanmaz.
- Sertifikalı bir hakedişin resmi "reversal"/revizyon mekanizması —
  bu sprintte İNŞA EDİLMEDİ (bkz. §7.4).
- Saha (Field) rolü için basit bir hakediş/talep görünürlüğü —
  DEĞERLENDİRİLDİ ama kapsam büyümesi riski nedeniyle ERTELENDİ (mevcut
  "sahada finansal görünürlük yok" ilkesiyle tutarlı).
- Mobilde yalnızca OKUMA (Subcontract + Progress Claim liste/detay,
  `projects.subcontracts.read` ile korunur) — oluşturma/onay/
  sertifikasyon/değişiklik-emri mobilde YOK (web-first ilkesi, Sprint
  2/3/4 ile aynı).
