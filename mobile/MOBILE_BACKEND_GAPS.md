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

## 2. ~~No organization name/id anywhere in the API~~ — RESOLVED
`GET /auth/me` (and login/refresh) now returns `organization_id`,
`organization_name`, `organization_role_code`, `organization_role_name`,
`must_change_password`, `onboarding_completed`, `onboarding_step`, and
`permissions` alongside the original fields (super-admin + RBAC/onboarding
phases) — see `mobile/lib/features/auth/domain/user.dart`. `role` remains a
coarse platform/tenant axis (`admin|kullanici|super_admin`); it is NOT the
same axis as `organization_role_code` (`owner|admin|project_manager|
finance|field|legacy_user|...`) — see API_CONTRACT.md#auth. No further
action needed here; keeping the entry so the history of the gap (and its
fix) isn't lost.

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

## 5. No staff-side approve/reject for PROJECT-level change orders
Scope narrowed 2026-09-22 — this gap is specific to **project-level**
change orders (revenue-side, offer/contract amendments). Approval/rejection
there only happens through the unauthenticated public link (`POST
/api/v1/public/change-orders/{token}/respond`); no authenticated "mark as
approved" action for staff exists. Mobile's Finans tab now DOES surface
these read-only (`_ChangeOrdersTab` in `project_detail_screen.dart`) — the
"not yet surfaced" framing this entry originally had is stale, only the
"no staff approve/reject" part of the gap is still current. Separately,
**subcontract-level** change orders (cost-side) are a DIFFERENT feature
with their OWN authenticated staff approve/reject action
(`POST .../subcontract-change-orders/{id}/approve|reject`, full mobile
create/edit/detail screens) — do not conflate the two when reasoning about
this gap.

## 6. Notes are create+list only
`internal/repository/queries/project_operations.sql` defines
`UpdateProjectNote`/`DeleteProjectNote` and sqlc generated the Go functions,
but no service method or route wires them up. `PUT`/`DELETE` on a project
note is not reachable via HTTP today, even though the DB layer supports it.

## 7. No void-reason field for PROJECT-level change orders
Same scope narrowing as #5 — this is specific to project-level change
orders. Unlike collections/expenses/subcontractor-payments (which all take
`{reason}` on void), `CancelChangeOrder` takes no request body at all —
there is no `VoidedAt`/`VoidReason` on `domain.ChangeOrder`. Mobile's
read-only Finans tab view doesn't offer a cancel action at all (staff
cancellation isn't built for these), so this remains not directly
applicable today, but the "change orders aren't yet surfaced" premise is
stale (see #5) — kept accurate for if/when a staff-side cancel action is
added here.

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

## 13. Project modules added in 1.4.0+5 — backend gaps found (not changed)
Found while bringing the web's project page to mobile (contract, change
orders, budget/cost control, payment plan, invoices, schedule, team,
access, legacy subcontractor payments, activity). The app works around
each one; none needs a mobile change once fixed server-side.
- **Change orders:** no email-log list endpoint (history is read from
  project `events`); detail GET has no profitability (merged from the list
  row); cancel takes no reason (see §7).
- **Invoices:** no field-edit endpoint (only POST + `PUT .../status`), no
  status state machine (any status, including un-cancelling), no
  single-invoice GET.
- **Payment plan:** no single-item GET, no restore for a cancelled item;
  `DELETE` on a missing/already-cancelled item answers "proje bulunamadı".
- **Lock rule is UI-only** for `DELETE /payment-plan/{id}` and
  `PUT /invoices/{id}/status` (no `requireOpenProject`); contract
  Complete/Terminate is allowed on a closed project by design.
- **Schedule:** no DELETE — items are set to `cancelled`.
- **Commitments:** `POST /commitments/{id}/void` does not check
  `source_type`, so purchase-order/subcontract commitments can be voided via
  API/web (contradicts docs/cost-control.md §5); the app only offers void on
  manual ones.
- **Budget:** `GET /budget` and `GET /budget/lines` return 404 both for "no
  budget" and "project not found".
- **Permissions text:** `projects.cost_control.manage`'s description names
  WBS, but router.go gates WBS writes with `projects.budget.manage`.
- **Money leak (already in HANDOFF §8):** `GET /projects/{id}/events`
  returns `amount`/`planned_amount`/`contract_amount`/`grand_total` to users
  without `projects.finance.read`; the app hides them client-side.
- **Revenue in cost control:** `GET /projects/{id}/cost-control` returns
  `contract_value`, `forecast_profit` and `forecast_margin_percent` to
  anyone with `projects.cost_control.read` (the default Proje Yöneticisi
  role has it, but not `projects.finance.read`). The app shows cost figures
  (budget, EAC, commitments, actuals, variance) under cost-control/budget
  permissions and hides the three revenue/profit fields without
  finance.read (2026-09-29 review fix). Server-side fix: null them without
  finance.read, like the dashboard does.
- **Change-order share token:** the list/detail response carries
  `active_share_token` under `projects.finance.read`. That token lets whoever
  opens `/ek-is/{token}` approve or reject the change order as the customer.
  The app shows/copies the link only with `projects.finance.manage`; the
  token itself should be returned only to finance.manage.
- **Pickers need org-level permissions:** "Ekibe Ekle" needs
  `GET /employees` (`employees.read`) and "Erişim Ver" needs `GET /users`
  (`requireAdmin` + `organization.users.read`). The default Proje Yöneticisi
  / Saha roles have `projects.operations.manage` but not `employees.read`,
  so the app hides these buttons (with a note) instead of opening a picker
  that can never load. A project-scoped option list (e.g.
  `GET /projects/{id}/member-options`) would let them add team members.
- **Legacy subcontractor create has no idempotency key**
  (`POST /projects/{id}/subcontractors`); a retried or double-submitted
  request creates a duplicate. The app blocks closing the sheet while the
  request is in flight.
