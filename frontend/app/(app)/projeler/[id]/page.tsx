import Link from "next/link";
import { cookies } from "next/headers";

import { Button } from "@/components/ui/Button";
import { StatusBadge } from "@/components/ui/StatusBadge";
import { ControlledTabPanel, ControlledTabs } from "@/components/ui/Tabs";
import { PageHeader } from "@/components/layout/PageHeader";
import { apiServer } from "@/lib/api";
import { formatMoney, formatSignedMoney } from "@/lib/format";
import { PROJECT_STATUS } from "@/lib/status";
import {
  type BudgetAdjustment,
  type BudgetLine,
  type ChangeOrder,
  type Collection,
  type Commitment,
  type CostControlData,
  type CostForecast,
  type Expense,
  type FinancialSummary,
  type OrganizationCostCode,
  type OrgUserOption,
  type PaymentPlanItem,
  type Project,
  type ProjectAccessUser,
  type ProjectBudget,
  type ProjectEvent,
  type ProjectInvoice,
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
  type WBSNode,
} from "@/lib/types";

import { Section } from "@/components/ui/Accordion";
import { ProjectAccessSection } from "./AccessSections";
import { ChangeOrdersSection } from "./ChangeOrderSections";
import { CostControlWorkspace } from "./CostControlSections";
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

// Finans modülleri gelmeden tahsilat/masraf/kâr için sayı üretmiyoruz --
// "Kalan bakiye = sözleşme bedeli" demek, henüz hiç tahsilat kaydı
// tutulmadığı için doğru değil, sadece doğru GÖRÜNEN bir varsayım olurdu.
const NO_DATA = "—";

// 17 bölüm, 5 üst-seviye sekmeye ayrılır (Genel/Finans/Operasyon/
// Dosyalar/Aktivite). TÜM veri page.tsx'te (Server Component) Promise.all
// ile önceden çekildiği için, ControlledTabs TÜM panel'leri DOM'da tutar
// (yalnızca CSS ile gizler) -- sekme değişiminde yeniden fetch veya
// accordion-açık durumu kaybı olmaz.

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

// settled, bir Promise.allSettled sonucunu null-güvenli bir değere çevirir.
// RBAC/Project Membership sprint'i: kullanıcının org rolü (project_manager/
// finance/field) bu projenin YALNIZCA bir kısmına izinli olabilir (ör.
// finance yalnızca finans uçlarına, field yalnızca operasyon uçlarına
// erişebilir) -- TEK bir 403, eskisi gibi (Promise.all) TÜM sayfayı
// çökertmemeli. Her kaynak bağımsız olarak null'a düşer, ilgili bölüm
// sessizce gizlenir (spec'in mobil için istediği "erişilemeyen alanı
// gösterme" ilkesinin web'deki karşılığı -- client-side gizleme yalnızca
// UX'tir, gerçek sınır zaten backend'de).
function settled<T>(r: PromiseSettledResult<T>): T | null {
  return r.status === "fulfilled" ? r.value : null;
}

export default async function ProjeDetayPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const cookieHeader = (await cookies()).toString();
  const base = `/api/v1/projects/${id}`;

  // project, sayfanın var olabilmesi için ZORUNLUDUR -- ayrı ve
  // korumasız çekilir; başarısızsa (proje yok/erişim yok) temiz bir
  // "erişim yok" ekranı gösterilir (Next.js'in ham hata sayfası yerine).
  let project: Project;
  try {
    project = await apiServer<Project>(base, cookieHeader);
  } catch {
    return (
      <>
        <PageHeader title="Proje" />
        <div className="p-8">
          <div className="rounded-lg border border-border bg-surface p-6 text-sm text-text-muted">
            Bu projeyi görüntüleme yetkiniz yok ya da proje bulunamadı.
          </div>
        </div>
      </>
    );
  }

  const [
    summaryR, planR, collectionsR, expensesR, invoicesR, subcontractorsR, subPaymentsR, eventsR,
    opsR, membersR, scheduleR, tasksR, filesR, photosR, notesR, employeesR, changeOrdersR, accessR, orgUsersR,
    costControlR, budgetR, budgetLinesR, wbsNodesR, adjustmentsR, commitmentsR, forecastsR, costCodesR,
  ] = await Promise.allSettled([
    apiServer<FinancialSummary>(`${base}/financial-summary`, cookieHeader),
    apiServer<{ items: PaymentPlanItem[]; planned_total: number }>(`${base}/payment-plan`, cookieHeader),
    apiServer<{ collections: Collection[] }>(`${base}/collections`, cookieHeader),
    apiServer<{ expenses: Expense[] }>(`${base}/expenses`, cookieHeader),
    apiServer<{ invoices: ProjectInvoice[] }>(`${base}/invoices`, cookieHeader),
    apiServer<{ subcontractors: Subcontractor[] }>(`${base}/subcontractors`, cookieHeader),
    apiServer<{ payments: SubcontractorPayment[] }>(`${base}/subcontractor-payments`, cookieHeader),
    apiServer<{ events: ProjectEvent[] }>(`${base}/events`, cookieHeader),
    apiServer<OperationsSummary>(`${base}/operations-summary`, cookieHeader),
    apiServer<{ members: ProjectMember[] }>(`${base}/members`, cookieHeader),
    apiServer<{ items: ScheduleItem[] }>(`${base}/schedule`, cookieHeader),
    apiServer<{ tasks: ProjectTask[] }>(`${base}/tasks`, cookieHeader),
    apiServer<{ files: ProjectFile[] }>(`${base}/files`, cookieHeader),
    apiServer<{ photos: ProjectPhoto[] }>(`${base}/photos`, cookieHeader),
    apiServer<{ notes: ProjectNote[] }>(`${base}/notes`, cookieHeader),
    apiServer<{ employees: Employee[] }>(`/api/v1/employees?filter=aktif`, cookieHeader),
    apiServer<{ change_orders: ChangeOrder[] }>(`${base}/change-orders`, cookieHeader),
    apiServer<{ users: ProjectAccessUser[] }>(`${base}/access`, cookieHeader),
    // Kullanıcı seçici yalnızca projects.access.manage sahibi (owner/admin/
    // legacy_user) tarafından kullanılır -- bu roller zaten organization.
    // users.read'e de sahiptir (bkz. router.go /users grubu), bu yüzden
    // project_manager/finance/field için bu çağrı 403 olsa bile (seçiciyi
    // hiç göremeyecekleri için) sorun yaratmaz.
    apiServer<{ users: OrgUserOption[] }>("/api/v1/users?limit=200", cookieHeader),
    // Sprint 2 -- Maliyet Kontrolü. cost-control TEK istekte özet+kırılım
    // döner (N+1 yok); budget AYRI çekilir çünkü bütçesiz bir projede 404
    // döner (settled() bunu null'a indirger, "Bütçe" sekmesi bunu "Bütçe
    // Oluştur" CTA'sına çevirir) -- cost-control İSE bütçesiz projede bile
    // 200 döner (bkz. handler yorumu).
    apiServer<CostControlData>(`${base}/cost-control`, cookieHeader),
    apiServer<ProjectBudget>(`${base}/budget`, cookieHeader),
    apiServer<{ budget_lines: BudgetLine[] }>(`${base}/budget/lines`, cookieHeader),
    apiServer<{ wbs_nodes: WBSNode[] }>(`${base}/wbs`, cookieHeader),
    apiServer<{ adjustments: BudgetAdjustment[] }>(`${base}/budget/adjustments`, cookieHeader),
    apiServer<{ commitments: Commitment[] }>(`${base}/commitments`, cookieHeader),
    apiServer<{ forecasts: CostForecast[] }>(`${base}/forecasts`, cookieHeader),
    apiServer<{ cost_codes: OrganizationCostCode[] }>("/api/v1/organization/cost-codes", cookieHeader),
  ]);

  const summary = settled(summaryR);
  const plan = settled(planR);
  const collections = settled(collectionsR);
  const expenses = settled(expensesR);
  const invoices = settled(invoicesR);
  const subcontractors = settled(subcontractorsR);
  const subPayments = settled(subPaymentsR);
  const events = settled(eventsR);
  const ops = settled(opsR);
  const members = settled(membersR);
  const schedule = settled(scheduleR);
  const tasks = settled(tasksR);
  const files = settled(filesR);
  const photos = settled(photosR);
  const notes = settled(notesR);
  const employees = settled(employeesR);
  const changeOrders = settled(changeOrdersR);
  const access = settled(accessR);
  const orgUsers = settled(orgUsersR);
  const costControl = settled(costControlR);
  const budget = settled(budgetR);
  const budgetLines = settled(budgetLinesR);
  const wbsNodes = settled(wbsNodesR);
  const adjustments = settled(adjustmentsR);
  const commitments = settled(commitmentsR);
  const forecasts = settled(forecastsR);
  const costCodes = settled(costCodesR);

  // Tamamlanmış/iptal edilmiş projede finans hareketleri kilitlidir --
  // backend zaten reddediyor, UI da form göstermez.
  const locked = project.status === "completed" || project.status === "cancelled";

  return (
    <>
      <PageHeader
        title={`${project.project_no} — ${project.name}`}
        action={
          <div className="flex items-center gap-3">
            <StatusBadge status={project.status} registry={PROJECT_STATUS} />
            <Link href={`/projeler/${project.id}/duzenle`}>
              <Button variant="secondary">Düzenle</Button>
            </Link>
          </div>
        }
      />

      <div className="flex flex-col gap-6 p-8">
        {summary && <FinanceSummary summary={summary} />}

        {/* Operasyon özeti — ops null ise (ör. finance rolü, operations.read
            iznine sahip değil) tamamen gizlenir. */}
        {ops && (
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
        )}

        {/* Üst özet şeridi */}
        <div className="grid grid-cols-2 gap-4 rounded-lg border border-border bg-surface p-4 text-sm md:grid-cols-4 lg:grid-cols-6">
          <Row label="Proje No" value={<span className="font-medium">{project.project_no}</span>} />
          <Row label="Müşteri" value={project.customer_name} />
          <Row
            label="Ana Sözleşme Bedeli"
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

        <ControlledTabs
          defaultTab="genel"
          items={[
            { key: "genel", label: "Genel" },
            { key: "finans", label: "Finans" },
            { key: "maliyet", label: "Maliyet Kontrolü" },
            { key: "operasyon", label: "Operasyon" },
            { key: "dosyalar", label: "Dosyalar" },
            { key: "aktivite", label: "Aktivite" },
          ]}
        >
          <ControlledTabPanel tab="genel">
            <Section title="Genel / Fiyat" defaultOpen>
              <div className="grid grid-cols-2 gap-4 md:grid-cols-4">
                <Row label="Proje No" value={project.project_no} />
                <Row label="Proje Adı" value={project.name} />
                <Row label="Proje Tipi" value={project.project_type || NO_DATA} />
                <Row label="Durum" value={<StatusBadge status={project.status} registry={PROJECT_STATUS} />} />
                <Row label="Başlangıç Tarihi" value={formatDate(project.start_date)} />
                <Row label="Planlanan Bitiş" value={formatDate(project.end_date)} />
                <Row label="Para Birimi" value={project.currency} />
              </div>

              {/* Fiyat kırılımı: ana sözleşme + onaylı ek işler/eksiltmeler.
                  Bunların toplamı olan güncel proje bedeli üstteki KPI
                  şeridinde; gerçekleşen kâr/marj ise Finans > Maliyet /
                  Kârlılık bölümünde -- burada tekrarlanmaz. summary null ise
                  (finance.read izni yok) yalnızca ASLA değişmeyen ana
                  sözleşme bedeli gösterilir. */}
              <div className="mt-4 grid grid-cols-2 gap-4 border-t border-border pt-4 md:grid-cols-4">
                <Row
                  label="Ana Sözleşme Bedeli"
                  value={<span className="font-medium">{formatMoney(project.contract_amount, project.currency)}</span>}
                />
                {summary && (
                  <>
                    <Row
                      label="Onaylı Ek İşler"
                      value={
                        <span className={summary.approved_additions > 0 ? "text-success" : ""}>
                          {formatSignedMoney(summary.approved_additions, project.currency)}
                        </span>
                      }
                    />
                    <Row
                      label="Onaylı Eksiltmeler"
                      value={
                        <span className={summary.approved_deductions > 0 ? "text-danger" : ""}>
                          {formatSignedMoney(-summary.approved_deductions, project.currency)}
                        </span>
                      }
                    />
                    <Row
                      label="Güncel Proje Bedeli"
                      value={
                        <span className="font-medium text-gold">
                          {formatMoney(summary.current_contract_value, project.currency)}
                        </span>
                      }
                    />
                  </>
                )}
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
          </ControlledTabPanel>

          <ControlledTabPanel tab="finans">
            {/* Bu sekmenin TÜM kaynakları AYNI izne (projects.finance.read)
                bağlıdır -- ya hepsi doludur ya da (finance izni olmayan bir
                rol, ör. field) hepsi null'dır; tek bir kontrol yeterli. */}
            {summary && plan && collections && expenses && invoices && subcontractors && subPayments && changeOrders ? (
              <>
                <Section title="Ödeme Planı" defaultOpen>
                  <PaymentPlanSection
                    project={project}
                    items={plan.items}
                    plannedTotal={plan.planned_total}
                    currentContractValue={summary.current_contract_value}
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

                <ExpensesSection
                  project={project}
                  expenses={expenses.expenses}
                  changeOrders={changeOrders.change_orders}
                  costCodes={costCodes?.cost_codes ?? []}
                  budgetLines={budgetLines?.budget_lines ?? []}
                  locked={locked}
                />

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

                <Section title="Ek İşler" defaultOpen>
                  <ChangeOrdersSection project={project} changeOrders={changeOrders.change_orders} locked={locked} />
                </Section>
              </>
            ) : (
              <p className="text-sm text-text-muted">Bu bölümü görüntüleme yetkiniz yok.</p>
            )}
          </ControlledTabPanel>

          <ControlledTabPanel tab="maliyet">
            {costControl ? (
              <CostControlWorkspace
                project={project}
                data={costControl}
                budget={budget}
                budgetLines={budgetLines?.budget_lines ?? []}
                wbsNodes={wbsNodes?.wbs_nodes ?? []}
                costCodes={costCodes?.cost_codes ?? []}
                adjustments={adjustments?.adjustments ?? []}
                commitments={commitments?.commitments ?? []}
                forecasts={forecasts?.forecasts ?? []}
                expenses={expenses?.expenses ?? []}
                locked={locked}
              />
            ) : (
              <p className="text-sm text-text-muted">Bu bölümü görüntüleme yetkiniz yok.</p>
            )}
          </ControlledTabPanel>

          <ControlledTabPanel tab="operasyon">
            {/* Planlama/Personel/Notlar/Proje Erişimi = projects.operations.*;
                Görevler AYRI bir izin (projects.tasks.*) -- ikisi genelde
                birlikte gelir ama ayrı ayrı kontrol edilir. */}
            {schedule && (
              <Section title="Planlama" defaultOpen>
                <ScheduleSection project={project} items={schedule.items} locked={locked} />
              </Section>
            )}

            {members && employees && (
              <Section title="Personel / Ekip" defaultOpen>
                <MembersSection
                  project={project}
                  members={members.members}
                  employees={employees.employees}
                  locked={locked}
                />
              </Section>
            )}

            {tasks && schedule && members && (
              <Section title="Görevler" defaultOpen>
                <TasksSection
                  project={project}
                  tasks={tasks.tasks}
                  scheduleItems={schedule.items}
                  members={members.members}
                  locked={locked}
                />
              </Section>
            )}

            {notes && (
              <Section title="Notlar">
                <NotesSection project={project} notes={notes.notes} locked={locked} />
              </Section>
            )}

            {access && (
              <Section title="Proje Erişimi">
                <ProjectAccessSection
                  project={project}
                  users={access.users}
                  orgUsers={orgUsers?.users ?? []}
                />
              </Section>
            )}

            {!schedule && !members && !tasks && !notes && !access && (
              <p className="text-sm text-text-muted">Bu bölümü görüntüleme yetkiniz yok.</p>
            )}
          </ControlledTabPanel>

          <ControlledTabPanel tab="dosyalar">
            {files && photos ? (
              <>
                <Section title="Dosyalar" defaultOpen>
                  <FilesSection project={project} files={files.files} locked={locked} />
                </Section>

                <Section title="Şantiye Fotoğrafları" defaultOpen>
                  <PhotosSection project={project} photos={photos.photos} locked={locked} />
                </Section>
              </>
            ) : (
              <p className="text-sm text-text-muted">Bu bölümü görüntüleme yetkiniz yok.</p>
            )}
          </ControlledTabPanel>

          <ControlledTabPanel tab="aktivite">
            <Section title="Aktivite Geçmişi" defaultOpen>
              {events ? (
                <ProjectActivitySection events={events.events} currency={project.currency} />
              ) : (
                <p className="text-sm text-text-muted">Bu bölümü görüntüleme yetkiniz yok.</p>
              )}
            </Section>
          </ControlledTabPanel>
        </ControlledTabs>
      </div>
    </>
  );
}
