import { ArrowUpRight } from "lucide-react";
import Link from "next/link";

import { FOCUS_RING } from "@/components/ui/styles";
import { attentionChip, COPY, moduleAttention, MODULES, sectionFailed, type ModuleKey } from "@/lib/dashboard";

import { AttentionFooter } from "./AttentionFooter";
import { Chip } from "./Chip";
import type { CardContext } from "./context";
import { MODULE_ICONS } from "./module-icons";
import { SectionError } from "./SectionError";

// Standart modül kartı iskeleti (her kartta aynı anatomi): başlık (ikon,
// ad, dikkat rozeti, "Aç"), birincil gösterge + küçük göstergeler, en
// çok bir görsel, en çok 2 dikkat satırlı alt kısım. Kartın kendisi
// @container/card'dır: tam genişlikte (geniş mod, ≥ 48rem) gövde iki
// sütuna ayrılır -- solda göstergeler, sağda liste/görsel (aside).
// Kenarlık hiçbir zaman renklenmez; renk yalnızca alt satırlarda.
export function ModuleCard({
  moduleKey,
  ctx,
  main,
  aside,
}: {
  moduleKey: ModuleKey;
  ctx: CardContext;
  main?: React.ReactNode;
  aside?: React.ReactNode;
}) {
  const meta = MODULES[moduleKey];
  const Icon = MODULE_ICONS[moduleKey];
  const failed = ctx.data.sections[moduleKey] === undefined && sectionFailed(ctx.data, moduleKey);
  const groups = failed ? [] : moduleAttention(ctx.data, moduleKey);
  const chip = attentionChip(groups);
  const headingId = `modul-${moduleKey}-baslik`;
  const bodyPad = "p-4 @4xl/home:p-5";

  return (
    <article
      id={`modul-${moduleKey}`}
      aria-labelledby={headingId}
      className="@container/card flex h-full min-h-52 min-w-0 scroll-mt-4 flex-col rounded-lg border border-border bg-surface"
    >
      <header className="flex items-center gap-2 border-b border-border px-4 py-3 @xs/card:gap-3 @4xl/home:px-5">
        <span aria-hidden className="flex size-7 shrink-0 items-center justify-center rounded-md bg-surface-hover text-text-muted">
          <Icon size={16} strokeWidth={1.75} />
        </span>
        <h3 id={headingId} className="min-w-0 flex-1 truncate text-sm font-semibold text-text">
          <Link href={meta.href} className={`rounded-sm hover:text-gold ${FOCUS_RING}`}>
            {meta.title}
          </Link>
        </h3>
        {chip && <Chip tone={chip.tone}>{chip.label}</Chip>}
        {/* Dar kartta (< 20rem) "Aç" yazısı yalnızca ekran okuyucuya kalır,
            ok ikonu görünür, aralıklar daralır: başlık rozetle birlikte sığsın. */}
        <Link
          href={meta.href}
          className={`inline-flex shrink-0 items-center gap-1 rounded-sm text-xs font-medium text-text-muted hover:text-gold ${FOCUS_RING}`}
        >
          <span className="@max-xs/card:sr-only">{COPY.open}</span>
          <span className="sr-only">: {meta.title}</span>
          <ArrowUpRight size={14} strokeWidth={2} aria-hidden />
        </Link>
      </header>

      {failed ? (
        <div className={`flex flex-1 flex-col ${bodyPad}`}>
          <SectionError />
        </div>
      ) : (
        <>
          {aside ? (
            <div
              className={`flex flex-1 flex-col gap-4 ${bodyPad} @3xl/card:grid @3xl/card:grid-cols-[minmax(0,5fr)_minmax(0,7fr)] @3xl/card:items-start @3xl/card:gap-6`}
            >
              <div className="flex min-w-0 flex-col gap-3">{main}</div>
              <div className="flex min-w-0 flex-col gap-3">{aside}</div>
            </div>
          ) : (
            <div className={`flex flex-1 flex-col gap-3 ${bodyPad}`}>{main}</div>
          )}
          <AttentionFooter groups={groups} moduleKey={moduleKey} dikkatVisible={ctx.dikkatVisible} />
        </>
      )}
    </article>
  );
}

/** Bölüm anahtarı yoksa: hesaplanamadıysa hata gövdeli kart, izin yoksa hiçbir şey. */
export function MissingModule({ moduleKey, ctx }: { moduleKey: ModuleKey; ctx: CardContext }) {
  if (!sectionFailed(ctx.data, moduleKey)) return null;
  return <ModuleCard moduleKey={moduleKey} ctx={ctx} />;
}
