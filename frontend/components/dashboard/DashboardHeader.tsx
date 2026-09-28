import { COPY, firstName, quickActionsFor } from "@/lib/dashboard";
import { formatLongDate, istanbulDate } from "@/lib/format";
import { userRoleLabel, type User } from "@/lib/types";

import { QuickActions } from "./QuickActions";

// Anında çizilen başlık (yalnızca /auth/me verisi): "Merhaba, {ad}" (günün
// saatine göre selamlama YOK), İstanbul takvimine göre bugünün tarihi,
// firma ve rol; sağda hızlı işlemler.
export function DashboardHeader({ user }: { user: User }) {
  const today = istanbulDate(new Date());
  return (
    <header className="border-b border-border">
      <div className="mx-auto flex w-full max-w-[96rem] flex-wrap items-center justify-between gap-x-6 gap-y-3 px-4 py-5 @2xl:px-6 @4xl:px-8">
        <div className="min-w-0">
          <h1 className="text-xl font-bold tracking-tight text-balance">{COPY.greeting(firstName(user.full_name))}</h1>
          <p className="mt-0.5 text-sm text-text-muted">
            <time dateTime={today}>{formatLongDate(today)}</time>
            {user.organization_name && <span className="hidden @2xl:inline"> · {user.organization_name}</span>}
            <span> · {userRoleLabel(user)}</span>
          </p>
        </div>
        <QuickActions actions={quickActionsFor(user)} />
      </div>
    </header>
  );
}
