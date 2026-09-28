import { formatCompactNumber, formatMoney } from "@/lib/format";
import { COPY, monthLongLabel, monthShortLabel, niceCeil } from "@/lib/dashboard";

// Son 6 ayın tahsilat / çıkış çift çubukları -- elle çizilmiş sunucu SVG'si
// (grafik kütüphanesi YOK). Geometri sabit: viewBox 320×140, çizim alanı
// x 54–316, y 8–108; ay başına iki 12px çubuk (3px ara). Eksen üst sınırı
// 1 / 2 / 2,5 / 5 × 10^k basamağına yuvarlanır; etiketler kısa sayıdır
// (para eki yok).
//
// Çizim alanı spec'teki x=44 yerine x=54'ten başlar: "500.000" gibi 7
// karakterlik etiket 11px'te ~43 birimdir, 38 birimlik boşluğa sığmayıp
// SVG kenarında kırpılıyordu.
//
// Erişilebilirlik: SVG tek bir role="img" (aria-label'da tüm aylar) ve
// aynı veri gizli bir tabloda. Ay grupları klavye odağı ALMAZ: role="img"
// altındaki öğeler sunuma dönüşür, odak durağı ekran okuyucuya hiçbir şey
// söylemez ve açık altın odak zemini görünmezdi. Fareyle üzerine gelince
// <title> tam değeri gösterir.

const X0 = 54;
const X1 = 316;
const Y0 = 8;
const Y1 = 108;
const BAR = 12;
const GAP = 3;

export interface PairedBarsMonth {
  month: string; // "2026-04"
  collections: number;
  outflows: number;
}

export function PairedBars({
  months,
  currency,
  currentMonth,
}: {
  months: PairedBarsMonth[];
  currency: string;
  // Vurgulanan ay ("2026-09").
  currentMonth: string;
}) {
  const max = niceCeil(Math.max(0, ...months.flatMap((m) => [m.collections, m.outflows])));
  const y = (v: number) => (max > 0 ? Y1 - (Math.max(0, v) / max) * (Y1 - Y0) : Y1);
  const grid = max > 0 ? [0, max / 2, max] : [0];
  const groupW = months.length > 0 ? (X1 - X0) / months.length : X1 - X0;
  const describe = (m: PairedBarsMonth) =>
    `${monthLongLabel(m.month)} — ${COPY.chartIn} ${formatMoney(m.collections, currency)} · ${COPY.chartOut} ${formatMoney(m.outflows, currency)}`;

  return (
    <figure className="min-w-0">
      <svg
        viewBox="0 0 320 140"
        role="img"
        aria-label={`${COPY.cashFlow}, ${COPY.cashFlowPeriod.toLocaleLowerCase("tr")}: ${months.map(describe).join("; ")}`}
        className="h-36 w-full @4xl/home:h-40"
      >
        {grid.map((v) => (
          <g key={v} aria-hidden>
            <line x1={X0} x2={X1} y1={y(v)} y2={y(v)} className="stroke-border" strokeWidth={1} strokeDasharray="2 3" />
            <text x={X0 - 6} y={y(v)} dy="0.32em" textAnchor="end" className="fill-text-muted text-[11px] tabular-nums">
              {formatCompactNumber(v)}
            </text>
          </g>
        ))}
        {months.map((m, i) => {
          const cx = X0 + groupW * (i + 0.5);
          const inY = y(m.collections);
          const outY = y(m.outflows);
          const current = m.month === currentMonth;
          return (
            <g key={m.month} className="group">
              <title>{describe(m)}</title>
              <rect
                x={X0 + groupW * i + 1}
                y={Y0 - 4}
                width={Math.max(0, groupW - 2)}
                height={Y1 - Y0 + 28}
                rx={3}
                className="fill-transparent group-hover:fill-surface-hover"
              />
              <rect x={cx - BAR - GAP / 2} y={inY} width={BAR} height={Y1 - inY} rx={1.5} className="fill-chart-in" />
              <rect x={cx + GAP / 2} y={outY} width={BAR} height={Y1 - outY} rx={1.5} className="fill-chart-out" />
              <text
                x={cx}
                y={128}
                textAnchor="middle"
                className={`text-[11px] ${current ? "fill-text font-semibold" : "fill-text-muted"}`}
              >
                {monthShortLabel(m.month)}
              </text>
            </g>
          );
        })}
      </svg>
      {/* sr-only bir KAPSAYICI: tablo width:1px'i yok sayıp nowrap içeriği
          kadar genişler ve kendi kutusu overflow ile kırpılmaz -- doğrudan
          tabloya sr-only verilince telefonda sayfa yana kayıyordu. */}
      <div className="sr-only">
        <table>
          <caption>
            {COPY.cashFlow} · {COPY.cashFlowPeriod}
          </caption>
          <thead>
            <tr>
              <th scope="col">Ay</th>
              <th scope="col">{COPY.chartIn}</th>
              <th scope="col">{COPY.chartOut}</th>
            </tr>
          </thead>
          <tbody>
            {months.map((m) => (
              <tr key={m.month}>
                <th scope="row">{monthLongLabel(m.month)}</th>
                <td>{formatMoney(m.collections, currency)}</td>
                <td>{formatMoney(m.outflows, currency)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <figcaption aria-hidden className="mt-2 flex flex-wrap gap-x-3 gap-y-1 text-xs text-text-muted">
        <span className="inline-flex items-center gap-1.5">
          <span className="size-2 rounded-sm bg-chart-in" />
          {COPY.chartIn}
        </span>
        <span className="inline-flex items-center gap-1.5">
          <span className="size-2 rounded-sm bg-chart-out" />
          {COPY.chartOut}
        </span>
      </figcaption>
    </figure>
  );
}
