import { ChevronRight, CircleCheckBig } from "lucide-react";
import Link from "next/link";

import { FOCUS_RING } from "@/components/ui/styles";
import {
  attentionAnchorId,
  attentionGroupHref,
  attentionTitle,
  COPY,
  MODULES,
  type AttentionGroup,
  type ModuleKey,
} from "@/lib/dashboard";

import { SEVERITY_ICONS, SEVERITY_TEXT } from "./module-icons";

// Kartın alt satırı: modülün en acil en çok 2 dikkat grubu (sunucu
// sırasıyla); yoksa sakin "Bekleyen iş yok". Kartta renk YALNIZCA burada.
export function AttentionFooter({
  groups,
  moduleKey,
  dikkatVisible,
}: {
  groups: AttentionGroup[];
  moduleKey: ModuleKey;
  dikkatVisible: boolean;
}) {
  const shown = groups.slice(0, 2);
  return (
    <footer className="mt-auto border-t border-border px-4 py-2.5 @4xl/home:px-5">
      {shown.length === 0 ? (
        <p className="flex min-h-9 items-center gap-2 text-xs text-text-muted">
          <CircleCheckBig size={14} strokeWidth={2} aria-hidden className="shrink-0 text-success" />
          {COPY.quiet}
        </p>
      ) : (
        <ul>
          {shown.map((g) => {
            const Icon = SEVERITY_ICONS[g.severity] ?? SEVERITY_ICONS.info;
            // Tek kayıt -> kayda; çok kayıt -> Dikkat panelindeki grubu (açılır),
            // panel gizliyse modül sayfası.
            const href =
              attentionGroupHref(g) ?? (dikkatVisible ? `#${attentionAnchorId(g.code)}` : MODULES[moduleKey].href);
            const cls = `group flex min-h-9 items-center gap-2 rounded-sm text-sm text-text hover:text-gold ${FOCUS_RING}`;
            const content = (
              <>
                <Icon size={14} strokeWidth={2} aria-hidden className={`shrink-0 ${SEVERITY_TEXT[g.severity] ?? ""}`} />
                <span className="min-w-0 flex-1 truncate">{attentionTitle(g)}</span>
                <ChevronRight size={14} strokeWidth={2} aria-hidden className="shrink-0 text-text-muted" />
              </>
            );
            return (
              <li key={g.code}>
                {href.startsWith("#") ? (
                  // Sayfa içi çapa düz <a>: tarayıcı hashchange olayını üretir,
                  // Dikkat paneli grubu açar (Link history.pushState kullanır).
                  <a href={href} className={cls}>
                    {content}
                  </a>
                ) : (
                  <Link href={href} className={cls}>
                    {content}
                  </Link>
                )}
              </li>
            );
          })}
        </ul>
      )}
    </footer>
  );
}
