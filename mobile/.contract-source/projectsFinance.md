# ARVEND Backend — Verified API Contract: `/api/v1/projects/*`

Repo root: `/Users/tahaeryetisozen/Documents/GitHub/x-api/ARVEND/backend`
All facts below are read directly from source; every struct is quoted verbatim with `file:line`. Nothing is guessed.

---

## 0. Global conventions (verified)

**Auth mechanism**: NOT a Bearer header. `RequireAuth` (`internal/httpapi/middleware/auth.go:26-45`) reads a cookie named `access_token`, parses it as a JWT, and injects `user_id`, `role`, `organization_id` into context. Every route under `/api/v1/projects/*` only has `r.Use(requireAuth)` applied at the group level (`internal/httpapi/router.go:145-146`) — **no `requireAdmin`** anywhere in the projects tree (comment at router.go:147-148 confirms this is deliberate: "Projeler de teklifler gibi sıradan personel işidir -- admin şartı YOK"). So every endpoint documented below requires only a valid session cookie, any role.

**Error shape** (`internal/platform/httpjson/httpjson.go:22-24`):
```go
func Error(w http.ResponseWriter, status int, message string) {
	Write(w, status, map[string]string{"error": message})
}
```
So every error body is exactly `{"error": "<turkish message>"}`. Status codes are decided per-handler in `writeError` (`internal/httpapi/handler/project_handler.go:253-285`):
- `domain.ErrNotFound` → **404** `{"error":"proje bulunamadı"}`
- `ErrOfferNotAccepted`, `ErrInvalidProjectState`, `ErrProjectLocked`, `ErrCurrencyMismatch`, `ErrAlreadyVoided`, `ErrDuplicateMember`, `ErrDuplicateContent`, `ErrChangeOrderNotEditable`, `ErrChangeOrderNotSendable`, `ErrChangeOrderNotCancellable`, `ErrChangeOrderNotRevisable`, `ErrChangeOrderWouldGoNegative` → **409 Conflict**
- `ErrInvalidEmployee`, `ErrInvalidSchedule`, `ErrUnsupportedType`, `ErrFileTooLarge`, `ErrEmptyFile`, `ErrInvalidChangeOrderRef`, `ErrNoChangeOrderItems` → **400**
- `ErrStorageFailure` or any DB/network/context error (`isInternalError`, `errors.go:25-35`) → **500** with a generic message `"beklenmeyen bir sunucu hatası oluştu"` (real error only logged server-side, never leaked)
- default (any other `errors.New(...)` from the service layer, e.g. validation messages) → **400** with that exact message as `error`
- Malformed JSON body → **400** `{"error":"geçersiz istek gövdesi"}` (from `httpjson.Decode`, which uses `json.NewDecoder(...).DisallowUnknownFields()` — **unknown fields in a request body are rejected as a decode error**, not silently ignored)

**Date/time formats**: `dateLayout = "2006-01-02"` (date-only, e.g. `start_date`, `due_date`, `expense_date`) and `rfc3339 = "2006-01-02T15:04:05Z07:00"` (timestamps, e.g. `created_at`, `updated_at`, `voided_at`) — constants at `internal/httpapi/handler/offer_handler.go:65,429`, used project-wide.

**Money/quantity serialization — verified directly, not assumed**: Every DTO under `/api/v1/projects/*` (and its finance/change-order sub-resources) declares amounts as Go `float64` with plain `json:"amount"` tags (no `,string`) — e.g. `Amount float64 \`json:"amount"\`` in `expenseResponse` (project_finance_handler.go:249), `collectionResponse` (line 156), `ContractAmount float64` in `projectResponse` (project_handler.go:39). **These serialize as JSON numbers, not strings.** By contrast, `/api/v1/calculations/*` DTOs in `internal/httpapi/handler/calc_handler.go` (e.g. `QuantityPerM2 string`, `UnitPrice string`, `LineTotal string`, `TotalCost string` — lines 243-459) declare the same kind of values as Go `string`, so they serialize as **JSON strings**. This confirms the documented exception is real and scoped only to `/calculations/*` — every projects/finance endpoint uses native JSON numbers.

---

## 1. `GET /api/v1/projects` — List

Router: `router.go:149`. Auth: `requireAuth` only.

**Query params** (`project_handler.go:169-195`, filter logic in `internal/service/project_service.go:287-372`, SQL in `internal/repository/queries/projects.sql:37-86`):
| param | meaning | notes |
|---|---|---|
| `status` | exact match on `domain.ValidProjectStatus` (`planned/active/paused/completed/cancelled`) | invalid value → 400 `"geçersiz proje durumu"` |
| `customer_id` | exact match, UUID | **invalid/unparseable UUID is silently ignored** (filter dropped, not an error) — verified: `service.List` only uses it if `repository.StringToUUID` succeeds |
| `project_type` | exact match, free string | |
| `currency` | exact match | |
| `start_from` | date (`YYYY-MM-DD`); filters `start_date >= start_from` | unparseable date silently becomes nil filter (`parseDateParam` swallows errors) |
| `q` | search string; SQL does `ILIKE '%q%'` OR-ed across `p.name`, `p.project_no`, `p.customer_name` | |
| `page` | 1-based; `<=0` → defaults to 1 | |
| `limit` | `<=0` or `>200` → defaults to 50 (hard cap 200) | |

Sort order is fixed: `ORDER BY p.created_at DESC` (no client-side sort param exists).

**Response 200**:
```json
{ "projects": [ <projectResponse>, ... ], "total": <int64> }
```
List items are built via `repository.ToDomainProjectListItem` (`internal/repository/pool.go:390-411`), which sets `HasFinanceAggregates = true` — **so list rows DO include** `collected_amount`, `total_expenses`, `subcontractor_paid`, `subcontractor_remaining`, `remaining_receivable`, `realized_cost`, `realized_gross_profit`, `invoice_count`, `paid_invoice_count`, `change_order_net`, `current_contract_value` (see §3 below — full field list is the same struct as Get, `projectResponse`).

---

## 2. `POST /api/v1/projects/from-offer/{offerId}` — Create (from accepted offer)

Router: `router.go:150`. There is **no bare `POST /api/v1/projects`** — creation is only possible from an accepted offer. Auth: `requireAuth`.

**Request struct** — `createProjectRequest` (`project_handler.go:138-144`):
```go
type createProjectRequest struct {
	Name        string  `json:"name"`
	ProjectType string  `json:"project_type"`
	StartDate   *string `json:"start_date"`   // "YYYY-MM-DD" or null
	EndDate     *string `json:"end_date"`     // "YYYY-MM-DD" or null
	Description string  `json:"description"`
}
```
All fields optional; if `Name` is blank the service derives `"{CustomerName} - {OfferNo}"` (`project_service.go:129-132`).

**Business rules** (`internal/service/project_service.go:67-209`):
- Source offer's **current revision** must have `status == "kabul_edildi"` (accepted), else `ErrOfferNotAccepted` → 409.
- **Idempotent**: if that revision was already converted, returns the existing project (200-equivalent via 201, same object) rather than erroring or duplicating — guarded by a Postgres advisory lock + a `UNIQUE(organization_id, source_revision_id)` constraint as last resort.
- `Customer*` fields and `ContractAmount`/`Currency` are **frozen snapshots** copied from the offer revision at conversion time (`revRow.CustomerName`, `revRow.GrandTotal`, etc.) — they never track later offer edits.
- `project_no` is generated as `PRJ-{year}-{4-digit-seq}` (`generateProjectNo`, line 221-228).
- New project's `Status` is always `domain.ProjectStatusPlanned` ("planned").

**Response 201**: `projectResponse` (full DTO, see §3) — but since this is a single-object read path (`ToDomainProject`, not the list variant), **`HasFinanceAggregates` is false**, so all the `*float64`/`*int64` finance pointer fields are entirely absent from the JSON (see the critical note in §3).

---

## 3. `GET /api/v1/projects/{id}` — Get (full DTO)

Router: `router.go:151`. Auth: `requireAuth`.

**Response struct** — `projectResponse`, verbatim (`project_handler.go:25-73`):
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
	ContractAmount   float64 `json:"contract_amount"`
	Currency         string  `json:"currency"`
	Status           string  `json:"status"`
	StartDate        *string `json:"start_date"`   // date-only, or null
	EndDate          *string `json:"end_date"`     // date-only, or null
	Description      string  `json:"description"`
	InternalNotes    string  `json:"internal_notes"`
	CreatedBy        *string `json:"created_by"`
	CreatedAt        string  `json:"created_at"`   // RFC3339
	UpdatedAt        string  `json:"updated_at"`   // RFC3339

	// ONLY populated (non-nil) when HasFinanceAggregates is true —
	// see critical note below.
	CollectedAmount        *float64 `json:"collected_amount,omitempty"`
	TotalExpenses          *float64 `json:"total_expenses,omitempty"`
	SubcontractorPaid      *float64 `json:"subcontractor_paid,omitempty"`
	SubcontractorRemaining *float64 `json:"subcontractor_remaining,omitempty"`
	RemainingReceivable    *float64 `json:"remaining_receivable,omitempty"`
	RealizedCost           *float64 `json:"realized_cost,omitempty"`
	RealizedGrossProfit    *float64 `json:"realized_gross_profit,omitempty"`
	InvoiceCount           *int64   `json:"invoice_count,omitempty"`
	PaidInvoiceCount       *int64   `json:"paid_invoice_count,omitempty"`
	ChangeOrderNet       *float64 `json:"change_order_net,omitempty"`
	CurrentContractValue *float64 `json:"current_contract_value,omitempty"`
}
```

### ⚠️ CRITICAL FINDING for the mobile client

`GET /projects/{id}` calls `service.Get` → `withSourceOfferInfo` → `repository.ToDomainProject` (`project_service.go:230-247`, `pool.go:348-386`). This path **never sets `HasFinanceAggregates`**, so it stays `false` (Go zero value). In `toProjectResponse` (`project_handler.go:99-115`), the entire finance block — **including `current_contract_value` and `change_order_net`** — is only filled in `if p.HasFinanceAggregates { ... }`. Since that's false here, all ten finance fields above (`collected_amount` … `current_contract_value`) are **`nil` and, due to `omitempty`, completely absent from the JSON body** — not `0`, not `null`, simply missing keys.

This is by design and documented in the domain code itself (`internal/domain/project.go:100-108` and `project_handler.go:50-58`): *"Proje detayının gerçek finans kaynağı her zaman GET /projects/{id}/financial-summary'dir"* ("The real source of truth for a project's detail-screen finances is always GET /projects/{id}/financial-summary"). This exact behavior was called out as a fixed audit finding — the pointer/omitempty pattern is the fix that replaced silently-wrong zeros.

**Mobile implication**: the project detail screen must NOT rely on `GET /projects/{id}` for `current_contract_value`, `collected`, `balance`, cost/profit figures. It must call `GET /projects/{id}/financial-summary` (§6) separately and merge. Only the **list** endpoint (§1) returns these fields populated on the `projectResponse` itself.

There is also a sibling read-only endpoint reusing the exact same `projectResponse` DTO and the exact same omission behavior: `GET /api/v1/offers/{id}/project` (router.go:141, handler `GetByOffer`, project_handler.go:210-218) — returns 404 if the offer hasn't been converted to a project yet (used by the offer screen's "Convert to Project" vs "View Project" toggle).

---

## 4. `PUT /api/v1/projects/{id}` — Update

Router: `router.go:152`. Auth: `requireAuth`.

**Request struct** — `updateProjectRequest` (`project_handler.go:220-228`):
```go
type updateProjectRequest struct {
	Name          string  `json:"name"`
	ProjectType   string  `json:"project_type"`
	Status        string  `json:"status"`
	StartDate     *string `json:"start_date"`
	EndDate       *string `json:"end_date"`
	Description   string  `json:"description"`
	InternalNotes string  `json:"internal_notes"`
}
```
Note deliberately **absent** fields (comment at `project_service.go:374-378`): `project_no`, `source_offer_id`, `source_revision_id`, `contract_amount`, `currency`, and all `customer_*` fields — these are frozen snapshots and cannot be edited via this endpoint.

**Validation / state machine** (`project_service.go:390-471`, transitions defined in `internal/domain/project.go:29-52`):
- `name` required (trimmed non-empty) → else 400 `"proje adı zorunludur"`.
- If `status` omitted, keeps current status.
- `status` must be one of `planned/active/paused/completed/cancelled` → else 400 `"geçersiz proje durumu"`.
- Transition must be legal per `projectTransitions` map:
  - `planned` → `active`, `paused`, `cancelled`
  - `active` → `paused`, `completed`, `cancelled`
  - `paused` → `active`, `completed`, `cancelled`
  - `completed` → `active` **only** (reopening) — completed is otherwise locked
  - `cancelled` → *(none — terminal)*
  - Same-status "no-op" update is always allowed.
  - Illegal transition → `ErrInvalidProjectState` → **409**.
- The whole update runs inside a transaction with `SELECT ... FOR UPDATE` row lock to avoid races with concurrent finance mutations that also check project status.

**Response 200**: same `projectResponse` as §3 (same omission caveat applies — `Update` also uses `withSourceOfferInfo`/`ToDomainProject`, so finance fields are absent here too).

---

## 5. `GET /api/v1/projects/{id}/financial-summary`

Router: `router.go:153`. Auth: `requireAuth`. **This is the actual/authoritative source for `current_contract_value` and all cost/profit numbers** for a single project.

**Response struct** — `financialSummaryResponse`, verbatim (`project_finance_handler.go:620-650`):
```go
type financialSummaryResponse struct {
	BaseContractAmount     float64 `json:"base_contract_amount"`
	ApprovedAdditions      float64 `json:"approved_additions"`
	ApprovedDeductions     float64 `json:"approved_deductions"`
	CurrentContractValue   float64 `json:"current_contract_value"`
	PendingAdditions       float64 `json:"pending_additions"`
	PendingDeductions      float64 `json:"pending_deductions"`
	PotentialContractValue float64 `json:"potential_contract_value"`

	ContractAmount               float64 `json:"contract_amount"`  // == BaseContractAmount, kept for back-compat
	Currency                     string  `json:"currency"`
	PlannedCollections           float64 `json:"planned_collections"`
	CollectedAmount              float64 `json:"collected_amount"`
	RemainingReceivable          float64 `json:"remaining_receivable"`
	OverCollected                float64 `json:"over_collected"`
	TotalExpenses                float64 `json:"total_expenses"`
	TotalSubcontractorCommitment float64 `json:"total_subcontractor_commitment"`
	SubcontractorPaid            float64 `json:"subcontractor_paid"`
	SubcontractorRemaining       float64 `json:"subcontractor_remaining"`
	IssuedInvoiceTotal           float64 `json:"issued_invoice_total"`
	PaidInvoiceTotal             float64 `json:"paid_invoice_total"`
	RealizedCost                 float64 `json:"realized_cost"`
	CommittedCost                float64 `json:"committed_cost"`
	RealizedGrossProfit          float64 `json:"realized_gross_profit"`
	EstimatedGrossProfit         float64 `json:"estimated_gross_profit"`
	RealizedMarginPercent        float64 `json:"realized_margin_percent"`
	EstimatedMarginPercent       float64 `json:"estimated_margin_percent"`
}
```
None of these are pointers/omitempty — **all 21 fields are always present as JSON numbers** (except `currency`, a string), computed in one SQL query (`GetProjectFinancialSummary`) and mapped 1:1 by `repository.ToDomainFinancialSummary`. Definitions worth calling out for the mobile app's labels:
- `current_contract_value` = `base_contract_amount + approved_additions - approved_deductions` (domain.go:111-114, 259-271).
- `realized_cost` = `total_expenses + subcontractor_paid` (domain.go:124, mirrored in SQL).
- `realized_gross_profit` = `current_contract_value - realized_cost`.
- `over_collected` = `max(0, -remaining_receivable)` — i.e. how much the customer overpaid, exposed as a always-non-negative separate field rather than a negative `remaining_receivable` the UI must reinterpret.
- `potential_contract_value` = current + still-pending (unapproved) change orders' net effect (optimistic projection).

This is the single field set the task asked to locate exactly: **`current_contract_value` (§CurrentContractValue), `collected` → `collected_amount`, `balance` → `remaining_receivable`, `realized_cost` → `realized_cost`, `estimated_cost` → `committed_cost`** (there is no field literally named `estimated_cost`; the closest concept is `committed_cost` = realized + subcontractors' remaining commitment), **`estimated_profit` → `estimated_gross_profit`**.

---

## 6. `GET /api/v1/projects/{id}/events`

Router: `router.go:154`. Returns the project's audit timeline.

**Response**: `{"events": [ <projectEventResponse>, ... ]}`, struct (`project_finance_handler.go:676-682`):
```go
type projectEventResponse struct {
	ID        string         `json:"id"`
	EventType string         `json:"event_type"`
	UserID    *string        `json:"user_id"`
	Metadata  map[string]any `json:"metadata,omitempty"`
	CreatedAt string         `json:"created_at"`
}
```
`event_type` enum values are all the `domain.ProjectEvent*` / `domain.ProjectEventChangeOrder*` constants (`project_finance.go:77-95`, `project_change_order.go:51-61`): `project_created`, `project_updated`, `project_status_changed`, `payment_plan_created`, `payment_plan_updated`, `payment_plan_cancelled`, `collection_received`, `collection_voided`, `expense_added`, `expense_updated`, `expense_voided`, `invoice_created`, `invoice_status_changed`, `subcontractor_added`, `subcontractor_updated`, `subcontractor_payment_added`, `subcontractor_payment_voided`, `change_order_created`, `change_order_updated`, `change_order_sent`, `change_order_viewed`, `change_order_approved`, `change_order_rejected`, `change_order_cancelled`, `change_order_superseded`, `change_order_email_sent`, `change_order_email_failed`. `metadata` is a free-form JSON object (varies per event type, not typed).

---

## 7. Payment plan — `/projects/{id}/payment-plan`

| Method | Path | Handler |
|---|---|---|
| GET | `/api/v1/projects/{id}/payment-plan` | `ListPaymentPlan` |
| POST | `/api/v1/projects/{id}/payment-plan` | `CreatePaymentPlanItem` |
| PUT | `/api/v1/projects/{id}/payment-plan/{itemId}` | `UpdatePaymentPlanItem` |
| DELETE | `/api/v1/projects/{id}/payment-plan/{itemId}` | `CancelPaymentPlanItem` (soft — sets status `cancelled`, no hard delete) |

**Request** — `paymentPlanItemRequest` (`project_finance_handler.go:69-76`):
```go
type paymentPlanItemRequest struct {
	Name          string   `json:"name"`
	Percentage    *float64 `json:"percentage"`      // if set, PlannedAmount is ignored & recomputed
	PlannedAmount float64  `json:"planned_amount"`
	DueDate       *string  `json:"due_date"`
	SortOrder     int      `json:"sort_order"`
	Notes         string   `json:"notes"`
}
```
Rules (`project_finance_service.go:111-182, 227-304`): `name` required; if `percentage` provided it must be `> 0` and the amount is computed server-side as `round(contract_amount * percentage / 100, 2)` in SQL numeric (never client-trusted); resulting `amount` must be `> 0` else `ErrInvalidAmount` (400, message `"tutar sıfırdan büyük olmalıdır"`). Requires project not `completed`/`cancelled` (`ErrProjectLocked`, 409).

**Response item** — `paymentPlanItemResponse` (lines 44-55):
```go
type paymentPlanItemResponse struct {
	ID              string   `json:"id"`
	SortOrder       int      `json:"sort_order"`
	Name            string   `json:"name"`
	Percentage      *float64 `json:"percentage"`
	PlannedAmount   float64  `json:"planned_amount"`
	CollectedAmount float64  `json:"collected_amount"`
	RemainingAmount float64  `json:"remaining_amount"`  // max(0, planned-collected), computed in handler
	DueDate         *string  `json:"due_date"`
	Status          string   `json:"status"`            // DERIVED, see below — never "stale"
	Notes           string   `json:"notes"`
}
```
`status` is one of `pending|partial|paid|overdue|cancelled` (`domain.PlanItem*` constants, `project_finance.go:10-16`) — **only `pending` and `cancelled` are ever stored**; `partial/paid/overdue` are derived at read time from `collected vs planned` and `due_date vs today` (`domain.EffectivePlanItemStatus`, `project_finance.go:135-155`) so they can never go stale.

**List response**: `{"items": [...], "planned_total": <float64>}` — `planned_total` is computed by a separate SQL-numeric aggregate query (`GetPaymentPlanTotal`) specifically to avoid float rounding drift vs. the financial-summary endpoint.

---

## 8. Collections — `/projects/{id}/collections`

| Method | Path |
|---|---|
| GET | `/api/v1/projects/{id}/collections` |
| POST | `/api/v1/projects/{id}/collections` |
| POST | `/api/v1/projects/{id}/collections/{collectionId}/void` |

**Request** — `collectionRequest` (`project_finance_handler.go:175-184`):
```go
type collectionRequest struct {
	PaymentPlanItemID *string `json:"payment_plan_item_id"`  // optional link to a plan item
	Amount            float64 `json:"amount"`
	Currency          string  `json:"currency"`               // must equal project currency, or be empty
	ReceivedDate      string  `json:"received_date"`          // "" → defaults to today (server clock)
	PaymentMethod     string  `json:"payment_method"`
	Description       string  `json:"description"`
	ReferenceNo       string  `json:"reference_no"`
	IdempotencyKey    string  `json:"idempotency_key"`        // body field, NOT a header
}
```
Rules: `amount > 0` (`ErrInvalidAmount`, 400); `currency` if non-empty must match the project's currency exactly, else `ErrCurrencyMismatch` (409) — no FX conversion exists in this codebase; project must be open (`ErrProjectLocked`, 409); if `payment_plan_item_id` given it must belong to the same project or `"geçersiz ödeme planı kalemi"` (400); idempotency is enforced both app-side (lookup by key) and DB-side (partial unique index) — a repeat POST with the same key returns the original record (still 201), never a duplicate or error.

**Response** — `collectionResponse` (lines 152-164):
```go
type collectionResponse struct {
	ID                string  `json:"id"`
	PaymentPlanItemID *string `json:"payment_plan_item_id"`
	Amount            float64 `json:"amount"`
	Currency          string  `json:"currency"`
	ReceivedDate      string  `json:"received_date"`   // date-only
	PaymentMethod     string  `json:"payment_method"`
	Description       string  `json:"description"`
	ReferenceNo       string  `json:"reference_no"`
	VoidedAt          *string `json:"voided_at"`        // RFC3339 or null
	VoidReason        string  `json:"void_reason"`
	CreatedAt         string  `json:"created_at"`
}
```
List response: `{"collections": [...]}`.

**Void**: `POST .../collections/{collectionId}/void`, body `voidRequest {Reason string \`json:"reason"\`}` (`project_finance_handler.go:226-228`) — **body decode errors are swallowed** (`_ = httpjson.Decode(r, &req)`, line 232), so a malformed/missing body simply results in `reason=""`; reason is never required non-empty by the service. Soft-void only (row kept, `voided_at`/`voided_by`/`void_reason` set) — collections are never hard-deleted. Voiding an already-voided record → `ErrAlreadyVoided` (409, distinct from 404 for "not found").

---

## 9. Expenses — `/projects/{id}/expenses` (exact shape requested)

| Method | Path |
|---|---|
| GET | `/api/v1/projects/{id}/expenses` |
| POST | `/api/v1/projects/{id}/expenses` |
| PUT | `/api/v1/projects/{id}/expenses/{expenseId}` |
| POST | `/api/v1/projects/{id}/expenses/{expenseId}/void` |

**Request struct — `expenseRequest`, verbatim** (`project_finance_handler.go:271-282`):
```go
type expenseRequest struct {
	Category       string  `json:"category"`
	Description    string  `json:"description"`
	Amount         float64 `json:"amount"`
	Currency       string  `json:"currency"`
	ExpenseDate    string  `json:"expense_date"`      // "YYYY-MM-DD"; "" defaults to today
	SupplierName   string  `json:"supplier_name"`
	InvoiceNo      string  `json:"invoice_no"`
	Notes          string  `json:"notes"`
	IdempotencyKey string  `json:"idempotency_key"`
	ChangeOrderID  string  `json:"change_order_id"`    // plain string, "" = none (not a *string)
}
```
Same struct is used for both Create and Update (only Update additionally requires `Amount > 0` directly, since it has no `requireOpenProject` money floor check the same way — see below).

**`category` enum** — `domain.ValidExpenseCategory` (`project_finance.go:21-36`), exactly these 7 values, no others accepted (400 `"geçersiz masraf kategorisi"` otherwise):
`material`, `personnel`, `transport`, `accommodation`, `food`, `equipment`, `other`.
Note the domain comment explicitly documents that `"subcontractor"` is **intentionally not** a category — subcontractor payments are entered only through the separate Subcontractor Payments resource (§10) to avoid double-counting cost.

**Validation** (`project_finance_service.go:533-625` Create, `647-696` Update):
- `category` must be valid (400).
- `description` (trimmed) required, else 400 `"masraf açıklaması zorunludur"`.
- `amount > 0` and `currency` (if given) must equal project currency — same `validateMoney` as collections (`ErrInvalidAmount`/`ErrCurrencyMismatch`).
- Project must be open (Create only — `requireOpenProject`; Update does **not** call `requireOpenProject`, only Create/Void do — worth flagging: an expense on a locked/completed project can still be *edited* via `UpdateExpense`, just not *created*).
- `change_order_id` optional; if non-empty it is resolved via `resolveChangeOrderRef` (`project_change_order_service.go:80-100`) which requires it to be a valid UUID belonging to the **same project and organization**, else `ErrInvalidChangeOrderRef` (400). Empty string → stored as SQL NULL (not linked to any change order — falls under the base contract).
- Idempotency: same body-field + DB-unique-index pattern as collections (`idempotency_key`, symmetric with Collections/SubcontractorPayments — the code comment explicitly says this parity was a fix, expenses previously lacked it).

**Response struct — `expenseResponse`** (lines 245-259):
```go
type expenseResponse struct {
	ID            string  `json:"id"`
	Category      string  `json:"category"`
	Description   string  `json:"description"`
	Amount        float64 `json:"amount"`
	Currency      string  `json:"currency"`
	ExpenseDate   string  `json:"expense_date"`
	SupplierName  string  `json:"supplier_name"`
	InvoiceNo     string  `json:"invoice_no"`
	Notes         string  `json:"notes"`
	VoidedAt      *string `json:"voided_at"`
	VoidReason    string  `json:"void_reason"`
	CreatedAt     string  `json:"created_at"`
	ChangeOrderID *string `json:"change_order_id,omitempty"`
}
```
List response: `{"expenses": [...]}`. Void: `POST .../expenses/{expenseId}/void`, same `voidRequest{reason}` body as collections, same soft-void semantics, same `ErrAlreadyVoided` distinction.

---

## 10. Invoices — `/projects/{id}/invoices`

| Method | Path |
|---|---|
| GET | `/api/v1/projects/{id}/invoices` |
| POST | `/api/v1/projects/{id}/invoices` |
| PUT | `/api/v1/projects/{id}/invoices/{invoiceId}/status` |

**Request** — `invoiceRequest` (`project_finance_handler.go:377-387`):
```go
type invoiceRequest struct {
	InvoiceNo    string  `json:"invoice_no"`
	InvoiceType  string  `json:"invoice_type"`   // "sales" | "purchase"
	InvoiceDate  string  `json:"invoice_date"`   // "" → today
	DueDate      *string `json:"due_date"`
	Amount       float64 `json:"amount"`
	Currency     string  `json:"currency"`
	Status       string  `json:"status"`          // "" → defaults to "draft"
	CustomerName string  `json:"customer_name"`   // "" → defaults to project.CustomerName
	Notes        string  `json:"notes"`
}
```
`invoice_type` must be `sales` or `purchase` (`domain.ValidInvoiceType`, `project_finance.go:38-41,58-60`) else 400 `"geçersiz fatura tipi"`. `status` enum (`domain.ValidInvoiceStatus`, lines 43-56): `draft`, `issued`, `sent`, `paid`, `cancelled`. `invoice_no` required non-empty (400 `"fatura numarası zorunludur"`). Same `validateMoney`/`requireOpenProject` gates as expenses.

Status change endpoint takes a separate tiny body: `invoiceStatusRequest{Status string \`json:"status"\`}` (line 424-426) — re-validated against the same enum.

**Response** — `invoiceResponse` (lines 354-366): `id, invoice_no, invoice_type, invoice_date, due_date(*string), amount(float64), currency, status, customer_name, notes, created_at`. List response `{"invoices": [...]}`.

---

## 11. Subcontractors + Payments

| Method | Path |
|---|---|
| GET | `/api/v1/projects/{id}/subcontractors` |
| POST | `/api/v1/projects/{id}/subcontractors` |
| PUT | `/api/v1/projects/{id}/subcontractors/{subcontractorId}` |
| POST | `/api/v1/projects/{id}/subcontractors/{subcontractorId}/payments` |
| GET | `/api/v1/projects/{id}/subcontractor-payments` |
| POST | `/api/v1/projects/{id}/subcontractor-payments/{paymentId}/void` |

**Subcontractor request** — `subcontractorRequest` (`project_finance_handler.go:474-487`):
```go
type subcontractorRequest struct {
	Name            string  `json:"name"`
	CompanyName     string  `json:"company_name"`
	Phone           string  `json:"phone"`
	Email           string  `json:"email"`
	WorkDescription string  `json:"work_description"`
	ContractAmount  float64 `json:"contract_amount"`
	Currency        string  `json:"currency"`
	StartDate       *string `json:"start_date"`
	EndDate         *string `json:"end_date"`
	Status          string  `json:"status"`          // "" on create → "planned"
	Notes           string  `json:"notes"`
	ChangeOrderID   string  `json:"change_order_id"`  // optional, same resolveChangeOrderRef rule as expenses
}
```
`status` enum (`domain.ValidSubcontractorStatus`, `project_finance.go:63-74`): `planned`, `active`, `completed`, `cancelled`. `name` required; `contract_amount` validated via `validateMoney` (Create) / must be `>0` (Update).

**Subcontractor response** — `subcontractorResponse` (lines 446-462): `id, name, company_name, phone, email, work_description, contract_amount(float64), paid_amount(float64), remaining_amount(float64), currency, start_date(*string), end_date(*string), status, notes, change_order_id(*string, omitempty)`. `paid_amount`/`remaining_amount` are aggregated from actual payment rows, not stored columns.

**Subcontractor payment request** — `subcontractorPaymentRequest` (lines 564-570): `amount(float64), currency, paid_date(string, ""→today), description, idempotency_key`. Idempotency key is scoped **per-subcontractor** (not per-project) — explicitly called out in a code comment (`project_finance_service.go:1098-1100`) as a fix for a bug where two different subcontractors in the same project could collide on the same key.

**Payment response** — `subcontractorPaymentResponse` (lines 544-554): `id, subcontractor_id, amount(float64), currency, paid_date, description, voided_at(*string), void_reason, created_at`. Void follows the same `voidRequest{reason}` / soft-void / `ErrAlreadyVoided` pattern as collections/expenses.

---

## 12. Change Orders — `/projects/{id}/change-orders/*`

| Method | Path | Handler | Purpose |
|---|---|---|---|
| GET | `/api/v1/projects/{id}/change-orders` | `ListChangeOrders` | |
| POST | `/api/v1/projects/{id}/change-orders` | `CreateChangeOrder` | create draft |
| GET | `/api/v1/projects/{id}/change-orders/{changeOrderId}` | `GetChangeOrder` | |
| PUT | `/api/v1/projects/{id}/change-orders/{changeOrderId}` | `UpdateChangeOrder` | edit draft only |
| POST | `/api/v1/projects/{id}/change-orders/{changeOrderId}/send` | `SendChangeOrder` | draft → sent, creates share link |
| POST | `/api/v1/projects/{id}/change-orders/{changeOrderId}/send-email` | `SendChangeOrderEmail` | emails the customer share link |
| POST | `/api/v1/projects/{id}/change-orders/{changeOrderId}/revise` | `ReviseChangeOrder` | sent/rejected → new draft, old → superseded |
| POST | `/api/v1/projects/{id}/change-orders/{changeOrderId}/cancel` | `CancelChangeOrder` | draft/sent → cancelled |

### ⚠️ State machine — exact, verified (`internal/domain/project_change_order.go:22-39` + `internal/service/project_change_order_service.go`)

```
draft --(send)--> sent --(customer approves via PUBLIC link)--> approved  [FINAL]
                       \-(customer rejects via PUBLIC link)---> rejected
                       \-(staff cancel)------------------------> cancelled [terminal]
draft --(staff cancel)------------------------------------------> cancelled [terminal]
sent, rejected --(staff revise)---------------------------------> superseded (old) + new draft cloned
```
- **`approved` is FINAL**: cannot be edited, cancelled, or revised again (comment at domain file lines 29-31). Its commercial effect can only be reversed by creating a new `deduction`-type change order.
- **There is NO authenticated-staff "approve" or "reject" endpoint.** Approval/rejection ONLY happens through the customer-facing, unauthenticated public link: `POST /api/v1/public/change-orders/{token}/respond` with body `{"decision": "approved"|"rejected"}` (`public_change_order_handler.go:86-110`, service `RespondChangeOrderByShareLinkToken`, `project_change_order_service.go:800-882`). If the mobile staff app needs an internal "mark as approved" action, **NOT SUPPORTED — no endpoint found**; the only staff-side action after `send` is `cancel` or `revise`.
- **There is NO "void" action or void-reason field on change orders.** `CancelChangeOrder` (`project_change_order_handler.go:228-237`) takes **no request body at all** — it doesn't even call `httpjson.Decode`. `domain.ChangeOrder` has no `VoidedAt`/`VoidReason` fields (compare `project_change_order.go:79-121` to `Collection`/`Expense`/`SubcontractorPayment` in `project_finance.go`, which do have `VoidedAt/VoidedBy/VoidReason`). So: **NOT SUPPORTED — cancel takes no reason field**, unlike collections/expenses/subcontractor-payment voids which do.
- Approving a `deduction` is blocked server-side if it would push `current_contract_value` negative — `ErrChangeOrderWouldGoNegative` (409, checked via a dedicated numeric SQL check `ChangeOrderApprovalWouldGoNegative` to avoid float rounding false-positives).
- `email` action (`send-email`) is allowed while status is `sent`, `approved`, or `rejected` (not `draft`/`cancelled`/`superseded`) — else `ErrChangeOrderNotSendable` (409).

**Create/Update request** — `changeOrderRequest` (`project_change_order_handler.go:23-31`):
```go
type changeOrderRequest struct {
	ChangeType    string                   `json:"change_type"`  // "addition" | "deduction"
	Title         string                   `json:"title"`
	Description   string                   `json:"description"`
	VatRate       float64                  `json:"vat_rate"`
	CustomerNotes string                   `json:"customer_notes"`
	InternalNotes string                   `json:"internal_notes"`
	Items         []changeOrderItemRequest `json:"items"`
}
type changeOrderItemRequest struct {
	ProductID         *string  `json:"product_id"`
	Description       string   `json:"description"`
	Quantity          float64  `json:"quantity"`
	Unit              string   `json:"unit"`
	UnitPrice         float64  `json:"unit_price"`
	EstimatedUnitCost *float64 `json:"estimated_unit_cost"`
}
```
Validation (`validateChangeOrderInput`, `project_change_order_service.go:126-151`): `change_type` ∈ {`addition`,`deduction`}; `title` required; `vat_rate >= 0`; **at least one item required**, else `ErrNoChangeOrderItems` (400 — literal message "en az bir kalem girilmeli ve toplam sıfırdan büyük olmalıdır"); each item needs non-empty `description`, `quantity > 0`, `unit_price > 0`. Line totals and `subtotal/vat_amount/grand_total` are always recomputed server-side in SQL (`RecomputeChangeOrderTotals`), never trusted from the client. `Update` only works while status is exactly `draft` (`ErrChangeOrderNotEditable`, 409) — it fully replaces the item list (delete-then-reinsert), same pattern as offer revisions.

**Response struct** — `changeOrderResponse` (auth'd, staff-only view; verbatim, `project_change_order_handler.go:74-102`):
```go
type changeOrderResponse struct {
	ID                      string                            `json:"id"`
	ProjectID               string                            `json:"project_id"`
	SequenceNo              int                               `json:"sequence_no"`
	ChangeOrderNo           string                            `json:"change_order_no"`      // "EK-003" derived, not stored
	ChangeType              string                            `json:"change_type"`
	Title                   string                            `json:"title"`
	Description             string                            `json:"description"`
	Status                  string                            `json:"status"`
	Subtotal                float64                           `json:"subtotal"`
	VatRate                 float64                           `json:"vat_rate"`
	VatAmount               float64                           `json:"vat_amount"`
	GrandTotal              float64                           `json:"grand_total"`
	Currency                string                            `json:"currency"`
	InternalNotes           string                            `json:"internal_notes"`
	CustomerNotes           string                            `json:"customer_notes"`
	CreatedBy               *string                           `json:"created_by"`
	CreatedAt               string                            `json:"created_at"`
	UpdatedAt               string                            `json:"updated_at"`
	SentAt                  *string                           `json:"sent_at"`
	RespondedAt             *string                           `json:"responded_at"`
	ApprovedAt              *string                           `json:"approved_at"`
	RejectedAt              *string                           `json:"rejected_at"`
	CancelledAt             *string                           `json:"cancelled_at"`
	SupersedesChangeOrderID *string                           `json:"supersedes_change_order_id"`
	ActiveShareToken        *string                           `json:"active_share_token,omitempty"`
	Items                   []changeOrderItemResponse         `json:"items,omitempty"`
	Profitability           *changeOrderProfitabilityResponse `json:"profitability,omitempty"`
}
```
`status` enum: `draft`, `sent`, `approved`, `rejected`, `cancelled`, `superseded`. `change_order_no` is derived as `EK-%03d` from `sequence_no`, never a stored column. `active_share_token` is only present when there's a currently-valid (non-revoked, non-expired) share link — populated for **List** rows directly from the JOIN, and for **Get** (single) only when `status == "sent"` (slight asymmetry, both verified in `repository/project_change_order.go:95-98` vs `service/project_change_order_service.go:279-286`). `profitability` (verbatim, lines 60-68):
```go
type changeOrderProfitabilityResponse struct {
	RevenueEffect          float64 `json:"revenue_effect"`
	RealizedCost           float64 `json:"realized_cost"`
	CommittedCost          float64 `json:"committed_cost"`
	RealizedProfit         float64 `json:"realized_profit"`
	EstimatedProfit        float64 `json:"estimated_profit"`
	RealizedMarginPercent  float64 `json:"realized_margin_percent"`
	EstimatedMarginPercent float64 `json:"estimated_margin_percent"`
}
```
Populated only on **List** (each row gets it computed); **Get** (single change order) leaves `Profitability` nil → omitted (`omitempty`). List response wrapper: `{"change_orders": [...]}`.

**send-email request/response**: `changeOrderEmailRequest{to, subject, message}` (all strings) → `{"status": "sent"}` on success (200) regardless of whether the underlying SMTP send itself failed or not at the HTTP layer — actual delivery success/failure is recorded as a `ChangeOrderEmailLog` row and a `change_order_email_sent`/`change_order_email_failed` event, but the handler always returns 200 `{"status":"sent"}` if the surrounding validation passed (verify with your QA — the SMTP failure is swallowed into the event log, not surfaced as an HTTP error, per `SendChangeOrderEmail`'s three-phase design at `project_change_order_service.go:583-690`, phase 3 does `return sendErr` — actually correcting myself: the function DOES return `sendErr` from `SendChangeOrderEmail` at line 689, so a real SMTP failure **does** propagate as a non-nil error to the handler, which then goes through `writeError`; since `sendErr` is a plain `errors.New`-shaped mailer error it falls into the default 400 branch unless it's a recognized internal/network error type).

---

## 13. Consolidated "NOT SUPPORTED" list (for anything the task hypothesized)

- **No plain `POST /api/v1/projects`** — creation only via `POST /projects/from-offer/{offerId}`.
- **No `DELETE /api/v1/projects/{id}`.**
- **No authenticated staff "approve"/"reject" endpoint for change orders** — only the public customer link (`/api/v1/public/change-orders/{token}/respond`) can approve/reject.
- **No "void" endpoint or void-reason field for change orders** — only `cancel`, with no request body.
- **`GET /projects/{id}` does not return `current_contract_value` or any finance aggregate** — call `GET /projects/{id}/financial-summary` instead (see the critical finding in §3).
- **No currency conversion anywhere** — every finance sub-resource enforces `currency == project.currency` server-side (or accepts empty and defaults to it); mismatched currency is a hard 409, not converted.
- **`idempotency_key` is always a JSON body field**, never an HTTP header, across collections/expenses/subcontractor-payments.
- **Auth is a cookie (`access_token`), not an `Authorization: Bearer` header** — the mobile HTTP client must persist and send cookies (with `credentials: include`-equivalent), matching the CORS config's `AllowCredentials: true` (`router.go:45`).