# ARVEND Home Dashboard ("Ana Sayfa"): final implementation spec (v1)

Status: implemented on 2026-09-28 (backend `GET /api/v1/dashboard`, web `components/dashboard/`, mobile `lib/features/dashboard/`). Code comments cite this file as "spec §…" / "spec D…". Where the implementation deviates, the code and `docs/dashboard/fixtures/*.json` are authoritative.

What the owner asked for: "birde ana sayfada bölüm bölüm özet olsun, dashboard gibi, her bölümden özet" (a home page like a dashboard, with a summary from every section).

Base: this spec builds on the winning direction (A, "Yönetici Nabzı": KPI first, with one summary card per module). It adds ideas taken from the other two directions, B ("Gündem") and C ("Portföy Masası"), and fixes every problem the judges raised. Appendix Z maps each problem to its fix.

This spec is binding for three engineers: backend (Go), web (Next.js 16) and mobile (Flutter). Where a platform detail is not stated, follow the other platform. The shared contract lives in §4 (JSON) and §7 (Turkish copy).

---

## 0. Binding decisions (read first)

| # | Decision |
|---|---|
| D1 | **One endpoint** feeds both platforms: `GET /api/v1/dashboard`. It uses one RepeatableRead read-only snapshot. Each section runs inside its own SAVEPOINT, so one failing section does not break the rest. Clients never sum money and never recompute totals: they only format numbers and draw proportions. |
| D2 | **The server decides visibility.** A section key missing from `sections` means "no permission" and the card is not rendered: no locked teaser, no zeros. A permission-gated **field inside** a visible section is `null`, and clients hide that sub-block. Clients check permissions only for (a) quick-action buttons and (b) predicting which skeleton to draw. |
| D3 | **Links use neutral `ref` objects** `{kind,id,project_id,parent_id,action}`. The server never sends web or mobile paths. Two pure functions map a ref to a route: web `webHrefFor(ref)` and mobile `mobileRouteFor(ref)`, both unit-tested. On mobile, rows open the exact record screen (talep, RFQ, sipariş, hakediş, değişiklik emri, görev). |
| D4 | **Deep-link query parameters:** web `/projeler/{id}?tab=genel\|finans\|maliyet\|satinalma\|operasyon\|dosyalar\|aktivite`; mobile `/projeler/:id?grup=ozet\|finans\|operasyon\|dokumanlar&alt=<sub-view>`. The names are English-style, like the existing `status`, `q` and `period`. |
| D5 | **Compact money has one rule on both platforms.** Below 1.000.000 → full integer with grouping ("850.000 TL"). 1.000.000 and above → one decimal plus "Mn" ("12,5 Mn TL"; a trailing ",0" is dropped, so "12 Mn TL"). 1.000.000.000 and above → "Mr" ("1,2 Mr TL"). **"B" / "Bin" is never used.** Chart axis labels follow the same rule without the currency suffix. Rows, breakdowns, tooltips and `aria-label`s always use the full value (`formatMoney`, 2 decimals). |
| D6 | **The greeting stays "Merhaba, {ad}"**, with no time-of-day logic. This needs no clock, gives no server/UTC mistakes, and keeps the existing mobile tests stable. The date comes from the server's Istanbul `today` (mobile) or from `Intl`/`DateFormat` with an explicit `Europe/Istanbul` zone (web header). The device or server-local clock is never used. |
| D7 | **Colour:** no new hues. Web adds only alias tokens (`--color-chart-in`, `--color-chart-out`, `--color-track`).<br>• **Tahsilat / collected money = success (green) everywhere.** This covers the KPI bar, finance card, project rows and cash chart.<br>• **Gold = task/work progress, brand, primary CTA, and the "action" severity (web).**<br>• Graphite = neutral data (elapsed time, outflows). Danger = only for real overdue / over-budget / failed states.<br>• "Upcoming" is neutral text plus a `CalendarClock` icon on web, and `AppStatusColors.warning` on mobile.<br>• Mobile gold is never a status colour, so mobile "action" uses `warning`. |
| D8 | **No chart library.** There are three primitives: ProgressBar, SegmentBar and PairedBars. The only time series is the 6-month cash chart. There are no sparklines, no donuts and no "vs last month" deltas. |
| D9 | **Web loading uses in-page `<Suspense>`, never `loading.tsx`.** `DashboardBody` catches everything and never throws, because of the HANDOFF §7 caveat. `getCurrentUser` is wrapped in React `cache()`. |
| D10 | **"Dikkat Gerektirenler" has three lanes:** **Senin sıran** (items you can act on, or your own overdue tasks), **Takipte** (waiting on someone else or on the customer), and **Yaklaşan · 14 gün** (dated list).<br>• Operational flags you cannot act on are **hidden** from Dikkat; their numbers still appear on the module card.<br>• Info-only facts (offer viewed, price increases, never-logged-in users, stale sync) are **card notes only**, never Dikkat rows. |
| D11 | **De-duplication rule:** each attention fact appears in at most two places: its Dikkat row and its module card footer. KPI sub-lines show only neutral breakdown numbers, never attention sentences. The summary sentence shows only lane counts. |
| D12 | **Offer decision dates come from `offer_events`.** This fixes C's wrong "no decision timestamp" claim. Customer decisions use `customer_accepted` / `customer_rejected`. Internal decisions use `offer_updated`, and `UpdateStatus` now writes `{"from_status","to_status"}` metadata. `offers.updated_at` is never used. Archived offers (`is_passive=true`) are excluded everywhere. |
| D13 | **Primary currency** comes from `organization_commercial_settings.default_currency`. Every `by_currency` array is sorted by the server with the primary currency first, then by main amount descending. Clients use `[0]` and show the other currencies as a "Diğer: …" line. Amounts are never summed across currencies. |
| D14 | **No payroll or salary figures anywhere on the home page**, even for the owner. **No markups or supplier prices.** |
| D15 | **Attendance is organisation-wide**, and every attendance tile says "Firma geneli". |
| D16 | **Project pickers must not use `GET /projects`**, which leaks money. They use the new slim `GET /api/v1/dashboard/project-options`. |
| D17 | **No margin KPI.** On unfinished projects, "(contract value − cost to date) / value" overstates profit. The KPI is instead **PROJE NAKİT DENGESİ** = collected − realized cost, a real cash figure. |
| D18 | **Task completion % is labelled "Görev %" (unweighted task count).** It is never compared to budget and never produces a money flag. There is no "behind schedule" flag. |
| D19 | **UI copy uses the informal "sen" form** throughout, matching the existing app texts. |
| D20 | **The Europe/Istanbul day is the only "today".** The pool session timezone is also set to Europe/Istanbul (B0), so existing `CURRENT_DATE` queries (`/tasks/mine`, task stats) agree with the dashboard between 00:00 and 03:00. |

---

## 1. Page anatomy and how 18 cards stay readable

### 1.1 Order, top to bottom (web and mobile)

1. **Header.** Greeting, then date · company · role, then quick actions. It renders instantly from `/auth/me`.
2. **Summary line.** One sentence built from lane counts. Next to it (web): "Güncellendi 09:41" and the refresh button. When the viewer is membership-restricted, a scope line appears.
3. **Nabız.** Up to 4 KPI tiles, picked by priority (§3.3). The row is hidden when fewer than 2 are available.
4. **Top row.**
   - **Dikkat Gerektirenler**: primary, placed left on web.
   - **Secondary panel**, placed right:
     - **Nakit Akışı** when `finance` exists;
     - otherwise **Görevlerim** when the viewer has a linked employee;
     - otherwise nothing, and Dikkat takes the full width with its lanes side by side.
5. **Module summaries.** 18 cards in 4 fixed bands (§1.2).
6. **Akış.** Son Hareketler and Bildirimler. On mobile only Son Hareketler appears; the bell covers Bildirimler.

**Onboarding mode** (§3.6) replaces items 3 and 4 with a checklist card. It also collapses the 9 project-bound cards into one placeholder card.

### 1.2 Bands and card order (fixed; the order never changes with data)

| Band (web h2; mobile overline) | Standard cards, in order | Compact cards |
|---|---|---|
| NAKİT & SATIŞ | Proje Finansı · Teklifler · Ek İşler | – |
| PROJE & SAHA | Projeler · Görevler · Şantiye · Sözleşmeler · Mesai / Puantaj | – |
| TEDARİK & MALİYET | Satın Alma · Taşeron · Bütçe & Maliyet | – |
| FİRMA KAYITLARI | Müşteriler · Personel · Ürünler & Zam · Ekip | Metraj · Tedarikçiler · Maliyet Kodları |

### 1.3 Readability rules (these make 18 cards calm)

1. **Stable positions.** Cards keep their order whatever the data says. Urgency is shown only in Dikkat and in card footers; cards are never reshuffled.
2. **One anatomy for every standard card:**
   - header: icon tile, title, optional attention chip, and an "Aç" link;
   - a primary metric;
   - 2–4 small stats;
   - at most **one** mini-visual;
   - a footer with at most **2** attention lines, pinned to the bottom.
   If there is nothing to report, the footer shows the quiet line "Bekleyen iş yok". Cards never get coloured borders; only the footer rows carry colour.
3. **Bands group related modules.** Band headings appear only when the band has at least one card. Empty bands disappear.
4. **Density switch.** When 5 or fewer standard cards are visible (field, PM and new-company cases), band headings are dropped. All cards then go into one grid under the heading "BÖLÜMLER", and list-style content opens (project rows, task rows).
5. **Span-fill so the grid has no holes** (§5.4). If the last row of a band has 1 card, it spans the full width and switches to wide mode (metrics on the left, list on the right). If it has 2 cards at 3 columns, they split 6/6.
6. **Equal row heights** (`items-stretch`, card `h-full`, footer `mt-auto`). Minimum heights: standard card 208px, compact 72px.
7. **Low-importance registries are compact.** Metraj, Tedarikçiler and Maliyet Kodları are one-line cards. On mobile, all of FİRMA KAYITLARI is one grouped card with rows.
8. **Only two places carry alarm colour:** the Dikkat panel and card footers. KPI tiles are neutral, except for a signed value, which is coloured and always has a sign.

---

## 2. Per-module summary table (the owner's "her bölümden özet")

**Conventions used in this table:**
- **Scope:** MEM = membership-scoped server-side (owner, admin and legacy_user see all projects); ORG = organisation-wide.
- **Metrics:** the primary metric is listed first (web shows it uppercase through CSS).
- **Attention codes** are defined in §3.1.
- **Mobile links:** go = `context.go`, push = `context.push`. "–" means the row is not tappable on mobile.

| # | Card (Turkish title) · JSON key | Read gate · scope | Metrics (Turkish label = field) | Mini-visual | Attention codes (footer, ≤2) and card notes | Web link | Mobile link |
|---|---|---|---|---|---|---|---|
| 1 | **Proje Finansı** · `finance` | `projects.finance.read` · MEM | **Portföy değeri** = `portfolio_value`; Tahsil edilen = `collected_total`; Açık alacak = `open_receivable`; Harcanan = `realized_cost` | ProgressBar (success) `collection_pct`, caption "%59 tahsil edildi" | `plan_item_overdue`, `sales_invoice_overdue`. Note: "Diğer: 45.000 $" when there are several currencies | `/projeler?status=active`; rows → ref | go `/projeler`; rows → ref |
| 2 | **Teklifler** · `offers` | `offers.read` · ORG, `is_passive=false` | **Yanıt bekleyen** = `awaiting_customer.amount` + "{count} teklif"; Taslak = `draft.count`; Müşteri inceledi (7 gün) = `viewed_by_customer_7d`; Kabul oranı (90 gün) = `conversion_rate_90d_pct` | SegmentBar "Son 90 gün": Kabul (success) / Red (danger), with count legend | `offer_expired_awaiting`, `offer_accepted_not_converted`. Note: "{n} teklifin süresi 7 gün içinde doluyor" | `/teklifler`; rows → ref | go `/teklifler` |
| 3 | **Ek İşler** · `change_orders` | `projects.finance.read` · MEM | **Müşteri onayında** = count · amount; Taslak = count · amount; Bu ay onaylanan (net) = `approved_net_this_month`, signed | – | `change_order_awaiting_customer` | `/projeler?status=active`; rows → ref | go `/projeler`; rows → ref |
| 4 | **Projeler** · `projects` | `projects.read` · MEM; row `task_progress_pct` needs `projects.tasks.read`; row `collection_pct` needs finance.read | **Aktif proje** = `counts.active` + "toplam {total}"; Planlanan = `counts.planned`; Bitişi geçen = `past_end_date`; 30 günde bitecek = `ending_within_30d` | SegmentBar of status (Planlandı muted, Devam gold, Beklemede muted-dark, Tamamlandı success; İptal in the legend only). List of the top 3 open projects (5 in wide mode): bars Süre (graphite), Görev (gold, if present), Tahsilat (success, if present) | `project_past_end` | `/projeler?status=active`; rows `/projeler/{id}` | go `/projeler`; rows push `/projeler/{id}` |
| 5 | **Görevler** · `tasks` | `projects.tasks.read` · MEM (+ employee link for "mine") | **Açık görevim** = `mine.open` (**Ekipte açık görev** = `team.open` if not linked); Gecikmiş = `mine.overdue`; Bugün = `mine.due_today`; Atanmamış = `team.unassigned`; Son 7 günde tamamlanan = `team.completed_7d` | List of the next 3 `mine.items` (hidden when Görevlerim is promoted to the top row) | `my_task_overdue`, `my_task_due_today`, `team_task_overdue`, `team_task_unassigned` | `/projeler?status=active` (web has no task page); rows → ref (`?tab=operasyon`) | go `/gorevler`; rows push task route |
| 6 | **Şantiye** · `operations` | `projects.operations.read` · MEM | **Sahadaki ekip** = `active_crew` "kişi"; 7 günde biten iş kalemi = `milestones.due_7d`; Geciken iş kalemi = `milestones.overdue`; Fotoğraf (7 gün) = `photos_7d` | – | `milestone_overdue` | `/projeler?status=active` | go `/projeler` |
| 7 | **Sözleşmeler** · `contracts` | `projects.contracts.read` · MEM | **Aktif sözleşme** = `counts.active`; Taslak = `counts.draft`; Sözleşmesiz aktif proje = `active_projects_without_contract`; Bitişi geçen = `past_planned_completion` | SegmentBar: Taslak muted, Aktif gold, Tamamlandı success, İptal/Fesih danger | `contract_activation`, `contract_past_completion`, `active_without_contract` | `/projeler?status=active`; rows → ref (`?tab=finans`) | go `/projeler`; rows → ref |
| 8 | **Mesai / Puantaj** · `attendance` | `attendance.read` · ORG | **Bugün sahada** = "{on_site} / {active_employees}"; Gelmedi = `absent`; İzinli = `on_leave`; Girilmedi = `not_recorded`; Bu ay toplam = `month_work_hours` "4.120,5 sa". Caption "Firma geneli" | SegmentBar: Geldi success, Yarım gün gold, Gelmedi danger, İzinli muted, Girilmedi dashed outline | `attendance_not_recorded` (workdays only) | `/mesai` | push `/diger/mesai` |
| 9 | **Satın Alma** · `procurement` | `projects.procurement.read` · MEM | **Onay bekleyen talep** = `purchase_requests.submitted`; Açık RFQ = `rfqs.issued`; Açık sipariş = `purchase_orders.approved_open`; Geciken teslimat = `purchase_orders.late_delivery` | Flow row: "Talep {submitted} onayda → RFQ {issued} açık → Sipariş {approved_open} açık" (ChevronRight between steps) | `purchase_request_approval`, `purchase_order_draft`, `rfq_award`, `rfq_no_quote`, `po_late_delivery`. Note: "Bu ay onaylanan: {n} sipariş · {amount}" | `/projeler?status=active`; rows → ref (`?tab=satinalma`) | go `/projeler`; rows → exact talep/RFQ/sipariş route |
| 10 | **Taşeron** · `subcontracts` | `projects.subcontracts.read` · MEM; `claims` needs `subcontract_claims.read`; `paid_*` and `certified_unpaid` need `subcontract_payments.read` | **Aktif sözleşme** = `active_count` · `current_value`; Onayda hakediş = `claims.submitted`; Onaylı, ödenmemiş = `claims.certified_unpaid`; Değişiklik emri (onayda) = `change_orders_submitted` | ProgressBar (success) `paid_pct` "%34 ödendi", with an info tooltip: "Hakedişe bağlanmamış avans ödemeleri 'ödenmemiş' tutarını azaltmaz." | `progress_claim_certify`, `claim_certified_unpaid`, `subcontract_co_approval`. Web note: "Taşeron hakediş ve değişiklik emirleri şimdilik mobil uygulamada yönetilir." | `/projeler?status=active`; rows → `?tab=finans` | go `/projeler`; rows → exact hakediş/değişiklik-emri route |
| 11 | **Bütçe & Maliyet** · `cost_control` | `projects.budget.read` OR `projects.cost_control.read` · MEM | **Bütçeyi aşan proje** = `over_budget.count` (if null: **Onaylı bütçe** = "{baselined} / {open} proje"); Onayda revizyon = `pending_adjustments.count`; Aktif taahhüt = `committed_active`; Bütçesiz açık proje = `budgets.none` | SegmentBar: Bütçesiz muted, Taslak gold, Onaylı success | `budget_adjustment_approval`, `over_budget`, `active_without_budget` | `/projeler?status=active`; rows → `?tab=maliyet` | go `/projeler`; rows → `?grup=finans&alt=maliyet` |
| 12 | **Müşteriler** · `customers` | `customers.read` · ORG (`with_active_projects` is MEM) | **Aktif müşteri** = `active`; Bu ay eklenen = `new_this_month`; Aktif projesi olan = `with_active_projects` | – | – | `/musteriler` | push `/diger/musteriler` |
| 13 | **Personel** · `employees` | `employees.read` · ORG | **Aktif personel** = `active`; Pasif = `inactive`; Kullanıcı hesabı olan = `with_user_account`; Bu ay başlayan = `new_this_month` | – | – (never payroll) | `/admin/personel` | – |
| 14 | **Ürünler & Zam** · `products` | `products.read` · ORG | **Ürün** = `total`; Zamlanan ürün (30 gün) = `price_changes_30d.products_increased`; Ortalama zam = `avg_increase_percent`; En yüksek zam = "%{change_percent} · {product_name}" (link to the product) | SegmentBar of source: Manuel `text-muted/40`, Ulaş graphite, Demir Profil `text`. Plus source chips "Ulaş · 2 gün önce · Başarılı/Hata/Hiç senkronlanmadı" | `price_sync_failed`, `price_sync_never`. Note: "{Kaynak} fiyatları {n} gündür güncellenmedi" when older than 7 days | `/admin/urunler/zamlar?period=30`; secondary link "Ürünler" `/admin/urunler` | – |
| 15 | **Ekip** · `users` | coarse `role=admin` AND `organization.users.read` · ORG; `with_personal_overrides` also needs `organization.roles.read` | **Aktif kullanıcı** = `active`; Hiç giriş yapmamış = `never_logged_in`; Projesi olmayan = `restricted_without_project`; Personel kaydı olmayan = `without_employee_link`; Kişiye özel yetkili = `with_personal_overrides` | Role chips (muted Badges): "Sahip 1 · Yönetici 1 · Proje Yöneticisi 2 · Finans 1 · Saha 3" | `users_without_project`. Note: "{n} kullanıcının personel kaydı yok; görev listeleri boş görünür." | `/admin/kullanicilar`; secondary link "Roller & Yetkiler" `/admin/roller` | – |
| 16 | **Metraj** (compact) · `calculations` | `calculations.read` · ORG | "{groups} grup · {categories} kategori" | – | Notes: "Son 30 günde {n} teklif kaleminde kullanıldı" (needs offers.read); "{n} reçete kalemi ürüne bağlı değil" (needs calculations.manage) | `/admin/metraj-hesaplama` | push `/diger/metraj` |
| 17 | **Tedarikçiler** (compact) · `suppliers` | `organization.suppliers.read` · ORG | "{active} aktif · {inactive} pasif" | – | Note: "Bu ay {n} tedarikçiden sipariş verildi" (needs procurement.read, MEM) | `/admin/tedarikciler` | – |
| 18 | **Maliyet Kodları** (compact) · `cost_codes` | `organization.cost_codes.read` · ORG | "{active} aktif · {inactive} pasif" | – | Note: "Bu ay {n} masrafta maliyet kodu yok" (needs cost_control.read, MEM) | `/admin/maliyet-kodlari` | – |
| F1 | **Bildirimler** (Akış panel) · `notifications` | `notifications.read` · own rows | Unread badge "{n} okunmamış"; latest 5: dot, title, one-line body, relative time | – | Action "Tümünü okundu say" (`POST /notifications/read-all`) | rows `webHrefForActionTarget(action_target)`; no web page | not a card (bell) |
| F2 | **Son Hareketler** (Akış panel) · `activity` | per-event permission map (§4.9) · MEM | 10 rows web / 5 mobile: "{user} · {etiket} · {project_no} {project_name}", relative time; **no amounts** | – | – | `/projeler/{p}?tab=aktivite` | push `/projeler/{p}` |

**Empty-state copy for every card is in §7.4.** A card shows its empty state inside the standard frame. The CTA is shown only with the matching write permission.

---

## 3. Cross-cutting catalogs

### 3.1 Attention code catalog (drives Dikkat, card footers and card chips)

**Lane rule:**
- If the viewer holds the **act** permission(s): lane = `mine`.
- Otherwise: `watching` or hidden, as the "If cannot act" column says.
- The `my_task_*` codes are always `mine`.

A code is produced only when **its module section is visible AND its own visible gate passes**. Projects with status `cancelled` never produce attention.

**Ranking (server, Go, unit-tested):**
1. lane `mine` before `watching`;
2. severity `danger` > `action` > `info`;
3. `oldest_days` descending;
4. primary-currency amount descending;
5. `code` ascending (tie-breaker, for determinism).

**Title templates** below use `{n}`. Turkish uses the singular noun after numerals, so one template serves every count.

| code | module | severity | visible if | act if | If cannot act | Title (Dikkat and footer) | Record ref kind · record line |
|---|---|---|---|---|---|---|---|
| `plan_item_overdue` | finance | danger | projects.finance.read | projects.finance.manage | watching | "{n} ödeme planı kaleminin vadesi geçti" | payment_plan_item · "{item_name} · {project} · {days} gün gecikti" + remaining amount |
| `sales_invoice_overdue` | finance | danger | projects.finance.read | projects.finance.manage | watching | "{n} satış faturasının vadesi geçti" | invoice · "{invoice_no} · {project} · {days} gün gecikti" |
| `change_order_awaiting_customer` | change_orders | info | projects.finance.read | – (the customer decides) | watching | "{n} ek iş müşteri onayında" | change_order · "{title} · {project} · {days} gündür bekliyor" |
| `offer_expired_awaiting` | offers | danger | offers.read | offers.update | watching | "{n} teklifin süresi doldu, müşteri yanıt vermedi" | offer · "{offer_no} · {customer} · {days} gün önce doldu" |
| `offer_accepted_not_converted` | offers | action | offers.read | projects.create | watching | "{n} kabul edilen teklif projeye dönüştürülmedi" | offer (action `convert` when can_act) · "{offer_no} · {customer}" |
| `purchase_request_approval` | procurement | action | projects.procurement.read | projects.procurement.approve | watching | "{n} satın alma talebi onay bekliyor" | purchase_request · "{pr_no} · {title} · {project} · {days} gündür bekliyor" |
| `purchase_order_draft` | procurement | action | projects.procurement.read | projects.procurement.approve | watching | "{n} sipariş taslağı onaylanmadı" | purchase_order · "{po_no} · {project}" |
| `rfq_award` | procurement | action | projects.procurement.read | projects.procurement.approve | watching | "{n} RFQ'da teklifler toplandı, karar bekliyor" | rfq (action `award`) · "{rfq_no} · {title} · {project}" |
| `rfq_no_quote` | procurement | action | projects.procurement.read | projects.procurement.manage | hide | "{n} RFQ'nun süresi doldu, teklif gelmedi" | rfq · "{rfq_no} · {project} · {days} gün geçti" |
| `po_late_delivery` | procurement | danger | projects.procurement.read | projects.procurement.manage | watching | "{n} siparişin teslimi gecikti" | purchase_order · "{po_no} · {project} · {days} gün gecikti" |
| `progress_claim_certify` | subcontracts | action | projects.subcontract_claims.read | projects.subcontract_claims.certify | watching | "{n} taşeron hakedişi onay bekliyor" | progress_claim (parent = subcontract) · "{claim_number} · {project} · {days} gündür bekliyor" + net_payable |
| `claim_certified_unpaid` | subcontracts | action | subcontract_claims.read AND subcontract_payments.read | projects.subcontract_payments.manage | watching | "{n} onaylı hakedişin ödemesi yapılmadı" | progress_claim · "{claim_number} · {project}" + unpaid amount |
| `subcontract_co_approval` | subcontracts | action | projects.subcontracts.read | projects.subcontracts.approve | watching | "{n} taşeron değişiklik emri onay bekliyor" | subcontract_change_order (parent = subcontract) · "{number} · {title} · {project}" |
| `budget_adjustment_approval` | cost_control | action | projects.budget.read | projects.budget.manage | watching | "{n} bütçe revizyonu onay bekliyor" | budget_adjustment · "{project} · {days} gündür bekliyor" + amount |
| `over_budget` | cost_control | danger | projects.cost_control.read | projects.cost_control.manage | watching | "{n} proje bütçesini aştı" | project_cost · "{project} · %{pct} aşım" |
| `active_without_budget` | cost_control | action | projects.budget.read | projects.budget.manage | hide | "{n} aktif projenin onaylı bütçesi yok" | project_cost · "{project}" |
| `contract_activation` | contracts | action | projects.contracts.read | projects.contracts.lifecycle | watching | "{n} sözleşme taslakta, aktifleştirilmedi" | contract · "{project}" |
| `contract_past_completion` | contracts | danger | projects.contracts.read | projects.contracts.lifecycle | watching | "{n} sözleşmenin planlanan bitişi geçti" | contract · "{project} · {days} gün geçti" |
| `active_without_contract` | contracts | action | projects.contracts.read | projects.contracts.manage | hide | "{n} aktif projenin sözleşme kaydı yok" | project_finance · "{project}" |
| `project_past_end` | projects | danger | projects.read | projects.update | hide | "{n} projenin bitiş tarihi geçti" | project · "{project_no} {name} · {days} gün geçti" |
| `my_task_overdue` | tasks | danger | tasks.read + linked employee | always | – | "{n} görevin gecikti" | task · "{title} · {project} · {days} gün gecikti" |
| `my_task_due_today` | tasks | action | same | always | – | "{n} görevin bugün bitiyor" | task · "{title} · {project}" |
| `team_task_overdue` | tasks | danger | projects.tasks.read | projects.tasks.create | hide | "Ekipte {n} görev gecikmiş" | task · "{title} · {project} · {days} gün gecikti" |
| `team_task_unassigned` | tasks | action | projects.tasks.read | projects.tasks.create | hide | "{n} görev kimseye atanmamış" | task · "{title} · {project}" |
| `milestone_overdue` | operations | danger | projects.operations.read | projects.operations.manage | hide | "{n} iş programı kalemi gecikti" | milestone · "{name} · {project} · {days} gün gecikti" |
| `attendance_not_recorded` | attendance | action | attendance.read AND `is_workday` | attendance.manage AND employees.read | hide | "Bugün {n} personelin mesaisi girilmedi" | – (the group links to Mesai) |
| `price_sync_failed` | products | danger | products.read | products.manage | watching | "{Kaynak} fiyat senkronu başarısız oldu" | price_source · "{relative last_synced_at}" |
| `price_sync_never` | products | action | products.read | products.manage | hide | "{Kaynak} fiyat kaynağı hiç senkronlanmadı" | price_source |
| `users_without_project` | users | action | admin + organization.users.read | projects.access.manage | hide | "{n} kullanıcı hiçbir projeyi göremiyor" | user · "{full_name} · {role_name}" |

**Notes on the rules above:**
- `{Kaynak}` is "Ulaş" or "Demir Profil".
- Why `team_task_*` uses `projects.tasks.create` rather than `projects.tasks.update`: field workers hold `update`, and B's version wrongly put team rows in their lane.
- Why missing-setup codes are `action`, not `danger`: this avoids over-alarming (judge note on F12).

**Card chip** (module header), computed from the groups that belong to the module:
- any danger group → Badge `danger` "{Σ danger counts} uyarı";
- else any action group → web Badge `gold` / mobile `warning` "{Σ} bekliyor";
- else any info group → Badge `info` "{Σ} takipte";
- else no chip.

### 3.2 Upcoming (Yaklaşan · 14 gün)

- Window: `today` … `today+13`, at most 8 items, sorted by date ascending, then by kind.
- Overdue items never appear here.
- Today's own tasks are excluded, because they are already `my_task_due_today`.

| kind | gate | label (TR) | title | amount |
|---|---|---|---|---|
| `plan_item_due` | projects.finance.read | Ödeme planı | "{item_name} · {project}" | remaining |
| `offer_expiry` | offers.read | Teklif süresi doluyor | "{offer_no} · {customer}" | grand_total |
| `po_delivery` | projects.procurement.read | Sipariş teslimi | "{po_no} · {project}" | – |
| `milestone_end` | projects.operations.read | İş programı | "{name} · {project}" | – |
| `project_end` | projects.read | Proje bitişi | "{project_no} {name}" | – |
| `my_task_due` (from tomorrow) | tasks.read + linked employee | Görev | "{title} · {project}" | – |

Date display: "Bugün", "Yarın", otherwise web shows a date block ("30" over "EYL") and mobile shows "30 Eyl".

### 3.3 Nabız KPI candidates (take the first 4 available; hide the row if fewer than 2)

"Available" means the source exists and is non-empty. For finance tiles, `by_currency` must have at least 1 row. For the pipeline tile, `offers.by_currency` must have at least 1 row. For "Açık görevim", `tasks.mine.linked_employee` must be true.

| # | key | Label (TR) | Value | Sub-lines (neutral breakdown only) | Visual | Web link | Mobile |
|---|---|---|---|---|---|---|---|
| 1 | receivable | Açık alacak | compact `finance.by_currency[0].open_receivable` | "%{collection_pct} tahsil edildi" | ProgressBar success | `/projeler?status=active` | go `/projeler` |
| 2 | net_cash | Bu ay net nakit | signed compact `month.net_cash`; success/danger text **with sign** | "Giriş {collections}" / "Çıkış {outflows}" | – | `#nakit-akisi` | not tappable |
| 3 | pipeline | Teklif hattı | compact `offers.by_currency[0].awaiting_customer.amount` | "{count} teklif yanıt bekliyor" · "Kabul oranı %{x} · 90 gün" (if not null) | – | `/teklifler` | go `/teklifler` |
| 4 | cash_balance | Proje nakit dengesi | signed compact `finance.by_currency[0].cash_balance` | "Tahsilat {collected_total} · Harcama {realized_cost}" | – | `/projeler?status=active` | not tappable |
| 5 | active_projects | Aktif proje | `projects.counts.active` | "{planned} planlanan · {paused} beklemede" | – | `/projeler?status=active` | go `/projeler` |
| 6 | my_tasks | Açık görevim | `tasks.mine.open` | "{overdue} gecikmiş · {due_today} bugün" | – | `#gorevlerim` (web panel) | go `/gorevler` |
| 7 | team_overdue | Ekipte geciken görev | `tasks.team.overdue` (danger text when >0) | "{unassigned} görev atanmamış" | – | `#modul-tasks` | go `/gorevler` |
| 8 | on_site | Bugün sahada | "{on_site} / {active_employees}" | "Firma geneli · {not_recorded} kişi girilmedi" | – | `/mesai` | push `/diger/mesai` |
| 9 | unread | Okunmamış bildirim | `notifications.unread` | latest title (truncated) | – | `#bildirimler` | push `/diger/bildirimler` |

- **Several currencies:** when `by_currency.length > 1`, the tile adds a line "Diğer: {compact others joined by ' · '}". This line is plain text: tiles are links, so there is no nested interaction.
- **Resulting KPI sets:**
  - Owner: 1, 2, 3, 4.
  - Finance: 1, 2, 4, 5.
  - Field: 5, 6, 7, 8.
  - Project manager: 5, 6, 7, 9.

### 3.4 Summary sentence and scope line (both platforms, from `agenda`)

**Summary sentence:**
- `mine_count > 0`: "Bugün {mine_count} iş senin sıranda" + (`mine_danger_count > 0` ? "; {mine_danger_count} tanesi acil." : ".")
- `mine_count == 0 && watching_count > 0`: "Senin sıranda iş yok; {watching_count} konu takipte."
- both 0: "Bugün seni bekleyen bir iş yok."

**Scope line**, only when `viewer.all_projects == false`:
- "Üyesi olduğun {accessible_project_count} projenin verileri gösteriliyor."
- When the count is 0: "Henüz bir projeye eklenmedin; yöneticin seni eklediğinde proje verileri burada görünür."

### 3.5 Quick actions (client-gated by write permissions, in this order)

| key | Web label | Mobile label | Gate | Web target | Mobile target |
|---|---|---|---|---|---|
| offer | Yeni Teklif | **Teklif Oluştur** (kept; tests assert it) | offers.create | `/teklifler/yeni` | push `/teklifler/yeni` |
| collection | Tahsilat Gir | Tahsilat Gir | projects.finance.manage | ProjectPicker → `/projeler/{p}?tab=finans` | ProjectPicker → `showCollectionFormSheet(ctx, p.id, currency: p.currency)` |
| expense | Masraf Gir | Masraf Gir (replaces the ungated "Masraf Ekle") | projects.finance.manage | picker → `?tab=finans` | picker → `showExpenseFormSheet(...)` |
| attendance | Mesai Gir | Mesai Gir | attendance.manage **AND** employees.read | `/mesai` | push `/diger/mesai` |
| purchase_request | Satın Alma Talebi | Satın Alma Talebi | projects.procurement.manage | picker → `?tab=satinalma` | picker → push `/projeler/{p}/satin-alma/talepler/yeni` |
| task | Görev Ekle | Görev Ekle | projects.tasks.create | picker → `?tab=operasyon` | picker → push `/projeler/{p}/gorevler/yeni` |
| note | – | Not Ekle | projects.operations.manage | – | picker → `showNoteFormSheet(ctx, p.id)` |
| customer | Müşteri Ekle | **Müşteri Ekle** (kept) | customers.manage | `/musteriler/yeni` | `CustomerFormSheet` (existing) |
| calc | Metraj Hesapla | **Metraj Hesapla** (kept) | calculations.read | `/admin/metraj-hesaplama` | push `/diger/metraj` |
| product | Ürün Ekle | – | products.manage | `/admin/urunler/yeni` | – |
| employee | Personel Ekle | – | employees.manage | `/admin/personel/yeni` | – |
| user | Kullanıcı Ekle | – | coarse admin AND organization.users.manage | `/admin/kullanicilar/yeni` | – |

- **There is no "Yeni Proje".** Projects come only from `/teklifler/{id}/projeye-donustur`, which Dikkat surfaces via `offer_accepted_not_converted`.
- **ProjectPicker:** if the viewer has exactly 1 open project, the picker is skipped. After a mobile sheet closes with a result, the screen calls `ref.invalidate(dashboardProvider)`.
- **Web placement:**
  - action 1 is a `primary` Button;
  - action 2 is `secondary` from the `@2xl` container size up;
  - action 3 is `secondary` from `@4xl` up;
  - all remaining actions go in a `DropdownMenu`, trigger label "Diğer işlemler", icon `MoreHorizontal`.
  - Items 2 and 3 are also in the dropdown, with `@2xl:hidden` / `@4xl:hidden`.
  - With 0 actions the area is absent.
- **Mobile:** a horizontal `QuickActionButton` row. It is hidden when empty.

### 3.6 Onboarding mode (new company)

**When it applies:** the server returns `onboarding` only when the viewer is coarse admin AND the organisation has 0 projects AND 0 non-passive offers. Otherwise it returns `null`.

**Layout changes:**
- A "Kurulum — ilk adımlar" card replaces the Nabız row and the top row.
- The 9 project-bound module cards (finance, change_orders, projects, tasks, operations, contracts, procurement, subcontracts, cost_control) are replaced by **one** placeholder card, "Proje modülleri".
- Density mode applies: a single "BÖLÜMLER" grid in this order: placeholder (full width), Teklifler, Mesai / Puantaj, Müşteriler, Personel, Ürünler & Zam, Ekip, then the compact cards.

**Steps**, with `done` computed by the server:

| key | Step text | Done when | CTA (gate) |
|---|---|---|---|
| customer | İlk müşterini ekle | active customers > 0 | Müşteri Ekle (customers.manage) |
| catalog | Ürün kataloğunu hazırla. Helper: "Ulaş veya Demir Profil'den çekebilir ya da elle ekleyebilirsin." | products > 0 | Ürünlere git (products.read) |
| employee | Personel ekle | active employees > 0 | Personel Ekle (employees.manage) |
| team | Ekibini davet et | active users > 1 | Kullanıcı Ekle (admin + organization.users.manage) |
| first_offer | İlk teklifini hazırla | offers > 0 | Yeni Teklif (offers.create) |
| convert | Kabul edilen teklifi projeye dönüştür. Helper: "Müşteri teklifi kabul edince tek tıkla proje açılır." | projects > 0 | Tekliflere git (offers.read) |

- **Extra link** (not a step): "Firma bilgilerini gözden geçir →". Web goes to `/admin/firma-ayarlari`; mobile pushes `/diger/firma-ayarlari`.
- **Done row:** `CircleCheckBig` icon in success colour, muted text, and a detail (for example "628 ürün"). The CTA is hidden.
- **Header:** "{done_count} / {total} tamamlandı", a ProgressBar in gold, and a "Gizle" link.
  - Web stores the dismissal in `localStorage` under key `arvend.home.onboarding.hidden.{orgId}.{userId}` = "1" (wrapped in try/catch).
  - Mobile uses `SharedPreferences` (the package already exists) with the same key.
- **After "Gizle":** the normal layout shows, with honest zeros.

---

## 4. (A) Backend

### 4.0 Prerequisite fixes (small, same PR series)

- **B0. Istanbul everywhere.**
  - In `internal/repository/pool.go`, `NewPool` switches to `pgxpool.ParseConfig`, sets `cfg.ConnConfig.RuntimeParams["timezone"] = "Europe/Istanbul"`, then calls `pgxpool.NewWithConfig`. With this, `CURRENT_DATE` / `now()::date` in the existing queries (`CountProjectTaskStats`, `ListMyTasks`) use the Istanbul date.
  - Move `istanbulLocation` from `service/price_source_service.go:798` into `internal/service/timezone.go` (exported helper `IstanbulNow(now time.Time) time.Time` plus a `DashboardClock`).
  - Change the callers of `domain.IsPastDue(due, now)` to pass `time.Now().In(istanbul)`.
  - Test: a DB session reports `SHOW timezone = Europe/Istanbul`.
- **B1. Offer decision timestamp.** In `OfferService.UpdateStatus`, pass `map[string]any{"from_status": previousStatus, "to_status": status}` to `logOfferEvent` in place of `nil`. The event type stays `offer_updated`, or `revision_sent`.
- **B2. Activity labels are not the backend's job.** Activity rows carry only `event_type`.

### 4.1 Routes (`internal/httpapi/router.go`, inside `/api/v1`)

```go
r.With(requireAuth, requireTenant, requireOnboarded, loadAuthorization).
    Get("/dashboard", d.Dashboard.Get)
r.With(requireAuth, requireTenant, requireOnboarded, loadAuthorization, perm(domain.PermProjectsRead)).
    Get("/dashboard/project-options", d.Dashboard.ProjectOptions)
```

- `/dashboard` has no `perm()`: each section gates itself. Super Admin gets 403 `tenant_context_required` from `requireTenant`.
- **Errors:** the endpoint returns 200 even when some sections fail. It returns 500 only if the transaction or the viewer/meta queries fail.
- **Project options:** `GET /dashboard/project-options?q=` returns
  `{"projects":[{"id","project_no","name","customer_name","currency","status"}]}`
  - statuses `planned`, `active` and `paused`;
  - MEM predicate;
  - `q` matched with ILIKE on `name` / `project_no`;
  - ordered by name, limit 50;
  - **no money fields**.

### 4.2 Files

| File | Content |
|---|---|
| `internal/domain/dashboard.go` | Response structs with json tags (§4.4). Section keys; `AttentionCode`, `UpcomingKind` and `RefKind` constants. `AttentionRules` table (code → module, severity, visible perms, act perms, when-cannot-act). `ActivityEventPermissions map[string]string` covering every project event type (§4.9). |
| `internal/service/timezone.go` | Istanbul location and `NewDashboardClock(now time.Time) DashboardClock`. |
| `internal/service/dashboard_service.go` | `DashboardService{pool, q}`. Method `Get(ctx, DashboardInput) (*domain.Dashboard, error)` plus the section registry, savepoints and error map. |
| `internal/service/dashboard_sections.go` | One builder per section: `buildProjects`, `buildFinance`, … Each returns `(section any, attention []AttentionGroup, upcoming []UpcomingItem, err error)`. |
| `internal/service/dashboard_agenda.go` | Lane assignment, ranking, counts. Pure functions. |
| `internal/repository/queries/dashboard.sql` | All queries (sqlc). Regenerate with `sqlc generate`, output to `internal/repository/sqlc/dashboard.sql.go`. |
| `internal/httpapi/handler/dashboard_handler.go` | `Get` and `ProjectOptions`. |
| `db/migrations/0047_dashboard_indexes.up/down.sql` | `CREATE INDEX IF NOT EXISTS` on `project_events (organization_id, created_at DESC)`, `attendance_logs (organization_id, date)`, `project_tasks (organization_id, status, due_date)`, `purchase_requests (organization_id, status)`, `subcontract_progress_claims (organization_id, status)`. |
| `docs/dashboard/fixtures/{owner,empty_company,field,finance}.json` | Canonical contract fixtures. All three test suites use them (§4.11). |
| Docs | `mobile/API_CONTRACT.md` (new endpoints); `HANDOFF.md` (dashboard section); `MOBILE_BACKEND_GAPS.md` (close the dashboard gap). |

### 4.3 Service flow

```go
type DashboardInput struct {
    OrganizationID, UserID string
    CoarseRole domain.Role                // from middleware.RoleFromContext
    Authz *service.AuthzContext           // from middleware.AuthzContextFromRequest
    Now time.Time                         // injected clock (tests)
}
```

1. **Clock.** `clk := NewDashboardClock(in.Now)` computes all Istanbul dates:
   - `Today`, `MonthStart`, `NextMonthStart`, `TrendStart` (= MonthStart − 5 months), `D7Start` (= today − 6), `D30Start` (= today − 29), `D90Start` (= today − 89), `Plus6`, `Plus13`, `Plus29`;
   - `timestamptz` bounds at Istanbul midnight for each of these;
   - `IsWorkday = weekday != Sunday`.
2. **Membership restriction.** `restrict := ""`; if `!in.Authz.BypassesProjectMembership()` then `restrict = in.UserID`. This is copied verbatim from `project_handler.go:181-184`.
3. **Transaction.** `tx := pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly})`, then:
   `SET LOCAL statement_timeout = '5s'; SET LOCAL TIME ZONE 'Europe/Istanbul';`
   and `q := s.q.WithTx(tx)`.
4. **Meta.** Read `primary_currency`, the viewer counts (`accessible_project_count`) and, for coarse admin, the onboarding counts. **These run outside savepoints: a failure here returns 500.**
5. **Sections.** For each section in registry order, if `gate(authz, coarseRole)` passes:
   - `sp, _ := tx.Begin(ctx)` (a pgx nested tx, i.e. a SAVEPOINT);
   - run the builder;
   - on error: `sp.Rollback`, log with the section key, set `section_errors[key] = "section_failed"`, continue;
   - on success: `sp.Commit` (releases the savepoint).
   - **Sections that are not permitted are never executed and never appear in `section_errors`.**
6. **Agenda.** Collect the attention groups and upcoming items of the successful sections. Apply the lane rules (§3.1, using `authz.HasPermission`), rank, cap each group's `items` to 3 and the upcoming list to 8, and compute the counts.
7. **Finish.** Commit (read-only) and marshal.
8. **Test hook.** A test-only option `DashboardService.FailSection(key)` forces a builder error, for the `section_errors` tests.

### 4.4 Response contract (canonical; TypeScript notation, Go/Dart mirror it)

```ts
type ISODate = string;          // "2026-09-28" (Europe/Istanbul calendar date)
type ISODateTime = string;      // RFC3339 with offset, "2026-09-28T09:41:12+03:00"
type Money = number;            // JSON number, 2 decimals, SQL numeric(18,2) → float64 transport
type Pct = number | null;       // 1 decimal, null when denominator is 0
interface MoneyAmount { currency: string; amount: Money }
interface CountAmount { count: number; amount: Money }                 // single-currency contexts
interface CountAmounts { count: number; amounts: MoneyAmount[] }       // multi-currency; [] when count 0

type RefKind = "project" | "project_finance" | "project_cost" | "project_operations" | "offer" | "task" |
  "milestone" | "purchase_request" | "rfq" | "purchase_order" | "subcontract" | "progress_claim" |
  "subcontract_change_order" | "change_order" | "budget_adjustment" | "contract" | "payment_plan_item" |
  "invoice" | "customer" | "product" | "user" | "price_source";
interface Ref { kind: RefKind; id: string; project_id: string | null; parent_id: string | null;
  action: "open" | "award" | "convert" }   // parent_id = subcontract id for claims / sub-COs; price_source id = "ulas"|"demirprofil"

interface DashboardResponse {
  generated_at: ISODateTime; today: ISODate; timezone: "Europe/Istanbul"; is_workday: boolean;
  period: { month_start: ISODate; next_month_start: ISODate; upcoming_end: ISODate };
  primary_currency: string;
  viewer: { user_id: string; organization_role_code: string; is_admin: boolean;
            all_projects: boolean; accessible_project_count: number };
  onboarding: { steps: { key: "customer"|"catalog"|"employee"|"team"|"first_offer"|"convert";
                         done: boolean; detail: string | null }[]; done_count: number; total: number } | null;
  agenda: {
    groups: AttentionGroup[];         // ranked, lanes mine|watching only
    upcoming: UpcomingItem[];         // ≤8
    mine_count: number; mine_danger_count: number; watching_count: number;   // Σ group.count
  };
  sections: Partial<Sections>;        // absent key = no permission
  section_errors: Partial<Record<SectionKey, "section_failed">>;   // only permitted sections
}

interface AttentionGroup { code: string; module: ModuleKey; lane: "mine" | "watching";
  severity: "danger" | "action" | "info"; count: number; amounts: MoneyAmount[];
  oldest_days: number | null; items: AttentionRecord[] }            // items ≤3, most urgent first
interface AttentionRecord { ref: Ref; label: string; project_name: string | null;
  amount: MoneyAmount | null; date: ISODate | null; days: number | null; pct: Pct }
interface UpcomingItem { kind: "plan_item_due"|"offer_expiry"|"po_delivery"|"milestone_end"|"project_end"|"my_task_due";
  date: ISODate; ref: Ref; title: string; project_name: string | null; amount: MoneyAmount | null }

type SectionKey = ModuleKey | "notifications" | "activity";
type ModuleKey = "finance"|"offers"|"change_orders"|"projects"|"tasks"|"operations"|"contracts"|"attendance"|
  "procurement"|"subcontracts"|"cost_control"|"customers"|"employees"|"products"|"users"|
  "calculations"|"suppliers"|"cost_codes";

interface Sections {
  projects: { counts: { planned: number; active: number; paused: number; completed: number; cancelled: number; total: number };
    past_end_date: number; ending_within_30d: number; top: ProjectRow[] /* ≤5 open, server-ranked */ };
  finance: { by_currency: {
    currency: string; portfolio_value: Money; collected_total: Money; open_receivable: Money; collection_pct: Pct;
    realized_cost: Money; cash_balance: Money;
    month: { collections: Money; expenses: Money; subcontract_payments: Money; outflows: Money; net_cash: Money };
    overdue_plan: CountAmount; overdue_sales_invoices: CountAmount;
    trend_6m: { month: string /* "2026-04" */; collections: Money; outflows: Money; net: Money }[] /* exactly 6, oldest first */
  }[] };
  change_orders: { by_currency: { currency: string; awaiting_customer: CountAmount; draft: CountAmount;
    approved_net_this_month: Money }[] };
  offers: { total_active: number;
    by_currency: { currency: string; draft: CountAmount; awaiting_customer: CountAmount;
                   accepted_90d: CountAmount; rejected_90d: CountAmount }[];
    expiring_within_7d: number; expired_awaiting: number; viewed_by_customer_7d: number;
    accepted_not_converted: number; conversion_rate_90d_pct: Pct };
  procurement: { purchase_requests: { draft: number; submitted: number };
    rfqs: { issued: number; awaiting_award: number; past_due_no_quote: number };
    purchase_orders: { draft: number; approved_open: number; late_delivery: number };
    approved_this_month: { currency: string; count: number; amount: Money }[] };
  subcontracts: { active_count: number;
    by_currency: { currency: string; current_value: Money; paid_to_date: Money | null; paid_pct: Pct }[];
    claims: { submitted: CountAmounts; certified_unpaid: CountAmounts | null } | null;
    change_orders_submitted: CountAmounts };
  cost_control: { budgets: { none: number; draft: number; baselined: number; open_projects: number } | null;
    pending_adjustments: CountAmounts | null; committed_active: MoneyAmount[] | null;
    over_budget: { count: number; worst: { ref: Ref; project_name: string; overrun_pct: number } | null } | null };
  contracts: { counts: { draft: number; active: number; completed: number; cancelled: number; terminated: number };
    active_projects_without_contract: number; past_planned_completion: number };
  tasks: { mine: { linked_employee: boolean; open: number; overdue: number; due_today: number; items: MyTask[] /* ≤5 */ };
    team: { open: number; overdue: number; due_today: number; unassigned: number; completed_7d: number } };
  operations: { active_crew: number; milestones: { due_7d: number; overdue: number }; photos_7d: number };
  attendance: { date: ISODate; scope: "organization"; active_employees: number; present: number; half_day: number;
    absent: number; on_leave: number; not_recorded: number; on_site: number; month_work_hours: number };
  employees: { active: number; inactive: number; with_user_account: number; new_this_month: number };
  customers: { active: number; new_this_month: number; with_active_projects: number };
  products: { total: number; by_source: { manual: number; ulas: number; demirprofil: number };
    price_changes_30d: { increased_count: number; decreased_count: number; products_increased: number;
      avg_increase_percent: Pct; max_increase: { ref: Ref; product_name: string; change_percent: number } | null };
    price_sources: { source: "ulas" | "demirprofil"; last_synced_at: ISODateTime | null;
      last_status: "never" | "success" | "failed"; auto_sync: boolean; days_since_sync: number | null }[] };
  calculations: { groups: number; categories: number; used_in_offer_lines_30d: number | null; recipe_items_unlinked: number | null };
  suppliers: { active: number; inactive: number; ordered_this_month: number | null };
  cost_codes: { active: number; inactive: number; expenses_without_code_month: number | null };
  users: { active: number; inactive: number; never_logged_in: number; restricted_without_project: number;
    without_employee_link: number; by_role: { code: string; name: string; count: number }[];
    with_personal_overrides: number | null };
  notifications: { unread: number; latest: { id: string; type: string; title: string; body: string;
    action_target: string | null; created_at: ISODateTime; read_at: ISODateTime | null }[] /* ≤5 */ };
  activity: { items: { source: "project" | "offer"; event_type: string; ref: Ref; project_no: string | null;
    project_name: string | null; offer_no: string | null; user_name: string | null; created_at: ISODateTime }[] /* ≤10 */ };
}
interface ProjectRow { ref: Ref; project_no: string; name: string; status: "planned" | "active" | "paused";
  customer_name: string; start_date: ISODate | null; end_date: ISODate | null; days_to_end: number | null;
  time_progress_pct: Pct; task_progress_pct: Pct /* null w/o projects.tasks.read */;
  overdue_task_count: number | null; collection_pct: Pct /* null w/o finance.read */;
  current_value: MoneyAmount | null /* null w/o finance.read */;
  flags: ("past_end" | "ending_soon" | "overdue_tasks" | "overdue_plan" | "over_budget" | "no_contract")[] }
interface MyTask { ref: Ref; title: string; project_name: string; due_date: ISODate | null;
  days_overdue: number | null; priority: "low" | "normal" | "high" | "urgent"; status: "todo" | "in_progress" }
```

**Go rules:**
- Nullable fields are pointers (`*float64`, `*int`, `*Sub`) that serialise as `null`.
- Absent sections are `omitempty` on a `map[string]any` or on pointer fields with `omitempty`.
- Arrays are never `null`: empty arrays are `[]`.

**Flag leak rule:** a `ProjectRow.flags` entry is emitted only when the viewer holds the permission of the block it comes from:
- `overdue_plan` needs finance.read;
- `over_budget` needs cost_control.read;
- `overdue_tasks` needs tasks.read;
- `no_contract` needs contracts.read;
- `past_end` / `ending_soon` need projects.read.

**Never reuse the `GET /projects` row mapper.**

### 4.5 Per-section gate and SQL definition

**Common rules:**
- Every project-scoped query starts from the `ap` CTE (§4.6).
- Child tables join `ap` **and** repeat `organization_id = @org_id` (defence in depth).
- "Open project" = status IN (planned, active, paused).
- "Non-cancelled" = status <> cancelled.
- Date columns use the Istanbul date parameters; `timestamptz` columns use the Istanbul-midnight bounds.
- Clients never do SQL-like math; all percentages are computed in SQL with divide-by-zero guards, rounded to 1 decimal.

| Section | Gate (Go) | Definitions |
|---|---|---|
| projects | `HasPermission(projects.read)` | See the **projects** notes below. |
| finance | projects.finance.read | See the **finance** notes below. |
| change_orders | projects.finance.read | Over `project_change_orders` ⋈ ap (non-cancelled): `awaiting_customer` = status 'sent'; `draft` = 'draft' (`grand_total`, grouped by the change order's currency); `approved_net_this_month` = Σ(addition) − Σ(deduction) for status 'approved' with `approved_at` in the month's timestamptz bounds. |
| offers | offers.read | See the **offers** notes below. |
| procurement | projects.procurement.read | See the **procurement** notes below. |
| subcontracts | projects.subcontracts.read | See the **subcontracts** notes below. |
| cost_control | budget.read OR cost_control.read | See the **cost_control** notes below. |
| contracts | projects.contracts.read | `project_contracts` ⋈ ap: counts by status; `active_projects_without_contract` = active ap with no contract row; `past_planned_completion` = status 'active' AND `planned_completion_date` < today. |
| tasks | projects.tasks.read | See the **tasks** notes below. |
| operations | projects.operations.read | `active_crew` = count DISTINCT `employee_id` in `project_members` ⋈ ap(active) where (`start_date` IS NULL OR ≤ today) AND (`end_date` IS NULL OR ≥ today). `project_schedule_items` with status IN (planned, active): `due_7d` = `end_date` BETWEEN today AND today+6; `overdue` = `end_date` < today. `photos_7d` = `project_photos` with `deleted_at` IS NULL and `created_at` ≥ d7_start_ts. |
| attendance | attendance.read | `active_employees` = `employees` (org, `archived_at` IS NULL, `is_active`). `attendance_logs` for org and `date` = today, counted by status: geldi → present, "yarım gün" → half_day, gelmedi → absent, izinli → on_leave (pass the Turkish status strings as parameters). `not_recorded` = active employees with no log today. `on_site` = present + half_day. `month_work_hours` = Σ `work_hours` over the month's dates. |
| employees | employees.read | `archived_at` IS NULL; active/inactive by `is_active`; `with_user_account` = `user_id` IS NOT NULL; `new_this_month` = `start_date` in month. **Salary and daily_wage are never selected.** |
| customers | customers.read | active = `is_active`; `new_this_month` = `created_at` in month bounds; `with_active_projects` = count DISTINCT `customer_id` in ap with status 'active' (MEM). |
| products | products.read | `total` uses the same filter as the `GET /products` total. `by_source` = COALESCE(source,'manual'). `price_changes_30d`: call the existing sqlc queries `SummarizePriceChanges` and `GetMaxPriceIncrease` **on the tx-bound `q`**, with from = d30_start_ts and to = now. `price_sources` = rows of `organization_price_sources` for the org; `days_since_sync` = today − `last_synced_at::date`. **No markup fields.** |
| calculations | calculations.read | Active `calc_groups` / `calc_categories`. `used_in_offer_lines_30d` (only if offers.read) = count `offer_revision_items` with `calc_category_id` IS NOT NULL, in current revisions of non-passive offers created ≥ d30_start_ts. `recipe_items_unlinked` (only if calculations.manage) = active `calc_recipe_items` with `product_id` IS NULL. |
| suppliers | organization.suppliers.read | active/inactive by `is_active`. `ordered_this_month` (only if procurement.read) = count DISTINCT `supplier_id` of `purchase_orders` ⋈ ap with `approved_at` in month. |
| cost_codes | organization.cost_codes.read | active/inactive. `expenses_without_code_month` (only if cost_control.read) = non-void `project_expenses` ⋈ ap with `cost_code_id` IS NULL and `expense_date` in month. |
| users | coarse role == admin AND organization.users.read | See the **users** notes below. |
| notifications | notifications.read | Reuse the existing unread-count and list queries for `user_id`. Limit 5, `created_at` DESC. The semantics match the bell. |
| activity | always evaluated; rows filtered | See §4.9. |

**projects**
- `counts` over ap, by status.
- `past_end_date` = open AND `end_date` < @today.
- `ending_within_30d` = open AND `end_date` BETWEEN @today AND @plus29.
- `top`: compute per open project:
  - `time_progress_pct` = clamp(0, 100, (today − start) / (end − start) × 100); null if either date is missing or end ≤ start.
  - Task stats (only if tasks.read): the `CountProjectTaskStats` formula, i.e. completed / non-cancelled, and overdue = open tasks with `due_date` < today.
  - `collection_pct` / `current_value` (only if finance.read): the finance formula below.
  - The over_budget flag (only if cost_control.read) and the no_contract flag (only if contracts.read).
- These blocks are **separate queries keyed by `project_id`**, run only when permitted, and merged in Go.
- **Ranking:**
  - tier 1 = past_end OR overdue_plan OR over_budget;
  - tier 2 = overdue_tasks OR ending_soon;
  - tier 3 = the rest;
  - within a tier: `end_date` ASC NULLS LAST, then name.
  - Take 5.

**finance** (by project currency)
- **Project set P** = ap non-cancelled.
- **current_value** per project = `contract_amount` + approved additions − approved deductions. Copy the `co_effect` expressions verbatim from `GetProjectFinancialSummary`.
- **portfolio_value** = Σ current_value.
- **collected_total** = Σ non-void `project_collections`.
- **open_receivable** = Σ GREATEST(current_value − collected, 0) per project.
- **collection_pct** = collected_total / portfolio_value × 100.
- **realized_cost** = Σ(non-void expenses + non-void legacy `project_subcontractor_payments` + non-void `subcontract_payments`). This is the same formula as the summary. The two payment tables are physically separate (migration 0039), so there is no double count.
- **cash_balance** = collected_total − realized_cost.
- **month.*** over **all ap, including cancelled** (the cash is real), with dates in [month_start, next_month_start):
  - `collections` by `received_date`;
  - `expenses` by `expense_date`;
  - `subcontract_payments` = legacy `paid_date` + Sprint 5 `paid_date`;
  - `outflows` = expenses + subcontract_payments;
  - `net_cash` = collections − outflows.
- **overdue_plan:** items with status <> 'cancelled' AND `due_date` < today AND (`planned_amount` − Σ collections linked by `payment_plan_item_id`) > 0, over P. Count and remaining amount.
- **overdue_sales_invoices:** `invoice_type` = 'sales' AND status IN ('issued','sent') AND `due_date` < today, over P.
- **trend_6m:** `generate_series(@trend_start, @month_start, '1 month')` × the currencies present, LEFT JOIN monthly sums (the same sources as `month.*`); empty months give 0.
- **Currency set** = currencies of P ∪ currencies with month movements. Sort: primary first, then by portfolio_value DESC.

**offers**
- Scope: `offers` o with `organization_id` = org AND `is_passive` = false, ⋈ `offer_revisions` r ON r.id = o.current_revision_id. Status strings are passed as parameters from the `domain.OfferStatus*` constants (never typed into the SQL).
- **draft** / **awaiting_customer** = o.status taslak / gönderildi, with Σ r.grand_total by r.currency.
- **Decisions:** `decided_at` = max(e.created_at) over `offer_events` e where e.offer_id = o.id AND e.revision_id = o.current_revision_id AND (e.event_type IN ('customer_accepted','customer_rejected') OR (e.event_type = 'offer_updated' AND COALESCE(e.metadata->>'to_status', o.status) = o.status)), for o.status IN (kabul edildi, reddedildi).
- **accepted_90d / rejected_90d** = decided_at ≥ d90_start_ts. **conversion_rate_90d_pct** = accepted / (accepted + rejected) × 100.
- **expiring_within_7d** = gönderildi AND r.valid_until BETWEEN today AND today+6.
- **expired_awaiting** = gönderildi AND valid_until < today.
- **viewed_by_customer_7d** = count DISTINCT offers with a `customer_viewed` event at or after d7_start_ts.
- **accepted_not_converted** = kabul edildi AND NOT EXISTS (projects p WHERE p.source_offer_id = o.id).
- **total_active** = count of non-passive offers.

**procurement** (⋈ ap non-cancelled)
- **purchase_requests:** counts of 'draft' and 'submitted'. `purchase_request_approval` amount = `estimated_total` in the project currency; oldest = `submitted_at`.
- **rfqs:**
  - `issued` = count;
  - `awaiting_award` = issued AND `due_date` < today AND EXISTS `supplier_quotations` (rfq_id);
  - `past_due_no_quote` = issued AND due < today AND NOT EXISTS.
- **purchase_orders:**
  - `draft`;
  - `approved_open` = 'approved' (closed is excluded);
  - `late_delivery` = 'approved' AND `expected_delivery_date` < today.
- **approved_this_month** = `approved_at` in month bounds, Σ total by currency.

**subcontracts** (⋈ ap non-cancelled)
- **active_count** = `project_subcontracts` with status 'active'.
- **current_value** = the `new_sc_value` formula (status NOT IN draft, cancelled).
- **paid_to_date / paid_pct** (only if subcontract_payments.read) = non-void `subcontract_payments`.
- **claims** (only if subcontract_claims.read):
  - `submitted` = status 'submitted', Σ `net_payable`;
  - `certified_unpaid` (also needs payments.read) = status 'certified' AND `net_payable` − Σ non-void payments with `progress_claim_id` > 0.
- **change_orders_submitted** = `subcontract_change_orders` with status 'submitted', Σ amount.

**cost_control** (⋈ ap open)
- **budgets** (budget.read): per open project, the `project_budgets` row status; none = no row.
- **pending_adjustments** (budget.read) = `project_budget_adjustments` with status 'draft'.
- **committed_active** (cost_control.read) = Σ `committed_amount` of `project_commitments` with status 'active', by currency.
- **over_budget** (cost_control.read): reuse the CTEs of `GetProjectCostControlSummary` (`cost_control.sql:356+`), grouped by project, for baselined budgets:
  - revised = original lines + approved adjustments;
  - actual = non-void expenses with `budget_line_id`;
  - over when actual > revised > 0;
  - `overrun_pct` = (actual − revised) / revised × 100.
- **Attention `active_without_budget`** = active projects with no baselined budget.

**tasks** (⋈ ap non-cancelled)
- **mine:** employee via `employees.user_id` = viewer AND org (as in `ListMyTasks`); `linked_employee` = employee found.
  - Open = status IN (todo, in_progress); overdue = open AND due < today; due_today = due = today.
  - Items: overdue first, then `due_date` ASC NULLS LAST; limit 5.
- **team:** open, overdue, due_today, unassigned (open AND `assigned_employee_id` IS NULL), completed_7d (`completed_at` ≥ d7_start_ts).

**users**
- Users of the org with `deleted_at` IS NULL.
- active / inactive by `is_active`.
- `never_logged_in` = active AND `last_login_at` IS NULL.
- `restricted_without_project` = active users whose role code NOT IN (owner, admin, legacy_user) AND no `project_users` row.
- `without_employee_link` = active users with no `employees.user_id` link.
- `by_role` via `organization_roles` (code, name).
- `with_personal_overrides` (only if organization.roles.read) = count DISTINCT user_id in `user_permission_overrides` among active users.

### 4.6 Core SQL patterns (sqlc)

```sql
-- Every project-scoped query:
WITH ap AS (
  SELECT p.* FROM projects p
  WHERE p.organization_id = @org_id
    AND (sqlc.narg('restrict_to_user_id')::uuid IS NULL OR EXISTS (
         SELECT 1 FROM project_users pu
         WHERE pu.project_id = p.id AND pu.user_id = sqlc.narg('restrict_to_user_id')::uuid))
)

-- name: DashboardFinanceByCurrency :many
WITH ap AS (...),
pn AS (SELECT * FROM ap WHERE status <> 'cancelled'),
co AS (SELECT project_id,
         COALESCE(sum(grand_total) FILTER (WHERE change_type='addition'  AND status='approved'),0)
       - COALESCE(sum(grand_total) FILTER (WHERE change_type='deduction' AND status='approved'),0) AS net
       FROM project_change_orders WHERE organization_id=@org_id AND project_id IN (SELECT id FROM pn)
       GROUP BY project_id),
coll AS (SELECT project_id, sum(amount) AS total FROM project_collections
         WHERE organization_id=@org_id AND voided_at IS NULL AND project_id IN (SELECT id FROM pn) GROUP BY project_id),
cost AS (SELECT project_id, sum(amount) AS total FROM (
           SELECT project_id, amount FROM project_expenses WHERE organization_id=@org_id AND voided_at IS NULL
           UNION ALL SELECT project_id, amount FROM project_subcontractor_payments WHERE organization_id=@org_id AND voided_at IS NULL
           UNION ALL SELECT project_id, amount FROM subcontract_payments WHERE organization_id=@org_id AND voided_at IS NULL) x
         WHERE project_id IN (SELECT id FROM pn) GROUP BY project_id),
per AS (SELECT pn.id, pn.currency, (pn.contract_amount + COALESCE(co.net,0)) AS current_value,
               COALESCE(coll.total,0) AS collected, COALESCE(cost.total,0) AS realized
        FROM pn LEFT JOIN co ON co.project_id=pn.id LEFT JOIN coll ON coll.project_id=pn.id
        LEFT JOIN cost ON cost.project_id=pn.id)
SELECT currency,
  sum(current_value)::numeric(18,2)                              AS portfolio_value,
  sum(collected)::numeric(18,2)                                  AS collected_total,
  sum(GREATEST(current_value - collected, 0))::numeric(18,2)     AS open_receivable,
  sum(realized)::numeric(18,2)                                   AS realized_cost,
  CASE WHEN sum(current_value) > 0
       THEN round(sum(collected) / sum(current_value) * 100, 1) END AS collection_pct
FROM per GROUP BY currency;
-- (legacy project_subcontractor_payments: if the table lacks organization_id, filter via project_id IN pn only)

-- Month flows / trend: one query, all ap statuses, keyed by (currency, month):
--   SELECT ap.currency, date_trunc('month', received_date)::date AS m, sum(amount) ... WHERE received_date >= @trend_start AND received_date < @next_month_start
--   UNION ALL expenses (expense_date) / both payment tables (paid_date) with a kind column,
--   then Go (or an outer SELECT over generate_series) pivots into 6 rows per currency.

-- Attention groups: one aggregate query + one LIMIT-3 records query per code, e.g.
-- name: DashboardPurchaseRequestsSubmitted :many   (aggregate)
WITH ap AS (...)
SELECT ap.currency, count(*) AS cnt, sum(pr.estimated_total)::numeric(18,2) AS amount,
       min(pr.submitted_at) AS oldest_at
FROM purchase_requests pr JOIN ap ON ap.id = pr.project_id AND ap.status <> 'cancelled'
WHERE pr.organization_id = @org_id AND pr.status = 'submitted' GROUP BY ap.currency;
-- name: DashboardPurchaseRequestsSubmittedTop :many  (records)
... SELECT pr.id, pr.project_id, pr.pr_no, pr.title, ap.name, pr.estimated_total, ap.currency, pr.submitted_at
    ... ORDER BY pr.submitted_at ASC LIMIT 3;
```

- `oldest_days` is computed in Go as `today − oldest_at` (Istanbul date).
- `days` for due-based codes is computed in SQL as `@today::date − due_date`.

### 4.7 Agenda builder (pure Go, `dashboard_agenda.go`)

- **Input:** a list of `rawGroup{code, count, amounts, oldestAt, items}` from the successful sections, plus `authz` and `clock`.
- **Steps:**
  1. Look up `AttentionRules[code]`.
  2. Evaluate the visible gate (it should already hold, since the builder ran).
  3. Evaluate the act gate, giving lane `mine`, `watching` or dropped.
  4. Set severity from the rule.
  5. Rank (§3.1).
  6. Compute `mine_count`, `mine_danger_count` and `watching_count`.
- **Special case:** for `offer_accepted_not_converted` records, `ref.action` = "convert" only when projects.create is held; otherwise "open".
- **Upcoming:** merge, sort, cap at 8.

### 4.8 Per-section permission summary (what each default role receives)

| Role | Sections returned |
|---|---|
| owner / admin | all 20; `onboarding` only in a new company |
| legacy_user | projects, finance, change_orders, offers, tasks, operations, attendance, customers, calculations, suppliers?/cost_codes? (per its role_permissions), notifications, activity. **Not** users (not coarse admin). |
| project_manager | projects, tasks, operations, contracts, procurement, subcontracts (+claims), cost_control, customers, products, calculations, suppliers, cost_codes, notifications, activity |
| finance | projects, finance, change_orders, contracts, procurement, subcontracts (+claims, payments), cost_control, suppliers, cost_codes, notifications, activity |
| field | projects, tasks, operations, attendance, notifications, activity |

A per-person override (grant or revoke) changes the set, because gates read the effective permission set.

### 4.9 Activity permission map (fail-closed; every type is listed in `domain.ActivityEventPermissions`)

- **projects.read:** project_created, project_updated, project_status_changed.
- **projects.finance.read:**
  - collection_received, collection_voided;
  - expense_added, expense_updated, expense_voided;
  - payment_plan_created, payment_plan_updated, payment_plan_cancelled;
  - invoice_created, invoice_status_changed;
  - subcontractor_added, subcontractor_updated, subcontractor_payment_added, subcontractor_payment_voided (legacy);
  - change_order_* (created, updated, sent, viewed, approved, rejected, cancelled, superseded, email_sent, email_failed).
- **projects.procurement.read:** purchase_request_*, purchase_order_*, rfq_*, quotation_*.
- **projects.budget.read:** budget_*, budget_adjustment_*, budget_line_*, wbs_*.
- **projects.cost_control.read:** commitment_*, forecast_updated.
- **projects.contracts.read:** contract_*.
- **projects.subcontracts.read:** subcontract_created / updated / activated / completed / cancelled / terminated, subcontract_change_order_*.
- **projects.subcontract_claims.read:** subcontract_progress_claim_*.
- **projects.subcontract_payments.read:** subcontract_payment_made, subcontract_payment_void.
- **projects.tasks.read:** task_created, task_updated, task_assigned, task_completed.
- **projects.operations.read:** schedule_*, member_assigned, member_removed, file_uploaded, file_removed, photo_uploaded, photo_removed, note_added.
- **Offer events (offers.read):** offer_created, revision_sent, customer_viewed, customer_accepted, customer_rejected, offer_cancelled, project_created.
- **Anything unmapped is excluded.**

**Query:** `project_events` ⋈ ap with `event_type = ANY(@allowed_types)`, ORDER BY `created_at` DESC LIMIT 10. Plus `offer_events` (offers.read, limited types, non-passive offers) LIMIT 10. Merge in Go and take 10. Select `event_type`, ids, `users.full_name`, `created_at` **only; never metadata**.

**Unit test:** iterate all `domain.Event*` constants for project events and assert that each is either mapped or explicitly excluded.

### 4.10 Handler

```go
func (h *DashboardHandler) Get(w http.ResponseWriter, r *http.Request) {
  orgID, _ := middleware.OrganizationIDFromContext(r.Context())
  authz, _ := middleware.AuthzContextFromRequest(r.Context())
  role, _ := middleware.RoleFromContext(r.Context())
  res, err := h.svc.Get(r.Context(), service.DashboardInput{OrganizationID: orgID, UserID: authz.UserID,
      CoarseRole: role, Authz: authz, Now: time.Now()})
  // err → 500 with the house error JSON; else 200 writeJSON(res)
}
```

- Response headers: `Cache-Control: no-store`.
- Target: p95 < 300 ms on 200 projects; response about 15–40 KB.

### 4.11 Backend tests

**1. Security** — `internal/httpapi/middleware/dashboard_security_test.go`. Uses the harness from `tasks_mine_security_test.go` (`setupRBACTestRouter`, `mustCreateReadyOrg`, `mustCreateRoleUser`, `mustCreateProject`, `rbacDo`), with the dashboard handler added to the deps.
1. No token → 401.
2. Super Admin → 403 `tenant_context_required`.
3. Owner → the section key set equals all 20.
4. Field, member of 1 of 2 projects:
   - `projects.counts.total == 1`;
   - team tasks count only the member project;
   - the keys `finance`, `offers`, `procurement`, `users` are absent;
   - every `projects.top[*].collection_pct` / `current_value` is null;
   - no agenda group has module ∉ visible sections;
   - `team_task_*` are absent (no tasks.create).
5. Project manager:
   - no `finance`, `change_orders`, `offers`, `attendance`, `employees`;
   - a submitted PR shows as `purchase_request_approval` with lane `watching`.
6. Finance:
   - no `tasks` key, and no `/tasks/mine`-equivalent query error;
   - a submitted PR is in lane `mine`.
7. Overrides:
   - granting `offers.read` to field adds `offers`;
   - revoking `projects.finance.read` from finance removes `finance`, `change_orders` and `plan_item_overdue`.
8. Cross-tenant: org B projects, offers and users never change org A counts.
9. `FailSection("procurement")` for an owner → `section_errors == {"procurement": "section_failed"}` and the other sections are intact. The same failure for a field user → `section_errors` is empty.
10. Users: deleted users (`deleted_at`) are not counted; a non-admin with `organization.users.read` via override gets no `users` key.
11. Activity: a field member never receives `collection_received` for their own project.
12. `/dashboard/project-options`: the field user sees only member projects, and the response has no money keys.

**2. Service and SQL** — `internal/service/dashboard_*_test.go`, against the dev DB like the other service tests.
- **Clock:** `Now = 2026-09-30T21:30Z` gives today = 2026-10-01 and month_start = 2026-10-01; the trend covers 2026-05 … 2026-10; `is_workday` is false on Sunday.
- **Finance:**
  - receivable is clamped per project;
  - cancelled projects are excluded from portfolio and receivable but included in month flows;
  - a voided collection is excluded;
  - a due_date equal to today is **not** overdue;
  - both payment tables count toward `realized_cost`.
- **Offers:**
  - `is_passive` is excluded;
  - the 90-day decision uses the event date (an old `offer_date` with a recent `customer_accepted` counts);
  - an internal accept with `to_status` metadata counts.
- **Agenda:**
  - a table-driven test over `AttentionRules` × role permission sets → lane;
  - ranking order;
  - `items` capped at 3;
  - `upcoming` capped at 8 and sorted.
- **Contract:** each `docs/dashboard/fixtures/*.json` file decodes into `domain.Dashboard` with `json.Decoder.DisallowUnknownFields()`. This catches drift between the fixtures and the Go structs.

---

## 5. (B) Web (Next.js 16 App Router, Tailwind v4)

### 5.1 Files

**Create:**

| Path | Kind | Purpose |
|---|---|---|
| `lib/dashboard.ts` | pure TS | API types (§4.4); `MODULES` registry; `BANDS`; `predictSections(user)`; `pickKpis(data)`; `secondaryPanel(data)`; `visibleModules(data, onboardingActive)`; `layoutBands(...)`; `spanClass(i, n)`; `compactSpanClass(i, n)`; `kpiGridClass(n)`; `moduleAttention(data, key)`; `attentionChip(groups)`; `attentionTitle(g)`; `attentionRecordLine(r, code)`; `upcomingLabel(kind)`; `summarySentence(agenda)`; `scopeLine(viewer)`; `webHrefFor(ref)`; `webHrefForActionTarget(path)`; `DASHBOARD_PATH = "/api/v1/dashboard"`; `COPY` (§7) |
| `lib/dashboard.test.mts` | node test | see §5.10 |
| `lib/format.test.mts` | node test | new format helpers |
| `lib/events.ts` | pure TS | `PROJECT_EVENT_LABELS` (moved verbatim from `app/(app)/projeler/[id]/ProfitabilitySection.tsx:58`) + `OFFER_EVENT_LABELS` (from `app/(app)/teklifler/[id]/ActivityTimeline.tsx`) + `eventLabel(source, type)`, with fallback "Kayıt güncellendi" |
| `lib/nav-icons.ts` | pure TS | the `ICONS` map moved out of `components/layout/NavLinks.tsx` (a "use client" module) so server components can import it |
| `components/ui/StatCard.tsx` | server-safe | KPI tile |
| `components/ui/ProgressBar.tsx` | server-safe | `{pct, tone: "success"\|"gold"\|"graphite"\|"danger", label}` |
| `components/ui/SegmentBar.tsx` | server-safe | `{segments: {key, value, tone, label}[], legend?: boolean, ariaLabel}` |
| `components/dashboard/HomeDashboard.tsx` | server | root; props `{user}` |
| `components/dashboard/DashboardHeader.tsx` | server | greeting, date, org, role, `<QuickActions/>` |
| `components/dashboard/QuickActions.tsx` | client | buttons, dropdown, `ProjectPickerModal` |
| `components/dashboard/ProjectPickerModal.tsx` | client | Modal + SearchInput over `/api/v1/dashboard/project-options` |
| `components/dashboard/DashboardBody.tsx` | server | `apiServer` fetch in try/catch; renders `DashboardView` or `DashboardUnavailable` |
| `components/dashboard/DashboardView.tsx` | server | full layout from data |
| `components/dashboard/SummaryLine.tsx` | server + client `RefreshButton` | sentence, scope, "Güncellendi HH:mm", refresh |
| `components/dashboard/RefreshButton.tsx` | client | `router.refresh()` in `useTransition`; icon spins while pending (`motion-reduce:animate-none`) |
| `components/dashboard/KpiRow.tsx` | server | |
| `components/dashboard/AttentionPanel.tsx` | client | lanes, disclosure, show-all |
| `components/dashboard/CashFlowPanel.tsx` + `charts/PairedBars.tsx` | server | |
| `components/dashboard/MyTasksPanel.tsx` | server | |
| `components/dashboard/ModuleBands.tsx` | server | bands, grid, density |
| `components/dashboard/ModuleCard.tsx`, `CompactModuleCard.tsx`, `AttentionFooter.tsx` | server | shared anatomy |
| `components/dashboard/modules/{Finance,Offers,ChangeOrders,Projects,Tasks,Operations,Contracts,Attendance,Procurement,Subcontracts,CostControl,Customers,Employees,Products,Users,Calculations,Suppliers,CostCodes}Card.tsx` | server | one per module; each returns `null` when its key is absent |
| `components/dashboard/ProjectModulesPlaceholder.tsx` | server | onboarding |
| `components/dashboard/OnboardingChecklist.tsx` | client | hide with localStorage |
| `components/dashboard/NotificationsPanel.tsx` | client | mark all read (`apiClient POST /api/v1/notifications/read-all`, then `router.refresh()`) |
| `components/dashboard/ActivityPanel.tsx` | server | |
| `components/dashboard/SectionError.tsx` | client | "Tekrar dene" → `router.refresh()` |
| `components/dashboard/DashboardUnavailable.tsx` | server | error card + Kısayollar |
| `components/dashboard/DashboardSkeleton.tsx` | server | |
| `components/dashboard/module-icons.ts` | pure | ModuleKey → lucide icon |

**Modify:**
- `app/(admin)/admin/page.tsx` → `const user = await requireAdminRole(); return <HomeDashboard user={user} />;` plus `export const metadata = { title: "Ana Sayfa" }`.
- `app/(panel)/panel/page.tsx` → `const user = await getCurrentUser(); if (!user) redirect("/giris"); return <HomeDashboard user={user} />;` plus the same metadata.
- `lib/auth.ts` → `export const getCurrentUser = cache(async (): Promise<User | null> => { …unchanged body… })`, with `import { cache } from "react"`.
- `app/(app)/projeler/[id]/page.tsx` → add `searchParams: Promise<{ tab?: string }>`. Validate against `["genel","finans","maliyet","satinalma","operasyon","dosyalar","aktivite"]`; else `"genel"`. Pass the result as `defaultTab`.
- `lib/format.ts` → add `formatCompactMoney`, `formatSignedCompactMoney`, `formatPercent` (moved here; `lib/price-sources.ts` re-exports it), `formatRelativeTime(ts, nowIso)`, `formatLongDate(isoDate)`, `formatShortDate(isoDate)`, `formatAgeDays(n)`, `formatHm(ts)`. All use the `tr-TR` locale and `timeZone: "Europe/Istanbul"` where a time is involved.
- `components/layout/NavLinks.tsx`, `ProfitabilitySection.tsx`, `ActivityTimeline.tsx` → import from `lib/nav-icons.ts` / `lib/events.ts`.
- `components/ui/DropdownMenu.tsx` → `DropdownMenuItem` accepts an optional `className`.
- `app/globals.css`:
  - add to `:root`: `--color-chart-in: var(--color-success); --color-chart-out: var(--color-graphite); --color-track: var(--color-surface-hover);`
  - add the same three to `@theme inline`;
  - add W0 (below).
- **W0 (small shell fix, phone-width web):**
  - add the class `sidebar-label` to the label or brand elements that `Sidebar.tsx`, `NavLinks.tsx`, `LogoutButton.tsx` and `SidebarCollapseToggle.tsx` already hide when collapsed;
  - add to `globals.css`: `@media (max-width: 767px) { .app-sidebar { width: var(--sidebar-width-collapsed); } .app-sidebar .sidebar-label { display: none; } }`;
  - also centre the icons there, matching the collapsed styles.
  - The dashboard itself works down to 260px of content without W0; W0 only makes phones usable.

### 5.2 Component tree

```
HomeDashboard (server)
└ <div class="@container">
  ├ DashboardHeader                           ← instant (only /auth/me)
  │   h1 "Merhaba, {ad}" · p "{formatLongDate(istanbulToday)} · {organization_name} · {userRoleLabel(user)}"
  │   QuickActions (client)
  └ <Suspense fallback={<DashboardSkeleton plan={predictSections(user)} />}>
      DashboardBody (server; never throws)
      └ DashboardView | DashboardUnavailable
          ├ SummaryLine (sentence · scope · Güncellendi 09:41 · RefreshButton)
          ├ onboarding ? OnboardingChecklist : KpiRow
          ├ !onboarding && TopRow: AttentionPanel + (CashFlowPanel | MyTasksPanel)?
          ├ ModuleBands → band <section> → grid → *Card / CompactModuleCard / ProjectModulesPlaceholder
          └ Akış row: ActivityPanel (if items) + NotificationsPanel (if section)
```

- **`DashboardBody` error handling:**
  ```ts
  try { data = await apiServer<DashboardResponse>(DASHBOARD_PATH, cookieHeader) }
  catch { return <DashboardUnavailable user={user}/> }
  ```
  If `data.onboarding` is set, `OnboardingChecklist` (client) reads localStorage after mount. Before mount it renders the checklist, to avoid hydration mismatch. If the flag is found, it calls a local `setHidden(true)` that swaps to the normal layout (the normal layout is rendered as a hidden sibling and toggled). **Simpler alternative, allowed:** in onboarding mode, always render the checklist and put the "Gizle" behaviour inside the checklist only; it collapses to a one-line "Kurulum rehberi gizlendi · Göster" bar. **Use this simpler alternative.**

### 5.3 Layout tiers (container queries on the root, because the sidebar width varies)

| Tier | Container width | Typical viewport × sidebar | Padding | KPI | Top row | Standard module grid | Compact | Akış |
|---|---|---|---|---|---|---|---|---|
| T1 | < 42rem (672px) | phone, or 768 expanded (528px) | `p-4` | 1 col (< 22rem) / 2 cols | stacked: Dikkat, then secondary | 1 col | 1 col | stacked |
| T2 | `@2xl` ≥ 42rem | 768 collapsed (696), 1024 expanded (784) | `@2xl:p-6` | 2×2 (n=3: 3 cols) | stacked | 2 cols | 2 cols (`@xl`) | stacked |
| T3 | `@4xl` ≥ 56rem | 1024 collapsed (952), 1280 expanded (1040) | `@4xl:p-8` | 4 cols | 12-col: Dikkat 7 / secondary 5 | 3 cols | 3 cols | 7 / 5 |
| T4 | `@6xl` ≥ 72rem | 1440 expanded (1200), 1440 collapsed (1368), 1920 | same | 4 cols | Dikkat 8 / secondary 4 | 3 cols | 3 cols | 8 / 4 |

- **Inner wrapper:** `mx-auto flex w-full max-w-[96rem] flex-col gap-6 p-4 @2xl:p-6 @4xl:p-8`.
- **Header wrapper:** the same horizontal padding, with `border-b border-border py-5`.
- DOM order equals visual order at every tier: Dikkat is always first and on the left.

### 5.4 Grid class rules (static literals in `lib/dashboard.ts`; Tailwind v4 scans `lib/`)

- **KPI row** (`kpiGridClass(n)`):
  - n=4: `grid grid-cols-1 gap-3 @min-[22rem]:grid-cols-2 @4xl:grid-cols-4 @4xl:gap-4`
  - n=3: `grid grid-cols-1 gap-3 @min-[22rem]:grid-cols-2 @2xl:grid-cols-3 @4xl:gap-4 @min-[22rem]:[&>*:last-child]:col-span-2 @2xl:[&>*:last-child]:col-span-1`
  - n=2: `grid grid-cols-1 gap-3 @min-[22rem]:grid-cols-2 @4xl:gap-4`
  - n<2: the row is not rendered.
- **Top row:** `grid grid-cols-1 gap-4 @4xl:grid-cols-12`.
  - With a secondary panel: Dikkat `@4xl:col-span-7 @6xl:col-span-8`, secondary `@4xl:col-span-5 @6xl:col-span-4`.
  - Without one: Dikkat `@4xl:col-span-12`, and its lanes go into 2 internal columns (`@container/dikkat` → `@3xl/dikkat:grid-cols-2`: Senin sıran | Takipte + Yaklaşan).
- **Standard band grid:** `grid grid-cols-12 gap-3 @4xl:gap-4`. `spanClass(i, n)` = `"col-span-12 " + t2 + " " + t3`, where:
  - t2 = (n % 2 === 1 && i === n - 1) ? `@2xl:col-span-12` : `@2xl:col-span-6`
  - r = n % 3; t3 = (r === 1 && i === n - 1) ? `@4xl:col-span-12` : (r === 2 && i >= n - 2) ? `@4xl:col-span-6` : `@4xl:col-span-4`
- **Compact grid:** same function, with `@xl` (2 cols) and `@4xl` (3 cols): `compactSpanClass`.
- **Wide mode is pure CSS.**
  - Every card is `@container/card`.
  - The body switches to `@3xl/card:grid @3xl/card:grid-cols-[minmax(0,5fr)_minmax(0,7fr)] @3xl/card:gap-6` (metrics on the left, list on the right).
  - List limits become 5 rows via `@3xl/card:` visibility. Render 5 rows; rows 4–5 have `hidden @3xl/card:flex`.
- **Density mode:** `standardCount <= 5 || onboardingActive` → one `<section>` with h2 "Bölümler", one grid, compact cards after.

### 5.5 Wireframes

**T3: owner, 1280 × expanded sidebar (container ≈ 1040px)**
```
┌────────────┬──────────────────────────────────────────────────────────────────────────────────────┐
│▌ARVEND YAPI│ [Ara… (yakında)]                                         🔔   Taha Eryetişözen       │
│ Yönetim S. │                                                                Sahip · Arvend Yapı   │
│            ├──────────────────────────────────────────────────────────────────────────────────────┤
│▣ Ana Sayfa │ Merhaba, Taha                      [+ Yeni Teklif] [Tahsilat Gir] [Masraf Gir] [⋯]    │
│□ Teklifler │ 28 Eylül 2026, Pazartesi · Arvend Yapı · Sahip                                        │
│□ Projeler  ├──────────────────────────────────────────────────────────────────────────────────────┤
│□ Mesai     │ Bugün 7 iş senin sıranda; 3 tanesi acil.                    Güncellendi 09:41  [↻]    │
│□ Müşteriler│ ┌AÇIK ALACAK ─────[▢]┐┌BU AY NET NAKİT ─[▢]┐┌TEKLİF HATTI ────[▢]┐┌PROJE NAKİT DENGESİ▢┐│
│□ Ürünler   │ │5,1 Mn TL           ││+420.000 TL         ││2,3 Mn TL           ││+2,2 Mn TL          ││
│□ …         │ │▓▓▓▓▓▓▓▓▓░░░░░░░    ││Giriş 950.000 TL    ││5 teklif yanıt      ││Tahsilat 7,4 Mn TL  ││
│            │ │%59 tahsil edildi   ││Çıkış 530.000 TL    ││bekliyor · %62,5    ││Harcama 5,2 Mn TL   ││
│            │ └────────────────────┘└────────────────────┘└────────────────────┘└────────────────────┘│
│            │ ┌DİKKAT GEREKTİRENLER ────────────── [7] ┐┌NAKİT AKIŞI · SON 6 AY ─────────────────┐ │
│            │ │SENİN SIRAN · 7                          ││1,2 Mn ┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄  │ │
│            │ │▌⚠ 4 ödeme planı kaleminin vadesi     ▾ ││             ▇            █          │ │
│            │ │▌  geçti · 850.000 TL · en eski 21 gün   ││600.000 ▇▅ ▆▃ ▅▄ ▇▆ ▆▅ █▄               │ │
│            │ │▌☑ 3 satın alma talebi onay bekliyor  ▾ ││0 ─────────────────────────────────    │ │
│            │ │▌  145.000 TL · en eski 4 gün            ││   Nis May Haz Tem Ağu [Eyl]            │ │
│            │ │▌☑ 1 taşeron hakedişi onay bekliyor   › ││   ■ Tahsilat  ■ Çıkış                  │ │
│            │ │▌  HK-004 · Kadıköy · 90.000 TL          ││BU AY                                   │ │
│            │ │TAKİPTE · 2                              ││Tahsilat           +950.000,00 TL       │ │
│            │ │▌⧗ 2 ek iş müşteri onayında · 180.000 ▾ ││Masraf             -310.000,00 TL       │ │
│            │ │YAKLAŞAN · 14 GÜN                        ││Taşeron ödemesi    -220.000,00 TL       │ │
│            │ │ 30  Ödeme planı · 3. Hakediş · 250.000  ││─────────────────────────────────       │ │
│            │ │ EYL Ataşehir Konut B                    ││Net                +420.000,00 TL       │ │
│            │ │ 02  Teklif süresi doluyor · TKL-0102    │└────────────────────────────────────────┘ │
│            │ │ EKİ Demir Yapı A.Ş.                     │                                           │
│            │ │               Tümünü göster (12) ▾      │                                           │
│            │ └─────────────────────────────────────────┘                                           │
│            │ NAKİT & SATIŞ ─────────────────────────────────────────────────────────────────────── │
│            │ ┌[▤] Proje Finansı [1 UYARI]    Aç↗┐┌[▤] Teklifler [1 UYARI]   Aç↗┐┌[▤] Ek İşler [2 TAKİPTE] Aç↗┐│
│            │ │PORTFÖY DEĞERİ                   ││YANIT BEKLEYEN                ││MÜŞTERİ ONAYINDA             ││
│            │ │12,5 Mn TL                       ││2,3 Mn TL · 5 teklif          ││2 · 180.000 TL               ││
│            │ │▓▓▓▓▓▓▓▓▓░░░░░ %59 tahsil edildi ││Taslak 3 · İnceledi 3 · %62,5 ││Taslak 1 · 40.000 TL         ││
│            │ │Tahsil 7,4 Mn  Alacak 5,1 Mn     ││SON 90 GÜN ▓▓▓▓▓▓▓▒▒▒▒         ││Bu ay onaylanan +95.000 TL   ││
│            │ │Harcanan 5,2 Mn                  ││● Kabul 5  ● Red 3            ││                             ││
│            │ ├─────────────────────────────────┤├──────────────────────────────┤├─────────────────────────────┤│
│            │ │⚠ 4 ödeme planı kaleminin v… ›   ││⚠ 1 teklifin süresi doldu… ›  ││⧗ 2 ek iş müşteri onayında › ││
│            │ └─────────────────────────────────┘└──────────────────────────────┘└─────────────────────────────┘│
│            │ PROJE & SAHA ─────────────────────────────────────────────────────────────────────── │
│            │ [Projeler: status bar + 3 rows]  [Görevler: counts + 3 tasks]  [Şantiye: 4 stats]    │
│            │ [Sözleşmeler (6/12)]                              [Mesai / Puantaj (6/12)]            │
│            │ TEDARİK & MALİYET ─────────────────────────────────────────────────────────────────── │
│            │ [Satın Alma: flow row]           [Taşeron: paid bar]           [Bütçe & Maliyet]      │
│            │ FİRMA KAYITLARI ───────────────────────────────────────────────────────────────────── │
│            │ [Müşteriler]                     [Personel]                    [Ürünler & Zam]        │
│            │ [Ekip ── wide: stats left │ role chips + "Projesi olmayan 2" line right ──────────]   │
│            │ [▢ Metraj · 12 grup · 95 kategori ↗][▢ Tedarikçiler · 44 aktif ↗][▢ Maliyet Kodları ↗]│
│            │ ┌SON HAREKETLER ──────────────────────────────┐┌BİLDİRİMLER ─── 4 okunmamış ──┐     │
│            │ │● Ayşe K. · Sipariş onaylandı · PRJ-0007 2 sa ││● Hakediş onaya gönderildi 2 sa│     │
│            │ │● Mehmet D. · Fotoğraf eklendi · PRJ-0011 dün ││● Talep onaylandı          dün │     │
│            │ │  … (10)                                      ││[Tümünü okundu say]            │     │
│            │ └──────────────────────────────────────────────┘└───────────────────────────────┘     │
└────────────┴──────────────────────────────────────────────────────────────────────────────────────┘
Legend: ▌ 3px severity bar; ⚠ TriangleAlert (danger); ☑ ClipboardCheck (action, gold icon); ⧗ Hourglass (info)
```

**Projeler card (standard; wide mode moves the list to the right and shows 5 rows)**
```
┌[▦] Projeler                [1 UYARI]  Aç ↗┐
│AKTİF PROJE                                │
│7   toplam 23                              │
│░░▓▓▓▓▓▓▓▒████████████  (status bar)       │
│● Planlandı 2 ● Devam 7 ● Beklemede 1 ● Tamamlandı 12 · İptal 1 │
│Kadıköy Ofis Bloğu          [DEVAM EDİYOR] │
│PRJ-2026-0004 · 13 gün gecikti             │
│Süre █████████ %100 Görev ██████░ %71      │
│Tahsilat ████░░░░ %41                      │
│… 2 more rows                              │
├───────────────────────────────────────────┤
│⚠ 2 projenin bitiş tarihi geçti         ›  │
└───────────────────────────────────────────┘
```

**T2 (1024 × expanded, ≈ 784px) and T1 (phone web with W0, ≈ 318px)**
```
T2                                               T1
Merhaba, Taha        [+ Yeni Teklif] [Tahsilat] [⋯]   Merhaba, Taha
28 Eylül 2026, Pazartesi · Arvend Yapı · Sahip       28 Eylül 2026, Pazartesi · Sahip
Bugün 7 iş senin sıranda; 3 tanesi acil.  09:41 ↻    [+ Yeni Teklif] [⋯]
┌AÇIK ALACAK──────┐┌BU AY NET NAKİT──┐               Bugün 7 iş senin sıranda…  ↻
┌TEKLİF HATTI─────┐┌PROJE NAKİT DEN.─┐               ┌AÇIK ALACAK──┐┌NET NAKİT───┐
┌DİKKAT GEREKTİRENLER (full width)──────┐           ┌TEKLİF HATTI─┐┌NAKİT DENG.─┐
┌NAKİT AKIŞI (chart, breakdown below)───┐           ┌DİKKAT (1 col)───────────┐
NAKİT & SATIŞ                                        ┌NAKİT AKIŞI (h-36)───────┐
[Proje Finansı]      [Teklifler]                     NAKİT & SATIŞ
[Ek İşler ── wide, full row ──────────]              [Proje Finansı] [Teklifler] … 1 col
```

### 5.6 Exact classes and tokens

- **Focus ring constant** (every interactive element): `focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-gold`. No focus-visible style exists in the codebase today; add it everywhere on the dashboard.
- **Header:**
  - h1: `text-xl font-bold tracking-tight text-balance`
  - meta line: `text-sm text-text-muted`
- **Summary line:**
  - sentence: `text-sm text-text`
  - scope line: `text-xs text-text-muted`
  - "Güncellendi 09:41": `text-xs text-text-muted tabular-nums`
  - refresh: `IconButton label="Yenile"` with `RefreshCw size={16}`
- **StatCard (KPI):**
  - root: `group flex min-h-28 min-w-0 flex-col gap-1.5 rounded-lg border border-border bg-surface px-4 py-3.5`. As a Link, add `hover:bg-surface-hover/60` + focus ring.
  - label: `text-xs font-semibold uppercase tracking-widest text-text-muted`
  - value: `text-xl @4xl:text-2xl font-bold tracking-tight tabular-nums`. Tones: `text-success` / `text-danger` only for a signed value, and always with a sign. Full value in `title`, plus an sr-only `aria-label`.
  - sub: `text-xs text-text-muted truncate`
  - icon: lucide 16 / 1.75, `text-text-muted`, at the top right.
- **Panels** (Dikkat, Nakit, Görevlerim, Akış): `rounded-lg border border-border bg-surface min-h-[17.5rem]`.
  - header `flex items-center justify-between border-b border-border px-4 py-3 @4xl:px-5`
  - title: house label style
  - count Badge
- **Dikkat group row:**
  - row: `relative flex min-h-11 items-start gap-3 px-4 py-2.5 hover:bg-gold-soft/30`
  - severity bar: `absolute inset-y-2 left-0 w-[3px] rounded-r-sm bg-danger|bg-gold|bg-info`
  - title: `text-sm font-medium text-text`
  - meta: `text-xs text-text-muted tabular-nums`
  - amount: `text-sm font-semibold tabular-nums whitespace-nowrap`
  - disclosure: a `<button aria-expanded aria-controls>` with ChevronDown (`transition-transform aria-expanded:rotate-180`, `motion-reduce:transition-none`)
  - expanded records: `<ul class="pl-11 pr-4 pb-2">` of `<Link>` rows (`text-sm`, `min-h-9`)
  - "+{n} daha" link to the module's web link.
- **Lane headings** (SENİN SIRAN · n / TAKİPTE · n / YAKLAŞAN · 14 GÜN): `px-4 pt-3 pb-1 text-[11px] font-semibold uppercase tracking-widest text-text-muted`.
  - Takipte info tooltip via `title`: "Bu işler başka birinin onayını ya da müşteriyi bekliyor."
- **Upcoming row:**
  - date block: `flex w-10 flex-col items-center rounded-md border border-border py-1 text-center`, day `text-sm font-bold tabular-nums`, month `text-[10px] font-semibold uppercase text-text-muted`; "Bugün" block `border-text/40`
  - icon: `CalendarClock 14 text-text-muted`
- **Module card:**
  - `<article id="modul-{key}" class="@container/card flex h-full min-h-52 min-w-0 flex-col rounded-lg border border-border bg-surface">`
  - header `flex items-center gap-3 border-b border-border px-4 py-3 @4xl:px-5`
  - icon tile `flex size-7 shrink-0 items-center justify-center rounded-md bg-surface-hover text-text-muted` (lucide 16/1.75)
  - h3 `min-w-0 flex-1 truncate text-sm font-semibold text-text` containing a Link `hover:text-gold`
  - chip `<Badge tone>`
  - "Aç" `inline-flex items-center gap-1 text-xs font-medium text-text-muted hover:text-gold` + ArrowUpRight 14
  - body `flex flex-1 flex-col gap-3 p-4 @4xl:p-5`
  - primary: label (house label style) + value `text-xl font-bold tabular-nums tracking-tight` + detail `text-xs text-text-muted`
  - stats grid `grid grid-cols-2 gap-x-4 gap-y-3 @md/card:grid-cols-3`: value `text-sm font-semibold tabular-nums`, label `text-xs text-text-muted`
  - footer `mt-auto border-t border-border px-4 py-2.5 @4xl:px-5`: lines `flex min-h-9 items-center gap-2 text-sm` with icon 14 (`text-danger` / `text-gold` / `text-info`) + Link text + ChevronRight 14
  - quiet line: `CircleCheckBig 14 text-success` + `text-xs text-text-muted` "Bekleyen iş yok"
- **Compact card:** `flex min-h-18 items-center gap-3 rounded-lg border border-border bg-surface px-4 py-3` = icon tile + title `text-sm font-semibold` + value `text-sm tabular-nums text-text-muted` + optional note line `text-xs text-text-muted` + ArrowUpRight.
- **Band heading:** `<div class="flex items-center gap-3"><h2 class="text-xs font-semibold uppercase tracking-widest text-text-muted">…</h2><div class="h-px flex-1 bg-border" aria-hidden></div></div>`.
- **ProgressBar:** `<div role="meter" aria-valuemin=0 aria-valuemax=100 aria-valuenow aria-valuetext="Tahsilat yüzde 59" class="h-1.5 w-full overflow-hidden rounded-sm bg-track"><div class="h-full bg-success|bg-gold|bg-graphite|bg-danger" style="width:X%"/></div>`. Values are clamped to 0–100; a value of 0 shows no fill.
- **SegmentBar:** `<div role="img" aria-label="…all segments…" class="flex h-2 w-full gap-px overflow-hidden rounded-sm bg-track">` with segments `style={{flexGrow: v}}` and `min-w-[2px]` when v > 0. The "Girilmedi" segment is `bg-transparent outline-dashed outline-1 outline-border -outline-offset-1`. Legend: `mt-2 flex flex-wrap gap-x-3 gap-y-1 text-xs text-text-muted` with items `inline-flex items-center gap-1.5`, dot `size-2 rounded-sm bg-*`, then "Devam 7" (numbers `tabular-nums`).
- **Tone map:**

  | Tone | Class |
  |---|---|
  | muted | `bg-text-muted/40` |
  | muted-dark | `bg-text-muted/70` |
  | gold | `bg-gold` |
  | success | `bg-success` |
  | danger | `bg-danger` |
  | info | `bg-info` |
  | graphite | `bg-graphite` |
  | ink | `bg-text` |

- **PairedBars** (server SVG):
  - `viewBox="0 0 320 140"`; plot x 44–316, y 8–108.
  - 6 groups of about 45px; 2 bars of 12px each with a 3px gap; `rx=1.5`.
  - `fill-chart-in` (success) for Tahsilat and `fill-chart-out` (graphite) for Çıkış.
  - 3 gridlines at 0, max/2 and max, `stroke-border` 1px dashed "2 3".
  - Y labels: compact without currency, `text-[11px] fill-text-muted`.
  - Month labels (Oca Şub Mar Nis May Haz Tem Ağu Eyl Eki Kas Ara) at y=128; the current month is `font-semibold fill-text`.
  - Max = a nice ceiling on the step ladder 1, 2, 2.5, 5 × 10^k.
  - Each group is `<g tabIndex={0}>` with a `<title>`, e.g. "Eylül 2026 — Tahsilat 950.000,00 TL · Çıkış 530.000,00 TL".
  - The SVG has `role="img"` and an aria-label listing all months. An sr-only `<table>` repeats the data.
  - Height: `h-36 @4xl:h-40`, `w-full`.
- **Currency switch** in the Nakit panel header, only when `by_currency.length > 1`: a small client segmented control (button group `rounded-md border`) over the currencies. No math.

### 5.7 Icons (lucide 16/1.75 in tiles; all names verified in lucide-react 1.46)

| Item | Icon |
|---|---|
| Proje Finansı | Wallet |
| Teklifler | FileText |
| Ek İşler | FilePlus |
| Projeler | Building2 |
| Görevler | ListChecks |
| Şantiye | Construction |
| Sözleşmeler | ScrollText |
| Mesai | Clock |
| Satın Alma | ShoppingCart |
| Taşeron | Handshake |
| Bütçe & Maliyet | Scale |
| Müşteriler | Users |
| Personel | HardHat |
| Ürünler & Zam | Package |
| Ekip | UserCog |
| Metraj | Ruler |
| Tedarikçiler | Truck |
| Maliyet Kodları | Coins |
| Bildirimler | Bell |
| Son Hareketler | History |
| KPI: receivable | Wallet |
| KPI: net_cash | ArrowDownUp |
| KPI: pipeline | FileText |
| KPI: cash_balance | Landmark |
| KPI: active_projects | Building2 |
| KPI: my_tasks | ListChecks |
| KPI: team_overdue | AlarmClock |
| KPI: on_site | HardHat |
| KPI: unread | Bell |
| State: danger | TriangleAlert |
| State: action | ClipboardCheck |
| State: info | Hourglass |
| State: upcoming | CalendarClock |
| State: ok | CircleCheckBig |
| State: error | CircleAlert |
| Controls | ArrowUpRight, ChevronRight, ChevronDown, RefreshCw, MoreHorizontal |

### 5.8 States

- **Loading:**
  - The header and quick actions render immediately.
  - `DashboardSkeleton` uses `predictSections(user)`, the same gates as the server (`canAccess` / `hasPermission`, fail-closed), to draw exactly:
    - the KPI tiles `h-28`;
    - the top-row panels `h-[17.5rem]`;
    - band cards `h-52` and compact `h-18`, using the same grid classes.
  - All placeholders are `Skeleton` blocks (`animate-pulse bg-surface-hover`, `motion-reduce:animate-none`).
  - "0" is never shown while loading.
- **Refresh:** `router.refresh()` in `useTransition`. Content stays and only the icon spins; there is no skeleton flash.
- **Section error** (`section_errors[key]`):
  - the card keeps its header (icon, title, "Aç" link);
  - the body shows `rounded-md bg-danger-soft px-3 py-2 text-sm text-danger` with the text "Bu özet şu an yüklenemedi." and a "Tekrar dene" button that calls `router.refresh()`.
  - KPI tiles whose source failed drop out, and the next candidate fills the slot.
  - The Dikkat footer shows `text-xs text-text-muted`: "Bazı bölümler yüklenemedi; liste eksik olabilir."
- **Whole request failed:**
  - `DashboardUnavailable` shows an ErrorNote card: "Özet yüklenemedi" / "Bağlantını kontrol edip tekrar dene. Modüllere aşağıdaki kısayollardan ulaşabilirsin." and a "Tekrar dene" button.
  - Below it, a **Kısayollar** grid: `getNavItems(user.role, user.permissions)` without home, as tiles `rounded-lg border px-4 py-3` with the icon from `lib/nav-icons.ts` and the label.
- **Empty states:** §7.4.

### 5.9 Accessibility

- Every region is `<section aria-labelledby>`.
- The KPI row has an sr-only h2 "Temel göstergeler". Band headings and panel titles are h2; card titles are h3; the greeting is h1.
- Dikkat lanes are `<ol>`. Groups with one record are a single `<Link>`; groups with more use the disclosure button pattern. Esc does not close the disclosure (it is not a popup).
- There are no whole-card links (they would nest interactive elements). Each card has a header link and footer links.
- Row targets are `min-h-11` at T1.
- Dates use `<time dateTime>`.
- **Contrast:** gold `#b8892a` is never used for text smaller than 18px. It is used only for bars, icons, dots and button backgrounds.
- "Güncellendi" sits in `aria-live="polite"`.

### 5.10 Web tests (`node --test "lib/**/*.test.mts"`)

**`format.test.mts`:**

| Input | Output |
|---|---|
| `formatCompactMoney(850000)` | "850.000 TL" |
| `formatCompactMoney(999999.6)` | "1 Mn TL" |
| `formatCompactMoney(12500000)` | "12,5 Mn TL" |
| `formatCompactMoney(12000000)` | "12 Mn TL" |
| `formatCompactMoney(999960000)` | "1 Mr TL" |
| `formatCompactMoney(1250000000)` | "1,3 Mr TL" |
| `formatCompactMoney(-420000)` | "-420.000 TL" |
| `formatCompactMoney(45000, "USD")` | "45.000 $" |
| `formatSignedCompactMoney(420000)` | "+420.000 TL" |
| `formatPercent(59.0)` | "%59" |
| `formatPercent(62.5)` | "%62,5" |

- `formatRelativeTime` cases: az önce, 12 dk önce, 3 sa önce, dün 17:40, 27.09 14:05, 27.09.2025.
- `formatLongDate("2026-09-28")` = "28 Eylül 2026, Pazartesi".

**`dashboard.test.mts`** (loads `../../docs/dashboard/fixtures/*.json` via `fs` and `import.meta.url`):
- `pickKpis`: owner [receivable, net_cash, pipeline, cash_balance], finance [receivable, net_cash, cash_balance, active_projects], field [active_projects, my_tasks, team_overdue, on_site].
- `spanClass` for n = 1…5 at every index.
- `layoutBands`:
  - owner → 4 bands, 15 standard cards and 3 compact;
  - field → density mode with 4 standard cards;
  - empty company → onboarding layout with the placeholder first.
- `secondaryPanel`: owner "cash", field "my_tasks".
- `webHrefFor` for each of the 22 ref kinds, plus the convert/award actions.
- `webHrefForActionTarget` for each mapping in §5.11.
- `summarySentence` for the 3 branches.
- `attentionChip` tones.
- `predictSections(user)` per role fixture.

### 5.11 Link mappers

**`webHrefFor(ref)`:**

| Ref kind | Web href |
|---|---|
| project | `/projeler/{id}` |
| project_finance | `/projeler/{id}?tab=finans` |
| project_cost | `?tab=maliyet` |
| project_operations | `?tab=operasyon` |
| offer | `/teklifler/{id}`, or with action convert `/teklifler/{id}/projeye-donustur` |
| task, milestone | `/projeler/{project_id}?tab=operasyon` |
| purchase_request, rfq, purchase_order | `?tab=satinalma` |
| subcontract, progress_claim, subcontract_change_order, change_order, contract, payment_plan_item, invoice | `?tab=finans` |
| budget_adjustment | `?tab=maliyet` |
| customer | `/musteriler/{id}` |
| product | `/admin/urunler/{id}` |
| user | `/admin/kullanicilar/{id}` |
| price_source | `/admin/urunler` |

**`webHrefForActionTarget(path)`** (notification targets are mobile paths):

| Mobile path | Web href |
|---|---|
| `/teklifler/{id}[/…]` | `/teklifler/{id}` |
| `/projeler/{p}/satin-alma/…` | `/projeler/{p}?tab=satinalma` |
| `/projeler/{p}/gorevler/…` | `?tab=operasyon` |
| `/projeler/{p}/taseronlar/…` | `?tab=finans` |
| `/projeler/{p}?grup=finans&alt=maliyet` | `?tab=maliyet` |
| other `?grup=finans` | `?tab=finans` |
| `?grup=operasyon` | `?tab=operasyon` |
| `?grup=dokumanlar` | `?tab=dosyalar` |
| other `/projeler/{p}…` | `/projeler/{p}` |
| `/diger/musteriler/{id}` | `/musteriler/{id}` |
| `/diger/mesai` | `/mesai` |
| `/diger/metraj` | `/admin/metraj-hesaplama` |
| anything else | `null` (the row is plain text) |

---

## 6. (C) Mobile (Flutter, Riverpod 2.6, go_router 16)

### 6.1 Files

**Create:**

| Path | Content |
|---|---|
| `lib/features/dashboard/domain/dashboard.dart` | Immutable models with `fromJson`. Every section is nullable (an absent key gives null). Unknown attention codes and ref kinds are kept as strings, with a generic rendering. Includes `Ref`, `MoneyAmount`, `AttentionGroup`, `UpcomingItem`, the per-section classes and `sectionErrors` (`Set<String>`). |
| `lib/features/dashboard/domain/dashboard_registry.dart` | `ModuleKey` enum; `kModules` (title, icon, band, compact, route builder); `kBands`; `pickKpis`; `secondaryPanel`; `layoutBands`; `attentionTitle`; `attentionRecordLine`; `attentionChip`; `upcomingLabel`; `summarySentence`; `scopeLine`; `predictSections(User?)`. These are the **same algorithms as web `lib/dashboard.ts`**. |
| `lib/features/dashboard/domain/mobile_routes.dart` | `String? mobileRouteFor(Ref ref)` (§6.6) |
| `lib/features/dashboard/data/dashboard_repository.dart` | `DashboardRepository(ApiClient api)` with `Future<Dashboard> fetch() async => Dashboard.fromJson(await api.get<Map<String, dynamic>>('/dashboard'))` and `Future<List<ProjectOption>> projectOptions({String q = ''})` |
| `lib/features/dashboard/data/dashboard_providers.dart` | `dashboardRepositoryProvider`; `dashboardProvider = FutureProvider.autoDispose<Dashboard>(...)`; `projectOptionsProvider = FutureProvider.autoDispose.family<List<ProjectOption>, String>`; `onboardingHiddenProvider` (AsyncNotifier over SharedPreferences, key `arvend.home.onboarding.hidden.{orgId}.{userId}`) |
| `lib/features/dashboard/presentation/dashboard_screen.dart` | **Rewrite.** Update the header comment to reference `/dashboard`. |
| `lib/features/dashboard/presentation/attention_screen.dart` | `/ana-sayfa/dikkat` |
| `lib/features/dashboard/presentation/widgets/` | `dashboard_header.dart`, `kpi_grid.dart`, `kpi_tile.dart`, `attention_card.dart`, `attention_row.dart`, `upcoming_row.dart`, `quick_actions_row.dart`, `cash_flow_card.dart`, `my_tasks_card.dart`, `module_band.dart`, `module_card.dart`, `module_cards.dart` (one builder per module), `records_group_card.dart` (FİRMA KAYITLARI), `activity_card.dart`, `onboarding_card.dart`, `project_modules_placeholder.dart`, `section_error_body.dart`, `dashboard_skeleton.dart`, `shortcuts_grid.dart`, `project_picker_sheet.dart` |
| `lib/core/widgets/viz/progress_bar.dart` | `AppProgressBar(pct, color, semanticsLabel)`: ClipRRect(radius 3) + track `AppColors.border` + `FractionallySizedBox`, height 6 |
| `lib/core/widgets/viz/segment_bar.dart` | `AppSegmentBar(segments, legend: true)`: Row of `Flexible(flex: value)` with a 1px gap and minimum 2px; legend as a `Wrap` of dot + "Devam 7" |
| `lib/core/widgets/viz/paired_bar_chart.dart` | `PairedBarChart(months, height: 140)`: a `CustomPainter` with the same geometry and rules as web; `Semantics(label: …)` |
| `lib/core/widgets/skeleton_box.dart` | `SkeletonBox(height, width?)` with fill `AppColors.border`, a 1.2s opacity pulse, disabled when `MediaQuery.disableAnimations` |
| `lib/core/auth/permissions.dart` | `extension UserCan on User? { bool can(String code) => this == null \|\| this!.permissions.isEmpty \|\| this!.hasPermission(code); bool canAll(List<String> c) => c.every(can); }` (existing fail-open semantics; used only for quick actions and skeleton prediction) |
| `lib/core/utils/event_labels.dart` | Verbatim Dart copy of web `lib/events.ts`, with fallback "Kayıt güncellendi" |

**Modify:**
- `lib/core/utils/formatters.dart`: add `moneyCompact(num, {currency})` and `signedMoneyCompact` (D5 rule, `NumberFormat.decimalPattern('tr_TR')` with maximumFractionDigits 1, and roll-over to Mn/Mr); `percent(num)` ("%59", "%62,5"); `relative(String iso, String nowIso)`; `longDate(String isoDate)` ("28 Eylül 2026, Pazartesi"); `shortDayMonth` ("30 Eyl"); `hm(String iso)`.
- `lib/core/theme/app_typography.dart`: add `metricHero` (22 / w800 / h1.1 / tabularFigures / textPrimary) and `overline` (11.5 / w700 / letterSpacing 0.8 / textMuted).
- `lib/app/app_router.dart`:
  - `/ana-sayfa` gets a child `GoRoute(path: 'dikkat', builder: (_, s) => AttentionScreen(initialCode: s.uri.queryParameters['kod']))`.
  - The `/projeler/:id` builder passes `initialGroup: state.uri.queryParameters['grup']` and `initialView: state.uri.queryParameters['alt']`.
- `lib/features/projects/presentation/project_detail_screen.dart`:
  - `ProjectDetailScreen({initialGroup, initialView})`. It maps `ozet|finans|operasyon|dokumanlar` to the group label and sets `DefaultTabController(initialIndex: index in visibleGroups, else 0)`.
  - `_FinansGroupTab(initialView: finans|ek-isler|maliyet)`, `_OperasyonGroupTab(initialView: taseronlar|satin-alma|gorevler)`, `_DokumanlarGroupTab(initialView: dosyalar|notlar)`: `_view ??=` the matching segment if visible, else the first.
- `test/redesign_workflow_test.dart`:
  - In the DashboardScreen group, script `'/dashboard': [(status: 200, body: <fixture json>)]` and `'/notifications/unread-count'`, and remove `/projects` and `/tasks/mine`.
  - Keep the assertions `'Merhaba, Ayşe'`, `'ARVEND Yapı A.Ş.'` (organisation name as its own Text), `'Teklif Oluştur'`, `'Metraj Hesapla'` and `'Müşteri Ekle'` with their gates.

### 6.2 Providers and data flow

```dart
final dashboardProvider = FutureProvider.autoDispose<Dashboard>(
    (ref) => ref.watch(dashboardRepositoryProvider).fetch());

Future<void> refreshAll(WidgetRef ref) async {
  try {
    await Future.wait([
      ref.refresh(dashboardProvider.future),
      ref.refresh(unreadNotificationCountProvider.future),
    ]);
  } catch (_) {/* state shows banner */}
}
```

- **Pull-to-refresh** waits for the new data, so the spinner is real. Old data stays visible (the default `skipLoadingOnRefresh`).
- **Resume refresh:** `AppLifecycleListener(onResume:)` refreshes when `generated_at` is more than 5 minutes old.
- **Re-tapping the Ana Sayfa tab** while on it scrolls to the top and refreshes, via the shell's `goBranch(0, initialLocation: true)` hook.
- **Removed:** the three old providers from this screen, the hard-coded `'ArvenYapı'` `_BrandDayCard`, the fake-"0" `maybeWhen` tiles, and the ungated "Masraf Ekle".
- **Kept:** `unreadNotificationCountProvider` for the AppBar bell.

### 6.3 Widget tree

```
DashboardScreen (ConsumerStatefulWidget)
└ Scaffold(appBar: buildAppBar('Ana Sayfa', actions: [BellButton(badge: unread)]))
  └ RefreshIndicator(onRefresh: () => refreshAll(ref))
    └ switch (asyncDashboard)
       · first load            → DashboardSkeleton(plan: predictSections(user))
       · error, no data        → ListView[DashboardHeader(user, null), ErrorCard, ShortcutsGrid(user)]
       · data (maybe + error)  → CustomScrollView(slivers: [SliverPadding(kScreenPadding, SliverList.list(children: [
            DashboardHeader(user, data),                      // Merhaba · org · date · sentence · scope
            if (hasError) StaleBanner(generatedAt),           // "Güncellenemedi · son veri 09:41" [Tekrar dene]
            if (onboardingActive) OnboardingCard(data)  else KpiGrid(pickKpis(data)),
            if (!onboardingActive) AttentionCard(data.agenda, errors),
            if (actions.isNotEmpty) QuickActionsRow(actions),
            if (!onboardingActive) switch secondaryPanel(data) { cash → CashFlowCard, myTasks → MyTasksCard, _ → nothing },
            for (band in layoutBands(data)) ModuleBand(band),  // band overline + cards (FİRMA KAYITLARI → RecordsGroupCard)
            if (activity non-empty) ActivityCard(items.take(5)),
          ]))])
```

**Spacing:** `AppSpacing.xl` (24) between zones, `AppSpacing.sm` (8) between cards, `AppSpacing.md` (12) inside cards.

### 6.4 Layout details

- **Header:**
  - `Text('Merhaba, $firstName', style: pageTitle)`
  - `Text(organizationName, style: metadata)`, as a separate widget (a test finds it)
  - `Text('${Formatters.longDate(data.today)} · ${Formatters.hm(data.generatedAt)} güncellendi', style: helper)`
  - `Text(summarySentence, style: body)`
  - optional scope line (`helper`)
  - While loading, only the first two lines plus a skeleton line are shown.
- **KpiGrid:**
  - 2 columns; n=3 gives 2 + 1 with the last tile spanning.
  - 1 column when `constraints.maxWidth < 340` or `textScaler.scale(1) >= 1.3`.
  - Hidden when fewer than 2 tiles.
  - **KpiTile** (`AppCard`, padding 14, minHeight 96):
    - top row: label (`metadata`, sentence case) + icon 18 `textMuted`
    - value `metricHero` inside `FittedBox(scaleDown)`; colour `AppStatusColors.success` / `.error` only for signed values
    - sub (`helper`, maxLines 2)
    - optional `AppProgressBar`
    - tap only when a route exists
    - `Semantics(label: full values)`
- **AttentionCard:**
  - `AppSectionHeader('Dikkat Gerektirenler', trailing: TextButton('Tümü ($total)'))`
  - `AppCard` containing the first 4 rows across lanes (mine, then watching, then upcoming), each lane preceded by a tiny `overline` label ("SENİN SIRAN", "TAKİPTE", "YAKLAŞAN · 14 GÜN").
  - **Row** (minHeight 64): 4dp severity bar (error / warning / info), icon 20 (`warning_amber_rounded` / `fact_check_outlined` / `hourglass_empty`), title (`body` w600, maxLines 2), meta (`helper`): "850.000 TL · en eski 21 gün".
  - **Tap:** count == 1 → `context.push(mobileRouteFor(item.ref) ?? moduleRoute)`; count > 1 → `context.push('/ana-sayfa/dikkat?kod=$code')`.
  - **Empty:** `check_circle_outline` success + "Her şey yolunda — seni bekleyen onay ya da gecikme yok."
- **AttentionScreen** (`AppPageScaffold`, title "Dikkat Gerektirenler"):
  - `AppFilterBar` chips "Tümü ({n})", "Senin sıran ({n})", "Takipte ({n})", "Yaklaşan ({n})";
  - each group is a card that expands to show up to 3 records (each pushes its route) plus "+{n} daha" (pushes the module route);
  - `initialCode` starts expanded and is scrolled into view.
- **QuickActionsRow:** `AppSectionHeader('Hızlı İşlemler')` + a horizontal `SingleChildScrollView` of `QuickActionButton`s. Icons:

  | Action | Icon |
  |---|---|
  | Teklif Oluştur | `description_outlined` |
  | Tahsilat Gir | `payments_outlined` |
  | Masraf Gir | `receipt_long_outlined` |
  | Mesai Gir | `more_time` |
  | Satın Alma Talebi | `shopping_cart_outlined` |
  | Görev Ekle | `add_task` |
  | Not Ekle | `sticky_note_2_outlined` |
  | Müşteri Ekle | `person_add_alt_outlined` |
  | Metraj Hesapla | `calculate_outlined` |

  Actions that need a project call `showProjectPickerSheet(context)`, which returns `ProjectOption?`. The sheet has a search field (hint "Proje ara…"), a list with title + "{project_no} · {customer}", empty "Açık proje bulunamadı." and error "Projeler yüklenemedi.". With exactly one project it is skipped.
- **CashFlowCard:** `AppSectionHeader('Nakit Akışı')` + `AppCard`:
  - `PairedBarChart` (height 140; Tahsilat `AppStatusColors.success`, Çıkış `AppColors.textMuted`, grid `AppColors.border`);
  - legend;
  - divider;
  - "Bu ay" `AppDataRow`s: Tahsilat / Masraf / Taşeron ödemesi / Net (signed full `Formatters.money`);
  - a `SegmentedButton` for currencies when there is more than one.
- **MyTasksCard** (promoted when there is no finance and the user is linked):
  - `AppSectionHeader('Görevlerim', trailing: TextButton('Tümü', go /gorevler))`;
  - up to 5 rows: title, project, due chip ("Bugün" warning, "{n} gün gecikti" error, "02 Eki" neutral), priority `StatusBadge` via `StatusRegistry.taskPriority`;
  - each row pushes the task route.
  - When promoted, the Görevler module card hides its list.
- **ModuleBand:** `Text(bandTitleUpper, style: overline)`; the cards are full width, one per row.
  - In density mode the heading is "BÖLÜMLER".
  - Uppercase band titles are literal strings, never `toUpperCase()` (Turkish "i"): "NAKİT & SATIŞ", "PROJE & SAHA", "TEDARİK & MALİYET", "FİRMA KAYITLARI", "BÖLÜMLER".
- **ModuleCard** (`AppCard`, padding 16):
  - header Row: 32×32 container (radius 8, `AppColors.background`) with an icon 20 `textMuted`; title `cardTitle` (Expanded, ellipsis); attention chip `StatusBadge(label, tone: error|warning|info)`; `chevron_right` when a route exists.
  - primary value `metricPrimary` + label `metadata`;
  - stats Row of up to 3 `Expanded` columns (value `body.copyWith(fontWeight: w700, fontFeatures: tabular)`, label `helper`). The stats `Wrap` into 2 per line when `textScale >= 1.3` or width < 300.
  - one visual;
  - footer: `Divider` + up to 2 attention lines (`InkWell`, minHeight 48, icon 18 in the severity colour, `helper` text coloured, `chevron_right` 16), or the quiet line (`check_circle_outline` success 16 + "Bekleyen iş yok").
  - The whole card is tappable only if the module has a mobile route.
- **RecordsGroupCard** (FİRMA KAYITLARI on mobile): one `AppCard` of rows (minHeight 52): icon 20, title, trailing value (`body` w700 tabular), detail (`helper`), chevron if routed. Rows and details:
  - Müşteriler "58 aktif · bu ay +3"
  - Personel "30 aktif"
  - Ürünler & Zam "4.393 ürün · 30 günde 198 zam · ort. %4,2"
  - Ekip "8 aktif · 2 projesiz"
  - Metraj "12 grup · 95 kategori"
  - Tedarikçiler "44 aktif"
  - Maliyet Kodları "61 aktif"

  Footer `helper`: "Bu kayıtlar web panelinden yönetilir." (shown if any row has no route). The attention lines of these modules (price_sync_*, users_without_project) appear in Dikkat only.
- **ActivityCard:** `AppSectionHeader('Son Hareketler')` + 5 rows: "{user} · {etiket}" / "{project_no} {project_name} · {relative}"; each pushes `/projeler/{p}`. There is no "Tümü".
- **Colours:**
  - severity danger → `AppStatusColors.error`, action → `.warning`, info → `.info`, upcoming → `.warning` icon with neutral text;
  - Tahsilat / collected → `.success`; task progress → `AppColors.gold` (progress fill, allowed); elapsed time → `textMuted`; track → `border`.
- **Material icons** (outlined, 20):

  | Module | Icon |
  |---|---|
  | finance | `account_balance_wallet_outlined` |
  | offers | `request_quote_outlined` |
  | change_orders | `note_add_outlined` |
  | projects | `apartment_outlined` |
  | tasks | `checklist` |
  | operations | `construction` |
  | contracts | `gavel_outlined` |
  | attendance | `schedule` |
  | procurement | `shopping_cart_outlined` |
  | subcontracts | `handshake_outlined` |
  | cost_control | `balance` |
  | customers | `people_outline` |
  | employees | `engineering_outlined` |
  | products | `inventory_2_outlined` |
  | users | `manage_accounts_outlined` |
  | calculations | `straighten` |
  | suppliers | `local_shipping_outlined` |
  | cost_codes | `sell_outlined` |
  | activity | `history` |

### 6.5 Wireframe (360 × 800 dp, owner)

```
┌──────────────────────────────────────┐
│ Ana Sayfa                     🔔(4)  │
├──────────────────────────────────────┤
│ Merhaba, Taha                        │
│ Arvend Yapı                          │
│ 28 Eylül 2026, Pazartesi · 09:41     │
│ güncellendi                          │
│ Bugün 7 iş senin sıranda; 3 tanesi   │
│ acil.                                │
│ ┌────────────────┐┌────────────────┐ │
│ │Açık alacak   ▢ ││Bu ay net nak.▢ │ │
│ │5,1 Mn TL       ││+420.000 TL     │ │
│ │▓▓▓▓▓▓░░░░      ││Giriş 950.000 TL│ │
│ │%59 tahsil edil.││Çıkış 530.000 TL│ │
│ └────────────────┘└────────────────┘ │
│ ┌────────────────┐┌────────────────┐ │
│ │Teklif hattı    ││Proje nakit den.│ │
│ │2,3 Mn TL       ││+2,2 Mn TL      │ │
│ │5 teklif yanıt  ││Tahsilat 7,4 Mn │ │
│ └────────────────┘└────────────────┘ │
│ Dikkat Gerektirenler       Tümü (12) │
│ ┌──────────────────────────────────┐ │
│ │ SENİN SIRAN                      │ │
│ │▌⚠ 4 ödeme planı kaleminin vadesi │ │
│ │▌  geçti                        › │ │
│ │▌  850.000 TL · en eski 21 gün    │ │
│ │▌☑ 3 satın alma talebi onay bekl. │ │
│ │▌  145.000 TL · en eski 4 gün   › │ │
│ │▌☑ 1 taşeron hakedişi onay bekl.› │ │
│ │ TAKİPTE                          │ │
│ │▌⧗ 2 ek iş müşteri onayında     › │ │
│ └──────────────────────────────────┘ │
│ Hızlı İşlemler                       │
│ (◎)Teklif (◎)Tahsilat (◎)Masraf (◎)→ │
│ Oluştur   Gir        Gir     Mesai   │
│ Nakit Akışı                          │
│ ┌──────────────────────────────────┐ │
│ │ ▇▅  ▆▃  ▅▄  ▇▆  ▆▅  █▄           │ │
│ │ Nis May Haz Tem Ağu Eyl          │ │
│ │ ■ Tahsilat  ■ Çıkış              │ │
│ │ Tahsilat          +950.000,00 TL │ │
│ │ Masraf            -310.000,00 TL │ │
│ │ Taşeron ödemesi   -220.000,00 TL │ │
│ │ Net               +420.000,00 TL │ │
│ └──────────────────────────────────┘ │
│ NAKİT & SATIŞ                        │
│ ┌──────────────────────────────────┐ │
│ │[▢] Proje Finansı  [1 uyarı]    › │ │
│ │12,5 Mn TL  Portföy değeri        │ │
│ │▓▓▓▓▓▓▓▓░░░░ %59 tahsil edildi    │ │
│ │7,4 Mn      5,1 Mn      5,2 Mn    │ │
│ │Tahsil ed.  Açık alacak Harcanan  │ │
│ │──────────────────────────────────│ │
│ │⚠ 4 ödeme planı kaleminin vade… › │ │
│ └──────────────────────────────────┘ │
│ … Teklifler, Ek İşler, PROJE & SAHA, │
│   TEDARİK & MALİYET cards …          │
│ FİRMA KAYITLARI                      │
│ ┌──────────────────────────────────┐ │
│ │👥 Müşteriler   58 aktif · +3    › │ │
│ │👷 Personel     30 aktif           │ │
│ │📦 Ürünler & Zam 4.393 · ort. %4,2 │ │
│ │⚙ Ekip          8 aktif · 2 proj.  │ │
│ │📏 Metraj       12 grup          › │ │
│ │🚚 Tedarikçiler 44 aktif           │ │
│ │🏷 Maliyet Kod. 61 aktif           │ │
│ │Bu kayıtlar web panelinden yönetilir.│
│ └──────────────────────────────────┘ │
│ Son Hareketler (5)                   │
├──────────────────────────────────────┤
│Ana Sayfa Projeler Teklifler Görev Diğer│
└──────────────────────────────────────┘
```

### 6.6 `mobileRouteFor(ref)`

| Ref kind | Mobile route |
|---|---|
| project | `/projeler/{id}` |
| project_finance | `/projeler/{id}?grup=finans&alt=finans` |
| project_cost | `?grup=finans&alt=maliyet` |
| project_operations | `?grup=operasyon&alt=gorevler` |
| offer | `/teklifler/{id}` (convert has no mobile screen; it opens the offer) |
| task | `/projeler/{p}/gorevler/{id}` |
| milestone | `/projeler/{p}?grup=operasyon&alt=gorevler` |
| purchase_request | `/projeler/{p}/satin-alma/talepler/{id}` |
| rfq | `/projeler/{p}/satin-alma/rfqlar/{id}`, or with action award `/projeler/{p}/satin-alma/rfqlar/{id}/karsilastir` |
| purchase_order | `/projeler/{p}/satin-alma/siparisler/{id}` |
| subcontract | `/projeler/{p}/taseronlar/{id}` |
| progress_claim | `/projeler/{p}/taseronlar/{parent}/hakedisler/{id}` |
| subcontract_change_order | `/projeler/{p}/taseronlar/{parent}/degisiklik-emirleri/{id}` |
| change_order | `/projeler/{p}?grup=finans&alt=ek-isler` |
| budget_adjustment | `?grup=finans&alt=maliyet` |
| contract, payment_plan_item, invoice | `?grup=finans&alt=finans` |
| customer | `/diger/musteriler/{id}` |
| product, user, price_source | `null` (not tappable) |

Notifications use `action_target` as-is.

### 6.7 States (mobile)

- **First load:** `DashboardSkeleton` from `predictSections(user)`. When `permissions` is empty, a generic skeleton: header lines, 4 KPI boxes (96), Dikkat (220), 4 cards (200).
- **Refresh:** old data stays and the spinner waits.
- **Error with data:** `StaleBanner` (`AppCard` with `color: AppStatusColors.error.withValues(alpha: .06)`, text "Güncellenemedi · son veri {HH:mm}", `TextButton('Tekrar dene')`).
- **Error without data:** header + `ErrorState(error, onRetry)` (the existing widget, message "Özet yüklenemedi…") + `ShortcutsGrid`. The shortcuts are the visible tabs (Projeler, Teklifler if offers.read, Görevler if tasks.read) plus the Diğer entries (Müşteriler, Mesai, Metraj, Bildirimler), gated with `can`.
- **Section error:** the card keeps its header; the body is `SectionErrorBody` ("Bu özet şu an yüklenemedi." + "Tekrar dene" → `ref.refresh(dashboardProvider.future)`).
- **Empty states:** §7.4.

### 6.8 Mobile tests

**Fixtures:**
- Read `../docs/dashboard/fixtures/{owner,empty_company,field,finance}.json` in `setUpAll` with `File(...).readAsStringSync()`. The flutter test working directory is `mobile/`.
- `test/features/dashboard/fixtures.dart` exposes `fixtureJson(name)` and the users `ownerUser` (all permissions), `emptyOwnerUser`, `fieldUser`, `financeUser` (default role permission sets from §4.8).

**1. `test/features/dashboard/dashboard_model_test.dart`:**
- each fixture parses;
- an absent key gives null;
- `section_errors` parses;
- an unknown attention code or ref kind is tolerated;
- `mobileRouteFor` for every kind;
- the `Formatters.moneyCompact` table (the same cases as web §5.10);
- `pickKpis` / `layoutBands` / `secondaryPanel` per persona match the web expectations.

**2. `test/features/dashboard/dashboard_screen_test.dart`** (behaviour). It uses the existing `FakeHttpClientAdapter` scripting `'/dashboard'` and `'/notifications/unread-count'`.
- **Owner:** shows the band headings "NAKİT & SATIŞ", "PROJE & SAHA", "TEDARİK & MALİYET", "FİRMA KAYITLARI"; the KPI labels "Açık alacak", "Bu ay net nakit", "Teklif hattı", "Proje nakit dengesi"; and "Nakit Akışı".
- **Finance:** no "Görevler" text inside the cards; `adapter.calls` contains no `/tasks/mine`; "Tahsilat Gir" is present.
- **Field:** no "Nakit Akışı"; "Görevlerim" is present; "BÖLÜMLER" is present (density mode); no quick actions except "Not Ekle".
- **Empty company:** "Kurulum — ilk adımlar" and "Proje modülleri" are present; no KPI grid.
- **Section error:** a fixture copy with `section_errors: {"procurement": "section_failed"}` shows exactly one "Bu özet şu an yüklenemedi.".
- **Whole failure:** `/dashboard` returns 500 → "Kısayollar" is present.
- **Layout robustness:** pump each persona at 320×1600 and at textScale 1.6 (the `_pump(size:, textScale:)` pattern from `phase4_polish_workflow_test.dart`) and expect `tester.takeException()` to be null.
- **Tapping** an attention row with count 1 pushes the expected route (mini GoRouter harness, as `_buildProjectTestRouter` does).

**3. `test/features/dashboard/dashboard_golden_test.dart`** (screenshot / golden, produces PNGs):

```dart
@Tags(['golden'])
library;

import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/date_symbol_data_local.dart';
// + app imports: AppTheme, DashboardScreen, AttentionScreen, dashboardProvider, Dashboard,
//   authControllerProvider, AuthController, User, unreadNotificationCountProvider,
//   apiClientProvider, buildFakeApiClient, FakeHttpClientAdapter

Future<void> _loadAppFonts() async {           // Inter + MaterialIcons, else Ahem boxes
  final manifest = json.decode(await rootBundle.loadString('FontManifest.json')) as List<dynamic>;
  for (final family in manifest.cast<Map<String, dynamic>>()) {
    final loader = FontLoader(family['family'] as String);
    for (final font in (family['fonts'] as List).cast<Map<String, dynamic>>()) {
      loader.addFont(rootBundle.load(font['asset'] as String));
    }
    await loader.load();
  }
}

class _FakeAuth extends AuthController {
  _FakeAuth(this._user);
  final User _user;
  @override
  Future<User?> build() async => _user;
}

const _sizes = <String, Size>{'360x800': Size(360, 800), '412x915': Size(412, 915)};
const _personas = ['owner', 'empty_company', 'field', 'finance'];

void main() {
  late Map<String, Map<String, dynamic>> fixtures;
  setUpAll(() async {
    await initializeDateFormatting('tr_TR');
    await _loadAppFonts();
    fixtures = {for (final p in _personas)
      p: json.decode(File('../docs/dashboard/fixtures/$p.json').readAsStringSync()) as Map<String, dynamic>};
  });

  Widget harness(String persona) {
    final router = GoRouter(initialLocation: '/ana-sayfa', routes: [
      GoRoute(path: '/ana-sayfa', builder: (_, __) => const DashboardScreen(),
          routes: [GoRoute(path: 'dikkat', builder: (_, __) => const AttentionScreen())]),
    ]);
    return ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(buildFakeApiClient(FakeHttpClientAdapter(script: {}))), // any stray call fails
        authControllerProvider.overrideWith(() => _FakeAuth(userFor(persona))),
        dashboardProvider.overrideWith((ref) async => Dashboard.fromJson(fixtures[persona]!)),
        unreadNotificationCountProvider.overrideWith((ref) async => 4),
      ],
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        locale: const Locale('tr', 'TR'),
        supportedLocales: const [Locale('tr', 'TR')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        routerConfig: router,
      ),
    );
  }

  for (final persona in _personas) {
    for (final entry in _sizes.entries) {
      testWidgets('dashboard $persona ${entry.key}', (tester) async {
        tester.view.devicePixelRatio = 2.0;
        tester.view.physicalSize = entry.value * 2.0;           // PNG 720×1600 / 824×1830
        addTearDown(tester.view.reset);
        await tester.pumpWidget(harness(persona));
        await tester.pumpAndSettle();
        await expectLater(find.byType(MaterialApp),
            matchesGoldenFile('goldens/dashboard_${persona}_${entry.key}.png'));
      });
    }
    testWidgets('dashboard $persona full page 360', (tester) async {  // whole scroll content, for review
      tester.view.devicePixelRatio = 2.0;
      tester.view.physicalSize = const Size(360, 4400) * 2.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(harness(persona));
      await tester.pumpAndSettle();
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/dashboard_${persona}_360_full.png'));
    });
  }
}
```

- Add `mobile/dart_test.yaml` with `tags: {golden: {}}`.
- **Generate or view the PNGs:** `cd mobile && flutter test --tags golden --update-goldens test/features/dashboard/dashboard_golden_test.dart`. The output is 12 PNGs in `mobile/test/features/dashboard/goldens/`.
- A normal `flutter test` compares against them.
- Goldens are macOS-specific; on other hosts run `flutter test --exclude-tags golden`.
- Data is fully deterministic: dates come from the fixture's `today` / `generated_at`, and no `DateTime.now()` is used in rendering.
- `SkeletonBox` never appears, because the data is provided synchronously.
- The web engineer may use these PNGs as the visual reference for spacing and hierarchy (not pixel-exact).

**Canonical owner fixture numbers.** Use these in the fixture and the wireframes, so web, mobile and backend agree:
- today 2026-09-28, generated_at 09:41 (+03:00), primary TRY
- portfolio 12.500.000; collected 7.400.000; receivable 5.100.000; collection 59.2; realized cost 5.200.000; cash balance 2.200.000
- month: collections 950.000 / expenses 310.000 / subcontract 220.000 → outflows 530.000, net 420.000
- trend_6m: Nisan–Eylül with non-zero values
- overdue plan 4 · 850.000 (oldest 21 days)
- PR approval 3 · 145.000 (oldest 4 days); claim 1 · 90.000 (HK-004); change orders awaiting 2 · 180.000
- offers awaiting 5 · 2.300.000; draft 3; accepted 90d 5; rejected 90d 3; conversion 62.5; expired 1; viewed 3
- projects: planned 2, active 7, paused 1, completed 12, cancelled 1 (total 23); past end 2; ending in 30 days 3
- a USD row on finance with receivable 45.000
- agenda: mine_count 7, mine_danger_count 3, watching 2, upcoming 3
- users: active 8, restricted without project 2
- products 4.393 (manual 120 / ulas 628 / demirprofil 3.645); Ulaş success, 2 days ago; Demir Profil never

---

## 7. Turkish copy catalog (single source; web `COPY` in `lib/dashboard.ts`, mobile `dashboard_registry.dart`)

The web shows uppercase through CSS (`<html lang="tr">` makes "i" → "İ" correct). Mobile shows sentence case, except the band overlines, which are literal uppercase strings.

### 7.1 Page, panels, bands

| Element | Text |
|---|---|
| Nav / page title | Ana Sayfa |
| Greeting | Merhaba, {ad} (no name → "Merhaba") |
| KPI row sr-only heading | Temel göstergeler |
| Panels | Dikkat Gerektirenler · Nakit Akışı · Son 6 ay · Görevlerim · Son Hareketler · Bildirimler · Hızlı İşlemler (mobile) · Kısayollar |
| Lanes | Senin sıran · Takipte · Yaklaşan · 14 gün |
| Bands | Nakit & Satış · Proje & Saha · Tedarik & Maliyet · Firma kayıtları · Bölümler. Mobile literals: "NAKİT & SATIŞ", "PROJE & SAHA", "TEDARİK & MALİYET", "FİRMA KAYITLARI", "BÖLÜMLER" |
| Cards | Proje Finansı · Teklifler · Ek İşler · Projeler · Görevler · Şantiye · Sözleşmeler · Mesai / Puantaj · Satın Alma · Taşeron · Bütçe & Maliyet · Müşteriler · Personel · Ürünler & Zam · Ekip · Metraj · Tedarikçiler · Maliyet Kodları · Proje modülleri (onboarding placeholder) |
| Card link | Aç |
| Card chips | {n} uyarı · {n} bekliyor · {n} takipte |
| Quiet footer | Bekleyen iş yok |
| Refresh | Yenile (aria) · Güncellendi {HH:mm} · Güncellenemedi · son veri {HH:mm} |
| Show all | Tümünü göster ({n}) · Daha az göster · Tümü ({n}) (mobile) · +{n} daha · {n} kayıt |
| Takipte tooltip | Bu işler başka birinin onayını ya da müşteriyi bekliyor. |
| Dropdown | Diğer işlemler |
| Picker | Proje seç · Proje ara… · Açık proje bulunamadı. · Projeler yüklenemedi. |
| Currency extra | Diğer: {değerler} |
| Chart | Tahsilat · Çıkış · Bu ay · Masraf · Taşeron ödemesi · Net. Months: Oca Şub Mar Nis May Haz Tem Ağu Eyl Eki Kas Ara |
| Relative time | az önce · {n} dk önce · {n} sa önce · dün {HH:mm} · {dd.MM} {HH:mm} · {dd.MM.yyyy} |
| Age | en eski {n} gün · {n} gün gecikti · {n} gündür bekliyor · {n} gün önce doldu · {n} gün geçti · Bugün · Yarın |
| Notifications | {n} okunmamış · Tümünü okundu say · Yeni bildirim yok. |
| Activity | Henüz hareket yok. · unknown type → Kayıt güncellendi |

### 7.2 Metric labels (sentence case)

- **KPI tiles:** Açık alacak · Bu ay net nakit · Teklif hattı · Proje nakit dengesi · Aktif proje · Açık görevim · Ekipte geciken görev · Bugün sahada · Okunmamış bildirim.
- **KPI sub-lines:** "%{x} tahsil edildi" · "Giriş {a}" / "Çıkış {b}" · "{n} teklif yanıt bekliyor" · "Kabul oranı %{x} · 90 gün" · "Tahsilat {a} · Harcama {b}" · "{n} planlanan · {m} beklemede" · "{n} gecikmiş · {m} bugün" · "{n} görev atanmamış" · "Firma geneli · {n} kişi girilmedi".
- **Card metrics:** the labels as listed in §2. Also:
  - "toplam {n}", "{n} teklif", "{n} kişi", "{x} sa";
  - Projeler legend: Planlandı · Devam · Beklemede · Tamamlandı · İptal;
  - Mesai legend: Geldi · Yarım gün · Gelmedi · İzinli · Girilmedi;
  - Sözleşmeler legend: Taslak · Aktif · Tamamlandı · İptal/Fesih;
  - Bütçe legend: Bütçesiz · Taslak · Onaylı;
  - Teklifler legend: Kabul · Red;
  - Ürünler legend: Manuel · Ulaş · Demir Profil;
  - Satın Alma flow: "Talep {n} onayda → RFQ {n} açık → Sipariş {n} açık";
  - project row bars: Süre · Görev · Tahsilat; "{n} gün gecikti" · "Bitiş {dd.MM.yyyy}";
  - source chip status: Başarılı · Hata · Hiç senkronlanmadı.

### 7.3 Summary and attention

- The summary sentence, scope line and every attention title and record line are listed in §3.1, §3.2 and §3.4.

### 7.4 Empty states (CTA shown only with the listed permission)

| Where | Text | CTA (gate) |
|---|---|---|
| Dikkat | Her şey yolunda — seni bekleyen onay ya da gecikme yok. | – |
| Nakit Akışı (all zero) | Son 6 ayda tahsilat ya da ödeme kaydı yok. (axes drawn empty) | – |
| Görevlerim | Sana atanmış açık görev yok. | – |
| Proje Finansı | Henüz tahsilat ya da masraf kaydı yok. Kayıtlar proje sayfasındaki Finans sekmesinden girilir. | Tahsilat Gir (projects.finance.manage) |
| Teklifler | Henüz teklif yok. İlk teklifini hazırlayıp müşterine bağlantıyla gönderebilirsin. | Yeni Teklif / Teklif Oluştur (offers.create) |
| Ek İşler | Bekleyen ek iş yok. Sözleşme dışı işler için proje sayfasından ek iş oluşturup müşteriye onaya gönderebilirsin. | – |
| Projeler (all-projects roles) | Henüz proje yok. Projeler, kabul edilen tekliflerden oluşturulur. | Tekliflere git (offers.read) |
| Projeler (restricted, 0 projects) | Henüz bir projeye eklenmedin. Yöneticin seni bir projeye eklediğinde projelerin burada görünür. | – |
| Projeler (no open projects) | Açık proje yok · {n} tamamlanan proje | Tamamlananlar → `/projeler?status=completed` |
| Görevler (linked, 0 open) | Sana atanmış açık görev yok. | – |
| Görevler (not linked; non-admin only) | Hesabın bir personel kaydına bağlı değil; sana atanan görevler burada görünmez. Yöneticinden bağlamasını iste. | – |
| Şantiye | Son 7 günde şantiye kaydı yok. | – |
| Sözleşmeler | Henüz sözleşme kaydı yok. Sözleşmeler proje sayfasındaki Finans sekmesinden açılır. | – |
| Mesai (no employees) | Mesai takibi için önce personel ekle. | Personel Ekle (employees.manage; web only) |
| Mesai (Sunday) | Bugün Pazar — mesai beklenmiyor. | – |
| Mesai (workday, nothing recorded) | Bugün için mesai kaydı girilmedi. | Mesai Gir (attendance.manage + employees.read) |
| Satın Alma | Açık satın alma kaydı yok. Malzeme ihtiyacı proje sayfasındaki Satın Alma sekmesinden talep edilir. | – |
| Taşeron | Henüz taşeron sözleşmesi yok. | – |
| Bütçe & Maliyet | Henüz bütçe oluşturulmadı. Bütçe, maliyet kontrolünün temelidir. | – |
| Müşteriler | Henüz müşteri yok. | Müşteri Ekle (customers.manage) |
| Personel | Henüz personel eklenmedi. | Personel Ekle (employees.manage) |
| Ürünler & Zam | Katalog boş. Ulaş veya Demir Profil fiyat kaynağını bağlayarak ürünleri içe aktarabilirsin. | Ürünlere git (products.read) |
| Ürünler (no source configured) | Fiyat kaynağı bağlı değil. | – |
| Ekip | Ekipte yalnızca sen varsın. Ekip arkadaşlarını davet et. | Kullanıcı Ekle (admin + organization.users.manage) |
| Metraj / Tedarikçiler / Maliyet Kodları | Henüz metraj grubu yok. / Henüz tedarikçi yok. / Henüz maliyet kodu yok. | – |
| Proje modülleri (onboarding) | Proje başladığında finans, ek iş, sözleşme, görev, şantiye, satın alma, taşeron ve bütçe özetleri burada görünecek. | – |
| Onboarding | Kurulum — ilk adımlar · {d} / {t} tamamlandı · Gizle · Kurulum rehberi gizlendi · Göster · Firma bilgilerini gözden geçir → | per step (§3.6) |
| Section error | Bu özet şu an yüklenemedi. | Tekrar dene |
| Dikkat partial | Bazı bölümler yüklenemedi; liste eksik olabilir. | – |
| Whole failure | Özet yüklenemedi · Bağlantını kontrol edip tekrar dene. Modüllere aşağıdaki kısayollardan ulaşabilirsin. | Tekrar dene |

---

## 8. (D) Persona walkthroughs

### 8.1 Owner (Sahip), company with data (`/admin`, mobile Ana Sayfa)

- **Sections returned:** all 20. `onboarding` = null. `viewer.all_projects` = true.
- **Header:** "Merhaba, Taha · 28 Eylül 2026, Pazartesi · Arvend Yapı · Sahip".
- **Web quick actions:** [+ Yeni Teklif] [Tahsilat Gir] [Masraf Gir] [⋯ Mesai Gir, Satın Alma Talebi, Görev Ekle, Müşteri Ekle, Metraj Hesapla, Ürün Ekle, Personel Ekle, Kullanıcı Ekle].
- **Mobile quick actions:** Teklif Oluştur, Tahsilat Gir, Masraf Gir, Mesai Gir, Satın Alma Talebi, Görev Ekle, Not Ekle, Müşteri Ekle, Metraj Hesapla.
- **Summary:** "Bugün 7 iş senin sıranda; 3 tanesi acil."
- **KPI tiles:** Açık alacak 5,1 Mn TL · Bu ay net nakit +420.000 TL · Teklif hattı 2,3 Mn TL · Proje nakit dengesi +2,2 Mn TL. The receivable tile adds "Diğer: 45.000 $".
- **Top row:**
  - Dikkat, **Senin sıran:** plan_item_overdue, sales_invoice_overdue, offer_expired_awaiting, over_budget, project_past_end, purchase_request_approval, progress_claim_certify, rfq_award, budget_adjustment_approval, contract_activation, offer_accepted_not_converted (as present in the data). The owner holds every act permission, so nearly everything is in his lane.
  - Dikkat, **Takipte:** change_order_awaiting_customer.
  - Dikkat, **Yaklaşan:** plan items, offer expiries, PO deliveries, milestones, project ends.
  - Nakit Akışı on the right.
- **Bands:** all 4, with 15 standard + 3 compact cards.
  - PROJE & SAHA = Projeler, Görevler, Şantiye, then Sözleşmeler and Mesai split 6/6.
  - FİRMA KAYITLARI = Müşteriler, Personel, Ürünler & Zam, then Ekip full width (wide), then the 3 compact cards.
- **Akış:** Son Hareketler (10) + Bildirimler (4 okunmamış).
- **Mobile:** the same order. Firma Kayıtları is one grouped card. There is no Bildirimler card.

### 8.2 New company, day 1 (owner, no data)

- **Sections:** all present with zero counts. `onboarding` = {customer ✗, catalog ✓ "628 ürün" (if synced) or ✗, employee ✗, team ✗, first_offer ✗, convert ✗}.
- **Page:**
  - header + quick actions;
  - summary "Bugün seni bekleyen bir iş yok.";
  - the **Kurulum — ilk adımlar** card (1 / 6) in place of KPI + top row;
  - a "Bölümler" grid: Proje modülleri placeholder (full width), then Teklifler (empty + Yeni Teklif), Mesai / Puantaj ("Mesai takibi için önce personel ekle." + Personel Ekle), Müşteriler (Müşteri Ekle), Personel (Personel Ekle), Ürünler & Zam (catalog count or empty + Ürünlere git; Dikkat is hidden in this mode, so the price_sync_never note shows as a card footer line), Ekip ("Ekipte yalnızca sen varsın." + Kullanıcı Ekle), then compact Metraj / Tedarikçiler / Maliyet Kodları;
  - Akış: Bildirimler "Yeni bildirim yok."; Son Hareketler hidden (empty).
- **After "Gizle":** the normal layout, with honest zero KPIs; Dikkat shows the success line.
- **Mode ends** automatically once the first offer or project exists.

### 8.3 Field worker (Saha): member of 2 projects, linked to an employee

- **Permissions:** projects.read, projects.tasks.read / update, projects.operations.read / manage, attendance.read, notifications.read.
- **Sections:** projects (rows carry Süre + Görev bars only; collection_pct / current_value = null; no money anywhere), tasks, operations, attendance, notifications, activity (task, schedule, member, file, photo, note and project_* events of member projects only).
- **Viewer:** all_projects = false; count = 2 → scope line "Üyesi olduğun 2 projenin verileri gösteriliyor."
- **Web header:** no quick actions (the field role has no create permissions and web has no note action). **Mobile:** quick action "Not Ekle" only.
- **KPI tiles:** Aktif proje 2 · Açık görevim 6 ("2 gecikmiş · 1 bugün") · Ekipte geciken görev 7 · Bugün sahada 25 / 30 ("Firma geneli · 2 kişi girilmedi").
- **Top row:**
  - Dikkat, **Senin sıran:** my_task_overdue, my_task_due_today, milestone_overdue (the field role holds operations.manage).
  - **Takipte:** empty. **Yaklaşan:** my_task_due, milestone_end, project_end.
  - **Hidden:** team_task_* (no tasks.create), project_past_end (no projects.update), attendance_not_recorded (no attendance.manage).
  - Right panel: **Görevlerim** (promoted, 5 tasks).
- **Modules:** 4 standard cards (Projeler, Görevler without its list, Şantiye, Mesai) → density mode "BÖLÜMLER".
  - At T3: Projeler, Görevler, Şantiye in 3 columns, then Mesai full width (wide).
  - Mobile: KPI → Dikkat → Not Ekle → Görevlerim → BÖLÜMLER cards → Son Hareketler.
- **Not linked to an employee:** tasks.mine.linked_employee = false. The KPI list becomes Aktif proje, Ekipte geciken görev, Bugün sahada, Okunmamış bildirim; there is no Görevlerim panel; the Görevler card shows the "Hesabın bir personel kaydına bağlı değil…" note plus the team stats.
- **Zero memberships:** the Projeler card shows the restricted empty state, and the scope line uses its 0-count text.

### 8.4 Finance user (Finans): member of 3 projects

- **Permissions:** projects.read, finance.read / manage, budget.*, cost_control.*, contracts.* (+ lifecycle), procurement.* (+ approve), subcontracts.* (+ approve), subcontract_claims.* (+ certify), subcontract_payments.*, organization.cost_codes.*, organization.suppliers.*, notifications.read.
- **Sections:** projects (rows: Süre + Tahsilat, no Görev), finance, change_orders, contracts, procurement, subcontracts (claims + payments), cost_control (all blocks), suppliers (+ ordered_this_month), cost_codes (+ expenses_without_code_month), notifications, activity (finance, procurement, budget, cost, contract and subcontract events).
- **No** `tasks`: `/tasks/mine` is never called. This fixes today's mobile 403 and the fake "0".
- **Scope line:** "Üyesi olduğun 3 projenin verileri gösteriliyor."
- **Web quick actions:** [Tahsilat Gir] [Masraf Gir] [⋯ Satın Alma Talebi]. **Mobile:** Tahsilat Gir, Masraf Gir, Satın Alma Talebi.
- **KPI tiles:** Açık alacak · Bu ay net nakit · Proje nakit dengesi · Aktif proje (over member projects only).
- **Top row:**
  - Dikkat, **Senin sıran:** plan_item_overdue, sales_invoice_overdue, purchase_request_approval, purchase_order_draft, rfq_award, rfq_no_quote, po_late_delivery, progress_claim_certify, claim_certified_unpaid, subcontract_co_approval, budget_adjustment_approval, over_budget, active_without_budget, contract_activation, contract_past_completion, active_without_contract.
  - **Takipte:** change_order_awaiting_customer.
  - **Yaklaşan:** plan_item_due, po_delivery, project_end.
  - Right panel: Nakit Akışı.
- **Bands:**
  - NAKİT & SATIŞ: Proje Finansı + Ek İşler (6/6).
  - PROJE & SAHA: Projeler + Sözleşmeler (6/6).
  - TEDARİK & MALİYET: Satın Alma, Taşeron, Bütçe & Maliyet.
  - FİRMA KAYITLARI: compact Tedarikçiler + Maliyet Kodları (6/6).
  - Total 7 standard cards → band headings are shown.
- **Mobile:**
  - the Görevler tab stays hidden (existing shell rule);
  - rows open the exact talep / sipariş / RFQ-karşılaştır / hakediş / değişiklik-emri screens;
  - FİRMA KAYITLARI holds Tedarikçiler and Maliyet Kodları rows with the note "Bu kayıtlar web panelinden yönetilir."

(Reference, project manager: KPI tiles Aktif proje · Açık görevim · Ekipte geciken görev · Okunmamış bildirim.
- **Senin sıran:** own tasks, team_task_* (tasks.create), milestone_overdue, rfq_no_quote / po_late_delivery (procurement.manage), active_without_contract (contracts.manage), project_past_end (projects.update).
- **Takipte:** PR / PO / RFQ / claim / budget / contract approvals (can_act false).
- **Right panel:** Görevlerim.
- **Bands:** PROJE & SAHA (Projeler, Görevler, Şantiye, Sözleşmeler), TEDARİK & MALİYET (all 3), FİRMA KAYITLARI (Müşteriler, Ürünler & Zam + Metraj / Tedarikçiler / Maliyet Kodları).
- **Not shown:** finance, offers or attendance.)

---

## 9. (E) Explicit non-goals (v1)

1. No dark mode on either platform, and no chart library (recharts, fl_chart and similar).
2. No user-customisable, draggable or hideable cards, and no per-user layout settings. The only persisted preference is the onboarding "Gizle".
3. No real-time push or polling. Refresh is manual, plus on app resume after more than 5 minutes on mobile.
4. No inline approve / reject / certify on the home page. Every approval opens its record screen.
5. No payroll, salary or wage figures. No offer internal pricing, markups or supplier prices.
6. No month-over-month deltas or comparisons. No sparklines. No time series besides 6-month cash.
7. No new web pages for Görevler, Bildirimler or Sprint-5 Taşeron / Hakediş. The Topbar bell stays "yakında". Web deep-links to project tabs instead.
8. No fix for the existing `GET /projects` money leak or the `/projects/{id}/events` finance-metadata leak (these are tracked separately). The dashboard does not reuse either; the pickers use `/dashboard/project-options`.
9. No notification access filtering (it matches the existing bell and screen semantics).
10. No holiday calendar: `is_workday` = Monday–Saturday.
11. No `?sections=` partial fetch in v1. Retry refetches the whole snapshot.
12. No web golden or visual regression tests (mobile goldens only). No CI setup.
13. No mobile screens for Ürünler, Personel, Tedarikçiler, Maliyet Kodları or Kullanıcılar: they are summary rows only.
14. No Şantiye photo strip (P2). No "Fotoğraf Ekle" quick action (P2). No org-level activity page.
15. No mobile-web sidebar drawer. Only the W0 CSS forced-collapse.
16. No project-level "behind schedule" judgement, and no budget-vs-task-progress comparison (D18).

---

## 10. Delivery order and acceptance

**Build order:**
1. B0, B1 (backend prerequisites)
2. Fixtures in `docs/dashboard/fixtures/*.json`, written to §4.4 with §6.8 numbers
3. `/dashboard` + `/dashboard/project-options` + tests
4. **In parallel:**
   - web: W0, `format.ts`, `lib/dashboard.ts` + tests, primitives, cards, `?tab=` support;
   - mobile: formatters, models / registry + tests, primitives, cards, `?grup` / `alt` support, goldens.
5. Docs: `API_CONTRACT.md`, HANDOFF, `MOBILE_BACKEND_GAPS`.

**Acceptance checklist:**
- **Owner fixture:** 18 module cards plus 2 feed panels on web; KPI set, bands and Dikkat lanes exactly as in §8.1; no horizontal scroll at container widths 1368, 1200, 1040, 952, 784, 696, 528 and 318.
- **Field fixture:** no money value anywhere in the DOM or widget tree (grep the rendered text for "TL"; expect none besides none); density mode; Görevlerim promoted.
- **Finance fixture:** no Görevler card; no `/tasks/mine` request; approvals in Senin sıran.
- **Empty company:** checklist + placeholder; no KPI row.
- **Section error:** one inline error card; the rest intact; the Dikkat partial note is shown.
- **Whole failure:** the header and quick actions still render, plus Kısayollar.
- **Tests:** all backend security tests pass; `node --test` passes; `flutter test` passes, including the 12 goldens generated on the developer Mac and the 320dp / 1.6× tests.
- **Consistency:** web and mobile show identical numbers, labels and KPI choices for the same fixture (the shared-fixture tests enforce this).

---

## Appendix Z: judge problems → resolution

| Problem raised | Resolution |
|---|---|
| Offers must exclude `is_passive`; users must exclude `deleted_at` | §4.5 offers / users; security test 10 |
| "Offers have no decision timestamp" (wrong) | D12, B1, `offer_events`-based `decided_at` |
| C's budget-vs-task-count meter misleads | D18: no such meter; "Görev %" label |
| C's warning hue too close to gold | D7: no new hue |
| C had no web targets for Tahsilat / Masraf | §3.5 ProjectPicker → `?tab=finans` |
| 6-month cash chart deferred | In v1 (§4.5 finance `trend_6m`) |
| Mobile links stopped at the project group | D3 + §6.6 exact routes |
| Duplicate facts in 4 places; over-alarmed flags | D11; setup codes are `action` not `danger`; card-only notes |
| A's drafting residue; "B" contradictions | §3.4 clean sentence; D5 single rule |
| B's info-only inbox noise | D10: info facts are card notes only |
| `loading.tsx` streaming caveat | D9 in-page Suspense, body never throws |
| Pay-to-see gap: TAŞERON tile without claims.read | claims block is null without claims.read; no such KPI |
| Possible double count of legacy and Sprint-5 payments | Verified physically separate (migration 0039); summed exactly like `GetProjectFinancialSummary` |
| Query-param inconsistency | D4 `?tab=` / `?grup=&alt=` |
| Endpoint is the critical path; security tests | §4.11 |
| `team_task_unassigned` in the field lane | act gate = projects.tasks.create |
| `&bolum=` anchors that exist nowhere | replaced by real `alt=` sub-views (§6.1 modify list) |
| Mesai Gir gate | attendance.manage AND employees.read, both platforms |
| `EVENT_LABELS` location | `lib/events.ts` merging ProfitabilitySection + ActivityTimeline; mobile copy |
| Greeting breaks the mobile test | D6 keeps "Merhaba, {ad}" |
| B's `offers.by_currency[TRY]` hard-coded | D13 `by_currency[0]` after server sort |
| Tier changing with data breaks stable positions | fixed card sizes per module (§1.2) |
| Paths in the API couple to the mobile router | D3 typed `ref` |
| Pickers fetch `GET /projects` (money leak) | D16 `/dashboard/project-options` |
| Attendance org-wide shown to field | D15 "Firma geneli" label, deliberate |
| Istanbul "today" inconsistency | D20 / B0 pool timezone + `IsPastDue` callers |
| primary_currency undefined | D13 from `organization_commercial_settings` |
| Clutter from C's density | 4 KPI tiles, 3 project rows, no anchor row, grouped mobile registries |
| Field users had no quick actions | mobile "Not Ekle" (operations.manage) |
