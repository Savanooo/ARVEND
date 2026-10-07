# ARVEND API Contract — Mobile Client Reference

Derived from a full read of the Go backend source (workflow run, 2026-09-15;
Auth section re-verified 2026-09-22 against the super-admin/RBAC/onboarding/
soft-delete backend work). Full per-domain deep-dives with file:line
citations are in `.contract-source/*.md` (auth, offers, projectsFinance,
operations, calculations, customersAttendance) — consult those before
implementing anything not summarized here (the auth deep-dive predates
2026-09-22 and is stale on the points re-verified below; this file is
authoritative for those).

Base: `https://app.arvendyapi.com.tr/api/v1`. Auth: httpOnly cookies
(`access_token` 15min, `refresh_token` 30d, rotated), never a Bearer header.
Every error body is `{"error": "<turkish message>"}` (sometimes `Content-Type:
text/plain` on 401/403 from raw `http.Error` — JSON-decode regardless). A
`code` field is present ONLY on three errors, all 403: `tenant_context_
required`, `permission_denied`, `project_access_denied` — every other error,
including all of the account-access-issue signatures below, has no `code`,
only the fixed message text.
`DisallowUnknownFields()` on every request decode — never send extra JSON keys.

## Account-access issues — mobile session-teardown signatures

Three 403 signatures mean "this account can no longer use the app right now"
(distinct from an ordinary per-action `403` such as "yetkiniz yok" on a
single write). Mobile classifies these centrally in
`lib/core/errors/api_exception.dart#classifyAccountAccessIssue` and reacts to
them in the `ApiClient` Dio `onError` interceptor (not per-screen) — see
`lib/core/api/api_client.dart`. **Do not add new per-screen handling for
these three; extend the central classifier instead.**

| Trigger | Status | Body | Distinguishable? |
|---|---|---|---|
| `super_admin` hits ANY tenant-scoped endpoint | 403 | `{"error":"...", "code":"tenant_context_required"}` | Yes, via `code` |
| Organization `suspended`, `cancelled`, OR soft-deleted (`deleted_at`) | 403 | `{"error":"firma askıya alınmış veya erişilemiyor"}` | **No** — backend returns the exact same body for all three; mobile treats them as one class |
| User `is_active=false` OR soft-deleted (`deleted_at`, soft-delete always also sets `is_active=false`) | 403 | `{"error":"kullanıcı pasif durumda"}` | **No** — backend returns the exact same body for both; mobile treats them as one class |

This applies uniformly to `/auth/refresh` failures too (not just ordinary
API calls) — a refresh that fails with one of these three signatures is
classified the same way, in preference to the generic "session expired"
path. `must_change_password`/`onboarding_completed`/`onboarding_step` are
NOT errors — they are booleans/strings inside the normal 200 body of
login/refresh/me (see below); a **separate** middleware (`RequireOnboarded`)
returns its own 403 (no `code`) if a business endpoint is called before
they're satisfied, but login/refresh/me themselves never error for this.

`super_admin` is a platform account with `organization_id = null` and is
**not a mobile user** — ARVEND Mobile is tenant-only. The app routes it to a
static "use the web console" screen immediately after login (before any
tenant API call is ever made), never into the tenant shell — see
`lib/app/app_router.dart` `_forcedRouteFor`.

## Money/quantity serialization — THREE different conventions, verified

| Domain | Convention |
|---|---|
| `/offers/*`, `/projects/*` (incl. finance/change-orders), `/employees`, `/attendance` | plain JSON **numbers** (float64) |
| `/calculations/*` (recipe items + `/run`) | JSON **strings** (`"100.00"`) — deliberate decimal-safety |

Mobile never does financial arithmetic — all totals come from the backend as-is.

## Auth
- `POST /auth/login` `{username, password}` → 200 `User`. 401 wrong creds, 403 inactive/deleted (`kullanıcı pasif durumda` — see account-access-issue table above; NOT distinguishable from a merely-inactive, non-deleted user).
- `POST /auth/refresh` no body (reads refresh_token cookie) → 200 `User` + new cookies. ANY non-200 clears both cookies server-side — treat as full logout (see account-access-issue table for the three classifiable 403 causes; a plain invalid/expired/reused refresh token is 401 `oturum geçersiz veya süresi dolmuş` and is NOT one of the three).
- `POST /auth/logout` no body → revokes refresh token.
- `GET /auth/me` → `User`. Subject to the SAME organization-status/user-active checks as any other authenticated route (i.e. it can also 403 with the org/user-blocked signatures above, not just a bare "not logged in" 401).
- `PATCH /users/me/password` `{current_password, new_password}` → `{ok:true}`. New password >= 8 chars.
- `POST /users/me/set-initial-password` `{new_password}` → the `must_change_password=true` flow (mobile "Yeni Şifre Belirleyin" screen) — does NOT require `current_password` (the user is already authenticated via a temporary password issued by an admin).

**`User` response shape** (login/refresh/me, all identical):
`id, username, full_name, role` (`admin|kullanici|super_admin` — a COARSE
platform/tenant axis, do not confuse with `organization_role_code` below),
`is_active, organization_id` (`null` for `super_admin`), `organization_name`
(`""` for `super_admin`), `organization_role_code`/`organization_role_name`
(fine-grained RBAC role — `owner|admin|project_manager|finance|field|
legacy_user|<custom>`; empty for `super_admin`), `must_change_password`,
`onboarding_completed`, `onboarding_step` (always `true`/`"completed"` for
`super_admin`, which has no organization to onboard), `permissions` (full
permission-code array, empty for `super_admin` — UX-only, the real
enforcement boundary is always server-side per request). Since 2026-09-27
this is the EFFECTIVE set: role permissions minus per-person revokes plus
per-person grants (owner is never restricted).

## Dashboard (Ana Sayfa) — added 2026-09-28
- `GET /dashboard` (`requireAuth`+tenant+onboarded; NO single `perm()` —
  every section gates itself server-side). One read-only snapshot; 200 even
  when individual sections fail (a failed section comes back as an error
  marker, the rest is intact). A section key that is ABSENT means "no
  permission" → render nothing (no locked teaser); a permission-gated field
  inside a visible section is `null` → hide that sub-block. Project-scoped
  numbers respect project membership (owner/admin/legacy_user see all).
  Links are neutral `ref` objects mapped by `mobileRouteFor(ref)`; the client
  never sums money (`by_currency` arrays: primary currency first).
  Canonical shape: `docs/dashboard/SPEC.md` §4.4 and the fixtures in
  `docs/dashboard/fixtures/*.json` (the mobile model tests decode them).
- `GET /dashboard/project-options?q=` (`projects.read`) → slim project picker
  rows `{id, project_no, name, customer_name, currency, status}` — NO money
  fields; use this instead of `GET /projects` for pickers.

## Remote update (Uzaktan güncelleme, pre-store Android) — added 2026-09-28
Until the app is on the stores, Android updates itself from our server.
Server: `backend/internal/service/app_release_service.go`; client:
`lib/core/update/`; publishing and one-time server setup: `RELEASE.md` §15.
- `GET /mobile/app-version?platform=android` — **PUBLIC** (no auth; also
  called from the login screen). `Cache-Control: no-store`. 200 with a valid
  release, exactly these fields:
  `{"platform":"android","build":3,"version":"1.2.0","sha256":"<64 lowercase hex>","size":62418702,"notes":"…","min_build":0,"published_at":"<RFC3339>"}`.
  No valid release (nothing published, or the release on disk is
  missing/corrupt/inconsistent) → exactly `{"platform":"android","build":0}`
  — never an error. Missing/unknown `platform` (only `android` exists) →
  400 `{"error"}`.
- `GET /mobile/app-download?platform=android` — `requireAuth` +
  `requireTenant` (any tenant user; NO permission, NO onboarding gate).
  Streams the current release APK: 200, `Content-Type:
  application/vnd.android.package-archive`, `Content-Disposition: attachment;
  filename="ARVEND-<version>.apk"`, `ETag: "<sha256>"`, `Content-Length`,
  `Accept-Ranges: bytes`, `Cache-Control: private, no-store`. The server
  supports resume with `Range: bytes=<n>-` + `If-Range: "<sha256>"` → 206;
  if a newer release was published in between, `If-Range` no longer matches
  and a full 200 comes back instead of mixed bytes. The current client does
  NOT resume: an interrupted download restarts from byte 0. No release →
  404 `{"error"}`; unknown platform → 400; no session → 401; `super_admin` /
  suspended-or-deleted organization → the usual 403 account-access
  signatures above. More than 3 concurrent downloads for the same user, or
  more than 20 in total → 429 `{"error"}` + `Retry-After: 30` (no APK
  headers). The write deadline is tied to progress, not a flat
  timeout: it moves to now + 2 min after each chunk the client accepts,
  capped at 1 h in total. A slow link that keeps reading finishes; a
  client that stops reading is dropped after about 2 min.
- Client rules: update available when `build > PackageInfo.buildNumber`;
  mandatory when `PackageInfo.buildNumber < min_build`. Before opening the
  installer, the SHA-256 of the downloaded file MUST equal `sha256` from
  `app-version` (refuse on mismatch). Android itself only installs an update
  signed with the same key as the installed app.

## Offers (`requireAuth`, no admin gate; creation ALSO gated by RBAC — `offers.create`, checked in `offers_screen.dart`/`metraj_screen.dart`/`dashboard_screen.dart`/`customer_detail_screen.dart` before showing any "new offer" entry point. Internal pricing visibility is a SEPARATE pair, `offers.internal_pricing.read`/`.manage`, see `kPermOffersInternalPricingRead`/`Manage` in `lib/features/offers/domain/offer.dart` — mobile has NOT found/confirmed distinct edit/status-change/delete permission codes beyond these; do not invent one without verifying against the backend first)
- `GET /offers/` — params: `filter=pasif|*`, `page`, `limit` (max 200). **No search/status/date filter server-side.** List rows never include `items`.
- `GET/PUT /offers/{id}`, `POST /offers/` (create), `POST /offers/{id}/revise`, `GET /offers/{id}/revisions[/{revisionId}]`, `PUT /offers/{id}/status`, `POST /offers/{id}/toggle-passive`, `DELETE /offers/{id}`, `POST /offers/{id}/send-email`, share-links CRUD, `/events`, `/email-logs`.
- History (mobile since 1.4.0+5, `lib/features/offers/history/`, `offers.read`): `GET /offers/{id}/events` → `{events}` (created_at ASC; view events feed the "görüntülenme" summary), `GET /offers/{id}/email-logs` → `{email_logs}` (sent_at DESC, status sent|failed), `GET /offers/{id}/revisions` (only for revision_id → revision_no). Shown on the offer detail ("Aktivite / Zaman Çizelgesi", "Mail Geçmişi") and in full at `/teklifler/:id/gecmis[?sekme=eposta]`; refreshed after status change, revise, share link, email and convert.
- Status enum (exact, Turkish): `taslak`, `gönderildi`, `kabul edildi`, `reddedildi`. Once `kabul edildi`, locked forever (no further status change, no delete).
- Item fields: `product_id`(nullable), `product_name`, `quantity`(number), `unit_price`(number), `line_total`(number, server-computed), `unit`, `section_label`, `calc_category_id`, `calc_snapshot`(opaque JSON) — last 4 `omitempty`.
- Create validation: >=1 item after dropping blank-name/qty<=0/price<0 rows; `customer_id` OR free-text `customer_name` required. **Company defaults (since 2026-10-07):** on create, omitted/null `vat_rate` → the firm's default VAT (onboarding "Teklif" step; 20% if never saved), omitted/null `currency` → firm default currency (TRY if never saved; must be a 3-letter code, `TL` is read as TRY, otherwise 400), omitted/null `valid_until` → Istanbul today + firm validity days (stays null if the firm has none); `valid_until: ""` = deliberately open-ended. Explicit values (incl. VAT 0) are always kept. On `PUT`, omitted `vat_rate` keeps the revision's current rate (it used to reset to 20%); `currency` is not editable. Offer responses now carry `currency`.
- `GET /offers/defaults` (`offers.create`) → `{vat_rate, currency, validity_days|null, valid_until|null ("YYYY-MM-DD", today Istanbul + days), payment_terms, delivery_terms, footer}` — never bank/IBAN data. Mobile pre-fills KDV from it in the new-offer form and shows the default validity end as info (the form has no date field and sends `valid_until: null`). Mobile asks for confirmation before saving an offer with any 0-priced line.
- **Conversion to project is NOT under `/offers`** — it's `POST /projects/from-offer/{offerId}`, requires current revision `status == kabul edildi`, idempotent. Check-if-converted: `GET /offers/{id}/project` (404 = not yet).

## Projects (`requireAuth`, no admin gate; every write across Finance/
Operations/Procurement/Subcontracts below is ALSO gated by a per-domain RBAC
permission code — `projects.finance.read/.manage`, `projects.cost_control.
read`, `projects.tasks.create/.update`, `projects.operations.manage`, plus
the Procurement & Subcontracts codes listed in their own section — checked
client-side with the `_failOpen` pattern (`user == null || user.permissions.
isEmpty || user.hasPermission('<code>')`) next to each action, in addition
to backend enforcement)
- `GET /projects` — params: `status`, `customer_id`, `project_type`, `currency`, `start_from`, `q` (ILIKE name/no/customer), `page`, `limit`. List rows DO include finance aggregate fields (current_contract_value etc).
- `GET/PUT /projects/{id}` — **finance aggregate fields are ABSENT here** (omitempty, always nil on single-object reads). Must call `/financial-summary` separately.
- `PUT /projects/{id}` (project-scoped `projects.update`; mobile "Proje bilgilerini düzenle", `/projeler/:id/duzenle`, since 1.3.0+4) — body is exactly `{name, project_type, status, start_date, end_date, description, internal_notes}`. Money/currency/customer/source offer are NOT editable here and are never sent. `status` must follow the machine below.
- `GET /projects/{id}/financial-summary` → 21 always-present number fields: `current_contract_value`, `collected_amount`, `remaining_receivable`, `realized_cost`, `committed_cost` (closest to "estimated cost"), `estimated_gross_profit`, etc. This is the authoritative source for the finance screen header.
- Status machine: `planned→{active,paused,cancelled}`, `active→{paused,completed,cancelled}`, `paused→{active,completed,cancelled}`, `completed→active only`, `cancelled` terminal.
- No plain POST/DELETE on projects.

### Finance sub-resources (all under `/projects/{id}/...`)
- `payment-plan` (GET/POST/PUT/DELETE-soft), `collections` (GET/POST/void), `expenses` (GET/POST/PUT/void), `invoices` (GET/POST/PUT status), `subcontractors` + `subcontractor-payments` (GET/POST/PUT/void).
- Expense create `{category, description, amount, currency, expense_date, supplier_name, invoice_no, notes, idempotency_key, change_order_id, cost_code_id, budget_line_id}` (links optional, empty string = none; when a budget line is chosen the server takes the cost code from the line). `category` ∈ `material|personnel|transport|accommodation|food|equipment|other`. Void via `POST .../{id}/void {reason}`.
- Collection create `{amount, received_date, payment_method, description, reference_no, payment_plan_item_id (null = not linked), idempotency_key}`; `currency` omitted = project currency. A linked collection raises the plan item's "Tahsil Edilen".
- Mobile (since 1.4.0+5, Finans > "Finans" view, `lib/features/projects/finance_ledger/`): tapping an expense/collection opens its detail (links resolved to "EK-… · title", cost code, plan item) and "İptal Et" (`projects.finance.manage`, open project only, reason REQUIRED in the app — the web allows an empty one). Expense form offers Ek İş / Bütçe Kalemi / Maliyet Kodu pickers (each loaded only with its read permission: `projects.finance.read`, `projects.budget.read`, `organization.cost_codes.read`), collection form offers the open plan items. Both forms keep one `idempotency_key` per form instance and parse Turkish amounts ("64.000" = 64 000, "1.250,50"). Add/void hidden on completed/cancelled projects (backend 409).
- Legacy subcontractors ("Taşeron Ödemeleri", `projects.finance.read/.manage`, same folder): `GET /subcontractors` → `{subcontractors}` (server computes `paid_amount`/`remaining_amount`), `GET /subcontractor-payments` → `{payments}`, `POST /subcontractors {name, company_name, work_description, contract_amount, currency}`, `POST /subcontractors/{subId}/payments {amount, currency, paid_date, description, idempotency_key}` (key per subcontractor + form). Payments count as realized cost — never also entered as expenses. Separate from the Sprint 5 subcontract CONTRACTS (`/subcontracts`, Operasyon > Taşeronlar).
- Activity (`projects.read`, `lib/features/projects/activity/`, `/projeler/:id/aktivite`): `GET /projects/{id}/events` → `{events: [{id, event_type, user_id, metadata, created_at}]}` (created_at ASC; the app shows newest first, grouped by Istanbul day, Turkish labels from `core/utils/event_labels.dart`). The endpoint returns money fields (`amount`, `planned_amount`, `contract_amount`, `grand_total`) to every project reader; the app shows them ONLY with `projects.finance.read`.
- `change-orders`: state machine `draft→sent→{approved(final),rejected}`, `sent|rejected→(revise)→superseded+new draft`, `draft|sent→(cancel)→cancelled`. **No staff approve/reject endpoint** — only via public link. **Cancel takes no reason body.**

### Procurement & Subcontracts sub-resources (all under `/projects/{id}/...`) — undocumented until 2026-09-22, verified against `lib/features/projects/data/projects_repository.dart`
Cost-side sibling of Finance (Offers/change-orders are revenue). Every write
here is gated by fine-grained RBAC permission codes (`projects.procurement.*`,
`projects.subcontracts.*`, `projects.subcontract_payments.*`,
`projects.subcontract_claims.*`), not just `requireAuth` — mobile mirrors
each with `user.hasPermission('<code>')` next to the corresponding button
(see `_failOpen` pattern in `project_detail_screen.dart`/
`subcontract_detail_screen.dart`/`rfq_detail_screen.dart`); do not add a
write action here without checking the matching permission first.
- `purchase-requests` (GET/POST/GET-by-id), lifecycle `draft→submitted→
  {approved,rejected}`, `{draft,submitted,approved}→(cancel, reason
  required)→cancelled`. Approve/cancel need `.manage`; reject needs
  `.approve` (asymmetric — do not assume the same permission covers both).
- `rfqs` (GET/POST/GET-by-id) + `quotations` (GET/POST/DELETE, nested under
  a specific RFQ) + `/comparison` (GET, side-by-side supplier comparison) +
  lifecycle actions `issue`/`close`/`cancel`/`award`. `award` locks the
  winning quotation and is a PREREQUISITE for creating a purchase order
  from it (mobile's "Bu Tekliften Sipariş Oluştur" action, `.manage`-gated).
- `purchase-orders` (GET/POST/GET-by-id) + `approve` (locks per-line
  commitment amounts, permanent — needs `.approve`, not `.manage`) +
  `close` (terminal archive marker, no cost-control effect) + `cancel`
  (reason required).
- `subcontracts` (GET/POST/GET-by-id, includes SOV line items read-only on
  the detail response) + lifecycle `activate`/`complete`/`cancel`
  (reason required)/`terminate` (reason required) — `.manage` for
  activate/edit, `.approve` for the rest. Nested: `payments` (GET/POST,
  **separate** permission pair `projects.subcontract_payments.read/.manage`
  — NOT the same as `subcontracts.manage`), `progress-claims` (GET/POST
  under the subcontract; individual claim GET/`submit`/`reject`/`cancel`
  live at `/projects/{id}/subcontract-progress-claims/{claimId}` — note
  the URL prefix change, permission `projects.subcontract_claims.*`),
  `change-orders` (GET/POST under the subcontract; individual change order
  GET/`approve`/`reject` live at
  `/projects/{id}/subcontract-change-orders/{changeOrderId}` — same
  prefix-change pattern; these DO have an authenticated approve/reject
  action, unlike project-level change orders — see gap #3 above; they
  share the parent subcontract's `.manage`/`.approve` permissions, they
  have no permission codes of their own).
- `cost-control` (GET) — budget-based EAC/estimated-profit, separate
  `projects.cost_control.read` permission; a user can see Finance without
  seeing this (mobile falls back to the financial-summary's committed-cost
  estimate instead of erroring).
- `POST /projects/{id}/subcontracts/{id}/payments`, all financial mutation
  endpoints here (payments/expenses/collections/etc.) follow the same
  `{reason}`-on-void convention as Finance's expenses/collections where
  applicable — check the specific endpoint, it is not universal (e.g.
  purchase-order `cancel` requires a reason, `close` does not).

### Operations sub-resources (all under `/projects/{id}/...`)
- `members` (GET/POST/DELETE-end), `schedule` (GET/POST/PUT, no DELETE), `tasks` (GET/POST/PUT/POST .../complete, no DELETE, **no cross-project endpoint — gap**), `photos` (GET/POST multipart field `file`/GET .../content/DELETE), `files` (same pattern, .../download has Content-Disposition), `notes` (GET/POST only — no PUT/DELETE despite SQL existing), `events` (GET, shared timeline with finance), `operations-summary` (GET — `task_completion_ratio` is ALREADY ×100, a percentage).
- Cross-project task lists (Görevler tab): `GET /tasks/mine?status=` → `{tasks, linked_employee}` and `GET /tasks/team?status=&assignee=` → `{tasks, total, truncated}` (list capped at 500; `truncated` = more exist, `total` = real count — mobile shows "İlk N görev gösteriliyor"). Each row = task fields + `project_id`, `project_name`, `project_status`, `project_closed` (completed/cancelled project; `is_overdue` is then false) — mobile shows a "Proje kapalı" chip.
- Upload: multipart field name `file` for both files and photos. 25 MiB hard cap (`ErrFileTooLarge` after write+delete). Content-type sniffed server-side, client header ignored. Photos: `stage` (before|progress|after), `taken_at` send date-only, get back full RFC3339. Files: `category` (contract|drawing|invoice|report|other).
- Task priority: `low|normal|high|urgent`. Task status: `todo|in_progress|completed|cancelled`. Create cannot set status=completed directly.

### Project modules added in 1.4.0+5 (2026-09-29) — contract, change orders, budget/cost control, payment plan, invoices, schedule, team, access
All `projPerm` (permission + project membership, checked server-side on
every request). Mobile gates each read with the fail-open `UserCan.can`
(same decision as `_failOpen` in `project_detail_screen.dart`) and makes NO
request while `/auth/me` is still loading; every write button is hidden
without the matching `.manage`/`.lifecycle` code and on completed/cancelled
projects (web `locked`). 403 → "yetkin yok" view, never a crash; 409 →
server message + reload. Sources: the doc comment at the top of each
repository below.

**Contract** (`projects.contracts.read/.manage/.lifecycle`, `lib/features/projects/contract_co/`):
- `GET /projects/{id}/contract` (404 = no contract yet → "Sözleşme Oluştur" CTA, manage only), `POST /contract` (201; 409 = already exists → reload), `PUT /contract` (draft only: scope, payment/progress/advance terms, `effective_date`/`planned_completion_date`, cleared date sent as `null`), `PUT /contract/notes` (draft + active).
- Lifecycle: `POST /contract/activate` (draft→active), `/cancel {reason}` (draft→cancelled, reason REQUIRED), `/complete` (active→completed), `/terminate {reason}` (active→terminated, reason REQUIRED). Project Manager role has manage but NOT lifecycle.

**Project change orders** (NO own permission — `projects.finance.read/.manage`, same folder):
- `GET /change-orders` → `{change_orders}` (includes internal profitability + active share link), `GET /change-orders/{coId}` (items; NO profitability — app merges it from the list row), `POST /change-orders` (201), `PUT /change-orders/{coId}` (draft only). Item: `{product_id?, description, quantity, unit, unit_price, estimated_unit_cost?}` — keep `product_id`/`estimated_unit_cost` on edit.
- `POST .../{coId}/send` (draft→sent + share link `/ek-is/{token}`), `POST .../{coId}/send-email {to, subject, message}`, `POST .../{coId}/revise` (sent|rejected → new draft, old one superseded), `POST .../{coId}/cancel` (NO body — cancel takes no reason). Approve/reject only via the public link.
- There is NO change-order email-log list endpoint; the mail history is read from `GET /projects/{id}/events` rows `change_order_email_sent|failed` (payload carries the recipient).

**Budget / cost control** (`lib/features/projects/budget/`):
- `projects.budget.read`: `GET /wbs`, `GET /budget` (404 = no budget), `GET /budget/lines` (404 = no budget), `GET /budget/adjustments`.
- `projects.budget.manage`: `POST /wbs`, `PUT/DELETE /wbs/{nodeId}` (DELETE = archive), `POST /budget`, `POST /budget/baseline`, `POST /budget/lines`, `PUT/DELETE /budget/lines/{lineId}` (draft budget), `POST /budget/adjustments` (non-zero, may be negative), `POST /budget/adjustments/{adjId}/approve|reject`.
- `projects.cost_control.read`: `GET /commitments`, `GET /forecasts`, `GET /cost-control`. `projects.cost_control.manage`: `POST /commitments` (manual, `idempotency_key`), `POST /commitments/{cId}/void {reason}` (app offers void ONLY for active manual commitments), `PUT /budget/lines/{lineId}/forecast`.
- Pickers/breakdown: `GET /organization/cost-codes` (`organization.cost_codes.read`), `GET /projects/{id}/expenses` (`projects.finance.read`; the "Gerçekleşen" card is hidden without it).

**Payment plan & invoices** (`projects.finance.read/.manage`, `lib/features/projects/finance_plan/`):
- `GET /payment-plan` → `{items, planned_total}`, `POST /payment-plan` (amount OR percentage, optional `due_date`, `notes`), `PUT /payment-plan/{itemId}` (full body), `DELETE /payment-plan/{itemId}` (cancels the item; row kept, no restore). No single-item GET — detail is derived from the list.
- `GET /invoices` → `{invoices}`, `POST /invoices` (`invoice_type` sales|purchase, `invoice_no`, amounts, `invoice_date`, `due_date?`, `customer_name?`, `notes?`), `PUT /invoices/{invoiceId}/status {status}` (any of the 5 statuses; no state machine server-side). No invoice field-edit endpoint.

**Schedule, team, access** (`lib/features/projects/ops_team/`):
- `projects.operations.read/.manage`: `GET/POST /schedule`, `PUT /schedule/{itemId}` (rewrites EVERY field — always send `{name, description, start_date, end_date, status, sort_order}`; no DELETE — the app "cancels" instead), `GET/POST /members {employee_id, role_title, start_date, notes}` (409 if already active), `DELETE /members/{memberId}` (ends the membership, sets `end_date`), `GET /employees?filter=aktif` (member picker, `employees.read`).
- `projects.access.read/.manage`: `GET /access` → `{users}`, `POST /access {user_id, project_role}`, `PUT /access/{userId} {project_role}`, `DELETE /access/{userId}`, `GET /users?limit=200` (user picker; coarse admin + `organization.users.read`, fetched only when the grant sheet opens).

**Deep links** (`lib/features/dashboard/domain/mobile_routes.dart`): `milestone` → `/projeler/{p}/planlama/{id}`, `change_order` → `/projeler/{p}/ek-isler/{id}`, `contract` → `/projeler/{p}/sozlesme`, `payment_plan_item` → `/projeler/{p}/odeme-plani/{id}`, `invoice` → `/projeler/{p}/faturalar/{id}`, `budget_adjustment` → `/projeler/{p}/maliyet/revizyonlar`. Project sub-views: `?grup=finans&alt=finans|sozlesme|odeme-plani|faturalar|taseron-odemeleri|ek-isler|maliyet`, `?grup=operasyon&alt=taseronlar|satin-alma|gorevler|planlama|ekip|erisim`, `?grup=dokumanlar&alt=dosyalar|notlar`.

## Calculations (`requireAuth`; read = `calculations.read`, group/category/recipe-item CUD = `calculations.manage` — no coarse admin gate any more)
- Recipe admin (mobile Diğer > Metraj Reçeteleri, `lib/features/calc_admin/`, since 1.3.0+4): `POST /calculations/groups`, `PUT /calculations/groups/{id}`, `POST /calculations/categories`, `PUT /calculations/categories/{id}`, `POST/PUT/DELETE /calculations/recipe-items[/{id}]`. Group/category edits send the existing `image_file_id` back unchanged. Deactivating a group/category hides it (lists return active only). The product picker pages `GET /products` (limit 200) only with `products.read`.
- `GET /calculations/groups` → active groups only.
- `GET /calculations/categories?group_id=X` → flat active categories in that group. `GET /calculations/categories` (no param) → nested `{groups:[{...,categories:[...]}]}` cascade shape — **response shape differs by presence of the query param.**
- `GET /calculations/recipe-items?category_id=X` (required param) → ALL items (active+inactive), any authed role.
- `POST /calculations/run` `{category_id, area?, width?, height?, perimeter?, pitch_deg?}` — all numeric inputs are `string`, all optional except category_id, but **if sent, must be > 0** (0 or negative is a hard error, not "treat as absent"). Area resolution: `area` wins, else needs BOTH width+height. Perimeter resolution independent: explicit wins, else derived only from width+height (never from area alone).
- Response: `{category, input:{footprint_area,effective_area,perimeter}, items:[{recipe_item_id,material_name,unit,quantity,product_id?,unit_price,line_total,group_name?,calculation_type,factor,waste_percent,rounding_type}], total_cost, warnings:[{item_id,code,message}]}`. **Every numeric field here is a JSON string.**
- Warning codes: `perimeter_missing`, `unknown_calculation_type`, `product_missing`, `product_zero_price`.
- **Price fallback (since 2026-10-07):** each item also has `price_source` (`product` | `reference` | `none`) and, unless the product price was used, `price_warning` (`"referans fiyat kullanıldı"` / `"fiyat yok"`). When the linked product is missing or 0 TL, `unit_price`/`line_total`/`total_cost` use the recipe item's `reference_unit_price` (if > 0); otherwise the line stays 0. Warning codes are unchanged (messages now name the price used). Mobile marks such lines, shows one summary note and drops the per-line `product_missing`/`product_zero_price` boxes for marked lines; the source is copied into `calc_snapshot.price_source`.
- **No "convert calc to offer" endpoint** — client converts `quantity`/`unit_price` strings→numbers itself and POSTs as an offer item with `unit`/`section_label`/`calc_category_id`/`calc_snapshot` (opaque JSON, client-defined shape, not validated).

## Customers (`requireAuth`, no admin gate)
- `GET /customers?filter=aktif|pasif&q=` — `q` matches **name only** (not phone/email). No pagination.
- `GET/POST/PUT/DELETE(soft)` — `customerResponse`: id,name,phone,email,address,tax_office,tax_number,notes,is_active. Phone/email always `""` not null — check non-empty for call/email actions.
- Duplicate guard: `POST`/`PUT` answer **409** `{error, code:"duplicate_customer", field:"tax_number"|"phone", existing_customer:{id,name,is_active}}` when another customer has the same tax number or phone; resend with `allow_duplicate: true` to save anyway. Mobile's customer form shows a dialog (Mevcut müşteriyi aç / Yine de kaydet / Vazgeç). `ApiException` now carries `code` and the raw JSON `body` for such cases.

## Products (`requireAuth`; read = `products.read`, write = `products.manage`) — mobile since 1.3.0+4 (`lib/features/products/`)
- `GET /products?page=&limit=&q=` → `{products, total}`. **limit max 200; above 200 silently falls back to 50.** Mobile pages 100 at a time.
- `GET /products/{id}`, `GET /products/{id}/price-history` → `{history:[{old_price,new_price,note,changed_at,reason(supplier|markup|manual),source,old_source_price?,new_source_price?}]}`.
- `POST /products`, `PUT /products/{id}` `{name, unit, unit_price, description, category}` (manage). Name/unit of a source-linked product stay locked in the UI (web sourceLink rules); so does `unit_price` for a product still in the supplier list (every sync, incl. the nightly one, rewrites it from source price + markup — the form sends the existing price and points to the markup settings).
- `GET /products/price-sources` → `{sources:[…]}` (Ulaş, Demir Profil). `PUT /products/price-sources/{source}` `{markup_percent, auto_sync, category_markups:[{category, markup_percent}]}` and `POST /products/price-sources/{source}/sync` (manage). Sync errors: **409** = another sync (or markup update) for this source is already running (`bu fiyat kaynağı için şu anda başka bir senkron çalışıyor, biraz sonra tekrar deneyin`); **502** = either the source was unreachable/unparseable (`tedarikçi fiyat listesi alınamadı; lütfen daha sonra tekrar deneyin`) OR the list came back much shorter than the last good sync, i.e. under half (`tedarikçi fiyat listesi beklenenden çok kısa geldi; fiyatlar değiştirilmedi`) — the two 502s are told apart only by that exact `error` text. Prices are unchanged in both 502 cases; details (HTTP code, counts) are recorded in the source's `last_error`.
- `GET /products/price-changes?from&to&reason&source&direction&category&q&sort&page&limit` and `GET /products/price-changes/summary?from&to&reason&source` (Zam Geçmişi).
- `source_price` and all markup values are returned **only** to `products.manage`; mobile additionally never renders them without manage.

## Employees / Attendance (`requireAuth`; employees read = `employees.read`, create/update/archive = `employees.manage`)
- `GET /employees?filter=` — no text search at all. Since 2026-09-27
  `salary`/`daily_wage` are `null` unless the caller holds
  `employees.manage` (listing personnel must not expose wages).
- Mobile Diğer > Personel (since 1.3.0+4, `lib/features/employees/`): `GET /employees/{id}`, `POST /employees`, `PUT /employees/{id}` `{full_name, phone, position, salary, daily_wage, start_date, description, is_active, user_id}`, `DELETE /employees/{id}` (archive = pasif, not a hard delete). "Giriş hesabı aç" chains `POST /users` + `PUT /employees/{id}` (`user_id`) + `PUT /users/{id}/permissions` (see Users below).
- Attendance is **pure manual entry, no GPS/geofence, no separate check-in/out calls**: `GET /attendance?month=YYYY-MM`, `POST/PUT /attendance` `{employee_id, date, check_in, check_out, work_hours(number), status, note}`. Status ∈ `geldi|yarım gün|gelmedi|izinli`. One record per employee+date (409 on dup).

## Users, Roles & Permissions (`requireAdmin` (coarse role) **plus** RBAC) — mobile since 1.3.0+4 (`lib/features/access/`)
Every endpoint here needs coarse `role=admin` in addition to the permission, so mobile gates with the strict `canAccess` (`core/auth/permissions.dart`, `kAdminRoleOnlyPermissions`).
- `GET /users?page=&limit=` (`organization.users.read`, limit ≤ 200) → `{users, total}`; `GET /users/{id}`; `GET /users/{id}/projects` → `{projects}`.
- `POST /users` `{username, password, full_name, organization_role_code}` — role code REQUIRED (else the member lands in "Eski Sistem"). `PUT /users/{id}` `{full_name, is_active}`; `PATCH /users/{id}/password` `{new_password}` (all `organization.users.manage`). Last active owner cannot be deactivated (409).
- `PUT /users/{id}/organization-role` `{role_code}` (`organization.roles.manage`) — resets that person's overrides.
- `GET/PUT /users/{id}/permissions` (`organization.roles.read` / `.manage`) — PUT `{permissions:[…]}` sets the EFFECTIVE set; differences from the role are stored as personal overrides. Owner → 409.
- `GET /organization/roles` → `{roles}`, `PUT /organization/roles/{id}/permissions` `{permissions:[…]}` (roles.read / roles.manage); `GET /organization/permissions` → `{permissions}` catalog (roles.read).

## Organization (`requireAuth`, mostly `requireAdmin`) — undocumented until 2026-09-22
- `GET /organization/cost-codes[/{id}]` (`organization.cost_codes.read`) and
  `GET /organization/suppliers[/{id}]` (`organization.suppliers.read`) —
  RBAC-gated, **no** coarse admin gate (finance/PM roles use them). Used by
  the procurement/subcontract pickers and, since 1.3.0+4, by Diğer >
  Maliyet Kodları / Tedarikçiler (`lib/features/cost_codes/`,
  `lib/features/suppliers/`). Writes (`.manage`): `POST /`, `PUT /{id}`,
  `DELETE /{id}` (archive), `POST /{id}/reactivate`. `code` is immutable
  after create. Supplier `iban` is write-only (response has `iban_set`);
  omit the key to keep the stored IBAN. Supplier PUT overwrites
  `specialty` with whatever is sent — always send it back.
- `GET /organization/settings` + `PUT /organization/settings/{company,
  billing,offers,finance,business}` — `requireAdmin`. This is a **different**
  route from `/settings` below (SMTP-only) — mobile's `OnboardingRepository`
  (`lib/features/onboarding/data/onboarding_repository.dart`) serves BOTH
  the first-run onboarding wizard (`basePath: '/onboarding'`, same
  sub-resource shape) and the post-onboarding "Firma Ayarları" screen
  (`basePath: '/organization/settings'`) off the identical request/response
  shape — only the base path differs.
- `GET /organization/roles`, `GET /organization/permissions` — consumed
  since 1.3.0+4 by the organization-admin screens (see "Users, Roles &
  Permissions" above). Platform (Super Admin) management stays web-only.

## Settings
`/settings` (note: NOT `/organization/settings` above — a different,
narrower route) is entirely `requireAdmin` + `organization.settings.*`,
SMTP configuration only — no per-user settings resource exists at all.
The mobile "Firma Ayarları" screen calls `/organization/settings`, not this.
Since 1.3.0+4 Diğer > E-posta Ayarları (`lib/features/settings/`, web
`/admin/ayarlar`) uses it: `GET /settings/smtp` (read) → `{…, password_set}`
(the stored password is NEVER returned); `PUT /settings/smtp` (manage) —
`password: null` keeps the stored one; `POST /settings/smtp/test` (manage)
sends a test mail with the SAVED settings.

## Confirmed backend gaps (do not fake; see MOBILE_BACKEND_GAPS.md)
1. No search/status/date filters on `/offers` beyond `filter=pasif`.
2. No text search on `/employees`; `/customers` search is name-only.
3. No staff-side approve/reject for **project-level** change orders (public link only) — subcontract-level change orders DO have an authenticated approve action (see Procurement & Subcontracts below); these are two separate features, do not conflate them.
4. Notes: create+list only (PUT/DELETE SQL exists, unwired).
5. Project change orders: no email-log list endpoint (history comes from project `events`); detail GET has no profitability (merged from the list); cancel takes no reason.
6. Invoices: no field-edit endpoint (only POST + PUT status) and no status state machine (any status, including un-cancelling, is accepted); no single-invoice GET.
7. Payment plan: no single-item GET, no restore for a cancelled item; `DELETE` on a missing/already-cancelled item answers "proje bulunamadı" (the app shows its own text).
8. Schedule: no DELETE (items are set to `cancelled`).
9. `DELETE /payment-plan/{itemId}` and `PUT /invoices/{id}/status` do not call `requireOpenProject`; the completed/cancelled lock is UI-only there (web and app).
10. `POST /commitments/{id}/void` does not check `source_type` — purchase-order/subcontract commitments can be voided via API/web (the app offers void only for manual ones).
11. `GET /budget` and `GET /budget/lines` return 404 both for "no budget" and "project not found".
12. `GET /projects/{id}/events` returns money in `metadata` to users without `projects.finance.read` (HANDOFF §8); the app hides it client-side.
13. Legacy subcontractors: the web neither edits a subcontractor nor voids its payments, so the app does not either (the backend has the endpoints).

(The cross-project "my tasks" endpoint and organization name/id on auth responses — formerly gaps #1/#2 here — are both RESOLVED; see MOBILE_BACKEND_GAPS.md for the history.)
