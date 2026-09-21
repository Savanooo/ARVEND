# Süper Admin (Platform Yöneticisi) — Yetki Modeli, Provizyon ve Legacy Admin Notu

Bu doküman, ARVEND'de **platform yönetimi** ile **organizasyon (tenant)
operasyonu** arasındaki ayrımı, gerçek bir `super_admin` hesabının nasıl
güvenle oluşturulacağını ve mevcut (legacy) `admin` hesabına neden
**dokunulmadığını** açıklar. Kod tarafındaki ayrıntılar için bkz.
`backend/docs/authorization.md`.

> Bu dokümandaki hiçbir SQL, onay alınmadan production'da ÇALIŞTIRILMAZ.
> §4'teki ifadeler yalnızca inceleme içindir ve varsayılan olarak
> `ROLLBACK` ile biter.

## 1. Üç katmanlı yetki modeli

| Katman | `users.role` | `organization_id` | `organization_role_id` | Erişim yüzeyi (API) | Web kabuğu |
|---|---|---|---|---|---|
| **A) Platform Süper Admin** | `super_admin` | `NULL` (DB CHECK: `users_super_admin_has_no_org`) | `NULL` (DB CHECK: `users_super_admin_has_no_org_role`) | Yalnızca `/api/v1/platform/*` (+ `/auth/*`) | `/super-admin/**` — `PlatformShell` (Firmalar, Planlar) |
| **B) Organizasyon Owner/Admin** | `admin` | dolu | `owner` / `admin` | Tüm tenant uçları (izinleri ölçüsünde) | `/admin/**` + iş rotaları — `AppShell` |
| **C) Operasyonel kullanıcı** | `kullanici` | dolu | `project_manager` / `finance` / `field` / `legacy_user` / özel | Yalnızca izin verilen tenant uçları (+ proje üyeliği) | `/panel/**` + iş rotaları — `AppShell` |

Değişmezler (backend'de her istekte uygulanır):

- `super_admin` bir organizasyon bağlamı **çıkarsamaz/uydurmaz**: her tenant
  rota grubu `RequireTenant` ile başlar ve `RequireOnboarded`,
  `LoadAuthorization`, `RequirePermission`, `RequireProjectPermission`
  katmanlarının **her biri** platform hesabını bağımsız olarak
  `403 {"code":"tenant_context_required"}` ile reddeder (muafiyet yoktur).
- Organizasyon hesapları (`admin` dahil) `/platform/*`'a
  `RequireRole(super_admin)` (tam eşitlik) nedeniyle giremez.
- Web: `proxy.ts` + `lib/route-policy.ts` + her route grubunun
  `layout.tsx`'i aynı karar tablosunu kullanır; doğrudan URL girişi menü
  görünürlüğüne bağlı değildir.

## 2. Legacy `admin` hesabının durumu (neden dokunulmadı)

Migration `0034` mevcut `users.role = 'admin'` kullanıcılarını organizasyon
rolü `owner`'a bağladı. Bugün production'daki `admin` hesabı şu şekildedir:

```
role = 'admin', organization_id = <Arvend Yapı>, organization_role = 'owner'
```

Yani bu hesap **bir tenant Owner'ıdır** (katman B) — platform yöneticisi
değildir. Giriş yaptığında tenant kabuğunu (Teklifler/Projeler/Müşteriler/...)
görmesi **doğru** davranıştır; ekran görüntüsündeki "Yönetici · Arvend Yapı"
tam olarak katman B kimliğidir.

Bu hesabı `super_admin`'e **dönüştürmek önerilmez**, çünkü:

1. DB kısıtı gereği `organization_id` NULL olmak zorundadır → hesap Arvend
   Yapı organizasyonundan **çıkar**; Arvend Yapı'nın tek Owner'ı ise firma
   sahipsiz kalır (uygulama katmanındaki "son owner düşürülemez" koruması
   ham SQL'de devreye girmez).
2. Platform yöneticisi ile firma sahibi ayrı sorumluluklardır; tek hesapta
   birleştirmek "en az yetki" ilkesine aykırıdır ve denetim izini (audit)
   bulanıklaştırır.
3. Bu hesabın `project_users`, `employees.user_id`, `refresh_tokens` gibi
   tenant-içi bağları vardır; dönüşüm bunların ayrıca temizlenmesini gerektirir.

**Önerilen yol: ayrı, yeni bir `super_admin` hesabı oluşturmak (§3).**
Legacy `admin` olduğu gibi kalır.

## 3. Önerilen provizyon: `create-platform-admin` CLI

Süper Admin **yalnızca** bu CLI ile oluşturulur — hiçbir HTTP ucu (platform
uçları dahil) super_admin yaratamaz; bir tenant admin'i kimseyi
`super_admin`'e yükseltemez (`organization_roles`'ta böyle bir kod yoktur).

Production sunucusunda (backend'in çalıştığı makinede, Go toolchain ile):

```bash
cd /path/to/ARVEND/backend
DB_URL="postgres://<kullanici>:<parola>@127.0.0.1:5432/<veritabani>?sslmode=disable" \
  go run ./cmd/create-platform-admin --username platform_admin --fullname "Platform Yöneticisi"
```

- Parola terminalden **gizli** olarak iki kez istenir; komut satırı
  bayrağı olarak alınmaz (shell geçmişine/`ps` çıktısına düşmez).
- `DB_URL`'i satır başına boşluk koyarak ya da `export` yerine bir
  `.env`'den okuyarak shell geçmişine yazdırmamaya dikkat edin.
- Hesap `organization_id = NULL`, `organization_role_id = NULL`,
  `must_change_password = false` ile oluşturulur.

Doğrulama (salt okunur):

```sql
SELECT username, role, organization_id, organization_role_id, must_change_password, is_active
  FROM users
 WHERE role = 'super_admin';
```

Beklenen: `organization_id` ve `organization_role_id` NULL, `is_active`
true. Ardından web'de bu hesapla giriş → doğrudan `/super-admin`
(Firmalar). `/teklifler`, `/projeler` vb. adresler `/super-admin`'e döner.

## 4. İNCELEME AMAÇLI SQL — ÇALIŞTIRMAYIN

### 4a. Ön kontroller (salt okunur, güvenli)

```sql
-- Production'da hâlihazırda bir platform hesabı var mı?
SELECT id, username, role, organization_id, organization_role_id
  FROM users WHERE role = 'super_admin';

-- Legacy admin'in tam şekli
SELECT u.id, u.username, u.role, o.name AS organization, r.code AS organization_role, u.is_active
  FROM users u
  JOIN organizations o ON o.id = u.organization_id
  LEFT JOIN organization_roles r ON r.id = u.organization_role_id
 WHERE u.username = 'admin';

-- Arvend Yapı'daki aktif Owner sayısı (dönüşüm düşünülüyorsa >= 2 olmalı)
SELECT count(*)
  FROM users u
  JOIN organization_roles r ON r.id = u.organization_role_id
 WHERE u.organization_id = '00000000-0000-0000-0000-000000000001'
   AND r.code = 'owner' AND u.is_active;
```

### 4b. (ÖNERİLMEZ — yalnızca inceleme) legacy admin'i platform hesabına dönüştürme

Bu yol §2'deki nedenlerle önerilmez; §3 tercih edilmelidir. Yine de
kararın karşılaştırılabilmesi için tam etkisi aşağıdadır. **Çalıştırılmaz;
onaylanmadan `COMMIT` edilmez.**

```sql
-- ÇALIŞTIRMAYIN -- inceleme amaçlı. Ön koşul: 4a'daki Owner sayısı >= 2.
BEGIN;

-- 1) Tenant-içi bağlar: proje erişim üyelikleri ve personel bağlantısı
DELETE FROM project_users
 WHERE user_id = (SELECT id FROM users WHERE username = 'admin' AND role = 'admin');
UPDATE employees SET user_id = NULL
 WHERE user_id = (SELECT id FROM users WHERE username = 'admin' AND role = 'admin');

-- 2) Rol/organizasyon dönüşümü (CHECK kısıtları için üçü AYNI ifadede)
UPDATE users u
   SET role = 'super_admin', organization_id = NULL, organization_role_id = NULL
 WHERE u.username = 'admin'
   AND u.role = 'admin'
   AND u.organization_id = '00000000-0000-0000-0000-000000000001'
   AND EXISTS (
         SELECT 1 FROM users u2
           JOIN organization_roles r ON r.id = u2.organization_role_id
          WHERE u2.organization_id = u.organization_id
            AND r.code = 'owner' AND u2.is_active AND u2.id <> u.id);
-- Beklenen: UPDATE 1. "UPDATE 0" ise başka Owner yoktur -> ROLLBACK.

-- 3) Açık oturumları düşür (yeni rol ancak yeni giriş ile geçerli olur)
DELETE FROM refresh_tokens
 WHERE user_id = (SELECT id FROM users WHERE username = 'admin');

ROLLBACK; -- onay olmadan asla COMMIT edilmez
```

### 4c. (Alternatif) SQL ile doğrudan platform hesabı ekleme

CLI (§3) parolayı bcrypt ile hashler; ham SQL'de hash'i elle üretmek
gerekir, bu yüzden **CLI tercih edilir**. Şablon (çalıştırılmaz):

```sql
-- ÇALIŞTIRMAYIN -- <bcrypt-hash> CLI/`auth.HashPassword` ile üretilmelidir.
INSERT INTO users (organization_id, username, password_hash, full_name, role, is_active, must_change_password)
VALUES (NULL, 'platform_admin', '<bcrypt-hash>', 'Platform Yöneticisi', 'super_admin', true, false);
```

## 5. Deploy sonrası doğrulama (production, salt okunur istekler)

Parolayı komut satırına yazmamak için gövdeyi bir dosyadan verin
(`login.json`), işiniz bitince dosyayı ve cookie jar'ları silin.

```bash
API=https://app.arvendyapi.com.tr/api/v1

# super_admin oturumu
curl -s -c sa.jar -H 'Content-Type: application/json' -d @login-sa.json "$API/auth/login" | head -c 300; echo
curl -s -o /dev/null -w 'platform/plans -> %{http_code}\n' -b sa.jar "$API/platform/plans"      # 200 beklenir
curl -s -w '\noffers -> %{http_code}\n'                 -b sa.jar "$API/offers/"             # 403 tenant_context_required
curl -s -w '\nprojects -> %{http_code}\n'               -b sa.jar "$API/projects/"           # 403 tenant_context_required

# organizasyon Owner oturumu (legacy admin)
curl -s -c owner.jar -H 'Content-Type: application/json' -d @login-owner.json "$API/auth/login" > /dev/null
curl -s -o /dev/null -w 'owner platform/plans -> %{http_code}\n' -b owner.jar "$API/platform/plans"  # 403 beklenir
curl -s -o /dev/null -w 'owner offers -> %{http_code}\n'         -b owner.jar "$API/offers/"         # 200 beklenir

rm -f sa.jar owner.jar login-sa.json login-owner.json
```

Web: super_admin ile giriş → `/super-admin`; adres çubuğuna `/teklifler`
yazınca `/super-admin`'e döner. Owner ile `/super-admin` → `/admin`'e döner.

## 6. Bilinen sınırlar / sonraki işler

- `super_admin` parolasını değiştiren bir API ucu **yoktur** (`/users/me/password`
  tenant kapsamlıdır ve platform hesabına kapalıdır). Parola değişikliği
  için CLI ile yeni hesap açıp eskisini pasifleştirmek ya da onaylı bir DB
  işlemi gerekir.
- Mobil uygulama platform kabuğu içermez; `super_admin` mobilde giriş
  yaparsa tenant uçlarından `403` alır. Mobile "bu hesap yalnızca web
  platform konsolunda kullanılır" ekranı ayrı bir iştir.
- Platform menüsünde yalnızca backend karşılığı olan öğeler vardır
  (Firmalar, Planlar). "Platform Ayarları", "Platform Kullanıcıları" ve
  global "Denetim Kayıtları" için backend ucu yoktur; eklenmedi.
