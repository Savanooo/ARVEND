Confirmed: `settingsSvc` is used only for SMTP settings (email sending), not for anything offer-number related. This closes the investigation.

## (A) Offer numbering mechanism

**Function** (`internal/service/offer_service.go:369-376`), quoted in full:
```go
func (s *OfferService) generateOfferNo(ctx context.Context, orgID pgtype.UUID) (string, error) {
	year := time.Now().Year()
	seq, err := s.q.NextOfferSeq(ctx, sqlc.NextOfferSeqParams{OrganizationID: orgID, Year: int32(year)})
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("TKF-%d-%04d", year, seq), nil
}
```
Called once from `Create()` at line 271, before the transaction begins (the number is minted, then used inside the tx to insert the offer row).

**The `"TKF-%d-%04d"` format string is hardcoded in Go.** There is no DB or config value for the prefix anywhere — a full grep for `prefix` across `internal/` and `db/` (Go and SQL) returned zero matches. `SettingsService` is injected into `OfferService` but is used only for SMTP settings (`s.settingsSvc.GetSmtp`, line 1374), never for offer numbering. **There is no per-organization customization point today** — "TKF" is the same literal for every organization.

**Underlying counter table** — `offer_counters`, created in `db/migrations/0004_create_offers.up.sql` as `(year int PRIMARY KEY, seq int)`, then altered in two later migrations:
- `0013_scope_offer_counters_by_organization.up.sql`: adds `organization_id uuid REFERENCES organizations(id)`, backfills existing rows to org `00000000-0000-0000-0000-000000000001` (this is "Arvend Yapı"), drops the old PK and re-adds PK as `(organization_id, year)`.
- `0014_scope_offer_no_uniqueness_by_organization.up.sql`: drops the old global `UNIQUE(offer_no)` on `offers` and replaces it with `UNIQUE(organization_id, offer_no)`.

The atomic increment query (`internal/repository/queries/offers.sql`, `NextOfferSeq`):
```sql
INSERT INTO offer_counters (organization_id, year, seq) VALUES ($1, $2, 1)
ON CONFLICT (organization_id, year) DO UPDATE SET seq = offer_counters.seq + 1
RETURNING seq;
```
So the counter is already fully keyed by `(organization_id, year)` — one independent sequence per org per year, upsert-on-conflict, race-safe via Postgres's own atomic `ON CONFLICT ... DO UPDATE`.

**Implication for an `offer_prefix` setting:** it is safe to add in the sense that the counter table is already partitioned by `organization_id`, so touching prefix logic cannot corrupt another org's sequence, and it wouldn't touch `offer_counters` at all — only the `fmt.Sprintf` in `generateOfferNo` needs the literal `"TKF"` replaced with a value looked up per `orgID` (e.g. via `settingsSvc` or a new organizations column). Arvend Yapı's already-issued `TKF-2026-XXXX` numbers are untouched by this because: (1) they're just stored strings in `offers.offer_no`, not regenerated, and (2) the counter row keyed `(org=00000000-...-000000000001, year=2026)` keeps incrementing from wherever `seq` currently sits, regardless of what prefix future calls use. The one thing to get right: whatever new mechanism is added must default Arvend Yapı's prefix to `"TKF"` explicitly (e.g. via a seed/migration default), otherwise a naive "new setting defaults to empty/organization name" would change the format of Arvend Yapı's *next* offer number even though nothing here corrupts the counter itself.

## (B) Calc catalog importer (`cmd/import-calc-recipes/main.go`)

**Invocation** (documented in the file's own header comment, lines 26-31):
```
DB_URL="postgres://.../arvend_dev" go run ./cmd/import-calc-recipes \
  --fixture db/fixtures/byz_calc_recipes.json \
  --org 00000000-0000-0000-0000-000000000001 \
  [--link-products]
```
Flags (all defined via `flag` package in `main()`, lines 87-90):
- `--fixture` (string, default `"db/fixtures/byz_calc_recipes.json"`) — path to the fixture JSON.
- `--org` (string, **required**, no default — exits with usage message if empty) — target organization UUID.
- `--link-products` (bool, default `false`) — if set, recipe items get matched/created against `products` by `(normalized_name, unit)`; if unset, every item is inserted with `product_id = NULL`.

It also reads `DB_URL` from the environment directly (not a flag) and fatals if unset.

**Fixture shape** (`db/fixtures/byz_calc_recipes.json`, 265,842 bytes): top-level object with exactly three keys — `groups` (16 items, each `{slug, name, description, sort_order}`), `categories` (95 items, each `{slug, name, description, group_slug, sort_order, image}`), `recipe_items` (814 items, each `{category_slug, material_name, unit, quantity_per_m2, reference_unit_price, group_name, sort_order, rounding_type}`) — matching the 16-group/95-category/814-item description exactly.

**What "idempotent" means precisely, per entity:**
- Groups: existence check is `GetCalcGroupBySlug(organization_id, slug)` (`internal/repository/queries/calc.sql:12-13`) — skip-and-reuse-ID if found (`existing.ID`), else `calcSvc.CreateGroup`.
- Categories: same pattern, `GetCalcCategoryBySlug(organization_id, slug)`.
- Recipe items: existence check is **`(category_id, organization_id, material_name, unit)`**, not slug — `GetCalcRecipeItemByCategoryMaterialUnit` (`internal/repository/queries/calc.sql:79-81`): `WHERE category_id=$1 AND organization_id=$2 AND material_name=$3 AND unit=$4`.

So per the task's framing: groups/categories key on `(organization_id, slug)`; recipe items key on `(organization_id, category_id, material_name, unit)` — a different, more granular tuple than groups/categories, because recipe items have no slug of their own. In every case a hit means **skip, never overwrite** (comment at file top, lines 12-16, states this explicitly as the deliberate inverse of BYZ's seed-on-every-boot overwrite behavior). Orphaned categories (unrecognized `group_slug`) and orphaned recipe items (unrecognized `category_slug`) are logged and skipped, not fatal.

**Callable as a library function from Go app code (e.g. for automatic new-org provisioning)?** Not as-is — it needs a small, mechanical refactor, not a redesign:
- All the actual logic (the three loops with skip-if-exists checks) lives inline inside `func main()` (lines 132-266), not in any exported function. Nothing is currently importable.
- `main()` does its own infra setup that a library call shouldn't repeat: reads `DB_URL` from env and calls `repository.NewPool` itself (lines 106-115), constructs `sqlc.New(pool)`, `service.NewCalcService(q)`, `service.NewProductService(q)` itself (lines 117-119), and `os.ReadFile`s the fixture path itself (line 97) instead of accepting an already-parsed fixture or an embedded one.
- It calls `os.Exit(1)` / `log.Fatalf` on every error path (used ~8 times) instead of returning an `error` — fatal in a CLI, but would crash the whole server process if reused verbatim inside request-handling code.
- The `fixture`/`fixtureGroup`/`fixtureCategory`/`fixtureRecipeItem` structs and the `mustUUID`/`decimalFromFloat` helpers are unexported (lowercase), so nothing outside `package main` in `cmd/import-calc-recipes` can reference them today.

What it does **not** need changed: the underlying calls are already the right shape for reuse — `calcSvc.CreateGroup(ctx, orgID string, in CalcGroupInput)`, `calcSvc.CreateCategory(ctx, orgID string, in CalcCategoryInput)`, `calcSvc.CreateRecipeItem(ctx, orgID string, in CalcRecipeItemInput)` (`internal/service/calc_service.go:69,185,334`) and `productSvc.Create(ctx, orgID, name, unit, unitPrice, description, category)` / `productSvc.List(...)` (`internal/service/product_service.go:80,28`) all take a plain `context.Context` and a `*sqlc.Queries`-backed service already constructed the normal app way — these are the exact same services the HTTP handlers use, so calling them from a new-org-onboarding code path is architecturally identical to what a request handler already does. No transaction wraps the three loops (each `CreateGroup`/`CreateCategory`/`CreateRecipeItem` is its own independent write), so a mid-run failure just leaves a partial, safely-resumable state — consistent with its skip-if-exists idempotency, and fine to call again.

**Bottom line:** to call this from application code for automatic provisioning, extract lines ~132-266 into an exported function such as `func ImportCalcRecipes(ctx context.Context, calcSvc *CalcService, productSvc *ProductService, q *sqlc.Queries, orgID string, fx Fixture, linkProducts bool) (Result, error)` (or similar; `Fixture` types would need to be exported or moved to a shared package, likely `internal/service` or a new `internal/calccatalog`), replacing every `log.Fatalf`/`os.Exit` with a returned `error`, and either embedding the fixture JSON (`go:embed`) or passing it in already-parsed rather than reading a file path. That's straightforward mechanical work — nothing about the current design (idempotency keys, no-overwrite semantics, per-org scoping via `organization_id` on every query) would need to change, and it fits the onboarding flow's needs directly since the skip-if-exists guarantee means it's safe to call unconditionally on every new-org creation.