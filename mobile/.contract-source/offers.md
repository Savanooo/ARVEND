# ARVEND Backend — `/api/v1/offers/*` API Contract (verified from source)

All info below was read directly from the Go source in `/Users/tahaeryetisozen/Documents/GitHub/x-api/ARVEND/backend`. File:line references are given for every struct/route so they can be re-verified. Nothing here is guessed — where a screen need has no backend support, it is called out explicitly.

---

## 0. Critical platform facts a mobile client MUST know first

### 0.1 Auth is cookie-based, NOT a bearer token
`internal/httpapi/middleware/auth.go:26-45`:
```go
func RequireAuth(issuer *auth.JWTIssuer) func(http.Handler) http.Handler {
    return func(next http.Handler) http.Handler {
        return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
            cookie, err := r.Cookie("access_token")
            if err != nil {
                http.Error(w, `{"error":"oturum bulunamadı"}`, http.StatusUnauthorized)
                return
            }
            claims, err := issuer.ParseAccessToken(cookie.Value)
            ...
```
`RequireAuth` reads the JWT from an `access_token` **cookie**, never an `Authorization: Bearer` header. `requireAdmin` = `appmw.RequireRole(domain.RoleAdmin)` (`internal/httpapi/router.go:49`), which checks `RoleFromContext(ctx) == domain.RoleAdmin` (`"admin"`, `internal/domain/user.go:11`) and returns raw (non-httpjson) `403 {"error":"bu işlem için yetkiniz yok"}` on failure (`internal/httpapi/middleware/require_role.go:11-22`). **A Flutter client must use a cookie jar (e.g. `dio_cookie_manager` / `cookie_jar`) and persist `Set-Cookie` from `/api/v1/auth/login`, not store/send a token in a header.**

### 0.2 Error response shape
`internal/platform/httpjson/httpjson.go`:
```go
func Error(w http.ResponseWriter, status int, message string) {
    Write(w, status, map[string]string{"error": message})
}
```
Every error is `{"error": "<turkish message>"}`. `RequireRole`'s 403 above is the one exception with the same shape but written via raw `http.Error`, not `httpjson.Error` — body shape is identical either way.

Internal/DB errors are masked (`internal/httpapi/handler/errors.go:25-43`): a `*pgconn.PgError`, a `net.Error`, or a `context.Canceled/DeadlineExceeded` is logged server-side and returned to the client as **500** `{"error":"beklenmeyen bir sunucu hatası oluştu"}` — raw DB error text never leaks.

Request-body decoding always uses `json.NewDecoder(r.Body).DisallowUnknownFields()` (`internal/platform/httpjson/httpjson.go:26-31`). **Sending any field not in the request struct causes the whole call to fail with 400 `{"error":"geçersiz istek gövdesi"}`.** The mobile client must not send extra/unknown JSON keys on any POST/PUT body in this API.

### 0.3 Money/quantity serialization — verified, not assumed
- **Offers module (this whole tree): all money/quantity fields are plain JSON numbers (Go `float64`)** — e.g. `offerItemResponse.Quantity float64 `json:"quantity"``, `offerResponse.GrandTotal float64` (`internal/httpapi/handler/offer_handler.go:26-63`).
- **`/api/v1/calculations/*` is the documented exception**: verified in `internal/httpapi/handler/calc_handler.go:17-25` (comment) and its response structs, e.g. `calcResultItemResponse.Quantity string`, `UnitPrice string` `json:"unit_price"`, `LineTotal string`, `calcRunResponse.TotalCost string` (lines 428-460) — these are deliberately **JSON strings** (`decimal.Decimal.String()` / `.StringFixed(2)`) to avoid float precision loss. Do not parse offer numbers as strings, and do not parse calc numbers as JS/Dart doubles without going through a decimal-safe parser.
- The `calc_snapshot` blob attached to an offer item (see §3) is the **frozen, opaque copy** of one `calcResultItemResponse`-shaped result at calculation time — server never re-interprets it (`internal/domain/offer.go:43-49` comment), so its internal numeric fields are almost certainly strings too, but this is client-supplied/opaque JSON (`json.RawMessage`) and is never validated or typed by the server.

---

## 1. Route table (as registered in `internal/httpapi/router.go:119-143`, group `r.Route("/offers", ...)`, `r.Use(requireAuth)` — every route below requires a valid session cookie, **none require admin**)

| Method | Path (client-visible) | Handler | Auth |
|---|---|---|---|
| GET | `/api/v1/offers/` | `Offers.List` | requireAuth |
| POST | `/api/v1/offers/` | `Offers.Create` | requireAuth |
| GET | `/api/v1/offers/{id}` | `Offers.Get` | requireAuth |
| PUT | `/api/v1/offers/{id}` | `Offers.Update` | requireAuth |
| POST | `/api/v1/offers/{id}/revise` | `Offers.Revise` | requireAuth |
| GET | `/api/v1/offers/{id}/revisions` | `Offers.ListRevisions` | requireAuth |
| GET | `/api/v1/offers/{id}/revisions/{revisionId}` | `Offers.GetRevision` | requireAuth |
| PUT | `/api/v1/offers/{id}/status` | `Offers.UpdateStatus` | requireAuth |
| POST | `/api/v1/offers/{id}/toggle-passive` | `Offers.TogglePassive` | requireAuth |
| POST | `/api/v1/offers/{id}/send-email` | `Offers.SendEmail` | requireAuth |
| POST | `/api/v1/offers/{id}/share-links` | `Offers.CreateShareLink` | requireAuth |
| GET | `/api/v1/offers/{id}/share-links` | `Offers.ListShareLinks` | requireAuth |
| DELETE | `/api/v1/offers/{id}/share-links/{linkId}` | `Offers.RevokeShareLink` | requireAuth |
| GET | `/api/v1/offers/{id}/events` | `Offers.ListEvents` | requireAuth |
| GET | `/api/v1/offers/{id}/email-logs` | `Offers.ListEmailLogs` | requireAuth |
| GET | `/api/v1/offers/{id}/project` | `Projects.GetByOffer` | requireAuth |
| DELETE | `/api/v1/offers/{id}` | `Offers.Delete` | requireAuth |
| POST | `/api/v1/projects/from-offer/{offerId}` | `Projects.CreateFromOffer` | requireAuth (in `/projects` group) |
| GET | `/api/v1/public/offers/{token}` | `PublicOffer.Get` | **none** |
| POST | `/api/v1/public/offers/{token}/respond` | `PublicOffer.Respond` | **none** |

**Important correction to the task's assumption**: there is **no** `/api/v1/offers/{id}/projeye-donustur` route. The conversion endpoint actually lives under the projects resource: `POST /api/v1/projects/from-offer/{offerId}`. The offers tree only exposes `GET /api/v1/offers/{id}/project` to check whether a conversion already happened (404 if not converted yet — used by the UI to switch between "Projeye Dönüştür" and "Projeyi Görüntüle" buttons, per comment at `router.go:138-141`).

---

## 2. Shared response structs

### `offerItemResponse` (`offer_handler.go:26-42`)
```go
type offerItemResponse struct {
    ID          string  `json:"id"`
    ProductID   *string `json:"product_id"`
    ProductName string  `json:"product_name"`
    Quantity    float64 `json:"quantity"`
    UnitPrice   float64 `json:"unit_price"`
    LineTotal   float64 `json:"line_total"`

    Unit           string          `json:"unit,omitempty"`
    SectionLabel   *string         `json:"section_label,omitempty"`
    CalcCategoryID *string         `json:"calc_category_id,omitempty"`
    CalcSnapshot   json.RawMessage `json:"calc_snapshot,omitempty"`
}
```
- `product_id`: nullable string (`*string`), always present as a key even if `null` (no `omitempty` on it) — free-text items have `product_id: null`.
- `unit`, `section_label`, `calc_category_id`, `calc_snapshot`: **only present in the JSON at all when non-empty** (`omitempty`). A manually-entered ("serbest") line item will simply omit these 4 keys. A metraj-calc-originated item includes all 4.
- `calc_snapshot` is raw/untyped JSON (`json.RawMessage`) — server never parses or validates its shape; treat as an opaque object to redisplay later.

### `offerResponse` (`offer_handler.go:44-108`)
```go
type offerResponse struct {
    ID              string              `json:"id"`
    OfferNo         string              `json:"offer_no"`
    RevisionNo      int                 `json:"revision_no"`
    CustomerID      *string             `json:"customer_id"`
    CustomerName    string              `json:"customer_name"`
    CustomerPhone   string              `json:"customer_phone"`
    CustomerEmail   string              `json:"customer_email"`
    CustomerAddress string              `json:"customer_address"`
    OfferDate       string              `json:"offer_date"`        // "2006-01-02"
    ValidUntil      *string             `json:"valid_until"`       // "2006-01-02" or null
    Subtotal        float64             `json:"subtotal"`
    VatRate         float64             `json:"vat_rate"`
    VatAmount       float64             `json:"vat_amount"`
    GrandTotal      float64             `json:"grand_total"`
    Notes           string              `json:"notes"`
    Status          string              `json:"status"`
    IsPassive       bool                `json:"is_passive"`
    Items           []offerItemResponse `json:"items,omitempty"`
}
```
Notes:
- `offer_date`/`valid_until` are date-only strings (`dateLayout = "2006-01-02"`, `offer_handler.go:65`), **not** RFC3339 timestamps.
- `status` is one of the 4 Turkish enum values below (§5) — never translated/anglicized.
- `discount_type`/`discount_value`/`discount_amount`/`currency` (which DO exist on `domain.Offer`, see `internal/domain/offer.go:82-88`) are **NOT serialized** in `offerResponse` at all — discount fields exist in the domain/DB layer but are dead in the public API today (always `DiscountNone`/`0` since nothing in `createOfferRequest` lets a client set them). Do not build discount UI against `/offers` expecting these fields to round-trip.
- `items` is omitted entirely (`omitempty`) if nil — on `List` responses items are **never populated** (see §3.1), only on `Get`, `Create`, `Update`, `Revise`.

### `offerRevisionResponse` (`offer_handler.go:259-279`)
```go
type offerRevisionResponse struct {
    ID              string              `json:"id"`
    OfferID         string              `json:"offer_id"`
    RevisionNo      int                 `json:"revision_no"`
    CustomerID      *string             `json:"customer_id"`
    CustomerName    string              `json:"customer_name"`
    CustomerPhone   string              `json:"customer_phone"`
    CustomerEmail   string              `json:"customer_email"`
    CustomerAddress string              `json:"customer_address"`
    ValidUntil      *string             `json:"valid_until"`
    Subtotal        float64             `json:"subtotal"`
    VatRate         float64             `json:"vat_rate"`
    VatAmount       float64             `json:"vat_amount"`
    GrandTotal      float64             `json:"grand_total"`
    Currency        string              `json:"currency"`
    Notes           string              `json:"notes"`
    Status          string              `json:"status"`
    CreatedBy       *string             `json:"created_by"`
    CreatedAt       string              `json:"created_at"` // RFC3339 "2006-01-02T15:04:05Z07:00"
    Items           []offerItemResponse `json:"items,omitempty"`
}
```
Note `currency` **is** present here (unlike `offerResponse`), and `created_at` is a full RFC3339 timestamp (unlike the date-only fields on the offer itself).

---

## 3. Endpoint-by-endpoint detail

### 3.1 `GET /api/v1/offers/` — list
Handler `offer_handler.go:110-125`. Query params read (only these three — no `search`/`q`, no `status`, no `customer_id`, no date-range filter exist on this endpoint, confirmed against `internal/repository/queries/offers.sql:17-26`):

| Param | Type | Meaning |
|---|---|---|
| `filter` | string | `"pasif"` → archived offers only; anything else (including absent) → active offers only. `isPassive := r.URL.Query().Get("filter") == "pasif"` |
| `page` | int | 1-based; `<=0` → coerced to `1` (`service/offer_service.go:391-393`) |
| `limit` | int | `<=0` or `>200` → coerced to `50` (`offer_service.go:388-390`) |

SQL (`internal/repository/queries/offers.sql:17-26`): `WHERE organization_id = $1 AND is_passive = $2 ORDER BY created_at DESC LIMIT $3 OFFSET $4`. There is **NOT SUPPORTED — no text search, no status filter, no customer filter, no date filter** on this endpoint; a mobile "search offers" screen must fetch and filter client-side, or none exists server-side.

Response `200`:
```json
{"offers": [ offerResponse, ... ], "total": <int64>}
```
`offers[i].items` is **always empty/omitted** — list rows come from `ToDomainOfferListItem` (`repository/pool.go:224-246`), which only carries `customer_name`, `grand_total`, `revision_no` from a JOIN on the current revision; `Items` is never populated for list rows.

Error: `500 {"error":"teklifler alınamadı"}` on any DB error (not passed through `writeError`, so no distinct handling — always 500 regardless of cause).

### 3.2 `GET /api/v1/offers/{id}` — get by id
Returns `200 offerResponse` fully populated including `items` (current revision, merged flat view via `MergeOfferRevision`, `repository/pool.go:251-270`).
Errors via `writeError` (`offer_handler.go:556-570`):
- `404 {"error":"teklif bulunamadı"}` if not found / wrong org / invalid UUID (`domain.ErrNotFound`).
- `500` masked internal error for DB/network faults.

### 3.3 `POST /api/v1/offers/` — create
Request `createOfferRequest` (`offer_handler.go:151-161`):
```go
type createOfferRequest struct {
    CustomerID      *string                  `json:"customer_id"`
    CustomerName    string                   `json:"customer_name"`
    CustomerPhone   string                   `json:"customer_phone"`
    CustomerEmail   string                   `json:"customer_email"`
    CustomerAddress string                   `json:"customer_address"`
    ValidUntil      *string                  `json:"valid_until"`   // "2006-01-02"; invalid/empty silently → nil
    Notes           string                   `json:"notes"`
    VatRate         *float64                 `json:"vat_rate"`      // nil → defaults 20.0 server-side; explicit 0 is respected
    Items           []createOfferItemRequest `json:"items"`
}
```
Item struct `createOfferItemRequest` (`offer_handler.go:137-149`):
```go
type createOfferItemRequest struct {
    ProductID   *string `json:"product_id"`
    ProductName string  `json:"product_name"`
    Quantity    float64 `json:"quantity"`
    UnitPrice   float64 `json:"unit_price"`

    Unit           string          `json:"unit"`
    SectionLabel   *string         `json:"section_label"`
    CalcCategoryID *string         `json:"calc_category_id"`
    CalcSnapshot   json.RawMessage `json:"calc_snapshot"`
}
```
This maps directly to `service.OfferItemInput` (`offer_service.go:90-106`) with identical field names/types — no renaming happens in `toOfferItemInputs` (`offer_handler.go:174-189`).

**Validation rules a mobile client must satisfy** (`offer_service.go`):
1. `Create` rejects up-front if `len(Items) == 0` → `400 "en az bir kalem girilmelidir"` (`offer_service.go:263-265`).
2. Per-item silent filtering in `computeOfferTotals` (`offer_service.go:136-159`): an item is **dropped** (not erroring individually) if `strings.TrimSpace(ProductName) == ""` OR `Quantity <= 0` OR `UnitPrice < 0`. If **all** items get dropped this way, the whole call fails: `400 "geçerli en az bir kalem girilmelidir"`. → client should pre-validate: product_name non-blank, quantity > 0, unit_price >= 0, before submit, to avoid silent item loss.
3. `LineTotal = round2(Quantity * UnitPrice)` is always recomputed server-side (`offer_service.go:148`); any `line_total` sent by a client is ignored (the request struct doesn't even accept one for create/update — only present in the *response*).
4. `VatRate`: pointer semantics matter — omit the field (or send JSON `null`) for the 20% default; send `0` explicitly to force 0% (guards a "falsy zero" bug per the code comment, `offer_service.go:119-122`).
5. If `CustomerID` is non-empty: `CustomerName/Phone/Email/Address` sent in the request are **entirely ignored** and overwritten from the live customer record (snapshot semantics) (`offer_service.go:109-111, 302-309`). If `CustomerID` is empty/omitted, the four free-text fields are used, and `CustomerName` (trimmed) must be non-blank → `400 "müşteri adı zorunludur"` otherwise (`offer_service.go:310-313`).
6. `CustomerID`, if given but not a valid UUID or not found in this organization → `400 "geçersiz müşteri"` (`offer_service.go:169-177`).
7. Per item, `ProductID` is validated to belong to the same organization; if invalid/foreign/not-a-UUID it is **silently dropped to NULL** (not an error) — the item still saves as a free-text line (`offer_service.go:189-196`).
8. Per item, `CalcCategoryID` is validated the **same way** — must resolve to a `calc_categories` row in the same organization, else **silently set to NULL** (`offer_service.go:197-204`, confirming the task's specific concern about "calc_category_id ownership": it is enforced, but as a silent downgrade, not a hard error). `CalcSnapshot` is written verbatim regardless of whether `CalcCategoryID` validated (`offer_service.go:216-219`).
9. `Unit` is trimmed with `strings.TrimSpace` before storage (`offer_service.go:215`).
10. Offer number is server-generated: `TKF-<year>-<4-digit-seq>` (`offer_service.go:369-376`), not client-settable (there is no field for it in the request).
11. New offer is always created with `status = "taslak"` and `revision_no = 0` (`offer_service.go:295, 318`); not client-settable.
12. `currency` is hard-coded `"TRY"` on creation (`offer_service.go:332`) — not present at all in `createOfferRequest`, and not surfaced in `offerResponse` either (only shows in `offerRevisionResponse`).

Response: `201 offerResponse`.
Errors: any of the above validation messages as `400 {"error":"..."}`; `400 {"error":"geçersiz istek gövdesi"}` for malformed/unknown-field JSON; masked `500` for DB faults.

### 3.4 `PUT /api/v1/offers/{id}` — update
Same request/response shape as Create (`createOfferRequest` / `offerResponse`), routed through `service.UpdateOfferInput` (identical fields, `offer_service.go:456-467`).

**Critical semantic difference from Revise**: `Update` **only works while the offer's current revision has `status == "taslak"`**; otherwise `409 {"error":"yalnızca taslak durumundaki teklifler düzenlenebilir"}` (`ErrOfferNotEditable`, `offer_service.go:454, 490-492`). It edits the current revision **in place** — `revision_no` does not change, no new revision row is created, and it wholesale **deletes and re-inserts all items** of that revision (`offer_service.go:546-552`, so any item IDs sent back to the client on Update will be brand-new UUIDs even for "unchanged" lines).

Same item validation rules as Create apply identically (uses the same `computeOfferTotals`/`insertRevisionItems`).

Errors via `writeError`: `404` not found, `409` `ErrOfferNotEditable`, `400` other validation, masked `500`.

### 3.5 `POST /api/v1/offers/{id}/revise` — "Revize Et"
No request body (handler reads no JSON — `offer_handler.go:248-257`). Only allowed when current status is **`gönderildi`** or **`reddedildi`**; explicitly rejected for `taslak` (use Update instead) and for `kabul edildi` (locked forever): `409 {"error":"bu teklif için revizyon oluşturulamaz"}` (`ErrOfferNotRevisable`, `offer_service.go:740, 785-787`).

Behavior: opens a new revision (`revision_no = latest+1`) that is a byte-for-byte clone of the current revision's customer/financial fields **and all items including `calc_category_id`/`calc_snapshot`** (`cloneRevisionItems`, `offer_service.go:235-256` — items are NOT re-validated against product/category ownership on clone, since they were already validated in the prior revision), sets offer status back to `taslak`, and points `current_revision_id` at the new revision. Serialized via a Postgres advisory lock keyed on the offer UUID to prevent concurrent double-revise (`offer_service.go:774`).

Response: `201 offerResponse` (the **new** revision's flat view).
Errors: `404`, `409 ErrOfferNotRevisable`, masked `500`.

### 3.6 `GET /api/v1/offers/{id}/revisions` — list revisions
Response `200`:
```json
{"revisions": [ offerRevisionResponse, ... ]}
```
Newest-first (`ORDER BY` implied by `ListOfferRevisions` query — service comment confirms "en yeni önce", `offer_service.go:873-875`). Each entry includes full `items`.
Errors: `404` (bad offer id/org), masked `500`.

### 3.7 `GET /api/v1/offers/{id}/revisions/{revisionId}` — get one revision
Note: **only `revisionId` is used to look up the row** — `chi.URLParam(r, "revisionId")` (`offer_handler.go:341`); the `{id}` path segment is not cross-checked against the revision's `offer_id` by this handler at all (any revision UUID belonging to the caller's organization can be fetched via any `{id}` in the URL — tenant isolation is still enforced by `organization_id`, but offer/revision consistency is not). Response `200 offerRevisionResponse` (full, with items). `404` if the revision UUID doesn't parse or doesn't belong to the org.

### 3.8 `PUT /api/v1/offers/{id}/status` — staff-driven status change
Request:
```go
type updateStatusRequest struct {
    Status string `json:"status"`
}
```
`status` must be one of the 4 enum values in §5 (`domain.ValidOfferStatus`) else `400 {"error":"geçersiz durum"}` (`offer_service.go:594-596`). If the offer's **current** status is already `kabul edildi`, **any** further status change is rejected: `409 {"error":"kabul edilmiş teklif/revizyon durumu değiştirilemez"}` (`ErrOfferLocked`, `offer_service.go:574, 634-636`) — this includes trying to move it to `reddedildi` or back to `taslak`; acceptance is permanent via this endpoint. Any other transition (including going straight `taslak → kabul edildi` or `taslak → reddedildi` without ever sending) is allowed — there is no state-machine graph beyond "not out of kabul edildi".

Side effect: transitioning **into** `gönderildi` for the first time (`previousStatus != gönderildi`) auto-revokes all still-active share links pointing at *other* revisions of the same offer (`offer_service.go:655-670`) and logs a `revision_sent` event instead of `offer_updated`.

Serialized with the same advisory lock as Revise/Respond (`offer_service.go:620`).

Response: `200 offerResponse`. Errors: `404`, `400` invalid status, `409 ErrOfferLocked`, masked `500`.

### 3.9 `POST /api/v1/offers/{id}/toggle-passive` — archive/unarchive
No body. Flips `is_passive`. Response: `200 {"ok": true}`. Only entering the archived state (`false→true`) logs an `offer_cancelled` event; unarchiving logs nothing (`offer_service.go:694-737`). Errors: `404`, masked `500`.

### 3.10 `DELETE /api/v1/offers/{id}` — delete
Response `200 {"ok": true}`. Hard-blocked if current status is `kabul edildi`: `409 {"error":"kabul edilmiş teklif silinemez"}` (`ErrOfferAccepted`, `offer_service.go:1429, 1451-1453`). No soft-delete distinction from `toggle-passive` — this is a real DB delete (`q.DeleteOffer`).

### 3.11 `POST /api/v1/offers/{id}/send-email`
Request:
```go
type sendOfferEmailRequest struct {
    To      string `json:"to"`
    Subject string `json:"subject"`
    Message string `json:"message"`
}
```
All optional-ish: `To` falls back to the offer's `customer_email` if blank; if still blank → `400 "alıcı e-posta adresi belirtilmedi"`. Recipient length is hard-capped at 255 runes → `400 "alıcı e-posta adresi çok uzun"` if exceeded (not truncated — rejected) (`offer_service.go:1340-1353`). `Subject` defaults to `"Teklifiniz: <offer_no>"`, then is truncated (not rejected) to 300 runes. `Message` defaults to a canned Turkish greeting; the current active share-link URL is always appended.

Side effects: gets-or-creates a share link for the current revision (unlimited/no-expiry if newly created), writes an `offer_email_logs` row **regardless of success/failure**, and **only on send success** promotes status `taslak → gönderildi` (which cascades the link-revocation logic from §3.8). On SMTP failure, the handler returns the `sendErr` itself as the HTTP error (goes through generic `writeError` default branch → `400 {"error":"<smtp error text>"}`, unless it happens to match `isInternalError` in which case it's masked to 500).

Response on success: `200 {"ok": true}` (note: **the updated offer body is NOT returned** — the handler discards `_` = the offer/*domain.Offer the service returns: `offer_handler.go:402-409`). A client must call `GET /offers/{id}` afterward to see the new status.

### 3.12 `POST /api/v1/offers/{id}/share-links` — create
Request:
```go
type createShareLinkRequest struct {
    ExpiresIn string `json:"expires_in"` // "" | "never" | "7d" | "30d"
}
```
Any other value → `400 {"error":"geçersiz süre seçeneği"}`. Always binds to the offer's **current** revision at creation time (`offer_service.go:970-976`) — it does not move if the offer is later revised.

Response `201 shareLinkResponse`:
```go
type shareLinkResponse struct {
    ID         string  `json:"id"`
    OfferID    string  `json:"offer_id"`
    RevisionID string  `json:"revision_id"`
    Token      string  `json:"token"`
    CreatedBy  *string `json:"created_by"`
    CreatedAt  string  `json:"created_at"`   // RFC3339
    ExpiresAt  *string `json:"expires_at"`   // RFC3339 or null
    RevokedAt  *string `json:"revoked_at"`   // RFC3339 or null
    IsActive   bool    `json:"is_active"`    // computed: !revoked && (no expiry || not yet expired)
}
```
The public URL a mobile app would construct/share is `<frontendURL>/paylas/<token>` (constructed server-side inside `SendOfferEmail`, `offer_service.go:1365`, but the client can build the same pattern using the returned `token` if it needs to share manually) — **NOT SUPPORTED as a distinct field**: the response does not return a ready-made full URL, only the bare `token`.

### 3.13 `GET /api/v1/offers/{id}/share-links` — list
Response: `200 {"share_links": [shareLinkResponse, ...]}`, newest-first, includes revoked/expired links too (comment: "aktif/iptal edilmiş/süresi dolmuş... birlikte" — `offer_service.go:991-993`).

### 3.14 `DELETE /api/v1/offers/{id}/share-links/{linkId}` — revoke
Response `200 {"ok": true}`. `404` if `linkId` invalid, not found, wrong org, or already revoked (all collapsed to the same `domain.ErrNotFound`, `offer_service.go:1034-1042`) — a client cannot distinguish "already revoked" from "never existed" from this response.

### 3.15 `GET /api/v1/offers/{id}/events` — audit timeline
```go
type offerEventResponse struct {
    ID         string         `json:"id"`
    RevisionID *string        `json:"revision_id"`
    EventType  string         `json:"event_type"`
    UserID     *string        `json:"user_id"`
    Metadata   map[string]any `json:"metadata,omitempty"`
    CreatedAt  string         `json:"created_at"` // RFC3339
}
```
Response: `200 {"events": [...]}`. Full enum of `event_type` values, from `internal/domain/offer_event.go:8-23`:
`offer_created`, `offer_updated`, `revision_created`, `revision_sent`, `share_link_created`, `share_link_revoked`, `customer_viewed`, `customer_accepted`, `customer_rejected`, `email_sent`, `email_failed`, `offer_cancelled`, `project_created`.

### 3.16 `GET /api/v1/offers/{id}/email-logs`
```go
type emailLogResponse struct {
    ID           string  `json:"id"`
    RevisionID   string  `json:"revision_id"`
    Recipient    string  `json:"recipient"`
    Subject      string  `json:"subject"`
    Status       string  `json:"status"`         // domain.EmailLogStatusSent / EmailLogStatusFailed
    ErrorMessage string  `json:"error_message"`  // "" on success
    SentBy       *string `json:"sent_by"`
    SentAt       string  `json:"sent_at"`        // RFC3339
}
```
Response: `200 {"email_logs": [...]}`, newest-first.

### 3.17 `GET /api/v1/offers/{id}/project` — conversion status check
Handler is `ProjectHandler.GetByOffer` (`project_handler.go:207-218`), calling `ProjectService.GetByOfferID`. Response `200 projectResponse` (full shape below in §4) **if a project already exists for this offer**; **`404 {"error":"proje bulunamadı"}` (or whatever `writeError` on ProjectHandler maps `domain.ErrNotFound` to — same pattern as offers, check `project_handler.go` `writeError`) if the offer has never been converted**. This is exactly the "has it been converted" check the task asked about.

---

## 4. Offer → Project conversion: `POST /api/v1/projects/from-offer/{offerId}`

Registered at `router.go:150` inside the `/projects` group (`requireAuth`, no admin requirement).

Request `createProjectRequest` (`project_handler.go:138-144`):
```go
type createProjectRequest struct {
    Name        string  `json:"name"`         // optional — blank derives "<customer_name> - <offer_no>"
    ProjectType string  `json:"project_type"`
    StartDate   *string `json:"start_date"`    // "2006-01-02" or null
    EndDate     *string `json:"end_date"`      // "2006-01-02" or null
    Description string  `json:"description"`
}
```

**Validation rule (directly answers the task's concern)**: the offer's **current revision must have `status == "kabul edildi"`**, else `400 {"error":"yalnızca kabul edilmiş bir teklif projeye dönüştürülebilir"}` (`ErrOfferNotAccepted`, `project_service.go:41-42, 108-110`). This is enforced under the same offer-scoped advisory lock used by Revise/UpdateStatus/customer-Respond, so it can't race a concurrent revise/accept/reject.

**Idempotent**: if the current (accepted) revision was already converted, calling this again returns the **existing** project (`200`... actually still `201` per handler regardless, since the handler always writes `http.StatusCreated` — `project_handler.go:166` — even on the idempotent "already exists" path) rather than creating a duplicate; enforced doubly by a DB `UNIQUE(organization_id, source_revision_id)` constraint as a race-safety net (`project_service.go:61-66, 163-177`).

Response `201 projectResponse` (`project_handler.go:25-73`):
```go
type projectResponse struct {
    ID               string  `json:"id"`
    ProjectNo        string  `json:"project_no"`
    Name             string  `json:"name"`
    ProjectType      string  `json:"project_type"`
    SourceOfferID    string  `json:"source_offer_id"`
    SourceOfferNo    string  `json:"source_offer_no"`
    SourceRevisionID string  `json:"source_revision_id"`
    SourceRevisionNo int     `json:"source_revision_no"`
    CustomerID       *string `json:"customer_id"`
    CustomerName     string  `json:"customer_name"`
    CustomerPhone    string  `json:"customer_phone"`
    CustomerEmail    string  `json:"customer_email"`
    CustomerAddress  string  `json:"customer_address"`
    ContractAmount   float64 `json:"contract_amount"`  // snapshot of the accepted revision's grand_total; frozen forever
    Currency         string  `json:"currency"`
    Status           string  `json:"status"`           // starts as domain.ProjectStatusPlanned
    StartDate        *string `json:"start_date"`        // "2006-01-02" or null
    EndDate          *string `json:"end_date"`
    Description      string  `json:"description"`
    InternalNotes    string  `json:"internal_notes"`
    CreatedBy        *string `json:"created_by"`
    CreatedAt        string  `json:"created_at"`  // RFC3339
    UpdatedAt        string  `json:"updated_at"`  // RFC3339

    // finance aggregate fields — ONLY present (non-nil) on the LIST endpoint response,
    // always absent/nil here on Create/Get/GetByOffer (see comment at project_handler.go:50-58):
    CollectedAmount        *float64 `json:"collected_amount,omitempty"`
    TotalExpenses          *float64 `json:"total_expenses,omitempty"`
    SubcontractorPaid      *float64 `json:"subcontractor_paid,omitempty"`
    SubcontractorRemaining *float64 `json:"subcontractor_remaining,omitempty"`
    RemainingReceivable    *float64 `json:"remaining_receivable,omitempty"`
    RealizedCost           *float64 `json:"realized_cost,omitempty"`
    RealizedGrossProfit    *float64 `json:"realized_gross_profit,omitempty"`
    InvoiceCount           *int64   `json:"invoice_count,omitempty"`
    PaidInvoiceCount       *int64   `json:"paid_invoice_count,omitempty"`
    ChangeOrderNet         *float64 `json:"change_order_net,omitempty"`
    CurrentContractValue   *float64 `json:"current_contract_value,omitempty"`
}
```
Explicitly: **on `CreateFromOffer`/`Get`/`GetByOffer` responses, all 11 finance-aggregate fields are absent from the JSON entirely** — a mobile client must call `GET /api/v1/projects/{id}/financial-summary` for real numbers, per the code's own comment (`project_handler.go:56-58`).

`Errors`: same pattern (`404` not found, `400` `ErrOfferNotAccepted`, masked `500`).

---

## 5. Enum values

### Offer status (`internal/domain/offer.go:8-24`)
```go
const (
    OfferStatusTaslak      = "taslak"
    OfferStatusGonderildi  = "gönderildi"
    OfferStatusKabulEdildi = "kabul edildi"
    OfferStatusReddedildi  = "reddedildi"
)
```
These 4 exact strings (including the Turkish diacritics) are the only valid values for `PUT /offers/{id}/status`'s `status` field and for `POST /public/offers/{token}/respond`'s `decision` field (only `kabul edildi`/`reddedildi` allowed there, see below). No other status values exist anywhere (no "draft"/"sent"/"accepted"/"rejected" English aliases).

### Discount type (`internal/domain/offer.go:26-30`) — present in domain/DB, **not exposed in any offers JSON response or request**
```go
const (
    DiscountNone    = "none"
    DiscountPercent = "percent"
    DiscountFixed   = "fixed"
)
```
NOT SUPPORTED via API today — always hard-coded to `DiscountNone`/`0` on create/update; there is no client-facing way to set a discount on an offer.

---

## 6. Public offer endpoints (no auth) — `/api/v1/public/offers/{token}`

Registered at `router.go:266-269`. `{token}` is the share-link UUID; it alone is the security boundary (no `organization_id` from the request is ever trusted, per comment `public_offer_handler.go:18-20`).

### `GET /api/v1/public/offers/{token}`
Response `200`:
```go
type publicOfferResponse struct {
    offerResponse           // embedded — all fields from §2 offerResponse
    CanRespond bool `json:"can_respond"`
}
```
`offerResponse.Status` here is overridden to the **frozen revision's own status** (not the offer's live current status) — so an old link keeps showing "gönderildi" even if the offer has since moved on (`offer_service.go:1128-1131`). `can_respond` is `true` only if: the link's revision is still the offer's *current* revision AND that revision's status is `gönderildi` (`offer_service.go:1117-1118`) — this is what the client uses to decide whether to render Accept/Reject buttons.

Side effect: fires a best-effort (never fails the request) `customer_viewed` audit event.

Errors (`public_offer_handler.go:85-103`):
- `404 {"error":"teklif bulunamadı"}` — bad/unknown token.
- `410 Gone` `{"error":"bu paylaşım bağlantısı iptal edilmiş"}` — link revoked (`ErrShareLinkRevoked`).
- `410 Gone` `{"error":"bu paylaşım bağlantısının süresi dolmuş"}` — link expired (`ErrShareLinkExpired`).
- masked `500` for DB/network faults.
(410 vs 404 is deliberate — "existed, now permanently gone" vs "never existed", per code comment `public_offer_handler.go:91-93`.)

### `POST /api/v1/public/offers/{token}/respond`
Request:
```go
type respondOfferRequest struct {
    Decision string `json:"decision"` // must be exactly "kabul edildi" or "reddedildi"
}
```
Any other value → `400 {"error":"geçersiz karar"}` (`offer_service.go:1166-1167`).

Race/consistency guarantees (all enforced under the same offer-scoped advisory lock as staff-side Revise/UpdateStatus):
- If the offer was revised (a newer revision is now current) since this link's revision → `409 {"error":"bu teklif için yeni bir revizyon oluşturuldu, bu bağlantı üzerinden artık karar verilemez"}` (`ErrOfferSuperseded`).
- If the linked revision's status is not `gönderildi` any more (already decided once, or was never sent) → `409 {"error":"bu teklif için onay/red işlemi yapılamaz"}` (`ErrOfferNotRespondable`) — this is also how a **second click on the same link is safely rejected** (no separate idempotency-key mechanism exists or is needed, per the code comment).
- Link still revoked/expired → same `410` handling as GET.

On success: writes `customer_accepted` or `customer_rejected` event, flips the offer's status/current-revision status to the decision, and returns `200 offerResponse` (the plain one, not the `publicOfferResponse` wrapper — `can_respond` is NOT included in the Respond response).

---

## 7. Summary of gaps ("NOT SUPPORTED") relevant to a mobile client

- **No server-side search/filter on `GET /offers/`** beyond `filter=pasif`, `page`, `limit` — no `q`, `status`, `customer_id`, or date-range params exist for offers (unlike `/projects` which has several).
- **No discount fields** exposed anywhere in the offers API (domain-only, always zero/none).
- **No ready-made public share URL** returned by `POST /offers/{id}/share-links` — only the bare `token`; the client must know/hardcode the `<frontend>/paylas/<token>` pattern itself if it needs to construct a link outside of the email-send flow.
- **`SendEmail` does not return the updated offer** — client must re-`GET` to see status flip to `gönderildi`.
- **`RevokeShareLink` 404 is ambiguous** between "never existed" and "already revoked".
- **No endpoint to fetch a single share link by id** — only list-all (`GET .../share-links`) or delete (`DELETE .../share-links/{linkId}`).
- **`GET /offers/{id}/revisions/{revisionId}` does not verify `{id}` matches the revision's actual offer** — only organization-level isolation is enforced; treat `{id}` there as effectively unused by the server.
- There is genuinely **no** `/offers/{id}/projeye-donustur`-style endpoint under `/offers` — conversion is `POST /api/v1/projects/from-offer/{offerId}` (confirmed exact path above).