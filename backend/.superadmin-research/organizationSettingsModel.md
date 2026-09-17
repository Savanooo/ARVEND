I now have the complete, verified picture. Report follows.

## 1. Exact current `organizations` table schema

From `backend/db/migrations/0009_create_organizations.up.sql` (unaltered by any later migration — confirmed by grepping every migration file for `organizations`; all later hits are either `organization_id` FK columns added to *other* tables, or table-creation migrations that reference `organizations(id)` as a FK target):

```sql
CREATE TABLE organizations (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name       varchar(200) NOT NULL,
    slug       varchar(100) NOT NULL UNIQUE,
    is_active  boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER organizations_set_updated_at BEFORE UPDATE ON organizations
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
```

6 columns total, all currently in use — `id, name, slug, is_active, created_at, updated_at`. No billing/business fields (no address, tax number, IBAN, phone, plan/tier, etc.) exist on this table today. `down.sql` is a plain `DROP TABLE IF EXISTS organizations;`.

The domain struct (`internal/domain/organization.go`) mirrors this exactly — `ID, Name, Slug, IsActive, CreatedAt, UpdatedAt` — plus the `DefaultOrganizationID` constant (point 3 below).

## 2. `OrganizationService` — exact existing methods

File exists at `internal/service/organization_service.go`, 3 methods, all read/create only, no update/deactivate/delete:

- `Create(ctx, name, slug string) (*domain.Organization, error)` — trims/validates name+slug non-empty, calls `sqlc.CreateOrganization`, maps `23505` (unique violation on slug) to a friendly Turkish error. **This is already exactly "create organization" semantics** — it does not provision anything else (no admin user, no settings row, no defaults).
- `Get(ctx, id string) (*domain.Organization, error)`
- `List(ctx) ([]domain.Organization, error)`

**Confirmed: no registered HTTP route.** `internal/httpapi/router.go`'s `Deps` struct has no `Organizations` field at all (fields are `JWT, Auth, Users, Products, Offers, Projects, Customers, Employees, Attendance, Settings, PublicOffer, PublicChangeOrder, Calc, CORSOrigins`), and `cmd/api/main.go` never calls `service.NewOrganizationService(...)` in production wiring. The only callers of `NewOrganizationService` in the whole repo are test files (`internal/service/*_test.go`, 8 of them) that construct it purely to seed a second org for tenant-isolation tests. There is no `organization_handler.go` in `internal/httpapi/handler/` at all.

The actual "create org + provision first admin" flow today lives entirely in `cmd/seed-organization/main.go`, a standalone one-shot CLI (explicitly commented as "TEK SEFERLİK bir araçtır -- kalıcı uygulama kodu değildir... self-servis bir 'firma kaydı' akışı bu pass'te yok"). It does, in one pgx transaction: `sqlc.CreateOrganization` → `auth.HashPassword` → `sqlc.CreateUser` with `RoleAdmin` → commit. This is the closest existing precedent for "create + provision" and is a reasonable template for a new Super Admin HTTP endpoint, but it's Go-CLI code, not service/handler code, and bypasses `OrganizationService.Create` (calls sqlc directly).

## 3. `DefaultOrganizationID` — hardcoded usage

Constant defined once: `internal/domain/organization.go:17` → `const DefaultOrganizationID = "00000000-0000-0000-0000-000000000001"`, seeded as `'Arvend Yapı'` / slug `arvend-yapi` in the same 0009 migration's `INSERT`.

Grepped across the **entire backend module** for both the symbol and the literal UUID; only 4 real hits, all in one place:
- `cmd/api/main.go:108` — `seedAdmin()` resolves `orgID` from `domain.DefaultOrganizationID` to count existing users.
- `cmd/api/main.go:123` — same function creates the seed admin user under this org if the org has zero users.
- `internal/domain/organization.go:14,17` — the constant's own declaration/doc comment.
- (A fifth, non-code hit: `cmd/import-calc-recipes/main.go:30` is only a `--org` usage example in a comment.)

No handler, service, or migration hardcodes this UUID elsewhere — it is used exactly once, only for first-boot admin seeding. It is safe as long as any Super-Admin org-management work doesn't touch/delete this row or change `seedAdmin`'s reliance on it.

## 4. Existing per-organization settings table pattern

Exactly one precedent exists: `smtp_settings`, originally created singleton (`0007_create_smtp_settings.up.sql`, `id smallint PRIMARY KEY DEFAULT 1 CHECK (id=1)`), then converted to per-org in `0012_add_organization_id_to_offers_and_smtp.up.sql`:

```sql
ALTER TABLE smtp_settings ADD COLUMN organization_id uuid;
UPDATE smtp_settings SET organization_id = '00000000-0000-0000-0000-000000000001' WHERE id = 1;
ALTER TABLE smtp_settings DROP CONSTRAINT smtp_settings_pkey;
ALTER TABLE smtp_settings ALTER COLUMN organization_id SET NOT NULL;
ALTER TABLE smtp_settings ADD CONSTRAINT smtp_settings_pkey PRIMARY KEY (organization_id);
ALTER TABLE smtp_settings ADD CONSTRAINT smtp_settings_organization_id_fkey
    FOREIGN KEY (organization_id) REFERENCES organizations(id);
ALTER TABLE smtp_settings DROP COLUMN id;
```

Resulting shape: **`organization_id` IS the primary key** (one settings row per org, 1:1, no separate surrogate `id`). Query layer (`internal/repository/queries/settings.sql`) is get-by-org + a single `UpsertSmtpSettings ... ON CONFLICT (organization_id) DO UPDATE` — no separate insert/update paths. Service (`SettingsService`) returns a zero-value `domain.SmtpSettings{OrganizationID: ...}` when `pgx.ErrNoRows`, i.e. "unconfigured" is represented by row-absence, not a nullable-flag row. Handler exposes it at `GET/PUT /settings/smtp` (+ `POST /settings/smtp/test`), org resolved from JWT context via `middleware.OrganizationIDFromContext`, never from the request body/URL. **A new "organization business/billing settings" table (IBAN etc.) should follow this exact pattern**: `organization_id uuid PRIMARY KEY REFERENCES organizations(id)`, one upsert query, service returns empty struct on no-rows rather than erroring.

## 5. SMTP settings encryption pattern (for IBAN-style fields)

`internal/platform/crypto/secretbox.go` — full public API, verbatim:

```go
type SecretBox struct{ gcm cipher.AEAD }

func NewSecretBox(base64Key string) (*SecretBox, error)
func (s *SecretBox) Encrypt(plaintext string) (string, error)
func (s *SecretBox) Decrypt(encoded string) (string, error)
```

Mechanics: AES-256-GCM. Key comes from `.env` `SETTINGS_ENCRYPTION_KEY`, must be base64-decodable to exactly 32 bytes (`NewSecretBox` errors otherwise). `Encrypt` generates a random `gcm.NonceSize()` nonce, seals with `nonce` as both the nonce and prefix (`Seal(nonce, nonce, plaintext, nil)`), base64-encodes `nonce||ciphertext` as one string, no AAD. `Decrypt("")` returns `("", nil)` (empty = "not set", not an error); otherwise base64-decodes, splits nonce/ciphertext, `gcm.Open`.

Usage convention (from `settings_service.go`): the encrypted column is named `<field>_enc text` (e.g. `password_enc`), stored via `s.box.Encrypt(...)` only when a non-nil/non-empty new value is supplied — a `nil` pointer in the update input means "keep existing encrypted value" (re-fetch and reuse `existing.PasswordEnc` rather than re-encrypting). The domain struct carries both a plaintext field (`Password string`, decrypted only server-side, doc-commented "never written to any API response") and a boolean presence flag (`PasswordSet bool`, `row.PasswordEnc != ""`) that IS safe to return over HTTP. One shared `*crypto.SecretBox` instance is constructed once in `cmd/api/main.go` from `cfg.SettingsEncryptionKey` and injected into `SettingsService` — the same instance/key would be reused for a new organization-settings service (no per-field or per-table keys). This same `_enc` column + present-flag + nil-means-unchanged convention is the one to replicate for IBAN/other sensitive organization fields.