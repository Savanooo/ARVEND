import { EMPTY, quickActionFor } from "@/lib/dashboard";
import { formatCount } from "@/lib/format";

import { CtaLink, EmptyNote, Metric, Stat, StatGrid } from "../card-parts";
import type { CardContext } from "../context";
import { MissingModule, ModuleCard } from "../ModuleCard";

// Personel -- maaş/yevmiye ana sayfada ASLA gösterilmez (sunucu da seçmez).
export function EmployeesCard({ ctx }: { ctx: CardContext }) {
  const s = ctx.data.sections.employees;
  if (!s) return <MissingModule moduleKey="employees" ctx={ctx} />;
  if (s.active + s.inactive === 0) {
    const add = quickActionFor(ctx.user, "employee");
    return (
      <ModuleCard
        moduleKey="employees"
        ctx={ctx}
        main={<EmptyNote text={EMPTY.employees} action={add?.href ? <CtaLink href={add.href} label={add.label} /> : undefined} />}
      />
    );
  }
  return (
    <ModuleCard
      moduleKey="employees"
      ctx={ctx}
      main={
        <>
          <Metric label="Aktif personel" value={formatCount(s.active)} />
          <StatGrid>
            <Stat label="Pasif" value={formatCount(s.inactive)} />
            <Stat label="Kullanıcı hesabı olan" value={formatCount(s.with_user_account)} />
            <Stat label="Bu ay başlayan" value={formatCount(s.new_this_month)} />
          </StatGrid>
        </>
      }
    />
  );
}
