import { EMPTY } from "@/lib/dashboard";
import { formatCount } from "@/lib/format";

import { CompactModuleCard } from "../CompactModuleCard";
import type { CardContext } from "../context";

// Tedarikçiler (kompakt); satın alma okuma izniyle bu ay sipariş verilenler.
export function SuppliersCard({ ctx }: { ctx: CardContext }) {
  const s = ctx.data.sections.suppliers;
  if (!s) return <CompactModuleCard moduleKey="suppliers" ctx={ctx} />;
  if (s.active + s.inactive === 0) return <CompactModuleCard moduleKey="suppliers" ctx={ctx} value={EMPTY.suppliers} />;
  const notes = s.ordered_this_month !== null ? [`Bu ay ${formatCount(s.ordered_this_month)} tedarikçiden sipariş verildi`] : [];
  return (
    <CompactModuleCard
      moduleKey="suppliers"
      ctx={ctx}
      value={`${formatCount(s.active)} aktif · ${formatCount(s.inactive)} pasif`}
      notes={notes}
    />
  );
}
