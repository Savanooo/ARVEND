import Link from "next/link";
import { cookies } from "next/headers";

import { Badge } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { Topbar } from "@/components/layout/Topbar";
import { apiServer } from "@/lib/api";
import { formatMoney } from "@/lib/format";
import {
  PROJECT_STATUS_LABELS,
  type Collection,
  type Expense,
  type FinancialSummary,
  type PaymentPlanItem,
  type Project,
  type ProjectEvent,
  type ProjectInvoice,
  type ProjectStatus,
  type Subcontractor,
  type SubcontractorPayment,
  type Employee,
  type OperationsSummary,
  type ProjectFile,
  type ProjectMember,
  type ProjectNote,
  type ProjectPhoto,
  type ProjectTask,
  type ScheduleItem,
} from "@/lib/types";

import { Section } from "./Accordion";
import { FinanceSummary } from "./FinanceSummary";
import {
  CollectionsSection,
  ExpensesSection,
  InvoicesSection,
  PaymentPlanSection,
  SubcontractorsSection,
} from "./FinanceSections";
import { ProfitabilitySection, ProjectActivitySection } from "./ProfitabilitySection";
import {
  FilesSection,
  MembersSection,
  NotesSection,
  PhotosSection,
  ScheduleSection,
  TasksSection,
} from "./OperationSections";

const STATUS_TONE: Record<ProjectStatus, "muted" | "gold" | "success" | "danger"> = {
  planned: "muted",
  active: "gold",
  paused: "muted",
  completed: "success",
  cancelled: "danger",
};

// Finans modülleri gelmeden tahsilat/masraf/kâr için sayı üretmiyoruz --
// "Kalan bakiye = sözleşme bedeli" demek, henüz hiç tahsilat kaydı
// tutulmadığı için doğru değil, sadece doğru GÖRÜNEN bir varsayım olurdu.
const NO_DATA = "—";

// Bu fazda yalnızca ilk üç bölüm çalışır; kalanlar ileride doldurulacak
// iskelettir.
// Faz 6'da finans bölümleri gerçek verilerle çalışır hale geldi; aşağıdakiler
// sonraki fazlara kaldı.
// Faz 7'de operasyon bölümleri gerçek verilerle çalışır hale geldi;
// geriye yalnızca Ek İşler (change orders) kaldı.
const PLACEHOLDER_SECTIONS = ["Ek İşler"];

function Row({ label, value }: { label: string; value: React.ReactNode }) {
  return (
    <div className="flex flex-col gap-0.5">
      <span className="text-xs uppercase tracking-widest text-text-muted">{label}</span>
      <span>{value}</span>
    </div>
  );
}

function formatDate(d: string | null) {
  return d ? new Date(d).toLocaleDateString("tr-TR") : NO_DATA;
}

export default async function ProjeDetayPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const cookieHeader = (await cookies()).toString();
  const base = `/api/v1/projects/${id}`;
  const [project, summary, plan, collections, expenses, invoices, subcontractors, subPayments, events] =
    await Promise.all([
      apiServer<Project>(base, cookieHeader),
      apiServer<FinancialSummary>(`${base}/financial-summary`, cookieHeader),
      apiServer<{ items: PaymentPlanItem[]; planned_total: number }>(`${base}/payment-plan`, cookieHeader),
      apiServer<{ collections: Collection[] }>(`${base}/collections`, cookieHeader),
      apiServer<{ expenses: Expense[] }>(`${base}/expenses`, cookieHeader),
      apiServer<{ invoices: ProjectInvoice[] }>(`${base}/invoices`, cookieHeader),
      apiServer<{ subcontractors: Subcontractor[] }>(`${base}/subcontractors`, cookieHeader),
      apiServer<{ payments: SubcontractorPayment[] }>(`${base}/subcontractor-payments`, cookieHeader),
      apiServer<{ events: ProjectEvent[] }>(`${base}/events`, cookieHeader),
    ]);

  const [ops, members, schedule, tasks, files, photos, notes, employees] = await Promise.all([
    apiServer<OperationsSummary>(`${base}/operations-summary`, cookieHeader),
    apiServer<{ members: ProjectMember[] }>(`${base}/members`, cookieHeader),
    apiServer<{ items: ScheduleItem[] }>(`${base}/schedule`, cookieHeader),
    apiServer<{ tasks: ProjectTask[] }>(`${base}/tasks`, cookieHeader),
    apiServer<{ files: ProjectFile[] }>(`${base}/files`, cookieHeader),
    apiServer<{ photos: ProjectPhoto[] }>(`${base}/photos`, cookieHeader),
    apiServer<{ notes: ProjectNote[] }>(`${base}/notes`, cookieHeader),
    apiServer<{ employees: Employee[] }>(`/api/v1/employees`, cookieHeader),
  ]);

  // Tamamlanmış/iptal edilmiş projede finans hareketleri kilitlidir --
  // backend zaten reddediyor, UI da form göstermez.
  const locked = project.status === "completed" || project.status === "cancelled";

  return (
    <>
      <Topbar
        title={`${project.project_no} — ${project.name}`}
        action={
          <div className="flex items-center gap-3">
            <Badge tone={STATUS_TONE[project.status]}>
              {PROJECT_STATUS_LABELS[project.status]}
            </Badge>
            <Link href={`/projeler/${project.id}/duzenle`}>
              <Button variant="secondary">Düzenle</Button>
            </Link>
          </div>
        }
      />

      <div className="flex flex-col gap-6 p-8">
        <FinanceSummary summary={summary} />

        {/* Operasyon özeti */}
        <div className="grid grid-cols-2 gap-3 md:grid-cols-5">
          <Row label="Aktif Ekip" value={`${ops.active_member_count} kişi`} />
          <Row label="Açık Görev" value={`${ops.open_task_count}`} />
          <Row
            label="Geciken Görev"
            value={
              <span className={ops.overdue_task_count > 0 ? "text-danger" : ""}>
                {ops.overdue_task_count}
              </span>
            }
          />
          <Row
            label="Tamamlanma"
            value={`%${ops.task_completion_ratio.toFixed(0)} (${ops.completed_task_count}/${ops.total_task_count})`}
          />
          <Row
            label="Süre"
            value={`${formatDate(project.start_date)} → ${formatDate(project.end_date)}`}
          />
        </div>

        {/* Üst özet şeridi */}
        <div className="grid grid-cols-2 gap-4 rounded-lg border border-border bg-surface p-4 text-sm md:grid-cols-4 lg:grid-cols-6">
          <Row label="Proje No" value={<span className="font-medium">{project.project_no}</span>} />
          <Row label="Müşteri" value={project.customer_name} />
          <Row
            label="Proje Bedeli"
            value={
              <span className="font-medium">
                {formatMoney(project.contract_amount, project.currency)}
              </span>
            }
          />
          <Row label="Başlangıç" value={formatDate(project.start_date)} />
          <Row label="Bitiş" value={formatDate(project.end_date)} />
          <Row
            label="Kaynak Teklif"
            value={
              <Link
                href={`/teklifler/${project.source_offer_id}`}
                className="hover:text-gold hover:underline"
              >
                {project.source_offer_no} · Rev. {project.source_revision_no}
              </Link>
            }
          />
        </div>

        <div className="flex flex-col gap-3">
          <Section title="Genel / Fiyat" defaultOpen>
            <div className="grid grid-cols-2 gap-4 md:grid-cols-4">
              <Row label="Proje No" value={project.project_no} />
              <Row label="Proje Adı" value={project.name} />
              <Row label="Proje Tipi" value={project.project_type || NO_DATA} />
              <Row label="Durum" value={PROJECT_STATUS_LABELS[project.status]} />
              <Row label="Başlangıç Tarihi" value={formatDate(project.start_date)} />
              <Row label="Planlanan Bitiş" value={formatDate(project.end_date)} />
              <Row label="Para Birimi" value={project.currency} />
              <Row
                label="Ana Sözleşme Bedeli"
                value={<span className="font-medium">{formatMoney(project.contract_amount, project.currency)}</span>}
              />
            </div>

            <div className="mt-4 grid grid-cols-2 gap-4 border-t border-border pt-4 md:grid-cols-4">
              <Row
                label="Tahsil Edilen"
                value={formatMoney(summary.collected_amount, project.currency)}
              />
              <Row
                label={summary.over_collected > 0 ? "Fazla Tahsilat" : "Kalan Bakiye"}
                value={formatMoney(
                  summary.over_collected > 0 ? summary.over_collected : summary.remaining_receivable,
                  project.currency
                )}
              />
              <Row
                label="Gerçekleşen Maliyet"
                value={formatMoney(summary.realized_cost, project.currency)}
              />
              <Row
                label="Gerçekleşen Brüt Kâr"
                value={`${formatMoney(summary.realized_gross_profit, project.currency)} (%${summary.realized_margin_percent})`}
              />
            </div>

            {project.description && (
              <div className="mt-4 border-t border-border pt-4">
                <Row label="Açıklama" value={project.description} />
              </div>
            )}
            {project.internal_notes && (
              <div className="mt-4 border-t border-border pt-4">
                <Row
                  label="Dahili Notlar (müşteri görmez)"
                  value={project.internal_notes}
                />
              </div>
            )}
          </Section>

          <Section title="Müşteri Bilgileri" defaultOpen>
            <div className="grid grid-cols-2 gap-4 md:grid-cols-4">
              <Row label="Müşteri" value={<span className="font-medium">{project.customer_name}</span>} />
              <Row label="Telefon" value={project.customer_phone || NO_DATA} />
              <Row label="E-posta" value={project.customer_email || NO_DATA} />
              <Row label="Adres" value={project.customer_address || NO_DATA} />
            </div>
            {project.customer_id && (
              <div className="mt-4 border-t border-border pt-4">
                <Link
                  href={`/musteriler/${project.customer_id}`}
                  className="text-sm hover:text-gold hover:underline"
                >
                  Müşteri kartını aç →
                </Link>
              </div>
            )}
            <p className="mt-3 text-xs text-text-muted">
              Bu bilgiler teklifin kabul edildiği andan alınmış anlık görüntüdür; müşteri kartı
              sonradan değişse bile proje kaydı değişmez.
            </p>
          </Section>

          <Section title="Teklif Bilgileri" defaultOpen>
            <div className="grid grid-cols-2 gap-4 md:grid-cols-4">
              <Row label="Teklif No" value={project.source_offer_no} />
              <Row label="Kabul Edilen Revizyon" value={`Revizyon ${project.source_revision_no}`} />
              <Row label="Teklif Toplamı" value={formatMoney(project.contract_amount, project.currency)} />
              <Row label="Para Birimi" value={project.currency} />
            </div>
            <div className="mt-4 border-t border-border pt-4">
              <Link href={`/teklifler/${project.source_offer_id}/revizyonlar/${project.source_revision_id}`}>
                <Button variant="secondary">Teklifi Görüntüle</Button>
              </Link>
            </div>
          </Section>

          <Section title="Ödeme Planı" defaultOpen>
            <PaymentPlanSection
              project={project}
              items={plan.items}
              plannedTotal={plan.planned_total}
              locked={locked}
            />
          </Section>

          <Section title="Tahsilatlar" defaultOpen>
            <CollectionsSection
              project={project}
              collections={collections.collections}
              planItems={plan.items}
              locked={locked}
            />
          </Section>

          <Section title="Masraflar">
            <ExpensesSection project={project} expenses={expenses.expenses} locked={locked} />
          </Section>

          <Section title="Fatura Bilgileri">
            <InvoicesSection project={project} invoices={invoices.invoices} locked={locked} />
          </Section>

          <Section title="Taşeronlar">
            <SubcontractorsSection
              project={project}
              subcontractors={subcontractors.subcontractors}
              payments={subPayments.payments}
              locked={locked}
            />
          </Section>

          <Section title="Maliyet / Kârlılık">
            <ProfitabilitySection summary={summary} />
          </Section>

          <Section title="Planlama" defaultOpen>
            <ScheduleSection project={project} items={schedule.items} locked={locked} />
          </Section>

          <Section title="Personel / Ekip" defaultOpen>
            <MembersSection
              project={project}
              members={members.members}
              employees={employees.employees}
              locked={locked}
            />
          </Section>

          <Section title="Görevler" defaultOpen>
            <TasksSection
              project={project}
              tasks={tasks.tasks}
              scheduleItems={schedule.items}
              members={members.members}
              locked={locked}
            />
          </Section>

          <Section title="Dosyalar">
            <FilesSection project={project} files={files.files} locked={locked} />
          </Section>

          <Section title="Şantiye Fotoğrafları">
            <PhotosSection project={project} photos={photos.photos} locked={locked} />
          </Section>

          <Section title="Notlar">
            <NotesSection project={project} notes={notes.notes} locked={locked} />
          </Section>

          <Section title="Aktivite Geçmişi">
            <ProjectActivitySection events={events.events} currency={project.currency} />
          </Section>

          {PLACEHOLDER_SECTIONS.map((title) => (
            <Section key={title} title={title} placeholder />
          ))}
        </div>
      </div>
    </>
  );
}
