# Sözleşme (Contract) Modülü — Teknik Dokümantasyon

> ARVEND V2 — Sprint 3: Proje Sözleşmesi (Contract) + Mobil Ek İş
> Görünürlüğü. Bu doküman, gerçek bir Sözleşme varlığının durum
> makinesini, veri modelini, yetkilendirme mantığını ve API'sini uçtan
> uca anlatır. Kod tabanındaki gerçek dosya/satırlara referans verir;
> herhangi bir değişiklikte bu doküman da güncellenmelidir.

---

## 1. Genel Bakış ve Amaç

Sprint 3 öncesi denetimi (5 paralel araştırma ajanı + sentez) şu gerçeği
netleştirdi: kod tabanında **hiçbir yapısal "Kontrat" (Contract) varlığı
yoktu** — yalnızca `projects.contract_amount` (offer'dan tek seferlik
dondurulmuş bir sayı) ve hiçbir şeye biçimsel olarak bağlı olmayan,
etiketlenebilir bir dosya-yükleme kategorisi (`category='contract'`)
vardı. Buna karşılık **Ek İş (Change Order) modülü Faz 8'de zaten tam
olarak inşa edilmişti** (şema, servis, ~40 gerçek-DB testi, public
onay/red akışı, web UI).

Bu modülün amacı, bir projenin **gelir (revenue) tarafına** — Sprint
2'nin Bütçe/Maliyet Kontrolü'nün **maliyet (cost) tarafına** karşılık
gelen — resmi bir yapı kazandırmaktır: kendi durum makinesi, şartlar/
kapsam/ödeme-koşulları alanları, kaynak teklif revizyonuna ve onu
değiştiren Ek İşlere biçimsel bağlantı.

**Bu sprintte YAPILMAYANLAR** (bilinçli kapsam dışı — kullanıcının kendi
sınırı, bkz. §8): PDF üretimi, e-imza/müşteri-onay akışı, Ek İş →
Bütçe Revizyonu otomatik bağlantısı, `project_change_orders`'a
`contract_id` FK, proje başına çoklu/versiyonlu kontrat, mevcut
projelere backfill, mobilde Sözleşme ekranı, kontrat metin alanları
için resmi bir "amendment" mekanizması, production deploy/migration.

---

## 2. Kritik Kavram Ayrımları

| Kavram A | Kavram B | Fark |
|---|---|---|
| **Contract** (Sözleşme) | **Change Order** (Ek İş) | Contract, projenin TEK ticari çerçevesidir (kapsam/ödeme koşulları + durum). Change Order, bu çerçeveyi değiştiren bireysel bir işlemdir (`project_change_orders`, Faz 8). Bir proje bir Contract'a, birden çok Change Order'a sahip olabilir. |
| **Contract** | **Budget** (Sprint 2) | Contract **gelir** tarafıdır (müşteriyle ilişki, ticari şartlar). Budget **maliyet** tarafıdır (iç maliyet planı). İkisi arasındaki fark kârdır — bkz. `docs/cost-control.md` §2. |
| **Contract'ın ticari temeli (baseline)** | **`projects.contract_amount`/`currency`/`source_offer_id`/müşteri anlık görüntüsü** | Bu ikinci grup, ZATEN proje seviyesinde immutable'dır (bkz. §3.1) — Contract bunları TEKRARLAMAZ, canlı olarak `project_id` JOIN'i ile okur. Contract yalnızca bugüne kadar hiçbir yerde korunmayan alanları (kapsam, ödeme/hakediş/avans koşulları, tarihler) kilitler. |
| **Contract Activation** | **Budget Baseline** (Sprint 2) | Kavramsal olarak benzerdir (her ikisi de "artık bu şartlar sabit" anlamına gelir) ama AYRI durum makineleridir — Budget `draft→baselined` (tek yönlü, iki durumlu); Contract `draft→active→completed` + iki ayrı terminal dal (§4). Birbirine bağlı DEĞİLDİR. |

---

## 3. Durum Makinesi

```
DRAFT
  ├── Activate  -> ACTIVE
  │                 ├── Complete  -> COMPLETED   (terminal)
  │                 └── Terminate -> TERMINATED  (terminal, gerekçe + zaman damgası zorunlu)
  └── Cancel    -> CANCELLED      (terminal, gerekçe zorunlu)
```

- **DRAFT**: tüm sözleşme alanları serbestçe düzenlenebilir; henüz
  ticari bir taban DEĞİLDİR. `Activate` veya (vazgeçilirse, gerekçeli)
  `Cancel` ile çıkılır.
- **ACTIVE**: Activation, ticari tabanı (baseline) **KALICI OLARAK
  KİLİTLER**. Kilitlenen alanlar: `scope`, `payment_terms`,
  `retention_terms`, `advance_terms`, `effective_date`,
  `planned_completion_date` (bkz. §3.1 — bunların DIŞINDAKİ ticari
  alanlar zaten proje seviyesinde immutable'dır). Aktivasyon sonrası
  ticari değişiklikler yalnızca resmi bir Ek İş ile yapılabilir.
  `internal_notes` gibi ticari OLMAYAN dahili alanlar active'te de
  düzenlenebilir kalır. Normal tamamlanma `Complete`'e, erken/olağandışı
  sonlanma (gerekçeli) `Terminate`'e gider.
- **CANCELLED / TERMINATED / COMPLETED**: hepsi terminal —
  **Sprint 3'te hiçbir yeniden açma/reaktivasyon YOKTUR**.
- **`draft` ASLA `terminate` edilemez** — hiç yürürlüğe girmemiş bir
  sözleşme feshedilemez, yalnızca iptal (`cancel`) edilebilir. Bu kural
  hem servis katmanında (`CancelProjectContract`/`TerminateProjectContract`
  yalnızca ilgili başlangıç durumundan çıkışı kabul eder) hem güvenlik
  testinde (`14_terminate_rejected_from_draft` — "kritik" olarak
  işaretli) doğrulanmıştır.
- Tüm geçişler backend-enforced, izin-kontrollü (§5), transaction-safe
  (§7) ve denetimlidir (§9). **Frontend buton görünürlüğüne
  GÜVENİLMEZ** — web UI'da her buton yalnızca bir UX kısayoludur, gerçek
  sınır her zaman backend'dedir.

### 3.1 Hangi Alanlar Neden Kilitlenir — Kod Kanıtı

`backend/internal/repository/sqlc/projects.sql.go`'daki `UpdateProject`
sorgusunun kendi yorumu, `project_no`/`source_offer_id`/
`source_revision_id`/`contract_amount`/`currency`/müşteri anlık
görüntüsünün **kasıtlı olarak** güncelleme kapsamı dışında bırakıldığını
söyler — bunlar kaynak teklife ait dondurulmuş verilerdir ve
`UpdateProjectInput`'ta hiç yer almaz. Yani bu alanlar **zaten** proje
seviyesinde immutable'dır; `project_contracts` bunları tekrar ETMEZ,
`project_id` üzerinden canlı okunur.

Buna karşılık `projects.start_date`/`end_date` **gerçekten mutable**dır
(`UpdateProjectInput.StartDate`/`EndDate`, aynı dosyada doğrulandı) —
yani kullanıcının sözleşme-kapsamında saydığı "effective/planned
completion date" için proje seviyesinde HİÇBİR koruma yoktu. Bu yüzden
`project_contracts`, kendi bağımsız `effective_date`/
`planned_completion_date` alanlarını taşır (projenin serbestçe
düzenlenebilen operasyonel `start_date`/`end_date`'i İLE
KARIŞTIRILMAMALI).

Sonuç: `project_contracts`'ta GERÇEKTEN yeni ve kilitlenmesi gereken
alanlar — `scope`, `payment_terms`, `retention_terms`, `advance_terms`,
`effective_date`, `planned_completion_date` — bunların hiçbirinin
Sprint 3 öncesi hiçbir yerde bir karşılığı/koruması yoktu; Contract
bunların TEK ve İLK sahibidir.

---

## 4. Veri Modeli

Migration: `backend/db/migrations/0036_create_project_contracts.up.sql`

### `project_contracts` — proje başına TEK sözleşme

| Kolon | Tip | Açıklama |
|---|---|---|
| `id`, `organization_id`, `project_id` | | `UNIQUE(project_id)` — bir projede yalnızca BİR sözleşme olabilir |
| `currency` | `varchar(3)` | Proje oluşturulurken snapshot (Bütçe'nin `currency`'siyle AYNI emsal — zaten immutable bir alanın kopyası, sorgu kolaylığı için) |
| `status` | `draft` \| `active` \| `completed` \| `cancelled` \| `terminated` | CHECK constraint ile sınırlı |
| `scope`, `payment_terms`, `retention_terms`, `advance_terms` | `text` | Yalnızca `draft`'ta düzenlenebilir (bkz. §3.1) |
| `effective_date`, `planned_completion_date` | `date`, nullable | Aynı şekilde yalnızca `draft`'ta düzenlenebilir |
| `internal_notes` | `text` | Ticari DEĞİL — `draft` VE `active`'te düzenlenebilir, terminal durumlarda kilitlenir |
| `created_by`, `created_at`, `updated_at` | | |
| `activated_at`/`by`, `completed_at`/`by` | | |
| `cancelled_at`/`by`, `cancel_reason` | | Yalnızca `cancel` ile dolar |
| `terminated_at`/`by`, `termination_reason` | | Yalnızca `terminate` ile dolar |

Tutarlılık trigger'ı **gerekmiyor** — tek zorunlu FK (`project_id`) var,
`project_budget_lines` gibi opsiyonel çapraz-proje referansı yok.

**`project_change_orders`'a `contract_id` FK EKLENMEDİ**: proje↔kontrat
kardinalitesi 1:1 olduğu için `project_id` zaten yeterlidir — bir
projenin (en fazla bir) sözleşmesini değiştiren Ek İşler listesi, mevcut
`GET /projects/{id}/change-orders` ile aynen çekilir (yeni bir
sorgu/ilişki İCAT EDİLMEDİ).

### 4.1 Otomatik Oluşturma YOK — Sprint 4 Düzeltmesi

Sprint 3'te, Bütçe'nin otomatik-oluşturma emsali Contract'a da
uygulanmıştı: yeni bir proje, offer dönüşümünde sessizce boş bir taslak
Contract alıyordu. **Sprint 4'te bu davranış kaldırıldı**: Contract
gerçek bir ticari nesnedir (kullanıcının bir eylemle — "Sözleşme
Oluştur" — var ettiği bir kayıt), salt proje var diye "hayalet" bir boş
taslak sözleşme YARATILMAZ. Bütçe'nin (Sprint 2, maliyet tarafı)
otomatik-oluşturma davranışı bundan ETKİLENMEDİ — bu ayrım BİLİNÇLİDİR:
Bütçe her projenin ZORUNLU bir maliyet planlama iskeletidir, Contract
ise yalnızca kullanıcı bir ticari çerçeveyi resmileştirmek istediğinde
var olan opsiyonel bir belgedir.

Güncel davranış, TÜM projeler için tekdüzedir:

- `ProjectService.CreateFromOffer`, kabul edilen teklifin ticari anlık
  görüntüsünü (`contract_amount`/`currency`/`source_offer_id`/
  `source_revision_id`/müşteri anlık görüntüsü) her zaman olduğu gibi
  `projects` tablosuna yazar — bu **DEĞİŞMEDİ**, yalnızca
  `project_contracts` satırının otomatik oluşturulması kaldırıldı.
- `project_contracts` satırı hiçbir projede (yeni veya eski) otomatik
  oluşmaz.
- Sözleşmesi olmayan bir projede web Finans ekranı her zaman "Sözleşme
  Oluştur" CTA'sını gösterir; kullanıcı `POST /projects/{id}/contract`
  ile (`contracts.manage` izni gerektirir) açıkça bir taslak oluşturur.

Regresyon testi (`backend/internal/service/project_contract_test.go`,
`1_offer_conversion_does_not_auto_create_contract` +
`2_manual_create_after_offer_conversion`): offer → project dönüşümü
sonrası projenin var olduğu, ticari anlık görüntünün korunduğu, ama
`project_contracts`'ta hiçbir satır OLUŞMADIĞI ve `POST .../contract`
ucunun taslağı başarıyla oluşturduğu doğrulanır.

---

## 5. Yetkilendirme — 3 Katmanlı İzin Modeli

Sprint 1'in yetkilendirme sistemi **ZORUNLUDUR ve DEĞİŞTİRİLMEMİŞTİR** —
yalnızca 3 yeni izin kodu eklenmiştir (migration 0036, kategori
"Finans"):

| Kod | Kapsam |
|---|---|
| `projects.contracts.read` | Sözleşmeyi, şartlarını, durum geçmişini, kaynak teklif/revizyon referanslarını, güncel sözleşme değerini (Ek İş etkileriyle) görüntüleme |
| `projects.contracts.manage` | Taslak oluşturma, `draft` alanlarını düzenleme, aktivasyon SONRASI yalnızca güvenli/kilitlenmemiş metadata'yı (`internal_notes`) düzenleme. **Lifecycle geçişlerine İZİN VERMEZ** |
| `projects.contracts.lifecycle` | Activate/Cancel/Complete/Terminate — her zaman backend-enforced ve denetimli |

Bu, Sprint 2'nin basit `read`/`manage` çiftlerinden **kasıtlı olarak
farklı** bir modeldir: `manage`, lifecycle geçişlerini İÇERMEZ — bu,
"kim taslağı düzenleyebilir" ile "kim ticari taahhüdü resmileştirebilir/
sonlandırabilir" sorularının AYRI yetkiler olması gerektiği kararına
dayanır.

### 5.1 Rol Matrisi (gerekçeli)

| Rol | read | manage | lifecycle |
|---|:-:|:-:|:-:|
| Owner / Admin | ✓ | ✓ | ✓ |
| **Finance** | ✓ | ✓ | ✓ |
| **Project Manager** | ✓ | **✓** | **—** |
| **Legacy User** | ✓ | ✓ | **—** |
| Field | — | — | — |

- **Finance / Owner / Admin**: tam yetki — sözleşme, doğal olarak
  finansın/yönetimin sorumluluğundadır.
- **Project Manager — Sprint 2'den KASITLI SAPMA**: Sprint 2'de PM,
  Bütçe/Maliyet Kontrolü'nde **salt okunurdu** (`docs/cost-control.md`
  §11.1). Sprint 3'te PM, sözleşme taslağını **düzenleyebilir**
  (`manage`) ama **lifecycle geçişi yapamaz** — saha/proje yönetimi
  ticari şartları hazırlayabilir, ama resmileştirme (aktivasyon) ve
  sonlandırma (tamamlama/fesih/iptal) yetkisi Finans/Owner/Admin'de
  kalır. Bu, "PM ticari metni hazırlayabilmeli ama taahhüdü TEK BAŞINA
  bağlayıcı/sonlandırıcı hale getirememeli" ilkesine dayanır ve bilinçli
  bir tasarım kararıdır, tutarsızlık DEĞİLDİR — güvenlik testinde
  (`project_manager_manage_allowed`/`lifecycle_denied`) "kritik" olarak
  işaretlenmiştir.
- **Legacy User**: migration 0034'ün mevcut grant listesi denetlendi —
  `legacy_user` bugün `projects.finance.read` VE `.manage`'in İKİSİNE de
  sahip (Ek İşler bugün tam olarak bu iki kod altında yaşıyor). Bu
  geriye-uyumluluk gerekçesiyle `contracts.read`+`contracts.manage`
  verilir (finance full-grant'ıyla simetrik) — ama `contracts.lifecycle`
  **KESİNLİKLE otomatik verilmez**: bu yeni bir eylem sınıfıdır, eskiden
  bu yetkinin bir "lifecycle" karşılığı yoktu, bu yüzden miras alınmaz.
- **Field**: mevcut "sahada finansal/ticari görünürlük YOK" ilkesiyle
  simetrik — hiçbir sözleşme izni verilmez.

Proje üyeliği kuralları (Sprint 1'in `project_users`) DEĞİŞMEDEN
uygulanır: bir Finans veya Proje Yöneticisi kullanıcı, yalnızca erişimi
olan bir projenin sözleşmesine erişebilir (Owner/Admin/Legacy User
üyelikten muaf kalmaya devam eder, `RoleBypassesProjectMembership`).

### 5.2 Süper Admin

`RequirePermission`/`RequireProjectPermission`
(`backend/internal/httpapi/middleware/require_permission.go`) içindeki
koşulsuz `role==super_admin` bypass'ı **Sprint 3'e özgü YENİ bir risk
DEĞİLDİR** — Sprint 1'den beri var olan, TÜM izin-korumalı rotalar
(Bütçe/Maliyet Kontrolü/Finans/her şey) için tekdüze bir sistem
davranışıdır. Süper Admin platform-scoped'dur ve `/projects/*`
rotalarına pratikte hiç gitmez (organizasyon bağlamı yok) — Contract'a
özel bir koruma eklenmesi gerekmemiştir, yalnızca şeffaflık için burada
belgelenmiştir.

### 5.3 Kiracı/Proje İzolasyonu (IDOR Koruması)

Her repository sorgusu `organization_id` + `project_id` ile filtrelenir.
Cross-project ve cross-tenant erişim (bir projeye yetkili kullanıcı,
başka bir projenin/organizasyonun sözleşmesine URL üzerinden ulaşmaya
çalışırsa) hem servis katmanında hem gerçek HTTP isteğiyle
(`project_contract_security_test.go`) reddedildiği doğrulanmıştır —
Sprint 1/2'deki AYNI savunma deseni tekrarlanmıştır, yeni bir ilke İCAT
EDİLMEMİŞTİR.

---

## 6. API Rota Özeti

```
GET        /projects/{id}/contract                (contracts.read)
POST       /projects/{id}/contract                (contracts.manage — yalnızca yoksa oluşturur)
PUT        /projects/{id}/contract                (contracts.manage — yalnızca draft alanları, yalnızca status=draft'ta)
PUT        /projects/{id}/contract/notes          (contracts.manage — draft+active'te)
POST       /projects/{id}/contract/activate       (contracts.lifecycle)
POST       /projects/{id}/contract/cancel         (contracts.lifecycle — yalnızca draft'tan, reason zorunlu)
POST       /projects/{id}/contract/complete       (contracts.lifecycle — yalnızca active'ten)
POST       /projects/{id}/contract/terminate      (contracts.lifecycle — yalnızca active'ten, reason zorunlu)
```

Üç ayrı `projPerm` route grubu kullanılır (`router.go`) — mevcut
kaynak-bazlı middleware konvansiyonuna sadık kalınmıştır, yeni bir
konvansiyon İCAT EDİLMEMİŞTİR.

---

## 7. Eşzamanlılık (Concurrency)

Yeni bir eşzamanlılık ilkesi İCAT EDİLMEDİ — Sprint 2'nin
"durum-korumalı `FOR UPDATE`" deseni (`BaselineProjectBudget`/
`SendChangeOrder` ile AYNI) tekrarlanmıştır: her lifecycle geçişi
(`Activate`/`Cancel`/`Complete`/`Terminate`) `loadProjectContract`
(kilitsiz ön-kontrol) → `GetProjectContractForUpdate` (`FOR UPDATE`
satır kilidi) → Go-seviyeli durum kontrolü → `status`-korumalı
`UPDATE ... WHERE status='<beklenen>'` (savunma-derinliği ikinci
katmanı) → `logProjectEvent` → commit sırasını izler. Eşzamanlı iki
aktivasyon/iptal/tamamlama/fesih isteğinden yalnızca biri 0'dan fazla
satır etkiler, diğeri ilgili hata sentinelini alır.

---

## 8. Denetim (Audit)

Yeni bir paralel denetim sistemi OLUŞTURULMADI — Contract proje-özel bir
varlık olduğu için mevcut `project_events` tablosu +
`logProjectEvent` helper'ı kullanılır (Sprint 2'nin maliyet kodları için
kullandığı org-seviyeli `organization_events` BURAYA uymaz, Contract
`organization_events`'e ZORLANMADI). Olay türleri:
`ProjectEventContractCreated/Updated/NotesUpdated/Activated/Completed/
Cancelled/Terminated` (`backend/internal/domain/project_contract.go`).

---

## 9. Açıkça Hariç Tutulanlar

- **PDF üretimi YOK, e-imza/müşteri-onay akışı YOK** — Ek İşlerin
  aksine, sözleşme geçişlerinin hepsi dahili/authenticated'dir; hiçbir
  public/token akışı yoktur.
- **Ek İş → Bütçe Revizyonu otomatik bağlantısı YOK** (Sprint 2'nin
  bıraktığı genişletme noktası kullanılmadı, manuel kalır).
- **`project_change_orders`'a `contract_id` FK YOK** (bkz. §4 — 1:1
  kardinalite yüzünden gereksiz).
- **Versiyonlu/proje-başına-çoklu-kontrat sistemi YOK** —
  `UNIQUE(project_id)`.
- **Mevcut projelere backfill YOK** (bkz. §4.1).
- **Mobilde Sözleşme ekranı YOK, mobilde yeni bir izin YOK** — mobil
  yalnızca Ek İşleri salt-okunur gösterir (bkz. §10), Sözleşme'nin
  kendisi yalnızca web'dedir.
- **Kontrat metin alanları (scope/terms/vb.) için resmi bir
  "amendment" mekanizması İNŞA EDİLMEDİ** — yalnızca aktivasyon-sonrası
  düzenleme REDDİ var; bu bilinçli, dokümante edilen bir sınırdır
  (Sprint 2'nin kendi "bilinen boşluk" raporlama tarzıyla aynı).

---

## 10. Mobil Kapsamı

Contract'ın kendisi mobilde **YOKTUR** (yalnızca web) — kullanıcının
açık kararı. Mobil, yalnızca projenin sözleşmesini değiştiren **Ek
İşleri salt-okunur** listeler (spec: "read-only visibility this
sprint"):

- Yeni bir "Ek İşler" sekmesi, proje detay ekranına eklendi
  (`mobile/lib/features/projects/presentation/project_detail_screen.dart`).
- İzin: **mevcut** `projects.finance.read` yeniden kullanılır — Ek
  İşler bugün backend'de bu iznin altında yaşadığı için mobil için ayrı
  bir izin tanımlanmadı.
- Liste: Ek İş no + başlık, durum rozeti
  (`StatusRegistry.changeOrder` — Sprint 1'de tanımlanmış ama Sprint
  3'e kadar hiç kullanılmamış bir registry, sıfır yeni renk/durum kodu
  gerekti) ve işaretli tutar (ekleme=yeşil, eksiltme=kırmızı — web'in
  `formatSignedMoney` mantığıyla aynı).
- **Oluşturma/gönderme/revize/iptal YOK** — hiçbir yazma eylemi
  sunulmaz, genuinely salt-okunur.
- Domain sınıfı (`ChangeOrder`, `mobile/lib/features/projects/domain/
  project.dart`) web'in tam DTO'sundan bilinçli olarak dar bir alt
  kümedir — kalemler/kârlılık/dahili notlar salt-okunur özet için
  gereksizdir (`CostControlLine`'ın Sprint 2'deki AYNI minimalizm
  ilkesi).

**Güncelleme (mobil 1.4.0+5, 2026-09-29):** yukarıdaki kapsam ESKİDİ.
Mobilde artık Sözleşme ekranı VAR (`mobile/lib/features/projects/
contract_co/`, Finans > Sözleşme, `/projeler/:id/sozlesme`): taslak
oluştur/düzenle, dahili not, Aktifleştir / İptal Et (gerekçe zorunlu) /
Tamamla / Feshet (gerekçe zorunlu); 3 katmanlı izin (read/manage/
lifecycle) aynen uygulanır — Proje Yöneticisi taslağı düzenler ama durum
değiştiremez, finans izni yoksa hiçbir tutar görmez. Finans grubu
`projects.contracts.read` ile de görünür (§11'deki web hatasının mobil
karşılığı baştan önlendi). Ek İşler de tam yönetimli: oluştur/düzenle
(kalemler, KDV), Gönder, Mail Gönder, Linki Kopyala, Revize Et, İptal Et
(`projects.finance.manage`, kapalı projede gizli), detayda kârlılık ve
mail/olay geçmişi. Onay/red yine yalnızca müşterinin herkese açık
linkinden.

**Kapalı projede yaşam döngüsü (mobil, 2026-09-29 inceleme):** backend
Tamamla/Feshet/İptal Et'i `requireOpenProject`'e bilinçli olarak bağlamaz
(kapanış eylemi, bkz. `project_contract_service.go`). Mobil artık bunu
izler: tamamlanmış/iptal edilmiş projede şartlar ve not kilitli, yeni
sözleşme ve Aktifleştir yok, ama `projects.contracts.lifecycle` ile
sözleşme kapatılabilir. Web bu düğmeleri `locked` iken hâlâ gizliyor (web
tarafında açık fark). Ek iş paylaşım linkinin METNİ de artık yalnızca
"Linki Kopyala"yı görebilene (`projects.finance.manage`) gösterilir.

---

## 11. Web UI Yerleşimi

Sözleşme, YENİ bir üst-seviye sekme DEĞİL — proje detayının mevcut
"Finans" sekmesi içinde, **"Ek İşler" bölümünün ÜSTÜNDE** ayrı bir
bölüm olarak yer alır (kullanıcının açık kararı — kontrat, kendisini
değiştiren Ek İşlerden ÖNCE okunmalıdır).

**Önemli mimari not**: Sözleşme bölümü, Finans sekmesinin geri kalanını
saran tekil `projects.finance.read` iznine bağlı toplu kapının
**DIŞINDA**, bağımsız olarak render edilir
(`frontend/app/(app)/projeler/[id]/page.tsx`). Aksi halde
`finance.read`'i olmayan ama `contracts.manage`'e sahip bir Proje
Yöneticisi (bkz. §5.1 rol matrisi) sözleşmeyi hiç göremezdi — bu,
canlı tarayıcı doğrulaması sırasında keşfedilip düzeltilen gerçek bir
wiring hatasıdır, Contract'ın kendi 3-katmanlı izin setinin Finans'ın
paylaşılan `finance.read` iznine sessizce tabi kılınmaması gerektiğini
doğrular.

Lifecycle butonlarının (`Aktifleştir`/`Tamamla`/`Feshet`/`İptal Et`)
`contracts.lifecycle` iznine sahip olmayan kullanıcılara (ör. Project
Manager) client-side gizlenmesi için **mevcut, önceden kurulmuş bir
konvansiyon bulunamadı** (web'de `User.permissions` alanı taşınır ama
hiçbir ekranda kullanılmaz) — bu yüzden Sprint 3, backend-enforced-only
fallback'e dayanır: butonlar görünür kalır, yetkisiz bir tıklama
backend'den 403 döner ve mevcut, codebase genelinde zaten kanıtlanmış
`ApiError` → satır-içi hata mesajı deseniyle (bkz.
`useConfirmDialog`/`voidCommitment` emsali) kullanıcıya gösterilir.

---

## 12. Yeni Bir İzin/Alan Eklerken

Bu modüle yeni bir izin kodu eklerken hem migration'daki `permissions`
seed'inde hem `backend/internal/domain/authorization.go`'daki `Perm*`
sabitinde karşılığı olmalıdır (Sprint 1/2'nin kendi kuralıyla AYNI).
Yeni bir olay türü eklerken `domain/project_contract.go`'daki
`ProjectEventContract*` sabitlerine eklenmelidir.
