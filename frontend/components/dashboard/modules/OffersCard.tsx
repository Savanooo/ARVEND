import { SegmentBar } from "@/components/ui/SegmentBar";
import { COPY, EMPTY, quickActionFor } from "@/lib/dashboard";
import { formatCompactMoney, formatCount, formatPercent } from "@/lib/format";

import { CtaLink, EmptyNote, Metric, MiniLabel, Money, Note, Stat, StatGrid } from "../card-parts";
import type { CardContext } from "../context";
import { MissingModule, ModuleCard } from "../ModuleCard";

// Teklifler (arşivlenmiş/pasif teklifler hariç, firma geneli): yanıt
// bekleyen tutar, taslak, müşterinin incelediği, son 90 gün kabul/red.
export function OffersCard({ ctx }: { ctx: CardContext }) {
  const s = ctx.data.sections.offers;
  if (!s) return <MissingModule moduleKey="offers" ctx={ctx} />;

  if (s.total_active === 0) {
    const create = quickActionFor(ctx.user, "offer");
    return (
      <ModuleCard
        moduleKey="offers"
        ctx={ctx}
        main={<EmptyNote text={EMPTY.offers} action={create?.href ? <CtaLink href={create.href} label={create.label} /> : undefined} />}
      />
    );
  }

  const rows = s.by_currency;
  const o = rows[0];
  const currency = o?.currency ?? ctx.data.primary_currency;
  const accepted = o?.accepted_90d.count ?? 0;
  const rejected = o?.rejected_90d.count ?? 0;
  const notes: string[] = [];
  if (s.expiring_within_7d > 0) notes.push(`${formatCount(s.expiring_within_7d)} teklifin süresi 7 gün içinde doluyor`);
  if (rows.length > 1) {
    notes.push(COPY.other(rows.slice(1).map((r) => formatCompactMoney(r.awaiting_customer.amount, r.currency)).join(" · ")));
  }

  return (
    <ModuleCard
      moduleKey="offers"
      ctx={ctx}
      main={
        <>
          <Metric
            label="Yanıt bekleyen"
            value={<Money value={o?.awaiting_customer.amount ?? 0} currency={currency} />}
            detail={`${formatCount(o?.awaiting_customer.count ?? 0)} teklif`}
          />
          <StatGrid>
            <Stat label="Taslak" value={formatCount(o?.draft.count ?? 0)} />
            <Stat label="Müşteri inceledi (7 gün)" value={formatCount(s.viewed_by_customer_7d)} />
            <Stat
              label="Kabul oranı (90 gün)"
              value={s.conversion_rate_90d_pct === null ? "—" : formatPercent(s.conversion_rate_90d_pct)}
            />
          </StatGrid>
          <div className="flex flex-col gap-1.5">
            <MiniLabel>Son 90 gün</MiniLabel>
            <SegmentBar
              ariaLabel="Son 90 gün teklif kararları"
              segments={[
                { key: "accepted", value: accepted, tone: "success", label: "Kabul" },
                { key: "rejected", value: rejected, tone: "danger", label: "Red" },
              ]}
            />
          </div>
          {notes.map((n) => (
            <Note key={n}>{n}</Note>
          ))}
        </>
      }
    />
  );
}
