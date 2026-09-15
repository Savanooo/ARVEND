# ARVEND API Contract — Mobile Client Reference

Derived from a full read of the Go backend source (workflow run, 2026-09-15). Full
per-domain deep-dives with file:line citations are in `.contract-source/*.md`
(auth, offers, projectsFinance, operations, calculations, customersAttendance) —
consult those before implementing anything not summarized here.

Base: `https://app.arvendyapi.com.tr/api/v1`. Auth: httpOnly cookies
(`access_token` 15min, `refresh_token` 30d, rotated), never a Bearer header.
Every error body is `{"error": "<turkish message>"}` (sometimes `Content-Type:
text/plain` on 401/403 from raw `http.Error` — JSON-decode regardless).
`DisallowUnknownFields()` on every request decode — never send extra JSON keys.

## Money/quantity serialization — THREE different conventions, verified

| Domain | Convention |
|---|---|
| `/offers/*`, `/projects/*` (incl. finance/change-orders), `/employees`, `/attendance` | plain JSON **numbers** (float64) |
| `/calculations/*` (recipe items + `/run`) | JSON **strings** (`"100.00"`) — deliberate decimal-safety |

Mobile never does financial arithmetic — all totals come from the backend as-is.

## Auth
- `POST /auth/login` `{username, password}` → 200 `User` (id, username, full_name, role, is_active). 401 wrong creds, 403 inactive.
- `POST /auth/refresh` no body (reads refresh_token cookie) → 200 `User` + new cookies. ANY non-200 clears both cookies server-side — treat as full logout.
- `POST /auth/logout` no body → revokes refresh token.
- `GET /auth/me` → `User`. **No organization_id/name anywhere in the API** (gap).
- `PATCH /users/me/password` `{current_password, new_password}` → `{ok:true}`. New password >= 8 chars.

## Offers (`requireAuth`, no admin gate)
- `GET /offers/` — params: `filter=pasif|*`, `page`, `limit` (max 200). **No search/status/date filter server-side.** List rows never include `items`.
- `GET/PUT /offers/{id}`, `POST /offers/` (create), `POST /offers/{id}/revise`, `GET /offers/{id}/revisions[/{revisionId}]`, `PUT /offers/{id}/status`, `POST /offers/{id}/toggle-passive`, `DELETE /offers/{id}`, `POST /offers/{id}/send-email`, share-links CRUD, `/events`, `/email-logs`.
- Status enum (exact, Turkish): `taslak`, `gönderildi`, `kabul edildi`, `reddedildi`. Once `kabul edildi`, locked forever (no further status change, no delete).
- Item fields: `product_id`(nullable), `product_name`, `quantity`(number), `unit_price`(number), `line_total`(number, server-computed), `unit`, `section_label`, `calc_category_id`, `calc_snapshot`(opaque JSON) — last 4 `omitempty`.
- Create validation: >=1 item after dropping blank-name/qty<=0/price<0 rows; `customer_id` OR free-text `customer_name` required; `vat_rate` omit→20%, explicit 0 respected.
- **Conversion to project is NOT under `/offers`** — it's `POST /projects/from-offer/{offerId}`, requires current revision `status == kabul edildi`, idempotent. Check-if-converted: `GET /offers/{id}/project` (404 = not yet).

## Projects (`requireAuth`, no admin gate)
- `GET /projects` — params: `status`, `customer_id`, `project_type`, `currency`, `start_from`, `q` (ILIKE name/no/customer), `page`, `limit`. List rows DO include finance aggregate fields (current_contract_value etc).
- `GET/PUT /projects/{id}` — **finance aggregate fields are ABSENT here** (omitempty, always nil on single-object reads). Must call `/financial-summary` separately.
- `GET /projects/{id}/financial-summary` → 21 always-present number fields: `current_contract_value`, `collected_amount`, `remaining_receivable`, `realized_cost`, `committed_cost` (closest to "estimated cost"), `estimated_gross_profit`, etc. This is the authoritative source for the finance screen header.
- Status machine: `planned→{active,paused,cancelled}`, `active→{paused,completed,cancelled}`, `paused→{active,completed,cancelled}`, `completed→active only`, `cancelled` terminal.
- No plain POST/DELETE on projects.

### Finance sub-resources (all under `/projects/{id}/...`)
- `payment-plan` (GET/POST/PUT/DELETE-soft), `collections` (GET/POST/void), `expenses` (GET/POST/PUT/void), `invoices` (GET/POST/PUT status), `subcontractors` + `subcontractor-payments` (GET/POST/PUT/void).
- Expense create `{category, description, amount, currency, expense_date, supplier_name, invoice_no, notes, idempotency_key, change_order_id}`. `category` ∈ `material|personnel|transport|accommodation|food|equipment|other`. Void via `POST .../{id}/void {reason}`.
- `change-orders`: state machine `draft→sent→{approved(final),rejected}`, `sent|rejected→(revise)→superseded+new draft`, `draft|sent→(cancel)→cancelled`. **No staff approve/reject endpoint** — only via public link. **Cancel takes no reason body.**

### Operations sub-resources (all under `/projects/{id}/...`)
- `members` (GET/POST/DELETE-end), `schedule` (GET/POST/PUT, no DELETE), `tasks` (GET/POST/PUT/POST .../complete, no DELETE, **no cross-project endpoint — gap**), `photos` (GET/POST multipart field `file`/GET .../content/DELETE), `files` (same pattern, .../download has Content-Disposition), `notes` (GET/POST only — no PUT/DELETE despite SQL existing), `events` (GET, shared timeline with finance), `operations-summary` (GET — `task_completion_ratio` is ALREADY ×100, a percentage).
- Upload: multipart field name `file` for both files and photos. 25 MiB hard cap (`ErrFileTooLarge` after write+delete). Content-type sniffed server-side, client header ignored. Photos: `stage` (before|progress|after), `taken_at` send date-only, get back full RFC3339. Files: `category` (contract|drawing|invoice|report|other).
- Task priority: `low|normal|high|urgent`. Task status: `todo|in_progress|completed|cancelled`. Create cannot set status=completed directly.

## Calculations (`requireAuth`; group/category/recipe-item CUD is `requireAdmin`)
- `GET /calculations/groups` → active groups only.
- `GET /calculations/categories?group_id=X` → flat active categories in that group. `GET /calculations/categories` (no param) → nested `{groups:[{...,categories:[...]}]}` cascade shape — **response shape differs by presence of the query param.**
- `GET /calculations/recipe-items?category_id=X` (required param) → ALL items (active+inactive), any authed role.
- `POST /calculations/run` `{category_id, area?, width?, height?, perimeter?, pitch_deg?}` — all numeric inputs are `string`, all optional except category_id, but **if sent, must be > 0** (0 or negative is a hard error, not "treat as absent"). Area resolution: `area` wins, else needs BOTH width+height. Perimeter resolution independent: explicit wins, else derived only from width+height (never from area alone).
- Response: `{category, input:{footprint_area,effective_area,perimeter}, items:[{recipe_item_id,material_name,unit,quantity,product_id?,unit_price,line_total,group_name?,calculation_type,factor,waste_percent,rounding_type}], total_cost, warnings:[{item_id,code,message}]}`. **Every numeric field here is a JSON string.**
- Warning codes: `perimeter_missing`, `unknown_calculation_type`, `product_missing`, `product_zero_price`.
- **No "convert calc to offer" endpoint** — client converts `quantity`/`unit_price` strings→numbers itself and POSTs as an offer item with `unit`/`section_label`/`calc_category_id`/`calc_snapshot` (opaque JSON, client-defined shape, not validated).

## Customers (`requireAuth`, no admin gate)
- `GET /customers?filter=aktif|pasif&q=` — `q` matches **name only** (not phone/email). No pagination.
- `GET/POST/PUT/DELETE(soft)` — `customerResponse`: id,name,phone,email,address,tax_office,tax_number,notes,is_active. Phone/email always `""` not null — check non-empty for call/email actions.

## Employees / Attendance (`requireAuth`; employee C/U/D requires admin)
- `GET /employees?filter=` — no text search at all.
- Attendance is **pure manual entry, no GPS/geofence, no separate check-in/out calls**: `GET /attendance?month=YYYY-MM`, `POST/PUT /attendance` `{employee_id, date, check_in, check_out, work_hours(number), status, note}`. Status ∈ `geldi|yarım gün|gelmedi|izinli`. One record per employee+date (409 on dup).

## Settings
Entirely `requireAdmin` — zero non-admin access, no per-user settings resource exists at all. Do not build a mobile Settings screen calling this.

## Confirmed backend gaps (do not fake; see MOBILE_BACKEND_GAPS.md)
1. No cross-project "my tasks" endpoint.
2. No organization name/id on `/auth/me` or anywhere else.
3. No search/status/date filters on `/offers` beyond `filter=pasif`.
4. No text search on `/employees`; `/customers` search is name-only.
5. No staff-side approve/reject for change orders (public link only).
6. Notes: create+list only (PUT/DELETE SQL exists, unwired).
