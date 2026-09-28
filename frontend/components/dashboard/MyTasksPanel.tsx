import { Badge } from "@/components/ui/Badge";
import { LABEL } from "@/components/ui/styles";
import { COPY, type DashboardResponse } from "@/lib/dashboard";
import { formatCount } from "@/lib/format";

import { TaskRow } from "./rows";

// Finans bölümü olmayan ama personel kaydına bağlı izleyicide (saha, proje
// yöneticisi) Dikkat'in yanındaki panel: bana atanmış açık görevler.
export function MyTasksPanel({ data }: { data: DashboardResponse }) {
  const mine = data.sections.tasks?.mine;
  const items = mine?.items ?? [];
  return (
    <section
      id="gorevlerim"
      aria-labelledby="gorevlerim-baslik"
      className="flex h-full min-h-[17.5rem] scroll-mt-4 flex-col rounded-lg border border-border bg-surface"
    >
      <header className="flex items-center justify-between gap-3 border-b border-border px-4 py-3 @4xl/home:px-5">
        <h2 id="gorevlerim-baslik" className={LABEL}>
          {COPY.myTasks}
        </h2>
        {(mine?.open ?? 0) > 0 && <Badge tone="muted">{formatCount(mine?.open ?? 0)}</Badge>}
      </header>
      {items.length > 0 ? (
        <ul className="divide-y divide-border py-1">
          {items.slice(0, 5).map((task) => (
            <li key={task.ref.id}>
              <TaskRow task={task} today={data.today} />
            </li>
          ))}
        </ul>
      ) : (
        <p className="px-4 py-4 text-sm text-text-muted @4xl/home:px-5">{COPY.myTasksEmpty}</p>
      )}
    </section>
  );
}
