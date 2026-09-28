import { SegmentBar } from "@/components/ui/SegmentBar";
import { COPY, EMPTY } from "@/lib/dashboard";
import { formatCompactMoney, formatCount } from "@/lib/format";

import { EmptyNote, Metric, Money, Note, Stat, StatGrid } from "../card-parts";
import type { CardContext } from "../context";
import { MissingModule, ModuleCard } from "../ModuleCard";

// Bütçe & Maliyet: bütçe okuma izniyle bütçe durumları ve revizyonlar,
// maliyet kontrolü okuma izniyle taahhüt ve bütçe aşımı (izinsiz blok null).
export function CostControlCard({ ctx }: { ctx: CardContext }) {
  const s = ctx.data.sections.cost_control;
  if (!s) return <MissingModule moduleKey="cost_control" ctx={ctx} />;
  const b = s.budgets;
  const ob = s.over_budget;
  const pa = s.pending_adjustments;
  const ca = s.committed_active;

  const noBudgets = b !== null && b.draft + b.baselined === 0;
  const quiet = noBudgets && (ob?.count ?? 0) === 0 && (pa?.count ?? 0) === 0 && (ca?.length ?? 0) === 0;
  if (quiet) return <ModuleCard moduleKey="cost_control" ctx={ctx} main={<EmptyNote text={EMPTY.costControl} />} />;

  const primary = ob ? (
    <Metric label="Bütçeyi aşan proje" value={formatCount(ob.count)} />
  ) : b ? (
    <Metric label="Onaylı bütçe" value={`${formatCount(b.baselined)} / ${formatCount(b.open_projects)}`} detail="proje" />
  ) : null;

  return (
    <ModuleCard
      moduleKey="cost_control"
      ctx={ctx}
      main={
        <>
          {primary}
          <StatGrid>
            {pa && <Stat label="Onayda revizyon" value={formatCount(pa.count)} />}
            {ca && (
              <Stat
                label="Aktif taahhüt"
                value={
                  ca[0] ? <Money value={ca[0].amount} currency={ca[0].currency} /> : formatCompactMoney(0, ctx.data.primary_currency)
                }
              />
            )}
            {b && <Stat label="Bütçesiz açık proje" value={formatCount(b.none)} />}
          </StatGrid>
          {b && (
            <SegmentBar
              ariaLabel="Açık projelerin bütçe durumu"
              segments={[
                { key: "none", value: b.none, tone: "muted", label: "Bütçesiz" },
                { key: "draft", value: b.draft, tone: "gold", label: "Taslak" },
                { key: "baselined", value: b.baselined, tone: "success", label: "Onaylı" },
              ]}
            />
          )}
          {/* over_budget.worst burada yazılmaz: aşan proje zaten Dikkat
              satırında ve kartın alt satırında (D11: bir olgu en çok iki yerde). */}
          {ca && ca.length > 1 && (
            <Note>{COPY.other(ca.slice(1).map((m) => formatCompactMoney(m.amount, m.currency)).join(" · "))}</Note>
          )}
        </>
      }
    />
  );
}
