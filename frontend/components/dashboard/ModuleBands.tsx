import { compactSpanClass, spanClass, type DashboardLayout, type ModuleKey } from "@/lib/dashboard";

import type { CardContext } from "./context";
import { AttendanceCard } from "./modules/AttendanceCard";
import { CalculationsCard } from "./modules/CalculationsCard";
import { ChangeOrdersCard } from "./modules/ChangeOrdersCard";
import { ContractsCard } from "./modules/ContractsCard";
import { CostCodesCard } from "./modules/CostCodesCard";
import { CostControlCard } from "./modules/CostControlCard";
import { CustomersCard } from "./modules/CustomersCard";
import { EmployeesCard } from "./modules/EmployeesCard";
import { FinanceCard } from "./modules/FinanceCard";
import { OffersCard } from "./modules/OffersCard";
import { OperationsCard } from "./modules/OperationsCard";
import { ProcurementCard } from "./modules/ProcurementCard";
import { ProductsCard } from "./modules/ProductsCard";
import { ProjectsCard } from "./modules/ProjectsCard";
import { SubcontractsCard } from "./modules/SubcontractsCard";
import { SuppliersCard } from "./modules/SuppliersCard";
import { TasksCard } from "./modules/TasksCard";
import { UsersCard } from "./modules/UsersCard";
import { ProjectModulesPlaceholder } from "./ProjectModulesPlaceholder";

const CARDS: Record<ModuleKey, (props: { ctx: CardContext }) => React.ReactNode> = {
  finance: FinanceCard,
  offers: OffersCard,
  change_orders: ChangeOrdersCard,
  projects: ProjectsCard,
  tasks: TasksCard,
  operations: OperationsCard,
  contracts: ContractsCard,
  attendance: AttendanceCard,
  procurement: ProcurementCard,
  subcontracts: SubcontractsCard,
  cost_control: CostControlCard,
  customers: CustomersCard,
  employees: EmployeesCard,
  products: ProductsCard,
  users: UsersCard,
  calculations: CalculationsCard,
  suppliers: SuppliersCard,
  cost_codes: CostCodesCard,
};

function BandHeading({ id, title }: { id: string; title: string }) {
  return (
    <div className="flex items-center gap-3">
      <h2 id={id} className="text-xs font-semibold uppercase tracking-widest text-text-muted">
        {title}
      </h2>
      <div aria-hidden className="h-px flex-1 bg-border" />
    </div>
  );
}

// Modül özetleri: sabit bantlar (Nakit & Satış, Proje & Saha, Tedarik &
// Maliyet, Firma kayıtları) ya da yoğun modda tek "Bölümler" ızgarası.
// Kartların yeri veriye göre ASLA değişmez; aciliyet yalnızca Dikkat'te ve
// kart alt satırlarında. Son satırda boşluk kalmasın diye spanClass.
export function ModuleBands({ layout, ctx }: { layout: DashboardLayout; ctx: CardContext }) {
  return (
    <>
      {layout.bands.map((band) => {
        const headingId = `bant-${band.key}`;
        const standard = band.standard;
        return (
          <section key={band.key} aria-labelledby={headingId} className="flex flex-col gap-3">
            <BandHeading id={headingId} title={band.title} />
            {(band.placeholder || standard.length > 0) && (
              <div className="grid grid-cols-12 gap-3 @4xl:gap-4">
                {band.placeholder && (
                  <div className="col-span-12 min-w-0">
                    <ProjectModulesPlaceholder />
                  </div>
                )}
                {standard.map((key, i) => {
                  const Card = CARDS[key];
                  return (
                    <div key={key} className={`min-w-0 ${spanClass(i, standard.length)}`}>
                      <Card ctx={ctx} />
                    </div>
                  );
                })}
              </div>
            )}
            {band.compact.length > 0 && (
              <div className="grid grid-cols-12 gap-3 @4xl:gap-4">
                {band.compact.map((key, i) => {
                  const Card = CARDS[key];
                  return (
                    <div key={key} className={`min-w-0 ${compactSpanClass(i, band.compact.length)}`}>
                      <Card ctx={ctx} />
                    </div>
                  );
                })}
              </div>
            )}
          </section>
        );
      })}
    </>
  );
}
