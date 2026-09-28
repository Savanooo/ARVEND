import { LABEL } from "@/components/ui/styles";
import { COPY, trendMonths, type DashboardResponse, type FinanceCurrency } from "@/lib/dashboard";
import { currencySuffix, formatSignedMoney } from "@/lib/format";

import { PairedBars } from "./charts/PairedBars";
import { CurrencyPanels } from "./CurrencyPanels";

// "Nakit Akışı · Son 6 ay": tek zaman serisi (spec D8). Tahsilat yeşil,
// çıkış (masraf + taşeron ödemesi) grafit. Altında bu ayın dökümü (tam
// değer, işaretli). Tüm sayılar sunucudan; burada toplama/çıkarma YOK.

function Line({ label, value, strong = false, tone = "" }: { label: string; value: string; strong?: boolean; tone?: string }) {
  return (
    <div className={`flex items-baseline justify-between gap-3 py-1 ${strong ? "mt-1 border-t border-border pt-2 font-semibold" : ""}`}>
      <dt className={strong ? "text-sm text-text" : "text-sm text-text-muted"}>{label}</dt>
      <dd className={`text-sm whitespace-nowrap tabular-nums ${tone || "text-text"}`}>{value}</dd>
    </div>
  );
}

function Body({ row, monthStart, currency }: { row: FinanceCurrency | null; monthStart: string; currency: string }) {
  const months =
    row?.trend_6m && row.trend_6m.length > 0
      ? row.trend_6m
      : trendMonths(monthStart).map((month) => ({ month, collections: 0, outflows: 0 }));
  const allZero = months.every((m) => m.collections === 0 && m.outflows === 0);
  const month = row?.month ?? { collections: 0, expenses: 0, subcontract_payments: 0, outflows: 0, net_cash: 0 };
  const net = Math.round(month.net_cash);
  // content-start: panel Dikkat'in yüksekliğine uzar; satırlar uzamasın,
  // "Bu ay" dökümü lejantın hemen altında kalsın (boşluk en alta gider).
  return (
    <div className="grid flex-1 grid-cols-1 content-start gap-4 p-4 @4xl/home:p-5 @xl/nakit:grid-cols-[minmax(0,3fr)_minmax(0,2fr)] @xl/nakit:items-start">
      <div className="min-w-0">
        <PairedBars months={months} currency={currency} currentMonth={monthStart.slice(0, 7)} />
        {allZero && <p className="mt-2 text-xs text-text-muted">{COPY.cashEmpty}</p>}
      </div>
      <div className="min-w-0">
        <h3 className="text-[11px] font-semibold uppercase tracking-widest text-text-muted">{COPY.thisMonth}</h3>
        <dl className="mt-1">
          <Line label={COPY.chartIn} value={formatSignedMoney(month.collections, currency)} />
          <Line label={COPY.expenses} value={formatSignedMoney(-month.expenses, currency)} />
          <Line label={COPY.subcontractPayments} value={formatSignedMoney(-month.subcontract_payments, currency)} />
          <Line
            label={COPY.net}
            value={formatSignedMoney(month.net_cash, currency)}
            strong
            tone={net > 0 ? "text-success" : net < 0 ? "text-danger" : ""}
          />
        </dl>
      </div>
    </div>
  );
}

export function CashFlowPanel({ data }: { data: DashboardResponse }) {
  const rows = data.sections.finance?.by_currency ?? [];
  const monthStart = data.period.month_start;
  const heading = (
    <h2 id="nakit-akisi-baslik" className={LABEL}>
      {COPY.cashFlow}
      <span className="font-medium normal-case tracking-normal"> · {COPY.cashFlowPeriod}</span>
    </h2>
  );
  return (
    <section
      id="nakit-akisi"
      aria-labelledby="nakit-akisi-baslik"
      className="@container/nakit flex h-full min-h-[17.5rem] scroll-mt-4 flex-col rounded-lg border border-border bg-surface"
    >
      {rows.length > 1 ? (
        <CurrencyPanels
          heading={heading}
          labels={rows.map((r) => currencySuffix(r.currency))}
          panels={rows.map((r) => (
            <Body key={r.currency} row={r} monthStart={monthStart} currency={r.currency} />
          ))}
        />
      ) : (
        <>
          <header className="flex items-center justify-between gap-3 border-b border-border px-4 py-3 @4xl/home:px-5">{heading}</header>
          <Body row={rows[0] ?? null} monthStart={monthStart} currency={rows[0]?.currency ?? data.primary_currency} />
        </>
      )}
    </section>
  );
}
