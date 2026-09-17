# ARVEND Backend — Auth/Role/User Model (exact, as of current `main`)

Repo: `/Users/tahaeryetisozen/Documents/GitHub/x-api/ARVEND/backend` (read-only survey, nothing modified).

## 1. `User` struct fields and DB columns

`internal/domain/user.go:8-30`
```go
type Role string

const (
    RoleAdmin     Role = "admin"
    RoleKullanici Role = "kullanici"
)

func (r Role) Valid() bool {
    return r == RoleAdmin || r == RoleKullanici
}

type User struct {
    ID             string
    OrganizationID string
    Username       string
    PasswordHash   string
    FullName       string
    Role           Role
    IsActive       bool
    CreatedAt      time.Time
    UpdatedAt      time.Time
    LastLoginAt    *time.Time
}
```

DB columns, `db/migrations/0001_create_users.up.sql:3-14` (+ org column added later):
```sql
CREATE TABLE users (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    username       varchar(50) NOT NULL UNIQUE,
    password_hash  varchar(255) NOT NULL,
    full_name      varchar(150) NOT NULL,
    role           varchar(20) NOT NULL DEFAULT 'kullanici'
                   CHECK (role IN ('admin', 'kullanici')),
    is_active      boolean NOT NULL DEFAULT true,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    last_login_at  timestamptz
);
```
`db/migrations/0010_add_organization_id_to_users.up.sql:1-6`:
```sql
ALTER TABLE users ADD COLUMN organization_id uuid REFERENCES organizations(id);
UPDATE users SET organization_id = '00000000-0000-0000-0000-000000000001';
ALTER TABLE users ALTER COLUMN organization_id SET NOT NULL;
CREATE INDEX idx_users_organization_id ON users (organization_id);
```
`username` is `UNIQUE` **globally**, not per-org (no composite unique constraint was ever added — grep of all migrations for `ALTER TABLE users` finds only the one org-id migration above; no other `users` schema change exists). Mapping DB row → domain struct: `internal/repository/pool.go:52-69` (`ToDomainUser`).

## 2. `Role` type and `RequireRole` enforcement

Only two roles exist (`RoleAdmin = "admin"`, `RoleKullanici = "kullanici"`), enforced at the DB layer via a `CHECK` constraint (`0001_create_users.up.sql:8-9`) as well as `Role.Valid()` in Go.

`RequireRole` supports **exactly one role**, not "one of several":

`internal/httpapi/middleware/require_role.go:11-22`
```go
func RequireRole(role domain.Role) func(http.Handler) http.Handler {
    return func(next http.Handler) http.Handler {
        return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
            got, ok := RoleFromContext(r.Context())
            if !ok || got != role {
                http.Error(w, `{"error":"bu işlem için yetkiniz yok"}`, http.StatusForbidden)
                return
            }
            next.ServeHTTP(w, r)
        })
    }
}
```
It's a single `!=` comparison — there is no variadic/`...Role` form anywhere in the codebase. Every call site passes exactly one role: `router.go:49` `requireAdmin := appmw.RequireRole(domain.RoleAdmin)`. Adding a Super Admin role that should also pass `requireAdmin` checks would need either (a) a new middleware, or (b) changing this function's signature — it cannot today express "admin OR super_admin" without modification.

## 3. JWT claims structure and `ParseAccessToken`

`internal/auth/jwt.go:21-26`
```go
type AccessClaims struct {
    UserID         string      `json:"uid"`
    Role           domain.Role `json:"role"`
    OrganizationID string      `json:"org"`
    jwt.RegisteredClaims
}
```
Exactly three custom fields are embedded: user id (`uid`), role (`role`), organization id (`org`) — nothing else (no permissions array, no session id, no token version). Plus the standard `jwt.RegisteredClaims`, but only `IssuedAt`/`ExpiresAt` are actually set (`jwt.go:42-45`); no `Issuer`, `Subject`, `Audience`, `NotBefore`, or `ID` are populated.

Issuance: `internal/auth/jwt.go:37-49` — HS256, signed with a single shared secret (`j.secret []byte`), TTL fixed per issuer instance (`cfg.AccessTTL`).

`ParseAccessToken`: `internal/auth/jwt.go:51-63`
```go
func (j *JWTIssuer) ParseAccessToken(raw string) (*AccessClaims, error) {
    claims := &AccessClaims{}
    token, err := jwt.ParseWithClaims(raw, claims, func(t *jwt.Token) (interface{}, error) {
        if _, ok := t.Method.(*jwt.SigningMethodHMAC); !ok {
            return nil, ErrInvalidAccessToken
        }
        return j.secret, nil
    })
    if err != nil || !token.Valid {
        return nil, ErrInvalidAccessToken
    }
    return claims, nil
}
```
It only validates signature/expiry — it does not hit the DB, so a role embedded in an already-issued token stays valid (stale) until that access token expires. `middleware/auth.go:34-42` copies `claims.UserID`, `claims.Role`, `claims.OrganizationID` into `context.Context` via `ctxUserID`/`ctxRole`/`ctxOrganizationID`; nothing else is exposed to handlers from the token. The comment at `jwt.go:17-20` explicitly notes deactivation is only caught at refresh time, not on every request — a design fact relevant to any "revoke super admin immediately" requirement.

## 4. `UserService.Create` signature and callers

`internal/service/user_service.go:81-113`
```go
func (s *UserService) Create(ctx context.Context, organizationID, username, password, fullName string, role domain.Role) (*domain.User, error) {
    orgID, err := repository.StringToUUID(organizationID)
    ...
    if !role.Valid() {
        role = domain.RoleKullanici
    }
    hash, err := auth.HashPassword(password)
    ...
    row, err := s.q.CreateUser(ctx, sqlc.CreateUserParams{
        OrganizationID: orgID,
        Username:       username,
        PasswordHash:   hash,
        FullName:       strings.TrimSpace(fullName),
        Role:           string(role),
    })
    ...
}
```
Important: **it silently downgrades any invalid `Role` value to `RoleKullanici`** (line 90-92) rather than erroring — so a hypothetical `super_admin` string passed here today would be silently coerced to `kullanici` unless `Role.Valid()` is updated to recognize it. `organizationID` is a required, non-optional parameter — `Create` always scopes the new user to one org; there is no "org-less/platform" user creation path in this function.

Two programmatic callers, both requiring an `organization_id` up front (confirms org-scoping is baked into every user-creation path):

- **`cmd/api/main.go:107-128`** — `seedAdmin`, runs on every API boot, creates the first admin only if `CountUsers(DefaultOrganizationID) == 0`:
  ```go
  _, err = userSvc.Create(ctx, domain.DefaultOrganizationID, cfg.SeedAdminUser, cfg.SeedAdminPass, cfg.SeedAdminName, domain.RoleAdmin)
  ```
- **`cmd/seed-organization/main.go:29-90`** — one-off CLI, does *not* go through `UserService` at all; it calls `sqlc.Queries.CreateUser` directly inside a hand-rolled transaction (`tx := pool.Begin`; `sqlc.New(tx)`) so org creation + first admin creation are atomic:
  ```go
  org, err := q.CreateOrganization(ctx, sqlc.CreateOrganizationParams{Name: *name, Slug: *slug})
  ...
  user, err := q.CreateUser(ctx, sqlc.CreateUserParams{OrganizationID: org.ID, Username: *adminUsername, PasswordHash: hash, FullName: *adminFullName, Role: string(domain.RoleAdmin)})
  ```
  This is the file's own doc comment: "yeni bir organizasyon ... ve ilk admin kullanıcısını atomik bir transaction'da oluşturur ... TEK SEFERLİK bir araçtır" (lines 1-6) — i.e. this is the established convention for bootstrapping an org + its first privileged user, and would be the natural template for a platform-level super-admin seeding tool.

`domain.DefaultOrganizationID = "00000000-0000-0000-0000-000000000001"` (`internal/domain/organization.go:14-17`) is the fixed seed org from `0009_create_organizations.up.sql:16-18` (`INSERT INTO organizations (id, name, slug) VALUES ('00000000-0000-0000-0000-000000000001', 'Arvend Yapı', 'arvend-yapi')`).

## 5. Password hashing; "temporary password" / "must change password" concept

Hashing: `internal/auth/password.go`
```go
const bcryptCost = 12
func HashPassword(plain string) (string, error) { ... bcrypt.GenerateFromPassword([]byte(plain), bcryptCost) ... }
func CheckPassword(hash, plain string) bool { return bcrypt.CompareHashAndPassword([]byte(hash), []byte(plain)) == nil }
```
Used by: `UserService.Create` (`user_service.go:93`), `UserService.setPassword` (`user_service.go:182`, shared by both `ChangeOwnPassword` and `AdminResetPassword`), and `AuthService.Login` (`auth_service.go:42`).

`grep -rni "must_change|temporary|force_password|temp_password|password_reset"` across all `.go` and `.sql` files (excluding vendor) returned **zero matches**. There is no `must_change_password`, `temporary`, `force_password_reset`, or password-expiry column/flag anywhere in the schema or code. `AdminResetPassword` (`user_service.go:164-172`) simply overwrites `password_hash` via `setPassword` (min length 8, `user_service.go:179-181`) — the user is not flagged to change it on next login. Any "must change password on first login" requirement for a new Super Admin would be a wholly new concept, not an existing convention to reuse.

## 6. Single-org vs multi-org membership

`organization_id` is a **direct, required, non-nullable column on `users`** (`0010_add_organization_id_to_users.up.sql:3` — `ALTER COLUMN organization_id SET NOT NULL`), with a plain FK to `organizations.id` (no `ON DELETE` clause specified, so default `NO ACTION`). There is **no memberships/join table** — grep confirms `internal/repository/queries/users.sql` has no `user_organizations`/`memberships` query, and no such migration exists. Every user query is single-org-scoped by construction: `GetUserByIDInOrg`, `ListUsers`, `CountUsers`, `UpdateUser`, `UpdateUserPassword`, `DeactivateUser` all filter/require `organization_id = $N` (`internal/repository/queries/users.sql:9-40`). `GetUserByID` and `GetUserByUsername` (lines 6-7, 12-13) are the only org-unscoped lookups, used for login (`auth_service.go:35`) and refresh (`auth_service.go:71`) before the org id from the row itself is used. **A user today belongs to exactly one organization.** A platform Super Admin that must operate across all orgs cannot be expressed with the current `organization_id NOT NULL` column/model without either (a) a schema change (nullable org id meaning "all orgs", or a separate flag), or (b) treating it as an orthogonal concept outside the `users.organization_id` scoping that every existing query enforces.

## 7. Cookie/session mechanics

Confirmed unchanged — `internal/httpapi/handler/auth_handler.go:125-136`:
```go
func (h *AuthHandler) cookie(name, value string, ttl time.Duration) *http.Cookie {
    return &http.Cookie{
        Name:     name,
        Value:    value,
        Path:     "/",
        Domain:   h.cookieDomain,
        MaxAge:   int(ttl.Seconds()),
        HttpOnly: true,
        Secure:   h.cookieSecure,
        SameSite: http.SameSiteStrictMode,
    }
}
```
Two cookies, `access_token` and `refresh_token` (`setSessionCookies`, lines 115-118), both `HttpOnly: true`, `SameSite: Strict`. `Secure` is config-driven (`cookieSecure` from `cfg.CookieSecure`), not hardcoded. Refresh tokens are opaque 32-byte random values, only the SHA-256 hash is stored server-side (`internal/auth/jwt.go:65-81`, table `refresh_tokens` — `db/migrations/0002_create_refresh_tokens.up.sql`), and are rotated on every `/auth/refresh` call (`auth_service.go:61-84`, `RevokeRefreshToken` then reissue).

## Route groups exactly as registered

`internal/httpapi/router.go:58-79`
```go
r.Route("/auth", func(r chi.Router) {
    r.Post("/login", d.Auth.Login)
    r.Post("/refresh", d.Auth.Refresh)
    r.Post("/logout", d.Auth.Logout)
    r.With(requireAuth).Get("/me", d.Auth.Me)
})

r.Route("/users", func(r chi.Router) {
    r.Use(requireAuth)
    r.Patch("/me/password", d.Users.ChangeOwnPassword)

    r.Group(func(r chi.Router) {
        r.Use(requireAdmin)
        r.Get("/", d.Users.List)
        r.Post("/", d.Users.Create)
        r.Get("/{id}", d.Users.Get)
        r.Put("/{id}", d.Users.Update)
        r.Patch("/{id}/password", d.Users.AdminResetPassword)
        r.Delete("/{id}", d.Users.Deactivate)
    })
})
```
where `requireAuth := appmw.RequireAuth(d.JWT)` and `requireAdmin := appmw.RequireRole(domain.RoleAdmin)` (`router.go:48-49`). All `/users` mutation/listing endpoints except self-password-change require the single `admin` role — nothing today distinguishes an org admin from a hypothetical platform super admin; both would collide on `RequireRole(domain.RoleAdmin)` unless the role model and middleware are extended.

## Summary of what a Super Admin feature would need to touch (facts only, no proposal)

- `domain.Role` enum + `Role.Valid()` (`internal/domain/user.go:8-17`) — currently exactly 2 values, closed set, backed by a Postgres `CHECK` constraint that would need a migration to extend.
- `RequireRole` (`middleware/require_role.go`) — currently single-role equality check; router only ever instantiates it once as `requireAdmin`.
- `AccessClaims` (`auth/jwt.go:21-26`) — carries only `uid`/`role`/`org`; a platform-wide super admin concept that must act outside one `org` is not representable in the current claims shape without a change (e.g., a nullable/sentinel org, or a new claim).
- `users.organization_id` — `NOT NULL` FK, single-org membership, no memberships table exists anywhere in the migrations.
- No "must change password"/"temporary password" concept exists anywhere today (confirmed by full-repo grep, zero hits) — this would be new, not reused.
- The established convention for bootstrapping a new privileged user tied to org creation is `cmd/seed-organization/main.go` (direct `sqlc` calls in a transaction); the established convention for bootstrapping a privileged user in an existing org via the service layer is `seedAdmin` in `cmd/api/main.go:107-128` calling `UserService.Create`.