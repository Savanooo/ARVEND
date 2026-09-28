import { ProgressBar } from "@/components/ui/ProgressBar";
import { StatCard } from "@/components/ui/StatCard";
import { COPY, kpiGridClass, kpiTile, type DashboardResponse, type KpiKey } from "@/lib/dashboard";

import { KPI_ICONS } from "./module-icons";

// "Nabız": en çok 4 KPI kutusu (öncelik sırasıyla ilk uygun 4; 2'den azsa
// satır yok). Kutular nötrdür; yalnızca işaretli değer işaretiyle renklenir.
export function KpiRow({ data, keys }: { data: DashboardResponse; keys: KpiKey[] }) {
  if (keys.length < 2) return null;
  return (
    <section aria-labelledby="temel-gostergeler">
      <h2 id="temel-gostergeler" className="sr-only">
        {COPY.kpiHeading}
      </h2>
      <div className={kpiGridClass(keys.length)}>
        {keys.map((key) => {
          const t = kpiTile(data, key);
          const Icon = KPI_ICONS[key];
          return (
            <StatCard
              key={key}
              label={t.label}
              value={t.value}
              valueFull={t.valueFull}
              tone={t.tone}
              icon={<Icon size={16} strokeWidth={1.75} />}
              sub={t.sub}
              other={t.other}
              href={t.href}
            >
              {t.progress && (
                <ProgressBar pct={t.progress.pct} tone="success" label={t.label} valueText={t.progress.label} />
              )}
            </StatCard>
          );
        })}
      </div>
    </section>
  );
}
