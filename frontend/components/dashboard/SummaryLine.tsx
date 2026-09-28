import { scopeLine, summarySentence, type DashboardResponse } from "@/lib/dashboard";
import { formatHm } from "@/lib/format";

import { RefreshButton } from "./RefreshButton";

// Özet cümlesi (yalnızca şerit sayıları), üyelik kapsamı satırı,
// "Güncellendi 09:41" (sunucunun İstanbul saati) ve Yenile.
export function SummaryLine({ data }: { data: DashboardResponse }) {
  const scope = scopeLine(data.viewer);
  return (
    <div className="flex flex-wrap items-start justify-between gap-x-4 gap-y-2">
      <div className="min-w-0">
        <p className="text-sm text-text">{summarySentence(data.agenda)}</p>
        {scope && <p className="mt-0.5 text-xs text-text-muted">{scope}</p>}
      </div>
      <div className="flex shrink-0 items-center gap-1">
        <RefreshButton generatedAt={data.generated_at} updatedHm={formatHm(data.generated_at)} />
      </div>
    </div>
  );
}
