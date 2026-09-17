## Summary of findings

### 1. Three layouts already share one shell (confirmed current state)

`app/(admin)/layout.tsx`, `app/(app)/layout.tsx`, `app/(panel)/layout.tsx` are now thin wrappers — the earlier gateway-audit refactor already landed. Each does: `getCurrentUser()` → redirect to `/giris` if null → (admin-only) redirect to `/panel` if `user.role !== "admin"` → render `<AppShell user={user}>{children}</AppShell>`. All auth/role logic lives only in the layout; `AppShell` (`components/layout/AppShell.tsx`) is purely presentational — reads the `SIDEBAR_COLLAPSED_COOKIE`, then renders `ToastProvider > Sidebar + (Topbar + main)`, with `items={getNavItems(user.role)}`.

**Pattern for a new `/super-admin` section**: add `app/(super-admin)/layout.tsx` following the exact same shape, e.g. `if (user.role !== "super_admin") redirect(...)`, then `<AppShell user={user}>{children}</AppShell>`. No new shell component needed.

### 2. `lib/auth.ts` — `getCurrentUser()`
Server-only. Reads cookies via `next/headers`, returns `null` immediately if no cookie header. Calls `apiServer<User>("/api/v1/auth/me", cookieHeader)`; on `ApiError` with status 401/403 returns `null`, otherwise rethrows. Layouts then decide redirect target.

### 3. `lib/api.ts` — confirmed current state matches expectations
- `API_BASE = process.env.NEXT_PUBLIC_API_URL ?? "http://localhost:8080"` (client-safe, public).
- `internalApiBase() = process.env.INTERNAL_API_URL || API_BASE` (server-only, used only inside `apiServer`).
- `apiClient<T>(path, options)` — browser-only, uses `fetchWithSession` (single-flight refresh-on-401, redirects to `/giris` via `window.location.assign` on unauthorized), sends `credentials: "include"`.
- `apiServer<T>(path, cookieHeader, options)` — server-only, calls `internalApiBase()${path}`, forwards `Cookie: cookieHeader`, `cache: "no-store"`, does **not** attempt refresh (documented rationale: RSC can't write Set-Cookie).
- Both funnel through `parse<T>()` which throws `ApiError(status, message)` on non-2xx (message from `body.error`).

This is exactly what's needed for onboarding-redirect logic: any new gate should follow the same `getCurrentUser()` → `ApiError` 401/403 → `null` pattern, and use `apiServer` in layouts/server components, `apiClient` in client forms.

### 4. `proxy.ts` — Next 16 middleware replacement
Fast, non-authoritative pre-check only (comment explicitly says JWT signature is NOT verified here, real enforcement is backend `RequireRole`). Reads `access_token` cookie, decodes only the `role` claim (base64url JSON parse, no verification). If no token → redirect `/giris`. If `pathname.startsWith("/admin")` and `role !== "admin"` → redirect `/panel`. `matcher: ["/admin/:path*", "/panel/:path*"]`.

**Note for a new `/super-admin` section**: `proxy.ts`'s `matcher` currently only covers `/admin/:path*` and `/panel/:path*` — a `/super-admin` route segment would need its own matcher entry and its own role-check branch (and the `AccessClaims.role` union type, currently `"admin" | "kullanici"`, would need extending) for the UX pre-redirect to work there too. Currently it would fall through with no proxy-level protection (still safe since real enforcement is in the layout + backend, but UX redirect wouldn't fire).

### 5. `lib/nav.ts` + `components/layout/NavLinks.tsx` — nav pattern
`getNavItems(role: Role): NavItem[]` is the single source of truth, keyed by role, returns `{href, label}[]`. Icons are deliberately kept OUT of `nav.ts` and instead mapped by href string in `NavLinks.tsx`'s client-side `ICONS: Record<string, LucideIcon>` — explicit reasoning given: raw lucide component references can't cross the Server→Client Component boundary as props from `nav.ts` (a Server Component context) into the "use client" `NavLinks`. Active-link detection: `pathname === item.href || pathname.startsWith(`${item.href}/`)`.

**Pattern for `/super-admin` nav**: add a role branch in `getNavItems` (`Role` type in `lib/types.ts` is currently `"admin" | "kullanici"` — would need a new role value added there first), and add corresponding `href → Icon` entries in `NavLinks.tsx`'s `ICONS` map.

### 6. Admin CRUD reference pattern — `/admin/urunler` (products)
- **List** (`page.tsx`, Server Component): `cookies()` → `apiServer<{products, total}>` fetch → renders `PageHeader` (title + action button linking to `/admin/urunler/yeni`) → `Card > Table > thead/Th, tbody > Tr > Td` with a "Düzenle" text-link per row, empty-state row when `.length === 0`.
- **Create** (`yeni/page.tsx`, Client Component, `"use client"`): local `useState` form object, `handleSubmit` does `apiClient<Product>("/api/v1/products", {method:"POST", body: JSON.stringify(form)})`, then `router.push(...)` + `router.refresh()`; errors caught as `ApiError` shown inline (`text-danger`); wrapped in `Card > CardBody > form` using `Input` components with `label` props.
- **Edit** (`[id]/page.tsx` server + `[id]/EditProductForm.tsx` client): detail page fetches via `apiServer` (parallel `Promise.all` for product + price history) and passes down as props; the form component does `apiClient(path, {method:"PUT", ...})`, shows inline success/error message, `router.refresh()` on success (no navigation away, unlike create).

Exact component usage: `Card`, `CardBody`, `CardHeader`, `Table`/`Th`/`Td`/`Tr`, `Button`, `Input`, `PageHeader` (from `@/components/layout/PageHeader`, not `ui`). No `Modal`/`Textarea` used in this particular screen (product form uses plain `Input` for description, not `Textarea`).

### 7. `/admin/kullanicilar` (users) — closest precedent for "create a user with a role"

Exact POST body shape to `/api/v1/users` (from `yeni/page.tsx`):
```ts
{
  username: string,
  password: string,
  full_name: string,
  role: Role,          // "kullanici" (default) | "admin"
}
```
Role picker is a plain native `<select>` (not the `Select` ui component) with hardcoded `<option>`s, styled inline: `className="rounded-md border border-border bg-surface px-3 py-2 text-sm text-text outline-none focus:border-gold"`. Password field: `Input` with `type="password"`, `minLength={8}`.

Edit form (`EditUserForm.tsx`) splits into two independent `Card`s/forms: one PUTs `{full_name, role, is_active}` to `/api/v1/users/:id`, another PATCHes `{new_password}` to `/api/v1/users/:id/password`. Active toggle is a raw `<input type="checkbox" className="accent-gold">`, not a ui component.

**For super-admin user creation**: this is the direct template — POST to `/api/v1/users` (or whatever new endpoint) with `{username, password, full_name, role}`, role value would need to include whatever new role string the backend defines for super-admin-created accounts.

### 8. `components/ui/` — full file list
```
Accordion.tsx
Badge.tsx
Button.tsx
Card.tsx
ConfirmDialog.tsx
DateInput.tsx
DropdownMenu.tsx
EmptyState.tsx
IconButton.tsx
Input.tsx
Modal.tsx
Pagination.tsx
SearchInput.tsx
Select.tsx
Skeleton.tsx
StatusBadge.tsx
Table.tsx
Tabs.tsx
Textarea.tsx
Toast.tsx
```

### 9. `Modal.tsx` — full props signature (quoted verbatim)

```tsx
export function Modal({
  open,
  onClose,
  title,
  children,
  footer,
  widthClassName = "max-w-md",
}: {
  open: boolean;
  onClose: () => void;
  title?: string;
  children: React.ReactNode;
  footer?: React.ReactNode;
  // Mevcut tüm kullanım yerleri bunu vermediği için max-w-md korunur;
  // Metraj Hesapla gibi tablo içeren geniş paneller için override edilir.
  widthClassName?: string;
})
```

Implementation notes relevant to reuse: built on native `<dialog>` + `showModal()` (browser-native focus trap/backdrop/ESC, no extra dependency). `useEffect` syncs `open` to `dialog.showModal()`/`dialog.close()`. Backdrop click detected via `e.target === ref.current` (since `::backdrop` isn't a real DOM node) and calls `onClose`. Structure rendered: header row (`title` + close `X` icon button, `aria-label="Kapat"`) → scrollable body (`max-h-[75vh] overflow-y-auto`, children) → optional `footer` row (right-aligned, `flex justify-end gap-2`) only rendered if `footer` is truthy.

### Files read (absolute paths)
- `/Users/tahaeryetisozen/Documents/GitHub/x-api/ARVEND/frontend/app/(admin)/layout.tsx`
- `/Users/tahaeryetisozen/Documents/GitHub/x-api/ARVEND/frontend/app/(app)/layout.tsx`
- `/Users/tahaeryetisozen/Documents/GitHub/x-api/ARVEND/frontend/app/(panel)/layout.tsx`
- `/Users/tahaeryetisozen/Documents/GitHub/x-api/ARVEND/frontend/components/layout/AppShell.tsx`
- `/Users/tahaeryetisozen/Documents/GitHub/x-api/ARVEND/frontend/lib/auth.ts`
- `/Users/tahaeryetisozen/Documents/GitHub/x-api/ARVEND/frontend/lib/api.ts`
- `/Users/tahaeryetisozen/Documents/GitHub/x-api/ARVEND/frontend/proxy.ts`
- `/Users/tahaeryetisozen/Documents/GitHub/x-api/ARVEND/frontend/lib/nav.ts`
- `/Users/tahaeryetisozen/Documents/GitHub/x-api/ARVEND/frontend/components/layout/NavLinks.tsx`
- `/Users/tahaeryetisozen/Documents/GitHub/x-api/ARVEND/frontend/lib/types.ts`
- `/Users/tahaeryetisozen/Documents/GitHub/x-api/ARVEND/frontend/app/(admin)/admin/urunler/page.tsx`
- `/Users/tahaeryetisozen/Documents/GitHub/x-api/ARVEND/frontend/app/(admin)/admin/urunler/yeni/page.tsx`
- `/Users/tahaeryetisozen/Documents/GitHub/x-api/ARVEND/frontend/app/(admin)/admin/urunler/[id]/EditProductForm.tsx`
- `/Users/tahaeryetisozen/Documents/GitHub/x-api/ARVEND/frontend/app/(admin)/admin/urunler/[id]/page.tsx`
- `/Users/tahaeryetisozen/Documents/GitHub/x-api/ARVEND/frontend/app/(admin)/admin/kullanicilar/page.tsx`
- `/Users/tahaeryetisozen/Documents/GitHub/x-api/ARVEND/frontend/app/(admin)/admin/kullanicilar/yeni/page.tsx`
- `/Users/tahaeryetisozen/Documents/GitHub/x-api/ARVEND/frontend/app/(admin)/admin/kullanicilar/[id]/EditUserForm.tsx`
- `/Users/tahaeryetisozen/Documents/GitHub/x-api/ARVEND/frontend/app/(admin)/admin/kullanicilar/[id]/page.tsx`
- `/Users/tahaeryetisozen/Documents/GitHub/x-api/ARVEND/frontend/components/ui/Modal.tsx`