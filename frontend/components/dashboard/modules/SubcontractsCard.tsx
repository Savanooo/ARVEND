import { Info } from "lucide-react";

import { ProgressBar } from "@/components/ui/ProgressBar";
import { COPY, EMPTY, formatPercentNumber } from "@/lib/dashboard";
import { formatCompactMoney, formatCount, formatPercent } from "@/lib/format";

import { EmptyNote, Metric, Money, Note, Stat, StatGrid } from "../card-parts";
import type { CardContext } from "../context";
import { MissingModule, ModuleCard } from "../ModuleCard";

// Taşeron (Sprint 5 sözleşmeleri). Hakediş bloğu yalnızca hakediş okuma
// izniyle, ödeme oranı/ödenmemiş yalnızca ödeme okuma izniyle gelir
// (null -> gizli). Hakediş ve değişiklik emirleri şimdilik mobilde yönetilir.
export function SubcontractsCard({ ctx }: { ctx: CardContext }) {
  const s = ctx.data.sections.subcontracts;
  if (!s) return <MissingModule moduleKey="subcontracts" ctx={ctx} />;
  const quiet =
    s.active_count === 0 &&
    s.by_currency.length === 0 &&
    (s.claims?.submitted.count ?? 0) === 0 &&
    s.change_orders_submitted.count === 0;
  if (quiet) return <ModuleCard moduleKey="subcontracts" ctx={ctx} main={<EmptyNote text={EMPTY.subcontracts} />} />;

  const rows = s.by_currency;
  const b = rows[0];
  const paid = b?.paid_pct ?? null;

  return (
    <ModuleCard
      moduleKey="subcontracts"
      ctx={ctx}
      main={
        <>
          <Metric
            label="Aktif sözleşme"
            value={
              b ? (
                <>
                  {formatCount(s.active_count)} · <Money value={b.current_value} currency={b.currency} />
                </>
              ) : (
                formatCount(s.active_count)
              )
            }
          />
          {paid !== null && (
            <div>
              <ProgressBar pct={paid} tone="success" label="Taşeron ödemesi" valueText={`Ödenen yüzde ${formatPercentNumber(paid)}`} />
              <p className="mt-1 flex items-center gap-1 text-xs text-text-muted">
                {formatPercent(paid)} ödendi
                <span title={COPY.subcontractPaidInfo} className="inline-flex">
                  <Info size={12} strokeWidth={2} aria-hidden />
                  <span className="sr-only">{COPY.subcontractPaidInfo}</span>
                </span>
              </p>
            </div>
          )}
          <StatGrid>
            {s.claims && <Stat label="Onayda hakediş" value={formatCount(s.claims.submitted.count)} />}
            {s.claims?.certified_unpaid && (
              <Stat label="Onaylı, ödenmemiş" value={formatCount(s.claims.certified_unpaid.count)} />
            )}
            <Stat label="Değişiklik emri (onayda)" value={formatCount(s.change_orders_submitted.count)} />
          </StatGrid>
          {rows.length > 1 && (
            <Note>{COPY.other(rows.slice(1).map((r) => formatCompactMoney(r.current_value, r.currency)).join(" · "))}</Note>
          )}
          <Note>{COPY.subcontractWebNote}</Note>
        </>
      }
    />
  );
}
