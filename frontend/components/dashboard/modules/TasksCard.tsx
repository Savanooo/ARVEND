import { COPY, EMPTY } from "@/lib/dashboard";
import { formatCount } from "@/lib/format";

import { Metric, Note, Stat, StatGrid } from "../card-parts";
import type { CardContext } from "../context";
import { MissingModule, ModuleCard } from "../ModuleCard";
import { TaskRow } from "../rows";

// Görevler: izleyicinin personel kaydına atanmış görevleri + ekip
// (üyesi olduğu projeler) sayıları. "Görev %" ağırlıksız görev sayısıdır,
// bütçeyle karşılaştırılmaz. Web'de görev sayfası yok: satırlar projenin
// Operasyon sekmesini açar. Görevlerim üst satıra taşındıysa liste burada
// tekrarlanmaz.
export function TasksCard({ ctx }: { ctx: CardContext }) {
  const s = ctx.data.sections.tasks;
  if (!s) return <MissingModule moduleKey="tasks" ctx={ctx} />;
  const m = s.mine;
  const t = s.team;
  const linked = m.linked_employee;

  let aside: React.ReactNode = null;
  if (!linked) {
    // Personel kaydı olmayan yönetici için uyarı gerekmez (görev atanmıyor olabilir).
    if (!ctx.data.viewer.is_admin) aside = <Note>{EMPTY.tasksNotLinked}</Note>;
  } else if (!ctx.promotedMyTasks) {
    aside =
      m.items.length > 0 ? (
        <div className="flex flex-col">
          {m.items.slice(0, 5).map((task, i) => (
            <div key={task.ref.id} className={i < 3 ? "" : "hidden @3xl/card:block"}>
              <TaskRow task={task} today={ctx.data.today} inset />
            </div>
          ))}
        </div>
      ) : (
        <p className="text-sm text-text-muted">{COPY.myTasksEmpty}</p>
      );
  }

  return (
    <ModuleCard
      moduleKey="tasks"
      ctx={ctx}
      main={
        <>
          {linked ? (
            <Metric label="Açık görevim" value={formatCount(m.open)} />
          ) : (
            <Metric label="Ekipte açık görev" value={formatCount(t.open)} />
          )}
          <StatGrid>
            <Stat label="Gecikmiş" value={formatCount(linked ? m.overdue : t.overdue)} />
            <Stat label="Bugün" value={formatCount(linked ? m.due_today : t.due_today)} />
            <Stat label="Atanmamış" value={formatCount(t.unassigned)} />
            <Stat label="Son 7 günde tamamlanan" value={formatCount(t.completed_7d)} />
          </StatGrid>
        </>
      }
      aside={aside ?? undefined}
    />
  );
}
