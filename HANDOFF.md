# ARVEND — Proje Durumu / Oturum Devir Dokümanı

Bu dosya, bir sonraki AI oturumunun (veya insan geliştiricinin) projeye SIFIRDAN
bakıp hızlıca bağlam kazanması için yazıldı. `README.md` artık eski (yalnızca
ilk modülü listeliyor) — gerçek, güncel durum burada ve aşağıda listelenen
diğer `docs/*.md`/`mobile/*.md` dosyalarındadır. Bu dosyayı OTURUM SONUNDA
tekrar güncellemek (yeni fazlar eklendikçe) iyi bir pratiktir, ama otomatik
değildir — bir sonraki oturum bunu elle güncellemelidir.

Son güncelleme: 2026-09-28, yeni ana sayfa (dashboard) commit'i dahil.
2026-09-26/28 oturumunun özeti §7'de, ana sayfa §7.1'de.

---

## 1. ARVEND nedir

Bir inşaat/yapı şirketi için **çok-kiracılı (multi-tenant) SaaS ERP**:
teklif → proje dönüşümü, proje finansmanı (tahsilat/masraf/fatura/taşeron),
satın alma (talep→RFQ→sipariş), taşeron sözleşmeleri (hakediş/değişiklik
emri/ödeme), bütçe/maliyet kontrolü, metraj hesaplama motoru, personel/mesai,
dosya/fotoğraf yönetimi, bildirimler. Ayrıca bir **platform (Süper Admin)**
katmanı var: firmaları (organizations) oluşturma/yaşam-döngüsü yönetimi
(askıya alma/iptal/silme) ve platform kullanıcı yönetimi — bu KESİNLİKLE
kiracı (tenant) uygulamasından izole edilmiş ayrı bir güvenlik sınırı.

Önceki sistem `byz-app` (Flask + MongoDB) idi; ARVEND bunun Go + PostgreSQL +
Next.js + Flutter ile **sıfırdan yeniden yazımı**.

## 2. Depo yapısı

```
ARVEND/
├── backend/     Go API (chi router, pgx+sqlc, golang-migrate, JWT httpOnly cookie)
├── frontend/    Next.js (App Router) — tenant uygulaması + platform (Süper Admin) konsolu
├── mobile/      Flutter — YALNIZCA kiracı (tenant) kullanıcıları için mobil uygulama
├── docs/        Tasarım/araştırma/mimari dokümanları (aşağıda liste)
└── scripts/     Yardımcı script'ler
```

### Backend (`backend/`)
- `cmd/` — giriş noktaları (`cmd/api` ana sunucu, ayrıca `create-platform-admin`
  gibi CLI yardımcıları).
- `internal/domain/` — saf iş mantığı tipleri/sabitleri (hata sentinelleri,
  durum makineleri, izin kodları).
- `internal/repository/` — `sqlc` ile üretilen SQL erişim katmanı
  (`internal/repository/sqlc/*.go` GENERATED, elle düzenlenmez — kaynak
  `internal/repository/queries/*.sql`, değişiklik sonrası `sqlc generate`).
- `internal/service/` — iş kuralları, transaction yönetimi.
- `internal/pricesource/` — tedarikçi fiyat listesi ayrıştırıcıları (Ulaş
  HTML tablosu, Demir Profil `llms-full.txt`), sabit URL'li fetcher'lar,
  Türkçe sayı ayrıştırma. Testler yalnızca elle yazılmış fixture kullanır;
  gerçek siteye ASLA test içinden gidilmez.
- `internal/httpapi/` — `handler/` (HTTP katmanı) + `middleware/`
  (`RequireAuth`, `RequireTenant`, `RequireOnboarded`, `RequirePermission`,
  `RequireProjectPermission`) + `router.go` (tüm route wiring).
- `db/migrations/` — `golang-migrate` migration'ları, numaralı (`0001`...
  `0047` şu an en yüksek; `0044`-`0047` canlıda HENÜZ çalıştırılmadı).

### Frontend (`frontend/`)
- `app/(app)/` — normal KİRACI uygulaması (teklifler, projeler, vb.).
- `app/(platform)/` — Süper Admin konsolu (`/super-admin/...`) — AYRI bir
  layout/shell/navigasyon kullanır, `lib/route-policy.ts` bu ikisini
  kesin olarak ayırır.
- `app/(onboarding)/`, `app/(auth)/`, `app/(admin)/`, `app/(panel)/` —
  diğer route grupları.
- `proxy.ts` (eski adıyla `middleware.ts`) — auth/routing guard.
- `lib/` — paylaşılan istemci mantığı (`api.ts`, `types.ts`, `status.ts`,
  `org-lifecycle.ts`, `route-policy.ts`, `nav.ts`, `auth-guards.ts`,
  `permissions.ts` (sayfa izinleri + `canAccess`), `products.ts` (tüm
  kataloğu sayfa sayfa çeker), `price-sources.ts`, `price-changes.ts`;
  yanlarındaki `.test.mts` node test dosyaları — `npm test`).
- `components/permissions/` — kişiye özel yetki matrisi (`PermissionMatrix`)
  ve onu kullanan kartlar (Personel + Kullanıcı ekranlarında ortak).

### Mobile (`mobile/`)
- Flutter + Riverpod + go_router, Material 3. **Yalnızca kiracı kullanıcıları
  içindir** — hiçbir platform-yönetim ekranı YOK (bilinçli ürün kararı).
- `lib/core/` — `api/` (tek `ApiClient`, Dio + httpOnly cookie jar + tek-uçuş
  401 refresh + merkezi hesap-erişim-engeli sınıflandırması), `auth/`
  (`AuthController`), `config/` (`AppConfig` — API base URL), `errors/`
  (`ApiException`, `AccountAccessIssue`), `theme/` (tasarım token'ları),
  `widgets/` (paylaşılan bileşenler), `utils/`.
- `lib/features/<domain>/{domain,data,presentation}/` — her modül kendi
  domain modeli + repository + ekranları.
- `lib/app/` — `app_router.dart` (TÜM redirect/guard mantığı burada
  merkezi), `app_shell.dart` (alt navigasyon: Ana Sayfa/Projeler/Teklifler/
  Görevler/Diğer).
- `API_CONTRACT.md`, `MOBILE_BACKEND_GAPS.md`, `RELEASE.md` — mobile'a özel,
  SÜREKLİ güncel tutulması gereken 3 referans dosyası (bu oturumda hepsi
  güncellendi, bkz. §6).

### `docs/`
- `authorization.md` (backend'de, `backend/docs/`) — RBAC/izin modeli.
- `super-admin-provisioning.md` — platform admin nasıl oluşturulur.
- `cost-control.md`, `contracts.md`, `procurement.md`, `subcontracts.md`,
  `teklif-modulu.md` — modül bazlı tasarım/mimari dokümanları.
- `production-deployment-plan-szutech2.md` — üretim dağıtım planı (backend
  henüz bu plana göre CANLIYA ALINMADI — bkz. mobile/RELEASE.md §14).
- `byz-*.md` — eski sistemden veri taşıma/analiz notları.

---

## 3. Kritik mimari kavramlar (ASLA karıştırılmaması gereken 3 eksen)

Sistemde bir kullanıcıyla ilgili **üç bağımsız eksen** var — biri diğerinin
yerine kullanılırsa ciddi bir güvenlik/UX hatası olur:

1. **`users.role`** — kaba platform/kiracı ekseni: `admin | kullanici |
   super_admin`. `super_admin` HİÇBİR organizasyona bağlı değildir
   (`organization_id IS NULL`) ve mobilde/kiracı uygulamasında ASLA
   görünmemelidir.
2. **`organization_role_code`/`organization_role_name`** — ince-taneli RBAC
   rolü (RBAC/Project Membership sprint'i): `owner | admin |
   project_manager | finance | field | legacy_user | <özel roller>`. Bu,
   `users.role`'den TAMAMEN AYRI bir eksendir.
3. **`deleted_at`/`is_active`/organizasyon `status`** — yaşam döngüsü/soft-
   delete ekseni, YUKARIDAKİ İKİSİNDEN DE bağımsız. Kavramlar KESİNLİKLE
   ayrı tutulur: `Askıya Al` (geçici erişim durdurma) ≠ `İptal Et`
   (iş/lifecycle sonlandırma) ≠ `Sil` (soft-delete, normal listelerden
   kaldırma — veri ASLA fiziksel silinmez).

**Etkin izin kümesi (2026-09-27'den beri):** `(rol izinleri − kişiye özel
revoke) ∪ kişiye özel grant` (`user_permission_overrides`, migration 0044).
Tek çözümleyici `GetUserPermissions` sorgusudur — `RequirePermission`,
`/auth/me` ve bildirim alıcıları hep bunu kullanır. Sahip (owner) muaftır
(kilitlenmeyi önlemek için), rol değişince kişiye özel ayarlar silinir.
`organization.users.*`, `organization.roles.*`, `organization.settings.*`
uçları izne EK OLARAK `requireAdmin` (kaba rol) ister; bu yüzden bu izinler
Sahip/Yönetici dışındakilere kişiye özel EKLENEMEZ (backend 400 döner).

**Web `/admin/**` kabuğu:** Özet, Kullanıcılar, Roller, Firma Ayarları,
Ayarlar yalnızca kaba rol `admin`'e açıktır. Ürünler, Metraj, Personel,
Maliyet Kodları, Tedarikçiler (`lib/route-policy.ts`
`PERMISSION_GATED_ADMIN_PREFIXES`) izni olan HER üyeye açıktır ve
"düzenleme" izni yoksa salt-okunur çalışır. Her sayfa kendi kapısını
çağırır (`requirePagePermission` / `requireAdminRole`).

Gerçek yetki sınırı HER ZAMAN backend'dedir (her istek sunucuda ayrıca
doğrulanır) — istemcilerdeki (`hasPermission()`, frontend route guard'ları)
kontroller yalnızca UX'tir (gereksiz 403'leri önlemek/menüyü temizlemek
için), asla TEK güvenlik katmanı değildir.

Çok-kiracılılık: her sorgu `organization_id` ile scoped'dır; cross-tenant
erişim denemeleri backend'de reddedilir (bkz. `1d16f5e` — bu türden bir
sızıntı erken bir fazda bulunup düzeltildi, o zamandan beri güvenlik
testleri bu regresyonu kapsıyor).

---

## 4. Kronolojik geliştirme geçmişi (77 commit, özetlenmiş)

**Temel (Modül 1-4, en eski commit'ler):** Auth + Kullanıcı/Rol + Admin
paneli iskeleti → Ürün kataloğu → Teklif (çekirdek) → Personel/Mesai.

**Teklif derinleşmesi (Faz 1-4):** Çok-kiracılı temel + güvenlik denetimi →
müşteri varlığı + taslak düzenleme → teklif revizyon sistemi → paylaşım
linki/audit/mail logları + yarış-durumu düzeltmeleri.

**Proje modülü (Faz 5-8):** Tekliften projeye dönüşüm → proje finans
(ödeme planı/tahsilat/masraf/fatura/taşeron) → proje operasyonları
(ekip/planlama/görev/dosya/foto/not) → Ek İşler (Change Order) + gelişmiş
kârlılık. Her fazın kendi "denetim düzeltmeleri" commit'i var — bu projede
YERLEŞİK bir pratik: her büyük fazdan sonra ayrı bir odaklı güvenlik/bug
denetimi yapılıp AYRI commit'lenir.

**Tasarım + metraj + prod hazırlığı:** Frontend tasarım sistemi modernizasyonu
→ metraj (calculations) motoru + teklif entegrasyonu → prod ortam ayarları
(API base URL ayrımı, auth refresh sertleştirme).

**Mobil uygulamanın doğuşu (`e4192e3`):** Flutter/Android uygulaması tam
üretim API entegrasyonuyla eklendi — bunu izleyen çok sayıda `feat(mobile):
complete <modül> workflows` commit'i mobildeki HER operasyonel modülü
(dosya/foto, bildirim, profil, teklif, müşteri, metraj, mesai, görev,
satın alma, taşeron hakediş/değişiklik emri) tek tek tamamladı.

**Platform + RBAC + onboarding (bu oturumdan HEMEN ÖNCEki büyük dalga):**
Süper Admin platformu + organizasyon yaşam döngüsü + onboarding backend
(`62b22ee`) → web Süper Admin konsolu + onboarding sihirbazı + firma
ayarları (`10cb953`) → mobil must-change-password + onboarding guard'ı
(`e57091b`) → backend'de first-login/onboarding zorunluluğu (`976f0bd`) →
RBAC + proje üyeliği yetkilendirme temeli (`1758ae0`) → web+mobilde RBAC/
proje erişim yönetimi yüzeyi (`9ec6c6f`).

**Cost Control, Contracts, Procurement, Subcontracts sprint'leri:** WBS
maliyet kodları + proje bütçeleri (backend+UI) → proje sözleşmesi (Contract)
varlığı, kendi durum makinesi + 3-katmanlı izin (read/manage/lifecycle) +
mobilde Ek İş salt-okunur görünürlük → Sprint 4 satın alma (talep→RFQ→
sipariş) backend+web+mobil salt-okunur → Sprint 5 taşeron yönetimi backend
→ mobilde kârlılık özeti/tahsilat/taşeron ödemeleri → dahili-yalnız
taşeron maliyet/kâr-marjı fiyatlama (teklif kalemi başına) → mobilde P0
teklif düzenleme/revizyon/dahili fiyatlama tamamlandı.

**Görev/atama düzeltmeleri:** `/tasks/mine` eklendi, mobildeki O(N)
proje-bazlı birleştirme kaldırıldı (`d9ae7df`, öncesinde `7cf7c1f` ile
"görevlerim" endpoint'inin doğru şekilde ÇALIŞANA atanmış görevlere
çözüldüğü, proje üyeliğine DEĞİL, düzeltildi).

**2026-09-22 OTURUMU (aşağıda §5-6'da tam detay):** Süper Admin'i kiracı
uygulamasından izole eden RBAC/navigasyon mimarisi düzeltmesi → masaüstü
UX cilası → EXPLICIT soft-delete (Kullanıcıyı Sil/Firmayı Sil, non-
destructive) → mobil final entegrasyon/production-hardening geçişi.

**2026-09-26/28 OTURUMU (aşağıda §7'de tam detay):** Web menü/sayfaları
Roller & Yetkiler'e uydu (13 gizli çökme giderildi) → personel/kullanıcı
ekranında kişiye özel detaylı yetkiler → BYZ'deki Ulaş fiyat senkronu
firma bazında + kâr oranı ayarları → Demir Profil ikinci kaynak + zam
geçmişi.

---

## 5. 2026-09-22 oturumu — WEB/BACKEND (4 ayrı commit, hepsi tamamlandı)

Kronolojik sıra, her biri kendi commit'i:

### Commit `09f65f7` — Süper Admin izolasyonu (RBAC/navigasyon mimarisi)
**Problem:** Platform Süper Admin ile kiracı (organizasyon) uygulaması
arasında net bir mimari ayrım yoktu. **Çözüm:** Backend'de
`RequireTenant` middleware'i + paylaşılan `rejectPlatformAccount()`
helper'ı — `super_admin`'in hiçbir kiracı iznini/onboarding kontrolünü
miras ALAMAYACAĞINI ve sessizce bir kiracı bağlamında ÇALIŞAMAYACAĞINI
garanti eder (`403 {"code":"tenant_context_required"}`). Frontend'de
`lib/route-policy.ts` (tek gerçek kaynak), `PlatformShell.tsx` (ayrı
kabuk/navigasyon), `proxy.ts`/`auth-guards.ts` güncellemeleri. Kapsamlı
middleware + izolasyon testleri eklendi (`require_tenant_test.go`,
`platform_isolation_test.go`).
**KESİN KURAL:** `super_admin` HER ZAMAN `organization_id IS NULL,
organization_role_id IS NULL` olmalı, hiçbir zaman tenant bağlamında
DOLAYLI/SESSİZCE çalışmamalı. Legacy production admin hesabı
MUTASYONA UĞRATILMADI (yalnızca review-only bir SQL önerisi
dokümante edildi, hiçbir zaman çalıştırılmadı).

### Commit `f960189` — Masaüstü UX cilası (Süper Admin ekranları)
**Kapsam:** SADECE frontend layout/interaksiyon/spacing — backend
davranışı/yetkilendirme/veritabanı verisi/yaşam döngüsü kuralları
DEĞİŞTİRİLMEDİ. On maddelik bir problem listesi çözüldü: dar içerik
genişliği (1180-1360px'e çıkarıldı), sol-üste sabitlenmiş modal'lar
(gerçek kök neden: Tailwind v4 preflight'ın `margin:0` reset'i, UA'nın
`dialog{margin:auto}`'sunu eziyordu — `m-auto` ile düzeltildi), yeni
`Drawer.tsx` bileşeni (sağdan açılan panel), organizasyon detay sayfası
iki-kolonlu yeniden tasarım, Kullanıcılar sekmesi gerçek bir admin
tablosu oldu, Kullanıcı Oluştur UX'i ("Kullanıcı Oluştur", rol varsayılan
SEÇİMSİZ), yaşam-döngüsü buton hiyerarşisi (Askıya Al=ikincil/uyarı,
İptal Et=görsel olarak ayrılmış yıkıcı), legacy hesap gösterimi
("Yönetici"/"admin" gerçek verisi korundu, rol "Sahip" olarak gösterilir),
1440/1280/1024/768px responsive kontrolleri.

### Commit `2244e5e` — Explicit soft-delete (Kullanıcıyı Sil / Firmayı Sil)
**Önceki varsayımın DÜZELTİLMESİ:** Faz F'nin bir guard testi "silme
aksiyonu OLMAMALI" varsayımıyla yazılmıştı — bu oturumda kullanıcı bunu
AÇIKÇA TERSİNE ÇEVİRDİ: ürünün GÖRÜNÜR "Sil" aksiyonlarına ihtiyacı var,
AMA silme KESİNLİKLE non-destructive (yumuşak silme) olmalı.
**Backend:** migration `0043` — `deleted_at timestamptz NULL, deleted_by
uuid NULL` (ek, additive) hem `users` hem `organizations` tablosuna.
`POST .../delete`/`POST .../restore` eylem-fiili rotaları (HTTP DELETE
metodu ASLA kullanılmaz — mevcut `deactivate`/`reactivate` konvansiyonuyla
tutarlı). **KESİN KURAL — LAST OWNER RULE:** son aktif/silinmemiş Owner
silinemez, bu backend'de (`guardLastActiveOwner` — deactivate/rol-değişimi/
silme'de PAYLAŞILAN aynı helper) zorlanır, yalnızca UI'da DEĞİL. Kullanıcı
soft-delete = otomatik olarak `is_active=false` DA olur (login/refresh/
session reddi SIFIR yeni kontrolle otomatik çalışır). Kullanıcı adları
KALICI olarak rezerve kalır (global UNIQUE constraint, değişmedi — bu,
"kullanıcı adı yeniden kullanım davranışı açıkça tanımlanmalı" gereksinimine
verilen açık cevap). Restore, reaktivasyonla BİRLEŞTİRİLMEDİ (bilinçli
tasarım: geri yüklenen kullanıcı "Pasif" kalır, ayrı bir "Aktifleştir"
gerekir — denetlenebilirlik için). Organizasyon soft-delete AYNI mekanizma
üzerinden erişimi engeller (askıya alma ile aynı `RequireAuth` per-request
kontrolü, artık `deleted_at`'i de okuyor). **`cancelled` asla "silindi"
anlamına GELMEZ** — üç kavram (Askıya Al/İptal Et/Sil) kod ve UI'da AYRI
tutulur. Frontend: Firmalar/Kullanıcılar sekmelerinde Arşiv/Silinenler
filtresi, organizasyon silme için firma-adı-yazarak-onay deseni,
"TEHLİKELİ İŞLEMLER" sayfa-altı danger zone (normal durum/plan
butonlarından AYRI). **Test kapsamı:** soft-delete/restore/last-owner-
guard/cross-tenant-IDOR/hard-DELETE-yok testleri (`platform_soft_delete_
test.go`, `platform_soft_delete_security_test.go`).

**Doğrulama:** Her üç commit'te de `go build/vet/test ./...` VE
`npm test`/`tsc`/`lint`/`build` tam yeşil; gerçek local dev DB'ye karşı
canlı tarayıcı doğrulaması (`rbac-dogrulama` test organizasyonu + local
`localsuper` süper admin hesabı `create-platform-admin` CLI'ı ile
oluşturuldu). Production'a HİÇBİR ŞEY push/deploy EDİLMEDİ.

---

## 6. 2026-09-22 oturumu — MOBIL final entegrasyon (commit `519b9f5`)

**Görev:** Mobil uygulamayı yukarıdaki backend değişiklikleriyle (RBAC/
soft-delete/onboarding) senkronize etmek + production-hardening. **KESİN
ÜRÜN KURALI:** ARVEND Mobile SADECE bir kiracı-kullanıcı uygulamasıdır —
hiçbir platform-yönetim/firma-yönetim/plan-yönetim/organizasyon-silme-UI'ı
mobilde YOK ve OLMAYACAK.

### 6.1 Hesap-erişim-engeli mimarisi (en büyük yeni parça)
Backend denetimi (bir araştırma ajanıyla, gerçek Go kaynağı okunarak)
şunu netleştirdi: organizasyon suspended/cancelled/deleted → backend'in
ÜÇÜ İÇİN DE AYNI 403 gövdesini döndüğünü (`"firma askıya alınmış veya
erişilemiyor"`, kod YOK) — mobil bunları AYIRT EDEMEZ ve ETMEMELİ. Aynı
şekilde kullanıcı inactive/deleted → AYNI `"kullanıcı pasif durumda"`
gövdesi. Yalnızca `super_admin`'in bir kiracı ucuna isabet etmesi
makine-okunur bir `code:"tenant_context_required"` taşıyor.

**Yeni katman** (`lib/core/errors/api_exception.dart`,
`lib/core/api/api_client.dart`): `AccountAccessIssue` enum'u +
`classifyAccountAccessIssue()` — bu ÜÇ sabit imzayı MERKEZİ olarak,
Dio'nun `onError` interceptor'ında sınıflandırır (HER istekte, yalnızca
401 refresh akışında DEĞİL). Tek-seferlik bildirim guard'ı
(`_accountBlockNotified`) istek fırtınasını önler; yeni bir girişte
(`resetAccountAccessGuard()`) açılır. `AuthController`'a yeni
`accountAccessIssueProvider` eklendi, TEK yetkili oturum-sıfırlama yolu
(`sessionExpired()`) hem sıradan token-süresi-dolması hem hesap-engeli
için kullanılıyor.

**Yeni ekranlar:**
- `SuperAdminUnsupportedScreen` — `super_admin` giriş yapar yapmaz
  (`app_router.dart`'ın `_forcedRouteFor`'unda İLK kontrol, herhangi bir
  kiracı API çağrısından ÖNCE) buraya yönlendirilir. Tam gereken metin:
  *"Bu hesap platform yönetimi içindir. Yönetim panelini web üzerinden
  kullanın."* Çıkış butonu var, hiçbir kiracı API'si ÇAĞIRMAZ.
- `AccountAccessBlockedScreen` — organizasyon engellendiğinde, çıkış
  butonlu özel bir ekran (kendi mesajıyla).
- `LoginScreen` — kullanıcı engeli (userBlocked) durumunda, düz giriş
  ekranına dönüp tek seferlik bilgilendirici bir mesaj gösterir (organizasyon
  engelinden BİLİNÇLİ OLARAK farklı UX — spec'in kendi ayrımı).

### 6.2 İzin-tabanlı yazma aksiyonu regresyon denetimi — 6 gerçek bug bulundu ve düzeltildi
Arka planda çalışan bir denetim ajanı, 13 operasyonel modülü backend'in
GERÇEK RBAC izin kodlarına karşı kontrol etti (sahte/yüzeysel değil —
`router.go`'daki her `perm()` çağrısına karşı doğrulandı):
1. Proje Finans sekmesi "Masraf/Tahsilat Ekle" — HİÇ izin kontrolü YOKTU.
2. Proje Genel Bakış hızlı aksiyonları, aynı butonlar — YANLIŞ izinle
   (`.read` yerine `.manage`) kontrol ediliyordu.
3. Taşeron detay "Ödeme Ekle" — HİÇ izin kontrolü YOKTU.
4. Teklifler ekranı "Yeni Teklif" FAB — HİÇ izin kontrolü YOKTU.
5. Metraj ekranı "Teklife Ekle" (bağımsız modda) — HİÇ izin kontrolü
   YOKTU.
6. RFQ detay "Bu Tekliften Sipariş Oluştur" — yalnızca ödül durumuna
   bakıyordu, `canManage` izin kontrolü EKSİKTİ.
Hepsi, dosyanın kendi içindeki KANITLANMIŞ `_failOpen`/`hasPermission()`
deseniyle düzeltildi (yeni bir desen İCAT EDİLMEDİ). Hiçbir raw Dio
kullanımı (merkezi interceptor'ı atlayan) bulunmadı. `user.role`'ün RBAC
yerine yanlışlıkla kullanıldığı tek yer (`other_menu_screen.dart`'taki
"Firma Ayarları" görünürlüğü) incelendi ve backend'in KENDİSİ o ucu
`requireAdmin` (RBAC `perm()` DEĞİL) ile koruduğu için DOĞRU olduğu
doğrulandı — yalnızca netleştirici bir yorum eklendi, kod DEĞİŞTİRİLMEDİ.

### 6.3 Doğrulama
`flutter analyze`: temiz. `flutter test`: **375 geçti** (13'ü bu oturumda
eklendi — hesap-erişim sınıflandırması, 3 yeni ekran, 6 izin-düzeltmesi
regresyonu). `flutter build apk --debug/--release` ve `flutter build
appbundle --release`: hepsi BAŞARILI (gerçek prod keystore bu makinede
YOK, bilinçli olarak — release build debug anahtarıyla imzalanıyor,
Gradle bunu AÇIKÇA loglar). iOS: bu makinede Xcode TAM kurulu değil
(yalnızca Command Line Tools) — `flutter build ios` denenemedi, ama tüm
konfigürasyon dosyaları (bundle ID, Info.plist izinleri, ikon) elle
doğrulandı ve DOĞRU.

### 6.4 Doküman güncellemeleri (aynı commit içinde)
`API_CONTRACT.md` — Auth bölümü tamamen yeniden yazıldı (organization_id/
role/permissions artık VAR, hesap-erişim-engeli tablosu eklendi), YENİ
"Procurement & Subcontracts" ve "Organization" bölümleri eklendi (önceden
HİÇ dokümante edilmemişti), alt kısımdaki kendiyle-çelişen "Confirmed
backend gaps" listesi düzeltildi. `MOBILE_BACKEND_GAPS.md` — #2 (org
adı/id) RESOLVED işaretlendi, #5/#7 (change order approve/reject) kapsamı
daraltıldı (proje-seviyesi vs taşeron-seviyesi ayrımı netleştirildi —
taşeron-seviyesi zaten authenticated approve/reject'e SAHİP). `RELEASE.md`
— 2026-09-22 yeniden-doğrulama notu eklendi.

**Commit:** `519b9f5` (2026-09-28'de diğer commit'lerle birlikte push edildi).

---

## 7. 2026-09-26/28 oturumu — yetkiler + tedarikçi fiyatları (6 commit, push edildi)

### Commit `4b85305` — Firmanın kendi eklediği üye "Eski Sistem" olmasın
Kiracı kendi panelinden kullanıcı eklediğinde kişi `legacy_user` ("Eski
Sistem") rolüne düşüyordu. `POST /users` artık `organization_role_code`
ZORUNLU alır; web formu rol seçtirir.

### Commit `f8fc4be` + `1ab53c4` — Menü ve sayfalar izne uydu
Web menüsü yalnızca kaba role bakıyordu; izni olmayan bölümü görüp tıklayan
üye backend 403'ü yüzünden çöken sayfaya düşüyordu. Her menü öğesi, sayfasının
ilk çağırdığı ucun izniyle süzülür; her sayfa veri çekmeden önce
`requirePagePermission` çağırır. `loading.tsx` olan rotalarda hata HTTP 200
ile akıp RSC içinde `E{"digest":...}` satırı olarak gelir — sadece 500'e
bakan tarama bunları kaçırıyordu; 6 rol × tüm sayfalarda 13 gizli çökme
bulunup giderildi.

### Commit `cd80e7b` — Kişiye özel detaylı yetkiler
- Personel ekle/düzenle ve Kullanıcı detay ekranlarında rol + kutucuk kutucuk
  izin matrisi (`components/permissions/`). Yazma izni açılınca görüntüleme
  izni de açılır, görüntüleme kapanınca bağlı yazma izinleri kapanır.
- Girişi olmayan personele personel ekranından hesap açılabilir.
- Backend: `GET/PUT /users/{id}/permissions` (roles.read / roles.manage).
- Yönetim kabuğu izne açıldı (bkz. §3); Ürünler/Metraj/Maliyet Kodları/
  Tedarikçiler/Personel salt-okunur modları.
- Maaş/yevmiye API'den yalnızca `employees.manage` sahibine döner.
- Teklif ve Metraj ürün seçicileri tüm kataloğu yükler (list ucu sayfa başına
  en fazla 200 döndürür, 200 üstü limit SESSİZCE 50'ye düşer — eskiden yalnızca
  alfabetik ilk 50 ürün seçilebiliyordu).

### Commit `e1bdbc1` — Ulaş'tan ürün çekme + kâr oranı
BYZ ürünleri `ulas.com.tr/flist.asp` listesinden %15 kârla çekiyordu (buton +
gece 00:05). ARVEND'de firma bazında: Ürünler sayfasında kaynak kartı,
"Ulaş'tan Güncelle", varsayılan + kategori bazında kâr oranı, oran değişince
anında yeniden fiyatlama (fiyat geçmişiyle). KESİN KURALLAR:
- Eşleşme yalnızca o kaynağın satırları arasında (ad, birim, kategori);
  ürün id'leri korunur → teklif/reçete bağlantıları kopmaz.
- Elle eklenen ürünlere dokunulmaz; listeden düşen ürün SİLİNMEZ
  (`source_synced_at` ile "listede yok" işaretlenir) — `project_change_order`
  kalemleri ürünlere silme kuralı olmadan bağlı, silme FK hatası verir.
- Gece senkronu her firmada varsayılan KAPALI; açan firmalar için advisory
  lock ile tek sefer çalışır. `PRICE_SYNC_SCHEDULER=off` ile tamamen kapanır.
- Tedarikçi alış fiyatı ve kâr oranları yalnızca `products.manage` sahibine
  döner (satış fiyatı + oran = maliyet).
- Ulaş'ın kendi listesinde hatalı fiyatlar var (ör. bir 2,5 Lt boya 3,1 TL);
  ayrıştırıcı sadık, veri kaynağın kendisinde böyle.

### Commit `1b83e81` — Demir Profil + Zam Geçmişi
- Demir Profil (Omega Çelik) `https://www.demirprofil.com.tr/llms-full.txt`
  (haftalık, toptan, KDV hariç). Başlık-güdümlü ayrıştırıcı: kutu profil/boru
  ₺/m, sac/hadde ₺/kg, sandviç panel ₺/m², delikli sac ₺/adet; "KDV dahil"
  sütunları ASLA kullanılmaz, fiyatsız çatı satırları atlanır (~3.022 ürün).
  Sitenin kullanım notu kaynak ve liste ayının belirtilmesini ister —
  fiyatların görüldüğü her yerde "Kaynak: demirprofil.com.tr — <Ay Yıl>
  listesi" yazar.
- Kaynaklar tek bir kayıt defterini paylaşır (`domain.PriceSources`).
- Gelen liste son başarılı senkronun yarısından kısaysa hiçbir fiyat değişmez.
- `product_price_history` artık `reason` (supplier/markup/manual), `source` ve
  eski/yeni tedarikçi fiyatını tutar (migration 0046).
- `/admin/urunler/zamlar` "Zam Geçmişi": dönem özeti, "Zam Gelen Ürünler"
  tablosu (kaynak/neden/yön/kategori filtreleri), güncelleme zaman çizelgesi.
  API: `GET /products/price-changes`, `GET /products/price-changes/summary`.

### Fiyat kaynağı araştırması (2026-09-27, 34 kaynak tek tek doğrulandı)
Bağlanabilir: Demir Profil (yapıldı), ABS Alçı (PDF fiyat listesi), TÜİK
İnşaat Maliyet Endeksi (fiyat değil, endeks; resmi API). ÇŞB/YFK birim
fiyatları ve BirimFiyat.net yazılı izin/lisans olmadan yazılıma AKTARILAMAZ.
Akakçe, Cimri, Bauhaus, Trendyol, Proemtia vb. şartları otomatik veri
toplamayı yasaklıyor.

### Doğrulama
Backend `go test ./...`, frontend `tsc`/`eslint`/129 node testi/`build`,
mobil `flutter analyze` + 375 test yeşil. Yerel dev DB'de 6 rol (owner,
admin, legacy_user, project_manager, finance, field) × ~37 sayfa taramasında
0 çökme. Ulaş (628) ve Demir Profil (3.022) senkronu yerel test firması
"Deneme Magaza"da canlı denendi.

## 7.1 Ana sayfa (dashboard) — 2026-09-28

Web `/admin` + `/panel` ve mobil "Ana Sayfa" sekmesi baştan tasarlandı.
Bağlayıcı tasarım şartnamesi: **`docs/dashboard/SPEC.md`** (kodda "spec §…",
"spec D…" diye anılır); ortak test verisi `docs/dashboard/fixtures/*.json`
(owner, empty_company, field, finance) — backend sözleşme testi, web node
testleri ve mobil model/golden testleri AYNI fixture'ları kullanır.

- **Backend:** tek uç `GET /api/v1/dashboard` — tek RepeatableRead salt-okunur
  snapshot, her bölüm kendi SAVEPOINT'inde (bir bölüm hata verirse yalnızca o
  bölüm hata işaretiyle döner). Bölüm yoksa = izin yok; izinli bölüm içindeki
  yetkiye bağlı alan `null`. Proje bazlı sayılar üyelik kuralına uyar. Maaş,
  kâr oranı, tedarikçi fiyatı ASLA dönmez. `GET /dashboard/project-options`
  para içermeyen proje seçici. Migration `0047` yalnızca indeks.
  Veritabanı oturum saat dilimi artık kodda `Europe/Istanbul`'a sabit
  (`repository/pool.go`), `CURRENT_DATE` her ortamda İstanbul günü.
- **Sayfa:** selamlama + hızlı işlemler → özet cümle → Nabız (en çok 4 KPI) →
  Dikkat Gerektirenler (Senin sıran / Takipte / Yaklaşan 14 gün) + Nakit Akışı
  (6 ay) veya Görevlerim → 18 bölüm kartı 4 bantta (Nakit & Satış, Proje &
  Saha, Tedarik & Maliyet, Firma Kayıtları) → Son Hareketler + Bildirimler.
  Grafik kütüphanesi yok (ProgressBar/SegmentBar/PairedBars elle çizildi).
  Para gösterimi: 1 milyon altı tam, üstü "12,5 Mn TL" / "1,2 Mr TL".
- **Mobil golden testleri:** `mobile/test/features/dashboard/goldens/`
  (360×800, 412×915, 360 tam sayfa × 4 persona). Görsel değişiklikte
  `flutter test test/features/dashboard --update-goldens` ile yenilenir.
- **Örnek veri:** "Deneme Magaza" test firmasına API üzerinden gerçekçi
  demo veri girildi (6 müşteri, 13 teklif, 5 proje, görevler, mesai, satın
  alma, taşeron vb.) — yalnızca yerel dev DB.
- Doğrulama: backend testleri, web 231 node testi + build, mobil 447 test
  yeşil; 6 rol web taramasında 0 çökme; Saha kullanıcısının yanıtında/DOM'unda
  hiç para değeri yok.

---

## 8. Bilinen eksikler / bir sonraki oturumun bilmesi gerekenler

- **`README.md` köke güncel DEĞİL** (yalnızca ilk modülü listeliyor) — bu
  `HANDOFF.md` şimdilik daha güncel referans.
- **Canlı durum (2026-09-28):** `app.arvendyapi.com.tr` szutech2'de çalışıyor;
  2026-09-28'de `97f1699` + `a92343d` (kilit dosyası düzeltmesi) sürümüne
  güncellendi, veritabanı şeması `0047`. `docs/production-deployment-plan-
  szutech2.md` ESKİMİŞ: gerçekte Caddy `:8088` → API `127.0.0.1:8081`
  (8080'de başka bir proje var) + web `127.0.0.1:3000`; `/opt/arvend/src`
  git deposu değil düz kopya; sunucu GitHub'dan çekemiyor. Güncelleme yolu:
  yerelde `git archive` + Linux'a derlenmiş `arvend-api` → sunucuda
  `~/arvend-release-<commit>/` → `deploy.sh` (yedek → web derle → API durdur,
  migration → başlat → doğrula), yanında `rollback.sh`. Sunucudaki npm 10
  kilit dosyasını reddeder: `npx -y npm@11.6.2 ci`. Migration'lar YALNIZCA
  API durdurulmuşken çalıştırılır (eski ikili yeni sütunlarda `SELECT *`
  taramasında hata verir).
- **Bilinen veri sızıntıları (ayrı iş olarak işaretlendi, düzeltilmedi):**
  `GET /projects` finans izni olmayana (Saha, Proje Yöneticisi) proje
  tutarlarını döndürüyor; `GET /projects/{id}/events` tahsilat/masraf
  olaylarının tutarlarını döndürüyor; proje listesindeki gerçekleşen maliyet
  proje özetindeki formülden eksik hesaplanıyor. Ana sayfa bunları
  KULLANMAZ (bkz. `docs/dashboard/SPEC.md` §9 madde 8).
- **Arvend Yapı'nın (canlı firma) kataloğu** hâlâ 2026-09-12'deki tek
  seferlik BYZ aktarımından; Ulaş/Demir Profil'den hiç senkronlanmadı, gece
  otomatiği kapalı — açmak firma sahibinin kararı.
- **Yeni firmalarda Metraj reçeteleri ürünlere bağlı değil** (`product_id`
  NULL, referans fiyat kullanılır); çekilen Ulaş/Demir Profil ürünlerine
  bağlanmadı.
- **Web'de bildirimler "yakında"** — zamlar yalnızca Zam Geçmişi sayfasında
  ve kaynak kartlarında görünür; açık tekliflerdeki ürünlere gelen zam için
  uyarı yok.
- **Fiyat kaynakları, Zam Geçmişi ve kişiye özel yetki düzenleme yalnızca
  web'de.** Mobil `/auth/me` izinlerini kullandığı için kişiye özel izinler
  mobilde de geçerli olmalı, ama cihazda ayrıca denenmedi.
- Yerel dev DB'deki test verileri (Deneme Magaza'da ~3.650 senkron ürün,
  `detayli.yetki`/`girissiz.personel` test hesapları) yalnızca yereldir.
- **Mobil store-release blokerleri** (mobile/RELEASE.md §9, §14'te tam
  liste): Gizlilik Politikası/KVKK metni YOK (her iki mağaza için SERT
  blokaj), Apple Developer Program üyeliği + tam Xcode kurulumu YOK,
  Android production keystore henüz üretilmedi (kullanıcının kendisi
  yapmalı, ajan/oturum üretemez).
- **`.contract-source/*.md`** (mobile/) — 2026-09-15 tarihli derin-dalış
  dokümanları, auth kısmı artık KISMEN eski (API_CONTRACT.md'nin kendisi
  şimdi bu konuda otoriter, orada açıkça not edildi).
- Bu oturumda dokunulmayan ama mevcut olan büyük modüller: Cost Control
  (bütçe/WBS), Contracts (proje sözleşmesi), Procurement (satın alma),
  Subcontracts (taşeron) — hepsi ÇALIŞIR durumda, bu oturum yalnızca
  mobildeki İZİN GÖRÜNÜRLÜĞÜ regresyonlarını düzeltti, bu modüllerin
  backend/web tarafına dokunmadı.

## 9. Hızlı doğrulama komutları

```bash
# Backend
cd backend && go build ./... && go vet ./... && go test ./...

# Frontend
cd frontend && npm test && npx tsc --noEmit && npx eslint . && npm run build

# Mobile
cd mobile && flutter analyze && flutter test && flutter build apk --debug
```

## 10. İlgili diğer dokümanlar (bu dosyanın DETAYLARINI taşımaz, yalnızca işaret eder)

- `backend/docs/authorization.md` — RBAC/izin modeli tam referansı.
- `docs/dashboard/SPEC.md` — ana sayfa (dashboard) tasarım şartnamesi,
  `docs/dashboard/fixtures/` ortak test verisi.
- `docs/super-admin-provisioning.md` — platform admin nasıl oluşturulur.
- `docs/cost-control.md`, `docs/contracts.md`, `docs/procurement.md`,
  `docs/subcontracts.md`, `docs/teklif-modulu.md` — modül mimarisi.
- `mobile/API_CONTRACT.md` — mobilin backend'e karşı GÜNCEL sözleşmesi
  (bu oturumda büyük ölçüde yeniden yazıldı, en güncel referans).
- `mobile/MOBILE_BACKEND_GAPS.md` — mobil'in backend'de gördüğü, henüz
  kapatılmamış (veya kasıtlı olarak yapılmamış) eksiklikler.
- `mobile/RELEASE.md` — mobil store-release kontrol listesi, TAM ve güncel.
