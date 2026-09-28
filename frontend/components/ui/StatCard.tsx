import Link from "next/link";

import { FOCUS_RING } from "./styles";

// KPI kutusu (ana sayfa "Nabız" satırı). Değer kısa (ör. "5,1 Mn TL")
// yazılır; tam değer title'da ve ekran okuyucu metninde. Renk yalnızca
// işaretli değerde (işaretiyle birlikte) -- renge tek başına güvenilmez.
// href verilirse kutunun tamamı bir bağlantıdır (içinde başka etkileşimli
// öğe YOK). Server-safe.
export function StatCard({
  label,
  value,
  valueFull,
  tone = null,
  icon,
  sub = [],
  other = null,
  href = null,
  children,
}: {
  label: string;
  value: string;
  valueFull?: string;
  tone?: "success" | "danger" | null;
  icon?: React.ReactNode;
  sub?: string[];
  other?: string | null;
  href?: string | null;
  // İsteğe bağlı görsel (ör. ProgressBar), değerin altında.
  children?: React.ReactNode;
}) {
  const toneClass = tone === "success" ? "text-success" : tone === "danger" ? "text-danger" : "text-text";
  const full = valueFull ?? value;
  const body = (
    <>
      <span className="flex items-start justify-between gap-2">
        <span className="text-xs font-semibold uppercase tracking-widest text-text-muted">{label}</span>
        {icon && (
          <span aria-hidden className="shrink-0 text-text-muted">
            {icon}
          </span>
        )}
      </span>
      <span className={`text-xl font-bold tracking-tight tabular-nums @4xl:text-2xl ${toneClass}`}>
        <span aria-hidden title={full}>
          {value}
        </span>
        <span className="sr-only">{full}</span>
      </span>
      {children}
      {sub.map((line) => (
        <span key={line} className="truncate text-xs text-text-muted">
          {line}
        </span>
      ))}
      {other && <span className="truncate text-xs text-text-muted">{other}</span>}
    </>
  );
  const base = "group flex min-h-28 min-w-0 flex-col gap-1.5 rounded-lg border border-border bg-surface px-4 py-3.5";
  if (href) {
    const cls = `${base} transition-colors hover:bg-surface-hover/60 ${FOCUS_RING}`;
    // Sayfa içi çapa ("#nakit-akisi") düz <a> ile: tarayıcının kendi
    // kaydırması ve hashchange olayı korunur.
    if (href.startsWith("#")) {
      return (
        <a href={href} className={cls}>
          {body}
        </a>
      );
    }
    return (
      <Link href={href} className={cls}>
        {body}
      </Link>
    );
  }
  return <div className={base}>{body}</div>;
}
