import Link from "next/link";
import { cookies } from "next/headers";
import { notFound } from "next/navigation";

import { Button } from "@/components/ui/Button";
import { StatusBadge } from "@/components/ui/StatusBadge";
import { ControlledTabPanel, ControlledTabs } from "@/components/ui/Tabs";
import { PageHeader } from "@/components/layout/PageHeader";
import { apiServer, ApiError } from "@/lib/api";
import { getCurrentUser } from "@/lib/auth";
import { parseProjectTab } from "@/lib/dashboard";
import { formatMoney, formatSignedMoney } from "@/lib/format";
import { hasPermission, PAGE_PERMISSIONS } from "@/lib/permissions";
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
  type ProjectContract,
  type ProjectEvent,
  type ProjectInvoice,
  type Subcontractor,
  type SubcontractorPayment,
  type OperationsSummary,
  type ProjectFile,
  type ProjectMember,
  type ProjectNote,
  type ProjectPhoto,
  type ProjectTask,
  type PurchaseOrder,
  type PurchaseRequest,
  type RFQ,
  type ScheduleItem,
  type Supplier,
  type WBSNode,
} from "@/lib/types";

import { Section } from "@/components/ui/Accordion";
import { ProjectAccessSection } from "./AccessSections";
import { ChangeOrdersSection } from "./ChangeOrderSections";
import { ContractSection } from "./ContractSection";
import { CostControlWorkspace } from "./CostControlSections";
import { PurchasingWorkspace } from "./PurchasingSections";
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
  type ProjectAssignee,
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
  searchParams,
}: {
  params: Promise<{ id: string }>;
  // ?tab=genel|finans|maliyet|satinalma|operasyon|dosyalar|aktivite -- ana
  // sayfadaki kayıt bağlantıları ilgili sekmeyi açar; bilinmeyen değer "genel".
  searchParams: Promise<{ tab?: string | string[] }>;
}) {
  const { id } = await params;
  const defaultTab = parseProjectTab((await searchParams).tab);
  const cookieHeader = (await cookies()).toString();
  const base = `/api/v1/projects/${id}`;
  // Proje üyesi olan ama teklif görme izni olmayan roller (Proje Yöneticisi/
  // Finans/Saha) için kaynak teklif bağlantıları düz metne döner -- tıklanınca
  // teklif sayfası backend 403'ü ile çöküyordu. Düzenle yalnızca
  // projects.update ile.
  const user = await getCurrentUser();
  const canReadOffers = hasPermission(user?.permissions, PAGE_PERMISSIONS.offers);
  const canUpdateProject = hasPermission(user?.permissions, "projects.update");
  // Bölüm içi yazma düğmeleri, backend'in o uçta zorladığı izne göre
  // gösterilir (bkz. router.go) -- izni olmayana düğme gösterip 403
  // döndürmek yerine. Asıl sınır yine backend'dir.
  const perms = user?.permissions;
  const canReadContract = hasPermission(perms, "projects.contracts.read");
  const canManageContract = hasPermission(perms, "projects.contracts.manage");
  const canContractLifecycle = hasPermission(perms, "projects.contracts.lifecycle");
  const canManageFinance = hasPermission(perms, "projects.finance.manage");
  const canApproveExpenses = hasPermission(perms, "projects.expenses.approve");
  const canManageProcurement = hasPermission(perms, "projects.procurement.manage");
  const canApproveProcurement = hasPermission(perms, "projects.procurement.approve");
  // Operasyon düğmeleri izne göre: Saha'da tasks.create yok (Görev Ekle
  // gizlenir), operations.manage ekle/çıkar düğmelerini açar.
  const canCreateTasks = hasPermission(perms, "projects.tasks.create");
  const canManageOperations = hasPermission(perms, "projects.operations.manage");

  // project, sayfanın var olabilmesi için ZORUNLUDUR -- ayrı ve
  // korumasız çekilir; proje yoksa (404: silinmiş/bayat bağlantı) "Kayıt
  // bulunamadı", erişim yoksa temiz bir "erişim yok" ekranı gösterilir
  // (Next.js'in ham hata sayfası yerine).
  const project = await apiServer<Project>(base, cookieHeader).catch((err: unknown) =>
    err instanceof ApiError && err.status === 404 ? ("missing" as const) : null
  );
  if (project === "missing") notFound();
  if (!project) {
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
    opsR, membersR, scheduleR, tasksR, filesR, photosR, notesR, assigneesR, changeOrdersR, contractR, accessR, orgUsersR,
    costControlR, budgetR, budgetLinesR, wbsNodesR, adjustmentsR, commitmentsR, forecastsR, costCodesR,
    purchaseRequestsR, rfqsR, purchaseOrdersR, suppliersR,
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
    // Ekip/görev/plan seçicileri: ücretsiz personel listesi + proje erişimi
    // (projects.read yeter). Eskiden /employees (employees.read) çekiliyordu;
    // Proje Yöneticisi/Saha'da o izin olmadığı için "Personel / Ekip"
    // bölümü hiç görünmüyordu.
    apiServer<{ employees: ProjectAssignee[] }>(`${base}/assignees`, cookieHeader),
    apiServer<{ change_orders: ChangeOrder[] }>(`${base}/change-orders`, cookieHeader),
    // Sprint 3 -- Sözleşme (Contract). Sözleşmesi henüz oluşturulmamış bir
    // projede (backfill YOK) 404 döner -- settled() bunu null'a indirger,
    // ContractSection bunu "Sözleşme Oluştur" CTA'sına çevirir (Bütçe'nin
    // AYNI deseni).
    apiServer<ProjectContract>(`${base}/contract`, cookieHeader),
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
    // Sprint 4 -- Procurement Foundation. Liste uçları kalem/tedarikçi
    // detayı TAŞIMAZ (ChangeOrderCard'ın AYNI ilkesi) -- detay, satır
    // genişletildiğinde istemci tarafında AYRICA çekilir (N+1'i yalnızca
    // gerçekten AÇILAN satırlar için ödemek üzere).
    apiServer<{ purchase_requests: PurchaseRequest[] }>(`${base}/purchase-requests`, cookieHeader),
    apiServer<{ rfqs: RFQ[] }>(`${base}/rfqs`, cookieHeader),
    apiServer<{ purchase_orders: PurchaseOrder[] }>(`${base}/purchase-orders`, cookieHeader),
    apiServer<{ suppliers: Supplier[] }>("/api/v1/organization/suppliers", cookieHeader),
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
  const assignees = settled(assigneesR)?.employees ?? null;
  const changeOrders = settled(changeOrdersR);
  const contract = settled(contractR);
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
  const purchaseRequests = settled(purchaseRequestsR);
  const rfqs = settled(rfqsR);
  const purchaseOrders = settled(purchaseOrdersR);
  const suppliers = settled(suppliersR);

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
            {canUpdateProject && (
              <Link href={`/projeler/${project.id}/duzenle`}>
                <Button variant="secondary">Düzenle</Button>
              </Link>
            )}
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
              canReadOffers ? (
                <Link
                  href={`/teklifler/${project.source_offer_id}`}
                  className="hover:text-gold hover:underline"
                >
                  {project.source_offer_no} · Rev. {project.source_revision_no}
                </Link>
              ) : (
                `${project.source_offer_no} · Rev. ${project.source_revision_no}`
              )
            }
          />
        </div>

        {/* key: aynı sayfadayken ?tab= değişirse (ör. başka bir derin
            bağlantı) sekme durumu yeni değerle baştan kurulur. */}
        <ControlledTabs
          key={defaultTab}
          defaultTab={defaultTab}
          items={[
            { key: "genel", label: "Genel" },
            { key: "finans", label: "Finans" },
            { key: "maliyet", label: "Maliyet Kontrolü" },
            { key: "satinalma", label: "Satın Alma" },
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
              {canReadOffers && (
                <div className="mt-4 border-t border-border pt-4">
                  <Link href={`/teklifler/${project.source_offer_id}/revizyonlar/${project.source_revision_id}`}>
                    <Button variant="secondary">Teklifi Görüntüle</Button>
                  </Link>
                </div>
              )}
            </Section>
          </ControlledTabPanel>

          <ControlledTabPanel tab="finans">
            {/* Sözleşme (Sprint 3) kendi 3-katmanlı izin setine sahiptir
                (contracts.read/manage/lifecycle) -- AŞAĞIDAKİ finance.read'e
                bağlı toplu kapıdan KASITLI OLARAK AYRI tutulur. Aksi halde
                finance.read'i olmayan ama contracts.manage'e sahip bir Proje
                Yöneticisi (bkz. rol matrisi) Sözleşme'yi hiç göremezdi. */}
            <Section title="Sözleşme" defaultOpen>
              {canReadContract ? (
                <ContractSection
                  project={project}
                  contract={contract}
                  changeOrders={changeOrders?.change_orders ?? []}
                  locked={locked}
                  canManage={canManageContract}
                  canLifecycle={canContractLifecycle}
                />
              ) : (
                <p className="text-sm text-text-muted">Bu bölümü görüntüleme yetkiniz yok.</p>
              )}
            </Section>

            {/* Bu sekmenin GERİ KALAN TÜM kaynakları AYNI izne (projects.
                finance.read) bağlıdır -- ya hepsi doludur ya da (finance izni
                olmayan bir rol, ör. field) hepsi null'dır; tek bir kontrol
                yeterli. */}
            {summary && plan && collections && expenses && invoices && subcontractors && subPayments && changeOrders ? (
              <>
                <Section title="Ödeme Planı" defaultOpen>
                  <PaymentPlanSection
                    project={project}
                    items={plan.items}
                    plannedTotal={plan.planned_total}
                    currentContractValue={summary.current_contract_value}
                    locked={locked}
                    canManage={canManageFinance}
                  />
                </Section>

                <Section title="Tahsilatlar" defaultOpen>
                  <CollectionsSection
                    project={project}
                    collections={collections.collections}
                    planItems={plan.items}
                    locked={locked}
                    canManage={canManageFinance}
                  />
                </Section>

                <ExpensesSection
                  project={project}
                  expenses={expenses.expenses}
                  changeOrders={changeOrders.change_orders}
                  costCodes={costCodes?.cost_codes ?? []}
                  budgetLines={budgetLines?.budget_lines ?? []}
                  locked={locked}
                  canManage={canManageFinance}
                  canApprove={canApproveExpenses}
                />

                <Section title="Fatura Bilgileri">
                  <InvoicesSection
                    project={project}
                    invoices={invoices.invoices}
                    locked={locked}
                    canManage={canManageFinance}
                  />
                </Section>

                <Section title="Taşeronlar">
                  <SubcontractorsSection
                    project={project}
                    subcontractors={subcontractors.subcontractors}
                    payments={subPayments.payments}
                    locked={locked}
                    canManage={canManageFinance}
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

          <ControlledTabPanel tab="satinalma">
            {purchaseRequests && rfqs && purchaseOrders ? (
              <PurchasingWorkspace
                project={project}
                purchaseRequests={purchaseRequests.purchase_requests}
                rfqs={rfqs.rfqs}
                purchaseOrders={purchaseOrders.purchase_orders}
                suppliers={suppliers?.suppliers ?? []}
                costCodes={costCodes?.cost_codes ?? []}
                wbsNodes={wbsNodes?.wbs_nodes ?? []}
                budgetLines={budgetLines?.budget_lines ?? []}
                locked={locked}
                canManage={canManageProcurement}
                canApprove={canApproveProcurement}
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
                <ScheduleSection
                  project={project}
                  items={schedule.items}
                  members={members?.members}
                  assignees={assignees ?? []}
                  locked={locked}
                />
              </Section>
            )}

            {members && (
              <Section title="Personel / Ekip" defaultOpen>
                <MembersSection
                  project={project}
                  members={members.members}
                  assignees={assignees}
                  canManage={canManageOperations}
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
                  assignees={assignees ?? []}
                  canCreate={canCreateTasks}
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
