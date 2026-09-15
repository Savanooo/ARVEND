# ARVEND Backend — Project Operations Sub-Resource API Contract (verified against source)

Repo: `/Users/tahaeryetisozen/Documents/GitHub/x-api/ARVEND/backend`
Primary files read in full: `internal/httpapi/handler/project_operations_handler.go`, `internal/httpapi/router.go`, `internal/domain/project_operations.go`, `internal/service/project_operations_service.go`, plus supporting files (`project_finance_handler.go` for events, `project_finance_service.go` for shared helpers, `project_handler.go` for `writeError`/date helpers, `platform/httpjson`, `httpapi/middleware`, `platform/storage`).

---

## 0. Answer to the critical question: cross-project "my tasks" endpoint

**NOT SUPPORTED — no endpoint found.** I read `internal/httpapi/router.go` in full (280 lines, every route registration) and grepped the entire `internal/` tree for any variant (`gorevlerim`, `görevlerim`, `my-tasks`, `/me/tasks`, assignee-scoped task queries). There is:
- No route anywhere outside `/api/v1/projects/{id}/tasks` that returns tasks.
- No SQL query in `internal/repository/queries/project_operations.sql` that lists tasks by `assigned_employee_id` without a `project_id` filter — `ListTasks` (line 63) is always `WHERE project_id = $1 AND organization_id = $2`.
- No service method resembling `ListMyTasks` / `ListAssignedTasks`.

**This is a real backend gap.** A mobile "my tasks across all projects" screen has zero backend support today. The only way to approximate it client-side would be to call `GET /projects` (all projects) then `GET /projects/{id}/tasks` for each and filter by `assigned_employee_id` client-side — which is expensive and not equivalent to a real cross-project query (no server-side pagination/sort/filter by assignee exists at all). State this to the mobile team as a backend TODO, not something to fake.

---

## 1. Auth model for this entire resource family

All routes below live under `router.go:145` `r.Route("/projects", ...)` which applies **only** `r.Use(requireAuth)` (`router.go:146`). None of the operational sub-routes (members/schedule/tasks/files/photos/notes/events/operations-summary) are wrapped in a `requireAdmin` group — unlike `/users`, `/products`, `/calculations`, `/employees`, which nest admin-only groups. So:

- **Auth requirement for every endpoint in this doc: `requireAuth` only.** Any authenticated user in the organization can read/write all of these, regardless of role.
- Auth is **cookie-based**, not a Bearer header: `RequireAuth` (`internal/httpapi/middleware/auth.go`) reads the `access_token` httpOnly cookie, validates the JWT, and injects `userID`, `role`, `organizationID` into the request context. **The mobile client must send this as a cookie** (persist and replay `Set-Cookie` from `/api/v1/auth/login`), not as an `Authorization: Bearer` header — there is no bearer-token code path in this codebase.
- Auth failure shape (raw `http.Error`, not `httpjson`): `401 {"error":"oturum bulunamadı"}` (no cookie) or `401 {"error":"oturum geçersiz veya süresi dolmuş"}` (bad/expired JWT). `RequireRole` (only used elsewhere) would return `403 {"error":"bu işlem için yetkiniz yok"}` — not applicable here since no route in this family uses it.
- Multi-tenancy: every service method resolves `organizationID` from the JWT and every SQL query filters `WHERE ... AND organization_id = $N`. A valid project/task/file/photo UUID belonging to another organization is indistinguishable from a non-existent one — always `404`, never `403`.

---

## 2. Generic error envelope (`internal/platform/httpjson/httpjson.go`)

```go
func Write(w http.ResponseWriter, status int, payload any) { ... }         // sets Content-Type: application/json; charset=utf-8
func Error(w http.ResponseWriter, status int, message string) {
    Write(w, status, map[string]string{"error": message})
}
func Decode(r *http.Request, dst any) error {
    dec := json.NewDecoder(r.Body)
    dec.DisallowUnknownFields()   // <-- any unrecognized JSON field => decode error => 400
    return dec.Decode(dst)
}
```

So **every JSON error body from this API is exactly `{"error": "<string>"}`** — one flat string field, no error codes, no field-level validation arrays. Also important: `DisallowUnknownFields()` means the mobile client must send **exactly** the accepted JSON keys on any `POST`/`PUT` JSON body (extra fields cause a `400 {"error":"geçersiz istek gövdesi"}` — that literal message is hardcoded at each handler's decode-failure branch, e.g. `project_operations_handler.go:63,146,162,235,251,516`).

`ProjectHandler.writeError` (`internal/httpapi/handler/project_handler.go:253-285`) is the single dispatcher used by **every** handler in this file (members/schedule/tasks/files/photos/notes all call `h.writeError(w, err)`):

```go
func (h *ProjectHandler) writeError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, domain.ErrNotFound):
		httpjson.Error(w, http.StatusNotFound, "proje bulunamadı")
	case errors.Is(err, service.ErrOfferNotAccepted), errors.Is(err, service.ErrInvalidProjectState),
		errors.Is(err, service.ErrProjectLocked), errors.Is(err, service.ErrCurrencyMismatch),
		errors.Is(err, service.ErrAlreadyVoided), errors.Is(err, service.ErrDuplicateMember),
		errors.Is(err, service.ErrDuplicateContent), errors.Is(err, service.ErrChangeOrderNotEditable),
		errors.Is(err, service.ErrChangeOrderNotSendable), errors.Is(err, service.ErrChangeOrderNotCancellable),
		errors.Is(err, service.ErrChangeOrderNotRevisable), errors.Is(err, service.ErrChangeOrderWouldGoNegative):
		httpjson.Error(w, http.StatusConflict, err.Error())
	case errors.Is(err, service.ErrInvalidEmployee), errors.Is(err, service.ErrInvalidSchedule),
		errors.Is(err, service.ErrUnsupportedType), errors.Is(err, service.ErrFileTooLarge),
		errors.Is(err, service.ErrEmptyFile), errors.Is(err, service.ErrInvalidChangeOrderRef),
		errors.Is(err, service.ErrNoChangeOrderItems):
		httpjson.Error(w, http.StatusBadRequest, err.Error())
	case errors.Is(err, service.ErrStorageFailure):
		writeInternalError(w, err)
	case isInternalError(err):
		writeInternalError(w, err)
	default:
		httpjson.Error(w, http.StatusBadRequest, err.Error())
	}
}
```

**Critical gotcha for the mobile client:** `domain.ErrNotFound` (defined `internal/domain/errors.go:6` as `errors.New("kayıt bulunamadı")`, i.e. generically "record not found") is **always** rendered to the client as the literal string `"proje bulunamadı"` ("project not found") — even when the actually-missing record is a task, schedule item, member, file, photo, or note by ID. **Do not pattern-match on the error message text to distinguish "project missing" from "task missing"** — a `404` here just means "the resource you asked for by that ID/org doesn't exist," full stop; use the HTTP status, not the string.

`isInternalError` (`internal/httpapi/handler/errors.go:25-35`) catches raw Postgres errors (`*pgconn.PgError`), network-level errors, and context cancellation/timeout — these are logged server-side only and rendered to the client as a generic `500 {"error":"beklenmeyen bir sunucu hatası oluştu"}` (`errors.go:40-43`). Raw DB/filesystem error text (table names, absolute paths) never reaches the client — confirmed via `ErrStorageFailure` wrapping in `wrapStorageErr` (`project_operations_service.go:64-70`, only the sentinel `"dosya işlemi sırasında bir hata oluştu"` crosses the boundary).

---

## 3. Money/quantity serialization — the `/calculations/*` exception, verified directly

I did **not** assume this; I grepped `internal/httpapi/handler/calc_handler.go` directly. Confirmed real:

```go
QuantityPerM2      string  `json:"quantity_per_m2"`     // calc_handler.go:243
QuantityPerMeter   string  `json:"quantity_per_meter"`  // :244
FixedQuantity      string  `json:"fixed_quantity"`      // :245
ReferenceUnitPrice string  `json:"reference_unit_price"`// :250
Quantity     string  `json:"quantity"`                  // :432
UnitPrice    string  `json:"unit_price"`                // :434
TotalCost string      `json:"total_cost"`                // :458
```

So yes — `/calculations/*` really does serialize quantity/price/cost fields as **Go `string`**, i.e. **JSON strings, not numbers** (almost certainly to preserve decimal precision without float rounding).

**This exception does NOT apply to any endpoint in this report.** None of the team/schedule/tasks/notes/photos/files/events structs below carry a money or precision-sensitive quantity field — the only numeric fields in this family are `size_bytes` (`int64`), `sort_order` (`int`), `task_count`/`completed_task_count` (`int64`), and `task_completion_ratio` (`float64`), and **all of these are plain Go numeric types with no string-cast** — they serialize as JSON numbers, not strings. (For contrast, the project's own `contract_amount` field in `projectResponse` — `project_finance_handler.go`/`project_handler.go:39` — is `float64` and also serializes as a plain JSON number; the string-money convention is specific to `/calculations/*` only, verified, not a project-wide rule.)

---

## 4. Ekip (Team) — `/api/v1/projects/{id}/members`

### `GET /api/v1/projects/{id}/members`
No query params (no pagination/filter — full list every time; `ListMembers`, `project_operations_handler.go:46-58`).
Response `200`:
```json
{ "members": [ /* memberResponse[] */ ] }
```
`memberResponse` (`project_operations_handler.go:20-29`):
```go
type memberResponse struct {
	ID           string  `json:"id"`
	EmployeeID   string  `json:"employee_id"`
	EmployeeName string  `json:"employee_name"`   // snapshot at assignment time, does not update if employee record changes later
	RoleTitle    string  `json:"role_title"`
	StartDate    *string `json:"start_date"`       // nullable, "YYYY-MM-DD"
	EndDate      *string `json:"end_date"`         // nullable, "YYYY-MM-DD"; null == still active
	Notes        string  `json:"notes"`
	IsActive     bool    `json:"is_active"`         // = (EndDate == nil), computed server-side
}
```

### `POST /api/v1/projects/{id}/members` (assign member) → `201`
Request `assignMemberRequest` (lines 39-44):
```go
type assignMemberRequest struct {
	EmployeeID string  `json:"employee_id"`   // required; must be a valid UUID resolving to an employee in the SAME org, else 400 ErrInvalidEmployee
	RoleTitle  string  `json:"role_title"`    // optional, trimmed
	StartDate  *string `json:"start_date"`    // optional "YYYY-MM-DD"; malformed date is silently dropped to nil (parseDateParam swallows parse errors, project_handler.go:127-136) — NOT a validation error
	Notes      string  `json:"notes"`         // optional, trimmed
}
```
Response: `memberResponse` (same shape as above), `201`.
Business rules (`project_operations_service.go:100-163`):
- Project must be **open** (`requireOpenProject`, see §9) — a `completed`/`cancelled` project rejects new assignments with `409 ErrProjectLocked`.
- Partial-unique-index violation on "one active assignment per employee per project" → `409 {"error":"bu personel zaten projenin aktif ekibinde"}` (`ErrDuplicateMember`).
- Bad/unresolvable `employee_id` → `400 {"error":"geçersiz personel"}` (`ErrInvalidEmployee`).
- Writes a `member_assigned` project event in the same DB transaction as the insert.

### `DELETE /api/v1/projects/{id}/members/{memberId}` (end membership) → `200`
**No request body.** `EndMembership` handler (lines 79-88) always calls the service with a hardcoded `nil` for the optional end-date parameter — even though `service.EndMembership` accepts a custom `endDate *time.Time` (`project_operations_service.go:182`), **the HTTP layer never exposes it**. Effect: ending a membership via this API always stamps `end_date = today` (server clock), you cannot backdate/postdate it through this endpoint.
Response: `memberResponse` reflecting the now-ended member, `200`.
Errors: `404` if member ID doesn't resolve in-org. **No `requireOpenProject` check here** — you can end a membership even on a completed/cancelled project (asymmetric with `AssignMember`).

Not supported: no `GET /members/{memberId}` single-item read (a `GetProjectMember` SQL query exists at `project_operations.sql:15` but is never called from any service method or handler — dead code, not reachable via HTTP).

---

## 5. Planlama (Schedule) — `/api/v1/projects/{id}/schedule`

### `GET /api/v1/projects/{id}/schedule`
No query params. Response `200`: `{"items": [ /* scheduleItemResponse[] */ ]}`.

`scheduleItemResponse` (lines 92-102):
```go
type scheduleItemResponse struct {
	ID                 string  `json:"id"`
	Name               string  `json:"name"`
	Description        string  `json:"description"`
	StartDate          *string `json:"start_date"`   // nullable "YYYY-MM-DD"
	EndDate            *string `json:"end_date"`     // nullable "YYYY-MM-DD"
	Status             string  `json:"status"`        // enum, see below
	SortOrder          int     `json:"sort_order"`
	TaskCount          int64   `json:"task_count"`             // aggregate of tasks linked to this schedule item
	CompletedTaskCount int64   `json:"completed_task_count"`
}
```
**Status enum** (`domain/project_operations.go:5-17`): `"planned" | "active" | "completed" | "cancelled"`. Validated by `domain.ValidScheduleStatus`.

### `POST /api/v1/projects/{id}/schedule` → `201`
### `PUT /api/v1/projects/{id}/schedule/{itemId}` → `200`
Both share `scheduleItemRequest` (lines 113-120):
```go
type scheduleItemRequest struct {
	Name        string  `json:"name"`         // required, trimmed non-empty, else 400 "aşama adı zorunludur"
	Description string  `json:"description"`  // optional
	StartDate   *string `json:"start_date"`   // optional "YYYY-MM-DD"; malformed silently -> nil
	EndDate     *string `json:"end_date"`     // optional "YYYY-MM-DD"; malformed silently -> nil
	Status      string  `json:"status"`
	SortOrder   int     `json:"sort_order"`   // no min/max validation, any int accepted
}
```
**Create vs Update asymmetry (status field):**
- **Create** (`CreateScheduleItem`, service lines 249-300): if `status == ""`, defaults to `"planned"`; otherwise must be one of the 4 valid values or `400 "geçersiz aşama durumu"`. Also requires project open (`requireOpenProject`) — `409 ErrProjectLocked` on completed/cancelled projects.
- **Update** (`UpdateScheduleItem`, lines 318-380): **no default** — empty string fails `ValidScheduleStatus("")` and returns `400 "geçersiz aşama durumu"`. Client **must** always send an explicit valid status on `PUT`. **No `requireOpenProject` check on update** — you can edit schedule items on a locked project.
- Transition side-effect: if the new status is `"completed"` and the previous stored status was not, the service logs a `schedule_completed` event instead of the generic `schedule_updated` event (line 368-370) — purely an audit-log distinction, no extra validation/blocking logic.

Response: `scheduleItemResponse`.
Not supported: no `GET /schedule/{itemId}` single-item read, no `DELETE` for schedule items at all.

---

## 6. Görevler (Tasks) — `/api/v1/projects/{id}/tasks`

### `GET /api/v1/projects/{id}/tasks`
No query params — no pagination, filter, or search on this endpoint (confirmed: `ListTasks` handler just forwards project id + org id). Server-side fixed ordering (`project_operations.sql:63-66`):
```sql
ORDER BY (status = 'completed' OR status = 'cancelled'), due_date ASC NULLS LAST, created_at ASC
```
i.e. open tasks first (grouped ahead of completed/cancelled), then soonest-due first (nulls last), then oldest-created first. **No client-side sort control exists.**

Response `200`: `{"tasks": [ /* taskResponse[] */ ]}`.

`taskResponse` (lines 178-190):
```go
type taskResponse struct {
	ID                 string  `json:"id"`
	ScheduleItemID     *string `json:"schedule_item_id"`      // nullable
	Title              string  `json:"title"`
	Description        string  `json:"description"`
	AssignedEmployeeID *string `json:"assigned_employee_id"`  // nullable
	AssignedName       string  `json:"assigned_name"`         // snapshot, empty string if unassigned
	Priority           string  `json:"priority"`               // enum
	Status             string  `json:"status"`                 // enum
	DueDate            *string `json:"due_date"`               // nullable "YYYY-MM-DD"
	CompletedAt        *string `json:"completed_at"`           // nullable, full RFC3339 timestamp
	IsOverdue          bool    `json:"is_overdue"`             // computed server-side, see below
}
```

**Priority enum** (`domain/project_operations.go:33-45`): `"low" | "normal" | "high" | "urgent"`.
**Status enum** (`domain/project_operations.go:19-31`): `"todo" | "in_progress" | "completed" | "cancelled"`.

`IsOverdue` logic (`domain/project_operations.go:148-153`):
```go
func (t ProjectTask) IsOverdue(now time.Time) bool {
	if t.Status != TaskStatusTodo && t.Status != TaskStatusInProgress {
		return false   // completed/cancelled tasks are NEVER overdue, regardless of due_date
	}
	return IsPastDue(t.DueDate, now)  // calendar-day comparison; due date itself is not yet overdue
}
```

### `POST /api/v1/projects/{id}/tasks` → `201`
### `PUT /api/v1/projects/{id}/tasks/{taskId}` → `200`
Both use `taskRequest` (lines 201-209):
```go
type taskRequest struct {
	Title              string  `json:"title"`                 // required, trimmed non-empty -> else 400 "görev başlığı zorunludur"
	Description        string  `json:"description"`
	ScheduleItemID     *string `json:"schedule_item_id"`      // optional; if non-empty must resolve to a schedule item in SAME org AND SAME project, else 400 ErrInvalidSchedule ("geçersiz planlama aşaması")
	AssignedEmployeeID *string `json:"assigned_employee_id"`  // optional; if non-empty must resolve to an employee in SAME org, else 400 ErrInvalidEmployee ("geçersiz personel")
	Priority           string  `json:"priority"`
	Status             string  `json:"status"`
	DueDate            *string `json:"due_date"`              // optional "YYYY-MM-DD"; malformed silently -> nil
}
```

**Status/priority defaulting asymmetry, verified from `CreateTask` (service lines 429-504) vs `UpdateTask` (lines 522-603):**
- **Create**: `priority == ""` → defaults `"normal"`; `status == ""` → defaults `"todo"`. Both, if non-empty, validated against their enums (`400` on invalid). **Explicit extra rule: a task cannot be created directly with `status: "completed"`** → `400 "görev doğrudan tamamlanmış olarak oluşturulamaz"` (line 454-456). Requires project open (`requireOpenProject`).
- **Update**: **no defaulting at all** — `ValidTaskPriority(in.Priority)` and `ValidTaskStatus(in.Status)` are checked directly against whatever was sent; empty string fails both, giving `400 "geçersiz öncelik"` / `400 "geçersiz görev durumu"`. **The client must always send both fields explicitly and validly on `PUT`.** **No `requireOpenProject` check on update** — tasks can be edited on a locked project.
- **Update has no restriction against setting `status: "completed"` directly** — unlike Create, `PUT` lets you set any valid status including `completed` in one call. The exact SQL (`project_operations.sql:81-93`) keeps `completed_at` consistent with whatever status you send:
  ```sql
  completed_at = CASE WHEN $9::varchar = 'completed'
                      THEN COALESCE(completed_at, now())
                      ELSE NULL END
  ```
  So: setting status to `completed` via `PUT` stamps `completed_at = now()` (or keeps the existing timestamp if it was already completed); setting it to **anything else** (including re-opening a previously-completed task back to `todo`/`in_progress`) **always clears `completed_at` back to `null`**, even if the task had genuinely been completed before.
- Concurrency: `UpdateTask` reads the current row `FOR UPDATE` (`GetTaskForUpdate`, `project_operations.sql:76-80`) specifically to avoid double-firing the `task_completed` audit event under a race.
- Event log side effects on Update (mutually exclusive, in this priority order per `project_operations_service.go:583-594`): `task_completed` if status just became completed; else `task_assigned` if the assignee actually changed; else generic `task_updated`.

### `POST /api/v1/projects/{id}/tasks/{taskId}/complete` → `200`
No request body. `CompleteTask` (service lines 608-655) — the **idempotent** convenience path:
```sql
UPDATE project_tasks SET status='completed', completed_at=now()
WHERE id=$1 AND organization_id=$2 AND status <> 'completed'
```
- If already completed by the time this runs (0 rows affected — e.g. a concurrent duplicate request), the service does **not** error: it re-reads the existing row within the same transaction and returns it as-is, **without** writing a second `task_completed` event. So calling `complete` twice is safe and always returns `200` with the (already-)completed task — never a conflict error.
- On the actual first completion, a `task_completed` event is logged.
- **No `requireOpenProject` check** — you can complete a task on a locked project.
- Response: `taskResponse`, `200`.

**Concurrency summary you should tell the mobile team:** `requireOpenProject` (project-locked guard) is applied on **Create** for members/schedule-items/tasks/files/photos, but is **not** applied on any Update/Delete/Complete/EndMembership path in this whole family — i.e. once a project is `completed`/`cancelled`, you can no longer add new team members, schedule stages, tasks, files, or photos, but you can still edit/complete/remove existing ones.

Not supported: no `GET /tasks/{taskId}` single-task read, no `DELETE` for tasks.

---

## 7. Fotoğraflar (Photos) — `/api/v1/projects/{id}/photos`

### `GET /api/v1/projects/{id}/photos`
No query params. Response `200`: `{"photos": [ /* photoResponse[] */ ]}`.

`photoResponse` (lines 395-404):
```go
type photoResponse struct {
	ID           string  `json:"id"`
	OriginalName string  `json:"original_name"`
	MIMEType     string  `json:"mime_type"`
	SizeBytes    int64   `json:"size_bytes"`
	Stage        string  `json:"stage"`          // enum
	Description  string  `json:"description"`
	TakenAt      *string `json:"taken_at"`       // nullable, RFC3339 (see gotcha below)
	CreatedAt    string  `json:"created_at"`     // RFC3339
}
```
**Stage enum** (`domain/project_operations.go:62-72`): `"before" | "progress" | "after"`.
**Note: no `sha256` field on photos** (unlike files, below) — dedup by content-hash still happens server-side, it's just not surfaced in this response.

### `POST /api/v1/projects/{id}/photos` (multipart upload) → `201`
- **Multipart field name for the binary content: `file`** — same as document uploads (`r.FormFile("file")`, `project_operations_handler.go:305`). There is no separate field name for photos.
- Other multipart form fields read (via `r.FormValue`, `project_operations_handler.go:309-312`): `category`, `stage`, `description`, `taken_at` — **all four are always parsed by the shared `readUpload` helper regardless of endpoint**, but the photo handler (`UploadPhoto`, lines 428-451) only actually **uses** `stage`, `description`, `taken_at` (a submitted `category` field is silently ignored on this endpoint).
- `stage`: optional; empty → defaults `"progress"` (service line 873-875); if non-empty, must be a valid stage value or `400 "geçersiz fotoğraf aşaması"`.
- `taken_at`: optional; **must be exactly `"YYYY-MM-DD"` (date-only)** — parsed with `time.Parse(dateLayout, ...)` (handler lines 435-439) where `dateLayout = "2006-01-02"`. **A malformed value is silently dropped to `nil` — no error is raised.** Confirmed the input format is date-only but the DB column is `timestamptz` (`TimePtrToTimestamptz`, `repository/pool.go:413`) and the **response formats it as full RFC3339** (`tsStrPtr`, `project_finance_handler.go:34-40`, uses `rfc3339 = "2006-01-02T15:04:05Z07:00"`) — so a client that sends `taken_at: "2024-03-01"` will get back `"taken_at": "2024-03-01T00:00:00Z"`. **Tell the mobile team: send date-only on upload, expect full timestamp on read-back.**
- Response: `photoResponse`, `201`.

### `GET /api/v1/projects/{id}/photos/{photoId}/content` (content/view, not "download")
`DownloadPhoto` handler (lines 453-468) — despite being asked about `.../content`, this is the actual registered route (`router.go:204`), name in code is `DownloadPhoto` but the route path segment is literally `content`, not `download`. Streams raw bytes with headers:
```go
w.Header().Set("Content-Type", p.MIMEType)
w.Header().Set("X-Content-Type-Options", "nosniff")
w.Header().Set("Content-Length", fmt.Sprintf("%d", p.SizeBytes))
w.Header().Set("Cache-Control", "private, max-age=300")
```
**No `Content-Disposition` header** (unlike file download, below) — intentionally inline so it can be used directly as an `<img src>` / mobile image loader target; `nosniff` still prevents content-type confusion. Errors: `404` if not found/wrong org (`OpenFile`-equivalent org-scoped lookup means a cross-tenant UUID guess returns 404, never leaks a byte — this is explicitly commented in source for the file variant and identical logic for photo).

### `DELETE /api/v1/projects/{id}/photos/{photoId}` → `200`
Soft-delete (`SoftDeleteProjectPhoto`). Response: `{"ok": true}` (`map[string]bool`). Logs a `photo_removed` event. No `requireOpenProject` check.

Not supported: no `GET /photos/{photoId}` metadata-only endpoint (only the binary-content route exists), no update/edit-metadata endpoint for an already-uploaded photo.

---

## 8. Dosyalar (Files) — `/api/v1/projects/{id}/files`

### `GET /api/v1/projects/{id}/files`
No query params. Response `200`: `{"files": [ /* fileResponse[] */ ]}`.

`fileResponse` (lines 278-287):
```go
type fileResponse struct {
	ID           string `json:"id"`
	OriginalName string `json:"original_name"`
	MIMEType     string `json:"mime_type"`
	SizeBytes    int64  `json:"size_bytes"`
	SHA256       string `json:"sha256"`
	Category     string `json:"category"`   // enum
	Description  string `json:"description"`
	CreatedAt    string `json:"created_at"` // RFC3339
}
```
**Category enum** (`domain/project_operations.go:47-60`): `"contract" | "drawing" | "invoice" | "report" | "other"`.

### `POST /api/v1/projects/{id}/files` (multipart upload) → `201`
- **Multipart field name: `file`** (identical helper as photos, `readUpload`).
- Additional form fields used by this endpoint: `category`, `description` (a submitted `stage`/`taken_at` is parsed by the shared helper but simply unused here).
- `category`: optional; empty → defaults `"other"`; non-empty must be a valid category or `400 "geçersiz dosya kategorisi"`.
- `imagesOnly = false` for this endpoint (`storeUpload(..., false)`, service line 743) — accepted content types (server-detected, see §9) are the general document allowlist **or** any `image/*`.
- Response: `fileResponse`, `201`.

### `GET /api/v1/projects/{id}/files/{fileId}/download`
`DownloadFile` (lines 352-361) → `serveAttachment` (lines 377-391):
```go
w.Header().Set("Content-Type", mimeType)
w.Header().Set("X-Content-Type-Options", "nosniff")
w.Header().Set("Content-Length", fmt.Sprintf("%d", size))
w.Header().Set("Content-Disposition", fmt.Sprintf("attachment; filename=%q", safe))
```
`safe` strips `"`, `\`, `\r`, `\n` from the original filename before embedding it in the header (header-injection defense). This is a true "save as attachment" response, unlike the photo `content` endpoint.

### `DELETE /api/v1/projects/{id}/files/{fileId}` → `200`
Soft-delete. Response: `{"ok": true}`. Logs `file_removed` event.

Not supported: no `GET /files/{fileId}` metadata-only endpoint, no metadata-edit endpoint post-upload.

---

## 9. Upload internals shared by files + photos — exact 25 MiB enforcement chain

Multipart field name is **`file`** for both endpoints (`r.FormFile("file")`, `project_operations_handler.go:305`) — this is the one and only field name a mobile multipart client needs to use for the binary part on both `POST /files` and `POST /photos`.

`MaxUploadBytes = 25 << 20` (`internal/service/project_operations_service.go:39`) — exactly 25 MiB = 26,214,400 bytes.

Three distinct enforcement layers, in order, each producing a **different** client-visible outcome:

1. **Whole-request body cap** — `project_operations_handler.go:301`:
   ```go
   r.Body = http.MaxBytesReader(w, r.Body, service.MaxUploadBytes+1024)
   ```
   Caps the *entire* multipart request (headers + boundaries + form fields + file bytes) at 25 MiB + 1 KiB. If exceeded, `r.ParseMultipartForm` (`:302`) errors, and the handler returns `400 {"error":"dosya okunamadı: <wrapped parse error>"}`.
2. **File-content read cap during MIME sniffing** — `internal/service/project_operations_service.go:674`:
   ```go
   mime, body, n, err := sniffMIME(io.LimitReader(r, MaxUploadBytes+1))
   ```
   The actual file reader handed to storage is truncated to 25 MiB + 1 byte, regardless of what the client claims.
3. **Post-write hard check** — `project_operations_service.go:700-703`:
   ```go
   if obj.Size > MaxUploadBytes {
       _ = s.store.Delete(ctx, key)
       return storage.Object{}, "", ErrFileTooLarge
   }
   ```
   This is the **actual, documented 25 MiB business-rule enforcement point.** Note it runs *after* the object was already written to disk via `s.store.Put` — an over-limit file briefly touches disk and is then deleted before any DB row is created, so nothing oversized is ever persisted or returned to the client. This maps to `400 {"error":"dosya boyutu sınırı aşıldı"}` via the `ErrFileTooLarge` sentinel in `writeError`.

Additional upload validation (`storeUpload`, lines 673-706):
- **Empty body (0 bytes actually read) → `400 {"error":"boş dosya yüklenemez"}`** (`ErrEmptyFile`) — checked *before* anything is written to storage.
- **Content-type is never trusted from the client** — it's sniffed server-side from the first 512 bytes via `http.DetectContentType` (`sniffMIME`, lines 75-88), and the client-supplied `Content-Type` header on the multipart part is ignored entirely.
- Allowed types for **files** (`allowedFileTypes`, lines 44-55): `application/pdf`, `image/jpeg`, `image/png`, `image/gif`, `image/webp`, `text/plain`, `application/zip` (covers `.xlsx`/`.docx`, which are zip containers), `text/csv`, `application/rtf`, `application/msword` — **plus** any sniffed `image/*` (via the `|| strings.HasPrefix(mime, "image/")` fallback at line 689). Anything else → `400 {"error":"bu dosya türü kabul edilmiyor"}` (`ErrUnsupportedType`).
- Allowed types for **photos**: `imagesOnly=true` → sniffed MIME **must** start with `image/`, no exceptions, else the same `ErrUnsupportedType` `400`.
- **Content-based dedup**: SHA-256 of the stored content is computed by the storage layer; a duplicate upload to the *same project* (unique constraint on `(project_id, sha256)`) does **not** error — the service silently deletes the just-written duplicate object and returns the **pre-existing** file/photo record instead (`isUniqueViolation` branch, e.g. lines 761-777 for files, 918-932 for photos), still with a `201` status. The client cannot distinguish "newly stored" from "matched an existing upload" from the HTTP status alone — only by comparing the returned `id`/`created_at` against what it expects.
- File/photo names longer than 255 runes are silently truncated (lines 724-726, 884-886), not rejected.

---

## 10. Notlar (Notes) — `/api/v1/projects/{id}/notes`

### `GET /api/v1/projects/{id}/notes`
No query params. Response `200`: `{"notes": [ /* noteResponse[] */ ]}`.

`noteResponse` (lines 482-487):
```go
type noteResponse struct {
	ID            string `json:"id"`
	Content       string `json:"content"`
	CreatedByName string `json:"created_by_name"`  // snapshot of the author's name at creation time; empty string if unresolvable
	CreatedAt     string `json:"created_at"`        // RFC3339
}
```

### `POST /api/v1/projects/{id}/notes` → `201`
Request `noteRequest` (lines 496-498):
```go
type noteRequest struct {
	Content string `json:"content"`  // required; trimmed; empty -> 400 "not içeriği boş olamaz"
}
```
Response: `noteResponse`, `201`.

**Confirmed gap — not just "unsupported," but half-built on the backend:** `internal/repository/queries/project_operations.sql` defines both `-- name: UpdateProjectNote :one` (line 181) and `-- name: DeleteProjectNote :execrows` (line 186), and sqlc generated the corresponding Go functions in `internal/repository/sqlc/project_operations.sql.go`. I grepped every service and handler file in the repo (`grep -rn "UpdateNote\|DeleteNote\|UpdateProjectNote\|DeleteProjectNote" internal/service internal/httpapi`) and got **zero matches** — no service method calls these generated functions, no handler exists, no route is registered. **`PUT`/`DELETE` on a note is `NOT SUPPORTED — no endpoint found`, even though the SQL plumbing for it exists in the database layer.** Flag this precisely as "DB query written, never wired up" rather than "feature doesn't exist at all," in case product wants it turned on cheaply later — but today, notes are create+list only, permanently immutable and undeletable via the API.

---

## 11. Project events / activity log — `GET /api/v1/projects/{id}/events`

This **does** exist (route at `router.go:154`, registered at the top of the `/projects` group, not under the "Faz 7" comment block — it predates the operational sub-resources and is shared with the Faz 6 finance module). Handler: `ListEvents` (`project_finance_handler.go:684-699`).

No query params (no pagination, no `event_type` filter, no date-range filter — full history every call).

Response `200`: `{"events": [ /* projectEventResponse[] */ ]}`.

`projectEventResponse` (`project_finance_handler.go:676-682`):
```go
type projectEventResponse struct {
	ID        string         `json:"id"`
	EventType string         `json:"event_type"`
	UserID    *string        `json:"user_id"`             // nullable (system-generated events may have no actor)
	Metadata  map[string]any `json:"metadata,omitempty"`  // free-form JSON object, shape varies per event_type
	CreatedAt string         `json:"created_at"`           // RFC3339
}
```
Backing domain struct `ProjectEvent` (`internal/domain/project_finance.go:302-310`) matches 1:1.

**This is a single unified timeline** — the code comment at `domain/project_operations.go:74-76` is explicit that Faz 7 operational events are written into the **same** `project_events` table as Faz 6 financial events, specifically so the mobile/web client gets one chronological feed. `event_type` values relevant to this operations family (`domain/project_operations.go:77-91`):
```
member_assigned, member_removed,
schedule_created, schedule_updated, schedule_completed,
task_created, task_assigned, task_completed, task_updated,
file_uploaded, file_removed,
photo_uploaded, photo_removed,
note_added
```
(Plus finance-domain event types from Faz 6/8 not covered by this task, which will also appear interleaved in the same feed — the mobile client should treat `event_type` as an open string enum and handle unknown values gracefully, e.g. render a generic fallback row, since finance/change-order event types will show up here too.)

**`Metadata` shape is not type-safe/documented per event — it's `map[string]any` built ad hoc at each call site.** From reading every `logProjectEvent(...)` call in `project_operations_service.go`, the keys actually written per event type are:
- `member_assigned`: `{"member_id": string, "employee_name": string, "role": string}`
- `member_removed`: `{"member_id": string, "employee_name": string}`
- `schedule_created`: `{"schedule_item_id": string, "name": string}`
- `schedule_updated` / `schedule_completed`: `{"schedule_item_id": string, "name": string, "status": string}`
- `task_created`: `{"task_id": string, "title": string}`
- `task_assigned`: `{"task_id": string, "title": string, "employee_name": string}`
- `task_completed`: `{"task_id": string, "title": string}`
- `task_updated`: `{"task_id": string, "title": string, "status": string}`
- `file_uploaded`: `{"file_id": string, "name": string, "category": string}`
- `file_removed`: `{"file_id": string, "name": string}`
- `photo_uploaded`: `{"photo_id": string, "stage": string}`
- `photo_removed`: `{"photo_id": string}`
- `note_added`: `{"note_id": string}`

These are **not** separate Go structs per event, so there is no compile-time contract for the mobile client to bind to — it must treat `metadata` as a loosely-typed dictionary and look up keys defensively per `event_type`.

---

## 12. Operasyon Özeti (Operations summary) — `GET /api/v1/projects/{id}/operations-summary`

No query params. Response `200` (plain `map[string]any`, no named struct — `OperationsSummary` handler, `project_operations_handler.go:532-547`):
```json
{
  "active_member_count":   0,
  "total_task_count":      0,
  "open_task_count":       0,
  "overdue_task_count":    0,
  "completed_task_count":  0,
  "task_completion_ratio": 0
}
```
Backing type `ProjectOperationsSummary` (`domain/project_operations.go:199-206`) — all `int64` except `task_completion_ratio` which is `float64`.

**Naming gotcha, verified from `project_operations_service.go:1110-1113`:**
```go
ratio := 0.0
if stats.Total > 0 {
    ratio = float64(stats.CompletedCount) / float64(stats.Total) * 100
}
```
Despite the field being named `task_completion_ratio`, it is **already multiplied by 100** — i.e. it's a **percentage** (0–100 range, e.g. `66.66...`), not a 0–1 fraction. Render it directly as `"66.7%"`, do **not** multiply by 100 again in the mobile app.

`total_task_count` excludes cancelled tasks (`COUNT(*) FILTER (WHERE status <> 'cancelled')`, `project_operations.sql:100-108`); `open_task_count` = `todo + in_progress`; `overdue_task_count` = open tasks with a past-due `due_date` (calendar-day comparison, `due_date < CURRENT_DATE`, matching the domain-level `IsOverdue` semantics described in §6); `active_member_count` counts only members with `end_date IS NULL`.

---

## 13. Full route table (method, path, auth, handler)

All under `requireAuth` only, base `/api/v1/projects`:

| Method | Path | Handler |
|---|---|---|
| GET | `/{id}/operations-summary` | `OperationsSummary` |
| GET | `/{id}/members` | `ListMembers` |
| POST | `/{id}/members` | `AssignMember` |
| DELETE | `/{id}/members/{memberId}` | `EndMembership` |
| GET | `/{id}/schedule` | `ListScheduleItems` |
| POST | `/{id}/schedule` | `CreateScheduleItem` |
| PUT | `/{id}/schedule/{itemId}` | `UpdateScheduleItem` |
| GET | `/{id}/tasks` | `ListTasks` |
| POST | `/{id}/tasks` | `CreateTask` |
| PUT | `/{id}/tasks/{taskId}` | `UpdateTask` |
| POST | `/{id}/tasks/{taskId}/complete` | `CompleteTask` |
| GET | `/{id}/files` | `ListFiles` |
| POST | `/{id}/files` | `UploadFile` |
| GET | `/{id}/files/{fileId}/download` | `DownloadFile` |
| DELETE | `/{id}/files/{fileId}` | `DeleteFile` |
| GET | `/{id}/photos` | `ListPhotos` |
| POST | `/{id}/photos` | `UploadPhoto` |
| GET | `/{id}/photos/{photoId}/content` | `DownloadPhoto` |
| DELETE | `/{id}/photos/{photoId}` | `DeletePhoto` |
| GET | `/{id}/notes` | `ListNotes` |
| POST | `/{id}/notes` | `CreateNote` |
| GET | `/{id}/events` | `ListEvents` (shared with finance module) |

(All exact registrations: `internal/httpapi/router.go:154, 182-208`.)

**No cross-project task endpoint exists anywhere in the router** (see §0) — this is the one explicit gap to relay back verbatim to whoever is designing the "görevlerim" mobile screen.