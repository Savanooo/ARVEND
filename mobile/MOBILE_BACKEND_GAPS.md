# ARVEND Mobile — Backend Gaps

Confirmed by reading the Go backend source directly (not inferred). No fake
data, fake endpoints, or hardcoded "success" responses were used as a
substitute for any of these — where the backend doesn't support something,
the mobile app either omits the feature or clearly derives an approximation
client-side (marked below).

## 1. ~~No cross-project "my tasks" endpoint~~ — RESOLVED
`GET /api/v1/tasks/mine?status=` now exists (single query, scoped to the
caller's linked employee, `status` in `open|all|todo|in_progress|
completed|cancelled`) and the mobile "Görevlerim" screen
(`features/tasks/data/tasks_providers.dart`) has consumed it — not the O(N)
per-project loop — since before this entry was last verified. No further
action needed here; keeping the entry so the history of the gap (and its
fix) isn't lost.

## 2. No organization name/id anywhere in the API
`GET /auth/me` returns `id, username, full_name, role, is_active` only —
no `organization_id`, no org name. `domain.Organization` and
`organization_service.go` exist server-side but no `/api/v1/organizations*`
route is registered. The Profile screen cannot show a company name.
Proposed: add `organization_name` to `userResponse`, or a minimal
`GET /api/v1/organizations/me`.

## 3. No server-side search/filter on `GET /offers/`
Only `filter=pasif`, `page`, `limit` are read. No `q`, `status`, `customer_id`,
or date-range params exist (unlike `/projects`, which has several). The
Offers list screen filters status and free-text search **client-side** on
the page of data already fetched — this is not a full-catalog search.
Proposed: mirror `/projects`' `q`/`status` params on `/offers`.

## 4. No text search on `/employees`; `/customers` search is name-only
`GET /customers?q=` matches only the `name` column (`ILIKE`), never phone/
email/tax fields. `GET /employees` has no `q` param at all, only
`filter=aktif|pasif`. The mobile customer search box is honest about this
(searches name only); no employee search box was built since none would
work.

## 5. No staff-side approve/reject for change orders
Change order approval/rejection only happens through the unauthenticated
public link (`POST /api/v1/public/change-orders/{token}/respond`). There is
no authenticated "mark as approved" action for staff. Not built into the
mobile app's Finans tab change-order view (change orders are not yet
surfaced in the mobile UI at all, beyond the customer link staff already
send from elsewhere).

## 6. Notes are create+list only
`internal/repository/queries/project_operations.sql` defines
`UpdateProjectNote`/`DeleteProjectNote` and sqlc generated the Go functions,
but no service method or route wires them up. `PUT`/`DELETE` on a project
note is not reachable via HTTP today, even though the DB layer supports it.

## 7. No void-reason field for change orders
Unlike collections/expenses/subcontractor-payments (which all take
`{reason}` on void), `CancelChangeOrder` takes no request body at all —
there is no `VoidedAt`/`VoidReason` on `domain.ChangeOrder`. Not applicable
to the current mobile UI (change orders aren't yet surfaced), noted for
when they are.

## 8. Attendance is pure manual entry — confirmed no GPS/geofence
`domain.AttendanceLog` has no location fields anywhere. `POST/PUT
/attendance` takes free-text `check_in`/`check_out` strings and a numeric
`work_hours` the caller must compute — the backend never derives hours from
times. There is no separate "check-in" vs "check-out" call. The mobile
Mesai screen reflects this exactly: one form creates/edits one full day's
record; no clock-in/clock-out buttons were built since the backend has no
such action.

## 9. `/settings/*` is entirely admin-only, no per-user settings resource
Confirmed zero non-admin-accessible settings endpoint exists anywhere. No
mobile Settings screen was built for regular users, since there is nothing
for the app to call.

## 10. `calc_snapshot` has no server-enforced schema
`offer_revision_items.calc_snapshot` is `json.RawMessage` end-to-end — the
backend never validates or types it. The shape the mobile app writes
(`recipe_item_id`, `category_id`, `category_name`, `footprint_area`,
`effective_area`, `perimeter`, `calculation_type`, `factor`, `waste_percent`,
`rounding_type`, `price_at_calc`) is a **client convention**, not a backend
contract — matches the intent described in the domain code comment but
isn't enforced.

## 11. `calc_category_id`/`product_id` cross-org references fail silently
If a mobile client (bug, stale cache, or race) submits an offer item with a
`calc_category_id` or `product_id` that turns out not to belong to the
caller's organization, the backend **silently drops it to `null`** instead
of returning a 400. A round-trip GET after such a POST can show fewer
populated fields than were sent, with no error surfaced. Documented here
because it's easy for a client author to miss; not something the mobile
app can detect without comparing before/after.

## 12. No task-scoped comments/attachments; task creator is tracked but never returned
`project_tasks` has no comment/note/attachment relation at all — project-
level notes (`project_notes`) exist but carry no `task_id`, and project-
level files (`project_files`) likewise aren't linked to a task. Mobile does
not build a task comment/attachment feature because there is nothing on
the backend to call. Separately: `project_tasks.created_by` is written on
insert and present on the raw SQL row, but `repository.ToDomainTask`
(`internal/repository/project_operations.go`) never copies it into
`domain.ProjectTask`, so `created_by` — and `created_at`/`updated_at` on
the task's own row — never reach `taskResponse` at all. The mobile task
detail screen has no "creator"/"created" fields since the API has none to
show; not invented client-side.
