import { formatMoney, formatSignedMoney } from "@/lib/format";
import type { FinancialSummary } from "@/lib/types";

function Card({
  label,
  value,
  hint,
  tone,
}: {
  label: string;
  value: string;
  hint?: string;
  tone?: "success" | "danger" | "gold";
}) {
  const toneClass =
    tone === "success" ? "text-success" : tone === "danger" ? "text-danger" : tone === "gold" ? "text-gold" : "";
  return (
    <div className="rounded-lg border border-border bg-surface px-4 py-3">
      <div className="text-xs uppercase tracking-widest text-text-muted">{label}</div>
      <div className={`mt-1 text-base font-semibold ${toneClass}`}>{value}</div>
      {hint && <div className="mt-0.5 text-xs text-text-muted">{hint}</div>}
    </div>
  );
}

export function FinanceSummary({ summary }: { summary: FinancialSummary }) {
  const c = summary.currency;
  const over = summary.over_collected > 0;

  const hasChangeOrders = summary.approved_additions > 0 || summary.approved_deductions > 0;
  const hasPending = summary.pending_additions > 0 || summary.pending_deductions > 0;

  return (
    <div className="flex flex-col gap-2">
    <div className="grid grid-cols-2 gap-3 md:grid-cols-4 xl:grid-cols-7">
      <Card label="Ana Sözleşme" value={formatMoney(summary.base_contract_amount, c)} />
      {hasChangeOrders && (
        <>
          <Card
            label="Onaylı Ek İşler"
            value={formatSignedMoney(summary.approved_additions, c)}
            tone={summary.approved_additions > 0 ? "success" : undefined}
          />
          <Card
            label="Onaylı Eksiltmeler"
            value={formatSignedMoney(-summary.approved_deductions, c)}
            tone={summary.approved_deductions > 0 ? "danger" : undefined}
          />
          <Card label="Güncel Proje Bedeli" value={formatMoney(summary.current_contract_value, c)} tone="gold" />
        </>
      )}
      <Card
        label="Tahsil Edilen"
        value={formatMoney(summary.collected_amount, c)}
        hint={`Planlanan: ${formatMoney(summary.planned_collections, c)}`}
        tone={summary.collected_amount > 0 ? "success" : undefined}
      />
      {/* Negatif bakiye gizlenmez; "fazla tahsilat" olarak gösterilir. */}
      <Card
        label={over ? "Fazla Tahsilat" : "Bakiye"}
        value={formatMoney(over ? summary.over_collected : summary.remaining_receivable, c)}
        tone={over ? "gold" : undefined}
        hint={over ? "Sözleşme bedelinin üzerinde" : undefined}
      />
      <Card
        label="Gerçekleşen Maliyet"
        value={formatMoney(summary.realized_cost, c)}
        hint={`Masraf ${formatMoney(summary.total_expenses, c)} + taşeron ${formatMoney(summary.subcontractor_paid, c)}`}
      />
      <Card
        label="Tahmini Maliyet"
        value={formatMoney(summary.committed_cost, c)}
        hint={`Taşeron kalan taahhüt: ${formatMoney(summary.subcontractor_remaining, c)}`}
      />
      <Card
        label="Gerçekleşen Brüt Kâr"
        value={formatMoney(summary.realized_gross_profit, c)}
        tone={summary.realized_gross_profit >= 0 ? "success" : "danger"}
        hint={`%${summary.realized_margin_percent}`}
      />
      <Card
        label="Tahmini Brüt Kâr"
        value={formatMoney(summary.estimated_gross_profit, c)}
        tone={summary.estimated_gross_profit >= 0 ? "success" : "danger"}
        hint={`%${summary.estimated_margin_percent}`}
      />
    </div>
      {/* Potansiyel değer, GERÇEK güncel proje bedeliyle KESİNLİKLE
          karıştırılmamalı -- bilgi amaçlı, ayrı ve daha soluk gösterilir. */}
      {hasPending && (
        <div className="text-xs text-text-muted">
          Onay bekleyen ek iş: <span className="font-medium">{formatSignedMoney(summary.pending_additions - summary.pending_deductions, c)}</span>
          {" — "}Potansiyel proje bedeli: <span className="font-medium">{formatMoney(summary.potential_contract_value, c)}</span>
        </div>
      )}
    </div>
  );
}
