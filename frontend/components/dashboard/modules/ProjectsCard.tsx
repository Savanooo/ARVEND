import Link from "next/link";

import { SegmentBar } from "@/components/ui/SegmentBar";
import { FOCUS_RING } from "@/components/ui/styles";
import { EMPTY } from "@/lib/dashboard";
import { formatCount } from "@/lib/format";

import { CtaLink, EmptyNote, Metric, Stat, StatGrid } from "../card-parts";
import { canAll, type CardContext } from "../context";
import { MissingModule, ModuleCard } from "../ModuleCard";
import { ProjectListRow } from "../rows";

// Projeler (üyelik kapsamlı): durum dağılımı + sunucunun sıraladığı açık
// projeler (dar kartta 3, geniş modda 5 satır). Tahsilat çubuğu yalnızca
// finans izniyle, görev çubuğu yalnızca görev izniyle gelir (null -> yok).
export function ProjectsCard({ ctx }: { ctx: CardContext }) {
  const s = ctx.data.sections.projects;
  if (!s) return <MissingModule moduleKey="projects" ctx={ctx} />;
  const c = s.counts;

  if (c.total === 0) {
    if (!ctx.data.viewer.all_projects) {
      return <ModuleCard moduleKey="projects" ctx={ctx} main={<EmptyNote text={EMPTY.projectsRestricted} />} />;
    }
    return (
      <ModuleCard
        moduleKey="projects"
        ctx={ctx}
        main={
          <EmptyNote
            text={EMPTY.projectsAll}
            action={canAll(ctx, ["offers.read"]) ? <CtaLink href="/teklifler" label="Tekliflere git" /> : undefined}
          />
        }
      />
    );
  }

  const aside =
    s.top.length > 0 ? (
      <div className="flex flex-col">
        {s.top.slice(0, 5).map((p, i) => (
          <ProjectListRow key={p.ref.id} project={p} className={i < 3 ? "flex" : "hidden @3xl/card:flex"} />
        ))}
      </div>
    ) : (
      <div className="flex flex-col items-start gap-2">
        <p className="text-sm text-text-muted">{EMPTY.projectsNoOpen(c.completed)}</p>
        {c.completed > 0 && (
          <Link href="/projeler?status=completed" className={`rounded-sm text-xs font-medium text-text-muted hover:text-gold hover:underline ${FOCUS_RING}`}>
            Tamamlananlar →
          </Link>
        )}
      </div>
    );

  return (
    <ModuleCard
      moduleKey="projects"
      ctx={ctx}
      main={
        <>
          <Metric label="Aktif proje" value={formatCount(c.active)} detail={`toplam ${formatCount(c.total)}`} />
          <StatGrid>
            <Stat label="Planlanan" value={formatCount(c.planned)} />
            <Stat label="Bitişi geçen" value={formatCount(s.past_end_date)} />
            <Stat label="30 günde bitecek" value={formatCount(s.ending_within_30d)} />
          </StatGrid>
          <SegmentBar
            ariaLabel="Proje durumları"
            segments={[
              { key: "planned", value: c.planned, tone: "muted", label: "Planlandı" },
              { key: "active", value: c.active, tone: "gold", label: "Devam" },
              { key: "paused", value: c.paused, tone: "muted-dark", label: "Beklemede" },
              { key: "completed", value: c.completed, tone: "success", label: "Tamamlandı" },
            ]}
            legendExtra={[{ key: "cancelled", label: "İptal", value: c.cancelled }]}
          />
        </>
      }
      aside={aside}
    />
  );
}
