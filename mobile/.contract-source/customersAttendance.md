# ARVEND Backend API Contract — Mobile Client Reference (verified against Go source)

All paths are mounted under `/api/v1` in `internal/httpapi/router.go:58`. Base middleware for the group: `chimw.Recoverer`, `cors.Handler` (credentials-based, cookie-carrying CORS). There is **no `Authorization: Bearer` header** — auth is via **httpOnly cookies** (`access_token`, `refresh_token`) set by `/auth/login` (`internal/httpapi/handler/auth_handler.go:115-136`). A mobile client must send/receive cookies (e.g. `CookieJar`/`withCredentials`) — there is no bearer-token login response field.

---

## 0. Cross-cutting: error shapes (two different mechanisms — important)

**A. Handler-level errors** (`internal/platform/httpjson/httpjson.go:22-24`):
```go
func Error(w http.ResponseWriter, status int, message string) {
    Write(w, status, map[string]string{"error": message})
}
```
→ Body: `{"error": "<turkish message>"}`, `Content-Type: application/json; charset=utf-8`. Status codes used per-handler (see each endpoint below); default/unmapped service errors fall through to `http.StatusBadRequest` with the raw Go `err.Error()` string (Turkish, human-readable, **not a machine-readable code** — do not pattern-match on exact text beyond what's documented here).

**B. Middleware-level errors** (`internal/httpapi/middleware/auth.go:31,36` and `require_role.go:16`) use raw `http.Error`, NOT `httpjson`:
```go
http.Error(w, `{"error":"oturum bulunamadı"}`, http.StatusUnauthorized)          // no access_token cookie
http.Error(w, `{"error":"oturum geçersiz veya süresi dolmuş"}`, http.StatusUnauthorized) // bad/expired JWT
http.Error(w, `{"error":"bu işlem için yetkiniz yok"}`, http.StatusForbidden)    // role != required role
```
**Caveat for the mobile client:** `http.Error` sets `Content-Type: text/plain; charset=utf-8`, not `application/json`, even though the body text is JSON. JSON-decode the body regardless of the declared content type for 401/403s hit before a handler runs.

Domain sentinel errors (`internal/domain/errors.go:6-10`):
```go
ErrNotFound           = errors.New("kayıt bulunamadı")
ErrDuplicateUsername  = errors.New("bu kullanıcı adı zaten kullanılıyor")
ErrInvalidCredentials = errors.New("kullanıcı adı veya şifre hatalı")
ErrInactiveUser       = errors.New("kullanıcı pasif")
ErrInvalidToken       = errors.New("geçersiz veya süresi dolmuş oturum")
```
Note: `ErrInvalidCredentials` is reused for two different scenarios with different messages/status — login failure (401, "kullanıcı adı veya şifre hatalı") vs. wrong current password on self password-change (400, "mevcut şifre hatalı") — same Go sentinel, different handler-chosen text/status.

**Money/quantity string-encoding exception — verified directly:** Only `/api/v1/calculations/*` (recipe items) serializes numeric fields as JSON **strings** — confirmed at `internal/httpapi/handler/calc_handler.go:243-251` (`QuantityPerM2`, `QuantityPerMeter`, `FixedQuantity`, `WastePercent`, `ReferenceUnitPrice`, `MinQuantity`, `PackageSize` are all `string`, converted via `.String()` from `pgtype.Numeric` at line 268). **None of the endpoints in this task's scope (customers, employees, attendance, users, settings) use string-encoded numbers** — `Employee.Salary`/`DailyWage` and `AttendanceLog.WorkHours` are plain JSON numbers (`*float64`/`float64`). Do not apply the calculations-style string parsing to these.

---

## 1. GET /api/v1/auth/me (Profile screen)

- Auth: `requireAuth` only (`router.go:63`). No admin requirement.
- Request: no body, no query params.
- Response 200 — `userResponse` (`auth_handler.go:31-37`):
```go
type userResponse struct {
    ID       string      `json:"id"`
    Username string      `json:"username"`
    FullName string      `json:"full_name"`
    Role     domain.Role `json:"role"`   // string enum: "admin" | "kullanici"
    IsActive bool         `json:"is_active"`
}
```
Built by `toUserResponse` (`auth_handler.go:39-47`) from `domain.User` (`internal/domain/user.go:19-30`), returned via `AuthService.Me` (`internal/service/auth_service.go:90-99`, looks up by `GetUserByID`).

- **`domain.Role` enum — exact values** (`internal/domain/user.go:8-13`):
```go
type Role string
const (
    RoleAdmin     Role = "admin"
    RoleKullanici Role = "kullanici"
)
```

- **NOT SUPPORTED — organization data.** `domain.User` has an `OrganizationID string` field (`user.go:21`) but `userResponse` **does not serialize it** — no `organization_id`, no organization name/slug anywhere in this response. There is a separate `domain.Organization{ID, Name, Slug, IsActive, CreatedAt, UpdatedAt}` (`internal/domain/organization.go:5-12`) and an `internal/service/organization_service.go`, but **no `/api/v1/organizations*` route exists in `router.go`** — I grepped the full router and there is no such route registration. A Profile screen **cannot** show organization name/slug from any endpoint; the only way the client currently knows its org is implicitly (server-side, via the JWT claim used for scoping, never returned to the client). If the mobile team needs an org name on the profile screen, this is a backend gap, not a client bug.

- Error on failure: `httpjson.Error(w, http.StatusUnauthorized, "oturum bulunamadı")` if no user id in context (shouldn't happen after `requireAuth`), or `httpjson.Error(w, http.StatusUnauthorized, "oturum geçersiz")` if `Me()` errors (`auth_handler.go:88-100`).

---

## 2. /api/v1/customers/*

Route group (`router.go:221-231`): `r.Use(requireAuth)` only — **no admin requirement on any customer endpoint.**

### 2.1 GET /api/v1/customers
- Auth: `requireAuth`.
- Query params (`customer_handler.go:49-58`):
  - `filter` — `"aktif"` → server sets `activeOnly=true`; `"pasif"` → `activeOnly=false`; any other value (including absent) → `activeOnly=nil` (no filter, both shown).
  - `q` — free-text search, passed to `CustomerService.List` (`customer_service.go:34-52`) → SQL (`internal/repository/sqlc/customers.sql.go:106-112`):
    ```sql
    WHERE organization_id = $1
      AND ($3::boolean IS NULL OR is_active = $3::boolean)
      AND ($2::text = '' OR name ILIKE '%' || $2::text || '%')
    ORDER BY name ASC
    ```
    **Verified: `q` matches ONLY the `name` column (case-insensitive substring). It does NOT search phone, email, tax_office, tax_number, or notes.** A mobile "search by phone" feature has no backend support via this param — do not build UI implying phone/email search works here.
  - No pagination params exist for this endpoint (no `page`/`limit`/`cursor`) — it returns the full filtered list every time.
- Response 200: `{"customers": [customerResponse, ...]}` (`customer_handler.go:69`).
- Error: 500 `{"error":"müşteri listesi alınamadı"}` on failure.

### 2.2 GET /api/v1/customers/{id}
- Response 200: `customerResponse` (bare object, not wrapped).
- Error: 404 `{"error":"müşteri bulunamadı"}` if `domain.ErrNotFound`; otherwise 400 with raw error text (`customer_handler.go:146-153`).

### 2.3 POST /api/v1/customers (create)
- Request body — `upsertCustomerRequest` (`customer_handler.go:82-91`):
```go
type upsertCustomerRequest struct {
    Name      string `json:"name"`
    Phone     string `json:"phone"`
    Email     string `json:"email"`
    Address   string `json:"address"`
    TaxOffice string `json:"tax_office"`
    TaxNumber string `json:"tax_number"`
    Notes     string `json:"notes"`
    IsActive  bool   `json:"is_active"`
}
```
  All fields are plain `string`/`bool` — **no pointers, nothing nullable, nothing `omitempty` on the request.** `Decode` uses `DisallowUnknownFields()` (`httpjson.go:29`) so sending extra JSON keys → 400.
  **`IsActive` sent by the client is ignored on create** — handler forces `req.IsActive = true` right after decode (`customer_handler.go:112`), before building the service input.
  Server-side validation: `Name` is required (trimmed non-empty) or 400 `"müşteri adı zorunludur"` (`customer_service.go:79-82`); all other fields are only `strings.TrimSpace`'d, **no format validation on Phone or Email** (no regex, no length check) — so garbage phone/email strings are accepted as-is.
- Response 201: `customerResponse` (bare object).

### 2.4 PUT /api/v1/customers/{id} (update)
- Same request body shape as create; here `IsActive` from the client **is honored** (not overridden).
- Response 200: `customerResponse`.
- Error: 404 not found, else 400 with service error text (e.g. empty name).

### 2.5 DELETE /api/v1/customers/{id} (archive, not hard delete)
- Response 200: `{"ok": true}`. Comment in code confirms it's a soft-delete/pasifleştir, not a real delete (`customer_service.go:135-137`).

### `customerResponse` (exact shape returned by GET/POST/PUT) — `customer_handler.go:23-33`:
```go
type customerResponse struct {
    ID        string `json:"id"`
    Name      string `json:"name"`
    Phone     string `json:"phone"`      // always present, "" if not set — never null
    Email     string `json:"email"`      // always present, "" if not set — never null
    Address   string `json:"address"`
    TaxOffice string `json:"tax_office"`
    TaxNumber string `json:"tax_number"`
    Notes     string `json:"notes"`
    IsActive  bool   `json:"is_active"`
}
```
For a mobile "call"/"email" action: check `Phone != ""` / `Email != ""` (empty string, not `null` — the field has no `*string`/`omitempty`, so it's always present in the JSON).

`domain.Customer` (`internal/domain/customer.go:5-18`) additionally carries `OrganizationID`, `CreatedAt`, `UpdatedAt` in Go, but **these are not exposed** in `customerResponse` — not available to the client.

---

## 3. /api/v1/employees/*

Route group (`router.go:233-246`): `List`/`Get` under `requireAuth` only; `Create`/`Update`/`Archive` additionally require `requireAdmin`.

### 3.1 GET /api/v1/employees — auth: `requireAuth`
- Query param: `filter` (`"aktif"`/`"pasif"`, same semantics as customers). **No `q` search param at all** — `EmployeeService.List` (`employee_service.go:35-49`) takes no search string; `ListEmployees` SQL has no `ILIKE` clause. A mobile employee search box has **NO_SUPPORTED — no endpoint/query-param exists for text search over employees.**
- Response 200: `{"employees": [employeeResponse, ...]}`.

### 3.2 GET /api/v1/employees/{id} — auth: `requireAuth`
- Response 200: bare `employeeResponse`. Error 404 `"personel bulunamadı"` on not found.

### 3.3 POST /api/v1/employees — auth: `requireAuth` **+ `requireAdmin`**
- Request — `upsertEmployeeRequest` (`employee_handler.go:87-96`):
```go
type upsertEmployeeRequest struct {
    FullName    string   `json:"full_name"`
    Phone       string   `json:"phone"`
    Position    string   `json:"position"`
    Salary      *float64 `json:"salary"`      // nullable — omit or null → no salary
    DailyWage   *float64 `json:"daily_wage"`  // nullable
    StartDate   *string  `json:"start_date"`  // nullable; format "2006-01-02" (YYYY-MM-DD) if present
    Description string   `json:"description"`
    IsActive    bool     `json:"is_active"`
}
```
  `StartDate`, if non-nil and non-empty, must parse as `YYYY-MM-DD` (`time.Parse("2006-01-02", ...)`, `employee_handler.go:108-113`) or 400 `"geçersiz işe başlama tarihi"`. `FullName` required (trimmed non-empty) or 400 `"ad soyad zorunludur"`. `IsActive` is forcibly set to `true` on create (same override pattern as customers, `employee_handler.go:124`).
- Response 201: `employeeResponse`.

### 3.4 PUT /api/v1/employees/{id} — auth: `requireAuth` + `requireAdmin`
- Same request shape; `IsActive` from client honored on update.

### 3.5 DELETE /api/v1/employees/{id} — auth: `requireAuth` + `requireAdmin` (archive/soft-delete)
- Response 200: `{"ok": true}`.

### `employeeResponse` (`employee_handler.go:24-52`):
```go
type employeeResponse struct {
    ID          string   `json:"id"`
    FullName    string   `json:"full_name"`
    Phone       string   `json:"phone"`      // plain string, never null
    Position    string   `json:"position"`
    Salary      *float64 `json:"salary"`     // nullable, plain JSON number (not string)
    DailyWage   *float64 `json:"daily_wage"` // nullable, plain JSON number
    StartDate   *string  `json:"start_date"` // nullable, "YYYY-MM-DD" string when present
    IsActive    bool     `json:"is_active"`
    Description string   `json:"description"`
}
```
**Mobile note:** a non-admin mobile user can `GET` employees (list/detail) for attendance entry purposes, but **cannot create/edit/archive employees** — those calls will 403 with `{"error":"bu işlem için yetkiniz yok"}` (raw `http.Error`, `text/plain` content-type — see section 0B).

---

## 4. /api/v1/attendance/*

Route group (`router.go:248-255`): `r.Use(requireAuth)` — **no admin requirement on any attendance endpoint.** This is a **manual entry system — verified no GPS/geofence/location fields exist anywhere** in the request, response, service, or domain struct.

### `domain.AttendanceLog` (`internal/domain/employee.go:38-50`) — the actual shape, confirmed field-by-field:
```go
type AttendanceLog struct {
    ID             string
    OrganizationID string
    EmployeeID     string
    EmployeeName   string   // only populated on the LIST endpoint (JOIN); empty on create/update/get
    Date           time.Time
    CheckIn        string   // free-text string, NOT time.Time — no format enforced server-side
    CheckOut       string   // free-text string, same as above
    WorkHours      float64
    Status         string   // enum, see below
    Note           string
    CreatedAt      time.Time
}
```
Status enum — exact valid values (`internal/domain/employee.go:20-36`):
```go
AttendanceGeldi    = "geldi"
AttendanceYarimGun = "yarım gün"
AttendanceGelmedi  = "gelmedi"
AttendanceIzinli   = "izinli"
```
Any other string → 400 `"geçersiz mesai durumu"` (`attendance_service.go:81-83, 118-120`).

**`CheckIn`/`CheckOut` are unconstrained strings** — no regex/format validation anywhere in `attendance_handler.go` or `attendance_service.go` (only `strings.TrimSpace`). Whatever the mobile client sends (e.g. `"08:30"`, or anything else) is stored verbatim; the backend does not compute `WorkHours` from check-in/check-out — the client (or whoever calls the API) must supply `work_hours` itself as a number.

### 4.1 GET /api/v1/attendance (list by month)
- Query param: `month` — optional, format `YYYY-MM` (`time.Parse("2006-01", ...)`, `attendance_handler.go:51-60`). If absent, defaults to current month (`time.Now()`). Invalid format → 400 `"geçersiz ay (YYYY-MM bekleniyor)"`.
- Response 200: `{"attendance": [attendanceResponse, ...]}`, with `employee_name` populated (comes from a SQL JOIN, `internal/repository/pool.go:332-346`).

### 4.2 POST /api/v1/attendance (create — this is the "check-in/manual entry" endpoint; no separate check-in vs check-out call exists)
- Request — `upsertAttendanceRequest` (`attendance_handler.go:74-82`):
```go
type upsertAttendanceRequest struct {
    EmployeeID string  `json:"employee_id"`  // required, must be a valid UUID belonging to the same org
    Date       string  `json:"date"`         // required, "YYYY-MM-DD"
    CheckIn    string  `json:"check_in"`
    CheckOut   string  `json:"check_out"`
    WorkHours  float64 `json:"work_hours"`   // plain number, not a string
    Status     string  `json:"status"`       // must be one of the 4 enum values above
    Note       string  `json:"note"`
}
```
  `Date` must parse `YYYY-MM-DD` or 400 `"geçersiz tarih"` (`attendance_handler.go:90-94`). Service also validates the employee belongs to the caller's org (`GetEmployeeByID` check, `attendance_service.go:93-95`) → 400 `"geçersiz personel"` if not.
- Response 201: `attendanceResponse` (see below) — **`employee_name` will be omitted** here (empty string + `omitempty` tag) since create uses `ToDomainAttendance` (no JOIN), unlike the list endpoint.
- Error 409 `ErrAttendanceExists` → `{"error":"bu personel için bu tarihte zaten mesai kaydı var"}` if a unique-constraint violation (Postgres code `23505`) fires — i.e. **one attendance row per employee per date**; a second POST for the same employee+date conflicts (`attendance_service.go:106-111`, `attendance_handler.go:146-147`).

### 4.3 PUT /api/v1/attendance/{id} (update)
- Same body shape as create, **except `EmployeeID` and `Date` are not sent to the service on update** (`attendance_handler.go:119-125` only forwards `CheckIn/CheckOut/WorkHours/Status/Note` — even if the client includes `employee_id`/`date` in the JSON body, they are silently ignored/decoded-but-unused; you cannot move a record to a different employee or day via this endpoint).
- Response 200: `attendanceResponse` (again `employee_name` empty/omitted — no JOIN on update path).

### 4.4 DELETE /api/v1/attendance/{id}
- Response 200: `{"ok": true}`. Error 404 if not found.

### `attendanceResponse` (`attendance_handler.go:24-34`):
```go
type attendanceResponse struct {
    ID           string  `json:"id"`
    EmployeeID   string  `json:"employee_id"`
    EmployeeName string  `json:"employee_name,omitempty"` // present on LIST, omitted (empty) on create/get/update
    Date         string  `json:"date"`       // "YYYY-MM-DD"
    CheckIn      string  `json:"check_in"`
    CheckOut     string  `json:"check_out"`
    WorkHours    float64 `json:"work_hours"` // plain JSON number
    Status       string  `json:"status"`
    Note         string  `json:"note"`
}
```
**NOT SUPPORTED — no GPS/geofence/location, no separate "check-in" vs "check-out" action/endpoint, no device/photo-verification field.** There is only one `POST /api/v1/attendance` that creates a full day's record (status + optional check-in/out strings + work_hours), and `PUT /api/v1/attendance/{id}` to edit it. Do not design a two-step clock-in/clock-out UI expecting distinct backend calls — model it as "create/edit one attendance record for employee+date."

---

## 5. PATCH /api/v1/users/me/password (change own password)

- Path/method exactly: `PATCH /api/v1/users/me/password`.
- Auth: `requireAuth` only (registered directly under `r.Use(requireAuth)` at `router.go:66-68`, **outside** the `requireAdmin` subgroup that guards `/users` list/create/get/update/delete/admin-reset) — any authenticated user, admin or not, can call this for themselves.
- Request — `changeOwnPasswordRequest` (`user_handler.go:102-105`):
```go
type changeOwnPasswordRequest struct {
    CurrentPassword string `json:"current_password"`
    NewPassword     string `json:"new_password"`
}
```
- Server logic (`UserService.ChangeOwnPassword`, `user_service.go:146-162`): fetches the caller's own row, verifies `CurrentPassword` against the stored hash (`auth.CheckPassword`), then calls `setPassword` which enforces **`len(newPassword) >= 8`** (`user_service.go:179-181`) or 400 `"yeni şifre en az 8 karakter olmalı"`.
- Response 200: `{"ok": true}`.
- Errors (`user_handler.go:144-155`):
  - 401 `{"error":"oturum bulunamadı"}` if no user id in context (`user_handler.go:108-112`, before even calling the service).
  - 400 `{"error":"mevcut şifre hatalı"}` if `CurrentPassword` doesn't match (`domain.ErrInvalidCredentials`).
  - 404 `{"error":"kullanıcı bulunamadı"}` if `domain.ErrNotFound`.
  - 400 with raw text for anything else (e.g. the 8-char-minimum message).

Other `/users/*` endpoints (`List`, `Get`, `Create`, `Update`, `AdminResetPassword`, `Deactivate`) are all behind `requireAdmin` (`router.go:70-78`) — **not usable by a non-admin mobile user**, included here only for completeness since the task named `user_handler.go`:
- `GET /api/v1/users?page=&limit=` (limit clamped to 1-100, default 20; page default 1, `user_service.go:36-40`) → `{"users":[userResponse...], "total": <int64>}`.
- `GET /api/v1/users/{id}` → bare `userResponse`.
- `POST /api/v1/users` body `{username, password, full_name, role}` (`domain.Role`) → 201 `userResponse`; duplicate username → 409 `{"error":"bu kullanıcı adı zaten kullanılıyor"}`.
- `PUT /api/v1/users/{id}` body `{full_name, role, is_active}` → 200 `userResponse`; invalid role → 400.
- `PATCH /api/v1/users/{id}/password` (admin reset, no current-password check) body `{new_password}` → 200 `{"ok": true}`.
- `DELETE /api/v1/users/{id}` (deactivate) → 200 `{"ok": true}`.
`userResponse` shape is identical to the one used for `/auth/me` (section 1) — same struct, same file.

---

## 6. /api/v1/settings/*

Route group (`router.go:257-262`):
```go
r.Route("/settings", func(r chi.Router) {
    r.Use(requireAuth, requireAdmin)
    r.Get("/smtp", d.Settings.GetSmtp)
    r.Put("/smtp", d.Settings.UpdateSmtp)
    r.Post("/smtp/test", d.Settings.TestSmtp)
})
```
**Explicitly confirmed: the ENTIRE `/settings/*` group requires `requireAdmin`, with zero exceptions/sub-groups.** There is no non-admin-accessible settings endpoint at all — not even a read-only one. A non-admin mobile user gets 403 `{"error":"bu işlem için yetkiniz yok"}` (raw `http.Error`, `text/plain`) on every single one of these. **If the mobile app has any "Settings" screen for regular users, it must NOT call any `/api/v1/settings/*` endpoint** — there is nothing there for them (no notification prefs, no locale, no per-user settings resource exists in this codebase under any path).

For completeness/reference (admin-only), the shapes:
- `GET /api/v1/settings/smtp` → `smtpSettingsResponse` (`settings_handler.go:20-29`):
```go
type smtpSettingsResponse struct {
    Host        string `json:"host"`
    Port        int    `json:"port"`
    Username    string `json:"username"`
    PasswordSet bool   `json:"password_set"`  // actual password never returned, only whether one is set
    FromEmail   string `json:"from_email"`
    FromName    string `json:"from_name"`
    UseTLS      bool   `json:"use_tls"`
    Configured  bool   `json:"configured"`
}
```
- `PUT /api/v1/settings/smtp` request (`settings_handler.go:50-58`):
```go
type updateSmtpRequest struct {
    Host      string  `json:"host"`
    Port      int     `json:"port"`
    Username  string  `json:"username"`
    Password  *string `json:"password"`  // nullable — nil means "leave unchanged"
    FromEmail string  `json:"from_email"`
    FromName  string  `json:"from_name"`
    UseTLS    bool    `json:"use_tls"`
}
```
  Response: same `smtpSettingsResponse`.
- `POST /api/v1/settings/smtp/test` request `{"to": "<email>"}` (`testSmtpRequest`, `settings_handler.go:92-94`) → `{"ok": true}` on success, or 400 `{"error":"gönderilemedi: <mailer error>"}` on send failure.

---

## Summary of explicit gaps for the mobile app (do not build UI assuming these exist)

1. **Organization info on Profile screen — NOT SUPPORTED.** `GET /auth/me` returns only `id, username, full_name, role, is_active`. No `organization_id`, no org name/slug is returned by any endpoint (no `/organizations` route exists at all).
2. **Attendance GPS/geofence/clock-in-clock-out-as-two-calls — NOT SUPPORTED.** One `POST/PUT /attendance` call carries a free-text `check_in`/`check_out` string, a numeric `work_hours`, and a `status` enum; nothing else.
3. **Customer search by phone/email — NOT SUPPORTED.** The `q` param on `GET /customers` only matches the `name` column (`ILIKE`).
4. **Employee search — NOT SUPPORTED.** `GET /employees` has only an active/passive `filter` param, no text search.
5. **Any `/settings/*` for non-admin users — NOT SUPPORTED.** Entire route group is `requireAdmin`; no per-user or read-only carve-out exists.
6. **Pagination on `/customers` and `/employees` lists — NOT SUPPORTED.** Only `/users` (admin-only) paginates (`page`/`limit`); customers/employees always return the full filtered set.