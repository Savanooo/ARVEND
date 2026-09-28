import Link from "next/link";

import { FOCUS_RING, LABEL, buttonClass } from "@/components/ui/styles";
import { formatCompactMoney, formatMoney, formatSignedCompactMoney, formatSignedMoney } from "@/lib/format";

// Modül kartlarının ortak gövde parçaları (Server Component'ler).

/**
 * Kısa para (D5: "12,5 Mn TL") -- tam değer title'da ve ekran okuyucu
 * metninde. Kart gövdesinde renk YOK (işaretli değer de nötr; alarm rengi
 * yalnızca Dikkat ve kart alt satırında, §1.3 kural 8).
 */
export function Money({ value, currency, signed = false }: { value: number; currency: string; signed?: boolean }) {
  const short = signed ? formatSignedCompactMoney(value, currency) : formatCompactMoney(value, currency);
  const full = signed ? formatSignedMoney(value, currency) : formatMoney(value, currency);
  return (
    <span>
      <span aria-hidden title={full}>
        {short}
      </span>
      <span className="sr-only">{full}</span>
    </span>
  );
}

/** Kartın birincil göstergesi: etiket + büyük değer + küçük ayrıntı. */
export function Metric({ label, value, detail }: { label: string; value: React.ReactNode; detail?: React.ReactNode }) {
  return (
    <div className="min-w-0">
      <p className={LABEL}>{label}</p>
      <p className="mt-1 flex flex-wrap items-baseline gap-x-2 gap-y-0.5">
        <span className="text-xl font-bold tracking-tight tabular-nums text-text">{value}</span>
        {detail !== undefined && detail !== null && detail !== "" && (
          <span className="text-xs text-text-muted">{detail}</span>
        )}
      </p>
    </div>
  );
}

export function StatGrid({ children }: { children: React.ReactNode }) {
  return <dl className="grid grid-cols-2 gap-x-4 gap-y-3 @md/card:grid-cols-3">{children}</dl>;
}

/**
 * Küçük gösterge: değer üstte, etiket altta (DOM sırası etiket -> değer).
 * justify-end: column-reverse'te içerik ÜSTE toplanır; yoksa uzayan ızgara
 * satırında tek satırlık etiketli değer aşağı kayar, değerler hizasız kalır.
 */
export function Stat({ label, value, wide = false }: { label: string; value: React.ReactNode; wide?: boolean }) {
  return (
    <div className={`flex min-w-0 flex-col-reverse justify-end gap-0.5 ${wide ? "col-span-2 @md/card:col-span-3" : ""}`}>
      <dt className="text-xs text-text-muted">{label}</dt>
      <dd className="min-w-0 text-sm font-semibold tabular-nums text-text">{value}</dd>
    </div>
  );
}

export function Note({ children }: { children: React.ReactNode }) {
  return <p className="text-xs text-text-muted">{children}</p>;
}

/** Kartın boş durumu: metin + (izin varsa) tek CTA. */
export function EmptyNote({ text, action }: { text: string; action?: React.ReactNode }) {
  return (
    <div className="flex flex-col items-start gap-3">
      <p className="text-sm text-text-muted">{text}</p>
      {action}
    </div>
  );
}

export function CtaLink({ href, label }: { href: string; label: string }) {
  return (
    <Link href={href} className={buttonClass("secondary", "sm")}>
      {label}
    </Link>
  );
}

/** Kartın ikincil sayfa bağlantıları (ör. Ürünler & Zam -> "Ürünler"). */
export function CardLinks({ links }: { links: { href: string; label: string }[] }) {
  if (links.length === 0) return null;
  return (
    <p className="flex flex-wrap gap-x-4 gap-y-1 text-xs">
      {links.map((l) => (
        <Link key={l.href} href={l.href} className={`rounded-sm font-medium text-text-muted hover:text-gold hover:underline ${FOCUS_RING}`}>
          {l.label} →
        </Link>
      ))}
    </p>
  );
}

/** Kartın üst başlığı altındaki küçük bölüm etiketi (ör. "Son 90 gün"). */
export function MiniLabel({ children }: { children: React.ReactNode }) {
  return <p className="text-[11px] font-semibold uppercase tracking-widest text-text-muted">{children}</p>;
}
