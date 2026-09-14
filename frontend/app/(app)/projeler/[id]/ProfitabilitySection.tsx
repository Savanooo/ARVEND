import { formatMoney } from "@/lib/format";
import type { FinancialSummary, ProjectEvent } from "@/lib/types";

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
  return (
    <div className="flex flex-col gap-6 md:flex-row">
      <div className="flex flex-1 flex-col gap-1.5">
        <div className="text-xs font-semibold uppercase tracking-widest text-text-muted">
          Gerçekleşen
        </div>
        <Line label="Güncel proje bedeli" value={formatMoney(summary.current_contract_value, c)} />
        <Line label="Masraflar" value={`- ${formatMoney(summary.total_expenses, c)}`} />
        <Line label="Taşerona ödenen" value={`- ${formatMoney(summary.subcontractor_paid, c)}`} />
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
          value={`+ ${formatMoney(summary.subcontractor_remaining, c)}`}
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

const EVENT_LABELS: Record<string, string> = {
  project_created: "Proje oluşturuldu",
  project_updated: "Proje bilgileri güncellendi",
  project_status_changed: "Proje durumu değişti",
  payment_plan_created: "Ödeme planı kalemi eklendi",
  payment_plan_updated: "Ödeme planı kalemi güncellendi",
  payment_plan_cancelled: "Ödeme planı kalemi iptal edildi",
  collection_received: "Tahsilat kaydedildi",
  collection_voided: "Tahsilat iptal edildi",
  expense_added: "Masraf eklendi",
  expense_updated: "Masraf güncellendi",
  expense_voided: "Masraf iptal edildi",
  invoice_created: "Fatura eklendi",
  invoice_status_changed: "Fatura durumu değişti",
  subcontractor_added: "Taşeron eklendi",
  subcontractor_updated: "Taşeron güncellendi",
  subcontractor_payment_added: "Taşerona ödeme yapıldı",
  subcontractor_payment_voided: "Taşeron ödemesi iptal edildi",
  // Faz 7: operasyon olayları (aynı zaman çizelgesinde finans olaylarıyla birlikte).
  member_assigned: "Ekibe personel atandı",
  member_removed: "Personel ekipten çıkarıldı",
  schedule_created: "Planlama aşaması eklendi",
  schedule_updated: "Planlama aşaması güncellendi",
  schedule_completed: "Planlama aşaması tamamlandı",
  task_created: "Görev oluşturuldu",
  task_assigned: "Görev atandı",
  task_completed: "Görev tamamlandı",
  task_updated: "Görev güncellendi",
  file_uploaded: "Dosya yüklendi",
  file_removed: "Dosya silindi",
  photo_uploaded: "Şantiye fotoğrafı yüklendi",
  photo_removed: "Şantiye fotoğrafı silindi",
  note_added: "Not eklendi",
  // Faz 8: ek iş (değişiklik emri) olayları.
  change_order_created: "Ek iş oluşturuldu",
  change_order_updated: "Ek iş güncellendi",
  change_order_sent: "Ek iş müşteriye gönderildi",
  change_order_viewed: "Müşteri ek işi görüntüledi",
  change_order_approved: "Müşteri ek işi onayladı",
  change_order_rejected: "Müşteri ek işi reddetti",
  change_order_cancelled: "Ek iş iptal edildi",
  change_order_superseded: "Ek iş revize edildi",
  change_order_email_sent: "Ek iş e-postası gönderildi",
  change_order_email_failed: "Ek iş e-postası gönderilemedi",
};

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
  if (typeof m.from === "string" && typeof m.to === "string") parts.push(`${m.from} → ${m.to}`);
  if (typeof m.status === "string") parts.push(String(m.status));
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
        const d = new Date(e.created_at);
        const stamp = `${String(d.getDate()).padStart(2, "0")}.${String(d.getMonth() + 1).padStart(2, "0")} ${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
        const extra = detail(e, currency);
        return (
          <li key={e.id} className="flex gap-3">
            <span className="w-24 shrink-0 tabular-nums text-text-muted">{stamp}</span>
            <span className="text-text-muted">—</span>
            <span>
              {EVENT_LABELS[e.event_type] ?? e.event_type}
              {extra && <span className="text-text-muted"> · {extra}</span>}
            </span>
          </li>
        );
      })}
    </ol>
  );
}
