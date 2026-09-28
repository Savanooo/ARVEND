// İnce yatay oran çubuğu (grafik kütüphanesi YOK). Değer 0-100'e
// kırpılır; 0'da dolgu çizilmez. Server-safe (hook yok).

export type ProgressTone = "success" | "gold" | "graphite" | "danger";

const FILL: Record<ProgressTone, string> = {
  success: "bg-success",
  gold: "bg-gold",
  graphite: "bg-graphite",
  danger: "bg-danger",
};

export function ProgressBar({
  pct,
  tone = "success",
  label,
  valueText,
  className = "",
}: {
  pct: number | null;
  tone?: ProgressTone;
  // Erişilebilir ad ("Tahsilat") ve okunuş ("Tahsilat yüzde 59").
  label: string;
  valueText: string;
  className?: string;
}) {
  const value = Math.min(100, Math.max(0, pct ?? 0));
  return (
    <div
      role="meter"
      aria-label={label}
      aria-valuemin={0}
      aria-valuemax={100}
      aria-valuenow={Math.round(value * 10) / 10}
      aria-valuetext={valueText}
      className={`h-1.5 w-full overflow-hidden rounded-sm bg-track ${className}`}
    >
      {value > 0 && <div className={`h-full ${FILL[tone]}`} style={{ width: `${value}%` }} />}
    </div>
  );
}
