import { SegmentBar } from "@/components/ui/SegmentBar";
import { EMPTY } from "@/lib/dashboard";
import { formatCount } from "@/lib/format";

import { EmptyNote, Metric, Stat, StatGrid } from "../card-parts";
import type { CardContext } from "../context";
import { MissingModule, ModuleCard } from "../ModuleCard";

// Sözleşmeler (proje sözleşmesi kaydı): durum dağılımı, sözleşmesiz aktif
// proje, planlanan bitişi geçen.
export function ContractsCard({ ctx }: { ctx: CardContext }) {
  const s = ctx.data.sections.contracts;
  if (!s) return <MissingModule moduleKey="contracts" ctx={ctx} />;
  const c = s.counts;
  const none = c.draft + c.active + c.completed + c.cancelled + c.terminated === 0;
  if (none && s.active_projects_without_contract === 0) {
    return <ModuleCard moduleKey="contracts" ctx={ctx} main={<EmptyNote text={EMPTY.contracts} />} />;
  }
  return (
    <ModuleCard
      moduleKey="contracts"
      ctx={ctx}
      main={
        <>
          <Metric label="Aktif sözleşme" value={formatCount(c.active)} />
          <StatGrid>
            <Stat label="Taslak" value={formatCount(c.draft)} />
            <Stat label="Sözleşmesiz aktif proje" value={formatCount(s.active_projects_without_contract)} />
            <Stat label="Bitişi geçen" value={formatCount(s.past_planned_completion)} />
          </StatGrid>
          <SegmentBar
            ariaLabel="Sözleşme durumları"
            segments={[
              { key: "draft", value: c.draft, tone: "muted", label: "Taslak" },
              { key: "active", value: c.active, tone: "gold", label: "Aktif" },
              { key: "completed", value: c.completed, tone: "success", label: "Tamamlandı" },
              // İptal ve fesih tek parça: ikisi de sonlanmış sözleşme (sayı, para değil).
              { key: "ended", value: c.cancelled + c.terminated, tone: "danger", label: "İptal/Fesih" },
            ]}
          />
        </>
      }
    />
  );
}
