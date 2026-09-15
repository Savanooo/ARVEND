# ARVEND `/api/v1/calculations/*` — Verified API Contract (Flutter client reference)

All facts below are read directly from the Go source in `/Users/tahaeryetisozen/Documents/GitHub/x-api/ARVEND/backend`. File:line citations are given for every claim. Nothing here is inferred beyond what the code states.

---

## 0. Transport-level facts that apply to every endpoint below

**Auth is httpOnly-cookie based, not a Bearer header.** `router.go:48` wires `requireAuth := appmw.RequireAuth(d.JWT)`, and `middleware/auth.go:29` reads the JWT from `r.Cookie("access_token")` — there is no header-based auth path anywhere in this router. A Flutter client **must** use a cookie-aware HTTP client (persist `Set-Cookie` from `POST /api/v1/auth/login` and replay it) or every one of these endpoints will 401. Login (`auth_handler.go:47-59`) returns the user profile as JSON body and sets the token via `h.setSessionCookies(...)`, never in the response body.

**Route group for the whole tree** — `router.go:97-117`:
```go
r.Route("/calculations", func(r chi.Router) {
    r.Use(requireAuth)
    r.Get("/groups", d.Calc.ListGroups)
    r.Get("/categories", d.Calc.ListCategories)
    r.Post("/run", d.Calc.Run)
    r.Get("/recipe-items", d.Calc.ListRecipeItems)

    r.Group(func(r chi.Router) {
        r.Use(requireAdmin)
        r.Post("/groups", d.Calc.CreateGroup)
        r.Put("/groups/{id}", d.Calc.UpdateGroup)
        r.Post("/categories", d.Calc.CreateCategory)
        r.Put("/categories/{id}", d.Calc.UpdateCategory)
        r.Post("/recipe-items", d.Calc.CreateRecipeItem)
        r.Put("/recipe-items/{id}", d.Calc.UpdateRecipeItem)
        r.Delete("/recipe-items/{id}", d.Calc.DeleteRecipeItem)
    })
})
```
`requireAdmin := appmw.RequireRole(domain.RoleAdmin)` (`router.go:49`, role constant `RoleAdmin = "admin"` at `internal/domain/user.go:11`).

**Error response shapes** (there is no generic envelope beyond `{"error": "..."}`):
- `httpjson.Error` → `httpjson.Write(w, status, map[string]string{"error": message})` (`internal/platform/httpjson/httpjson.go:22-24`).
- 401 (no cookie): `http.Error(w, `{"error":"oturum bulunamadı"}`, 401)` (`middleware/auth.go:31`).
- 401 (bad/expired token): `{"error":"oturum geçersiz veya süresi dolmuş"}` (`middleware/auth.go:36`).
- 403 (wrong role): `{"error":"bu işlem için yetkiniz yok"}` (`middleware/require_role.go:16`).
- 400 (bad JSON body): `{"error":"geçersiz istek gövdesi"}` — every calc handler that decodes a body uses this exact literal (e.g. `calc_handler.go:74,91,196,215,355,375,465`). Body decoding uses `json.NewDecoder(r.Body).DisallowUnknownFields()` (`httpjson.go:29`), so **unknown JSON fields in a request body cause a 400**, not a silent ignore.
- 404: `domain.ErrNotFound = errors.New("kayıt bulunamadı")` (`internal/domain/errors.go:6`); handler maps it via `CalcHandler.writeError`:
```go
func (h *CalcHandler) writeError(w http.ResponseWriter, err error) {
    switch {
    case errors.Is(err, domain.ErrNotFound):
        httpjson.Error(w, http.StatusNotFound, "kayıt bulunamadı")
    default:
        httpjson.Error(w, http.StatusBadRequest, err.Error())
    }
}
```
(`calc_handler.go:567-574`) — **every other service-layer error (validation, "category not found for org", "recipe not defined for category", geometry errors) comes back as HTTP 400 with the raw Go error string as `message`**, in Turkish, verbatim from the service/domain layer (no generic "validation_error" code exists in this module). There is no field-level error array — it's a single string.

---

## 1. `GET /api/v1/calculations/groups`
- Auth: `requireAuth` only (any authenticated user, any role).
- Query params: none.
- Handler: `calc_handler.go:49-61`.
- Response `200`:
```go
type calcGroupResponse struct {
    ID          string `json:"id"`
    Slug        string `json:"slug"`
    Name        string `json:"name"`
    Description string `json:"description"`
    SortOrder   int    `json:"sort_order"`
    IsActive    bool   `json:"is_active"`
}
```
wrapped as `{"groups": [calcGroupResponse, ...]}`. `ListGroups` only returns **active** groups (`ListCalcGroups` SQL: `WHERE organization_id = $1 AND is_active = true`, `queries/calc.sql:4`) — there is no way for a non-admin to see inactive groups through this endpoint.
- Errors: `500 {"error":"gruplar alınamadı"}` on any DB error.

### `POST /api/v1/calculations/groups` (admin only)
Request:
```go
type upsertCalcGroupRequest struct {
    Slug        string `json:"slug"`
    Name        string `json:"name"`
    Description string `json:"description"`
    SortOrder   int    `json:"sort_order"`
    IsActive    *bool  `json:"is_active"`
}
```
`IsActive` is accepted in the request struct but **ignored by `CreateGroup`** (only `slug/name/description/sort_order` are passed to `service.CalcGroupInput`, `calc_handler.go:78-80`) — new groups are always created active (DB default `true`, migration line 36). Validation (`service.CalcGroupInput.validate`, `calc_service.go:59-67`): `slug` and `name` are required (`strings.TrimSpace(...) == ""` → error), description/sort_order unconstrained. Response `201` = `calcGroupResponse`. Duplicate slug → `mapCalcWriteError` converts Postgres `23505` into `"bu slug ile bir grup zaten var"` (400).

### `PUT /api/v1/calculations/groups/{id}` (admin only)
Same request body; here `IsActive` **is** honored (`isActive := true; if req.IsActive != nil { isActive = *req.IsActive }`, `calc_handler.go:95-98`) — omitting `is_active` in a PUT defaults to `true` (re-activates a group even if it was inactive, unless the client explicitly sends `false`). Response `200` = `calcGroupResponse`, 404 if group id/org mismatch.

---

## 2. `GET /api/v1/calculations/categories`
- Auth: `requireAuth` only.
- Query param: `group_id` (optional, UUID string).
- Handler: `calc_handler.go:145-182`.

**Two distinct response shapes depending on the query param** — this is the single most important shape-branching fact for the mobile client:

**a) `?group_id=<uuid>` present** → flat list, admin-editing shape:
```json
{"categories": [calcCategoryResponse, ...]}
```
via `ListCategoriesByGroup` → SQL filters `is_active = true` (`queries/calc.sql:30`) — **only active categories**, even though this call requires no admin role.

**b) no `group_id`** → nested "grup seç → kategori seç" cascade shape used by the calculator panel:
```go
type calcGroupWithCategoriesResponse struct {
    ID         string                 `json:"id"`
    Slug       string                 `json:"slug"`
    Name       string                 `json:"name"`
    Categories []calcCategoryResponse `json:"categories"`
}
```
wrapped as `{"groups": [calcGroupWithCategoriesResponse, ...]}`. Built from `ListCategoriesForOrg` → SQL `ListActiveCalcCategoriesForOrg` (`queries/calc.sql:37-42`), which requires **both** the category and its parent group to be active (`c.is_active = true AND g.is_active = true`). Note the response key is `"groups"` in **both** branches of `ListCategories`, but the array element type differs (flat category objects vs. grouped-with-nested-categories objects) — a client must switch parsing based on whether it sent `group_id`.

`calcCategoryResponse` (used inside both shapes):
```go
type calcCategoryResponse struct {
    ID          string  `json:"id"`
    GroupID     string  `json:"group_id"`
    GroupSlug   string  `json:"group_slug,omitempty"`
    GroupName   string  `json:"group_name,omitempty"`
    Slug        string  `json:"slug"`
    Name        string  `json:"name"`
    Description string  `json:"description"`
    ImageFileID *string `json:"image_file_id,omitempty"`
    SortOrder   int     `json:"sort_order"`
    IsActive    bool    `json:"is_active"`
}
```
(`calc_handler.go:111-122`). `GroupSlug`/`GroupName` are populated only via the JOIN in the ungrouped-org listing path (`ToDomainCalcCategoryListRow`, `repository/calc.go:82-92`) — when hit via `?group_id=`, these two fields are empty strings and thus **omitted** (`omitempty`) from the JSON. `ImageFileID` is `*string`, nullable, omitted when nil — it is just a free-form UUID-shaped reference column with **no FK constraint** (migration comment, `0028...up.sql:58-61`: "no general org-level file store exists yet, this is a placeholder"), so there is **no dedicated GET-image endpoint** for calc categories anywhere in the router.

### `POST /api/v1/calculations/categories` / `PUT /api/v1/calculations/categories/{id}` (admin only)
Request:
```go
type upsertCalcCategoryRequest struct {
    GroupID     string  `json:"group_id"`
    Slug        string  `json:"slug"`
    Name        string  `json:"name"`
    Description string  `json:"description"`
    ImageFileID *string `json:"image_file_id"`
    SortOrder   int     `json:"sort_order"`
    IsActive    *bool   `json:"is_active"`
}
```
Validation (`calc_service.go:172-183`): `group_id`, `slug`, `name` required (trim-empty check). `CreateCategory`/`UpdateCategory` additionally verify the `group_id` belongs to the caller's own organization (`GetCalcGroupByID` lookup, `calc_service.go:199-204`) — else `400 "group_id bu organizasyona ait değil"`. Same `IsActive` defaulting quirk as groups: ignored on create (always active), defaults to `true` on update if omitted. Duplicate slug → `"bu slug ile bir kategori zaten var"`.

---

## 3. `GET /api/v1/calculations/recipe-items` — admin vs. active, verified

- Auth: `requireAuth` only — **this route is NOT inside the `requireAdmin` group** (`router.go:105`, it sits before the `r.Group(func(r chi.Router){ r.Use(requireAdmin) ... })` block at line 107).
- Query param: `category_id` — **required**; missing/empty → `400 {"error":"category_id zorunludur"}` (`calc_handler.go:277-281`).
- Handler body (`calc_handler.go:276-293`) calls **`h.svc.ListRecipeItemsAdmin(...)`** unconditionally — there is no branch, no role check, no `?include_inactive=` flag. `ListRecipeItemsAdmin` runs SQL `ListCalcRecipeItemsAdmin`:
```sql
-- name: ListCalcRecipeItemsAdmin :many
SELECT * FROM calc_recipe_items
WHERE category_id = $1 AND organization_id = $2
ORDER BY sort_order ASC, material_name ASC;
```
(`queries/calc.sql:71-74`) — **no `is_active` filter at all.**

**Verified conclusion:** there is exactly **one** public listing endpoint for recipe items, `GET /calculations/recipe-items`, it requires only `requireAuth` (any role), and it always returns **all** recipe items for the category — active and inactive/soft-deleted alike. The "active only" variant (`ListCalcRecipeItems`, SQL at `queries/calc.sql:64-67`, `WHERE ... AND is_active = true`) exists in the service/repository layer but is **only ever invoked internally by `CalcService.Run`** (`calc_service.go:482`) — it is **NOT SUPPORTED as its own HTTP endpoint**. If the mobile app needs an "active-only recipe items" list independent of running a calculation, no such endpoint exists; the client must filter the admin-shaped response by `is_active` itself, or rely on `POST /run`'s `items[]` (which is implicitly active-only, since it's built from the active-only query).

Response `200`: `{"items": [calcRecipeItemResponse, ...]}` where:
```go
type calcRecipeItemResponse struct {
    ID                 string  `json:"id"`
    CategoryID         string  `json:"category_id"`
    ProductID          *string `json:"product_id,omitempty"`
    MaterialName       string  `json:"material_name"`
    Unit               string  `json:"unit"`
    CalculationType    string  `json:"calculation_type"`
    QuantityPerM2      string  `json:"quantity_per_m2"`
    QuantityPerMeter   string  `json:"quantity_per_meter"`
    FixedQuantity      string  `json:"fixed_quantity"`
    WastePercent       string  `json:"waste_percent"`
    RoundingType       string  `json:"rounding_type"`
    MinQuantity        *string `json:"min_quantity,omitempty"`
    PackageSize        *string `json:"package_size,omitempty"`
    ReferenceUnitPrice string  `json:"reference_unit_price"`
    GroupName          string  `json:"group_name"`
    SortOrder          int     `json:"sort_order"`
    IsActive           bool    `json:"is_active"`
    Notes              *string `json:"notes,omitempty"`
}
```
(`calc_handler.go:236-255`) — **every numeric field here is a JSON string** (`.String()` calls at `calc_handler.go:265-273`: `QuantityPerM2.String()`, `WastePercent.String()`, `ReferenceUnitPrice.String()`, etc.), including the nullable ones via `decimalPtrToStringPtr` (`calc_handler.go:257-263`, returns `nil` untouched, else `*string` of `.String()`). `product_id`, `min_quantity`, `package_size`, `notes` are `*string`/nullable-and-`omitempty` — absent from JSON when nil, present as a JSON string otherwise. `calculation_type` is a free string but domain-constrained to exactly `"area_based" | "perimeter_based" | "fixed"` (`domain/calc.go:34-41`, also DB `CHECK` at migration line 88). `rounding_type` constrained to `"none" | "ceil" | "round"` (`domain/calc.go:45-52`, DB CHECK line 99-100).

### `POST /api/v1/calculations/recipe-items` / `PUT .../{id}` (admin only)
Request:
```go
type upsertCalcRecipeItemRequest struct {
    CategoryID         string  `json:"category_id"`
    ProductID          *string `json:"product_id"`
    MaterialName       string  `json:"material_name"`
    Unit               string  `json:"unit"`
    CalculationType    string  `json:"calculation_type"`
    QuantityPerM2      string  `json:"quantity_per_m2"`
    QuantityPerMeter   string  `json:"quantity_per_meter"`
    FixedQuantity      string  `json:"fixed_quantity"`
    WastePercent       string  `json:"waste_percent"`
    RoundingType       string  `json:"rounding_type"`
    MinQuantity        *string `json:"min_quantity"`
    PackageSize        *string `json:"package_size"`
    ReferenceUnitPrice string  `json:"reference_unit_price"`
    GroupName          string  `json:"group_name"`
    SortOrder          int     `json:"sort_order"`
    IsActive           *bool   `json:"is_active"`
    Notes              *string `json:"notes"`
}
```
(`calc_handler.go:295-313`) — **note all numeric fields on the *request* side are plain (non-pointer) `string`, not `*string`**: `quantity_per_m2`, `quantity_per_meter`, `fixed_quantity`, `waste_percent`, `reference_unit_price` are required-shaped strings parsed by `parseOptionalDecimal` (`calc_handler.go:556-565`, empty/nil → `decimal.Zero`, else must parse as a decimal or `400 "<field> geçerli bir sayı olmalı"`). `min_quantity`/`package_size` are `*string` and parsed by `parseNullableDecimal` (`calc_handler.go:543-552`, nil/empty → `nil`, else parse-or-400). Sending a non-numeric string for any of these → `400` with that exact validation message.

Server-side domain validation (`calc_service.go:296-328`, `CalcRecipeItemInput.validate`): `material_name` and `unit` required (non-empty after trim); `calculation_type` must be one of the three valid values else `400 "geçersiz calculation_type: %q (area_based | perimeter_based | fixed olmalı)"`; `rounding_type` must be one of the three valid values (empty defaults to `"none"` via `.normalize()`, `calc_service.go:289-294`) else similar message; **all of** `quantity_per_m2, quantity_per_meter, fixed_quantity, waste_percent, reference_unit_price` must be `>= 0` (negative → `"<field> negatif olamaz"`); `min_quantity` if present must be `>= 0`; `package_size` if present must be `> 0` (`"package_size verilmişse 0'dan büyük olmalı"`). If `product_id` is given it must resolve to a product owned by the caller's own organization (`resolveOwnedProductID`, `calc_service.go:433-448`) else `400 "product_id bu organizasyona ait değil"`; if `product_id` given is malformed → `"geçersiz product_id"`. `category_id` (create only) must belong to caller's org, else `"category_id bu organizasyona ait değil"`. Duplicate `(category_id, material_name, unit)` → DB unique constraint (migration line 122) → `"bu kategoride aynı malzeme adı+birim zaten kayıtlı"`. Response `201`/`200` = `calcRecipeItemResponse` (same string-serialized shape as above).

### `DELETE /api/v1/calculations/recipe-items/{id}` (admin only)
Hard `DELETE` (`DeleteCalcRecipeItem` SQL, `queries/calc.sql:117`) — **not a soft-delete/deactivate**, despite recipe items having an `is_active` column used elsewhere. Response `200 {"ok": true}`; `404` (`domain.ErrNotFound`) if id/org doesn't match.

---

## 4. `POST /api/v1/calculations/run` — full contract

Auth: `requireAuth` only (any role — comment at `calc_service.go:22-25` and `router.go:99-101` explicitly say this must be usable by non-admin staff building offers). Handler: `calc_handler.go:462-539`.

### Request — `calcRunRequest`
```go
type calcRunRequest struct {
    CategoryID string  `json:"category_id"`
    Area       *string `json:"area"`
    Width      *string `json:"width"`
    Height     *string `json:"height"`
    Perimeter  *string `json:"perimeter"`
    PitchDeg   *string `json:"pitch_deg"`
}
```
(`calc_handler.go:407-414`). **Every numeric input field is a `*string`** (mirrors the JSON-string-for-decimals convention) and unknown JSON fields are rejected (`DisallowUnknownFields`).

Parsing/required-ness:
- `category_id`: required plain string. Empty/whitespace-only → `400 "category_id zorunludur"` (`calc_handler.go:468-471`). Not a valid UUID or not found for the caller's org → `404 kayıt bulunamadı` (via `domain.ErrNotFound` from `StringToUUID`/`GetCalcCategoryByID` failure, `calc_service.go:464-479`).
- `area`, `width`, `height`, `perimeter`, `pitch_deg`: each independently optional. `nil` or an empty/whitespace string → treated as **not provided** (`parseNullableDecimal` returns `nil, nil`, `calc_handler.go:543-551`). A non-numeric non-empty string → `400 "<field> geçerli bir sayı olmalı"`.

### `domain.ComputeGeometry` validation rules — quoted verbatim (`internal/domain/calc.go:182-229`)

```go
func ComputeGeometry(in CalcInput) (CalcGeometry, error) {
	if in.Area != nil && !in.Area.IsPositive() {
		return CalcGeometry{}, fmt.Errorf("'area' 0'dan büyük olmalı")
	}
	if in.Width != nil && !in.Width.IsPositive() {
		return CalcGeometry{}, fmt.Errorf("'width' 0'dan büyük olmalı")
	}
	if in.Height != nil && !in.Height.IsPositive() {
		return CalcGeometry{}, fmt.Errorf("'height' 0'dan büyük olmalı")
	}
	if in.Perimeter != nil && !in.Perimeter.IsPositive() {
		return CalcGeometry{}, fmt.Errorf("'perimeter' 0'dan büyük olmalı")
	}
	haveWH := in.Width != nil && in.Height != nil

	var footprint decimal.Decimal
	switch {
	case in.Area != nil:
		footprint = *in.Area
	case haveWH:
		footprint = in.Width.Mul(*in.Height)
	default:
		return CalcGeometry{}, fmt.Errorf("alan bilgisi eksik: 'area' ya da 'width' + 'height' girin")
	}

	var perimeter *decimal.Decimal
	switch {
	case in.Perimeter != nil:
		p := *in.Perimeter
		perimeter = &p
	case haveWH:
		p := in.Width.Add(*in.Height).Mul(decimal.NewFromInt(2))
		perimeter = &p
	}

	effective := footprint
	if in.PitchDeg != nil {
		deg, _ := in.PitchDeg.Float64()
		if deg > 0 && deg < 90 {
			factor := math.Cos(deg * math.Pi / 180)
			if factor > 0 {
				effective = footprint.Div(decimal.NewFromFloat(factor))
			}
		}
	}
	return CalcGeometry{FootprintArea: footprint, EffectiveArea: effective, Perimeter: perimeter}, nil
}
```

Distilled rules for the mobile client:
1. **Any of `area/width/height/perimeter` that IS sent must be strictly `> 0`** (a pointer that is non-nil but `<= 0`, e.g. `"area": "0"` or `"area": "-5"`, is a **hard validation error**, not "treat as absent"). Errors returned verbatim: `'area' 0'dan büyük olmalı`, `'width' 0'dan büyük olmalı`, `'height' 0'dan büyük olmalı`, `'perimeter' 0'dan büyük olmalı`.
2. **Footprint area resolution**: `area` wins if present; else requires **both** `width` AND `height` (`haveWH`); if neither → `400 "alan bilgisi eksik: 'area' ya da 'width' + 'height' girin"`. So `category_id` + `area` alone is valid; `category_id` + `width` alone (no height) is **not** valid (falls to the "eksik" error, since `haveWH` is false and `area` is nil).
3. **Perimeter resolution is independent of area resolution**: explicit `perimeter` wins; else, **only if both `width` and `height` were given**, perimeter is derived as `2*(width+height)`; otherwise perimeter stays `nil` (not zero — `CalcGeometry.Perimeter` is `*decimal.Decimal`). Consequence: sending `area` alone (no width/height/perimeter) leaves `Perimeter == nil`, and any `perimeter_based` recipe item in that category will then produce the `perimeter_missing` warning (see below) with quantity `0` — this is a legitimate, non-error API response, not a failure.
4. **`pitch_deg`** only affects `effective_area`, never `footprint_area`/`perimeter`. It only applies when `0 < pitch_deg < 90` (inclusive bounds excluded); outside that range (including `pitch_deg <= 0`, `pitch_deg >= 90`, or omitted) `effective_area == footprint_area` unchanged, **silently, with no warning or error**. When applied: `effective_area = footprint_area / cos(pitch_deg° → rad)` — this is the **one deliberate float64 usage** in the whole calc engine (`domain/calc.go:26-30,219-224`; `deg, _ := in.PitchDeg.Float64()` then `math.Cos`), everything else is `decimal.Decimal`.
5. If `category_id` resolves but the category has **zero active recipe items**, `Run` returns `400 "bu kategori için malzeme reçetesi tanımlanmamış"` (`calc_service.go:486-488`) — not a `200` with an empty `items[]`.

### `ComputeRecipeQuantity` — per-item pipeline, order, and warnings (`internal/domain/calc.go:254-315`)

Order (per the code's own comment, `domain/calc.go:240-243`): **base amount → waste → minimum → package (replaces rounding) → rounding (only if no package)**.

1. **Base amount** by `calculation_type`:
   - `area_based`: `base = effective_area * quantity_per_m2`.
   - `perimeter_based`: if `geo.Perimeter == nil` → **warning `perimeter_missing`**, quantity forced to `decimal.Zero` for this item (the item still appears in `items[]` with `quantity: "0"`, it is not dropped); else `base = perimeter * quantity_per_meter`.
   - `fixed`: `base = fixed_quantity` (ignores geometry entirely).
   - anything else (should be impossible given DB `CHECK`): **warning `unknown_calculation_type`**, quantity `0`.
   Exact warning messages (`domain/calc.go:262-278`):
   ```go
   Code: "perimeter_missing",
   Message: fmt.Sprintf("%q çevre bazlı hesaplanıyor ama istekte çevre (perimeter) bilgisi yok; miktar 0 döndü.", item.MaterialName)
   ...
   Code: "unknown_calculation_type",
   Message: fmt.Sprintf("%q için tanınmayan calculation_type %q; miktar 0 döndü.", item.MaterialName, item.CalculationType)
   ```
2. **Waste**: if `waste_percent > 0`: `withWaste = base * (1 + waste_percent/100)`; else unchanged.
3. **Minimum**: if `min_quantity != nil AND min_quantity > withWaste`: result is clamped up to `min_quantity`.
4. **Package rule (replaces rounding, not combined with it)**: if `package_size != nil AND package_size > 0`: **final quantity = `ceil(round(withMin / package_size, 6))`** — i.e. package count, always rounded up, ignoring `rounding_type` entirely.
5. **Else, rounding by `rounding_type`** (only reached if no package_size):
   - `"ceil"` → `round(withMin, 6).Ceil()`
   - `"round"` → `round(withMin, 2)`
   - `"none"` (default) → `round(withMin, 6)` (display-precision only, matches the `numeric(14,6)` column precision, `recipeCoefficientPrecision = 6`).

### Product price resolution & the other two warning codes (`calc_service.go:521-574`)

For each recipe item, in order:
- If `item.ProductID == nil` → **warning `product_missing`**: `"%q bir ürüne bağlı değil; birim fiyat 0 kabul edildi."` (`calc_service.go:543-546`). `unit_price = 0`.
- Else if `item.ProductID` doesn't resolve in the batch product lookup (deleted product) → **warning `product_missing`**: `"%q için bağlı ürün bulunamadı (silinmiş olabilir); birim fiyat 0 kabul edildi."` (`calc_service.go:537-540`). `unit_price = 0`, `resolvedProductID` stays `nil` (so response `product_id` is omitted/null even though the recipe item itself had a `product_id` — it was just deleted).
- Else (`product_id` resolved) → `unit_price = products.unit_price`. If that resolved product's price is exactly `0` → **additional warning `product_zero_price`**: `"%q için ürün fiyatı 0 TL."` (`calc_service.go:548-552`), on top of a valid, non-null `product_id` in the item response.

So the four documented warning codes and their exact triggers are: **`perimeter_missing`** (perimeter-based item, no perimeter resolvable from request), **`unknown_calculation_type`** (defensive, DB CHECK should prevent it), **`product_missing`** (no product linked, or linked product row no longer exists), **`product_zero_price`** (product linked and found, but its `unit_price` is `0`). All warnings carry `item_id` = the recipe item's UUID (`CalcWarning.ItemID`, `json:"item_id,omitempty"`) — never empty in practice since every warning path sets `ItemID: item.ID`.

**Line total & grand total**: `line_total = round(quantity * unit_price, 2)` per item (`calc_service.go:555`), and `total_cost = round(Σ line_total, 2)` — i.e. the **sum of already-rounded line totals**, explicitly NOT `round(Σ raw quantity*price)` (this is a deliberate anti-drift design per the comment at `calc_service.go:556` and migration lines 17-19).

### Response — `calcRunResponse` (`calc_handler.go:454-460`, `422-460`)

```go
type calcRunResponse struct {
    Category  calcCategoryRefResponse  `json:"category"`
    Input     calcInputResponse        `json:"input"`
    Items     []calcResultItemResponse `json:"items"`
    TotalCost string                   `json:"total_cost"`
    Warnings  []calcWarningResponse    `json:"warnings"`
}

type calcCategoryRefResponse struct {
    ID   string `json:"id"`
    Slug string `json:"slug"`
    Name string `json:"name"`
}

type calcInputResponse struct {
    FootprintArea string  `json:"footprint_area"`
    EffectiveArea string  `json:"effective_area"`
    Perimeter     *string `json:"perimeter"`
}

type calcResultItemResponse struct {
    RecipeItemID string  `json:"recipe_item_id"`
    MaterialName string  `json:"material_name"`
    Unit         string  `json:"unit"`
    Quantity     string  `json:"quantity"`
    ProductID    *string `json:"product_id,omitempty"`
    UnitPrice    string  `json:"unit_price"`
    LineTotal    string  `json:"line_total"`
    GroupName    string  `json:"group_name,omitempty"`
    CalculationType string `json:"calculation_type"`
    Factor          string `json:"factor"`
    WastePercent    string `json:"waste_percent"`
    RoundingType    string `json:"rounding_type"`
}

type calcWarningResponse struct {
    ItemID  string `json:"item_id,omitempty"`
    Code    string `json:"code"`
    Message string `json:"message"`
}
```

Field-by-field notes:
- `input.perimeter` is `*string` and JSON `null` (not `"0"`) when geometry couldn't derive a perimeter (see rule 3 above) — this is the client's cue that any `perimeter_based` item's `quantity` of `"0"` in `items[]` is a real "missing input" case, cross-checkable against `warnings[].code == "perimeter_missing"`.
- `items[].factor` (`calc_handler.go:558-566` in service, then `.String()` in handler) is **whichever single coefficient was actually used** for that item's `calculation_type` — `quantity_per_meter` for `perimeter_based`, `fixed_quantity` for `fixed`, `quantity_per_m2` for everything else (including the defensive `unknown_calculation_type` fallback, which still reports `quantity_per_m2` as `factor` even though it wasn't used to compute anything, since `quantity=0` in that branch).
- `items[].group_name` is `omitempty` — an item with `group_name == ""` (DB default) is omitted from JSON entirely, not present as `""`.
- `items[].product_id` is `omitempty`/nullable per the product-resolution rules above.
- Order of `items[]` matches the recipe item order used to compute (`sort_order ASC, material_name ASC`, since `Run` iterates `ListCalcRecipeItems` results in that order, `queries/calc.sql:66-67`).

### CRITICAL — exact serialization proof, quoted from `calc_handler.go`

The package doc comment states the rule explicitly (`calc_handler.go:17-25`):
```go
// CalcHandler, Metraj Hesaplama modülünün HTTP katmanıdır.
//
// Miktar/tutar alanları burada BİLİNÇLİ olarak JSON STRING olarak
// taşınır (ör. "quantity": "100", "total_cost": "43100.00") -- diğer
// ARVEND uçlarının aksine (ör. products.unit_price bir JSON number'dır).
```
And the actual encode calls, verbatim:
```go
// calc_handler.go:510-519 (Run)
items[i] = calcResultItemResponse{
    RecipeItemID: it.RecipeItemID, MaterialName: it.MaterialName, Unit: it.Unit,
    Quantity: it.Quantity.String(), ProductID: it.ProductID, UnitPrice: it.UnitPrice.StringFixed(2),
    LineTotal: it.LineTotal.StringFixed(2), GroupName: it.GroupName,
    CalculationType: it.CalculationType, Factor: it.Factor.String(),
    WastePercent: it.WastePercent.String(), RoundingType: it.RoundingType,
}
...
httpjson.Write(w, http.StatusOK, calcRunResponse{
    ...
    Input: calcInputResponse{
        FootprintArea: result.Geometry.FootprintArea.String(),
        EffectiveArea: result.Geometry.EffectiveArea.String(),
        Perimeter:     perimeterStr,   // *string via .String(), or nil
    },
    Items: items, TotalCost: result.TotalCost.StringFixed(2), Warnings: warnings,
})
```
and for the recipe-item CRUD responses (`calc_handler.go:265-273`):
```go
func toCalcRecipeItemResponse(i domain.CalcRecipeItem) calcRecipeItemResponse {
    return calcRecipeItemResponse{
        ID: i.ID, CategoryID: i.CategoryID, ProductID: i.ProductID, MaterialName: i.MaterialName, Unit: i.Unit,
        CalculationType: i.CalculationType, QuantityPerM2: i.QuantityPerM2.String(), QuantityPerMeter: i.QuantityPerMeter.String(),
        FixedQuantity: i.FixedQuantity.String(), WastePercent: i.WastePercent.String(), RoundingType: i.RoundingType,
        MinQuantity: decimalPtrToStringPtr(i.MinQuantity), PackageSize: decimalPtrToStringPtr(i.PackageSize),
        ReferenceUnitPrice: i.ReferenceUnitPrice.String(), GroupName: i.GroupName, SortOrder: i.SortOrder,
        IsActive: i.IsActive, Notes: i.Notes,
    }
}
```

**Exhaustive list of every JSON-string-typed numeric field in this module**, and which `decimal` method produced it (matters because `.String()` and `.StringFixed(2)` format differently — `.String()` preserves the value's natural scale, e.g. a `quantity_per_m2` of `0.166667` prints all 6 decimals or fewer if trailing zeros, whereas `.StringFixed(2)` always pads/truncates to exactly 2 decimals):
| Field | Endpoint(s) | Method |
|---|---|---|
| `quantity_per_m2`, `quantity_per_meter`, `fixed_quantity`, `waste_percent`, `reference_unit_price`, `min_quantity`, `package_size` | recipe-item response (GET/POST/PUT) | `.String()` |
| `footprint_area`, `effective_area`, `perimeter` | run response `input` | `.String()` |
| `quantity`, `factor`, `waste_percent` (on run items) | run response `items[]` | `.String()` |
| `unit_price`, `line_total` (on run items) | run response `items[]` | `.StringFixed(2)` |
| `total_cost` | run response | `.StringFixed(2)` |

**Every single numeric field under `/api/v1/calculations/*` is a JSON string.** There is no numeric field on this module's wire format that is a JSON number — the exception called out in the code comment is real and total. This is the opposite convention from `products.unit_price` (`product_handler.go:28,73`, plain `float64` JSON number) and from `offers`/`offer-revisions` (`offer_handler.go:30-32,55-58,269-272`: `Quantity`, `UnitPrice`, `LineTotal`, `Subtotal`, `VatAmount`, `GrandTotal` are all plain `float64` JSON numbers) — **a client parsing this API cannot use one shared decimal-parsing codepath for calculations vs. offers/products; it must branch by endpoint.**

Request-side numeric fields (recipe-item upsert body, run body) are also always plain JSON strings (`*string` or `string`), confirmed above — symmetric with the response convention.

---

## 5. How a calculation result becomes an offer item — cross-reference with the offers contract

There is **no dedicated "convert calculation to offer" endpoint**. The only integration point is that `POST /api/v1/offers/` and `PUT /api/v1/offers/{id}` accept optional calc-provenance fields on each line item, which the mobile client is responsible for populating itself from a prior `POST /calculations/run` response. Verified in `offer_handler.go:137-149`:

```go
type createOfferItemRequest struct {
    ProductID   *string `json:"product_id"`
    ProductName string  `json:"product_name"`
    Quantity    float64 `json:"quantity"`
    UnitPrice   float64 `json:"unit_price"`

    // Metraj Hesaplama entegrasyonu (Faz M2) -- "Teklife Ekle" bu dört
    // alanı da gönderir; serbest kalemlerde hepsi boş/nil bırakılır.
    Unit           string          `json:"unit"`
    SectionLabel   *string         `json:"section_label"`
    CalcCategoryID *string         `json:"calc_category_id"`
    CalcSnapshot   json.RawMessage `json:"calc_snapshot"`
}
```

Key facts, verified:
1. **`quantity` and `unit_price` on the offer item are plain JSON numbers (`float64`)** — NOT the JSON-string convention of `/calculations/*`. The client must convert the calc-run string values (`items[].quantity`, `items[].unit_price`) to numbers before submitting them as an offer item. `computeOfferTotals` (`offer_service.go:136-159`) recomputes `line_total = round2(quantity * unit_price)` server-side and **silently drops any item where `quantity <= 0` or `unit_price < 0` or `product_name` is blank** (`offer_service.go:145-146`) — it does not error per-item, it just excludes it; if *all* items get excluded this way, the whole create/update call fails with `400 "geçerli en az bir kalem girilmelidir"` (`offer_service.go:153`).
2. **`calc_snapshot` is `json.RawMessage`** — the backend does **not parse, validate, or type-check its contents at all**. It is stored as-is into a `jsonb` column (`offer_revision_items.calc_snapshot`, migration `0029...up.sql:21`) and returned as-is (`offerItemResponse.CalcSnapshot json.RawMessage`, `offer_handler.go:41`). **There is no Go struct anywhere in the backend defining the expected shape of `calc_snapshot`** — it is fully client-defined opaque JSON. The *only* documentation of an intended shape is a code comment, not an enforced schema (`domain/offer.go:43-49`, quoted verbatim):
   ```go
   // Unit/SectionLabel/CalcCategoryID/CalcSnapshot: Metraj Hesaplama
   // entegrasyonu (Faz M2). Serbest/elle girilen kalemlerde Unit boş,
   // diğerleri nil'dir. CalcSnapshot, hesap ANINDAKİ dondurulmuş
   // görünümdür (area/perimeter/pitch_deg/factor/waste/rounding/
   // price_at_calc) -- kategori/reçete sonradan değişse/silinse bile
   // bu kalem üzerinde HİÇBİR ZAMAN güncellenmez
   ```
   In practice, for a Flutter client to stay consistent with itself and with the intent above, `calc_snapshot` should be a JSON object echoing the relevant per-item fields from the `POST /calculations/run` response — a natural, code-consistent shape is (client-invented, not backend-enforced):
   ```json
   {
     "area": "...", "perimeter": "...", "pitch_deg": "...",
     "factor": "...", "waste_percent": "...", "rounding_type": "...",
     "price_at_calc": "...", "calculation_type": "...", "recipe_item_id": "..."
   }
   ```
   but the backend will accept **any** valid JSON value here (object, array, string, number, or `null`/omitted) without complaint — this is **NOT SUPPORTED as a validated contract**, only as free-form pass-through storage.
3. **`calc_category_id` is separately, actually validated** (unlike `calc_snapshot`): it must parse as a UUID and resolve to a `calc_categories` row in the caller's own organization, else it is **silently dropped to `NULL`** — no error is raised (`offer_service.go:197-204`, "başka bir organizasyonun kategori id'si sessizce NULL'a düşer" — same silent-drop convention as an invalid `product_id`). So a client should not assume a round-trip: POST a `calc_category_id`, then GET the offer back — if the category didn't belong to the org, the field will simply be absent/null, no 400 was ever returned.
4. **`unit`** is a required-looking but actually optional plain string (`varchar(30) NOT NULL DEFAULT ''`, migration line 15); free-typed offer items leave it `""`, which the response `omitempty`'s away (`offerItemResponse.Unit string \`json:"unit,omitempty"\``, `offer_handler.go:38`).
5. **`section_label`** is `*string`, purely a client-supplied grouping label with no relation to any calc data — nullable, `omitempty` in responses.
6. Immutability: `Revise` (`POST /offers/{id}/revise`) clones **all four** calc fields byte-for-byte into the new revision via `cloneRevisionItems` (`offer_service.go:235-256`) — a revised offer's calc-derived line items never re-run the calculation or re-fetch current product prices; the frozen `calc_snapshot`/quantity/unit_price persist forever, confirmed by the explicit test `TestOfferItems_CalcSnapshot` (`internal/service/offer_calc_snapshot_test.go:104-133`, "Revize Et calc_snapshot'ı MUTASYONSUZ (birebir) klonlar").

For completeness, the full offer-item response shape a mobile client will read back (`offer_handler.go:26-42`):
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
(`POST/PUT/GET/Revise /offers/*`, `offer_handler.go` route handlers at `router.go:119-143`, all under `requireAuth` only, no admin requirement — "teklif oluşturma sıradan personel işidir", `router.go:121-122`).

---

## Summary of things NOT SUPPORTED (explicitly verified absent)

- **NOT SUPPORTED** — a dedicated "active-only" `GET` recipe-items endpoint. Only one route exists (`GET /calculations/recipe-items`), and it always returns active+inactive items via the admin query, regardless of caller role.
- **NOT SUPPORTED** — pagination, sorting params, or free-text search on any `/calculations/*` GET endpoint (no `page`/`limit`/`q` params read anywhere in `calc_handler.go`, unlike e.g. `offers.List` which does read `page`/`limit`/`filter`, `offer_handler.go:111-113`).
- **NOT SUPPORTED** — any server-side schema/validation for `offer` items' `calc_snapshot` field; it is opaque pass-through JSON.
- **NOT SUPPORTED** — soft-delete/deactivate for recipe items via the delete endpoint; `DELETE /calculations/recipe-items/{id}` is a hard SQL `DELETE`.
- **NOT SUPPORTED** — Bearer-token auth; only httpOnly cookies (`access_token`/`refresh_token`) are accepted anywhere in this router.
- **NOT SUPPORTED** — a direct "calculate and create offer in one call" endpoint; the two are always two separate HTTP round-trips (`POST /calculations/run` then `POST /offers/`), stitched together only by the client.
- **NOT SUPPORTED** — an image/file GET endpoint for `calc_categories.image_file_id`; the column has no FK and no serving route exists in `router.go`.