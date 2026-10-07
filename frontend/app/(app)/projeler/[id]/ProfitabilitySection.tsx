import { PROJECT_EVENT_LABELS } from "@/lib/events";
import { formatDateTR, formatHm, formatMoney, istanbulDate } from "@/lib/format";
import {
  INVOICE_STATUS_LABELS,
  PROJECT_STATUS_LABELS,
  SCHEDULE_STATUS_LABELS,
  TASK_STATUS_LABELS,
  type FinancialSummary,
  type ProjectEvent,
} from "@/lib/types";

import { subcontractTotals } from "./FinanceSummary";

function Line({ label, value, strong }: { label: string; value: string; strong?: boolean }) {
  return (
    <div className={`flex justify-between ${strong ? "font-semibold" : ""}`}>
      <span className={strong ? "" : "text-text-muted"}>{label}</span>
      <span>{value}</span>
    </div>
  );
}

// Bu bölüm bir KPI tekrarı DEĞİL, kâr/marjın türetimidir: üst KPI
// şeridindeki toplamlar burada yalnızca hesabın adımları olarak geçer.
// Gerçekleşen brüt kâr ve marjı yalnızca burada gösterilir (KPI'da yok);
// tahmini taraf, gerçekleşen maliyetin üzerine kalan taahhüdü ekleyerek
// devam eder -- aynı satırı iki sütunda tekrar etmez.
export function ProfitabilitySection({ summary }: { summary: FinancialSummary }) {
  const c = summary.currency;
  const sub = subcontractTotals(summary);
  return (
    <div className="flex flex-col gap-6 md:flex-row">
      <div className="flex flex-1 flex-col gap-1.5">
        <div className="text-xs font-semibold uppercase tracking-widest text-text-muted">
          Gerçekleşen
        </div>
        <Line label="Güncel proje bedeli" value={formatMoney(summary.current_contract_value, c)} />
        <Line label="Masraflar" value={`- ${formatMoney(summary.total_expenses, c)}`} />
        <Line label="Taşerona ödenen" value={`- ${formatMoney(sub.paid, c)}`} />
        <div className="my-1 border-t border-border" />
        <Line label="Gerçekleşen maliyet" value={formatMoney(summary.realized_cost, c)} />
        <Line
          label={`Gerçekleşen brüt kâr (%${summary.realized_margin_percent})`}
          value={formatMoney(summary.realized_gross_profit, c)}
          strong
        />
      </div>

      <div className="flex flex-1 flex-col gap-1.5">
        <div className="text-xs font-semibold uppercase tracking-widest text-text-muted">
          Taahhüt dahil (tahmini)
        </div>
        <Line
          label="Gerçekleşen maliyetin üzerine taşeron kalan taahhüdü"
          value={`+ ${formatMoney(sub.remaining, c)}`}
        />
        <div className="my-1 border-t border-border" />
        <Line label="Tahmini maliyet" value={formatMoney(summary.committed_cost, c)} />
        <Line
          label={`Tahmini brüt kâr (%${summary.estimated_margin_percent})`}
          value={formatMoney(summary.estimated_gross_profit, c)}
          strong
        />
      </div>
    </div>
  );
}

// Olay etiketleri lib/events.ts'e taşındı (ana sayfa "Son Hareketler" de
// aynı haritayı kullanır).

// Olay metadata'sındaki durum kodları (planned, in_progress, paid...) ham
// gösterilmez: olay tipine göre ilgili etiket sözlüğünden Türkçesi alınır.
const STATUS_LABELS_BY_EVENT: Record<string, Record<string, string>> = {
  project_status_changed: PROJECT_STATUS_LABELS,
  invoice_status_changed: INVOICE_STATUS_LABELS,
  schedule_created: SCHEDULE_STATUS_LABELS,
  schedule_updated: SCHEDULE_STATUS_LABELS,
  schedule_completed: SCHEDULE_STATUS_LABELS,
  task_created: TASK_STATUS_LABELS,
  task_updated: TASK_STATUS_LABELS,
  task_completed: TASK_STATUS_LABELS,
};

function statusLabel(eventType: string, code: string): string {
  return STATUS_LABELS_BY_EVENT[eventType]?.[code] ?? code;
}

function detail(e: ProjectEvent, currency: string): string {
  const m = e.metadata ?? {};
  const parts: string[] = [];
  if (typeof m.name === "string") parts.push(m.name);
  if (typeof m.title === "string") parts.push(m.title);
  if (typeof m.project_no === "string") parts.push(m.project_no);
  if (typeof m.invoice_no === "string") parts.push(m.invoice_no);
  if (typeof m.amount === "number") parts.push(formatMoney(m.amount, currency));
  if (typeof m.planned_amount === "number") parts.push(formatMoney(m.planned_amount, currency));
  if (typeof m.contract_amount === "number") parts.push(formatMoney(m.contract_amount, currency));
  if (typeof m.grand_total === "number") parts.push(formatMoney(m.grand_total, currency));
  if (typeof m.from === "string" && typeof m.to === "string")
    parts.push(`${statusLabel(e.event_type, m.from)} → ${statusLabel(e.event_type, m.to)}`);
  if (typeof m.status === "string") parts.push(statusLabel(e.event_type, m.status));
  if (typeof m.reason === "string" && m.reason) parts.push(String(m.reason));
  return parts.join(" · ");
}

export function ProjectActivitySection({
  events,
  currency,
}: {
  events: ProjectEvent[];
  currency: string;
}) {
  if (events.length === 0) {
    return <p className="text-text-muted">Henüz kayıtlı bir olay yok.</p>;
  }
  return (
    <ol className="flex flex-col gap-1.5 text-sm">
      {events.map((e) => {
        // Yıl dahil, İstanbul saatiyle (geçen yılın olayları bu yılınkiyle
        // karışmasın; sunucu/tarayıcı saat dilimine bağlı olmasın).
        const d = new Date(e.created_at);
        const stamp = Number.isNaN(d.getTime())
          ? ""
          : `${formatDateTR(istanbulDate(d))} ${formatHm(e.created_at)}`;
        const extra = detail(e, currency);
        return (
          <li key={e.id} className="flex gap-3">
            <span className="w-32 shrink-0 tabular-nums text-text-muted">{stamp}</span>
            <span className="text-text-muted">—</span>
            <span>
              {PROJECT_EVENT_LABELS[e.event_type] ?? e.event_type}
              {extra && <span className="text-text-muted"> · {extra}</span>}
            </span>
          </li>
        );
      })}
    </ol>
  );
}
