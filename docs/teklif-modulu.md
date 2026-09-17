# Teklif Modülü — Teknik Dokümantasyon

> ARVEND ERP sisteminin en merkezi modülü. Bu doküman, Teklif (Offer)
> modülünün veri modelini, iş kurallarını, API'sini, yetkilendirme
> mantığını ve müşteriyle paylaşım/e-posta akışını uçtan uca anlatır.
> Kod tabanındaki gerçek dosya ve satırlara referans verir; herhangi bir
> değişiklikte bu doküman da güncellenmelidir.

---

## 1. Genel Bakış

Teklif modülü, BYZ Dizayn'ın (eski Flask/MongoDB sistemi) teklif
akışının Go/PostgreSQL karşılığıdır — iş mantığı korunmuş, geçmişte
yaşanan bir hata (KDV'nin "falsy-zero" sorunu) kök nedeninden itibaren
düzeltilmiştir. Modül üç aşamada geliştirildi:

| Aşama | Kapsam |
|---|---|
| **Faz 3 (çekirdek)** | Teklif oluşturma, kalemler, KDV/toplam hesabı, durum yönetimi, silme koruması |
| **Bu geçiş** | Paylaşım linki, müşteri onay/red sayfası, SMTP ayarları, e-posta gönderimi |
| **Kapsam dışı (gelecek)** | PDF üretimi, ödeme planı, revize geçmişi, kroki çizimi, masraf/fatura/taşeron entegrasyonu |

**Rol modeli:** Teklif oluşturma/görme/gönderme, BYZ'deki gerçek iş
akışında **sıradan personel işidir** — Users ve Ürünler modüllerinin
aksine, Teklif uçlarının hiçbirinde admin şartı yoktur. Yalnızca SMTP
ayarları (hassas kimlik bilgisi içerdiği için) admin'e özeldir.

---

## 2. Veri Modeli

### 2.1 `offers` — ana teklif tablosu

`backend/db/migrations/0004_create_offers.up.sql` (+ `0008_add_offers_share_token.up.sql`)

| Kolon | Tip | Açıklama |
|---|---|---|
| `id` | `uuid` PK | `gen_random_uuid()` |
| `offer_no` | `varchar(30)` UNIQUE | `TKF-YIL-SIRA` formatı, örn. `TKF-2026-0005` |
| `customer_name/phone/email/address` | serbest metin | **Ayrı bir müşteri tablosuna FK değil** — BYZ'deki gibi serbest metin, çünkü teklif anındaki müşteri bilgisi teklife ait bir anlık görüntüdür |
| `offer_date` | `date` | Oluşturma anında `CURRENT_DATE` |
| `valid_until` | `date`, nullable | Geçerlilik tarihi (opsiyonel) |
| `subtotal` / `vat_rate` / `vat_amount` / `grand_total` | `numeric(12,2)` / `numeric(5,2)` | Sunucu tarafında hesaplanır, istemciden gelen değerler kullanılmaz |
| `notes` | `text` | Serbest not |
| `status` | `varchar(20)` CHECK | `taslak` \| `gönderildi` \| `kabul edildi` \| `reddedildi` |
| `share_token` | `uuid` UNIQUE, NOT NULL, DEFAULT `gen_random_uuid()` | **Her teklif oluşturulduğu anda otomatik alır** — sonradan üretilmez, `/paylas/{token}` linkinin güvenlik sınırıdır |
| `is_passive` | `boolean` | Arşivleme (soft-hide), silme değil |
| `created_by` | `uuid` FK → `users(id)` ON DELETE SET NULL | Teklifi oluşturan kullanıcı |

İndeksler: `idx_offers_status`, `idx_offers_is_passive`. `share_token`
zaten UNIQUE olduğundan otomatik bir b-tree indeksi vardır (token →
teklif look-up'ı O(log n)).

### 2.2 `offer_items` — teklif kalemleri

Mongo'daki embedded `items[]` dizisi yerine ayrı bir tablo — sıralama
`sort_order` ile korunur.

| Kolon | Tip | Açıklama |
|---|---|---|
| `id` | `uuid` PK | |
| `offer_id` | `uuid` FK, **ON DELETE CASCADE** | Teklif silinirse kalemler de silinir |
| `product_id` | `uuid` FK → `products`, **ON DELETE SET NULL**, nullable | Ürün kataloğundan seçilmişse dolu; serbest satırsa `NULL` |
| `product_name` | `varchar(200)` | Ürün silinse/adı değişse bile teklifteki isim sabit kalır (o anki kayıt) |
| `quantity` / `unit_price` / `line_total` | `numeric(12,2)` | `line_total = round2(quantity * unit_price)` |
| `sort_order` | `int` | Kalem sırası |

### 2.3 `offer_counters` — teklif numarası sayacı

BYZ'deki `counters` koleksiyonuyla aynı fikir: yıl bazlı, atomik artan
sayaç.

```sql
CREATE TABLE offer_counters (
    year int PRIMARY KEY,
    seq  int NOT NULL DEFAULT 0
);
```

Numara üretimi tek bir atomik `UPSERT` ile yapılır (bkz. §4.2) — race
condition'a karşı güvenlidir (iki kullanıcı aynı anda teklif oluştursa
bile aynı numara asla üretilmez).

### 2.4 `smtp_settings` — SMTP yapılandırması (singleton)

`backend/db/migrations/0007_create_smtp_settings.up.sql`

```sql
CREATE TABLE smtp_settings (
    id            smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    host          varchar(255) NOT NULL DEFAULT '',
    port          int NOT NULL DEFAULT 587,
    username      varchar(255) NOT NULL DEFAULT '',
    password_enc  text NOT NULL DEFAULT '',
    from_email    varchar(255) NOT NULL DEFAULT '',
    from_name     varchar(150) NOT NULL DEFAULT '',
    use_tls       boolean NOT NULL DEFAULT true,
    updated_at    timestamptz NOT NULL DEFAULT now()
);
```

`id smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1)` deseni, tabloda
**tek bir satır** olmasını garanti eder (singleton tablo) — `UPSERT`
her zaman `id = 1` üzerinde çalışır (bkz. §7).

`password_enc`, düz metin şifre **değil**, AES-256-GCM ile şifrelenmiş
base64 metindir (bkz. §7.2). Bu, kullanıcının açıkça talep ettiği bir
tasarım kararıdır: *"müşteri smtp bilgi neden .env tutuyoruz, data
[base]'de şifreler tutsan"* geri bildirimi üzerine, düz metin `.env`
yerine DB + şifreleme yaklaşımına geçilmiştir.

---

## 3. İş Kuralları

### 3.1 KDV hesabı ve "falsy-zero" bug'ının önlenmesi

`backend/internal/service/offer_service.go` → `Create()`

```go
vatRate := 20.0
if in.VatRate != nil {
    vatRate = *in.VatRate
}
```

`CreateOfferInput.VatRate` bilinçli olarak `*float64` (pointer)
tipindedir. Eski BYZ Flask sisteminde `value or 20` deseni yüzünden
**açıkça girilen KDV `0`, sessizce `20`'ye dönüyordu** (Python'da `0`
falsy olduğu için). Burada:

- İstekte `vat_rate` alanı **hiç gönderilmezse** (`nil`) → %20 varsayılan.
- İstekte **açıkça `0` gönderilirse** → `0` olarak kalır.

Bu ayrım, yalnızca pointer kullanılarak "gönderilmedi" ile "sıfır
gönderildi" durumlarını birbirinden ayırt etmekle mümkündür — `curl`
ile doğrudan test edilmiş bir davranıştır (bkz. §5.3, `TKF-2026-0002`).

Hesap sırası:

```
subtotal   = round2(Σ line_total)
vat_amount = round2(subtotal * vat_rate / 100)
grand_total = round2(subtotal + vat_amount)
```

`round2()`, kuruş bazında yuvarlar (`int64(f*100+0.5)/100`) — kayan
nokta birikim hatalarını (floating point accumulation) engeller.

### 3.2 Teklif numarası üretimi

`generateOfferNo()`:

```go
seq, _ := s.q.NextOfferSeq(ctx, int32(year))
return fmt.Sprintf("TKF-%d-%04d", year, seq)
```

`NextOfferSeq` sorgusu:

```sql
INSERT INTO offer_counters (year, seq) VALUES ($1, 1)
ON CONFLICT (year) DO UPDATE SET seq = offer_counters.seq + 1
RETURNING seq;
```

Tek bir atomik `INSERT ... ON CONFLICT` — yıl ilk kez görülüyorsa `1`
ile başlar, aksi halde mevcut sayaç artırılır. Sonuç: `TKF-2026-0001`,
`TKF-2026-0002`, ... Her yıl sıfırdan başlar.

### 3.3 Durum akışı (state machine)

```
taslak ──(Mail Gönder / manuel durum değişimi)──> gönderildi
gönderildi ──(müşteri Kabul Et)──> kabul edildi   [FİNAL]
gönderildi ──(müşteri Reddet)──> reddedildi        [FİNAL]
```

- `domain.ValidOfferStatus()` dört sabit değeri kontrol eder:
  `taslak`, `gönderildi`, `kabul edildi`, `reddedildi`.
- Durum değişimi **iki yoldan** tetiklenebilir:
  1. Admin/personel panelinden manuel (`PUT /offers/{id}/status`) —
     herhangi bir duruma serbestçe geçiş yapılabilir (iş kısıtlaması
     yok, insan hatası düzeltmesi için).
  2. **Otomatik**: `Mail Gönder` çağrıldığında, teklif hâlâ `taslak`
     ise otomatik `gönderildi`ye geçer (bkz. §8.3).
  3. **Müşteri onay/red**: yalnızca `gönderildi` durumundaki teklifler
     için geçerlidir; `kabul edildi`/`reddedildi` **final**dir, tekrar
     değiştirilemez (bkz. §6.2, `ErrOfferNotRespondable`).

### 3.4 Silme koruması

```go
var ErrOfferAccepted = errors.New("kabul edilmiş teklif silinemez")

func (s *OfferService) Delete(ctx, id) error {
    ...
    if row.Status == domain.OfferStatusKabulEdildi {
        return ErrOfferAccepted   // → HTTP 409
    }
    return s.q.DeleteOffer(ctx, uid)
}
```

BYZ'deki kural korunur: **"kabul edildi" durumundaki bir teklif hiçbir
zaman silinemez** — çünkü müşteri onayının/potansiyel alacak kaydının
tek dayanağı olabilir. `taslak`, `gönderildi`, `reddedildi` teklifler
serbestçe silinebilir.

### 3.5 Pasife alma (arşivleme)

`TogglePassive()`, `is_passive` bayrağını tersine çevirir — teklif
silinmez, yalnızca listelerde "pasif" filtresine düşer. Aktif/pasif
filtre parametresi liste uçlarında zorunludur (`?filter=aktif|pasif`).

---

## 4. Roller ve Yetkilendirme

| Uç nokta grubu | `requireAuth` | `requireAdmin` | Gerekçe |
|---|---|---|---|
| `/api/v1/offers/*` (tümü) | ✅ | ❌ | Teklif oluşturma/görme/gönderme sıradan personel işi |
| `/api/v1/settings/smtp*` | ✅ | ✅ | SMTP kimlik bilgisi hassas, yalnızca admin yönetir |
| `/api/v1/public/offers/{token}*` | ❌ | ❌ | Müşteri auth'suz erişir; güvenlik sınırı tahmin edilemez UUID token'ın kendisidir |

Bu ayrım `backend/internal/httpapi/router.go` içinde açıkça
yorumlanmıştır:

```go
r.Route("/offers", func(r chi.Router) {
    r.Use(requireAuth)
    // Teklif oluşturma/görme gerçek işte sıradan personel işidir --
    // Users/Products'ın aksine admin şartı YOK.
    ...
})
```

Frontend tarafında bu, `(app)/teklifler/*` ve `(app)/mesai` gibi
**paylaşılan route grubu** ile yansıtılır — `(app)/layout.tsx` yalnızca
giriş kontrolü yapar, rol şartı koymaz; `lib/nav.ts` role göre farklı
menü öğeleri gösterir ama Teklifler/Mesai her iki role de görünür.

---

## 5. Backend Mimarisi — Dosya Haritası

Proje genelinde izlenen katman sırası: migration → sqlc query →
domain → repository (pgtype dönüşümü) → service (iş kuralı) → handler
(HTTP/JSON) → router (yetkilendirme) → main.go (wiring).

| Katman | Dosya | İçerik |
|---|---|---|
| Migration | `backend/db/migrations/0004_create_offers.{up,down}.sql` | `offers`, `offer_items`, `offer_counters` |
| Migration | `backend/db/migrations/0008_add_offers_share_token.{up,down}.sql` | `share_token` kolonu |
| Migration | `backend/db/migrations/0007_create_smtp_settings.{up,down}.sql` | `smtp_settings` |
| sqlc query | `backend/internal/repository/queries/offers.sql` | `CreateOffer`, `CreateOfferItem`, `GetOfferByID`, `GetOfferByShareToken`, `ListOffers`, `ListOfferItems`, `CountOffers`, `UpdateOfferStatus`, `SetOfferPassive`, `DeleteOffer`, `NextOfferSeq` |
| sqlc query | `backend/internal/repository/queries/settings.sql` | `GetSmtpSettings`, `UpsertSmtpSettings` |
| Domain | `backend/internal/domain/offer.go` | `Offer`, `OfferItem` struct'ları, durum sabitleri, `ValidOfferStatus()` |
| Domain | `backend/internal/domain/settings.go` | `SmtpSettings` struct'ı |
| Repository | `backend/internal/repository/pool.go` | `ToDomainOffer`, `ToDomainOfferItem` (pgtype → plain Go dönüşümleri) |
| Service | `backend/internal/service/offer_service.go` | Tüm iş mantığı — `Create`, `List`, `Get`, `UpdateStatus`, `TogglePassive`, `Delete`, `GetByShareToken`, `RespondByShareToken` |
| Service | `backend/internal/service/settings_service.go` | `GetSmtp` (şifre çözme), `UpdateSmtp` (şifre şifreleme) |
| Platform | `backend/internal/platform/crypto/secretbox.go` | AES-256-GCM `Encrypt`/`Decrypt` |
| Platform | `backend/internal/platform/mailer/mailer.go` | SMTP gönderim (`net/smtp`, TLS/STARTTLS ayrımı) |
| Handler | `backend/internal/httpapi/handler/offer_handler.go` | Auth'lu teklif uçları + `SendEmail` |
| Handler | `backend/internal/httpapi/handler/public_offer_handler.go` | Auth'suz paylaşım uçları (`Get`, `Respond`) |
| Handler | `backend/internal/httpapi/handler/settings_handler.go` | `GetSmtp`, `UpdateSmtp`, `TestSmtp` |
| Router | `backend/internal/httpapi/router.go` | Tüm route wiring + yetki grupları |
| Wiring | `backend/cmd/api/main.go` | Servislerin/handler'ların kurulumu, `SETTINGS_ENCRYPTION_KEY` doğrulaması |

---

## 6. API Referansı

Taban URL: `http://localhost:8080/api/v1` (geliştirme). Tüm istek/yanıt
gövdeleri JSON'dır. Auth, `access_token`/`refresh_token` httpOnly
cookie'leri üzerinden yapılır (`credentials: "include"`).

### 6.1 Auth'lu Teklif Uçları (`requireAuth`, admin şartı yok)

| Metod | Yol | Açıklama |
|---|---|---|
| `GET` | `/offers?filter=aktif\|pasif&page=&limit=` | Listeleme (sayfalı) |
| `POST` | `/offers` | Yeni teklif oluşturma (kalemlerle) |
| `GET` | `/offers/{id}` | Detay (kalemlerle birlikte) |
| `PUT` | `/offers/{id}/status` | Durum değiştirme (manuel) |
| `POST` | `/offers/{id}/toggle-passive` | Aktif/pasif değiştirme |
| `POST` | `/offers/{id}/send-email` | **[Yeni]** Müşteriye mail gönder |
| `DELETE` | `/offers/{id}` | Silme (kabul edildiyse 409) |

**`POST /offers` — istek gövdesi:**

```json
{
  "customer_name": "Ayse Test Musteri",
  "customer_phone": "",
  "customer_email": "",
  "customer_address": "",
  "valid_until": null,
  "notes": "",
  "vat_rate": null,
  "items": [
    { "product_id": null, "product_name": "Deneme", "quantity": 2, "unit_price": 50 }
  ]
}
```

**Yanıt (`201 Created`)** — `offerResponse` (bkz. `offer_handler.go`):

```json
{
  "id": "d70695b9-...",
  "offer_no": "TKF-2026-0003",
  "customer_name": "Ayse Test Musteri",
  "offer_date": "2026-09-12",
  "valid_until": null,
  "subtotal": 100, "vat_rate": 20, "vat_amount": 20, "grand_total": 120,
  "status": "taslak",
  "share_token": "750caf1d-84c4-4e8b-97bd-407b656e096d",
  "is_passive": false,
  "items": [ { "id": "...", "product_id": null, "product_name": "Deneme",
               "quantity": 2, "unit_price": 50, "line_total": 100 } ]
}
```

> `share_token` her yanıtta döner — frontend, `Linki Kopyala` butonunda
> doğrudan bunu kullanır (`window.location.origin + "/paylas/" + share_token`).

**`POST /offers/{id}/send-email` — istek gövdesi:**

```json
{ "to": "musteri@example.com", "subject": "", "message": "" }
```

- `to` boşsa → teklifin `customer_email`'i kullanılır; o da boşsa
  `400 Bad Request`.
- `subject` boşsa → `"Teklifiniz: TKF-2026-000X"`.
- `message` boşsa → varsayılan şablon (§8.3) + paylaşım linki eklenir;
  doluysa kullanıcının mesajının sonuna link eklenir.
- Gönderim başarılıysa ve teklif `taslak` ise → **otomatik**
  `gönderildi`ye geçirilir.
- Yanıt: `{"ok": true}` veya `400`/`500` + `{"error": "..."}`.

### 6.2 Auth'suz Paylaşım Uçları (`/public/offers/{token}`)

| Metod | Yol | Açıklama |
|---|---|---|
| `GET` | `/public/offers/{token}/` | Teklifi görüntüle (auth yok) |
| `POST` | `/public/offers/{token}/respond` | Kabul/red kararı |

**`POST .../respond` — istek gövdesi:**

```json
{ "decision": "kabul edildi" }   // veya "reddedildi"
```

Hata durumları:

| Durum | HTTP | Sebep |
|---|---|---|
| Token yok/geçersiz | `404` | `domain.ErrNotFound` |
| Teklif `gönderildi` durumunda değil | `409` | `service.ErrOfferNotRespondable` — taslak henüz gönderilmemiş, ya da zaten karar verilmiş |
| Geçersiz `decision` değeri | `400` | `"kabul edildi"`/`"reddedildi"` dışında bir şey |

`RespondByShareToken()` (offer_service.go):

```go
if row.Status != domain.OfferStatusGonderildi {
    return nil, ErrOfferNotRespondable
}
```

Bu kontrol, hem "henüz gönderilmemiş taslağın" hem de "zaten kararı
verilmiş teklifin" tekrar değiştirilmesini engeller — **idempotency**
garantisi curl ile doğrulanmıştır (aynı token'a ikinci `respond` isteği
her zaman `409` döner).

### 6.3 SMTP Ayarları (`requireAuth` + `requireAdmin`)

| Metod | Yol | Açıklama |
|---|---|---|
| `GET` | `/settings/smtp` | Mevcut ayarları getir (şifre asla düz metin dönmez) |
| `PUT` | `/settings/smtp` | Ayarları güncelle |
| `POST` | `/settings/smtp/test` | Test e-postası gönder |

**`GET /settings/smtp` yanıtı:**

```json
{
  "host": "localhost", "port": 1025, "username": "",
  "password_set": true,
  "from_email": "teklif@arvendyapi.com", "from_name": "Arvend Yapı",
  "use_tls": false, "configured": true
}
```

Dikkat: yanıtta **`password` alanı hiç yok** — yalnızca `password_set`
(boolean) döner, şifrenin var olup olmadığını belirtir, değerini asla
sızdırmaz.

**`PUT /settings/smtp` — istek gövdesi:**

```json
{
  "host": "smtp.gmail.com", "port": 587,
  "username": "arvend@gmail.com",
  "password": "yeni-sifre-veya-null",
  "from_email": "teklif@arvendyapi.com", "from_name": "Arvend Yapı",
  "use_tls": true
}
```

`password: null` (veya alan hiç gönderilmezse) → **mevcut şifreli
şifre korunur**, değiştirilmez. Bu, admin panelindeki "Şifre
(değiştirmek için doldurun)" alanının boş bırakılabilmesini sağlar
(bkz. §7.3).

**`POST /settings/smtp/test`:**

```json
{ "to": "test@example.com" }
```

Kayıtlı ayarlarla gerçek bir test e-postası gönderir; başarısızsa
`400` + SMTP hata mesajı (`"gönderilemedi: ..."`).

---

## 7. SMTP Ayarları ve Şifreleme

### 7.1 Neden veritabanında (ve neden `.env`'de değil)

İlk tasarımda SMTP kimlik bilgilerinin `.env`'de (JWT_SECRET,
DB_URL gibi) tutulması önerilmişti — gerekçe: tek-admin'li, kapalı bir
sistemde ek bir "Ayarlar" katmanı gereksiz karmaşıklık. Kullanıcı bunu
reddetti: *"müşteri smtp bilgi neden .env tutuyoruz, data[base]'de
şifreler tutsan"*. Sonuç tasarım: **hibrit** —

- `.env`'de yalnızca bir **ana şifreleme anahtarı**
  (`SETTINGS_ENCRYPTION_KEY`, 32 byte, base64) durur.
- Gerçek SMTP şifresi veritabanında, bu anahtarla **AES-256-GCM**
  şifrelenmiş olarak durur.
- Admin panelinden değiştirilebilir; sunucuya SSH/`.env` düzenleme
  gerekmez.

### 7.2 Şifreleme uygulaması

`backend/internal/platform/crypto/secretbox.go`:

```go
type SecretBox struct{ gcm cipher.AEAD }

func NewSecretBox(base64Key string) (*SecretBox, error) {
    key, _ := base64.StdEncoding.DecodeString(base64Key)  // 32 byte olmalı
    block, _ := aes.NewCipher(key)
    gcm, _ := cipher.NewGCM(block)
    return &SecretBox{gcm: gcm}, nil
}

func (s *SecretBox) Encrypt(plaintext string) (string, error) {
    nonce := make([]byte, s.gcm.NonceSize())
    io.ReadFull(rand.Reader, nonce)                         // her seferinde rastgele nonce
    sealed := s.gcm.Seal(nonce, nonce, []byte(plaintext), nil)
    return base64.StdEncoding.EncodeToString(sealed), nil   // nonce + ciphertext birlikte
}
```

- **AES-GCM** seçildi (authenticated encryption) — hem gizlilik hem
  bütünlük garantisi verir (kurcalanmış ciphertext `Decrypt`'te hata
  verir, sessizce bozuk veri döndürmez).
- Nonce her şifrelemede rastgele üretilir ve ciphertext'in başına
  eklenir (`Seal(nonce, nonce, ...)` deseni) — çözme sırasında ayrı
  saklamaya gerek kalmaz.
- Anahtar `main.go` başlangıcında doğrulanır; `SETTINGS_ENCRYPTION_KEY`
  yoksa veya 32 byte değilse **sunucu açılmaz** (`log.Fatal`) — sessiz
  bir güvenlik açığı yerine erken ve gürültülü hata.

### 7.3 `PasswordSet` deseni — şifrenin asla dışarı sızmaması

`SettingsService`, iki farklı bağlamda çalışır:

| Metod | `Password` alanı | Kullanım |
|---|---|---|
| `GetSmtp()` (dahili, mail gönderirken) | Çözülmüş düz metin | Yalnızca `mailer.Send()`'e geçirilir, asla JSON'a yazılmaz |
| Handler → `smtpSettingsResponse` | **Yok** — sadece `PasswordSet bool` | HTTP yanıtına yazılan tek bilgi: şifrenin var olup olmadığı |

Bu ayrım geliştirme sırasında bir bug olarak ortaya çıkıp
düzeltilmiştir: `UpdateSmtp()`'in ilk halinde dönüş değeri
`Password` alanını hiç doldurmuyordu, bu yüzden kaydetme sonrası
`password_set` yanlışlıkla `false` görünüyordu. Çözüm:
`domain.SmtpSettings`'e ayrı bir `PasswordSet bool` alanı eklenip her
iki serviste de (`GetSmtp`, `UpdateSmtp`) doğrudan
`row.PasswordEnc != ""`'ten hesaplanması — `curl` ile doğrulanan bir
regresyon testi haline geldi.

### 7.4 Gönderim — `net/smtp` ve TLS ayrımı

`backend/internal/platform/mailer/mailer.go`:

```go
if settings.Port == 465 {
    return sendImplicitTLS(addr, settings.Host, auth, from, []string{msg.To}, []byte(raw))
}
return smtp.SendMail(addr, auth, from, []string{msg.To}, []byte(raw))
```

- **Port 465** (implicit/wrapped TLS): bağlantı doğrudan
  `tls.Dial()` ile TLS üzerinden açılır, ardından `smtp.NewClient` bu
  bağlantı üzerine kurulur. Standart kütüphanenin `smtp.SendMail`'i bu
  modu desteklemez (yalnızca STARTTLS bilir), bu yüzden elle
  yazılmıştır.
- **Diğer portlar (587 vb., STARTTLS)**: `smtp.SendMail`, sunucu
  `STARTTLS` destekliyorsa otomatik yükseltir.
- Kimlik doğrulama: `username` boş değilse `smtp.PlainAuth` kullanılır
  (Gmail, Resend, SendGrid gibi çoğu sağlayıcı bunu destekler);
  boşsa (bazı yerel/kurumsal röle sunucuları) auth atlanır.
- Mesaj gövdesi düz metin (`Content-Type: text/plain; charset=UTF-8`),
  `MIME-Version: 1.0` başlığıyla — Türkçe karakterler doğru kodlanır.

### 7.5 Geliştirme ortamında test

Gerçek bir SMTP sağlayıcısı olmadan uçtan uca test için, `aiosmtpd`
(Python) ile yerel bir "sahte" SMTP sunucusu ayağa kaldırılıp
(`python3 -m aiosmtpd -n -l localhost:1025`), `smtp_settings` bu
adrese işaret edecek şekilde ayarlanmıştır (`host=localhost,
port=1025, use_tls=false`). Gönderilen her e-posta, bu sunucunun
konsoluna ham metin olarak basılır — gerçek bir alıcıya ulaşmadan tüm
akışın (mesaj başlıkları, gövde, link) doğruluğu görsel olarak
doğrulanabilir. Production'da bu ayarlar gerçek bir SMTP sağlayıcısına
(Gmail SMTP, SendGrid, Resend vb.) çevrilecektir.

---

## 8. Paylaşım Linki ve Müşteri Onay Akışı

### 8.1 `share_token` — nereden gelir, nasıl korunur

- Her teklif satırı, veritabanı seviyesinde `DEFAULT
  gen_random_uuid()` ile oluşturulduğu anda bir `share_token` alır —
  ayrı bir "link üret" adımı yoktur, **her teklifin her zaman bir
  linki vardır**.
- UUID v4, 122 bit rastgelelik taşır — tahmin edilerek başka bir
  teklife erişmek pratikte imkânsızdır. Güvenlik modeli tamamen bu
  varsayıma dayanır: **paylaşım linkini bilen herkes o teklifi
  görebilir ve (durumu uygunsa) karar verebilir.** Link, e-posta
  dışında paylaşılırsa (ör. yanlış kişiye WhatsApp'tan atılırsa) bu
  koruma aşılır — bilinçli bir tasarım tercihi, kullanıcı deneyimi
  lehine (ekstra bir giriş/doğrulama adımı yok).

### 8.2 Görüntüleme akışı

```
Müşteri linke tıklar
        │
        ▼
GET /paylas/{token}  (frontend, Next.js Server Component)
        │
        ▼
apiServer(`/api/v1/public/offers/{token}/`, "")   ← cookie yok, boş header
        │
        ▼
Backend: PublicOfferHandler.Get → OfferService.GetByShareToken
        │
        ├─ token geçersiz/yok  → 404 → sayfa "Bu bağlantıya ait teklif bulunamadı" gösterir
        └─ bulundu             → offerResponse (kalemlerle) JSON döner
```

Frontend (`frontend/app/paylas/[token]/page.tsx`), **hiçbir route
grubuna girmez** — `(admin)`/`(app)`/(panel)` dışında, doğrudan
`app/paylas/[token]/` altında yaşar, böylece kök `layout.tsx`'in
dışındaki hiçbir auth kontrolüne takılmaz. Sayfa; logo, teklif no +
durum rozeti, müşteri bilgisi, kalem tablosu, toplamlar ve (duruma
göre) `RespondButtons` bileşenini gösterir.

### 8.3 E-posta gönderme akışı

```
Kullanıcı (admin veya personel) teklif detayında "Mail Gönder" → form açılır
        │
        ▼
POST /api/v1/offers/{id}/send-email  { to, subject, message }
        │
        ▼
OfferHandler.SendEmail:
  1. h.svc.Get(id)                       → teklifi (ve share_token'ı) al
  2. to boşsa customer_email'i kullan; o da boşsa 400
  3. subject boşsa "Teklifiniz: {offer_no}"
  4. shareURL = frontendURL + "/paylas/" + share_token
  5. body = (varsayılan şablon veya kullanıcı mesajı) + shareURL
  6. settingsSvc.GetSmtp()                → şifre çözülmüş ayarlar
  7. mailer.Send(settings, {to, subject, body})
  8. eğer offer.Status == "taslak"        → UpdateStatus(id, "gönderildi")
        │
        ▼
{"ok": true}  (veya 400/500 + hata mesajı)
```

Varsayılan mesaj şablonu:

```
Sayın {customer_name},

Talebiniz üzerine hazırladığımız teklifi aşağıdaki bağlantıdan
inceleyebilirsiniz:
{shareURL}
```

### 8.4 Karar (kabul/red) akışı

```
Müşteri "Kabul Et" veya "Reddet" butonuna tıklar
        │
        ▼
POST /api/v1/public/offers/{token}/respond  { decision }
        │
        ▼
OfferService.RespondByShareToken:
  1. token'dan teklifi bul (404 yoksa)
  2. decision geçerli mi? ("kabul edildi" | "reddedildi")
  3. teklif.Status == "gönderildi" mi?  → değilse 409 (ErrOfferNotRespondable)
  4. UpdateOfferStatus(id, decision)
        │
        ▼
Güncellenmiş offerResponse döner → frontend router.refresh() → yeni durum gösterilir
```

Bu değişiklik **anında** admin/personel panelindeki teklif detayına da
yansır (aynı `status` alanı, aynı tablo satırı) — ayrı bir senkronizasyon
mekanizması gerekmez, çünkü tek bir `offers.status` kolonu her iki
arayüz tarafından da okunur.

---

## 9. Frontend Yapısı

| Dosya | Rol |
|---|---|
| `frontend/lib/types.ts` | `Offer` (artık `share_token` alanıyla), `SmtpSettings` tipleri |
| `frontend/lib/nav.ts` | Admin menüsüne `Ayarlar` eklendi; `Teklifler`/`Mesai` her iki role de açık |
| `frontend/app/(app)/teklifler/page.tsx` | Liste (aktif/pasif filtre) |
| `frontend/app/(app)/teklifler/yeni/page.tsx` | Oluşturma formu |
| `frontend/app/(app)/teklifler/[id]/page.tsx` | Detay — kalemler, toplamlar, müşteri kartı, **`ShareOfferCard`** |
| `frontend/app/(app)/teklifler/[id]/OfferActions.tsx` | Durum değiştirme (select) + Sil |
| `frontend/app/(app)/teklifler/[id]/ShareOfferCard.tsx` | **[Yeni]** "Linki Kopyala" + "Mail Gönder" (açılır form) |
| `frontend/app/paylas/[token]/page.tsx` | **[Yeni]** Auth'suz müşteri görüntüleme sayfası |
| `frontend/app/paylas/[token]/RespondButtons.tsx` | **[Yeni]** Kabul Et/Reddet butonları (yalnızca `gönderildi` durumunda render edilir) |
| `frontend/app/(admin)/admin/ayarlar/page.tsx` | **[Yeni]** SMTP ayarları sayfası (server component, veriyi çeker) |
| `frontend/app/(admin)/admin/ayarlar/SmtpSettingsForm.tsx` | **[Yeni]** Form + "Test Et" (client component) |

### 9.1 `ShareOfferCard` davranışı

- **Linki Kopyala**: `navigator.clipboard.writeText(window.location.origin + "/paylas/" + share_token)`
  — buton metni geçici olarak "Kopyalandı ✓" olur (2 saniye).
- **Mail Gönder**: tıklanınca inline bir form açılır (kime/konu/mesaj,
  varsayılan olarak `customer_email` ve `"Teklifiniz: {offer_no}"` ile
  önceden doldurulmuş); gönderim başarılı olursa form kapanır ve sayfa
  `router.refresh()` ile yenilenir (durum "gönderildi" olmuşsa hemen
  görünür).

### 9.2 `SmtpSettingsForm` davranışı — şifre alanı UX'i

Şifre input'u **her zaman boş** başlar (backend zaten düz metni asla
göndermiyor); eğer `password_set === true` ise placeholder
`"••••••••"` ve label `"Şifre (değiştirmek için doldurun)"` olur. Boş
bırakılıp kaydedilirse backend mevcut şifreyi korur (§6.3, §7.3).

---

## 10. Uçtan Uca Örnek Senaryo

1. Personel, `/teklifler/yeni`'den "Ayşe Test Müşteri" için 2 adet
   "Deneme" ürünü × 50 TL, KDV varsayılan (%20) ile teklif oluşturur
   → `TKF-2026-0003`, durum `taslak`, `share_token` otomatik atanır.
2. Personel, teklif detayında **Mail Gönder**'e tıklar, `to` alanına
   `ayse@example.com` yazıp gönderir.
   - Backend: e-posta gönderilir (SMTP ayarları admin tarafından daha
     önce `/admin/ayarlar`'dan kaydedilmiştir).
   - Teklif durumu otomatik `taslak` → `gönderildi`.
3. Ayşe, e-postadaki `http://.../paylas/{token}` linkine tıklar.
   - Auth'suz sayfa açılır: teklif no, kalemler, toplamlar, "Bu
     teklifi onaylıyor musunuz?" + Kabul Et/Reddet butonları
     (durum `gönderildi` olduğu için gösterilir).
4. Ayşe **Kabul Et**'e tıklar.
   - `POST /public/offers/{token}/respond {"decision":"kabul edildi"}`
   - Durum `gönderildi` → `kabul edildi` (final).
   - Sayfa "Bu teklifi kabul ettiniz." mesajını gösterir, butonlar
     kaybolur.
5. Personel, admin panelinde aynı teklife bakar → durum artık
   **"kabul edildi"** olarak görünür; **Sil** butonuna basarsa
   `409 Conflict` alır (§3.4) — teklif artık silinemez.

---

## 11. Bilinen Sınırlamalar / Sonraki Adımlar

Bilinçli olarak bu geçişin kapsamı dışında bırakılanlar:

- **PDF üretimi** — teklif şu an yalnızca web sayfası olarak
  görüntüleniyor, indirilebilir PDF yok.
- **Ödeme planı** — kabul edilen tekliften taksitli ödeme planına
  geçiş modellenmedi.
- **Revize geçmişi** — bir teklif güncellendiğinde önceki
  versiyonların saklanması yok; `UpdateStatus` dışında teklif
  içeriği (kalemler, toplamlar) oluşturulduktan sonra değiştirilemez.
- **E-posta gönderim geçmişi/loglama** — hangi teklifin ne zaman, kime
  gönderildiği ayrı bir tabloda tutulmuyor (yalnızca son gönderim
  sonucu `{"ok": true}`/hata olarak anlık döner).
- **Çoklu paylaşım linki / link iptali** — `share_token` teklif
  boyunca sabittir, yeniden üretilemez veya iptal edilemez (bir link
  sızarsa, teklif silinene kadar geçerliliğini korur).
- **Ürün fiyatlarını sıradan kullanıcıların düzenleyebilmesi** — ayrı
  bir backlog maddesi, bu modülle ilgisi yok ama henüz karara
  bağlanmadı.

---

## 12. Hızlı Referans — Dosya Haritası (özet tablo)

```
backend/
├── db/migrations/
│   ├── 0004_create_offers.{up,down}.sql
│   ├── 0007_create_smtp_settings.{up,down}.sql
│   └── 0008_add_offers_share_token.{up,down}.sql
├── internal/
│   ├── domain/{offer.go, settings.go}
│   ├── repository/
│   │   ├── queries/{offers.sql, settings.sql}
│   │   ├── sqlc/{offers.sql.go, settings.sql.go, models.go}
│   │   └── pool.go            (ToDomainOffer, ToDomainOfferItem)
│   ├── service/{offer_service.go, settings_service.go}
│   ├── platform/
│   │   ├── crypto/secretbox.go   (AES-GCM)
│   │   └── mailer/mailer.go      (net/smtp)
│   └── httpapi/
│       ├── handler/{offer_handler.go, public_offer_handler.go, settings_handler.go}
│       └── router.go
└── cmd/api/main.go

frontend/
├── lib/{types.ts, nav.ts}
└── app/
    ├── (app)/teklifler/
    │   ├── page.tsx, yeni/page.tsx
    │   └── [id]/{page.tsx, OfferActions.tsx, ShareOfferCard.tsx}
    ├── (admin)/admin/ayarlar/{page.tsx, SmtpSettingsForm.tsx}
    └── paylas/[token]/{page.tsx, RespondButtons.tsx}
```
