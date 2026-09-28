import Link from "next/link";

import { ProgressBar } from "@/components/ui/ProgressBar";
import { FOCUS_RING } from "@/components/ui/styles";
import { formatPercentNumber, webHrefFor, type MyTask, type ProjectRow } from "@/lib/dashboard";
import { formatCount, formatDateTR, formatPercent, formatShortDate } from "@/lib/format";
import { PROJECT_STATUS } from "@/lib/status";
import { TASK_PRIORITY_LABELS, type ProjectStatus } from "@/lib/types";

import { Chip } from "./Chip";

// Görevlerim paneli ve Görevler kartının ortak görev satırı.
export function TaskRow({ task, today, inset = false }: { task: MyTask; today: string; inset?: boolean }) {
  const href = webHrefFor(task.ref);
  let due: React.ReactNode = null;
  if (task.days_overdue !== null && task.days_overdue > 0) {
    due = <span className="font-medium text-danger">{formatCount(task.days_overdue)} gün gecikti</span>;
  } else if (task.due_date === today) {
    due = <span className="font-semibold text-text">Bugün</span>;
  } else if (task.due_date) {
    due = (
      <time dateTime={task.due_date} className="tabular-nums text-text-muted">
        {formatShortDate(task.due_date)}
      </time>
    );
  }
  const priority = task.priority === "urgent" || task.priority === "high" ? TASK_PRIORITY_LABELS[task.priority] : null;
  const pad = inset ? "-mx-2 px-2" : "px-4 @4xl/home:px-5";
  const content = (
    <>
      <div className="min-w-0 flex-1">
        <div className="truncate text-sm font-medium text-text">{task.title}</div>
        <div className="truncate text-xs text-text-muted">
          {task.project_name}
          {priority && <span className={task.priority === "urgent" ? "text-danger" : ""}> · {priority}</span>}
        </div>
      </div>
      {due && <span className="shrink-0 text-xs">{due}</span>}
    </>
  );
  const cls = `flex min-h-11 items-start gap-3 py-2.5 ${pad}`;
  if (!href) return <div className={cls}>{content}</div>;
  return (
    <Link href={href} className={`${cls} rounded-md hover:bg-gold-soft/30 ${FOCUS_RING}`}>
      {content}
    </Link>
  );
}

function BarLine({ label, pct, tone }: { label: string; pct: number; tone: "graphite" | "gold" | "success" }) {
  return (
    <>
      <span className="text-text-muted">{label}</span>
      <ProgressBar pct={pct} tone={tone} label={label} valueText={`${label} yüzde ${formatPercentNumber(pct)}`} />
      <span className="text-right tabular-nums text-text-muted">{formatPercent(Math.round(pct))}</span>
    </>
  );
}

// Projeler kartının proje satırı: süre (grafit), görev (altın, izin
// varsa), tahsilat (yeşil, izin varsa) çubukları. Sayılar sunucudan.
// p.flags YAZILMAZ: bayraklar yalnızca sunucudaki sıralama içindir; aynı
// olgular (vadesi geçen ödeme, bütçe aşımı, sözleşmesiz proje ...) zaten
// Dikkat satırında ve ilgili kartın alt satırında (D11: en çok iki yer).
export function ProjectListRow({ project: p, className = "" }: { project: ProjectRow; className?: string }) {
  const href = webHrefFor(p.ref);
  const meta: string[] = [p.project_no];
  if (p.days_to_end !== null && p.days_to_end < 0) meta.push(`${formatCount(-p.days_to_end)} gün gecikti`);
  else if (p.end_date) meta.push(`Bitiş ${formatDateTR(p.end_date)}`);
  const status = PROJECT_STATUS[p.status as ProjectStatus];
  const content = (
    <>
      <div className="flex items-start justify-between gap-2">
        <span className="min-w-0 truncate text-sm font-medium text-text">{p.name}</span>
        {/* Dashboard rozeti: kırılmaz; "Devam ediyor" altın tonu koyu metinle (§5.9). */}
        {status && <Chip tone={status.tone}>{status.label}</Chip>}
      </div>
      <div className="truncate text-xs text-text-muted">{meta.join(" · ")}</div>
      <div className="mt-1.5 grid grid-cols-[auto_minmax(0,1fr)_auto] items-center gap-x-2 gap-y-1 text-xs">
        {p.time_progress_pct !== null && <BarLine label="Süre" pct={p.time_progress_pct} tone="graphite" />}
        {p.task_progress_pct !== null && <BarLine label="Görev" pct={p.task_progress_pct} tone="gold" />}
        {p.collection_pct !== null && <BarLine label="Tahsilat" pct={p.collection_pct} tone="success" />}
      </div>
    </>
  );
  const cls = `-mx-2 flex-col px-2 py-2 ${className}`;
  if (!href) return <div className={cls}>{content}</div>;
  return (
    <Link href={href} className={`${cls} rounded-md hover:bg-gold-soft/30 ${FOCUS_RING}`}>
      {content}
    </Link>
  );
}
