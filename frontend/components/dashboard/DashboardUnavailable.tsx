import { CircleAlert } from "lucide-react";
import Link from "next/link";

import { FOCUS_RING, LABEL } from "@/components/ui/styles";
import { COPY } from "@/lib/dashboard";
import { getNavItems } from "@/lib/nav";
import { NAV_ICONS } from "@/lib/nav-icons";
import type { User } from "@/lib/types";

import { RetryButton } from "./RetryButton";

// Özet isteği tamamen başarısız: başlık ve hızlı işlemler zaten çizili;
// burada hata notu + menüdeki (izinle süzülmüş) modüllere kısayollar.
export function DashboardUnavailable({ user }: { user: User }) {
  const shortcuts = getNavItems(user.role, user.permissions).filter((i) => i.href !== "/admin" && i.href !== "/panel");
  return (
    <div className="mx-auto flex w-full max-w-[96rem] flex-col gap-6 p-4 @2xl:p-6 @4xl:p-8">
      <section aria-labelledby="ozet-hata-baslik" className="rounded-lg border border-border bg-surface p-4 @4xl:p-5">
        <div className="flex flex-wrap items-start gap-3 rounded-md bg-danger-soft px-3 py-3">
          <CircleAlert size={18} strokeWidth={2} aria-hidden className="mt-0.5 shrink-0 text-danger" />
          <div className="min-w-0 flex-1">
            <h2 id="ozet-hata-baslik" className="text-sm font-semibold text-danger">
              {COPY.unavailableTitle}
            </h2>
            <p className="mt-0.5 text-sm text-text">{COPY.unavailableBody}</p>
          </div>
          <RetryButton />
        </div>
      </section>

      {shortcuts.length > 0 && (
        <section aria-labelledby="kisayollar-baslik" className="flex flex-col gap-3">
          <h2 id="kisayollar-baslik" className={LABEL}>
            {COPY.shortcuts}
          </h2>
          <ul className="grid grid-cols-1 gap-3 @min-[22rem]:grid-cols-2 @2xl:grid-cols-3 @4xl:grid-cols-4">
            {shortcuts.map((item) => {
              const Icon = NAV_ICONS[item.href];
              return (
                <li key={item.href}>
                  <Link
                    href={item.href}
                    className={`flex min-h-11 items-center gap-3 rounded-lg border border-border bg-surface px-4 py-3 text-sm font-medium text-text transition-colors hover:bg-surface-hover/60 ${FOCUS_RING}`}
                  >
                    {Icon && <Icon size={18} strokeWidth={1.75} aria-hidden className="shrink-0 text-text-muted" />}
                    {item.label}
                  </Link>
                </li>
              );
            })}
          </ul>
        </section>
      )}
    </div>
  );
}
