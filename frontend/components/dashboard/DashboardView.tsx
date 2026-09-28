import { LABEL } from "@/components/ui/styles";
import {
  attentionPartial,
  COPY,
  layoutBands,
  ONBOARDING_STEPS,
  onboardingHiddenKey,
  pickKpis,
  secondaryPanel,
  sectionFailed,
  visibleModules,
  type DashboardResponse,
  type OnboardingStepKey,
} from "@/lib/dashboard";
import type { User } from "@/lib/types";

import { ActivityPanel } from "./ActivityPanel";
import { AttentionPanel } from "./AttentionPanel";
import { CashFlowPanel } from "./CashFlowPanel";
import { canAll, type CardContext } from "./context";
import { KpiRow } from "./KpiRow";
import { ModuleBands } from "./ModuleBands";
import { MyTasksPanel } from "./MyTasksPanel";
import { NotificationsPanel } from "./NotificationsPanel";
import { OnboardingChecklist, type ChecklistStep } from "./OnboardingChecklist";
import { SectionError } from "./SectionError";
import { SummaryLine } from "./SummaryLine";

// Özet yanıtından sayfanın tamamı (başlık hariç): özet satırı, Nabız (ya
// da kurulum listesi), Dikkat + Nakit Akışı/Görevlerim, modül bantları,
// Akış (Son Hareketler + Bildirimler). DOM sırası = görsel sıra.

function FailedPanel({ title }: { title: string }) {
  return (
    <section aria-label={title} className="flex h-full min-h-[17.5rem] flex-col rounded-lg border border-border bg-surface">
      <header className="border-b border-border px-4 py-3 @4xl/home:px-5">
        <h2 className={LABEL}>{title}</h2>
      </header>
      <div className="p-4 @4xl/home:p-5">
        <SectionError />
      </div>
    </section>
  );
}

function checklistSteps(data: DashboardResponse, ctx: CardContext): ChecklistStep[] {
  return (data.onboarding?.steps ?? []).flatMap((step) => {
    const meta = ONBOARDING_STEPS[step.key as OnboardingStepKey];
    if (!meta) return [];
    return [
      {
        key: step.key,
        title: meta.title,
        helper: meta.helper,
        done: step.done,
        detail: step.detail,
        cta: canAll(ctx, meta.cta.allOf) ? { label: meta.cta.label, href: meta.cta.href } : null,
      },
    ];
  });
}

export function DashboardView({ data, user }: { data: DashboardResponse; user: User }) {
  const onboarding = data.onboarding;
  const onboardingActive = onboarding !== null;
  const secondary = onboardingActive ? null : secondaryPanel(data);
  const kpis = onboardingActive ? [] : pickKpis(data);
  const layout = layoutBands(visibleModules(data, onboardingActive), onboardingActive);
  // Yalnızca dikkat/yaklaşan üreten bir bölüm hesaplanamadıysa liste eksiktir.
  const partial = attentionPartial(data);
  const ctx: CardContext = {
    data,
    user,
    promotedMyTasks: secondary === "my_tasks",
    dikkatVisible: !onboardingActive,
  };

  const activity = data.sections.activity;
  const showActivity = (activity !== undefined && activity.items.length > 0) || sectionFailed(data, "activity");
  const notifications = data.sections.notifications;
  const showNotifications = notifications !== undefined || sectionFailed(data, "notifications");
  const bothFeeds = showActivity && showNotifications;

  return (
    <div className="mx-auto flex w-full max-w-[96rem] flex-col gap-6 p-4 @2xl:p-6 @4xl:p-8">
      <SummaryLine data={data} />

      {onboarding ? (
        <OnboardingChecklist
          steps={checklistSteps(data, ctx)}
          doneCount={onboarding.done_count}
          total={onboarding.total}
          storageKey={onboardingHiddenKey(user.organization_id ?? "org", data.viewer.user_id || user.id)}
        />
      ) : (
        <KpiRow data={data} keys={kpis} />
      )}

      {!onboardingActive && (
        <div className="grid grid-cols-1 gap-4 @4xl:grid-cols-12">
          <div className={`min-w-0 ${secondary ? "@4xl:col-span-7 @6xl:col-span-8" : "@4xl:col-span-12"}`}>
            <AttentionPanel agenda={data.agenda} today={data.today} partial={partial} wide={secondary === null} />
          </div>
          {secondary === "cash" && (
            <div className="min-w-0 @4xl:col-span-5 @6xl:col-span-4">
              <CashFlowPanel data={data} />
            </div>
          )}
          {secondary === "my_tasks" && (
            <div className="min-w-0 @4xl:col-span-5 @6xl:col-span-4">
              <MyTasksPanel data={data} />
            </div>
          )}
        </div>
      )}

      <ModuleBands layout={layout} ctx={ctx} />

      {(showActivity || showNotifications) && (
        <div className="grid grid-cols-1 gap-4 @4xl:grid-cols-12">
          {showActivity && (
            <div className={`min-w-0 ${bothFeeds ? "@4xl:col-span-7 @6xl:col-span-8" : "@4xl:col-span-12"}`}>
              <ActivityPanel data={data} />
            </div>
          )}
          {showNotifications && (
            <div className={`min-w-0 ${bothFeeds ? "@4xl:col-span-5 @6xl:col-span-4" : "@4xl:col-span-12"}`}>
              {notifications ? (
                <NotificationsPanel notifications={notifications} nowIso={data.generated_at} />
              ) : (
                <FailedPanel title={COPY.notifications} />
              )}
            </div>
          )}
        </div>
      )}
    </div>
  );
}
