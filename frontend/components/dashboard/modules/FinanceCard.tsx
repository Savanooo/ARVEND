import { ProgressBar } from "@/components/ui/ProgressBar";
import { COPY, EMPTY, formatPercentNumber, quickActionFor } from "@/lib/dashboard";
import { formatCompactMoney, formatPercent } from "@/lib/format";

import { EmptyNote, Metric, Money, Note, Stat, StatGrid } from "../card-parts";
import type { CardContext } from "../context";
import { MissingModule, ModuleCard } from "../ModuleCard";
import { PickerActionButton } from "../PickerActionButton";

// Proje Finansı: portföy (güncel proje bedeli toplamı), tahsilat oranı,
// açık alacak, gerçekleşen maliyet -- birincil para birimi; diğerleri
// "Diğer: …" satırında (para birimleri ASLA toplanmaz).
export function FinanceCard({ ctx }: { ctx: CardContext }) {
  const s = ctx.data.sections.finance;
  if (!s) return <MissingModule moduleKey="finance" ctx={ctx} />;
  const rows = s.by_currency;
  const f = rows[0];

  if (!f) {
    const collect = quickActionFor(ctx.user, "collection");
    return (
      <ModuleCard
        moduleKey="finance"
        ctx={ctx}
        main={
          <EmptyNote
            text={EMPTY.finance}
            action={collect?.pickerTab ? <PickerActionButton tab={collect.pickerTab} label={collect.label} /> : undefined}
          />
        }
      />
    );
  }

  const pct = f.collection_pct;
  return (
    <ModuleCard
      moduleKey="finance"
      ctx={ctx}
      main={
        <>
          <Metric label="Portföy değeri" value={<Money value={f.portfolio_value} currency={f.currency} />} />
          {pct !== null && (
            <div>
              <ProgressBar pct={pct} tone="success" label="Tahsilat" valueText={`Tahsilat yüzde ${formatPercentNumber(pct)}`} />
              <p className="mt-1 text-xs text-text-muted">{formatPercent(pct)} tahsil edildi</p>
            </div>
          )}
          <StatGrid>
            <Stat label="Tahsil edilen" value={<Money value={f.collected_total} currency={f.currency} />} />
            <Stat label="Açık alacak" value={<Money value={f.open_receivable} currency={f.currency} />} />
            <Stat label="Harcanan" value={<Money value={f.realized_cost} currency={f.currency} />} />
          </StatGrid>
          {/* Diğer para birimlerinin açık alacağı ("Açık alacak" KPI kutusuyla aynı satır). */}
          {rows.length > 1 && (
            <Note>{COPY.other(rows.slice(1).map((r) => formatCompactMoney(r.open_receivable, r.currency)).join(" · "))}</Note>
          )}
        </>
      }
    />
  );
}
