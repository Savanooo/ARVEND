I now have everything needed. Here is the exact, verified API contract.

---

# ARVEND Backend — Auth API Contract (verified against source)

All bodies are `application/json; charset=utf-8`. All JSON request decoding uses `json.NewDecoder(...).DisallowUnknownFields()` (`internal/platform/httpjson/httpjson.go:26-31`), so **any unknown field in a request body causes a 400** — the mobile client must send exactly the documented fields, no extras.

## Auth model: cookie-based, NOT bearer-token

There is no token in any JSON response body. Login/refresh set two httpOnly cookies; the client never sees the raw tokens as JSON. A pure mobile HTTP client should use a cookie jar and send cookies exactly as received (no Authorization header is read anywhere in this codebase — confirmed by grep, none of the handlers/middleware reference an `Authorization` header).

### Cookies set on login/refresh (`auth_handler.go:125-136`)
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
Two cookies are set together on both login and refresh (`setSessionCookies`, `auth_handler.go:115-118`):
- `access_token` — MaxAge = `accessTTL.Seconds()`
- `refresh_token` — MaxAge = `refreshTTL.Seconds()`

Values from `config.go` (`Load()`, lines 50-66) as wired in `cmd/api/main.go:65-70`:
- `AccessTTL` = **15 minutes**, hardcoded in config.go (not env-configurable): `AccessTTL: 15 * time.Minute`
- `RefreshTTL` = **30 days**, hardcoded: `RefreshTTL: 30 * 24 * time.Hour`
- `Domain` = env `COOKIE_DOMAIN`, default `""` (empty string — host-only cookie)
- `Secure` = env `COOKIE_SECURE`, **default `false`** (`getEnv("COOKIE_SECURE", "false") == "true"`) — confirmed current default post the recent env changes
- `SameSite` = `http.SameSiteStrictMode` — **Strict**, not Lax/None. Note for mobile: this only matters for a WebView/browser-based client; a native HTTP client with a cookie jar is unaffected by SameSite (that's a browser-enforced attribute), but if the Flutter app uses an in-app WebView pointed at a web frontend, cross-site navigation won't carry the cookie under Strict.

Logout clears both cookies by re-setting them with `MaxAge = int((-time.Hour).Seconds())` (negative → delete), same Domain/Path/Secure/SameSite/HttpOnly (`clearSessionCookies`, `auth_handler.go:120-123`).

CORS (`router.go:41-46`): `AllowCredentials: true`, allowed origins = env `CORS_ORIGINS` (comma-split), default `["http://localhost:3000"]`. Methods allowed: GET, POST, PUT, PATCH, DELETE. Allowed headers: only `Content-Type` (no custom `Authorization`/other headers are CORS-allowed). This is browser-CORS only; irrelevant to a native mobile HTTP client but relevant if the Flutter app runs as Flutter Web.

`LISTEN_ADDR` (config.go:52): defaults to `":"+PORT` (PORT defaults to `8080`) if `LISTEN_ADDR` env unset.

---

## 1. POST /api/v1/auth/login

**Route**: `router.go:60` — `r.Post("/login", d.Auth.Login)`, inside `r.Route("/auth", ...)` under `/api/v1`. Full path: `/api/v1/auth/login`.
**Auth requirement**: none (registered before `requireAuth` is applied to this group; `requireAuth` is only `.With()`-attached to `/me`, line 63).

### Request body — `loginRequest` (`auth_handler.go:26-29`)
```go
type loginRequest struct {
	Username string `json:"username"`
	Password string `json:"password"`
}
```
- `username`: string, **required** (no pointer/omitempty; empty string is accepted by the decoder itself but will fail credential lookup)
- `password`: string, **required**

### Success response — `200 OK`, body `userResponse` (`auth_handler.go:31-37`)
```go
type userResponse struct {
	ID       string      `json:"id"`
	Username string      `json:"username"`
	FullName string      `json:"full_name"`
	Role     domain.Role `json:"role"`
	IsActive bool        `json:"is_active"`
}
```
- `id`: string (UUID as string)
- `username`: string
- `full_name`: string
- `role`: string enum — `domain.Role` is `type Role string` with exactly two values (`domain/user.go:8-17`): `"admin"` or `"kullanici"`. No other values exist anywhere in the domain package.
- `is_active`: bool

None of these fields are pointers/omitempty — all always present. No tokens appear in this body; they only arrive as `Set-Cookie` headers (see above).

### Error responses
Handler dispatch, `writeAuthError` (`auth_handler.go:102-113`):

| Condition | Status | Body |
|---|---|---|
| Malformed JSON body | 400 | `{"error":"geçersiz istek gövdesi"}` |
| Unknown username / wrong password (`domain.ErrInvalidCredentials`) | 401 | `{"error":"kullanıcı adı veya şifre hatalı"}` |
| User exists but `is_active = false` (`domain.ErrInactiveUser`) | 403 | `{"error":"kullanıcı pasif durumda"}` |
| Any other/unexpected service error | 500 | `{"error":"beklenmeyen bir hata oluştu"}` |

All error bodies use `httpjson.Error` → `httpjson.Write` → `{"error": "<message>"}` (`httpjson.go:22-24`), status set via `w.WriteHeader(status)`.

Service logic (`auth_service.go:34-56`, `Login`): looks up by username; `pgx.ErrNoRows` → `ErrInvalidCredentials`; bad password hash compare → `ErrInvalidCredentials`; `!IsActive` → `ErrInactiveUser`; otherwise issues session and calls `TouchLastLogin` (fire-and-forget, error ignored).

---

## 2. POST /api/v1/auth/refresh

**Route**: `router.go:61` — `r.Post("/refresh", d.Auth.Refresh)`.
**Auth requirement**: none via `requireAuth` middleware, but functionally requires a valid `refresh_token` cookie (read directly from the request, not via `middleware.RequireAuth`).

### Request body
**None.** `Refresh` (`auth_handler.go:64-78`) reads only `r.Cookie("refresh_token")` — there is no JSON request struct at all. The mobile client sends this as a bodyless POST relying on the cookie jar to attach `refresh_token`.

### Success response — `200 OK`, body: same `userResponse` shape as login (new access+refresh cookies are set again via `setSessionCookies`, rotating the refresh token per `auth_service.go:58-84`).

### Error responses

| Condition | Status | Body |
|---|---|---|
| No `refresh_token` cookie present | 401 | `{"error":"refresh token yok"}` |
| Refresh token not found / expired in DB (`domain.ErrInvalidToken`) | 401 | `{"error":"oturum geçersiz veya süresi dolmuş"}` — **and** both cookies are cleared (`clearSessionCookies` called first, line 72, before writing the error) |
| User behind the token is now inactive (`domain.ErrInactiveUser`) | 403 | `{"error":"kullanıcı pasif durumda"}` — cookies also cleared |
| Any other error | 500 | `{"error":"beklenmeyen bir hata oluştu"}` — cookies also cleared |

Note precisely: on **every** error path in `Refresh`, `h.clearSessionCookies(w)` runs before `h.writeAuthError(w, err)` (lines 72-74) — so a failed refresh always invalidates client-side cookies too, not just a 401. The mobile client should treat any non-200 from `/refresh` as "fully logged out, go to login screen."

Service logic (`auth_service.go:61-84`): hashes the raw token (SHA-256), looks up `GetValidRefreshToken` (presumably DB-side filters out expired/revoked — not re-verified here beyond confirming the query name), on success revokes the old token then issues a brand-new access+refresh pair (rotation).

---

## 3. POST /api/v1/auth/logout

**Route**: `router.go:62` — `r.Post("/logout", d.Auth.Logout)`.
**Auth requirement**: none.

### Request body
**None.** (`Logout`, `auth_handler.go:80-86`)

### Behavior
If a `refresh_token` cookie is present, it's revoked server-side (`h.svc.Logout` → `RevokeRefreshToken`); **the return value/error of this is discarded** (`_ = h.svc.Logout(...)`). Cookies are cleared unconditionally either way.

### Response — always `200 OK` (no error path exists in this handler at all)
```go
httpjson.Write(w, http.StatusOK, map[string]bool{"ok": true})
```
Body: `{"ok": true}`. There is no way for this endpoint to return a non-200 status.

---

## 4. GET /api/v1/auth/me

**Route**: `router.go:63` — `r.With(requireAuth).Get("/me", d.Auth.Me)`.
**Auth requirement**: `requireAuth` (`middleware.RequireAuth`) — reads and validates the `access_token` cookie's JWT signature/expiry only (does **not** hit the DB for the active-flag check on every request — see the code comment at `middleware/auth.go:21-25`: an access token's `is_active` staleness is only caught at next refresh, tolerated because the access TTL is 15 minutes).

### Request body
None (GET).

### Success response — `200 OK`, body: `userResponse` (same shape as login), built from a **fresh DB read** (`Me` calls `h.svc.Me(ctx, userID)` which does `GetUserByID`, `auth_service.go:90-104`) — so `is_active`/`full_name`/`role` reflect current DB state even though the JWT itself is not re-checked against the DB here.

### Error responses — **two different error paths with two different producers**

**(a) Middleware-level 401** — missing or invalid/expired access token cookie. This is produced by `middleware/auth.go` using **raw `http.Error`, NOT `httpjson.Error`** — confirm the exact literal body string:

```go
// missing cookie (auth.go:29-33)
http.Error(w, `{"error":"oturum bulunamadı"}`, http.StatusUnauthorized)

// present but invalid/expired signature (auth.go:34-38)
http.Error(w, `{"error":"oturum geçersiz veya süresi dolmuş"}`, http.StatusUnauthorized)
```
Because this uses `http.Error`, the response has `Content-Type: text/plain; charset=utf-8` (Go's default for `http.Error`, NOT `application/json`) with a trailing `\n` appended by `http.Error`. **This differs from every other error format in the API** — the mobile client's JSON error parser must not assume `Content-Type: application/json` here; it must be prepared to parse `{"error":"..."}\n` served as `text/plain`. This is the "different error format than httpjson.Error" the task flagged, and it is real: `httpjson.Error` always sets `Content-Type: application/json; charset=utf-8` (`httpjson.go:12`) while `middleware/auth.go` never sets a Content-Type header explicitly, so `net/http` defaults `http.Error`'s content type to `text/plain; charset=utf-8`.

**(b) Handler-level 401** — this only fires if the middleware already passed (valid JWT) but something is wrong downstream, produced normally via `httpjson.Error` (so this one *is* proper `application/json`):
```go
// auth_handler.go:88-100
userID, ok := middleware.UserIDFromContext(r.Context())
if !ok {
    httpjson.Error(w, http.StatusUnauthorized, "oturum bulunamadı")  // {"error":"oturum bulunamadı"}
    return
}
user, err := h.svc.Me(r.Context(), userID)
if err != nil {
    httpjson.Error(w, http.StatusUnauthorized, "oturum geçersiz")     // {"error":"oturum geçersiz"}
    return
}
```
Note: path (b)'s first branch (`!ok`) is dead in practice under normal routing since `requireAuth` always sets the context value before calling next — it would only trigger if `Me` were somehow reachable without the middleware. Path (b)'s second branch fires if `Me` (service) returns any error, including `domain.ErrNotFound` (user deleted after token issued) or `domain.ErrInvalidToken` (malformed UUID in claims) — both collapse to the same `{"error":"oturum geçersiz"}` message at 401, i.e. the mobile client cannot distinguish "user deleted" from "bad token" from this response alone.

Summary of exact bodies for GET /me failures:

| Case | Content-Type | Status | Body |
|---|---|---|---|
| No `access_token` cookie | text/plain | 401 | `{"error":"oturum bulunamadı"}\n` |
| Invalid/expired `access_token` JWT | text/plain | 401 | `{"error":"oturum geçersiz veya süresi dolmuş"}\n` |
| Valid JWT but `Me()` service error (user gone / bad id) | application/json | 401 | `{"error":"oturum geçersiz"}` |

---

## PATCH /users/me/password (own-password change) — related but not an `/auth/*` route

Not under `/auth`, but this is the mobile "change my password" screen's backend, confirmed to exist. **Full path**: `/api/v1/users/me/password` (`router.go:66-68`: `r.Route("/users", ...)` → `r.Use(requireAuth)` → `r.Patch("/me/password", d.Users.ChangeOwnPassword)`).

**Auth requirement**: `requireAuth` only (no admin requirement — it's inside the `requireAuth`-only block, before the `requireAdmin` sub-group).

### Request body — `changeOwnPasswordRequest` (`user_handler.go:102-105`)
```go
type changeOwnPasswordRequest struct {
	CurrentPassword string `json:"current_password"`
	NewPassword     string `json:"new_password"`
}
```
Both required strings, no pointers/omitempty.

### Success — `200 OK`, body `{"ok": true}` (`map[string]bool{"ok": true}`)

### Errors
- Malformed body → 400 `{"error":"geçersiz istek gövdesi"}`
- No auth context (defensive, practically unreachable given middleware) → 401 `{"error":"oturum bulunamadı"}`
- Service error dispatch via `writeUserError` (`user_handler.go:144-155`):
  - `domain.ErrNotFound` → 404 `{"error":"kullanıcı bulunamadı"}`
  - `domain.ErrDuplicateUsername` → 409 `{"error":"bu kullanıcı adı zaten kullanılıyor"}` (not reachable from this endpoint in practice, but it's the same dispatcher used by Create/Update)
  - `domain.ErrInvalidCredentials` (current password wrong) → 400 `{"error":"mevcut şifre hatalı"}`
  - anything else → 400 with **the raw `err.Error()` string** (not a fixed message) — I did not read `user_service.go`'s `ChangeOwnPassword` body to enumerate every possible raw error string it can produce; if you need those exact strings I can read `internal/service/user_service.go` next, but they were out of the requested file list.

All via `httpjson.Error` → proper `application/json`.

---

## Endpoints NOT covered / explicitly out of scope confirmations

- There is **no** `/api/v1/auth/register` or self-signup endpoint — only admin-created users (`POST /users`, admin-only) or seed script.
- There is **no** token-in-body login response anywhere — do not build the mobile client around storing a bearer token from the login JSON; there isn't one.
- `Authorization: Bearer` header is **NOT SUPPORTED — no code reads it anywhere in httpapi/middleware or handlers.** Auth is 100% via the `access_token`/`refresh_token` cookies. A native Flutter HTTP client must manage a cookie jar (e.g. `cookie_jar`/`dio_cookie_manager` packages) and must send `Domain`/`Path`-matching cookies back on every subsequent call, including cross-scheme quirks if `COOKIE_DOMAIN` is set.

---

### Quick field-type/enum summary for the mobile model layer

- `Role` enum: exactly `"admin"` | `"kullanici"` (`domain/user.go:10-13`) — no other values, no `"user"`, no `"manager"`, etc.
- All `userResponse` fields are non-nullable (no `*string`, no `omitempty`): `id`, `username`, `full_name`, `role`, `is_active`.
- No money/quantity fields appear in any of these four auth endpoints or the password-change endpoint, so the `/calculations/*` string-vs-number serialization exception mentioned in the task brief is **not applicable here** — it was verified as out of scope for this file set, not assumed away.

**Files read (for citation)**: `internal/httpapi/handler/auth_handler.go`, `internal/httpapi/handler/user_handler.go`, `internal/httpapi/handler/errors.go`, `internal/service/auth_service.go`, `internal/httpapi/middleware/auth.go`, `internal/httpapi/middleware/require_role.go`, `internal/httpapi/router.go`, `internal/domain/user.go`, `internal/domain/errors.go`, `internal/platform/httpjson/httpjson.go`, `internal/config/config.go`, `internal/auth/jwt.go`, `cmd/api/main.go`.