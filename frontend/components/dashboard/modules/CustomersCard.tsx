import { EMPTY, quickActionFor } from "@/lib/dashboard";
import { formatCount } from "@/lib/format";

import { CtaLink, EmptyNote, Metric, Stat, StatGrid } from "../card-parts";
import type { CardContext } from "../context";
import { MissingModule, ModuleCard } from "../ModuleCard";

// Müşteriler (firma geneli; "aktif projesi olan" üyelik kapsamlı).
export function CustomersCard({ ctx }: { ctx: CardContext }) {
  const s = ctx.data.sections.customers;
  if (!s) return <MissingModule moduleKey="customers" ctx={ctx} />;
  if (s.active === 0) {
    const add = quickActionFor(ctx.user, "customer");
    return (
      <ModuleCard
        moduleKey="customers"
        ctx={ctx}
        main={<EmptyNote text={EMPTY.customers} action={add?.href ? <CtaLink href={add.href} label={add.label} /> : undefined} />}
      />
    );
  }
  return (
    <ModuleCard
      moduleKey="customers"
      ctx={ctx}
      main={
        <>
          <Metric label="Aktif müşteri" value={formatCount(s.active)} />
          <StatGrid>
            <Stat label="Bu ay eklenen" value={formatCount(s.new_this_month)} />
            <Stat label="Aktif projesi olan" value={formatCount(s.with_active_projects)} />
          </StatGrid>
        </>
      }
    />
  );
}
