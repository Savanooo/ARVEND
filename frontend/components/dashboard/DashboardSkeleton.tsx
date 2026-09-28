import { Skeleton } from "@/components/ui/Skeleton";
import {
  compactSpanClass,
  kpiGridClass,
  layoutBands,
  MODULE_KEYS,
  predictKpiCount,
  predictSections,
  spanClass,
} from "@/lib/dashboard";
import type { User } from "@/lib/types";

// Özet gelene kadar (sayfa içi Suspense) iskelet: sunucunun döndüreceği
// bölümler kullanıcının izinlerinden AYNI kapılarla tahmin edilir, kartlar
// gerçek ızgara sınıflarıyla çizilir (yerleşim yüklenince zıplamaz).
// Yüklenirken hiçbir yerde "0" gösterilmez.
const PULSE = "motion-reduce:animate-none";

export function DashboardSkeleton({ user }: { user: User }) {
  const sections = predictSections(user);
  const kpiCount = predictKpiCount(sections);
  const layout = layoutBands(
    MODULE_KEYS.filter((k) => sections.includes(k)),
    false
  );
  const secondary = sections.includes("finance") || sections.includes("tasks");

  return (
    <div
      aria-busy="true"
      aria-label="Özet yükleniyor"
      className="mx-auto flex w-full max-w-[96rem] flex-col gap-6 p-4 @2xl:p-6 @4xl:p-8"
    >
      <Skeleton className={`h-5 w-72 max-w-full ${PULSE}`} />
      {kpiCount > 0 && (
        <div className={kpiGridClass(kpiCount)}>
          {Array.from({ length: kpiCount }, (_, i) => (
            <Skeleton key={i} className={`h-28 ${PULSE}`} />
          ))}
        </div>
      )}
      <div className="grid grid-cols-1 gap-4 @4xl:grid-cols-12">
        <Skeleton className={`h-[17.5rem] ${PULSE} ${secondary ? "@4xl:col-span-7 @6xl:col-span-8" : "@4xl:col-span-12"}`} />
        {secondary && <Skeleton className={`h-[17.5rem] ${PULSE} @4xl:col-span-5 @6xl:col-span-4`} />}
      </div>
      {layout.bands.map((band) => (
        <div key={band.key} className="flex flex-col gap-3">
          <Skeleton className={`h-3 w-32 ${PULSE}`} />
          {band.standard.length > 0 && (
            <div className="grid grid-cols-12 gap-3 @4xl:gap-4">
              {band.standard.map((key, i) => (
                <Skeleton key={key} className={`h-52 ${PULSE} ${spanClass(i, band.standard.length)}`} />
              ))}
            </div>
          )}
          {band.compact.length > 0 && (
            <div className="grid grid-cols-12 gap-3 @4xl:gap-4">
              {band.compact.map((key, i) => (
                <Skeleton key={key} className={`h-18 ${PULSE} ${compactSpanClass(i, band.compact.length)}`} />
              ))}
            </div>
          )}
        </div>
      ))}
    </div>
  );
}
