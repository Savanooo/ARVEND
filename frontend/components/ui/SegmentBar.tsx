// Parçalı dağılım çubuğu (durum/kaynak dağılımı) + isteğe bağlı açıklama.
// Parça genişliği yalnızca oran çizimidir (flex-grow = sayı); toplam
// hesaplanıp yazılmaz. Server-safe (hook yok).

export type SegmentTone = "muted" | "muted-dark" | "gold" | "success" | "danger" | "info" | "graphite" | "ink" | "dashed";

const FILL: Record<SegmentTone, string> = {
  muted: "bg-text-muted/40",
  "muted-dark": "bg-text-muted/70",
  gold: "bg-gold",
  success: "bg-success",
  danger: "bg-danger",
  info: "bg-info",
  graphite: "bg-graphite",
  ink: "bg-text",
  // "Girilmedi" gibi eksik kayıt: dolgu yok, kesikli çerçeve.
  dashed: "bg-transparent outline-dashed outline-1 outline-border -outline-offset-1",
};

const DOT: Record<SegmentTone, string> = {
  ...FILL,
  dashed: "border border-dashed border-text-muted/60",
};

export interface Segment {
  key: string;
  value: number;
  tone: SegmentTone;
  label: string;
}

export function SegmentBar({
  segments,
  ariaLabel,
  legend = true,
  legendExtra = [],
}: {
  segments: Segment[];
  // Çubuğun adı ("Proje durumları"); parçalar ve sayılar arkasına eklenir.
  ariaLabel: string;
  legend?: boolean;
  // Yalnızca açıklamada görünen kalemler (ör. Projeler'de "İptal").
  legendExtra?: { key: string; label: string; value: number }[];
}) {
  const fmt = (n: number) => n.toLocaleString("tr-TR");
  const spoken = [...segments, ...legendExtra].map((s) => `${s.label} ${fmt(s.value)}`).join(", ");
  return (
    <div>
      <div role="img" aria-label={`${ariaLabel}: ${spoken}`} className="flex h-2 w-full gap-px overflow-hidden rounded-sm bg-track">
        {segments
          .filter((s) => s.value > 0)
          .map((s) => (
            <div key={s.key} className={`h-full min-w-[2px] ${FILL[s.tone]}`} style={{ flexGrow: s.value, flexBasis: 0 }} />
          ))}
      </div>
      {legend && (
        <ul aria-hidden className="mt-2 flex flex-wrap gap-x-3 gap-y-1 text-xs text-text-muted">
          {segments.map((s) => (
            <li key={s.key} className="inline-flex items-center gap-1.5">
              <span className={`size-2 shrink-0 rounded-sm ${DOT[s.tone]}`} />
              {s.label} <span className="tabular-nums text-text">{fmt(s.value)}</span>
            </li>
          ))}
          {legendExtra.map((s) => (
            <li key={s.key} className="inline-flex items-center gap-1">
              · {s.label} <span className="tabular-nums">{fmt(s.value)}</span>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
