import { SegmentBar } from "@/components/ui/SegmentBar";
import { COPY, EMPTY, quickActionFor } from "@/lib/dashboard";
import { formatCount, formatHours } from "@/lib/format";

import { CtaLink, EmptyNote, Metric, Note, Stat, StatGrid } from "../card-parts";
import type { CardContext } from "../context";
import { MissingModule, ModuleCard } from "../ModuleCard";

// Mesai / Puantaj -- FİRMA GENELİ (proje üyeliğine göre süzülmez, bu
// bilinçli; her yerde "Firma geneli" yazar). Pazar mesai beklenmez.
export function AttendanceCard({ ctx }: { ctx: CardContext }) {
  const a = ctx.data.sections.attendance;
  if (!a) return <MissingModule moduleKey="attendance" ctx={ctx} />;

  if (a.active_employees === 0) {
    // "Personel Ekle" hızlı işlemiyle aynı hedef ve kapı.
    const add = quickActionFor(ctx.user, "employee");
    return (
      <ModuleCard
        moduleKey="attendance"
        ctx={ctx}
        main={
          <EmptyNote text={EMPTY.attendanceNoEmployees} action={add?.href ? <CtaLink href={add.href} label={add.label} /> : undefined} />
        }
      />
    );
  }

  let visual: React.ReactNode;
  if (!ctx.data.is_workday) {
    visual = <Note>{EMPTY.attendanceSunday}</Note>;
  } else if (a.not_recorded >= a.active_employees) {
    const enter = quickActionFor(ctx.user, "attendance");
    visual = (
      <EmptyNote text={EMPTY.attendanceNothing} action={enter?.href ? <CtaLink href={enter.href} label={enter.label} /> : undefined} />
    );
  } else {
    visual = (
      <SegmentBar
        ariaLabel="Bugünkü mesai durumu, firma geneli"
        segments={[
          { key: "present", value: a.present, tone: "success", label: "Geldi" },
          { key: "half_day", value: a.half_day, tone: "gold", label: "Yarım gün" },
          { key: "absent", value: a.absent, tone: "danger", label: "Gelmedi" },
          { key: "on_leave", value: a.on_leave, tone: "muted", label: "İzinli" },
          { key: "not_recorded", value: a.not_recorded, tone: "dashed", label: "Girilmedi" },
        ]}
      />
    );
  }

  return (
    <ModuleCard
      moduleKey="attendance"
      ctx={ctx}
      main={
        <>
          <Metric
            label="Bugün sahada"
            value={`${formatCount(a.on_site)} / ${formatCount(a.active_employees)}`}
            detail={COPY.firmWide}
          />
          <StatGrid>
            <Stat label="Gelmedi" value={formatCount(a.absent)} />
            <Stat label="İzinli" value={formatCount(a.on_leave)} />
            <Stat label="Girilmedi" value={formatCount(a.not_recorded)} />
            <Stat label="Bu ay toplam" value={formatHours(a.month_work_hours)} />
          </StatGrid>
          {visual}
        </>
      }
    />
  );
}
