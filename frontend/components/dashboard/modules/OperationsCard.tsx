import { EMPTY } from "@/lib/dashboard";
import { formatCount } from "@/lib/format";

import { EmptyNote, Metric, Stat, StatGrid } from "../card-parts";
import type { CardContext } from "../context";
import { MissingModule, ModuleCard } from "../ModuleCard";

// Şantiye: bugün projelere atanmış ekip, iş programı kalemleri, fotoğraflar.
export function OperationsCard({ ctx }: { ctx: CardContext }) {
  const s = ctx.data.sections.operations;
  if (!s) return <MissingModule moduleKey="operations" ctx={ctx} />;
  const quiet = s.active_crew === 0 && s.milestones.due_7d === 0 && s.milestones.overdue === 0 && s.photos_7d === 0;
  if (quiet) return <ModuleCard moduleKey="operations" ctx={ctx} main={<EmptyNote text={EMPTY.operations} />} />;
  return (
    <ModuleCard
      moduleKey="operations"
      ctx={ctx}
      main={
        <>
          <Metric label="Sahadaki ekip" value={formatCount(s.active_crew)} detail="kişi" />
          <StatGrid>
            <Stat label="7 günde biten iş kalemi" value={formatCount(s.milestones.due_7d)} />
            <Stat label="Geciken iş kalemi" value={formatCount(s.milestones.overdue)} />
            <Stat label="Fotoğraf (7 gün)" value={formatCount(s.photos_7d)} />
          </StatGrid>
        </>
      }
    />
  );
}
