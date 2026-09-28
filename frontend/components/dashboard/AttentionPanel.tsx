"use client";

import { CalendarClock, ChevronDown, ChevronRight, CircleCheckBig } from "lucide-react";
import Link from "next/link";
import { useEffect, useState, useSyncExternalStore } from "react";

import { FOCUS_RING, LABEL } from "@/components/ui/styles";
import {
  attentionAmount,
  attentionAnchorId,
  attentionCodeFromHash,
  attentionGroupHref,
  attentionMeta,
  attentionRecordLine,
  attentionTitle,
  COPY,
  isModuleKey,
  MODULES,
  upcomingDayWord,
  upcomingLabel,
  webHrefFor,
  type AttentionGroup,
  type DashboardAgenda,
  type UpcomingItem,
} from "@/lib/dashboard";
import { formatMoney, MONTHS_SHORT } from "@/lib/format";

import { Chip } from "./Chip";
import { SEVERITY_BAR, SEVERITY_ICONS, SEVERITY_TEXT } from "./module-icons";

// "Dikkat Gerektirenler": üç şerit -- Senin sıran (aksiyon alabildiğin ya
// da kendi geciken görevin), Takipte (başkasının onayı/müşteri), Yaklaşan
// (14 gün). Şerit/önem/sıra sunucudan gelir (bkz. backend
// dashboard_agenda.go); burada yalnızca çizim ve aç/kapa. Kapalıyken her
// şeritte sınırlı satır gösterilir, "Tümünü göster" hepsini açar. Kart alt
// satırlarından gelen #dikkat-<kod> bağlantısı ilgili grubu açar.

const LIMITS = { mine: 4, watching: 2, upcoming: 3 } as const;

function subscribeHash(onChange: () => void) {
  window.addEventListener("hashchange", onChange);
  return () => window.removeEventListener("hashchange", onChange);
}
const readHash = () => window.location.hash;
const serverHash = () => "";

const ROW_BASE = "relative flex min-h-11 w-full items-start gap-3 px-4 py-2.5 text-left @4xl/home:px-5";
const ROW = `${ROW_BASE} transition-colors hover:bg-gold-soft/30 ${FOCUS_RING}`;

export function AttentionPanel({
  agenda,
  today,
  partial,
  wide,
}: {
  agenda: DashboardAgenda;
  today: string;
  // Bazı bölümler hesaplanamadı: liste eksik olabilir notu.
  partial: boolean;
  // Yanında ikincil panel yoksa tam genişlik: şeritler iki sütuna ayrılır.
  wide: boolean;
}) {
  const hash = useSyncExternalStore(subscribeHash, readHash, serverHash);
  const hashCode = attentionCodeFromHash(hash);
  const [toggled, setToggled] = useState<Record<string, boolean>>({});
  // "auto": kapalı, ama #dikkat-<kod> gizli bir grubu hedefliyorsa açık.
  const [expand, setExpand] = useState<"auto" | "all" | "less">("auto");

  const mine = agenda.groups.filter((g) => g.lane === "mine");
  const watching = agenda.groups.filter((g) => g.lane === "watching");
  const upcoming = agenda.upcoming;
  const total = mine.length + watching.length + upcoming.length;
  const hiddenCount =
    Math.max(0, mine.length - LIMITS.mine) + Math.max(0, watching.length - LIMITS.watching) + Math.max(0, upcoming.length - LIMITS.upcoming);
  const hashTargetsHidden =
    hashCode !== null &&
    (mine.slice(LIMITS.mine).some((g) => g.code === hashCode) || watching.slice(LIMITS.watching).some((g) => g.code === hashCode));
  const showAll = expand === "all" || (expand === "auto" && hashTargetsHidden);

  // Kart alt satırından gelen bağlantı gizli bir grubu açtıysa, liste
  // açıldıktan sonra gruba kaydır (tarayıcı ilk atlamayı gizli öğeye yapamaz).
  useEffect(() => {
    if (!hashCode) return;
    document.getElementById(attentionAnchorId(hashCode))?.scrollIntoView({ block: "nearest" });
  }, [hashCode, showAll]);

  const isOpen = (code: string) => toggled[code] ?? code === hashCode;
  const toggle = (code: string) => setToggled((prev) => ({ ...prev, [code]: !(prev[code] ?? code === hashCode) }));

  const take = <T,>(list: T[], n: number) => (showAll ? list : list.slice(0, n));
  const mineShown = take(mine, LIMITS.mine);
  const watchingShown = take(watching, LIMITS.watching);
  const upcomingShown = take(upcoming, LIMITS.upcoming);
  const noGroups = mine.length === 0 && watching.length === 0;

  const mineLane =
    mine.length > 0 ? (
      <Lane id="dikkat-serit-mine" title={`${COPY.laneMine} · ${agenda.mine_count}`}>
        {mineShown.map((g) => (
          <GroupRow key={g.code} group={g} open={isOpen(g.code)} onToggle={() => toggle(g.code)} />
        ))}
      </Lane>
    ) : null;
  const watchingLane =
    watching.length > 0 ? (
      <Lane id="dikkat-serit-watching" title={`${COPY.laneWatching} · ${agenda.watching_count}`} tooltip={COPY.watchingTooltip}>
        {watchingShown.map((g) => (
          <GroupRow key={g.code} group={g} open={isOpen(g.code)} onToggle={() => toggle(g.code)} />
        ))}
      </Lane>
    ) : null;
  const upcomingLane =
    upcoming.length > 0 ? (
      <Lane id="dikkat-serit-upcoming" title={COPY.laneUpcoming}>
        {upcomingShown.map((u, i) => (
          <UpcomingRow key={`${u.kind}-${u.ref.id}-${i}`} item={u} today={today} />
        ))}
      </Lane>
    ) : null;
  const allClear = noGroups ? (
    <p className="flex items-start gap-2 px-4 py-3 text-sm text-text-muted @4xl/home:px-5">
      <CircleCheckBig size={16} strokeWidth={2} aria-hidden className="mt-0.5 shrink-0 text-success" />
      {COPY.attentionEmpty}
    </p>
  ) : null;

  return (
    <section
      id="dikkat"
      aria-labelledby="dikkat-baslik"
      className="@container/dikkat flex h-full min-h-[17.5rem] scroll-mt-4 flex-col rounded-lg border border-border bg-surface"
    >
      <header className="flex items-center justify-between gap-3 border-b border-border px-4 py-3 @4xl/home:px-5">
        <h2 id="dikkat-baslik" className={LABEL}>
          {COPY.attention}
        </h2>
        {agenda.mine_count > 0 && <Chip tone={agenda.mine_danger_count > 0 ? "danger" : "gold"}>{agenda.mine_count}</Chip>}
      </header>

      <div className="flex-1 pb-2">
        {wide ? (
          <div className="grid grid-cols-1 @3xl/dikkat:grid-cols-2 @3xl/dikkat:divide-x @3xl/dikkat:divide-border">
            <div>
              {allClear}
              {mineLane}
            </div>
            <div>
              {watchingLane}
              {upcomingLane}
            </div>
          </div>
        ) : (
          <>
            {allClear}
            {mineLane}
            {watchingLane}
            {upcomingLane}
          </>
        )}
      </div>

      {(hiddenCount > 0 || partial) && (
        <footer className="flex flex-wrap items-center justify-between gap-2 border-t border-border px-4 py-2 @4xl/home:px-5">
          {partial ? <p className="text-xs text-text-muted">{COPY.partial}</p> : <span />}
          {hiddenCount > 0 && (
            <button
              type="button"
              aria-expanded={showAll}
              onClick={() => setExpand(showAll ? "less" : "all")}
              className={`inline-flex min-h-9 items-center gap-1 rounded-sm text-xs font-medium text-text-muted hover:text-gold ${FOCUS_RING}`}
            >
              {showAll ? COPY.showLess : COPY.showAll(total)}
              <ChevronDown
                size={14}
                strokeWidth={2}
                aria-hidden
                className={`transition-transform motion-reduce:transition-none ${showAll ? "rotate-180" : ""}`}
              />
            </button>
          )}
        </footer>
      )}
    </section>
  );
}

function Lane({ id, title, tooltip, children }: { id: string; title: string; tooltip?: string; children: React.ReactNode }) {
  return (
    <div role="group" aria-labelledby={id}>
      <h3 id={id} title={tooltip} className="px-4 pt-3 pb-1 text-[11px] font-semibold uppercase tracking-widest text-text-muted @4xl/home:px-5">
        {title}
      </h3>
      <ol>{children}</ol>
    </div>
  );
}

function GroupRow({ group: g, open, onToggle }: { group: AttentionGroup; open: boolean; onToggle: () => void }) {
  const Icon = SEVERITY_ICONS[g.severity] ?? SEVERITY_ICONS.info;
  const title = attentionTitle(g);
  const meta = attentionMeta(g);
  const amount = attentionAmount(g);
  const href = attentionGroupHref(g);
  const listId = `${attentionAnchorId(g.code)}-kayitlar`;
  const moduleHref = isModuleKey(g.module) ? MODULES[g.module].href : null;

  const body = (
    <>
      <span aria-hidden className={`absolute inset-y-2 left-0 w-[3px] rounded-r-sm ${SEVERITY_BAR[g.severity] ?? "bg-info"}`} />
      <Icon size={16} strokeWidth={1.75} aria-hidden className={`mt-0.5 shrink-0 ${SEVERITY_TEXT[g.severity] ?? ""}`} />
      <span className="min-w-0 flex-1">
        <span className="block text-sm font-medium text-text">{title}</span>
        {(meta || amount) && (
          <span className="block text-xs text-text-muted tabular-nums">
            {/* Dar panelde tutar satır altına iner (sağda sıkışmasın). */}
            {amount && <span className="@md/dikkat:hidden">{amount}</span>}
            {amount && meta && <span className="@md/dikkat:hidden"> · </span>}
            {meta}
          </span>
        )}
      </span>
      {amount && <span className="hidden text-sm font-semibold whitespace-nowrap tabular-nums @md/dikkat:inline">{amount}</span>}
    </>
  );

  // Tek kayıt (ya da kaydı olmayan grup): satırın tamamı bağlantı.
  if (href !== null || g.items.length === 0) {
    return (
      <li id={attentionAnchorId(g.code)} className="scroll-mt-4">
        {href ? (
          <Link href={href} className={ROW}>
            {body}
            <ChevronRight size={14} strokeWidth={2} aria-hidden className="mt-1 shrink-0 text-text-muted" />
          </Link>
        ) : (
          <div className={ROW_BASE}>{body}</div>
        )}
      </li>
    );
  }

  // Çok kayıt: açılır liste (en çok 3 kayıt + "+n daha" modül sayfasına).
  const more = g.count - g.items.length;
  return (
    <li id={attentionAnchorId(g.code)} className="scroll-mt-4">
      <button type="button" aria-expanded={open} aria-controls={listId} onClick={onToggle} className={ROW}>
        {body}
        <ChevronDown
          size={14}
          strokeWidth={2}
          aria-hidden
          className={`mt-1 shrink-0 text-text-muted transition-transform motion-reduce:transition-none ${open ? "rotate-180" : ""}`}
        />
      </button>
      <ul id={listId} hidden={!open} className="pr-4 pb-2 pl-11 @4xl/home:pr-5">
        {g.items.map((r) => {
          const recordHref = webHrefFor(r.ref);
          const line = attentionRecordLine(r, g.code);
          const amt = r.amount ? formatMoney(r.amount.amount, r.amount.currency) : null;
          const content = (
            <>
              <span className="min-w-0 flex-1">{line}</span>
              {amt && <span className="shrink-0 whitespace-nowrap tabular-nums text-text-muted">{amt}</span>}
            </>
          );
          return (
            <li key={`${r.ref.kind}-${r.ref.id}`}>
              {recordHref ? (
                <Link
                  href={recordHref}
                  className={`flex min-h-9 items-center gap-3 rounded-sm py-1 text-sm text-text hover:text-gold ${FOCUS_RING}`}
                >
                  {content}
                  <ChevronRight size={14} strokeWidth={2} aria-hidden className="shrink-0 text-text-muted" />
                </Link>
              ) : (
                <div className="flex min-h-9 items-center gap-3 py-1 text-sm text-text">{content}</div>
              )}
            </li>
          );
        })}
        {more > 0 && moduleHref && (
          <li>
            <Link
              href={moduleHref}
              className={`inline-flex min-h-9 items-center rounded-sm text-xs font-medium text-text-muted hover:text-gold ${FOCUS_RING}`}
            >
              {COPY.more(more)}
            </Link>
          </li>
        )}
      </ul>
    </li>
  );
}

function DateBlock({ date, today }: { date: string; today: string }) {
  const word = upcomingDayWord(date, today);
  const [, m, d] = date.split("-");
  return (
    <time
      dateTime={date}
      className={`flex w-11 shrink-0 flex-col items-center justify-center rounded-md border py-1 text-center ${
        word === "Bugün" ? "border-text/40" : "border-border"
      }`}
    >
      {word ? (
        <span className="text-[10px] font-semibold uppercase text-text">{word}</span>
      ) : (
        <>
          <span className="text-sm leading-tight font-bold tabular-nums text-text">{Number(d)}</span>
          <span className="text-[10px] font-semibold uppercase text-text-muted">{MONTHS_SHORT[Number(m) - 1] ?? ""}</span>
        </>
      )}
    </time>
  );
}

function UpcomingRow({ item: u, today }: { item: UpcomingItem; today: string }) {
  const href = webHrefFor(u.ref);
  const amount = u.amount ? formatMoney(u.amount.amount, u.amount.currency) : null;
  const body = (
    <>
      <DateBlock date={u.date} today={today} />
      <span className="min-w-0 flex-1">
        <span className="flex items-center gap-1.5 text-xs text-text-muted">
          <CalendarClock size={14} strokeWidth={1.75} aria-hidden className="shrink-0" />
          {upcomingLabel(u.kind)}
        </span>
        <span className="block text-sm text-text">{u.title}</span>
        {amount && <span className="block text-xs tabular-nums text-text-muted @md/dikkat:hidden">{amount}</span>}
      </span>
      {amount && <span className="hidden text-sm whitespace-nowrap tabular-nums text-text @md/dikkat:inline">{amount}</span>}
    </>
  );
  const cls = "flex min-h-11 items-center gap-3 px-4 py-2 @4xl/home:px-5";
  return (
    <li>
      {href ? (
        <Link href={href} className={`${cls} transition-colors hover:bg-gold-soft/30 ${FOCUS_RING}`}>
          {body}
        </Link>
      ) : (
        <div className={cls}>{body}</div>
      )}
    </li>
  );
}
