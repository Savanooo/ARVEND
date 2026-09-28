import { Badge } from "@/components/ui/Badge";
import { EMPTY, quickActionFor } from "@/lib/dashboard";
import { formatCount } from "@/lib/format";

import { CardLinks, CtaLink, EmptyNote, Metric, Note, Stat, StatGrid } from "../card-parts";
import type { CardContext } from "../context";
import { MissingModule, ModuleCard } from "../ModuleCard";

// Ekip (yalnızca Sahip/Yönetici + organization.users.read): kullanıcı
// hesapları, rollere dağılım, projesi/personel kaydı olmayanlar.
export function UsersCard({ ctx }: { ctx: CardContext }) {
  const s = ctx.data.sections.users;
  if (!s) return <MissingModule moduleKey="users" ctx={ctx} />;
  // Roller & Yetkiler bağlantısı: kişiye özel yetki sayısı yalnızca
  // organization.roles.read ile gelir -- aynı izin o sayfanın kapısıdır.
  const links = s.with_personal_overrides !== null ? [{ href: "/admin/roller", label: "Roller & Yetkiler" }] : [];

  if (s.active <= 1) {
    const add = quickActionFor(ctx.user, "user");
    return (
      <ModuleCard
        moduleKey="users"
        ctx={ctx}
        main={
          <>
            <EmptyNote text={EMPTY.users} action={add?.href ? <CtaLink href={add.href} label={add.label} /> : undefined} />
            <CardLinks links={links} />
          </>
        }
      />
    );
  }

  return (
    <ModuleCard
      moduleKey="users"
      ctx={ctx}
      main={
        <>
          <Metric label="Aktif kullanıcı" value={formatCount(s.active)} />
          <StatGrid>
            <Stat label="Hiç giriş yapmamış" value={formatCount(s.never_logged_in)} />
            <Stat label="Projesi olmayan" value={formatCount(s.restricted_without_project)} />
            <Stat label="Personel kaydı olmayan" value={formatCount(s.without_employee_link)} />
            {s.with_personal_overrides !== null && (
              <Stat label="Kişiye özel yetkili" value={formatCount(s.with_personal_overrides)} />
            )}
          </StatGrid>
        </>
      }
      aside={
        <>
          {s.by_role.length > 0 && (
            <ul aria-label="Rollere göre kullanıcılar" className="flex flex-wrap gap-1.5">
              {s.by_role.map((r) => (
                <li key={r.code}>
                  <Badge tone="muted">
                    {r.name} {formatCount(r.count)}
                  </Badge>
                </li>
              ))}
            </ul>
          )}
          {s.without_employee_link > 0 && (
            <Note>{`${formatCount(s.without_employee_link)} kullanıcının personel kaydı yok; görev listeleri boş görünür.`}</Note>
          )}
          <CardLinks links={links} />
        </>
      }
    />
  );
}
