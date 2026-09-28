import { ChevronRight } from "lucide-react";

import { EMPTY } from "@/lib/dashboard";
import { formatCompactMoney, formatCount } from "@/lib/format";

import { EmptyNote, Metric, Note, Stat, StatGrid } from "../card-parts";
import type { CardContext } from "../context";
import { MissingModule, ModuleCard } from "../ModuleCard";

// Satın Alma (talep -> RFQ -> sipariş), üyelik kapsamlı.
export function ProcurementCard({ ctx }: { ctx: CardContext }) {
  const s = ctx.data.sections.procurement;
  if (!s) return <MissingModule moduleKey="procurement" ctx={ctx} />;
  const pr = s.purchase_requests;
  const rfq = s.rfqs;
  const po = s.purchase_orders;
  const quiet = pr.draft + pr.submitted + rfq.issued + po.draft + po.approved_open === 0 && s.approved_this_month.length === 0;
  if (quiet) return <ModuleCard moduleKey="procurement" ctx={ctx} main={<EmptyNote text={EMPTY.procurement} />} />;

  const approved = s.approved_this_month
    .map((r) => `${formatCount(r.count)} sipariş · ${formatCompactMoney(r.amount, r.currency)}`)
    .join(" · ");
  const chevron = <ChevronRight size={12} strokeWidth={2} aria-hidden className="shrink-0" />;

  return (
    <ModuleCard
      moduleKey="procurement"
      ctx={ctx}
      main={
        <>
          <Metric label="Onay bekleyen talep" value={formatCount(pr.submitted)} />
          <StatGrid>
            <Stat label="Açık RFQ" value={formatCount(rfq.issued)} />
            <Stat label="Açık sipariş" value={formatCount(po.approved_open)} />
            <Stat label="Geciken teslimat" value={formatCount(po.late_delivery)} />
          </StatGrid>
          <p className="flex flex-wrap items-center gap-x-1.5 gap-y-1 text-xs text-text-muted">
            <span>
              Talep <span className="font-semibold tabular-nums text-text">{formatCount(pr.submitted)}</span> onayda
            </span>
            {chevron}
            <span>
              RFQ <span className="font-semibold tabular-nums text-text">{formatCount(rfq.issued)}</span> açık
            </span>
            {chevron}
            <span>
              Sipariş <span className="font-semibold tabular-nums text-text">{formatCount(po.approved_open)}</span> açık
            </span>
          </p>
          {approved && <Note>Bu ay onaylanan: {approved}</Note>}
        </>
      }
    />
  );
}
