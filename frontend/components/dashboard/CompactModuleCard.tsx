import { ArrowUpRight } from "lucide-react";
import Link from "next/link";

import { MODULES, sectionFailed, type ModuleKey } from "@/lib/dashboard";

import type { CardContext } from "./context";
import { MODULE_ICONS } from "./module-icons";
import { SectionError } from "./SectionError";

// Düşük öncelikli kayıt defterleri (Metraj, Tedarikçiler, Maliyet Kodları)
// için tek satırlık kart. Başlık bağlantısı ::after ile kartın tamamını
// kaplar (iç içe etkileşimli öğe yok); odak halkası kartın kendisinde.
export function CompactModuleCard({
  moduleKey,
  ctx,
  value,
  notes = [],
}: {
  moduleKey: ModuleKey;
  ctx: CardContext;
  value?: string;
  notes?: string[];
}) {
  const meta = MODULES[moduleKey];
  const Icon = MODULE_ICONS[moduleKey];
  const missing = ctx.data.sections[moduleKey] === undefined;
  const failed = missing && sectionFailed(ctx.data, moduleKey);
  // Anahtar yok ve hata da yok = izin yok: kart hiç çizilmez.
  if (missing && !failed) return null;
  const headingId = `modul-${moduleKey}-baslik`;

  return (
    <article
      id={`modul-${moduleKey}`}
      aria-labelledby={headingId}
      className="relative flex h-full min-h-18 min-w-0 items-center gap-3 rounded-lg border border-border bg-surface px-4 py-3 transition-colors hover:bg-surface-hover/60 has-[a:focus-visible]:outline-2 has-[a:focus-visible]:outline-offset-2 has-[a:focus-visible]:outline-gold"
    >
      <span aria-hidden className="flex size-7 shrink-0 items-center justify-center rounded-md bg-surface-hover text-text-muted">
        <Icon size={16} strokeWidth={1.75} />
      </span>
      <div className="min-w-0 flex-1">
        <h3 id={headingId} className="text-sm font-semibold text-text">
          <Link href={meta.href} className="outline-none after:absolute after:inset-0 after:rounded-lg">
            {meta.title}
          </Link>
        </h3>
        {failed ? (
          // Hata kutusundaki "Tekrar dene" kartı kaplayan bağlantının üstünde kalır.
          <div className="relative z-10 mt-1">
            <SectionError />
          </div>
        ) : (
          <>
            {value && <p className="text-sm tabular-nums text-text-muted">{value}</p>}
            {notes.map((n) => (
              <p key={n} className="text-xs text-text-muted">
                {n}
              </p>
            ))}
          </>
        )}
      </div>
      <ArrowUpRight size={14} strokeWidth={2} aria-hidden className="shrink-0 text-text-muted" />
    </article>
  );
}
