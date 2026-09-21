# Yetkilendirme (Authorization) — RBAC + Proje Erişimi

Bu doküman, ARVEND V2 Sprint 1'de eklenen ince-taneli yetkilendirme
katmanını açıklar: platform rolü ile organizasyon rolü ayrımı, izin
kayıt defteri, proje üyeliği, istek yetkilendirme akışı, varsayılan
roller, yeni izin/rota ekleme adımları ve test gereksinimleri.

## 1. İki bağımsız eksen

ARVEND'in yetkilendirmesi **iki tamamen ayrı eksenden** oluşur; biri
diğerine hiçbir zaman köprülenmez.

### 1.1 Platform rolü (`users.role`)

- Değerler: `admin`, `kullanici`, `super_admin`.
- `super_admin`: `organization_id = NULL`, `organization_role_id = NULL`;
  yalnızca `/api/v1/platform/*` uçlarına erişir (organizasyon izolasyonu
  dışında, bilinçli olarak). `RequireRole(domain.RoleSuperAdmin)` ile
  korunur. Tenant uçlarında **muafiyeti YOKTUR**: `RequireTenant` ve
  ardındaki her katman (`RequireOnboarded`, `LoadAuthorization`,
  `RequirePermission`, `RequireProjectPermission`) onu bağımsız olarak
  `403 {"code":"tenant_context_required"}` ile reddeder — platform
  hesabı için asla bir organizasyon çıkarsanmaz/uydurulmaz. Provizyon
  yalnızca `cmd/create-platform-admin` CLI'ı ile yapılır (bkz.
  `docs/super-admin-provisioning.md`, repo kökü).
- `admin` (users.role) **platform yöneticisi DEĞİLDİR**: organizasyon
  Owner/Admin'idir (migration 0034 legacy `admin`'i org rolü `owner`'a
  bağladı) ve tenant kabuğunu/menüsünü görmesi doğrudur.
- `admin`/`kullanici`: organizasyona bağlı (tenant) kullanıcılar; bu
  sprint'ten SONRA business uçlarında artık **kullanılmıyor** (bkz.
  §4) — yalnızca `/users`, `/settings`, `/organization/roles`,
  `/onboarding`, `/organization/settings` gibi az sayıda rotada ek bir
  kapı (`requireAdmin`) olarak KALMAYA devam ediyor.
- Bir normal admin bir kullanıcıyı **asla** `super_admin`'e
  yükseltemez: `organization_roles` tablosunda `super_admin` kodlu
  hiçbir satır yoktur (yalnızca 6 tenant rolü seed edilir) ve
  `users_super_admin_has_no_org_role` CHECK kısıtı DB seviyesinde
  bunu garanti eder.

### 1.2 Organizasyon rolü (`users.organization_role_id` → `organization_roles`)

Bu sprint'te eklenen **ince-taneli** eksen. Her organizasyon için
migration 0034 ile otomatik seed edilen 6 sistem rolü:

| Kod               | Anlamı                                              | Proje üyeliği |
|-------------------|------------------------------------------------------|---------------|
| `owner`           | Firma sahibi, tüm izinler, son owner korumalı        | Muaf (tümünü görür) |
| `admin`           | Tam yetkili yönetici                                  | Muaf (tümünü görür) |
| `legacy_user`     | Migration öncesi `kullanici` rolünün izin karşılığı  | Muaf (tümünü görür) |
| `project_manager` | Yalnızca atandığı projelerde operasyonel yönetim      | Gerekli |
| `finance`         | Yalnızca atandığı projelerin finansal verileri        | Gerekli |
| `field`           | Yalnızca atandığı projelerde saha operasyonu          | Gerekli |

`legacy_user`, **yeni bir kullanıcıya asla atanmaz** — yalnızca
migration'ın geriye dönük uyumluluk backfill'idir (mevcut `kullanici`
rolündeki kullanıcıların migration öncesi sahip olduğu erişimi
birebir korur). Web rol seçicisinde (`domain.TenantSelectableOrgRoles`)
ve `AuthorizationService.ListOrganizationRoles(..., includeLegacy=false)`
çağrılarında bilinçli olarak gösterilmez.

`domain.RoleBypassesProjectMembership(code)`, hangi rollerin proje
üyeliğinden muaf olduğunun **tek kaynağıdır** — bu karar başka hiçbir
yerde tekrarlanmaz.

## 2. İzin kayıt defteri (`permissions` tablosu)

İzin kodları `domain/authorization.go`'da Go sabitleri olarak
tanımlıdır (`domain.PermProjectsRead` gibi) ve dış temsilleri her
zaman küçük harfli, noktalı string'lerdir (`"projects.read"`).
Kod, migration 0034'ün gerçek router.go endpoint envanterinden
çıkarılmıştır — spekülatif/örnek isimler kullanılmamıştır.

Kategoriler: Projeler, Finans, Görevler, Operasyon, Proje Erişimi,
Teklifler, Metraj, Ürünler, Müşteriler, Personel, Puantaj, Firma
Yönetimi.

**Deny-by-default**: `role_permissions`'ta olmayan bir izin =
erişim yok. `AuthorizationService.SetRolePermissions`, `permissions`
tablosunda olmayan bir kod verilirse `domain.ErrUnknownPermission`
döner (ön-doğrulama); DB'nin `role_permissions.permission_code` FK
kısıtı zaten aynı şeyi zorunlu kılar (savunma derinliği).

## 3. Proje üyeliği (`project_users`)

`project_users`, **mevcut `project_members` tablosuyla
KARIŞTIRILMAMALIDIR**: `project_members` personel/puantaj roster'ıdır
(`employee_id`'ye bağlı, login hesabıyla ilgisi yok — "Personel/Ekip"
özelliği). `project_users`, `user_id`'ye bağlı bir ERİŞİM KONTROLÜ
kaydıdır (web'de "Proje Erişimi" ekranı).

- `UNIQUE(project_id, user_id)`: bir kullanıcı bir projeye yalnızca
  bir kez üye olabilir. `CreateProjectUser` sorgusu
  `ON CONFLICT (project_id, user_id) DO UPDATE SET project_role = ...`
  kullanır — tekrarlı ekleme yeni satır YARATMAZ, mevcut satırın
  `project_role`'ünü günceller (idempotent, eşzamanlı çift-tıklamaya
  karşı güvenli).
- `trg_project_users_check_org_consistency` trigger'ı, satırın
  `organization_id`'sinin hem projenin hem kullanıcının
  `organization_id`'siyle eşleştiğini DB seviyesinde zorunlu kılar —
  cross-tenant membership servis katmanı bir hata yapsa bile
  reddedilir.
- Proje rolü (`project_role`: `project_manager`/`member`/`viewer`),
  organizasyon rolünden **tamamen ayrı bir eksendir** — ikinci bir
  tam izin motoru DEĞİLDİR, yalnızca proje içi görünüm/etiket
  amaçlıdır.

## 4. İstek yetkilendirme akışı

```
RequireAuth → RequireTenant → RequireOnboarded → LoadAuthorization → RequirePermission(code)
                                                                    → RequireProjectPermission(code)
```

- **RequireAuth**: JWT doğrular, `role`/`userID`/`organizationID`'yi
  context'e koyar (DEĞİŞMEDİ).
- **RequireTenant**: tenant (firma kapsamlı) HER rota grubunda
  `requireAuth`'un hemen ardından gelir; `super_admin`'i ve org claim'i boş
  her oturumu `403 tenant_context_required` ile keser. `/auth/*` ve
  `/platform/*` almaz.
- **RequireOnboarded**: `must_change_password`/`onboarding_completed`
  gate'i. `super_admin` burada da reddedilir (eski "muaf" davranışı
  kaldırıldı).
- **LoadAuthorization**: `super_admin` için AuthzContext ÜRETMEZ, reddeder.
  Tenant kullanıcıları için rol kodu + TÜM izin kodlarını **istek başına
  bir kez** (2 hafif, indeksli sorgu) yükler ve `*service.AuthzContext`'i
  request context'ine koyar.
- **RequirePermission(code)**: context'teki `AuthzContext`'i okur
  (sorgu ATMAZ), `HasPermission(code)` kontrolü yapar. Eksikse
  `403 {"code":"permission_denied"}`.
- **RequireProjectPermission(code)**: `RequirePermission` + URL'nin
  `{id}` route param'ını (proje kimliği — TÜM proje alt-kaynak
  rotalarının ortak sözleşmesi) `AuthorizationService.CanAccessProject`
  ile doğrular. `owner`/`admin`/`legacy_user` bu kontrolden muaftır;
  diğerleri yalnızca `project_users`'ta üye iseler geçer (tek `EXISTS`
  sorgusu). Eksikse `403 {"code":"project_access_denied"}`.

Bu sayede TEK bir istek, kaç tane `RequirePermission`/
`RequireProjectPermission` kontrolünden geçerse geçsin, toplam
**2-3 sorgu** çalıştırır (rol+izin yükleme + gerekirse üyelik
kontrolü) — veri boyutundan BAĞIMSIZ, sabit.

## 5. Liste uçlarında üyelik filtrelemesi

`GET /projects`, membership-farkında filtrelemeyi **SQL/repository
seviyesinde** uygular (fetch-all-then-filter DEĞİL): `ListProjects`/
`CountProjects` sorguları `sqlc.narg('restrict_to_user_id')` alır —
`owner`/`admin`/`legacy_user` için handler bunu boş bırakır (tüm
projeler), diğer roller için kullanıcının kendi ID'sini geçirir;
sorgu `EXISTS (SELECT 1 FROM project_users pu WHERE pu.project_id =
p.id AND pu.user_id = ...)` ile filtreler.

## 6. Child-resource (görev/dosya/fotoğraf/masraf/ek iş) koruması

`{project}/{child}` şeklindeki HER rota, hem `organization_id` HEM
`project_id` ile sorgulanır — yalnızca ebeveyn seviyesinde (proje)
yetkilendirmeye güvenilmez. Aksi halde, AYNI organizasyon içinde
yetkili olunan bir proje URL'si + başka bir projenin çocuk kaynak
UUID'si ile IDOR (Insecure Direct Object Reference) mümkün olurdu.
Bu, migration 0034 öncesi GERÇEK, exploit edilebilir bir güvenlik
açığıydı (tasks/files/photos/payment-plan/collections/expenses/
invoices/subcontractors/subcontractor-payments/change-orders/project
members — ~20 servis metodu) ve bu sprint'te kapatılmıştır (bkz.
`internal/httpapi/middleware/require_permission_test.go` ve
`internal/service/project_*_test.go`'daki `cross_project_*_idor_blocked`
testleri).

## 7. Yeni bir izin ekleme

1. `domain/authorization.go`'da yeni `PermXxx` Go sabitini ekle.
2. `db/migrations/00XX_*.up.sql`'de (yeni migration, 0034'ü DEĞİŞTİRME)
   `INSERT INTO permissions (...)` ile kaydı ekle, ilgili varsayılan
   rollerin `role_permissions`'ına ekle.
3. `.down.sql`'de kaldır.
4. `router.go`'da ilgili rotayı `perm(domain.PermXxx)` veya
   `projPerm(domain.PermXxx)` ile sar.

## 8. Yeni bir korumalı rota ekleme

- Org-wide (proje ekseni yok) bir uç: `r.With(perm(domain.PermXxx)).Get(...)`.
- Proje alt-kaynağı (`/projects/{id}/...`) bir uç:
  `r.With(projPerm(domain.PermXxx)).Get(...)` — `{id}` route param'ı
  MUTLAKA projenin kimliği olmalı (middleware bunu sabit isimle okur).
- Yeni bir child-resource sorgusu yazıyorsan: `WHERE id = $1 AND
  organization_id = $2 AND project_id = $3` (bkz. §6) — yalnızca
  `organization_id` YETERLİ DEĞİLDİR.

## 9. PostgreSQL Row-Level Security (RLS) — fizibilite notu

Bu sprint kapsamında RLS migration'ı **uygulanmamıştır** (spec'in
açık isteği). Uygulama seviyesi tenant scoping (her sorguda
`organization_id`/`project_id` WHERE koşulu) birincil mekanizma
olarak kalmaya devam eder.

Kısa değerlendirme: RLS, `SET app.current_organization_id` gibi bir
oturum değişkeniyle POLICY tanımları gerektirir; pgx havuzunda her
istek için bağlantı bazlı `SET`/`RESET` (veya `SET LOCAL` + transaction
zorunluluğu) ek karmaşıklık getirir, ve mevcut kod tabanının GENİŞ
kısmı zaten repository/servis katmanında doğru WHERE koşullarını
uyguluyor (bu sprint'in IDOR denetimi, eksik olan birkaç noktayı
tam olarak bunun için kapattı). RLS, gelecekte "uygulama kodu
hatası son savunma hattı olmasın" ilkesiyle EK bir katman olarak
değerlendirilebilir, ama bu sprint'in kapsamı/aciliyeti bunu
gerektirmiyor.

## 10. Test gereksinimleri

Yeni bir izin/rota eklerken:
- Real-DB entegrasyon testi (`internal/httpapi/middleware/
  require_permission_test.go` deseninde) — izin verilen/verilmeyen
  rol + üye/üye-olmayan proje kombinasyonu.
- `go test ./...`, `go test -race ./...`, `go vet ./...`, `gofmt -l .`
  temiz olmalı.
- Migration değişikliği varsa up→down→up gerçek dev DB'ye karşı
  test edilmeli.
