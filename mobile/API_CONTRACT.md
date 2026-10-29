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
`code` field is present ONLY on a few errors: three 403s (`tenant_context_
required`, `permission_denied`, `project_access_denied`) and the 503
`temporarily_unavailable` (see below) — every other error,
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

**Temporarily unavailable is NOT an account-access issue.** When the
database cannot be read at that moment (connection dropped, Postgres
restarting), the auth middleware (`RequireAuth`, `RequireActiveUser`,
`RequireOnboarded`), `GET /auth/me` and `/auth/refresh` answer **503**
`{"error":"sunucu şu anda yanıt veremiyor, biraz sonra tekrar deneyin","code":"temporarily_unavailable"}`
(+ `Retry-After`). Cookies are NOT cleared; the client keeps the session and
retries later. Before 2026-10 these failures came back as the org-blocked 403
above / a 401, and the whole team was logged out during a short DB outage.

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
- `POST /auth/refresh` no body (reads refresh_token cookie) → 200 `User` + new cookies. A 401/403 clears both cookies server-side — treat as full logout; a 5xx (incl. 503 `temporarily_unavailable`) keeps them — do NOT log out (see account-access-issue table for the three classifiable 403 causes; a plain invalid/expired/reused refresh token is 401 `oturum geçersiz veya süresi dolmuş` and is NOT one of the three).
- `POST /auth/logout` no body → revokes refresh token.
- `GET /auth/me` → `User`. Subject to the SAME organization-status/user-active checks as any other authenticated route (i.e. it can also 403 with the org/user-blocked signatures above, not just a bare "not logged in" 401). 401 only when the user/organization row really does not exist; 503 `temporarily_unavailable` when it could not be read.
- Permission refresh (mobile, since 2026-10-11): permissions change on the web while the Android process can live for days, so `AuthController.recheckPermissions` re-reads `/auth/me` when the app comes to the foreground, every 5 minutes while it is open (`PermissionRefreshWatcher`, stopped in the background) and after any 403 `code: "permission_denied"` (`ApiClient.onPermissionDenied`). At most one call per 30 s (`permissionRecheckInterval`); an unchanged user is not written back to the state.
- `PATCH /users/me/password` `{current_password, new_password}` → `{ok:true}`. New password >= 8 chars.
- `POST /users/me/delete` `{password}` → `{ok:true}` (since 2026-10-13, mobile 1.5.15; App Store 5.1.1(v)). The caller deletes their own account: soft delete + deactivation, sessions and push devices revoked, username/full name/password hash irreversibly replaced (`silinmis-<id>`, "Silinmiş kullanıcı"); company records stay. Wrong password → 400 `şifre hatalı`; the organization's only active owner → 409. Mobile: Profil → "Hesabımı Sil" (password + confirm), then `AuthController.accountDeleted()` (local cleanup only, no `/auth/logout`).
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
per-person grants (owner is never restricted). Since 2026-10-07 also
`organization_status` (`active|trial|suspended|cancelled`, empty for
`super_admin`) and, ONLY for a trial firm with an end date, `trial_ends_at`
(RFC3339), `trial_ends_on` (Istanbul calendar day `YYYY-MM-DD`),
`trial_days_left` (Istanbul days; 0 on the last day, negative after) and
`trial_expired` (bool). An expired trial is NOT blocked — the app shows a
per-day dismissible Ana Sayfa banner to Sahip/Yönetici only
(`features/dashboard/domain/trial_notice.dart`). Since 2026-10-24
(migration 0075) a subcontractor portal account also carries `supplier_id`
(omitted for everyone else) and `organization_role_code: "subcontractor"`
— see "Taşeron Paneli" below.

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
  — never an error — plus `"min_build":N` when the Play floor
  (`app-releases/android/play.json`, `{"min_build":N}`, RELEASE.md §16) is
  set. With a valid release `min_build` is the larger of the two floors.
  The sideload channel is closed (2026-10-09), so in practice this endpoint
  now only carries the Play build's mandatory-update floor.
  Missing/unknown `platform` (only `android` exists) → 400 `{"error"}`.
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
- Client rules (sideload): update available when `build > PackageInfo.buildNumber`;
  mandatory when `PackageInfo.buildNumber < min_build`. Play build
  (`lib/core/update/play_update.dart`): asks Google Play whether an update
  exists and reads only `min_build` here; below it the update is mandatory
  (Play's immediate update, then a blocking "Güncelleme gerekli" screen if
  declined). Unreachable Play/server never blocks the app. Before opening the
  installer, the SHA-256 of the downloaded file MUST equal `sha256` from
  `app-version` (refuse on mismatch). Android itself only installs an update
  signed with the same key as the installed app.

## Offers (`requireAuth`, no admin gate; creation ALSO gated by RBAC — `offers.create`, checked in `offers_screen.dart`/`metraj_screen.dart`/`dashboard_screen.dart`/`customer_detail_screen.dart` before showing any "new offer" entry point. Internal pricing visibility is a SEPARATE pair, `offers.internal_pricing.read`/`.manage`, see `kPermOffersInternalPricingRead`/`Manage` in `lib/features/offers/domain/offer.dart` — edit/status-change/delete codes: see "Permissions" below; do not invent one without verifying against the backend first)
- `GET /offers/` — params: `filter=pasif|*`, `page`, `limit` (max 200). **No search/status/date filter server-side.** List rows never include `items`.
- `GET/PUT /offers/{id}`, `POST /offers/` (create), `POST /offers/{id}/revise`, `GET /offers/{id}/revisions[/{revisionId}]`, `PUT /offers/{id}/status`, `POST /offers/{id}/toggle-passive`, `DELETE /offers/{id}`, `POST /offers/{id}/send-email`, share-links CRUD, `/events`, `/email-logs`.
- Delete requests (since 2026-10-14, migration 0067; mobile 1.5.16). `offers.delete` holders (owner, admin, legacy user) keep deleting directly with `DELETE /offers/{id}`. Anyone with `offers.create` or `offers.update` but without `offers.delete` asks instead:
  - `POST /offers/{id}/delete-request` `{reason?}` → 201 `{id, offer_id, requested_by, requested_by_name, reason, created_at}`. Accepted offer → 409; a pending request already exists → 409.
  - `DELETE /offers/{id}/delete-request` → withdraw. Only the requester; anyone else → 403.
  - `POST /offers/{id}/delete-request/approve` (`offers.delete`) → the offer is permanently deleted, and the requester is notified (target `/teklifler`).
  - `POST /offers/{id}/delete-request/reject` `{note?}` (`offers.delete`) → the offer stays, and the requester is notified with the note.
  - `GET /offers/delete-requests` (`offers.delete`) → `{data: [... + offer_no, customer_name, grand_total, currency]}`, oldest first.
  - `GET /offers/{id}` carries `delete_request` (same shape) while one is pending; otherwise the field is absent.
  - Approvers get the `offer_delete_requested` notification and the home attention code `offer_delete_approval` (ref kind `offer`).
- Permissions (verified in `router.go`): `offers.update` = edit / revise / send-email / share links; `offers.approve` = `PUT /status`, `toggle-passive` and share-link `mark_sent`; `offers.delete`.
- Archive (`POST /offers/{id}/toggle-passive`, `offers.approve`) → `{ok: true}`. **Since 2026-10-11** the body may carry `{"is_passive": true|false}`: the offer is set to that state and nothing changes if it already is (a stale screen cannot undo someone else's archiving); no body = old toggle. Archiving writes an `offer_cancelled` event; un-archiving writes `offer_reactivated` (since 2026-10-11; it used to write nothing — web, mobile 1.5.14 label it "Teklif arşivden çıkarıldı", older apps show "Kayıt güncellendi"). An archived offer's share links stop opening for the customer and work again once it is un-archived (they are not revoked). Mobile (1.5.14): "Arşivle" / "Arşivden Çıkar" in the offer detail's ⋮ menu, with confirmation, sending the explicit body.
- Share links (`offers.update`): `POST /offers/{id}/share-links {expires_in: ""|"7d"|"30d", mark_sent?: bool}` → 201 `{id, offer_id, revision_id, token, created_by, created_at, expires_at, revoked_at, is_active}`; `GET` → `{share_links}`; `DELETE .../share-links/{linkId}`. A link is pinned to the revision that was current when it was made. The customer page (`/paylas/{token}`) shows Kabul Et / Reddet only while that revision is still current, `gönderildi` and within `valid_until`; a `taslak` link is a preview (no buttons, no first-open notification). **`mark_sent` (since 2026-10-08, mobile 1.5.12):** `true` while the current revision is `taslak` → it becomes `gönderildi` in the same transaction as the link, exactly like `PUT /status` (previous revisions' links revoked, `revision_sent` event, past validity → 409 and NO link). Already sent/decided → status untouched, link created. Needs `offers.approve` on top of `offers.update`; without it → 403 `permission_denied` and no link, whatever the status. Omitted/false = old behaviour (web sends nothing). The backend rejects unknown JSON fields, so mobile sends `mark_sent` only when true: an older server answers 400 only to "Gönder ve link oluştur" — deploy the backend first. Mobile: "Paylaşım Linki" on a draft asks "Gönder ve link oluştur" / "Yalnızca önizleme linki" / "Vazgeç" (without `offers.approve`: preview only, with a note); other statuses create the link directly.
- History (mobile since 1.4.0+5, `lib/features/offers/history/`, `offers.read`): `GET /offers/{id}/events` → `{events}` (created_at ASC; view events feed the "görüntülenme" summary), `GET /offers/{id}/email-logs` → `{email_logs}` (sent_at DESC, status sent|failed), `GET /offers/{id}/revisions` (only for revision_id → revision_no). Shown on the offer detail ("Aktivite / Zaman Çizelgesi", "Mail Geçmişi") and in full at `/teklifler/:id/gecmis[?sekme=eposta]`; refreshed after status change, revise, share link, email and convert.
- Status enum (exact, Turkish): `taslak`, `gönderildi`, `kabul edildi`, `reddedildi`. Once `kabul edildi`, locked forever (no further status change, no delete).
- Item fields: `product_id`(nullable), `product_name`, `quantity`(number), `unit_price`(number), `line_total`(number, server-computed), `unit`, `section_label`, `calc_category_id`, `calc_snapshot`(JSON object in the canonical schema, see Calculations › "`calc_snapshot`") — last 4 `omitempty`. Responses also carry the item `id` (a revision item id; every save rewrites the items, so ids change after each `PUT`).
- **Item ids on `PUT /offers/{id}`** (mobile since 1.5.14, web always): a kept item is sent with its `id`, a new row without. For an editor without `offers.internal_pricing.manage` the server carries the stored internal cost over by that id. If the draft has items with an internal cost: no id at all → 409 (`ErrOfferInternalPricingUnmatched`, an old app — 1.5.13 and earlier on Play still get this); an id that is not on the current draft → 409 "bu taslak sen düzenlerken değişti…" (`ErrOfferItemsStale`, since 2026-10-11; it used to save and silently drop the internal costs). **`item_ids_sent: true`** (since 2026-10-11) says "I send ids; none here because every existing item was removed" — then an id-less list saves. Mobile sends it only on such a save by an editor without `.manage` (an older server answers 400 to the unknown field — deploy the backend first). Managers send the internal fields themselves; none of these checks apply to them.
- Create validation: >=1 item after dropping blank-name/qty<=0/price<0 rows; quantity is stored with 2 decimals, and a positive quantity that rounds to 0.00 is a 400 (`"X" kaleminin miktarı en az 0,01 olmalıdır`, since 2026-10-11 — it used to vanish silently); `customer_id` OR free-text `customer_name` required. **Company defaults (since 2026-10-07):** on create, omitted/null `vat_rate` → the firm's default VAT (onboarding "Teklif" step; 20% if never saved), omitted/null `currency` → firm default currency (TRY if never saved; must be a 3-letter code, `TL` is read as TRY, otherwise 400), omitted/null `valid_until` → Istanbul today + firm validity days (stays null if the firm has none); `valid_until: ""` = deliberately open-ended. Explicit values (incl. VAT 0) are always kept. On `PUT`, omitted `vat_rate` keeps the revision's current rate (it used to reset to 20%); `currency` is not editable. Offer responses now carry `currency`. **Revise (since 2026-10-11):** a `valid_until` that has already passed is not copied to the new draft revision; it gets Istanbul today + firm validity days instead (null only if the firm has none — it used to be null every time). A date that is still running is copied unchanged.
- Passive customer (since 2026-10-11): `customer_id` of an archived customer (`is_active=false`) → 400 `pasif müşteriye yeni teklif verilemez; önce müşteriyi aktifleştir` on create, and on `PUT` when the draft is not already linked to that customer (a draft linked before the customer was archived stays editable). Mobile hides "Yeni Teklif" on a passive customer's card.
- `GET /offers/defaults` (`offers.create`) → `{vat_rate, currency, validity_days|null, valid_until|null ("YYYY-MM-DD", today Istanbul + days), payment_terms, delivery_terms, footer}` — never bank/IBAN data. Mobile pre-fills KDV and the "Geçerlilik Tarihi" field from it in the new-offer form; the offer detail also reads it (only with `offers.create`, only for a draft without a date) to remind, in the "Gönderildi Olarak İşaretle" / "E-posta Gönder" / "Gönder ve link oluştur" confirmations, that the offer is open-ended while the firm has a validity period (sending is not blocked). The `/teklifler/yeni` route itself shows a no-access page without `offers.create` (fail-open like the entry points: an empty permission set opens the form); `/teklifler/:id/duzenle` needs `offers.update` (fail-closed). **Validity date on mobile (since 1.5.14):** the offer form (new and edit) has a date field; untouched → `valid_until: null` (create → firm default, `PUT` → stored date kept), "Süresiz yap" → `""`, a picked day → that day (the picker starts at today Istanbul; the server rejects past dates). So a draft whose date has passed can be saved without touching the date (since 2026-10-11 the server also accepts the stored date sent back unchanged on `PUT`, as the web form and app builds before 1.5.14 do; only a newly entered past date is rejected); sending it stays blocked (409 `ErrOfferSendExpired`) and the detail screen says so up front — the send buttons explain and lead to the form instead of calling the server. Mobile asks for confirmation before saving an offer with any 0-priced line.
- **Conversion to project is NOT under `/offers`** — it's `POST /projects/from-offer/{offerId}`, requires current revision `status == kabul edildi`, idempotent: a new project → 201. **Since 2026-10-11** an already converted offer returns the existing project with 200 only if the caller passes the same gate as `GET /offers/{id}/project` (`projects.read` + project access); otherwise 409 `{"code":"offer_already_converted"}` without any project data (it used to hand any `projects.create` holder the project, internal notes included). Check-if-converted: `GET /offers/{id}/project` (`projects.read`): 200 = converted (the project), 404 = not yet, 403 `project_access_denied` = converted but the caller is not a member. Mobile (1.5.14) asks only with `projects.read`; it treats only 404 as "not converted", shows a note for `project_access_denied` (no button) and an error with "Tekrar Dene" for anything else (it used to swallow every error as "not converted").
- Notifications (since 2026-10-07, `backend/internal/service/customer_link_notify.go`; `entity_type` `offer`, `action_target` `/teklifler/{id}`, no `project_id`): `offer_accepted` / `offer_rejected` when the customer decides on the share link ("Müşteri teklifi kabul etti" / "Müşteri teklifi reddetti") or staff sets the status ("Teklif kabul edildi" / "Teklif reddedildi", body ends with "· Kaydeden: {name}"; only on a real status change). Recipients, deduplicated, actor excluded, all must hold `offers.read`: the offer's creator, every Owner/Admin, and `offers.update` holders except the legacy "Eski Sistem" role. `offer_viewed` ("Müşteri teklifi açtı"): the FIRST open of a revision while it awaits the customer's decision (current revision, `gönderildi`) — once per revision, not on refresh/second link/draft preview/after the decision; to the creator only, or every Owner/Admin when there is no creator who can still read offers. Body: `TKL-… · {customer} · 1.250.000 TL` (a later revision's open says `TKL-… (Revizyon N)`). The first open is marked in `GET /offers/{id}/events` as a `customer_viewed` row with metadata `first_open: true`. Link-preview fetches (WhatsApp, mail scanners) can't be told apart from the customer: the public page is server-rendered and the API never sees the browser's User-Agent.

## Projects (`requireAuth`, no admin gate; every write across Finance/
Operations/Procurement/Subcontracts below is ALSO gated by a per-domain RBAC
permission code — `projects.finance.read/.manage`, `projects.cost_control.
read`, `projects.tasks.create/.update`, `projects.operations.manage`, plus
the Procurement & Subcontracts codes listed in their own section — checked
client-side with the `_failOpen` pattern (`user == null || user.permissions.
isEmpty || user.hasPermission('<code>')`) next to each action, in addition
to backend enforcement)
- `GET /projects` — params: `status`, `customer_id`, `project_type`, `currency`, `start_from`, `q` (ILIKE name/no/customer), `page`, `limit`. List rows include finance aggregate fields (current_contract_value etc) **only for `projects.finance.read`** (see "Finance visibility" below). No amount-based sort or filter exists.
- `GET/PUT /projects/{id}` — **finance aggregate fields are ABSENT here** (omitempty, always nil on single-object reads). Must call `/financial-summary` separately.
- **Finance visibility (since 2026-10, `canSeeProjectFinance` in `project_handler.go`):** the caller's EFFECTIVE permissions (role + personal grant/revoke) decide. Without `projects.finance.read`, every project object — `GET /projects`, `GET/PUT /projects/{id}`, `POST /projects/from-offer/{offerId}`, `GET /offers/{id}/project` — carries `contract_amount: null` (the key is always present; null means "not shown to you", never zero) and NONE of the list aggregates (`collected_amount`, `total_expenses`, `subcontractor_paid/remaining`, `new_subcontract_paid`, `remaining_receivable`, `realized_cost`, `realized_gross_profit`, `invoice_count`, `paid_invoice_count`, `change_order_net`, `current_contract_value`, and the VAT-exclusive `expense_vat_total`, `contract_vat_known`, `current_contract_value_net`, `realized_cost_net`, `realized_gross_profit_net`). `GET /projects/{id}/events` drops the money keys from `metadata` (see Activity below) and `GET /projects/{id}/cost-control` returns the whole revenue side as null: `summary.contract_value`, `forecast_profit`, `forecast_margin_percent` and `contract_vat_amount`, `contract_vat_known`, `contract_value_net`, `forecast_profit_net`, `forecast_margin_percent_net` (cost figures incl. `actual_cost_net`/`eac_net` unchanged). Non-money fields are unchanged for everyone. The app parses all of these as nullable (`Project.contractAmount`, `ProjectEditable.contractAmount`, `CostControlSummary.hasRevenue`) and draws no amount when null. **App builds before this change cast `contract_amount` as a non-null number and fail to load the project list/detail for users without finance.read** — the backend may go live only after the null-tolerant app (1.5.14) is on Play and has reached users (force it with the server's `min_build` if needed); shipping both together is not enough.
- `PUT /projects/{id}` (project-scoped `projects.update`; mobile "Proje bilgilerini düzenle", `/projeler/:id/duzenle`, since 1.3.0+4) — body is exactly `{name, project_type, status, start_date, end_date, description, internal_notes}`. Money/currency/customer/source offer are NOT editable here and are never sent. `status` must follow the machine below.
- `GET /projects/{id}/financial-summary` → 21 always-present number fields: `current_contract_value`, `collected_amount`, `remaining_receivable`, `realized_cost`, `committed_cost` (closest to "estimated cost"), `estimated_gross_profit`, etc. This is the authoritative source for the finance screen header.
- **Cost definitions (2026-10, migration 0073, `docs/maliyet-tanimlari.md`):** `realized_cost` is ACCRUAL-based. It is approved expenses + legacy subcontractor WORK payments + the subcontract module's realized work (certified claims, unpaid and retention included; an unlinked payment up to the contract's advance is an advance, not cost). New always-present fields:
  - `paid_cost`: cash, advances included;
  - `advance_open`: un-offset advances, not cost;
  - `pending_cost` = `pending_expenses` (awaiting approval) + `new_subcontract_pending_claims` (submitted claims);
  - `subcontractor_work_paid`, `subcontractor_advance_open`;
  - `new_subcontract_accrued`, `new_subcontract_advance_open`, `new_subcontract_payable` (certified net − work payments), `new_subcontract_retention`.

  `subcontractor_paid` / `new_subcontract_paid` stay cash. Remaining commitment per engagement = contract − WORK paid (legacy) / current value − realized work (module); an open advance stays inside it. List rows' `realized_cost` and the dashboard's `realized_cost` use the same view (`project_cost_basis`).
- Status machine: `planned→{active,paused,cancelled}`, `active→{paused,completed,cancelled}`, `paused→{active,completed,cancelled}`, `completed→active only`, `cancelled` terminal.
- No plain POST/DELETE on projects.

### Project delete (since 2026-10-14, migration 0070; mobile 1.5.17)

**Who can delete**
- `projects.delete` is held by owner and admin. Custom roles can be given it; legacy users do not get it.
- `DELETE /projects/{id}` (`projects.delete` + project access) → `{ok:true}`.

**What blocks a delete**
- Any expense, collection, legacy or contract subcontractor payment, invoice, purchase request, RFQ, purchase order or subcontract. Voided rows count too.
- A blocked delete returns 409 with a message that counts what blocks it. The user should set the project to İptal instead.

**What a delete removes**
- Tasks, notes, files, photos (including storage objects), payment plan, change orders, budget, WBS, contract, team and events.
- The source offer can be converted again. Its timeline gets `project_deleted`.

**Delete requests** (same shape as offer delete requests, keyed by `project_id`)
- `POST /projects/{id}/delete-request` `{reason?}` (`projects.update`) → 201. Blocked by the same records (409); a duplicate request → 409.
- `DELETE /projects/{id}/delete-request` withdraws it. Only the requester can.
- `POST .../delete-request/approve` and `.../reject {note?}` (`projects.delete`).
- `GET /projects/delete-requests` (`projects.delete`) → `{data: [... + project_no, project_name, customer_name]}`.
- `GET /projects/{id}` carries `delete_request` while one is pending.
- Notifications: `project_delete_requested|approved|rejected`. Home attention code: `project_delete_approval` (ref kind `project`).

### Finance sub-resources (all under `/projects/{id}/...`)
- `payment-plan` (GET/POST/PUT/DELETE-soft), `collections` (GET/POST/void), `expenses` (GET/POST/PUT/void), `invoices` (GET/POST/PUT status), `subcontractors` + `subcontractor-payments` (GET/POST/PUT/void).
- Expense create `{category, description, amount, currency, expense_date, supplier_name, invoice_no, notes, idempotency_key, change_order_id, cost_code_id, budget_line_id}` (links optional, empty string = none; when a budget line is chosen the server takes the cost code from the line). `category` ∈ `material|personnel|transport|accommodation|food|equipment|other`. Void via `POST .../{id}/void {reason}`.
- Expense approval (backend migration 0060): every expense row carries `approval_status` (`pending|approved|rejected`), `decided_by`, `decided_at`, `decision_note` (rejection reason). Every new expense starts `pending`, whoever enters it; `PUT .../expenses/{id}` puts it back to `pending` and clears the decision. Only `approved` + non-voided expenses count in ANY total (financial summary, cost control actuals/EAC, project list, change-order cost, dashboard). `POST .../expenses/{id}/approve` (no body) and `POST .../expenses/{id}/reject {reason}` (reason required, ≤ 500 chars) need `projects.expenses.approve` (default since migration 0066: owner + admin only; Finans lost it) + project access; closed project 409, already decided 409. Void works for every status. Mobile: list rows badge pending/rejected (approved rows have no badge), a "N masraf onay bekliyor" note on top, Onayla/Reddet in the expense detail for approvers (`canAccess`, open project); the form says "Masraf onaya gönderildi." after saving. Notifications: `expense_pending_approval` (to approvers, grouped, entering user excluded), `expense_approved` / `expense_rejected` (to the creator); `entity_type` `project_expense`, `action_target` `/projeler/{id}?grup=finans&alt=finans`.
- Expense VAT (backend migration 0065, product decision 2026-10-07): create/update take an optional `vat_rate` (0–100, %); field missing or `null` = "Belirtilmedi" (NULL — the amount counts in full, as before; the web form does not send it). `amount` stays what was paid (VAT-inclusive when a rate is given). Rows return `vat_rate`, `vat_amount` (= round(amount × rate / (100 + rate), 2), generated in the DB) and `net_amount` — all three `null` when not specified. Mobile omits the key instead of sending `null` (older servers reject unknown fields). `PUT .../expenses/{id}` rewrites the WHOLE row (now including `vat_rate` and `change_order_id`): send every unchanged field back as read; `projects.finance.manage`, open project, non-voided; the expense goes back to `pending`. Mobile: KDV chips (Belirtilmedi / KDV yok (%0) / %1 / %10 / %20) with a live "KDV hariç · KDV" preview; "Düzenle" in the expense detail opens the same form pre-filled (rejected expenses show the reason; approved ones confirm before saving), then "Masraf güncellendi; yeniden onaya gönderildi."
- Expense entry for everyone (backend migration 0066, product decision 2026-10-07: "masrafı herkes girsin ama onay beklesin; onayı sadece en üst yönetim yapsın"):
  - `POST /projects/{id}/expenses` needs `projects.expenses.create` (granted to EVERY role by default; firms can remove it in Roller & Yetkiler) + project access — no longer `projects.finance.manage`. Every new expense is `pending`.
  - A caller WITHOUT `projects.finance.manage` may send only the basic fields (`category, description, amount, currency, expense_date, vat_rate, supplier_name, invoice_no, notes, idempotency_key`). Non-empty `change_order_id` / `cost_code_id` / `budget_line_id` → **403** `{"error": "masrafı ek işe, bütçe kalemine veya maliyet koduna bağlamak finans yönetme yetkisi ister; ..."}` (refused, not silently dropped, so a client never believes a link was saved). On `PUT` the links may be empty or exactly the stored values (both mean "keep"); the stored links are always kept. Receipts/documents are separate uploads (see "Expense receipts" below, since migration 0076).
  - `PUT .../expenses/{id}` and `POST .../expenses/{id}/void {reason}` accept `projects.finance.manage` (every expense, any status — unchanged) OR `projects.expenses.create` (only the caller's OWN expense while `pending` or `rejected`; editing a rejected one puts it back to `pending`; void = "Geri çek", `voided_by` = the creator). Someone else's expense → **409** "yalnızca kendi girdiğiniz masrafı düzenleyebilir veya geri çekebilirsiniz"; own approved → **409** "onaylanmış masraf yalnızca finans yetkilisi tarafından ..."; already voided 409; closed project 409.
  - Rows now also carry `project_id`, `created_by`, `voided_by` (all expense responses).
  - General (no-project) expenses (since 2026-10-14, migration 0068; mobile 1.5.16). They are `project_expenses` rows with `project_id` NULL (`"project_id": ""` in JSON). They have the same body and the same rules as project expenses: pending until an approver decides, own-only edits, and no self-decision except the owner. Change order, cost code and budget line links are rejected with 400. Currency defaults to TRY. General expenses never enter project totals.
    - `POST /expenses/general` (`projects.expenses.create`).
    - `PUT /expenses/general/{expenseId}` and `POST /expenses/general/{expenseId}/void` {reason} (`projects.finance.manage` on any row; `projects.expenses.create` only on the caller's own pending or rejected row).
    - `POST /expenses/general/{expenseId}/approve|reject` (`projects.expenses.approve`).
    - Mobile `ProjectsRepository` expense methods switch to these paths when `projectId` is empty.
  - `GET /expenses?kind=general|project&status=pending|approved|rejected|voided&project_id=&date_from=&date_to=&mine=1` (`projects.expenses.create`) → `{expenses, limit: 500, truncated, can_see_all, totals?}`.
    - Rows: expense shape + `project_name/project_no/project_status` (empty for general) + `is_general` + `created_by_name`.
    - Holders of `projects.finance.read` see everyone's rows (project rows limited to member projects for membership-restricted roles) and get `totals: [{currency, approved, pending}]`. Others, or `mine=1`, see only their own rows and no totals.
    - Mobile: "Masraflar" (`/diger/masraflar[?durum=pending]`).
  - Pending general expenses join the `expense_approval` home group with ref kind `expenses` (→ `/diger/masraflar?durum=pending`).
  - `GET /expenses/mine[?project_id=<uuid>]` (`projects.expenses.create`) → `{expenses: [...], limit: 200}`: ONLY the caller's own expenses (incl. voided/withdrawn), newest entry first, max 200, in projects the caller can access (membership-restricted roles: member projects only; owner/admin/legacy: all). Each row = the expense shape above + `project_name`, `project_no`, `project_status`. No totals, no summary. Invalid `project_id` → 400. `GET /projects/{id}/expenses` and `/financial-summary` still need `projects.finance.read` (field users get 403).
  - Approve/reject: nobody may decide their OWN expense except the firm owner (Sahip — nobody above them) → **409** "kendi girdiğiniz masrafı onaylayamaz veya reddedemezsiniz; ...". Status is checked first (decided/voided → 409 not-pending / already-voided).
  - Mobile (next release, Yenilikler build 16): "Masraf Gir" (home quick action) and "Masraf Ekle" (project Özet + Finans list) need only `projects.expenses.create`; without `projects.finance.manage` the form shows no Ek İş / Bütçe Kalemi / Maliyet Kodu pickers (none are even loaded) and sends the three links empty. "Masraflarım" (`/diger/masraflarim[?proje=<id>][&masraf=<expenseId>]`, `lib/features/projects/my_expenses/`): Diğer > İş Araçları, home quick action "Masraf Takibi", and on the project Özet for users without `projects.finance.read`; filter chips Tümü / Onay bekliyor / Reddedildi / Onaylandı, status chip per row (Geri çekildi when `voided_by == created_by`), red "Red nedeni", no totals; `?masraf=` opens that expense's detail once. Detail actions come from `expenseActionsFor` (`lib/features/projects/domain/expense_actions.dart`): Düzenle (finance.manage, or own pending/rejected), İptal Et with reason (finance.manage), Geri Çek without reason (own pending/rejected, no finance.manage), Onayla/Reddet (`canAccess(projects.expenses.approve)`, pending, not own unless `organization_role_code == owner`; otherwise the note "Bu masrafı sen girdin; başka bir yöneticinin onaylaması gerekir.").
  - Notifications: `expense_pending_approval` skips both the actor and the creator. `expense_approved/rejected` go to the creator with `action_target` `/projeler/{id}?grup=finans&alt=finans` if the creator has `projects.finance.read`, otherwise `/diger/masraflarim?masraf=<expenseId>` (mobile opens Masraflarım with that expense's detail). Dashboard `expense_approval` agenda leaves out the viewer's own pending expenses unless the viewer is the owner.
  - General expenses visible to the people who enter and decide them (2026-10-29, migration 0076 release; user feedback "Genel giren masraflar hiç gözükmüyor"):
    - `GET /expenses/mine` now also returns the caller's general (no-project) expenses: `project_id: ""`, empty `project_name/project_no/project_status`, `is_general: true` (every row now carries `is_general`). `?project_id=` still filters to that project (general rows drop out). Same edit/withdraw rules as before (own pending/rejected only, general routes `/expenses/general/{id}`).
    - `GET /expenses` is open to `projects.expenses.create` OR `projects.expenses.approve` and returns `scope`: `all` (`projects.finance.read`: everyone's rows + `totals`, as before), `approver` (`projects.expenses.approve` without finance read: own rows + everyone else's non-voided rows that are `pending` or were decided in the last `approver_recent_days` = 30 days, in projects the caller can access, plus general ones; no `totals`), `mine` (everyone else, and `mine=1`). `can_see_all` is unchanged (true only for `all`). `created_by_name` is filled in every scope.
    - Pending-approval notification targets: general expenses → `/diger/masraflar?durum=pending`; project expenses → `/projeler/{id}?grup=finans&alt=finans` for approvers with `projects.finance.read`, `/diger/masraflar?durum=pending` for approvers without it (they cannot open the project Finans view). General-expense decisions → `/diger/masraflarim?masraf=<expenseId>` (was `/diger/masraflar`).
    - Unchanged: the home `expense_approval` agenda lives in the finance section (needs `projects.finance.read`); approvers without it rely on the notification and Masraflar's "Onay bekliyor" chip.
  - Expense receipts / documents (since migration 0076; user feedback "Masraf girme yerine resim ve dosya ekleme gibi bir yer olsun"). Several attachments per expense, project AND general expenses, same endpoints under both bases — `{base}` = `/projects/{id}/expenses/{expenseId}` or `/expenses/general/{expenseId}`:
    - `GET {base}/attachments` → `{attachments: [...], max: 10}` (oldest first). Gate: `projects.finance.read` | `projects.expenses.create` | `projects.expenses.approve` (+ project access on project routes).
    - `GET {base}/attachments/{attachmentId}/content` → the bytes, `Content-Type` = detected type, `X-Content-Type-Options: nosniff`, `Content-Disposition: inline`, `Cache-Control: private, max-age=300`. Auth required (cookie, via ApiClient — never `Image.network`). Same gate as the list.
    - `POST {base}/attachments` multipart field `file` (≤ 25 MB) → **201** attachment, or **200** with the EXISTING attachment when the same content (sha256) is already on this expense (a retried upload never duplicates). Gate: `projects.finance.manage` | `projects.expenses.create`.
    - `DELETE {base}/attachments/{attachmentId}` → `{ok: true}`; permanent (row + stored file). Same gate as upload.
    - Attachment shape: `{id, expense_id, original_name, mime_type, size_bytes, sha256, uploaded_by, created_at}`. Accepted content (detected from bytes, not the client's type): `image/jpeg`, `image/png`, `image/webp`, `image/heic`, `image/heif`, `application/pdf` — anything else **400** "yalnızca fotoğraf (JPEG, PNG, HEIC) ya da PDF eklenebilir"; empty **400**; > 25 MB **413**; 11th attachment **409** "bir masrafa en fazla 10 fiş veya belge eklenebilir".
    - Read rule (service): finance read/manage → any expense; the creator → own; an approver → non-voided expenses that are pending or decided within 30 days (same as the `approver` list scope). Anyone else → **404** (the expense is "not found"; existence is not leaked). A project route only serves that project's expense, a general route only general ones (404 otherwise).
    - Write rule: approved or voided expense → **409** "onaylanmış/iptal edilmiş masrafın fiş ve belgeleri değiştirilemez" (for everyone — the approver decided on what they saw); otherwise `projects.finance.manage` any expense, else only the creator (others who can read it, e.g. an approver → **409** "yalnızca kendi girdiğiniz masrafa fiş veya belge ekleyip silebilirsiniz"). Closed project → 409. Adding/removing serializes with approve/reject (same lock).
    - List rows of `GET /projects/{id}/expenses`, `GET /expenses/mine`, `GET /expenses` and the `PUT` (edit) responses carry `attachments: [...]` (empty array when none); other expense responses (create, approve, reject, void) omit the key. Voided/approved expenses keep their attachments read-only; `cmd/purge-project` deletes the stored files with the project.
    - Mobile (next release, `lib/features/projects/expense_attachments/`): the NEW-expense form has a "Fiş / Belge" section (Fotoğraf çek / Galeriden seç / Dosya seç — the file picker accepts only pdf/jpg/jpeg/png/webp/heic/heif names; thumbnails; remove before saving). After the expense is created each file is uploaded with a progress line; if one fails the expense stays saved ("Masraf kaydedildi ama N belge yüklenemedi. Masrafın ayrıntısından tekrar deneyebilirsin.") and the file waits in the expense detail with "Tekrar dene" / "Vazgeç" (`failedExpenseUploadsProvider`, session only). The edit form has no picker — existing expenses add/remove documents in the detail ("Belge ekle", trash icon on a tile; `ExpenseActions.canManageAttachments` = open project, not voided, not approved, finance.manage or own). Every expense detail (project Finans list, Masraflarım, Masraflar incl. the approver scope) shows "Fiş / Belge (N)" from the row's `attachments`: photo tiles load bytes via ApiClient (`expenseAttachmentBytesProvider`, disk cache under the photo cache dir, cleared on logout), tap = full-screen photo; PDF/HEIC tiles open with the OS viewer (`documentOpenerProvider`). Cards show a paperclip count (Masraflar/Masraflarım) or "N belge" (Finans list). Masraflar: shown to `projects.expenses.create` OR `projects.expenses.approve` (menu + screen), "Masraf Ekle" only with create, creator names for every scope except `mine`, approver footer text; Masraflarım lists general expenses as "Genel masraf".
- Financial summary VAT fields: `contract_vat_amount`, `contract_vat_known`, `current_contract_value_net`, `expense_vat_total` (VAT inside approved, non-voided expenses), `realized_cost_net`, `committed_cost_net`, `forecast_cost_net` (budget basis = Cost Control's `eac_net` + legacy subcontractors; EAC contains no uncoded expense, so only the VAT of cost-coded expenses comes out), `*_gross_profit_net`, `*_margin_percent_net`, `forecast_profit_net`, `forecast_margin_percent_net`. Gross fields are unchanged. When `contract_vat_known` is false the cost nets are still real VAT-exclusive costs but the profit/margin nets equal the gross ones. Mobile shows "Maliyet (KDV hariç)" only when it differs from the gross cost; profit rows show the server's `*_net` values as-is.
- VAT-exclusive figures everywhere else (2026-10-09; one rule, backend `domain.VATBasis`/`CostNet`, the same as the financial summary: cost − VAT inside approved non-voided expenses, an expense without a rate counts in full, subcontractor payments as they are; profit = VAT-exclusive value − VAT-exclusive cost, or the gross cost when the value's VAT is unknown). Unsuffixed fields keep their VAT-INCLUSIVE meaning everywhere (same as the summary's); only `*_net` fields are new, nothing was renamed:
  - `GET /projects` list rows: `expense_vat_total`, `contract_vat_known`, `current_contract_value_net`, `realized_cost_net`, `realized_gross_profit_net` (absent on single reads and without `projects.finance.read`, like the other aggregates). For the same project they equal the financial summary's fields of the same name, and `realized_cost` / `realized_gross_profit` / `current_contract_value` / `remaining_receivable` equal the summary's to the kuruş (same cost set: approved expenses + legacy + subcontract-module payments).
  - `GET /projects/{id}/cost-control`: every line and the summary add `actual_cost_net` and `eac_net` (= `actual_cost_net` + `etc`; ETC is still derived from the VAT-inclusive actual and its VAT is unknown); the summary adds `contract_vat_amount`, `contract_vat_known`, `contract_value_net`, `forecast_profit_net`, `forecast_margin_percent_net`. `actual_cost`, `eac`, `variance`, `forecast_profit`, `forecast_margin_percent` are unchanged (VAT-inclusive). The revenue side — `contract_value`, `forecast_profit`, `forecast_margin_percent` and the five revenue `*_net`/VAT keys — is written in one place (`setCostControlRevenue`) and is shown or hidden as a whole (all null without `projects.finance.read`); `actual_cost_net`/`eac_net` are cost figures and follow `actual_cost`/`eac`.
  - `GET /change-orders` → `profitability` adds `revenue_effect_net` (signed subtotal), `realized_cost_net`, `committed_cost_net`, `realized_profit_net`, `estimated_profit_net`, `realized_margin_percent_net`, `estimated_margin_percent_net` (margins on |net revenue effect|, kuruş precision).
  - `GET /dashboard` → `finance.by_currency[].realized_cost_net`. `realized_cost` (accrual, same as the summary since 2026-10), `paid_cost`, `cash_balance` (= collected − `paid_cost`) and `month.*` stay VAT-inclusive (collections are VAT-inclusive).
  - Not yet shown by the clients: mobile Maliyet Kontrolü ("Tahmini Kâr/Marj") and Ek İş "Kârlılık (dahili)" still show the VAT-inclusive values (web the same, plus the project list's "Brüt Kâr" column); switch both platforms together.
- Collection create `{amount, received_date, payment_method, description, reference_no, payment_plan_item_id (null = not linked), idempotency_key}`; `currency` omitted = project currency. A linked collection raises the plan item's "Tahsil Edilen".
- Mobile (since 1.4.0+5, Finans > "Finans" view, `lib/features/projects/finance_ledger/`): tapping an expense/collection opens its detail (links resolved to "EK-… · title", cost code, plan item) and "İptal Et" (`projects.finance.manage`, open project only, reason REQUIRED in the app — the web allows an empty one). Expense form offers Ek İş / Bütçe Kalemi / Maliyet Kodu pickers (each loaded only with its read permission: `projects.finance.read`, `projects.budget.read`, `organization.cost_codes.read`), collection form offers the open plan items. Both forms keep one `idempotency_key` per form instance and parse Turkish amounts ("64.000" = 64 000, "1.250,50"). Add/void hidden on completed/cancelled projects (backend 409).
- Legacy subcontractors ("Taşeron Ödemeleri", `projects.finance.read/.manage`, same folder): `GET /subcontractors` → `{subcontractors}` (server computes `paid_amount`/`remaining_amount`), `GET /subcontractor-payments` → `{payments}`, `POST /subcontractors {name, company_name, work_description, contract_amount, currency}`, `POST /subcontractors/{subId}/payments {amount, currency, paid_date, payment_kind?, description, idempotency_key}` (key per subcontractor + form).
  - `payment_kind` is `work` (default; old clients) or `advance`; any other value → 400.
  - Work payments count as realized cost and are never also entered as expenses. An advance is paid but not cost until `POST /subcontractor-payments/{paymentId}/offset` (`projects.finance.manage`, "İşe say") turns it into a work payment. That call returns the payment with `payment_kind: "work"` and `offset_at`. A work, voided or already-offset payment → 409; a locked project → 409.
  - Payment rows carry `payment_kind` and `offset_at`. Separate from the Sprint 5 subcontract CONTRACTS (`/subcontracts`, Operasyon > Taşeronlar).
- Activity (`projects.read`, `lib/features/projects/activity/`, `/projeler/:id/aktivite`): `GET /projects/{id}/events` → `{events: [{id, event_type, user_id, metadata, created_at}]}` (created_at ASC; the app shows newest first, grouped by Istanbul day, Turkish labels from `core/utils/event_labels.dart`). Every event is returned to every project reader, but without `projects.finance.read` the server drops the money keys (`amount`, `planned_amount`, `contract_amount`, `grand_total`, `total`, `net_payable`, `etc_amount` — backend `domain.ProjectEventMoneyKeys`) from `metadata`; the app also shows amounts ONLY with `projects.finance.read` and writes the detail without an amount when the key is missing.
- `change-orders`: state machine `draft→sent→{approved(final),rejected}`, `sent|rejected→(revise)→superseded+new draft`, `draft|sent→(cancel)→cancelled`. The customer decides via the public link, or staff records a phone/paper decision (`record-decision`, below). **Cancel takes no reason body.**

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
  estimate instead of erroring). The revenue side (`summary.contract_value`,
  `forecast_profit`, `forecast_margin_percent`) is null without
  `projects.finance.read`; cost figures are unchanged.
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

**Project change orders** (`projects.finance.read/.manage`, plus `projects.change_orders.approve` for recording the customer's decision; same folder):
- `GET /change-orders` → `{change_orders}` (includes internal profitability + active share link), `GET /change-orders/{coId}` (items; NO profitability — app merges it from the list row), `POST /change-orders` (201), `PUT /change-orders/{coId}` (draft only). Item: `{product_id?, description, quantity, unit, unit_price, estimated_unit_cost?}` — keep `product_id`/`estimated_unit_cost` on edit.
- `POST .../{coId}/send` (draft→sent + share link `/ek-is/{token}`), `POST .../{coId}/send-email {to, subject, message}`, `POST .../{coId}/revise` (sent|rejected → new draft, old one superseded), `POST .../{coId}/cancel` (NO body — cancel takes no reason).
- `POST .../{coId}/record-decision {decision: "approved"|"rejected", note}` (`projects.change_orders.approve`, default Owner/Admin; since 2026-10-07): "Müşteri onayladı/reddetti olarak işaretle" for a SENT change order. Same code path and rules as the public link (sent only → else 409; a deduction that would make the contract value negative → 409; same `change_order_approved|rejected` event, now with `user_id` and metadata `source: "staff"`, `note`). Change order responses carry `decision_recorded_by` (null = customer's own link), `decision_recorded_by_name`, `decision_note` (internal, never on the public page). The share link is not revoked; it just stops accepting answers. Without `projects.finance.read` the response is a money-free receipt (id, no, type, title, status, decision timestamps/recorder/note — no totals, items, profitability, internal notes or share token); `ProjectChangeOrder.fromJson` reads it without crashing.
- Decision notifications (since 2026-10-07; link and `record-decision` share one code path): `change_order_approved` / `change_order_rejected`, `entity_type` `change_order`, `project_id` set, `action_target` `/projeler/{id}/ek-isler/{coId}`. Titles: customer link "Müşteri ek işi onayladı" / "Müşteri ek işi reddetti"; staff record "Ek iş onaylandı" / "Ek iş reddedildi" (body ends with "· Kaydeden: {name}"). Body: `EK-003 {title} · {project} · +15.000 TL` (deductions `-`); if the reader's `projects.finance.read` was removed after the notification was created, `GET /notifications` and the dashboard drop the signed amount part (`EK-003 {title} · {project}`). Recipients, deduplicated, recorder excluded, all must hold `projects.finance.read` and be able to open the project: the change order's creator, every Owner/Admin, and `projects.change_orders.approve` holders who are on the project's Erişim list.
- There is NO change-order email-log list endpoint; the mail history is read from `GET /projects/{id}/events` rows `change_order_email_sent|failed` (payload carries the recipient).

**Budget / cost control** (`lib/features/projects/budget/`):
- `projects.budget.read`: `GET /wbs`, `GET /budget` (404 = no budget), `GET /budget/lines` (404 = no budget), `GET /budget/adjustments`.
- `projects.budget.manage`: `POST /wbs`, `PUT/DELETE /wbs/{nodeId}` (DELETE = archive), `POST /budget`, `POST /budget/baseline`, `POST /budget/lines`, `PUT/DELETE /budget/lines/{lineId}` (draft budget), `POST /budget/adjustments` (non-zero, may be negative; notifies `projects.budget.approve` holders with project access, creator excluded).
- `projects.budget.approve` (since 2026-10-07, default Owner/Admin/Finance): `POST /budget/adjustments/{adjId}/approve|reject`. 409 with a Turkish message when deciding your OWN adjustment (Owner exempt) or when approval would make the line's revised budget negative. Adjustment rows carry `created_by`/`approved_by`; the app hides approve/reject on the user's own adjustment unless Owner.
- `projects.cost_control.read`: `GET /commitments`, `GET /forecasts`, `GET /cost-control`. `projects.cost_control.manage`: `POST /commitments` (manual, `idempotency_key`), `POST /commitments/{cId}/void {reason}` (app offers void ONLY for active manual commitments), `PUT /budget/lines/{lineId}/forecast`.
- Pickers/breakdown: `GET /organization/cost-codes` (`organization.cost_codes.read`), `GET /projects/{id}/expenses` (`projects.finance.read`; the "Gerçekleşen" card is hidden without it).

**Payment plan & invoices** (`projects.finance.read/.manage`, `lib/features/projects/finance_plan/`):
- `GET /payment-plan` → `{items, planned_total}`, `POST /payment-plan` (amount OR percentage, optional `due_date`, `notes`), `PUT /payment-plan/{itemId}` (full body), `DELETE /payment-plan/{itemId}` (cancels the item; row kept, no restore). No single-item GET — detail is derived from the list.
- `GET /invoices` → `{invoices}`, `POST /invoices` (`invoice_type` sales|purchase, `invoice_no`, amounts, `invoice_date`, `due_date?`, `customer_name?`, `notes?`), `PUT /invoices/{invoiceId}/status {status}` (any of the 5 statuses; no state machine server-side). No invoice field-edit endpoint.

**Schedule, team, access** (`lib/features/projects/ops_team/`):
- `projects.operations.read/.manage`: `GET/POST /schedule`, `PUT /schedule/{itemId}` (rewrites EVERY field — always send `{name, description, start_date, end_date, status, sort_order}`; no DELETE — the app "cancels" instead), `GET/POST /members {employee_id, role_title, start_date, notes}` (409 if already active), `DELETE /members/{memberId}` (ends the membership, sets `end_date`), `GET /employees?filter=aktif` (member picker, `employees.read`).
- `projects.access.read/.manage`: `GET /access` → `{users}`, `POST /access {user_id, project_role}`, `PUT /access/{userId} {project_role}`, `DELETE /access/{userId}`, `GET /users?limit=200` (user picker; coarse admin + `organization.users.read`, fetched only when the grant sheet opens).

**Deep links** (`lib/features/dashboard/domain/mobile_routes.dart`): `milestone` → `/projeler/{p}/planlama/{id}`, `change_order` → `/projeler/{p}/ek-isler/{id}`, `contract` → `/projeler/{p}/sozlesme`, `payment_plan_item` → `/projeler/{p}/odeme-plani/{id}`, `invoice` → `/projeler/{p}/faturalar/{id}`, `budget_adjustment` → `/projeler/{p}/maliyet/revizyonlar`. Project sub-views: `?grup=finans&alt=finans|sozlesme|odeme-plani|faturalar|taseron-odemeleri|ek-isler|maliyet`, `?grup=operasyon&alt=taseronlar|satin-alma|gorevler|planlama|ekip|erisim`, `?grup=dokumanlar&alt=dosyalar|notlar`.

## Subcontractors / Taşeronlar (since 2026-10-14, migration 0069; mobile 1.5.16)

A subcontractor card is a `suppliers` row with `is_subcontractor=true`. Supplier responses now carry `is_subcontractor`.

**Linking simple project subcontractors to cards**
- `POST /projects/{id}/subcontractors` accepts `supplier_id`. Name, company, phone and email default from the card. An archived card → 400.
- Without `supplier_id`, the server links the record to a card with the same name (case and extra spaces ignored), or creates a new `TSR-NNNN` card. Old clients and the web stay linked this way.
- `PUT` with a non-empty `supplier_id` relinks; empty keeps the current link.
- Responses carry `supplier_id`.

**Endpoints**
- `GET /subcontractors` (`organization.suppliers.read`) → `{subcontractors: [supplier + paid_totals? + remaining_totals?], can_see_totals}`.
  - `paid_totals: [{currency, amount}]` sums non-voided simple project payments, contract subcontract payments and direct payments.
  - `remaining_totals: [{currency, amount}]` (since 1.5.18, migration 0071 release) sums, per job, `max(contract − paid, 0)` over non-cancelled simple project subcontractors and active/completed subcontracts (`original_amount`, same as the ledger). Currencies with zero remaining are omitted.
  - Totals are returned only to holders of `projects.finance.read`. For membership-restricted roles, project payments count only from member projects.
- `POST /subcontractors` (`organization.suppliers.manage`) takes the supplier body. An empty `code` gets `TSR-NNNN`.
- `POST /subcontractors/{id}/mark` (`organization.suppliers.manage`) flags an existing catalog supplier as a subcontractor.
- `GET /subcontractors/{id}/ledger` (`organization.suppliers.read` + `projects.finance.read`) → `{subcontractor, engagements, payments, paid_totals}`.
  - `engagements`: `{kind: simple|contract, id, project_id/name/no/status, title, status, currency, contract_amount, paid_amount, remaining_amount}`.
  - `payments` (voided included, newest first, max 500): `{source: simple|contract|direct, id, project_id?, project_name, project_no, engagement_id?, amount, currency, paid_date, description, voided_at?, void_reason, kind}`. `kind` is `work` / `advance` / `general`; `general` is a non-project payment. A contract payment not linked to a claim is `advance` when the contract has an advance amount.
  - `site_days` (since 1.5.18; newest first, max 90): `{report_date, project_id, project_name, project_no, workers, work_note}` from daily site reports. Membership-restricted roles see member projects only.
- `POST /subcontractors/{id}/payments` `{amount, currency?, paid_date, description?, idempotency_key, payment_kind?}` (`projects.finance.manage`) records a non-project (direct) payment. `payment_kind` is `general` (default) or `advance`, for information only; it never enters project cost. An archived card → 409.
- `POST /subcontractors/{id}/payments/{paymentId}/void` `{reason?}` (`projects.finance.manage`). Voiding an already voided or unknown payment → 404.

**Mobile**
- Diğer → "Taşeronlar" (`/diger/taseronlar`, `/diger/taseronlar/:id`).
- On the ledger screen, "Ödeme Yap" lets the user pick either a non-project payment or one of the card's simple project jobs. Project jobs go to `POST /projects/{pid}/subcontractors/{sid}/payments`.
- The project "Taşeron Ekle" form has a card picker.
- 1.5.18: the list shows "Kalan" (remaining_totals); the ledger shows "Sahada Çalıştığı Günler" (tap → that day's report), tap-to-call on the phone, and "Kartı düzenle" (`organization.suppliers.manage`, reuses the supplier form → `PUT /suppliers/{id}`).

## Daily site report / Günlük Şantiye Raporu (since 2026-10-15, migration 0071; mobile 1.5.18)

One report per project per day (`UNIQUE(project_id, report_date)`). Read and PDF = `projects.operations.read`; save and submit = `projects.operations.manage` (all `projPerm`, project access required). `{date}` is `YYYY-MM-DD`; a malformed date → 400.
- `GET /projects/{id}/daily-reports` → `{reports: [{id, report_date, weather, temperature_c?, own_workers, subcontractor_workers, status, work_done, created_by_name, photo_count}], today}` (newest first, max 120; `today` is the Istanbul date). Another org's project → 404.
- `GET /projects/{id}/daily-reports/{date}` → always 200. `{exists, id, project_id, report_date, weather, temperature_c?, own_workers, work_done, issues, materials, notes, status: draft|submitted, submitted_at?, submitted_by_name, created_by_name, updated_at?, subcontractors: [{supplier_id, name, specialty, workers, work_note}], suggested_own_workers, completed_tasks: [{id, title, assigned_name}], photos: [{id, stage, description}], subcontractor_options: [{supplier_id, name, specialty}]}`.
  - `exists=false`: the day has no report yet; the auto fields are still filled.
  - `suggested_own_workers`: project team members (`project_members` active that day) whose attendance is `geldi` or `yarım gün`.
  - `completed_tasks` / `photos`: tasks completed / photos uploaded on that Istanbul day.
  - `subcontractor_options`: active cards linked to the project (simple job not cancelled, subcontract not cancelled/terminated) or used in its earlier reports. The field role has no `organization.suppliers.read`, so the app's picker uses this list.
- `PUT /projects/{id}/daily-reports/{date}` `{weather: ''|sunny|cloudy|rainy|snowy|windy, temperature_c?: -50..60, own_workers: 0..10000, work_done, issues, materials, notes (≤4000 chars each), subcontractors: [{supplier_id, workers, work_note ≤300}] (≤30)}` → the report. Upsert; the subcontractor list is replaced as a whole. A future date, a bad value or a duplicate card → 400; an unknown/other-org card → 404; a completed/cancelled project → 409. A submitted report stays submitted when edited.
- `POST /projects/{id}/daily-reports/{date}/submit` → the report. No report for that day → 404; already submitted → 409. Notifies the project's managers (firm Sahip/Yönetici + `projects.update` holders on the access list), except the sender: type `daily_report_submitted`, target `/projeler/{id}/gunluk-rapor/{date}`. Writes project event `daily_report_submitted` (feed: `projects.operations.read`).
- `GET /projects/{id}/daily-reports/{date}/pdf` → `application/pdf` (`Gunluk-Rapor-<project_no>-<date>.pdf`). Up to 6 JPEG/PNG photos of the day, downscaled to 1400 px. No report → 404.

**Mobile**
- Project → Operasyon → "Günlük Rapor" (`?grup=operasyon&alt=gunluk-rapor`), full screens `/projeler/:id/gunluk-rapor` and `/projeler/:id/gunluk-rapor/:date`.
- Home quick action "Günlük Rapor" (`projects.operations.manage`): pick a project → today's report.

## Inventory / Stok Takibi (since 2026-10-15, migration 0072; mobile 1.5.19)

Standalone warehouses and stock, not tied to projects. Permissions are role permissions (Roller screen):
- `inventory.read`: view.
- `inventory.manage`: item cards, receipt, issue, transfer, attachments. Unit cost and stock value are returned only to holders.
- `inventory.adjust`: warehouses, waste, count, reversal.

Defaults: owner/admin all three; finance, project_manager and legacy_user read + manage; field read only.

Rules:
- Quantities are `numeric(14,3)`.
- Cost is the moving weighted average per item, VAT excluded. Transfers don't change cost.
- A project on an issue is information only; it never adds project cost.
- Posted documents never change. A reversal document undoes them.
- Balances can't go negative (409).
- Expiry: `track_expiry` items need `expiry_date`, or `production_date` plus the card's `shelf_life_months`, on receipt.
  - `expiry_policy=block`: an expired lot can only leave as waste.
  - `expiry_policy=warn`: an expired lot can leave, and the response `warnings` says so.
  - Without `lot_id`, outgoing lines are taken first-expiry-first-out.

Endpoints under `/inventory`:
- `GET /summary` → `{item_count, expired_lot_count, expiring_lot_count, below_min_count, can_see_values, stock_value?}`.
- `GET /alerts` → `{alerts: [{item_id, item_code, item_name, unit, expiry_policy, warehouse_id, warehouse_name, lot_id, lot_no, expiry_date, quantity, expired}]}`.
- `GET /warehouses` → `{warehouses: [{id, name, address, notes, is_active, item_count, created_at}]}`. The first call creates "Merkez Depo" if the org has none.
- `POST /warehouses` and `PUT /warehouses/{id}` `{name, address, notes, is_active?}` (adjust). Archiving a warehouse that has stock → 409.
- `GET /warehouses/{id}/balances` → `{balances: [{item_id, item_code, item_name, unit, lot_id?, lot_no, expiry_date?, quantity}]}`.
- `GET /items?warehouse_id=&include_inactive=1` → `{items: [item], can_see_values}`.
  - item: `{id, code, name, barcode, unit, category, product_id?, min_stock?, track_expiry, shelf_life_months?, expiry_policy, expiry_alert_days, notes, is_active, quantity, nearest_expiry?, expired_quantity, expiring_quantity, below_min, avg_unit_cost?, stock_value?}`.
- `GET /items/{id}` → `{item, balances: [{warehouse_id, warehouse_name, lot_id?, lot_no, expiry_date?, production_date?, quantity}], documents: [summary], can_see_values}`.
- `GET /items/by-barcode/{code}` → item (404 if none).
- `POST /items` and `PUT /items/{id}` (manage), body is the item fields. An empty `code` gets `STK-NNNN`. A duplicate code or barcode → 409. Archiving an item that has stock → 409.
- `POST /receipts`, `/issues`, `/transfers` (manage) and `/waste`, `/counts` (adjust).
  - Body: `{date?, warehouse_id, target_warehouse_id (transfer), project_id? (issue), supplier_id? (receipt), counterparty, reference_no, reason (waste: damaged|expired|cutting|lost|other), note, idempotency_key, lines}`.
  - Each line: `{item_id, quantity | counted_quantity (count), unit_cost? (receipt), lot_id?, lot_no?, expiry_date?, production_date?}`.
  - Returns 201 with the document. A repeated idempotency key returns the first document.
- `GET /documents?type=&warehouse_id=&item_id=&project_id=&limit=&offset=` → `{documents: [summary]}`.
  - summary: `{id, doc_no, doc_type, doc_date, status, counterparty, reference_no, reason, warehouse_name, target_warehouse_name, project_name, created_by_name, created_at, item_count, first_item_name, is_reversal}`.
- `GET /documents/{id}` → summary plus `{warehouse_id, target_warehouse_id?, project_id?, project_no, supplier_id?, supplier_name, note, has_attachment, attachment_name, attachment_mime, reversal_of_id?, reversal_of_no, reversed_by_doc_id?, reversed_by_doc_no, reversed_at?, reversed_by_name, reverse_reason, lines: [{line_no, item_id, item_code, item_name, unit, warehouse_id, warehouse_name, lot_id?, lot_no, expiry_date?, quantity (signed), unit_cost?}], warnings}`.
- `POST /documents/{id}/reverse {reason}` (adjust) → 201 with the reversal document.
  - Reason required.
  - Already reversed, or a reversal document → 409.
  - If the received stock was already used → 409.
- `POST /documents/{id}/attachment` multipart `file` (image or PDF, manage); `GET /documents/{id}/attachment`. Our documents are not a legal irsaliye; the supplier's irsaliye number goes in `reference_no`.

Daily alert: every day at 08:00 Istanbul, orgs with expired or expiring lots, or items below minimum stock, notify `inventory.manage` holders once a day.
- Type `inventory_alert`, entity `inventory`, target `/diger/stok`.

**Mobile**: Diğer → "Stok Takibi".
- Routes: `/diger/stok`, `/diger/stok/malzeme/:id`, `/diger/stok/fis/:type?depo=&malzeme=`, `/diger/stok/hareketler[/:id]`, `/diger/stok/depolar`.
- Barcode/QR scanning uses `mobile_scanner`: from the list, in the item picker and in the item form.

## Calculations (`requireAuth`; read = `calculations.read`, group/category/recipe-item CUD = `calculations.manage` — no coarse admin gate any more)
- Recipe admin (mobile Diğer > Metraj Reçeteleri, `lib/features/calc_admin/`, since 1.3.0+4): `POST /calculations/groups`, `PUT /calculations/groups/{id}`, `POST /calculations/categories`, `PUT /calculations/categories/{id}`, `POST/PUT/DELETE /calculations/recipe-items[/{id}]`. Group/category edits send the existing `image_file_id` back unchanged. Deactivating a group/category hides it (lists return active only). The product picker pages `GET /products` (limit 200) only with `products.read`.
- `GET /calculations/groups` → active groups only.
- `GET /calculations/categories?group_id=X` → flat active categories in that group. `GET /calculations/categories` (no param) → nested `{groups:[{...,categories:[...]}]}` cascade shape — **response shape differs by presence of the query param.**
- `GET /calculations/recipe-items?category_id=X` (required param) → ALL items (active+inactive), any authed role.
- `POST /calculations/run` `{category_id, area?, width?, height?, perimeter?, pitch_deg?}` — all numeric inputs are `string`, all optional except category_id, but **if sent, must be > 0** (0 or negative is a hard error, not "treat as absent"). Exception: `pitch_deg` `0` means no pitch; a negative pitch or one of 90° or more is a 400 (`'pitch_deg' 0 ile 90 derece arasında olmalı`, since 2026-10-11 — it used to be ignored silently, the area came out flat while the client froze the typed pitch). Mobile checks before sending and is stricter: the pitch must be above 0 and below 90 ("Çatı Eğimi 0'dan büyük olmalı" / "Çatı Eğimi 90'dan küçük olmalı"); an empty field means no pitch. Area resolution: `area` wins, else needs BOTH width+height. Perimeter resolution independent: explicit wins, else derived only from width+height (never from area alone).
- Response: `{category, input:{footprint_area,effective_area,perimeter,pitch_deg}, items:[{recipe_item_id,material_name,unit,quantity,product_id?,unit_price,line_total,group_name?,calculation_type,factor,waste_percent,min_quantity?,package_size?,rounding_type}], total_cost, warnings:[{item_id,code,message}]}`. **Every numeric field here is a JSON string.** `input.pitch_deg` (since 2026-10-11) is the pitch actually applied to `effective_area` — `null` when none (or `0`) was sent; older servers omit the key, then mobile falls back to the pitch it sent. `min_quantity`/`package_size` (same date) are the recipe's minimum and package rule, omitted when unset. Mobile sends `pitch_deg` only for roof groups (`looksLikeRoof`) and clears it on group change. A response that arrives after the measurements, input mode, group or category changed is discarded (slow network); the snapshot's `group_name` is the group the result was calculated in.
- Warning codes: `perimeter_missing`, `unknown_calculation_type`, `product_missing`, `product_zero_price`, `quantity_below_precision` (since 2026-10-11: a positive quantity under 0.01 came out as 0).
- **Quantity precision (since 2026-10-11):** `ceil`/package lines are whole numbers as before; `none` and `round` lines now come with at most 2 decimals — the offer item's precision (`offer_revision_items.quantity numeric(12,2)`) — and `line_total` is computed from that quantity. A line added to an offer therefore keeps the same quantity and line total, and `total_cost` equals the offer subtotal of the added lines (before, `none` returned 6 decimals and the two totals differed by a few kuruş).
- **Price fallback (since 2026-10-07):** each item also has `price_source` (`product` | `reference` | `none`) and, unless the product price was used, `price_warning` (`"referans fiyat kullanıldı"` / `"fiyat yok"`). When the linked product is missing or 0 TL, `unit_price`/`line_total`/`total_cost` use the recipe item's `reference_unit_price` (if > 0); otherwise the line stays 0. Warning codes are unchanged (messages now name the price used). Mobile marks such lines, shows one summary note and drops the per-line `product_missing`/`product_zero_price` boxes for marked lines; the source is copied into `calc_snapshot.price_source`.
- **No "convert calc to offer" endpoint** — client converts `quantity`/`unit_price` strings→numbers itself and POSTs as an offer item with `unit`/`section_label`/`calc_category_id`/`calc_snapshot`. Mobile adds only lines whose quantity is above 0 at offer precision (0-quantity lines, e.g. perimeter-based without a perimeter, start unchecked and cannot be checked), and drops the result as soon as a measurement, the input mode, the group or the category changes.
- **`calc_snapshot` canonical schema (since 2026-10-11, `backend/internal/domain/calc_snapshot.go`).** One flat JSON object, every value a string (as in the `/run` response) or `null`:
  `area` (effective area m², after pitch = `input.effective_area`), `footprint_area` (before pitch), `perimeter`, `pitch_deg` (applied pitch; `null` = no pitch), `recipe_item_id`, `category_id`, `category_name`, `group_name` (the calculation **group**, e.g. "Çatı Hesaplamaları" — not the item's material group), `calculation_type`, `recipe_factor` (= item `factor`), `waste_percent`, `min_quantity`, `package_size` (only when the recipe has them), `rounding_type`, `price_at_calc` (= item `unit_price`), `price_source`.
  The server normalizes on every write and every read: legacy mobile keys `effective_area`→`area` and `factor`→`recipe_factor` are renamed, unknown keys and non-scalar values are dropped, numbers become strings, values are capped at 200 characters; a non-object or empty snapshot becomes no snapshot. Stored rows are not rewritten, a key a legacy row never had (e.g. `pitch_deg` on old mobile rows) stays absent, i.e. "unknown". Clients treat it as read-only; mobile writes it in `buildOfferItemsFromCalcResult` (`lib/features/calculations/domain/calc.dart`), web in `MetrajHesaplaPanel.tsx` (web writes a subset: no `recipe_item_id`/`category_id`/`footprint_area`/`calculation_type`/`min_quantity`/`package_size`/`price_source`, and its `pitch_deg` is the typed input, not `input.pitch_deg`).

## Customers (`requireAuth`, no admin gate)
- `GET /customers?filter=aktif|pasif&q=` — `q` matches **name only** (not phone/email). No pagination.
- `GET/POST/PUT/DELETE(soft)` — `customerResponse`: id,name,phone,email,address,tax_office,tax_number,notes,is_active. Phone/email always `""` not null — check non-empty for call/email actions.
- Customer card (mobile): Teklifler = `GET /offers/?customer_id=`, Projeler = `GET /projects?customer_id=` (amounts only with `projects.finance.read`). "Finansal Özet" sums the list rows' `current_contract_value`/`collected_amount`/`remaining_receivable` per currency with the dashboard's open-receivable rule (since 2026-10-11): `cancelled` projects are skipped, each project's remaining is clamped at 0, over-collection is a separate "Fazla Tahsilat" row. Pull-to-refresh, returning from an opened offer/project and offer/collection/change-order writes refresh the sections. The projects list is read page by page (200 per page, at most 10 pages) so the summary covers every project; if fewer rows than `total` arrive the card says the summary is incomplete.
- Duplicate guard: `POST`/`PUT` answer **409** `{error, code:"duplicate_customer", field:"tax_number"|"phone", existing_customer:{id,name,is_active}}` when another customer has the same tax number or phone; resend with `allow_duplicate: true` to save anyway. Mobile's customer form shows a dialog (Mevcut müşteriyi aç / Yine de kaydet / Vazgeç). `ApiException` now carries `code` and the raw JSON `body` for such cases.

## Products (`requireAuth`; read = `products.read`, write = `products.manage`) — mobile since 1.3.0+4 (`lib/features/products/`)
- `GET /products?page=&limit=&q=` → `{products, total}`. **limit max 200; above 200 silently falls back to 50.** Mobile pages 100 at a time.
  - **`q` is word-based (since 2026-10-07, backend `domain/product_search.go`):** split into words (max 8) after the same Turkish folding as `normalized_name`; a product matches when EVERY word appears in its name OR category OR supplier (source code + registry name: `demir`/`profil`/`omega`/`çelik` → `demirprofil`, `ulaş`/`ulas` → `ulas`). Sizes/decimals fold on both sides: `×`/`x`/`X`/`*` are the same, `40 x 40` = `40x40`, `,` = `.` (`1.35` finds `1,35`). Plain substring — `%`/`_` are not wildcards. Edge punctuation is dropped; a punctuation-only `q` is no filter.
  - **Order with `q`:** all words in the name → some words in the name (name matches before category/supplier-only) → all words at a word start (`kutu 40`: 40×40 before 140×140) → the whole query as a phrase in the name → name starts with the first word → shorter name → name, id. Without `q` the order is unchanged (name, id). `total` is the match count before paging.
  - Previously `q` was one substring of the name only (`demir`, `kutu 40` found nothing).
  - Offer form catalog picker (1.5.11+17, `features/offers/presentation/product_suggestions.dart`): `GET /products?q=<typed>&limit=6&page=1` after 2+ characters, only with `products.read`, debounced 300 ms, the in-flight request is cancelled (Dio `CancelToken`) when a newer one starts. Picking fills `product_id`, name, `unit_price` (like web) and `unit` (web has no unit field); editing the name away from the picked one drops `product_id` (web rule). No match / offline / error: a short note, the typed text stays a free-text item.
- `GET /products/{id}`, `GET /products/{id}/price-history` → `{history:[{old_price,new_price,note,changed_at,reason(supplier|markup|manual),source,old_source_price?,new_source_price?}]}`.
- `POST /products`, `PUT /products/{id}` `{name, unit, unit_price, description, category}` (manage). Name/unit of a source-linked product stay locked in the UI (web sourceLink rules); so does `unit_price` for a product still in the supplier list (every sync, incl. the nightly one, rewrites it from source price + markup — the form sends the existing price and points to the markup settings).
- `GET /products/price-sources` → `{sources:[…]}` (Ulaş, Demir Profil). `PUT /products/price-sources/{source}` `{markup_percent, auto_sync, category_markups:[{category, markup_percent}]}` and `POST /products/price-sources/{source}/sync` (manage). Sync errors: **409** = another sync (or markup update) for this source is already running (`bu fiyat kaynağı için şu anda başka bir senkron çalışıyor, biraz sonra tekrar deneyin`); **502** = either the source was unreachable/unparseable (`tedarikçi fiyat listesi alınamadı; lütfen daha sonra tekrar deneyin`) OR the list came back much shorter than the last good sync, i.e. under half (`tedarikçi fiyat listesi beklenenden çok kısa geldi; fiyatlar değiştirilmedi`) — the two 502s are told apart only by that exact `error` text. Prices are unchanged in both 502 cases; details (HTTP code, counts) are recorded in the source's `last_error`.
- `GET /products/price-changes?from&to&reason&source&direction&category&q&sort&page&limit` and `GET /products/price-changes/summary?from&to&reason&source` (Zam Geçmişi).
- `source_price` and all markup values are returned **only** to `products.manage`; mobile additionally never renders them without manage.

## Employees / Attendance (`requireAuth`; employees read = `employees.read`, create/update/archive = `employees.manage`)
- `GET /employees?filter=` — no text search at all. Since 2026-09-27
  `salary`/`daily_wage` are `null` unless the caller holds
  `employees.manage` (listing personnel must not expose wages).
- Mobile Diğer > Personel (since 1.3.0+4, `lib/features/employees/`): `GET /employees/{id}`, `POST /employees`, `PUT /employees/{id}` `{full_name, phone, position, salary, daily_wage, start_date, description, is_active, user_id}`, `DELETE /employees/{id}` (archive = pasif, not a hard delete). "Giriş hesabı aç" chains `POST /users` (with `employee_id` = this personnel, see Users below) + `PUT /users/{id}/permissions`; the old `PUT /employees/{id}` (`user_id`) step is only a fallback when the response does not confirm the link.
- Person = one record (2026-10): every employee row carries `user_id`; callers holding `organization.users.read` also get `user_username`, `user_is_active` and (`true` only) `user_deleted` for the linked login. Others never see login names.
- Linking a login that is already linked to ANOTHER personnel record: if that other record was auto-created together with the login and never used (no edits, wage, attendance, payments, team, task or plan), it is deleted and the link moves (the admin's explicit choice wins). Otherwise 409 `bu kullanıcı hesabı zaten "<ad>" personel kaydına bağlı; …`.
- `GET /employees/link-suggestions` (`employees.manage` + `organization.users.read`) → `{suggestions:[{user_id, username, user_full_name, employee_id, employee_full_name, employee_position}]}`: logins without personnel vs. unlinked active personnel with exactly the same normalized name (unique on both sides). Never links by itself.
- Attendance is **pure manual entry, no GPS/geofence, no separate check-in/out calls**: `GET /attendance?month=YYYY-MM`, `POST/PUT /attendance` `{employee_id, date, check_in, check_out, work_hours(number), status, note}`. Status ∈ `geldi|yarım gün|gelmedi|izinli`. One record per employee+date (409 on dup).
- Payroll (`/payroll`, migration 0048) needs only `payroll.read` / `payroll.manage` — no `attendance.*`. Mobile (since 2026-10-11): a payroll-only user gets Diğer > "Maaş" (same screen, `/diger/mesai`), the list is built from `GET /payroll?month=` (worked days/hours from the summary) and `/attendance` + `/employees` are never called. A failed `/payroll` shows "Maaş bilgisi alınamadı" + Tekrar Dene (it used to be swallowed: no card, "Bu aya ait ödeme yok").

## Notifications (`notifications.read`; always the caller's own rows)
- `GET /notifications?page=&limit=` → `{notifications, total}` (created_at DESC, `created_at` RFC3339 to the second); `GET /notifications/unread-count` → `{unread_count}`; `POST /notifications/{id}/read`.
- `POST /notifications/read-all` — optional body `{before: "<RFC3339>"}` (since 2026-10-11): only notifications created up to that second are marked, so one that arrived after the list was opened (or a grouped one that was bumped since) stays unread. No body = every unread (older clients, web today). Mobile sends the newest `created_at` of the list it shows and does nothing when the list is empty. An older server ignores the body.
- The home "Okunmamış bildirim" tile reads `unreadNotificationCountProvider` (the bell's counter); the dashboard snapshot's `notifications.unread` is only the fallback.
- Push (since 2026-10-29): a notification read before the sender loop picks it up (~3 s) is not pushed to the phone. Firma Grubu notifications (`type: organization_chat`, see "Firma Grubu") use the fixed push tag / collapse key `firma-grubu`.

## Users, Roles & Permissions (`requireAdmin` (coarse role) **plus** RBAC) — mobile since 1.3.0+4 (`lib/features/access/`)
Every endpoint here needs coarse `role=admin` in addition to the permission, so mobile gates with the strict `canAccess` (`core/auth/permissions.dart`, `kAdminRoleOnlyPermissions`).
- `GET /users?page=&limit=` (`organization.users.read`, limit ≤ 200) → `{users, total}`; `GET /users/{id}`; `GET /users/{id}/projects` → `{projects}`.
- `POST /users` `{username, password, full_name, organization_role_code, create_employee?, employee_id?, link_same_name?}` — role code REQUIRED (else the member lands in "Eski Sistem"). `PUT /users/{id}` `{full_name, is_active}`; `PATCH /users/{id}/password` `{new_password}` (all `organization.users.manage`). Last active owner cannot be deactivated (409).
- Person = one record (2026-10): `POST /users` also creates/links a personnel record IN THE SAME TRANSACTION. Omitted fields = defaults (the frozen web sends none): `employee_id` set → link that personnel (400 not found, 409 already linked to another login — the account is NOT created in either case); else `create_employee:false` → nothing; else (default) link the single unlinked ACTIVE personnel whose normalized name matches (`İ/I/ı/i`, `ş/s` … folded, case/spaces ignored) unless `link_same_name:false`; two+ matches → nothing (ambiguous); no match → new personnel (name from the account, position empty, start today, no wage = payroll shows "Ücret tanımsız"). Personnel step needs `employees.manage`; without it the account is still created and nothing is linked (explicit `employee_id` → 403). Response = user + `employee_id`/`employee_full_name`/`employee_is_active` + `employee_link {status: created|linked|linked_same_name|skipped|ambiguous_name|no_permission, employee_id, employee_full_name, employee_is_active, message}` (`message` is ready-to-show Turkish).
- `GET /users` and `GET /users/{id}` rows carry `employee_id`/`employee_full_name`/`employee_is_active` when the login is linked (absent otherwise).
- Renaming a login (`PUT /users/{id}`) renames the linked personnel only if both had the same normalized name; deactivating/deleting a login never touches the personnel record or the link (the picker then shows "uygulaması yok").
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
  omit the key to keep the stored IBAN, `""` clears it. Since 2026-10-11 a
  non-empty IBAN is normalized (spaces dropped, upper-cased) and validated
  (ISO 13616 mod-97, TR = 26 chars) — invalid → 400 `IBAN geçersiz: …`
  (the same rule as mobile's `isValidIban`). Supplier PUT overwrites
  `specialty` with whatever is sent — always send it back.
- `GET /organization/settings` + `PUT /organization/settings/{company,
  billing,offers,finance,business}` — `requireAdmin` + `organization.settings.read`
  (GET) / `.manage` (PUT). Mobile (since 2026-10-11) shows "Firma Ayarları"
  with `canAccess('organization.settings.read')` (it used to check only the
  coarse role) and renders the forms read-only without `.manage`. This is a **different**
  route from `/settings` below (SMTP-only) — mobile's `OnboardingRepository`
  (`lib/features/onboarding/data/onboarding_repository.dart`) serves BOTH
  the first-run onboarding wizard (`basePath: '/onboarding'`, same
  sub-resource shape) and the post-onboarding "Firma Ayarları" screen
  (`basePath: '/organization/settings'`) off the identical request/response
  shape — only the base path differs. `PUT …/offers`: an omitted/empty
  `default_currency` keeps the stored one (TRY only if nothing is stored;
  it used to reset to TRY). Mobile always sends the current value
  (TRY/USD/EUR picker, any other stored code kept) — before 2026-10-11 it
  always sent TRY and silently overwrote a web choice (1.5.13 still does).
  `PUT …/finance` `iban` (write-only, omit = keep, `""` = clear) is
  normalized and validated like the supplier IBAN since 2026-10-11 →
  400 `IBAN geçersiz: …`; mobile checks it before saving.
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
12. RESOLVED (2026-10): `GET /projects/{id}/events`, `GET /projects` and the other project responses no longer return money to users without `projects.finance.read` (see "Finance visibility" under Projects).
13. Legacy subcontractors: the web neither edits a subcontractor nor voids its payments, so the app does not either (the backend has the endpoints).

(The cross-project "my tasks" endpoint and organization name/id on auth responses — formerly gaps #1/#2 here — are both RESOLVED; see MOBILE_BACKEND_GAPS.md for the history.)

## Siparişten teslim alma (2026-10, migration 0074)

Kurallar: `docs/procurement.md` §12.

- **Sipariş detayı** `GET /projects/{id}/purchase-orders/{poId}` ek alanlar:
  - `receipts`: iptaller dahil, en yeni önce. Her teslim `{id, sequence_no, received_date, delivery_note_no, destination: site|warehouse, warehouse_id, warehouse_name, notes, created_by, created_by_name, created_at, voided_at, void_reason, items: [{purchase_order_item_id, accepted_quantity, rejected_quantity, rejection_reason}]}`.
  - `receipt_summary`: `{status: none|partial|complete, accepted_total, costed_total, received_not_costed}`. Tutarlar KDV dahil.
  - Her kalemde `accepted_quantity`, `rejected_quantity`, `waiting_quantity`.
  - `purchase_order` içinde `receipt_status` ve `received_not_costed`.
- **Sipariş listesi** satırları `receipt_status` ve `received_not_costed` taşır.
- **Teslim girme:** `POST /projects/{id}/purchase-orders/{poId}/receipts` (`projects.procurement.receive`).
  - Gövde: `{received_date, delivery_note_no?, destination: "site"|"warehouse", warehouse_id? (depoda zorunlu), notes?, idempotency_key?, items: [{purchase_order_item_id, accepted_quantity, rejected_quantity, rejection_reason?}]}`.
  - Başarılı olursa `201` döner ve gövdede teslim vardır.
  - **400:** iki miktarı da 0 olan satırlar atlanır, hiç satır kalmazsa 400. Negatif miktar, tekrarlanan kalem, geçersiz teslim yeri de 400 döner.
  - **409:** onaylı olmayan sipariş; kalan kabulü aşan miktar (mesajda kalem ve en fazla miktar yazar); kapalı depo; başkasının tekrar anahtarı; kilitli proje.
  - **404:** başka projenin siparişi ya da kalemi.
- **Teslim iptali:** `POST /projects/{id}/purchase-receipts/{receiptId}/void {reason}` (`projects.procurement.receive`).
  - Gerekçe zorunlu (400).
  - Kapatılmış sipariş (409), zaten iptal (409).
- **Sipariş iptali:** teslim alınmış sipariş iptal edilemez → 409.
- **Sipariş kapatma:** teslim kaydı varsa gelmeyen kısım taahhütten çıkar.
- **Masraf:** `POST/PUT /projects/{id}/expenses` opsiyonel `purchase_order_id` alır. Bu projenin onaylı ya da kapatılmış siparişi olmalı, değilse 400.
  - PUT'ta alan yoksa bağ korunur, `""` gönderilirse kalkar.
  - Masraf satırları `purchase_order_id` taşır.
  - Finans izni olmayan (yalnızca kendi masrafını giren) kişi bağ yazamaz.
- **Finans özeti** `received_not_costed`: teslim alınmış, faturası girilmemiş tutar. Migration 0078'den beri sipariş tutarıyla maliyetin İÇİNDEDİR ("fatura bekleniyor" bilgisi).

## Satın almalar proje maliyetine girer (2026-10, migration 0078)

Kurallar: `docs/maliyet-tanimlari.md` "Satın almalar", `docs/procurement.md` §13.

- **Talep / sipariş yanıtları** `include_in_project_cost` (bool) taşır; talep ayrıca `cost_estimate` (null = kalemlerin toplamı), sipariş `purchase_request_id`.
- **`project_cost`** (liste, detay, onay ve karar yanıtlarında; diğer yazma yanıtlarında yok): `{included, amount, potential, source: estimate|orders|order|invoices|none, unpriced_items, warning?}`; siparişte ayrıca `order_amount`, `invoiced_amount`. `amount` bugün maliyete giren, `potential` eklenseydi girecek tutar (onay ekranındaki "maliyete eklenecek"). KDV dahil.
- **Talep onayı** `POST .../purchase-requests/{prId}/approve` gövde opsiyonel: `{include_in_project_cost?, cost_estimate?}`. Gövdesiz = evet, tahmin kalemlerden. Negatif tahmin / bilinmeyen alan 400. Tamamlanmış/iptal proje 409. Fiyatsız talepte (`estimate` 0, siparişi yok) `project_cost.warning` = "Bu talepte fiyat yok; maliyete 0 TL girer." (onaydan önce detayda da).
- **Sipariş oluşturma** opsiyonel `purchase_request_id` (bu projenin onaylı talebi; değilse 409); RFQ'dan açılan sipariş RFQ'nun talebine kendiliğinden bağlanır, çelişirse 409. Sipariş talebin kararını devralır.
- **Sipariş onayı** `POST .../purchase-orders/{poId}/approve` gövde opsiyonel: `{include_in_project_cost?}` (yoksa mevcut karar).
- **Kararı sonradan değiştirme** (`projects.procurement.approve`):
  - `POST /projects/{id}/purchase-requests/{prId}/project-cost {include_in_project_cost?, cost_estimate?}` — yalnızca onaylı talep (409), boş gövde 400. Karar talebin açık (taslak/onaylı) siparişlerine de uygulanır.
  - `POST /projects/{id}/purchase-orders/{poId}/project-cost {include_in_project_cost}` — taslak/onaylı sipariş (kapatılmış/iptal 409), alan zorunlu (400).
  - Tamamlanmış/iptal edilmiş projede 409. Yanıt talep/sipariş + `project_cost`.
- **Finans özeti** yeni alanlar: `expense_cost` (masraf satırı; siparişe bağlı faturalar hariç), `purchase_cost` ("Satın almalar (onaylı)"), `purchase_cost_vat`, `purchase_cost_uncoded`, `purchase_excluded` (maliyete eklenmeyen, bilgi), `realized_cost_vat` (`*_cost_net` bundan). `realized_cost = expense_cost + purchase_cost + subcontractor_work_paid + new_subcontract_accrued`. `total_expenses` bütün onaylı masraflar (nakit) olarak kaldı.
- **Maliyet Kontrolü** özet ve satırları `purchase_actual_cost` (actual_cost'un satın alma payı) taşır; `actual_cost` onaylı satın almaları içerir.
- Olaylar: `purchase_request_cost_decision`, `purchase_order_cost_decision` (metadata `included`, tahmin `amount`).

## Taşeron Paneli (2026-10-24, migration 0075; mobile 1.5.21)

Kurallar ve sonraki fazlar: `docs/taseron-paneli.md`.

- **Taşeron hesabı:** `users.supplier_id` dolu, kaba rol `kullanici`, organizasyon rolü `subcontractor` ("Taşeron"; izinleri yalnızca `subcontractor.portal` + `notifications.read`). Bu rol başka kullanıcıya atanamaz, izinleri değiştirilemez; taşeron hesabına rol/kişisel izin/proje üyeliği verilemez (409).
- **Varsayılan ret:** taşeron hesabı yalnızca şunlara girer: `/auth/*`, `/users/me/*` (şifre belirleme/değiştirme, hesabı silme), `/notifications*`, `POST /push/devices`, `/portal/*`. Diğer her uç 403 `{"code": "portal_only"}` döner.
- **Kart arşivlenirse** taşeron hesabı kilitlenir: oturumlu her istek 401, giriş ve yenileme 403 (`kullanıcı pasif durumda`).
- **Taşeron tarafı:** `GET /portal/overview` → `{supplier: {id, name}, projects, engagements, payments, totals}`.
  - Taşeron her zaman oturumdan bulunur; istekte kimlik yoktur. Taşeron olmayan hesap → 403.
  - `projects`: izin verilen projeler `{id, project_no, name, status}`.
  - `engagements`: yalnızca izinli projelerdeki işler `{kind: simple|contract, id, project_id, project_name, project_no, project_status, title, status, currency, contract_amount, certified (yalnızca contract, yoksa null), paid, payable, retention, advance_open, pending_claims, remaining}`. Sözleşmede `contract_amount` = ilk bedel + onaylı değişiklikler; taslak sözleşme görünmez.
  - `payments`: iptal edilmemiş ödemeler (izinli projelerdekiler + proje dışı `source: direct`), en yeni önce, en çok 500: `{source: simple|contract|direct, id, project_id?, project_name, project_no, amount, currency, paid_date, description, kind: work|advance|general}`.
  - `totals`: para birimi başına `{currency, contract_amount, paid, remaining, payable, retention}`; `paid` ödeme listesinin toplamı (proje dışı dahil), `remaining` işlerin `max(bedel − ödenen, 0)` toplamı. TRY önce.
- **Firma tarafı** (taşeron kartı):
  - `GET /subcontractors/{id}/portal` (`organization.suppliers.read` + `organization.users.read`) → `{users: [{id, username, full_name, is_active, must_change_password, last_login_at, created_at}], projects: [{id, project_no, name, status, granted, has_engagement}]}`. `projects` iptal edilmemiş projeler + izinli olanlar + işi olanlar; sırası izinli, işi olan, en yeni.
  - `POST /subcontractors/{id}/portal/users` `{full_name, username, temporary_password}` (`organization.users.manage`) → 201 kullanıcı. Hesap `must_change_password=true` açılır. Eksik alan / kısa şifre / ayrılmış ad 400, alınmış kullanıcı adı 409, arşivdeki kart 409.
  - `POST /subcontractors/{id}/portal/users/{userId}/password` `{temporary_password}` → kullanıcı; açık oturumlar kapanır, ilk girişte yeni şifre istenir.
  - `POST /subcontractors/{id}/portal/users/{userId}/active` `{active}` → kullanıcı; kapatınca oturumlar ve push kayıtları silinir.
  - `PUT /subcontractors/{id}/portal/projects` `{project_ids}` → güncel ayarlar (GET ile aynı). Verilen kümeyle değiştirir; başka firmanın projesi 400.
  - Proje izni `project_users`'tan ayrıdır (`subcontractor_project_access`); proje ekibine eklemek taşerona hiçbir şey açmaz.
- **Firma kullanıcısı değildir:** `GET /users` listesinde `organization_role_code: "subcontractor"` ile görünür. Personel kaydına bağlanamaz (`POST/PUT /employees` `user_id` → 409 `taşeron hesabı personel kaydına bağlanamaz`), personel bağlama önerilerinde ve Ana Sayfa'nın "projesi olmayan" / "personel kaydı olmayan" kullanıcı uyarılarında sayılmaz (aktif kullanıcı sayısında sayılır).
- **Mobil:** taşeron hesabı girişte `/taseron`'a gider ve firma ekranlarına yönlendirilemez (`app_router.dart`); profil `/taseron/profil`. Firma tarafı taşeron sayfasında "Taşeron Paneli" bölümü (`subcontractor_portal_section.dart`): giriş aç (geçici şifre üretilir, bilgiler bir kez gösterilir ve kopyalanır), şifreyi sıfırla, girişi kapat/aç, proje izinleri. Bölüm `organization.users.read` olmayana görünmez.

## Firma Grubu (2026-10-29, migration 0077; mobil: bir sonraki sürüm)

Firma başına TEK grup sohbeti (proje başına değil): metin + fotoğraf, telefona bildirim. Kural kaynağı `backend/internal/service/organization_chat.go`; web ekranı yok (`docs/web-yapilacaklar.md` §12).

- **İzin:** `organization.chat.use` (kategori "İletişim") — Taşeron dışındaki her rolde (mevcut roller + yeni firmaların seed'i). Bütün uçlar `/organization/chat/*`, izinsiz 403 `permission_denied`. Taşeron hesabı (`supplier_id`) bu uçlara hiç giremez (403 `portal_only`), rolü kilitli, kişiye özel de alamaz. Mobil girişleri KATI denetler (`canUseChat`: `canAccess` + taşeron değil) — izin listesi yoksa rozet isteği de atılmaz.
- **Mesaj:** `{id, seq, author_id (silinmiş hesapta null), author_name ("Silinmiş kullanıcı"), text, photo: {mime_type, size_bytes} | null, created_at (RFC3339, UTC), deleted, is_own, can_delete}`. `seq` firma içi artan numaradır (sıralama ve yoklama bununla; commit sırasıyla aynıdır, yoklama arada yazılan mesajı atlamaz). Silinmiş mesajda `text` boş, `photo` null, yazar kalır ("Mesaj silindi"). `is_own`/`can_delete` çağırana göredir.
- `GET /organization/chat/messages` → `{messages, has_more, updated, last_read_seq, muted, can_moderate, server_time}`. `messages` HER ZAMAN yeniden eskiye.
  - Parametresiz: en yeni sayfa. `?before=<seq>`: daha eski sayfa (`has_more` = daha eskisi var). `?limit=` varsayılan 50, en çok 100.
  - Yoklama: `?after=<seq>&changed_since=<server_time>` — `after`'dan sonraki mesajlar (sayfa dolarsa `has_more`, en büyük `seq` ile tekrar); `updated` = istemcinin elindeki aralıkta (`seq <= after`) o zamandan beri silinenler (bir dakika geriden: aynı silme iki kez gelebilir). `before` + `after` birlikte ya da eksi değer 400.
- `POST /organization/chat/messages` `{text, client_id?}` → 201 mesaj. `text` kırpılır, en çok 4000 karakter, boş 400; kontrol karakterleri atılır. `client_id` (uuid, telefonda üretilir): aynı kişi aynı `client_id` ile tekrar gönderirse yeni mesaj yazılmaz, ilki 200 ile döner ("Tekrar dene" yanıtı yolda kaybolan mesajı ikilemez). Tanımsız alan 400.
- `POST /organization/chat/messages/photo` multipart `file` (+ `text`, `client_id`) → 201 mesaj. 25 MB (413); tür içerikten: JPEG/PNG/WebP/GIF, diğerleri 400. Mobil seçicide küçültür (en uzun kenar 1920, JPEG %80).
- `GET /organization/chat/messages/{id}/photo` → bayt (inline, `Cache-Control: private, max-age=300`). Silinmiş, fotoğrafsız ya da başka firmanın mesajı 404. İçerik değişmez: mobil diskte saklar.
- `DELETE /organization/chat/messages/{id}` → mesajın silinmiş hali. Kendi mesajını herkes, herkesinkini Sahip/Yönetici (`can_moderate`) siler; diğerleri 403 (`permission_denied` kodu YOK — izin değişmedi). Tekrar silmek hata değil. Zildeki bildirimin gövdesi "<Ad>: Mesaj silindi" olur.
- `GET /organization/chat/status` → `{unread_count, muted, last_read_seq}`. `unread_count`: başkasının yazdığı, silinmemiş, okunan numaradan sonraki mesajlar; hesabın açılışından önceki geçmiş sayılmaz; en çok 1000 (rozet "99+").
- `POST /organization/chat/read` `{seq}` → status. Okuma geri gitmez, firmanın en büyük numarasıyla sınırlanır. Gösterdiği son mesaj okunduysa zildeki Firma Grubu bildirimi de okundu olur. Mesaj gönderen kendi mesajına kadar okumuş sayılır.
- `PUT /organization/chat/mute` `{muted: true|false}` → status. Sessizdekine bildirim (zil + telefon) gitmez; rozet sayısı görünür.
- **Hız sınırı:** kişi başına dakikada 20 mesaj (fotoğraf dahil) → 429 + `Retry-After: 30`, Türkçe metin.
- **Bildirim:** yeni mesaj yazar, sessize alanlar, pasif/silinmiş ve taşeron hesapları dışındaki üyelere gider. Kişi başına TEK okunmamış satır (`type: organization_chat`, `entity_type: chat_message`, `entity_id` = son mesaj, `action_target: /diger/firma-grubu`): ilk mesajda "Firma Grubu" / "Ahmet Yılmaz: metin" (fotoğrafta "Fotoğraf" ya da "Fotoğraf · alt yazı"); okunmadan gelen her yeni mesaj aynı satırı büyütür — "Firma Grubu: 3 yeni mesaj" / "Son: Ahmet Yılmaz: …", en üste çıkar, telefona yeniden gider. Push etiketi ve collapse key sabit `firma-grubu`: telefonda tek kart.
- **Mobil:** Ana Sayfa üst çubuğunda zilin yanında rozetli giriş (`ChatAppBarButton`), Diğer > İş Araçları'nın başında "Firma Grubu" (okunmamış sayısıyla), rota `/diger/firma-grubu` (`lib/features/chat/`). Ekran öndeyken 5 sn'de bir yoklar ve görülen en yeni mesaja kadar okundu der; arka planda durur, öne gelince hemen yoklar. Sohbet açıkken gelen Firma Grubu bildirimi alt bant göstermez, sohbeti yoklatır. Son 100 mesaj geçici dizinde (`firma-grubu/`, kişiye özel, çıkışta silinir): bağlantı yoksa "Bağlantı yok" bandıyla gösterilir. Gönderilemeyen mesaj kuyruğa girmez: balonunda "Tekrar dene" (aynı `client_id`) / "Vazgeç".
