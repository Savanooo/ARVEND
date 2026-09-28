import { COPY, EMPTY } from "@/lib/dashboard";
import { formatCompactMoney, formatCount } from "@/lib/format";

import { EmptyNote, Metric, Money, Note, Stat, StatGrid } from "../card-parts";
import type { CardContext } from "../context";
import { MissingModule, ModuleCard } from "../ModuleCard";

// Ek İşler (müşteri değişiklik emirleri): müşteri onayında, taslak, bu ay
// onaylanan net etki (işaretli).
export function ChangeOrdersCard({ ctx }: { ctx: CardContext }) {
  const s = ctx.data.sections.change_orders;
  if (!s) return <MissingModule moduleKey="change_orders" ctx={ctx} />;
  const rows = s.by_currency;
  const c = rows[0];
  const quiet = !c || (c.awaiting_customer.count === 0 && c.draft.count === 0 && Math.round(c.approved_net_this_month) === 0);
  if (quiet && rows.length <= 1) {
    return <ModuleCard moduleKey="change_orders" ctx={ctx} main={<EmptyNote text={EMPTY.changeOrders} />} />;
  }
  const currency = c?.currency ?? ctx.data.primary_currency;
  return (
    <ModuleCard
      moduleKey="change_orders"
      ctx={ctx}
      main={
        <>
          <Metric
            label="Müşteri onayında"
            value={
              <>
                {formatCount(c?.awaiting_customer.count ?? 0)} · <Money value={c?.awaiting_customer.amount ?? 0} currency={currency} />
              </>
            }
          />
          <StatGrid>
            <Stat
              label="Taslak"
              value={
                <>
                  {formatCount(c?.draft.count ?? 0)} · <Money value={c?.draft.amount ?? 0} currency={currency} />
                </>
              }
            />
            {/* İşaretli ama NÖTR renk: net eksiltme olağan bir sözleşme olayıdır,
                alarm rengi yalnızca Dikkat ve kart alt satırında (§1.3 kural 8). */}
            <Stat
              label="Bu ay onaylanan (net)"
              value={<Money value={c?.approved_net_this_month ?? 0} currency={currency} signed />}
            />
          </StatGrid>
          {rows.length > 1 && (
            <Note>
              {COPY.other(
                rows
                  .slice(1)
                  .map((r) => `${formatCount(r.awaiting_customer.count)} · ${formatCompactMoney(r.awaiting_customer.amount, r.currency)}`)
                  .join(" · ")
              )}
            </Note>
          )}
        </>
      }
    />
  );
}
