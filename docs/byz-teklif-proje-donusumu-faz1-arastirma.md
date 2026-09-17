# BYZ: "Teklif → Proje" Akışı — Faz 1 Araştırma Raporu

**Kapsam:** `/Users/tahaeryetisozen/Documents/GitHub/byz-app` (Flask + PyMongo backend, Flutter mobil). Salt okuma; hiçbir dosya değiştirilmedi, uygulama çalıştırılmadı. Yöntem: 6 paralel okuyucu (offers, finance, auth/tenancy, api/mobile, files/storage, tooling) + bağımsız bir "çürütücü" doğrulayıcının, tasarımı yönlendiren tüm iddiaları yeniden kod okuyarak sınaması. **Doğrulayıcı hiçbir iddiayı düzeltmek zorunda kalmadı** — aşağıdaki her VERIFIED madde iki kez (okuyucu + doğrulayıcı) bağımsız olarak koda dayandırıldı.

---

## ÖNCELİKLİ BULGU — İşe başlamadan önce karar gerektirir

**Bu görevin tarif ettiği tam özellik ("Offer → Convert to Project → Manage Project" — proje dönüşümü, ödeme planı/tahsilat, masraf, taşeron + iş kalemleri, kâr/zarar, dosya/foto) `/Users/tahaeryetisozen/Documents/GitHub/x-api/ARVEND` deposunda zaten inşa edilmiş durumda.**

Kanıt (bu oturumda doğrudan okundu):
- `ARVEND/README.md:1-4`: *"Arvend Yapı ERP sisteminin sıfırdan, modül modül yeniden yazımı (Go + PostgreSQL + Next.js). **Önceki sistem: `byz-app` (Flask + MongoDB)**."*
- Git geçmişi (`ARVEND` deposu): `869771d Faz 5: tekliften projeye donusum + proje listesi + proje detay iskeleti`, `6f03317 Faz 6: proje finans modulleri (odeme plani, tahsilat, masraf, fatura, taseron)`, `aafcb26 Faz 7: proje operasyon yonetimi (ekip, planlama, gorev, dosya, foto, not)`, `e410fd3 Faz 8: Ek İşler / Değişiklik Emirleri + gelişmiş proje kârlılığı`.
- `ARVEND/docs/teklif-modulu.md` mevcut (teklif modülünün belgesi).
- ARVEND backend: Go/chi/sqlc/pgx, PostgreSQL `numeric(18,2)`, `organization_id` çok-kiracılı izolasyon; frontend: Next.js App Router.

Yani istenen iş akışı — teklif kabulünde proje açma, ödeme planı/tahsilat, masraf, taşeron (+iş kalemleri), kâr/zarar özeti, dosya/foto, ek işler — **ARVEND'de zaten üretim kalitesinde bir tasarımla var**; BYZ ise bu işlevin bir kısmını (`offers` dokümanına gömülü olarak) daha kısıtlı bir modelle taşıyor.

Bu, üç olası okumadan biri olabilir ve hangisi olduğu **yalnızca kullanıcı tarafından karar verilebilir**:
1. **Kasıtlı ikili çalışma**: BYZ hâlâ üretimde canlı (gerçek mobil kullanıcılar, Cloudflare arkasında `app.byzdizayn.com.tr`), ARVEND henüz devreye alınmadı; bu özellik BYZ'ye de gerçekten isteniyor (geçici köprü / paralel bakım kabul ediliyor).
2. **Karışıklık**: İstek aslında ARVEND için yazılmıştı ama çalışma dizini/bağlam BYZ'ye kaydı; kullanıcı ARVEND'de bunun zaten var olduğunu bilmiyor olabilir.
3. **Göç niyeti**: Asıl istenen BYZ verisini/mantığını ARVEND'e taşımak, BYZ'de yeni bir paralel uygulama inşa etmek değil.

**Aşağıdaki Faz 1 raporu tam olarak istenen şekilde tamamlandı** (BYZ'nin mevcut mimarisi, veri modeli, kısıtları — 15 maddenin tümü). Ancak **Faz 2 (uygulama planı) ve Faz 3 (kod)'a geçmeden önce bu üç okumadan hangisinin geçerli olduğu teyit edilmeli** — aksi halde ya gereksiz bir ikinci implementasyon inşa edilmiş olur ya da yanlış depoda çalışılmış olur. Bu, "Do NOT begin a phase until its dependencies are understood" ilkesinin doğal bir sonucu.

---

## 1. Mevcut teklif (offer) veri modeli — VERIFIED

Tek koleksiyon: `offers` (Mongo, `erp_teklif_sistemi/services/db_service.py:150-161` indeksli). Oluşturma şeması (`routes/offer_routes.py:207-225`, mobil eşdeğeri `routes/api_routes.py:840-846`):

```python
offer_doc = {
    "offer_no": "TKF-YYYY-NNNN",          # counters koleksiyonu, atomik $inc (calculation_service.py:296-339)
    "customer_name/phone/email/address": str,   # customer_id YOK — serbest metin kopyası
    "offer_date": datetime, "valid_until": datetime,
    "items": [{product_id: ObjectId|None, product_name, quantity, unit_price, line_total, section_label, category_slug}],
    "subtotal": float, "vat_rate": float, "vat_amount": float, "grand_total": float,  # KDV DAHİL
    "notes": str, "status": "taslak"|"gönderildi"|"kabul edildi"|"reddedildi",
    "is_passive": bool, "shape_sketches": [...], "created_at": datetime,
}
```

`grand_total = subtotal + subtotal*vat_rate/100` (`services/calculation_service.py:52-60`) — sistemin **tek gelir referansı**; kârlılık, alacak, ödeme planı hepsi buradan türer. `updated_at` hiç yazılmaz. Toplamlar `float` + `round(x,2)`; `Decimal` hiçbir yerde kullanılmıyor.

Kalemde **`unit` alanı yok**. Müşteri bağlantısı **ID değil, 4 alanlık metin kopyası** (`customer_id`/`musteri_id` grep → 0 sonuç) — `offer_create.html:368-372` bunu bilinçli tasarım olarak belgeliyor.

---

## 2. Revizyon / geçmiş modeli — VERIFIED

Yeni doküman açılmaz; **yerinde güncelleme + snapshot push** (`offer_routes.py:232-263`):
```python
snapshot = {offer_no, offer_date, valid_until, items, subtotal, vat_rate, vat_amount, grand_total, notes, status, revised_at, revision}
offer_doc["revision"] = mevcut.get("revision", 0) + 1
update_one({"_id": revise_id}, {"$set": offer_doc, "$push": {"revisions": snapshot}})
```
`offer_no`/`is_passive`/`created_at` korunur; `shape_sketches` snapshot'a girmez. **Kritik:** `plan/odeme_plani/masraflar/faturalar/taseronlar/share` `$set` kapsamı dışında olduğu için revizede **korunur** — ama `grand_total` değişirse bu alt-sistemlerin tutarları (ödeme planı yüzdeleri, alacak `total_amount`) **otomatik senkronlanmaz**.

Web revize akışı kabul edilmiş teklifi **engellemiyor** (kontrolsüz); mobil 409 ile engelliyor (`api_routes.py:758-763`) + `expected_revision` optimistic-lock. Bu asimetri doğrulayıcı tarafından da bağımsız teyit edildi.

---

## 3. Müşteri ilişkisi — VERIFIED

`customers` bağımsız bir defterdir (`musteri_service.py:37-95`, tekillik uygulama katmanında `normalized_name` ile, DB index'i `unique=False`). Teklif **müşteri ID taşımaz**; yalnızca ad/telefon/e-posta/adres kopyalanır. Müşteri kartı **hard delete** edilir, teklifleri yetim bırakmaz (bilinçli tasarım: `customer_routes.py:74-88` docstring). **Müşteri cari/bakiye kavramı yok** (`cari|bakiye|balance` grep → yalnız 1 yorum satırı).

---

## 4. Mevcut masraf / cari / ödeme yapıları — VERIFIED (en kapsamlı bölüm)

**Ayrı bir `projects` koleksiyonu YOK.** "Proje" = `status == "kabul edildi"` olan `offers` dokümanının kendisi. Kod bunu açıkça söylüyor (`services/proje_ekstra_service.py:4-9`): *"Kabul edilmiş bir teklif fiilen bir 'proje'ye dönüşür ... Ayrı koleksiyon yerine offers.{masraflar,faturalar,taseronlar} gömülü dizisi kullanılıyor."*

| Varlık | Nerede | Şema | Yazarlar |
|---|---|---|---|
| **Masraf** | `offers.masraflar[]` | `{sira, kalem, tutar, tarih:str, not, eklenme}` | yalnız **web** `POST /offers/masraf/<id>`; mobil API ucu YOK |
| **Fatura** | `offers.faturalar[]` | `{sira, no, tarih, tutar, durum∈{kesildi,gönderildi,ödendi}, not}` | yalnız web; **hiçbir hesaba girmez** (kâr/nakit akış faturayı hiç okumaz) |
| **Taşeron** | `offers.taseronlar[]` + `odemeler[]` | `{sira, ad, is_tanimi, sozlesme_tutari, odemeler:[{tutar,tarih,not}]}` | yalnız web; `odenen`/`kalan` türetilir (`taseron_ozet`) |
| **Ödeme planı** | `offers.odeme_plani[]` | `{sira, ad, yuzde, tutar, vade, durum:'bekliyor'\|'tahsil edildi', tahsil_tarihi?, tahsil_tutar?}` | web **ve** mobil (`GET/POST /api/offers/<id>/payment-plan`) |
| **Alacak** | `receivables` (ayrı koleksiyon) | `{offer_id?, debtor_name, description, total_amount, due_date, source?}` | 3 farklı açılış yolu (bkz. §4.2) |
| **Tahsilat** | `receivable_payments` | `{receivable_id, amount, description, received_date}` | web+mobil+ödeme planı |
| **Borç** | `debts` | `{debtor_name, phone, debt_type, amount, paid_amount, remaining_amount, status}` | `offer_id` **sonradan**, yalnız mobil API `link-offer`; web'de bağlama formu yok |
| **Şantiye fotoğrafı** | `santiye_fotolari` + disk `erp_teklif_sistemi/santiye_foto/` | `{offer_id, dosya, sha256, asama∈{oncesi,ilerleme,sonrasi}, note, paylasimda}` | web+mobil |
| **Ekip ataması** | `assignments` | `{employee_id, date, offer_id, note}` upsert | web+mobil (ekip takvimi) |

Her gömülü kayıt kalıcı **`sira`** taşır (dizi index'i değil). **Tüm gömülü listeler "oku → tüm diziyi `$set` ile yaz" deseniyle yazılır** (`$push`/`$pull` yok) — bu **gerçek bir yarış koşulu**: iki kullanıcı aynı anda aynı teklife masraf eklerse biri kaybolabilir (doğrulayıcı bağımsız teyit etti, kilit/optimistic-concurrency kodda yok).

### 4.1 Kâr/zarar formülü — VERIFIED, satır satır doğrulandı

`services/proje_maliyet_service.py:77-152`:
```python
gelir = grand_total                                    # KDV DAHİL
iscilik = Σ (assignments ∩ attendance_logs) × daily_wage × {geldi:1.0, "yarım gün":0.5}
malzeme = Σ debts.amount WHERE debts.offer_id == oid    # tahakkuk, ödenmemiş dahil
masraf = Σ offers.masraflar[].tutar
taseron_odenen = Σ offers.taseronlar[].odemeler[].tutar # ÖDENEN (nakit), sözleşme kalanı değil
toplam_maliyet = iscilik + malzeme + masraf + taseron_odenen
kar = gelir - toplam_maliyet
kar_yuzde = kar / gelir * 100
```
**Faturalar bu hesaba hiç girmez** (kod + doğrulayıcı ikisi de teyit etti — `faturalar` alanı `_hesapla()` içinde hiç okunmuyor). Malzeme "tahakkuk" (borç `amount`), taşeron "nakit" (ödenen) esasına dayanıyor — iki kalem **farklı muhasebe mantığı** kullanıyor. `kar_yuzde` KDV dahil gelire göre; maliyet tarafında KDV ayrımı yok → marj sistematik olarak çarpık olabilir.

Kârlılık listesi (`tum_projeler`, limit 50) filtre `status ∈ {"kabul edildi","gönderildi"}` — yani **henüz kabul edilmemiş "gönderildi" teklifler de proje sayılıyor**.

### 4.2 "Kabul" üç farklı yoldan gerçekleşir, üç farklı yan etkiyle — VERIFIED

1. **Müşteri paylaşım linkinden onay** (`share_routes.py:112-155` → `offer_share_service.kabul_kaydet` + `kabul_sonrasi_kayitlar`): `status="kabul edildi"` yazar **ve** idempotent şekilde alacak açar (`source:"teklif-kabul"`).
2. **Ödeme planı ilk aşama tahsili** (`odeme_plani_service.py:187-201`): alacak yoksa lazy açar (`source:"odeme-plani"`).
3. **Web/mobil elle "kabul edildi" seçimi** (`update_offer_status`/`offer_status`): **yalnızca `status` alanını değiştirir — hiçbir yan etki yok, alacak açılmaz.**

Yani manuel olarak "kabul edildi" seçilen bir teklifin **alacağı hiç açılmayabilir** (ilk tahsilata kadar). Bu, "projeye dönüştür" tetikleyicisinin nereye bağlanacağı sorusunu doğrudan etkiliyor.

### 4.3 Diğer doğrulanmış tutarsızlıklar
- `plan_ozeti().tahsil_edilen` **planlanan** `tutar`ı toplar, gerçek `tahsil_tutar`ı değil — mobil kısmi tutar girebildiği için (`amount` parametresi) plan özeti ile alacak defteri farklı rakam gösterebilir.
- Alacak üzerinden manuel tahsilat + ödeme planı "Tahsil Et" aynı parayı iki kez `receivable_payments`'a yazabilir (çift tahsilat); tahsilat/alacak silme, ödeme planı aşamasının `tahsil edildi` durumunu **geri almaz** (doğrulayıcı: `odeme_plani_service.py` içinde bir "iptal" fonksiyonu yok, dosyanın tamamı okundu).
- Durum makinesi yok: herhangi bir durumdan herhangi birine geçilebilir (web'de doğrulamasız); "kabul edildi" tek istekle "taslak"a geri alınabilir.
- Teklif silme **cascade yapmaz**: `santiye_fotolari`/`assignments`/`debts.offer_id`/`receivables.offer_id` yetim kalır (yalnızca `status=="kabul edildi"` ise silme zaten engellenir).

---

## 5. Dosya / belge ekleri — VERIFIED

Yalnızca **şantiye fotoğrafı** için genel bir mekanizma var (`services/santiye_foto_service.py`): disk (`erp_teklif_sistemi/santiye_foto/`, `.gitignore`'da), DB'de yalnız üstveri, sha256 içerik-adresli dosya adı + mükerrer engeli, izinli uzantı `{jpg,jpeg,png,webp,heic}`, 12 MB sınır, `paylasimda` bayrağı (müşteri sayfasında gösterim). Route'lar: web `login_required`, mobil `api_login_required`, müşteri `paylasimda:true` şartıyla token'lı.

**Genel belge (PDF fatura, sözleşme, DWG) mekanizması yok** (`attachments|documents|dosyalar|ekler` grep → 0 sonuç, yalnızca bir UI açıklama metni). GridFS/Pillow-thumbnail yok; sihirli-bayt doğrulaması yok (yalnız uzantı kontrolü — APK yüklemesi hariç, o `b"PK"` kontrolü yapıyor).

PDF üretimi: WeasyPrint, `offer_print.html`'den `HTML(string=...).write_pdf()`; Google Fonts'a ağ bağımlılığı var (`@import`); sürüm pinlenmemiş. `MAX_CONTENT_LENGTH=220MB` global.

---

## 6. Mevcut API mimarisi — VERIFIED

Tek Flask blueprint `api_bp` (`/api` prefix), tüm mutasyonlar **POST-only**. Auth: `itsdangerous.URLSafeTimedSerializer` imzalı token (JWT değil), 30 gün, **iptal mekanizması yok** (şifre değişse bile eski token geçerli). Hata sözleşmesi: `{"error": "<Türkçe mesaj>"}` + durum kodu (400/401/404/409/429/500/502); başarı `{"ok": true, ...}` veya sarmalı okuma (`{"offers":[...]}`). `_jsonlanabilir` ObjectId→str, datetime→ISO (**saat dilimsiz**) dönüştürür. Sayfalama **yok**, yalnız sabit `.limit(N)`.

58 uç nokta envanteri çıkarıldı (tam tablo okuyucu raporunda). **Kritik boşluk**: masraf/fatura/taşeron/proje planı için **hiçbir mobil API ucu yok** — bu 3+1 modül yalnızca web'de erişilebilir. Ödeme planı, maliyet/kârlılık, borç bağlama, nakit akış **mobilde mevcut**.

`GET /api/offers/<id>/cost` (proje maliyet) ve `GET /api/projects/profitability` (kârlılık listesi) zaten "proje" kelimesini taşıyan uçlar — ama ikisi de `offers` okuyor.

---

## 7. Mevcut mobil mimari — VERIFIED

`StatefulWidget + setState` (provider/riverpod/bloc yok). `Api` sınıfı (`mobile/lib/api.dart`): base URL `https://app.byzdizayn.com.tr/api`, Bearer token `SharedPreferences`'ta (düz metin), 401'de otomatik çıkış. Dosya yükleme `MultipartRequest` (base64 değil). Ortak widget kütüphanesi `theme.dart` (Panel, ListeSatiri, SecimAlani, altSecim, DurumRozeti, tl(), vb.) — yeni ekranlar bunları kullanmalı.

Kabul edilmiş teklif için proje-benzeri veri gösteren ekranlar zaten var: `ProjeMaliyetEkrani`, `OdemePlaniEkrani`, `KarlilikEkrani`, `SantiyeFotoEkrani`, `EkipTakvimiEkrani` — hepsi teklif detayından 3 buton ile açılıyor (**kabul şartı olmadan her durumda görünür**, web'in `{% if status == 'kabul edildi' %}` kapısıyla tutarsız). Masraf/fatura/taşeron için mobil ekran **yok**.

Sürüm kapısı yok: eski APK'lar yeni sunucu yanıtlarıyla sorunsuz çalışmaya devam eder **ancak** mevcut JSON anahtarları yeniden adlandırılmamalı/silinmemeli — yalnızca eklenmeli.

---

## 8. Kimlik doğrulama / yetkilendirme — VERIFIED (kritik kısıt)

**Rol/yetki YOK.** `users` şeması yalnızca `{username, password_hash, full_name}` (`role`, `is_admin` yok). `login_required` yalnızca oturum var/yok kontrolü yapar; giriş yapan **her kullanıcı her şeyi yapabilir**. `created_by`/`updated_by` **hiçbir kayıtta yok** — "kim ekledi" sorusu bugün yanıtlanamaz.

**Tek kiracılı (single-tenant).** `organization_id`/`company_id`/`tenant` alanı hiçbir koleksiyonda yok (grep → 0). "Organizasyon kapsamı" = bir deploy + bir MongoDB = bir şirket; şirket kimliği yalnızca `.env`'deki `COMPANY_NAME` gibi config değerlerinde, PDF başlığı dışında hiçbir yerde kullanılmıyor.

**Sonuç:** Bu görevin istediği "org must never access another company's project/expenses/files" gereksinimi **bugün teknik olarak anlamsızdır** — sistemde birden fazla organizasyon kavramı yok. "Organization-safe endpoint" testi burada `@login_required`/`@api_login_required` varlığı + `parse_object_id`→404 + share-token beyaz listesinin sızdırmaması anlamına indirgenir (doğrulayıcı bunu ayrıca teyit etti).

CSRF koruması yok (yalnızca `SameSite=Lax`). Transaction/session desteği yok (grep → 0); çok-doküman tutarlılığı yalnız idempotent `find_one` kontrolleriyle sağlanıyor.

---

## 9. Yeni "proje" domain'i için en uygun yer — RECOMMENDATION

Koddan çıkan iki gerçekçi seçenek:

**Seçenek A — Mevcut deseni genişlet (offers-gömülü).** Zaten `plan/odeme_plani/masraflar/faturalar/taseronlar` bu şekilde çalışıyor; `proje_ekstra_service.py`, `odeme_plani_service.py`, `proje_maliyet_service.py` bu desenle yazılmış ve **anahtar parametreleştirilirse büyük ölçüde yeniden kullanılabilir** (offer_id → project_id, veya doğrudan aynı offer_id). En düşük geçiş riski, ama offers dokümanı büyümeye devam eder (kroki base64 + 50 revizyon + 6 gömülü dizi zaten 16 MB Mongo sınırına yaklaşıldığı kod yorumlarında kabul ediliyor) ve yarış koşulu riski büyür.

**Seçenek B — Ayrı `projects` koleksiyonu.** Daha temiz ama en az 6 yerde (santiye_fotolari, assignments, debts, receivables, 5 gömülü dizi, kârlılık/nakit-akış servisleri) `offer_id`→`project_id` geçişi veya çift-anahtar (`project_id` + `source_offer_id`) tutmayı gerektirir; mevcut `/karlilik`, `/api/projects/profitability`, mobil ekranlar migrasyon boyunca ya paralel çalışmalı ya da birlikte taşınmalı.

Her iki durumda da **"projeye dönüştür" tetikleyicisi tek bir merkezi fonksiyonda tanımlanmalı** — bugün 3 farklı "kabul" yolu 3 farklı yan etki üretiyor; bu görev metninin *"idempotent, prevent accidental duplicate"* gereksinimi mevcut `kabul_sonrasi_kayitlar` idempotent-alacak-açma deseninin (`offer_share_service.py:138-161`, `receivables.find_one({"offer_id"})` kontrolü) doğrudan genişletilmesiyle karşılanabilir.

---

## 10. Yeniden kullanılabilecek mevcut bileşenler — RECOMMENDATION

| İhtiyaç | Hazır bileşen |
|---|---|
| Proje numarası (PRJ-YYYY-NNNN) | `calculation_service.py:296-339` `generate_offer_number` deseni (counters + atomik `$inc`) |
| Masraf/taşeron/fatura CRUD | `proje_ekstra_service.py` (tamamı) — `sira` deseni, `(sonuc,hata)` sözleşmesi |
| Ödeme planı + tahsilat | `odeme_plani_service.py` (tamamı) — yalnız `grand_total`/`odeme_plani` alan adlarına bağımlı |
| Kâr/zarar hesabı | `proje_maliyet_service._hesapla` + `_toplu_veri` (4 sorguluk N+1'siz toplu okuma) |
| Dosya/foto deposu | `santiye_foto_service.py` (disk+üstveri+sha256 dedupe) — genel belge için uzantı listesi genişletilmeli |
| Alacak açma (idempotent) | `offer_share_service.kabul_sonrasi_kayitlar` — "projeye dönüştür" tetikleyicisinin doğal genişleme noktası |
| API iskeleti | `api_routes.py:49-77` `_jsonlanabilir` + `api_login_required`; `<int:sira>` route converter örneği |
| Index kurulumu | `db_service.py:105-198` `_INDEX_SPECS` + `ensure_indexes()` (idempotent) |
| Mobil istemci | `api.dart` Api.getir/gonder/dosyaGonder; `theme.dart` widget kütüphanesi |

---

## 11. Riskler ve çelişkiler — RECOMMENDATION öncesi tam liste

**Veri bütünlüğü**
- Gömülü dizilerin tam-`$set` yazımı → eşzamanlı yazımda kayıp güncelleme (kilit yok).
- Çift sayım riski: taşeron ödemesi hem `taseronlar[].odemeler[]` hem `debts`+`link-offer` ile girilirse iki kez maliyete yazılır.
- Fatura hiçbir hesaba bağlı değil; KDV/muhasebe mutabakatı yok.
- Teklif silme cascade yapmaz → yetim kayıtlar.

**Mimari**
- Rol/yetki/tenant/`created_by` **sıfırdan** inşa edilmeli — üzerine kurulacak mevcut bir desen yok.
- Durum makinesi yok; "projeye dönüştür" sonrası teklifin geri "taslak"a alınabilmesi proje-teklif tutarsızlığı yaratabilir.
- Tarih tipleri karışık (masraf/fatura/taşeron: string; alacak/borç: datetime) — proje modülünde tutarlı tip seçilmeli.
- Mobil API'de masraf/fatura/taşeron ucu yok; mobil-öncelikli mi web-öncelikli mi geliştirileceği baştan kararlaştırılmalı.

**Operasyonel**
- Otomatik test **yok** (`test_attendance_summary.py` assert içermiyor, her zaman "PASS" yazdırıyor); `pytest`/`mongomock`/lint hiçbiri kurulu değil. Yeni domain için test altyapısı sıfırdan kurulmalı (mongomock önerilir, `patch("services.X.get_collection")` deseni zaten kullanılıyor).
- Kök `.venv/` (2602 dosya) ve `.venv.zip` (42 MB) **git'te takipte** — bu görev kapsamında **kesinlikle dokunulmamalı/commitlenmemeli**.
- `ksucu.env` takipte, içeriği bu raporda okunmadı; eski `PROJE_DOKUMANTASYONU.md` git geçmişinde düz metin admin şifresi + Mongo URI içeriyor — bu feature commit'i sır sızıntısını büyütmemeli.
- Üretim ortamı (gunicorn worker sayısı, replica set/transaction desteği) kod/depo içinden doğrulanamadı — yalnız dokümantasyon iddiası.

---

## 12–15. Önerilen değişiklikler (DB / API / Web / Mobil) — RECOMMENDATION, taslak düzeyinde

Bu bölüm **§0'daki karar netleşmeden** detaylandırılmayacak — çünkü DB şeması (Seçenek A vs B), API yüzeyi ve mobil ekran kapsamı doğrudan o karara bağlı. Karar netleştikten sonra Faz 2 (uygulama planı) bu iskelet üzerine yazılabilir:

- **DB**: ya `offers` şemasına `proje: {donusturuldu_at, durum}` alt-dokümanı (Seçenek A) ya da yeni `projects` koleksiyonu + `_INDEX_SPECS` girdileri (Seçenek B).
- **API**: `POST /api/offers/<id>/convert-to-project` (idempotent, `kabul_sonrasi_kayitlar` deseni genişletilerek) + eksik mobil uçlar (`/expenses`, `/subcontractors`, `/invoices`) — mevcut stille (Türkçe JSON anahtarı, İngilizce URL, POST-only, `{"ok":true}`/`{"error"}`) tutarlı.
- **Web**: `offer_detail.html`'deki kapılı panellerin (masraf/taşeron/fatura) proje sayfasına taşınması ya da aynı yerde kalıp yeni "proje" durumuna bağlanması.
- **Mobil**: masraf/taşeron/fatura ekranları + API uçları sıfırdan; mevcut proje-benzeri ekranların (`ProjeMaliyetEkrani` vb.) yeni domaine yönlendirilmesi.

---

## Açık Sorular (mimarın karar vermesi gereken, önem sırasına göre)

1. **§0'daki üç okumadan hangisi doğru** — BYZ'de paralel implementasyon mu, yoksa asıl hedef ARVEND mi, yoksa BYZ→ARVEND göçü mü?
2. Proje ayrı koleksiyon mu, offers-gömülü model mi (Seçenek A/B)?
3. Gelir tanımı `grand_total` (KDV dahil, mevcut davranış) mı, `subtotal` mı?
4. Malzeme maliyeti tahakkuk (`debts.amount`) mı nakit (`paid_amount`) mı — taşeronla tutarlı hale getirilecek mi?
5. "Projeye dönüştür" tek bir merkezi tetikleyiciye mi bağlanacak (öneri: evet, `kabul_sonrasi_kayitlar` deseni genişletilerek)?
6. Rol/yetki ve `created_by` bu faz kapsamında mı eklenecek, yoksa mevcut "herkes her şeyi yapar" modeli mi korunacak?
7. Mobilde masraf/fatura/taşeron modülleri bu faz kapsamında mı (API + Flutter ekranları)?
8. Fatura kâr/zarar hesabına dahil edilecek mi (bugün hiç girmiyor)?
9. Test altyapısı (`pytest`+`mongomock`) bu vesileyle mi kurulacak?

---

*Rapor sonu. Kod tabanında hiçbir değişiklik yapılmadı.*
