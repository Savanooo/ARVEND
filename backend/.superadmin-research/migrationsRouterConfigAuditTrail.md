## ARVEND Backend — Current State Report (read-only investigation)

### 1. Migrations
Highest migration is **0029** (confirmed via `ls db/migrations/ | sort` — no later commits added more). Sequence: 0001 → 0029, no gaps, each has `.up.sql`/`.down.sql`. New migrations should start at **0030**.

**0028_create_calc_module** (up): creates `calc_groups`, `calc_categories`, `calc_recipe_items`. Conventions observed:
- `id uuid PRIMARY KEY DEFAULT gen_random_uuid()`
- `organization_id uuid NOT NULL REFERENCES organizations(id)` on every tenant-scoped table (multi-tenant isolation pattern)
- Heavy Turkish-language comment blocks above each table explaining rationale (often referencing `docs/*.md` analysis docs and prior "BYZ" legacy system)
- `created_at timestamptz NOT NULL DEFAULT now()`, `updated_at timestamptz NOT NULL DEFAULT now()` + a `CREATE TRIGGER ..._set_updated_at BEFORE UPDATE ... EXECUTE FUNCTION set_updated_at();` per table
- Indexes named `idx_<table>_<cols>`, e.g. `CREATE INDEX idx_calc_groups_org ON calc_groups (organization_id, is_active, sort_order);`
- `UNIQUE (organization_id, slug)` style composite tenant-scoped uniqueness
- FK deletion behavior is deliberate and commented (`ON DELETE SET NULL` vs. no-action/RESTRICT), with inline rationale for each choice
- down.sql is simply reverse-order `DROP TABLE IF EXISTS ...;`

**0029_add_calc_snapshot_to_offer_items** (up): `ALTER TABLE offer_revision_items ADD COLUMN ...` (unit, section_label, calc_category_id FK with `ON DELETE SET NULL`, calc_snapshot jsonb) + one partial index (`WHERE calc_category_id IS NOT NULL`). down.sql drops the index then drops columns in reverse order with `IF EXISTS`.

### 2. router.go (full file, 280 lines, `internal/httpapi/router.go`)
```go
requireAuth := appmw.RequireAuth(d.JWT)
requireAdmin := appmw.RequireRole(domain.RoleAdmin)
```
Top-level: `r.Get("/healthz", ...)` (no auth, outside `/api/v1`), then everything else under `r.Route("/api/v1", func(r chi.Router) {...})`. Route groups and their auth wiring:

| Group | Auth wiring |
|---|---|
| `/auth` | login/refresh/logout public; `/me` uses `r.With(requireAuth)` |
| `/users` | `r.Use(requireAuth)` on whole group; `PATCH /me/password` open to any authed user; rest (`List/Create/Get/Update/AdminResetPassword/Deactivate`) in a nested `r.Group(func(r){ r.Use(requireAdmin) ...})` |
| `/products` | `requireAuth` on group; GET (list/get/price-history) open to any authed user; POST/PUT/DELETE nested under `requireAdmin` group |
| `/calculations` | `requireAuth` on group; GET (groups/categories/recipe-items) + `POST /run` open to any authed user; all mutating group/category/recipe-item CRUD nested under `requireAdmin` group |
| `/offers` | `requireAuth` only, **no admin split** — full CRUD + revise/status/share-links/events/email-logs/delete all just need auth |
| `/projects` | `requireAuth` only, **no admin split** — same pattern, largest group (finance, operations, files, photos, notes, change-orders, all just `requireAuth`) |
| `/customers` | `requireAuth` only, no admin split |
| `/employees` | `requireAuth` on group; GET (list/get) open; POST/PUT/DELETE nested under `requireAdmin` |
| `/attendance` | `requireAuth` only, no admin split |
| `/settings` | `r.Use(requireAuth, requireAdmin)` on whole group (SMTP settings) |
| `/public/offers/{token}` | **no auth at all** — token is the security boundary |
| `/public/change-orders/{token}` | **no auth at all** — same pattern |

Two structural patterns for adding new groups: (a) `requireAuth` on the whole `r.Route(...)`, with a nested `r.Group(func(r chi.Router){ r.Use(requireAdmin); ... })` for admin-only subset (used by `/users`, `/products`, `/calculations`, `/employees`); (b) `requireAuth` on the whole group with no admin split (used by `/offers`, `/projects`, `/customers`, `/attendance`). For `/platform/*` (likely admin-heavy) pattern (a) fits; for `/onboarding/*` depends on whether it's pre-auth (token-based, like `/public/*`) or post-auth.

`Deps` struct (lines 18-33) is the wiring point — one field per handler plus `JWT` and `CORSOrigins`; new handlers get added here and threaded through `NewRouter`.

### 3. config.go (full file, `internal/config/config.go`)
Confirmed current state already includes `ListenAddr` (`LISTEN_ADDR`, defaults to `":"+PORT`) and `CORSOrigins` (`CORS_ORIGINS`, CSV via `splitCSV`, defaults to `http://localhost:3000`) as described. Full `Config` struct: `Port, ListenAddr, CORSOrigins, DatabaseURL, JWTSecret, AccessTTL, RefreshTTL, CookieDomain, CookieSecure, SeedAdminUser, SeedAdminPass, SeedAdminName, SettingsEncryptionKey, FrontendURL, StorageRoot`. Pattern for new config: add a field to `Config`, read it in `Load()` via `getEnv(key, default)`.

### 4. main.go (full file, `backend/cmd/api/main.go`)
Wiring order: `config.Load()` → validate required env (`DB_URL`, `JWT_SECRET`, `SETTINGS_ENCRYPTION_KEY`, fatal if missing) → `crypto.NewSecretBox` → pg pool + ping → `storage.NewLocalStore` → `sqlc.New(pool)` → construct each `service.New*Service(q, ...)` → `seedAdmin(...)` → `auth.NewJWTIssuer` + `service.NewAuthService` → `httpapi.NewRouter(httpapi.Deps{...})` with one line per handler wrapping its service → `http.Server{ReadHeaderTimeout: 10s, ReadTimeout/WriteTimeout: 5m, IdleTimeout: 120s}` → `srv.ListenAndServe()`. New services follow the exact same `svc := service.NewXService(q, ...)` → `handler.NewXHandler(svc)` → add to `Deps{}` literal pattern.

### 5. Audit infrastructure — confirmed pattern to reuse
**Two existing, near-identical audit/event tables already exist** — a new platform-level audit trail should follow the same shape rather than invent a new one:

- **`offer_events`** (migration 0020): `id, organization_id, offer_id (FK CASCADE), revision_id (FK SET NULL, nullable), event_type varchar(40), user_id (FK SET NULL, nullable — null for public/customer events), metadata jsonb DEFAULT '{}', ip_address varchar(45), user_agent varchar(500), created_at`. Immutability is enforced with a DB trigger (`offer_events_prevent_mutation()` raises exception `BEFORE UPDATE`); no delete trigger — deletion only happens via `ON DELETE CASCADE` from the parent.
- **`project_events`** (migration 0024): same core shape but slimmer — `id, organization_id, project_id (FK CASCADE), event_type varchar(40), user_id (FK SET NULL, nullable), metadata jsonb DEFAULT '{}', created_at` (no ip_address/user_agent columns), same immutable-via-trigger pattern (`project_events_prevent_mutation()`).

No generic/shared `audit_log` table exists — each domain has its own `<domain>_events` table with `organization_id` scoping, `event_type varchar(40)`, `metadata jsonb`, nullable `user_id`, immutability trigger, and an index `idx_<table>_<entity>_id (<entity>_id, created_at DESC)` plus `idx_<table>_organization_id`. A new platform-level audit table (e.g. `platform_events` or `audit_log`) should copy this exact shape (own table, own FK to whatever entity it's scoped to, own immutability trigger) rather than reuse `offer_events`/`project_events` directly.

### 6. Go module / UUID
- Module path: **`github.com/Savanooo/ARVEND/backend`**
- Go version: **`go 1.26.2`** (per `go.mod`)
- `github.com/google/uuid v1.6.0` is present in `go.mod` and **is** the established UUID package — actively used in `internal/service/project_operations_service.go:693` (`objectID := uuid.NewString()`). Only 1 file currently imports it, but it's the precedent to follow for new Go code needing UUID generation (e.g. `uuid.NewString()` or `uuid.New()`).
- Note: every entry in `go.mod`'s single `require (...)` block, including directly-imported packages like `chi`, `pgx`, `google/uuid`, `shopspring/decimal`, is marked `// indirect` — this appears to be a pre-existing quirk (module not run through a clean `go mod tidy`), not something to worry about when adding new code, but a subsequent `go mod tidy` elsewhere would likely rewrite these markers.