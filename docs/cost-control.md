# Maliyet Kontrolü Modülü — Teknik Dokümantasyon

> ARVEND V2 — Sprint 2: WBS + Maliyet Kodları + Proje Bütçesi + Maliyet
> Kontrolü. Bu doküman, projenin gerçek inşaat maliyet kontrolü
> altyapısının veri modelini, formüllerini, yetkilendirme mantığını ve
> API'sini uçtan uca anlatır. Kod tabanındaki gerçek dosya/satırlara
> referans verir; herhangi bir değişiklikte bu doküman da
> güncellenmelidir.

---

## 1. Genel Bakış ve Amaç

Bu modül, ARVEND'in gelecekteki tüm mali yol haritasının (Satınalma,
Satınalma Siparişleri, Taşeron Yönetimi, Hakediş, Faturalama, Nakit
Akışı, Portföy Kârlılığı) üzerine kurulacağı **finansal omurgadır**.
Amaç, bir Proje Yöneticisi/Finans kullanıcısının şu soruları
yanıtlayabilmesidir:

- Orijinal bütçe nedir, maliyet koduna göre kırılımı nasıldır?
- Bütçe ne kadar revize edildi (ve hangi gerekçeyle)?
- Şu ana kadar ne kadar taahhüt edildi, ne kadar gerçekleşti?
- Kalan tahmini maliyet (ETC) ve nihai tahmini maliyet (EAC) nedir?
- Hangi maliyet kodu bütçeyi aşıyor?
- Projenin tahmini nihai kârı/marjı nedir?

**Bu sprintte YAPILMAYANLAR** (bilinçli kapsam dışı — spec'in kendi
sınırı): Satınalma/RFQ/Satınalma Siparişi, tedarikçi teklif
karşılaştırma, taşeron yönetimi modülü, müşteri/taşeron hakediş
(progress claim), faturalama motoru, e-Fatura, tahsilat yeniden
tasarımı, Gantt/zamanlama motoru, RFI/Submittal/Doküman Kontrolü,
Envanter, Ekipman, CRM, AI, çoklu para birimi/FX motoru, tam
muhasebeleştirme, production deploy. Bunların hiçbiri bu sprintte
inşa edilmedi; şema yalnızca gelecekteki genişlemeye (özellikle
Satınalma Siparişi/Taşeron kaynaklı taahhütler) hazır bırakıldı (bkz.
§5).

---

## 2. Kritik Kavram Ayrımları

Bu modülde birbirine karıştırılan kavramlar ciddi hesap hatalarına yol
açar. Aşağıdakiler KESİNLİKLE farklı şeylerdir:

| Kavram A | Kavram B | Fark |
|---|---|---|
| **WBS** (İş Kırılım Yapısı) | **Cost Code** (Maliyet Kodu) | WBS, işi FİZİKSEL/İŞLEVSEL olarak gruplar (ör. "100 · Kaba İnşaat" → "110 · Temel"). Cost Code, maliyetin TÜRÜNÜ tanımlar (ör. "Malzeme", "İşçilik") ve organizasyon-seviyeli, projeler arası PAYLAŞILAN bir katalogdur. Bir bütçe kalemi HER İKİSİNE de (WBS opsiyonel, Cost Code zorunlu) sahip olabilir. |
| **Budget** (Bütçe) | **Expense** (Masraf) | Budget, PLANLANAN maliyettir (ne harcanacağı). Expense, GERÇEKLEŞEN maliyettir (ne harcandığı) — mevcut `project_expenses` tablosu. |
| **Budget** | **Offer/Teklif** | Offer, MÜŞTERİYE satılan fiyattır (gelir). Budget, İÇ maliyet planıdır. Bkz. §3 — offer'dan bütçe TÜRETİLMEZ. |
| **Committed** (Taahhüt) | **Paid** (Ödendi) | Committed, bir maliyetin YAPILMASI için verilen sözdür (henüz fatura/ödeme yok). Paid, gerçekten nakit çıkışı olan tutardır — bu ayrım gelecekteki Satınalma/Taşeron modülleri için önemlidir. |
| **Actual** (Gerçekleşen) | **Forecast** (Tahmin) | Actual, GEÇMİŞTE olan (kayıtlı masraf). Forecast (ETC), GELECEKTE olacağı tahmin edilen kalan maliyettir. |
| **Revenue** (Gelir) | **Cost Budget** (Maliyet Bütçesi) | Revenue, sözleşme bedelidir (`projects.contract_amount` + onaylı ek işler). Cost Budget, bu geliri elde etmek için harcanacak İÇ maliyettir — ikisi arasındaki fark kârdır, biri diğerinden TÜRETİLEMEZ. |
| **Change Order** (Ek İş) | **Budget Adjustment** (Bütçe Revizyonu) | Change Order, SÖZLEŞME bedelini (müşteriyle) değiştirir (`project_change_orders`, mevcut Faz 8 altyapısı). Budget Adjustment, İÇ bütçeyi (baseline sonrası) değiştirir. İkisi AYRI tablolardır ve otomatik birbirine bağlanmaz (bkz. §8). |

---

## 3. Neden Offer Geliri Otomatik Olarak Maliyet Bütçesi Değildir

Sprint 2'nin başında, mevcut teklif/hesaplama (offer/calc) zincirinin
**tam bir denetimi** yapıldı (5 paralel araştırma ajanı ile):
`offers`, `offer_revisions`, `offer_revision_items`, `calc_groups`,
`calc_categories`, `calc_recipe_items` — hiçbirinde **güvenilir bir
maliyet alanı bulunamadı**. Zincir yalnızca **satış fiyatını** taşır:

- `offer_revision_items.unit_price` → satış birim fiyatı.
- `calc_recipe_items` katsayıları → metraj/miktar hesaplama içindir,
  bir maliyet TABANI değildir (fiyatlandırma parametresi, maliyet
  kaydı değil).
- `project_change_order_items.estimated_unit_cost/estimated_cost` →
  var ama **hiçbir yerde agregatlanmıyor** (tamamen etkisiz/kullanılmayan
  alanlar).

Bu nedenle **yeni bir proje, offer'dan dönüştürüldüğünde HER ZAMAN boş
(sıfır kalemli) bir taslak bütçe alır** (`ProjectService.CreateFromOffer`,
bkz. `backend/internal/service/project_service.go`) — `offer.grand_total`
yalnızca `projects.contract_amount`'a (gelir tarafı) kopyalanır, maliyet
bütçesine ASLA otomatik yansımaz. Kullanıcı, gerçek maliyet kalemlerini
(WBS/Cost Code/Miktar/Birim Fiyat ile) elle girer.

**Bilinen boşluk (gap) olarak raporlanır, icat edilerek kapatılmaz**:
Gerçek bir maliyet tabanı (ör. tedarikçi fiyat listesi, geçmiş proje
maliyetleri) bugün sistemde YOKTUR — bu sprint bunu icat etmez, yalnızca
gerçeği yansıtır.

---

## 4. Veri Modeli

Migration: `backend/db/migrations/0035_create_cost_control_foundation.up.sql`

### 4.1 `organization_cost_codes` — organizasyon-seviyeli maliyet kodu kataloğu

| Kolon | Tip | Açıklama |
|---|---|---|
| `id` | `uuid` PK | |
| `organization_id` | `uuid` FK | Tenant-scoped |
| `code` | `varchar(30)` | UNIQUE `(organization_id, code)` |
| `name`, `description`, `category` | metin | Kategori serbest metindir (ör. "Malzeme", "İşçilik") — sabit bir enum DEĞİLDİR |
| `is_active` | `boolean` | **HARD DELETE YOK** — yalnızca `is_active=false` (arşiv). Geçmiş bütçe kalemi/taahhüt/gider kayıtları bu koda referans veriyor olabilir. |

### 4.2 `project_wbs_nodes` — proje-özel hiyerarşik WBS

| Kolon | Tip | Açıklama |
|---|---|---|
| `id`, `organization_id`, `project_id` | | |
| `parent_id` | `uuid`, nullable, self-FK | NULL = kök düğüm |
| `code`, `name`, `sort_order` | | UNIQUE `(project_id, code)` |
| `is_active` | `boolean` | Arşiv, hard-delete değil |

Tutarlılık trigger'ı (`project_wbs_nodes_check_consistency`): self-parent
ve farklı proje/organizasyona ait parent'ı reddeder. **Döngü (cycle)
oluşamaz** çünkü UI parent_id'yi yalnızca CREATE anında kabul eder,
sonradan re-parent etme UCU YOKTUR (`UpdateWBSNode` yalnızca
rename/reorder yapar) — bu, spec'in "karmaşık drag/drop zorunlu değil"
basitlik talebinin doğrudan sonucudur.

### 4.3 `project_budgets` — proje başına TEK bütçe

| Kolon | Tip | Açıklama |
|---|---|---|
| `id`, `organization_id`, `project_id` | | UNIQUE `(project_id)` — bir projede yalnızca BİR bütçe olabilir |
| `currency` | `varchar(3)` | Projenin para birimiyle AYNI (bkz. §9) |
| `status` | `draft` \| `baselined` | Tek yönlü geçiş, geri dönüş YOK |
| `version` | `integer` | Bilgilendirici sayaç (her baseline'da +1) |
| `created_by`, `baselined_at`, `baselined_by` | | |

### 4.4 `project_budget_lines` — bütçe kalemleri

| Kolon | Tip | Açıklama |
|---|---|---|
| `id`, `organization_id`, `project_id`, `budget_id` | | `budget_id` → `project_budgets(id)` **ON DELETE CASCADE** |
| `wbs_node_id` | nullable FK | Opsiyonel |
| `cost_code_id` | FK | **Zorunlu** |
| `description`, `quantity`, `unit`, `unit_cost` | | `quantity`/`unit_cost` opsiyonel |
| `original_amount` | `numeric(18,2)` | **Backend tarafından hesaplanır** (bkz. §6) |
| `notes` | | |

### 4.5 `project_budget_adjustments` — baseline SONRASI revizyonlar

| Kolon | Tip | Açıklama |
|---|---|---|
| `budget_id`, `budget_line_id` | FK | `budget_id` CASCADE, `budget_line_id` RESTRICT |
| `amount` | `numeric(18,2)` CHECK `<> 0` | Negatif = azaltım |
| `reason` | metin, zorunlu | |
| `status` | `draft` \| `approved` \| `rejected` | **YALNIZCA `approved` olanlar revize bütçeyi etkiler** |
| `created_by`, `approved_by`, `approved_at` | | |

### 4.6 `project_commitments` — taahhüt ledger'ı (bu sprint: yalnızca manuel)

| Kolon | Tip | Açıklama |
|---|---|---|
| `budget_line_id` | nullable FK | NULL = "bütçe dışı" (unbudgeted) taahhüt |
| `cost_code_id` | FK, zorunlu | |
| `source_type` | `manual` \| `purchase_order` \| `subcontract` | **Bu sprint SADECE `manual` üretilir** — şema gelecekteki Satınalma/Taşeron modülleri için hazır, ama sahte kayıt İCAT EDİLMEZ (bkz. §5) |
| `source_id` | nullable | Bu sprintte her zaman NULL |
| `committed_amount` | `numeric(18,2)` CHECK `> 0` | |
| `status` | `active` \| `voided` | Voided taahhütler toplamdan DIŞLANIR |
| `idempotency_key` | nullable, partial UNIQUE `(project_id, idempotency_key)` | Çift-tıklama koruması (mevcut expense/collection deseniyle AYNI) |

### 4.7 `project_cost_forecasts` — manuel ETC override

| Kolon | Tip | Açıklama |
|---|---|---|
| `budget_line_id` | FK, UNIQUE | Bir kalem için EN FAZLA bir override |
| `etc_amount` | `numeric(18,2)` CHECK `>= 0` | |
| `note`, `updated_by`, `updated_at` | | |

### 4.8 `project_expenses` / `project_subcontractors` — genişletildi (backward-compatible)

Yeni **nullable** kolonlar eklendi: `project_expenses.cost_code_id`,
`project_expenses.budget_line_id`, `project_subcontractors.cost_code_id`
(taşeronun `budget_line_id`'si YOKTUR — yalnızca cost_code_id üzerinden
kırılıma katkı verir). **Mevcut satırlar NULL kalır, hiçbir geriye dönük
veri bozulmaz.** Actual Cost, bu tablo ÜZERİNDEN okunur — paralel bir
ledger OLUŞTURULMAZ (spec'in en kesin şartı).

### 4.9 `organization_events` — yeni, minimal denetim tablosu

Migration 0033'ün kendi yorumundaki ilkeye ("her domain kendi
`*_events` tablosunu kullanır, paylaşılan genel bir `audit_log` YOKTUR")
sadık kalınarak eklendi — proje-bağımsız (kuruluş-seviyeli) olaylar
(maliyet kodu oluşturma/güncelleme/arşivleme) için. Ne mevcut
`project_events`'e (proje-özel) ne de `platform_audit_events`'e (Super
Admin/platform-özel) zorlanmadı.

---

## 5. Committed Cost — Çift Kaynak Riski Nasıl Çözüldü

"Taahhüt" tek bir tabloda YAŞAMAZ: `project_commitments` (manuel) VE
mevcut `project_subcontractors.contract_amount` (iptal edilmemiş
olanlar) **İKİSİ BİRLİKTE** agregatlanır (bkz.
`ListCostControlLines`/`GetProjectCostControlSummary` SQL'i). Bu, iki
amacı AYNI ANDA karşılar:

1. Taşeron sözleşmeleri (mevcut, Faz 8'den beri var olan veri) tekrar
   girilmeye ZORLANMAZ.
2. Yeni manuel taahhütler AYRI bir tabloda, gelecekteki Satınalma/
   Taşeron modülleri için genişletilebilir bir şemada tutulur.

Taşeron sözleşmesi verisi `project_commitments`'e KOPYALANMAZ/MİGRATE
EDİLMEZ — yalnızca okuma anında birleştirilir (UNION), tek bir kaynak
korunur.

---

## 6. Bütçe Kalemi Tutarı — Backend Otoriter Hesaplama

`quantity` VE `unit_cost` alanlarının İKİSİ de doluysa:

```
original_amount = round(quantity × unit_cost, 2)
```

İstemcinin AYRICA gönderdiği bir `original_amount` **YOK SAYILIR** —
bu, güvenlik açısından da önemlidir (istemci tarafında manipüle
edilmiş bir tutar asla kabul edilmez). Yalnızca biri veya hiçbiri
doluysa, istemcinin gönderdiği `original_amount` kullanılır (çarpılacak
bir şey yoktur). Yuvarlama, tüm codebase'in mevcut parasal yakınsaması
ile AYNI (`pgtype.Numeric` ↔ `float64`, 2 ondalık, `NumericToFloat64`/
`Float64ToNumeric`) — YENİ bir ondalık kütüphane İCAT EDİLMEDİ.

---

## 7. Baseline Semantiği

- **Draft**: kalemler serbestçe eklenir/düzenlenir/silinir.
- **Baseline** (`POST /projects/{id}/budget/baseline`): **TEK YÖNLÜ**
  geçiş (`draft → baselined`). FOR UPDATE kilit + `status='draft'`
  koşullu UPDATE ile korunur (eşzamanlı çift baseline İMKANSIZDIR —
  `project_change_orders`'daki `SendChangeOrder`/`RespondChangeOrder`
  İLE AYNI ilke, yeni bir eşzamanlılık ilkesi İCAT EDİLMEDİ).
- **Baseline SONRASI**: kalemlerin `original_amount`/`quantity`/
  `unit_cost`/`cost_code_id`/`wbs_node_id` alanları **KALICI OLARAK
  SABİTTİR** — `UpdateBudgetLine`/`CreateBudgetLine`/`DeleteBudgetLine`
  hepsi `ErrBudgetBaselined` döner.
- **Baseline sonrası kapsam genişlemesi kararı** (spec'in AÇIKÇA
  değerlendirilmesini istediği nokta): Bir Adjustment, YALNIZCA
  MEVCUT bir `budget_line_id`'yi hedefleyebilir (şema:
  `project_budget_adjustments.budget_line_id NOT NULL`) — yani
  baseline sonrası **YENİ bir bütçe kalemi asla eklenemez/silinemez**.
  Baseline sonrası ortaya çıkan, hiçbir kalemin karşılamadığı yeni bir
  maliyet kodu harcaması, otomatik olarak "bütçe dışı" (unbudgeted)
  satır olarak Maliyet Kontrolü tablosunda görünür (bkz. §4.6, §10) —
  ayrı bir "bütçe revizyonu ile yeni kalem ekleme" UCU İCAT EDİLMEDİ,
  çünkü bu, "original değerler baseline sonrası sonsuza dek sabittir"
  ilkesiyle ÇELİŞİRDİ (yeni bir kalem, tanım gereği yeni bir "orijinal"
  taşır). Gelecekte resmi bir "bütçe revizyon versiyonu" özelliği
  gerekirse, bu AYRI bir sprint kararı olmalıdır.

---

## 8. Bütçe Revizyonu (Adjustment) Semantiği

```
REVISED_BUDGET = ORIGINAL_AMOUNT + Σ(APPROVED adjustments)
```

- Adjustment, **YALNIZCA bütçe `baselined` durumdayken** oluşturulabilir
  (`ErrBudgetNotYetBaselined`) — draft'ta değişiklik zaten doğrudan
  kalem düzenlemesiyle yapılır, bu yüzden draft'ta bir Adjustment
  anlamsızdır.
- Yeni bir Adjustment `draft` durumunda oluşturulur ve **revize bütçeyi
  HENÜZ ETKİLEMEZ**.
- Yalnızca `Approve` edilen (FOR UPDATE + `status='draft'` koşullu,
  eşzamanlı çift onay İMKANSIZ) bir Adjustment revize bütçeyi etkiler.
- `Reject` edilen bir Adjustment kalıcı olarak `rejected` kalır, hiçbir
  etkisi olmaz.
- **`ORIGINAL_AMOUNT` hiçbir zaman değişmez** — Adjustment ayrı bir
  satırdır, orijinal kaydın ÜZERİNE yazmaz.
- Change Order (Ek İş) ile Budget Adjustment **otomatik bağlanmaz**
  (spec: "don't assume") — mevcut ek iş onay akışı hiçbir maliyet/bütçe
  tablosuna yazmaz (denetimle doğrulandı); Sprint 3'te (Kontratlar + Ek
  İşler) bu bağlantı resmi olarak ele alınabilir, bu sprintte yalnızca
  bir genişletme noktası (extension point) olarak bırakılmıştır.

---

## 9. Maliyet Kontrolü Metrikleri ve Formüller

Her bütçe kalemi (ve her "bütçe dışı" satır) için:

| Metrik | Formül |
|---|---|
| **Original** | Bütçe kaleminin `original_amount`'ı (bütçe dışı satırlarda her zaman 0) |
| **Approved Adjustments** | `Σ(status='approved' olan adjustment.amount)` |
| **Revised** | `Original + Approved Adjustments` |
| **Committed** | `Σ(project_commitments WHERE status='active')` + taşeron sözleşmesi (bkz. §5) |
| **Actual** | `Σ(project_expenses WHERE voided_at IS NULL)` — **tek gerçek kaynak** |
| **ETC** (Estimate To Complete) | Varsa `project_cost_forecasts.etc_amount` (manuel override); YOKSA varsayılan `GREATEST(Revised − Actual, 0)` |
| **EAC** (Estimate At Completion) | `Actual + ETC` — **Committed'i İÇERMEZ** (spec: "committed ile ETC'yi ÇİFT SAYMA") |
| **Variance** | `Revised − EAC` (**pozitif = bütçe altında**, negatif = bütçe aşımı — bu kural API/UI/testte HER YERDE aynıdır) |

**Proje toplamı, satır toplamlarının TOPLAMIDIR** (spec §13'ün
kesin şartı) — bağımsız bir formülle YENİDEN türetilmez. Bu, teknik
olarak ZORUNLUDUR çünkü per-satır ETC formülü (`GREATEST(...,0)`)
**doğrusal değildir (non-additive)** — proje seviyesinde ayrı bir
`GREATEST(SUM(Revised)-SUM(Actual),0)` hesaplansaydı, satır bazlı
toplamla farklı bir sonuç verebilirdi. Bu yüzden
`GetProjectCostControlSummary` SQL'i, `ListCostControlLines` İLE AYNI
CTE zincirini kullanıp SONUNDA `SUM()` alır (iki sorgu birbirinden
BAĞIMSIZ yazılmıştır çünkü sqlc sorgular arası CTE paylaşımını
desteklemez — biri değişirse DİĞERİ DE güncellenmelidir).

### 9.1 Kârlılık

```
ContractValue = projects.contract_amount + Σ(onaylı ek iş eklemeleri) − Σ(onaylı ek iş eksiltmeleri)
              (GetProjectFinancialSummary'deki current_contract_value İLE AYNI CANLI formül, kopya DEĞİL)

ForecastProfit  = ContractValue − EAC_total
ForecastMargin% = ContractValue > 0 ? round(ForecastProfit × 100 / ContractValue, 2) : 0
```

Sıfır/negatif `ContractValue`'da marj **güvenle 0 döner** —
`GetProjectFinancialSummary`'deki (Faz 8) AYNI `GREATEST/LEAST` clamp +
sıfıra bölme koruması deseni kullanılır, yeni bir güvenlik ilkesi İCAT
EDİLMEDİ.

### 9.2 "Bütçe Dışı" (Unbudgeted) Satırlar

Bir maliyet koduna DOĞRUDAN (bir `budget_line_id` OLMADAN) bağlanmış
taahhüt/gider varsa, bu kod için AYRI bir satır üretilir:
`Original=0`, `Revised=0`, `Committed`/`Actual` gerçek toplamları,
`Variance` HER ZAMAN negatiftir (`0 − Actual`). Bu, planlanmamış/kapsam
dışı harcamayı GÖRÜNÜR kılar, gizlemez.

---

## 10. Golden Money Test — Tam Sayısal Doğrulama

Spec'in tam sayısal örneği, hem `internal/service/cost_control_test.go`
(Go entegrasyon testi) hem GERÇEK tarayıcı üzerinden (bkz. final rapor)
doğrulanmıştır:

| Alan | Değer |
|---|---|
| Sözleşme Bedeli | 1.000.000 TRY |
| Orijinal Bütçe | 700.000 |
| Onaylı Revizyon | +50.000 |
| Revize Bütçe | 750.000 |
| Taahhüt | 400.000 |
| Gerçekleşen | 300.000 |
| ETC (manuel) | 350.000 |
| EAC | 650.000 (= 300.000 + 350.000) |
| Varyans | 100.000 (= 750.000 − 650.000) |
| Tahmini Kâr | 350.000 (= 1.000.000 − 650.000) |
| Tahmini Marj | %35.00 |

Sıfır float sürüklenmesi (floating-point drift) kabul edilmez — tüm
parasal hesaplar SQL `numeric(18,2)` ile yapılır, Go tarafında float64
çarpım/bölüm YOKTUR (yalnızca depolama/aktarım için round-trip).

---

## 11. Yetkilendirme (RBAC/Project Membership Sprint'i ÜZERİNE)

Sprint 1'in yetkilendirme sistemi **ZORUNLUDUR ve DEĞİŞTİRİLMEMİŞTİR**
— yalnızca 6 yeni izin kodu eklenmiştir (migration 0035):

| Kod | Kategori | Kapsam |
|---|---|---|
| `projects.budget.read` / `.manage` | Finans | WBS + Bütçe + Kalem + Revizyon (**planlama katmanı**) |
| `projects.cost_control.read` / `.manage` | Finans | Taahhüt + Tahmin + Özet (**izleme/takip katmanı**, planlama ÜZERİNE kurulu) |
| `organization.cost_codes.read` / `.manage` | Firma Yönetimi | Organizasyon-seviyeli maliyet kodu kataloğu |

`budget.*` ile `cost_control.*` AYRI izin kodlarıdır (WBS/UI rota
ayrımı da bunu izler) — bugün her rol bu ikisini BİRLİKTE aldığı için
pratik bir erişim farkı yoktur, ama gelecekte (Roller & Yetkiler
ekranından) bağımsız özelleştirilebilir olması için baştan ayrı
kurulmuştur.

### 11.1 Rol Matrisi (gerekçeli)

| Rol | budget.read | budget.manage | cost_control.read | cost_control.manage | cost_codes.read | cost_codes.manage |
|---|:-:|:-:|:-:|:-:|:-:|:-:|
| Owner/Admin | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| **Finance** | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| **Legacy User** | ✓ | ✓ | ✓ | ✓ | ✓ | — |
| **Project Manager** | ✓ | **—** | ✓ | **—** | ✓ | — |
| **Field** | — | — | — | — | — | — |

- **Finance**: mevcut `projects.finance.read/manage` full grant'ıyla
  BİREBİR simetrik — finans, maliyet kontrolünün doğal sahibidir.
- **Legacy User**: mevcut finans full-grant'ıyla simetrik (budget/
  cost_control full read+manage), ama maliyet kodu KATALOĞUNU
  yönetemez (`cost_codes.manage` YOK) — mevcut `products.read`-benzeri
  "salt okunur katalog erişimi" emsaline uyar (Legacy User zaten
  `products.manage`'e de sahip değil).
- **Project Manager — İŞ KARARI (spec §11'in açıkça değerlendirilmesini
  istediği nokta)**: PM bugün HİÇBİR finans iznine sahip değil (Sprint
  1'de `projects.finance.*` grantı YOK). Bu tutarlılığı korumak için PM,
  maliyet kontrolünde de **salt okunur** bırakıldı — bütçe
  oluşturma/onaylama/revizyon YETKİSİ Finans/Owner/Admin'de kalır. Bu,
  "PM sahada maliyeti GÖRMELİ ama parasal kararı VERMEMELİ" ilkesine
  dayanır; ileride PM'e `budget.manage` verilmesi saf bir konfigürasyon
  değişikliğidir (kod değişikliği gerektirmez), organizasyonun kendi iş
  kararına bırakılmıştır.
- **Field**: mevcut "sahada finansal görünürlük YOK" ilkesiyle simetrik
  — hiçbir maliyet kontrolü izni verilmez.

Proje üyeliği kuralları (Sprint 1'in `project_users`) DEĞİŞMEDEN
uygulanır: Owner/Admin/Legacy User üyelikten muaftır
(`RoleBypassesProjectMembership`), diğerleri yalnızca atandığı
projelerin maliyet kontrolüne erişebilir.

### 11.2 Kiracı/Proje İzolasyonu (IDOR Koruması)

Her repository sorgusu `organization_id` + `project_id` ile
filtrelenir. Somut saldırı senaryosu (spec §16) test edilmiştir:
*"Proje A'ya yetkili bir kullanıcı, Proje B'nin bütçe kalemi UUID'sini
bilerek Proje A'nın URL'si üzerinden ona bir revizyon/taahhüt/masraf
bağlamaya çalışırsa REDDEDİLİR"* — hem servis katmanında
(`resolveBudgetLineRef`, `resolveWBSParentRef`, `resolveCostCodeRef`)
hem GERÇEK HTTP isteğiyle (`internal/httpapi/middleware/cost_control_
security_test.go`) doğrulanmıştır. Bu, Sprint 1'de bulunan gerçek
cross-project IDOR açığıyla AYNI sınıf risktir — aynı savunma deseni
(URL'deki proje kimliğini sorgunun ÜÇÜNCÜ sınırı olarak kullanmak)
tekrarlanmıştır.

---

## 12. API Rota Özeti

Mevcut router.go konvansiyonuna (kaynak-bazlı, `perm`/`projPerm`
middleware) SADIK kalınmıştır — yeni bir konvansiyon İCAT EDİLMEMİŞTİR.

```
GET/POST   /organization/cost-codes
PUT/DELETE /organization/cost-codes/{id}          (DELETE → arşiv)
POST       /organization/cost-codes/{id}/reactivate

GET/POST   /projects/{id}/wbs
PUT/DELETE /projects/{id}/wbs/{nodeId}            (DELETE → arşiv)

GET/POST   /projects/{id}/budget
POST       /projects/{id}/budget/baseline
GET/POST   /projects/{id}/budget/lines
PUT/DELETE /projects/{id}/budget/lines/{lineId}
GET/POST   /projects/{id}/budget/adjustments
POST       /projects/{id}/budget/adjustments/{adjustmentId}/approve
POST       /projects/{id}/budget/adjustments/{adjustmentId}/reject

GET/POST   /projects/{id}/commitments
POST       /projects/{id}/commitments/{commitmentId}/void

GET        /projects/{id}/forecasts
PUT        /projects/{id}/budget/lines/{lineId}/forecast

GET        /projects/{id}/cost-control     (özet + kırılım TEK istekte, N+1 yok)
```

Mevcut `POST/PUT /projects/{id}/expenses[/{id}]` ve
`POST/PUT /projects/{id}/subcontractors[/{id}]` uçları, opsiyonel
`cost_code_id`/`budget_line_id` alanlarını kabul edecek şekilde
genişletildi (yeni bir uç DEĞİL).

---

## 13. Performans

`ListCostControlLines`/`GetProjectCostControlSummary`, bütçe kalemi
başına N+1 sorgu YAPMAZ — tek bir CTE zinciriyle (adjustments/
committed/actual/forecast alt sorguları `GROUP BY budget_line_id` ile
önceden agregatlanır, sonra `LEFT JOIN` edilir) tüm proje TEK sorguda
hesaplanır. İndeksler: `organization_id`, `project_id`, `budget_id`,
`cost_code_id`, `budget_line_id`, `status` — gerçek sorgu WHERE/JOIN
kalıplarına göre migration 0035'te tanımlıdır.

---

## 14. Para Birimi

Bu sprintte **çoklu para birimi/FX motoru YOKTUR**. Bir bütçe, TEK bir
para birimine (projenin `currency` alanı) sahiptir — bütçe oluşturma
anında projeden otomatik alınır, kullanıcı tarafından SEÇİLMEZ. Aynı
bütçe içinde farklı para birimleri KARIŞTIRILAMAZ. FX dönüşümü İCAT
EDİLMEDİ; bu gerçek bir boşluktur ve gelecekteki bir sprintte ele
alınmalıdır (çok uluslu/döviz bazlı tedarik yapan projeler için).

---

## 15. Denetim (Audit)

Mevcut altyapı kullanılır, yeni bir paralel denetim sistemi
OLUŞTURULMADI:

- Proje-özel olaylar (WBS/bütçe/kalem/revizyon/taahhüt/tahmin) →
  mevcut `project_events` tablosu, `logProjectEvent` helper'ı ile.
- Kuruluş-özel olaylar (maliyet kodu CRUD) → yeni `organization_events`
  tablosu (bkz. §4.9), `logOrgEvent` helper'ı ile — `logProjectEvent`
  İLE AYNI desen, yalnızca proje-bağımsız.

**Bilinen boşluk (bu sprintin kapsamı DIŞINDA, düzeltilmedi)**: Sprint
1'in `AuthorizationService`'i (rol/izin/proje-üyeliği değişiklikleri)
BUGÜN hiçbir denetim olayı ÜRETMİYOR — bu, Sprint 1'in kendi spec'inin
gerektirdiği ama uygulanmamış bir eksikliktir, Sprint 2 sırasında
keşfedilmiş ama bu sprintin kapsamı dışında bırakılmıştır.

---

## 16. Eşzamanlılık (Concurrency)

Yeni bir eşzamanlılık ilkesi İCAT EDİLMEDİ — codebase'in mevcut
"durum-korumalı `FOR UPDATE`" deseni (`project_change_orders`'daki
`SendChangeOrder`/`RespondChangeOrder`) tekrarlanmıştır:

- **Baseline**: `FOR UPDATE` kilit + `UPDATE ... WHERE status='draft'`
  → eşzamanlı iki baseline isteğinden yalnızca biri 0'dan fazla satır
  etkiler, diğeri `ErrBudgetNotBaselinable` alır.
- **Adjustment onay/red**: aynı desen, `status='draft'` koşuluyla.
- **Manuel taahhüt**: `idempotency_key` ile çift-gönderim koruması
  (mevcut expense/collection deseniyle AYNI).
- Para toplamları her zaman TEK bir transaction içinde (yazma + denetim
  olayı BİRLİKTE commit/rollback) işlenir.

---

## 17. Mobil Kapsamı

Mobil bu sprintte **YALNIZCA OKUMA** amaçlıdır (spec: "web-first"):
proje detayında yeni bir "Maliyet Kontrolü" sekmesi, özet KPI'ları
(Sözleşme/Revize Bütçe/Taahhüt/Gerçekleşen/EAC/Varyans/Tahmini Kâr/
Marj) ve salt-okunur bütçe kalemi listesini gösterir —
`projects.cost_control.read` izniyle korunur. **Bütçe düzenleme, manuel
taahhüt oluşturma/düzenleme, maliyet kodu yönetimi mobilde YOKTUR** —
hepsi web'e yönlendirilir.

---

## 18. Yeni Bir İzin/Alan Eklerken

Bu modüle yeni bir izin kodu eklerken hem migration'daki `permissions`
seed'inde hem `backend/internal/domain/authorization.go`'daki `Perm*`
sabitinde KARŞILIĞI olmalıdır (Sprint 1'in kendi kuralıyla AYNI, bkz.
`authorization.go` başlık yorumu). Yeni bir olay türü eklerken
`domain/cost_control.go`'daki `ProjectEvent*`/`OrgEvent*` sabitlerine
eklenmelidir.
