import Link from "next/link";

import { FOCUS_RING, LABEL } from "@/components/ui/styles";
import { COPY, projectHref, type DashboardResponse } from "@/lib/dashboard";
import { eventLabel } from "@/lib/events";
import { formatRelativeTime } from "@/lib/format";

import { SectionError } from "./SectionError";

type ActivityItem = NonNullable<DashboardResponse["sections"]["activity"]>["items"][number];

function activityHref(item: ActivityItem): string | null {
  if (item.source === "offer") return item.ref.kind === "offer" ? `/teklifler/${encodeURIComponent(item.ref.id)}` : null;
  const projectId = item.ref.project_id ?? (item.ref.kind === "project" ? item.ref.id : null);
  return projectId ? projectHref(projectId, "aktivite") : null;
}

// "Son Hareketler": izleyicinin görmeye yetkili olduğu olay tiplerinden
// (sunucu süzer) en yeni 10 kayıt. Tutar/metadata YOK; yalnızca kim, ne,
// hangi proje/teklif ve ne zaman. Zaman sunucunun generated_at'ine göre.
export function ActivityPanel({ data }: { data: DashboardResponse }) {
  const items = data.sections.activity?.items ?? [];
  const failed = data.sections.activity === undefined;
  return (
    <section aria-labelledby="son-hareketler-baslik" className="flex h-full min-h-[17.5rem] flex-col rounded-lg border border-border bg-surface">
      <header className="flex items-center justify-between gap-3 border-b border-border px-4 py-3 @4xl/home:px-5">
        <h2 id="son-hareketler-baslik" className={LABEL}>
          {COPY.activity}
        </h2>
      </header>
      {failed ? (
        <div className="p-4 @4xl/home:p-5">
          <SectionError />
        </div>
      ) : items.length === 0 ? (
        <p className="px-4 py-4 text-sm text-text-muted @4xl/home:px-5">{COPY.activityEmpty}</p>
      ) : (
        <ol className="divide-y divide-border py-1">
          {items.slice(0, 10).map((item, i) => {
            const href = activityHref(item);
            const who = [item.user_name, eventLabel(item.source, item.event_type)].filter(Boolean).join(" · ");
            const subject =
              item.source === "offer"
                ? item.offer_no
                : [item.project_no, item.project_name].filter(Boolean).join(" ");
            const content = (
              <>
                <span aria-hidden className="mt-1.5 size-1.5 shrink-0 rounded-full bg-text-muted/40" />
                <span className="min-w-0 flex-1">
                  <span className="block text-sm text-text">{who}</span>
                  {subject && <span className="block truncate text-xs text-text-muted">{subject}</span>}
                </span>
                <time dateTime={item.created_at} className="shrink-0 text-xs whitespace-nowrap tabular-nums text-text-muted">
                  {formatRelativeTime(item.created_at, data.generated_at)}
                </time>
              </>
            );
            const cls = "flex min-h-11 items-start gap-3 px-4 py-2.5 @4xl/home:px-5";
            return (
              <li key={`${item.source}-${item.event_type}-${item.created_at}-${i}`}>
                {href ? (
                  <Link href={href} className={`${cls} transition-colors hover:bg-gold-soft/30 ${FOCUS_RING}`}>
                    {content}
                  </Link>
                ) : (
                  <div className={cls}>{content}</div>
                )}
              </li>
            );
          })}
        </ol>
      )}
    </section>
  );
}
