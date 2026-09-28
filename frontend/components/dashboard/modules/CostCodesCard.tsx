import { EMPTY } from "@/lib/dashboard";
import { formatCount } from "@/lib/format";

import { CompactModuleCard } from "../CompactModuleCard";
import type { CardContext } from "../context";

// Maliyet Kodları (kompakt); maliyet kontrolü okuma izniyle bu ay kodsuz masraflar.
export function CostCodesCard({ ctx }: { ctx: CardContext }) {
  const s = ctx.data.sections.cost_codes;
  if (!s) return <CompactModuleCard moduleKey="cost_codes" ctx={ctx} />;
  if (s.active + s.inactive === 0) return <CompactModuleCard moduleKey="cost_codes" ctx={ctx} value={EMPTY.costCodes} />;
  const notes =
    s.expenses_without_code_month !== null && s.expenses_without_code_month > 0
      ? [`Bu ay ${formatCount(s.expenses_without_code_month)} masrafta maliyet kodu yok`]
      : [];
  return (
    <CompactModuleCard
      moduleKey="cost_codes"
      ctx={ctx}
      value={`${formatCount(s.active)} aktif · ${formatCount(s.inactive)} pasif`}
      notes={notes}
    />
  );
}
