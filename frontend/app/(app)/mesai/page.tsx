import Link from "next/link";
import { cookies } from "next/headers";

import { Badge } from "@/components/ui/Badge";
import { Card } from "@/components/ui/Card";
import { StatCard } from "@/components/ui/StatCard";
import { buttonClass } from "@/components/ui/styles";
import { Table, Td, Th, Tr } from "@/components/ui/Table";
import { PageHeader } from "@/components/layout/PageHeader";
import { apiServer } from "@/lib/api";
import { requirePagePermission } from "@/lib/auth";
import { formatTL } from "@/lib/format";
import { hasPermission, PAGE_PERMISSIONS } from "@/lib/permissions";
import type {
  AttendanceLog,
  AttendanceStatus,
  Employee,
  PaymentType,
  PayrollResponse,
  PayrollSummaryRow,
} from "@/lib/types";

import { AddAttendanceForm } from "./AddAttendanceForm";
import { AddPaymentForm } from "./AddPaymentForm";
import { AttendanceRowActions } from "./AttendanceRowActions";
import { PaymentRowActions } from "./PaymentRowActions";

const PAYMENT_TONE: Record<PaymentType, "success" | "gold" | "danger" | "muted"> = {
  maaş: "success",
  avans: "gold",
  mesai: "gold",
  prim: "success",
  diğer: "muted",
};

const num = new Intl.NumberFormat("tr-TR", { maximumFractionDigits: 2 });

const STATUS_TONE: Record<AttendanceStatus, "success" | "gold" | "danger" | "muted"> = {
  geldi: "success",
  "yarım gün": "gold",
  gelmedi: "danger",
  izinli: "muted",
};

function wageLabel(r: PayrollSummaryRow): string {
  if (r.wage_basis === "günlük" && r.daily_wage != null) return `${formatTL(r.daily_wage)} / gün`;
  if (r.wage_basis === "aylık" && r.salary != null) return `${formatTL(r.salary)} / ay`;
  return "Tanımsız";
}

function PayStatus({ r }: { r: PayrollSummaryRow }) {
  if (r.wage_basis === "") return <Badge tone="muted">Ücret tanımsız</Badge>;
  if (r.remaining <= 0) return <Badge tone="success">Ödendi</Badge>;
  return <Badge tone="gold">Bekliyor</Badge>;
}

function shiftMonth(month: string, delta: number): string {
  const [y, m] = month.split("-").map(Number);
  const d = new Date(y, m - 1 + delta, 1);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}`;
}

function currentMonth(): string {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}`;
}

// Personel listesi YALNIZCA "Mesai Ekle" formunun personel seçicisi içindir
// (tablo personel adını zaten mesai kaydının kendisinden alır) -- bu yüzden
// yalnızca form gösterilecekse çekilir. Eskiden koşulsuz çekiliyordu ve
// employees.read'i olmayan bir rol (ör. Saha: yalnızca puantajı görür)
// sayfayı açınca backend 403'ü tüm sayfayı çökertiyordu.
async function fetchData(month: string, withEmployees: boolean, withPayroll: boolean) {
  const cookieHeader = (await cookies()).toString();
  const [attendanceRes, employeesRes, payroll] = await Promise.all([
    apiServer<{ attendance: AttendanceLog[] }>(`/api/v1/attendance?month=${month}`, cookieHeader),
    withEmployees
      ? apiServer<{ employees: Employee[] }>("/api/v1/employees?filter=aktif", cookieHeader)
      : Promise.resolve({ employees: [] as Employee[] }),
    // Maaş bölümü payroll.read ister (attendance.read'den AYRI): puantaj
    // girebilen herkes maaşları görmemeli. İzin yoksa hiç çağrılmaz -- yoksa
    // backend'in 403'ü bütün sayfayı çökertirdi (personel listesindeki
    // dersle aynı).
    withPayroll
      ? apiServer<PayrollResponse>(`/api/v1/payroll?month=${month}`, cookieHeader)
      : Promise.resolve(null),
  ]);
  return {
    attendance: attendanceRes.attendance,
    employees: employeesRes.employees,
    payroll,
  };
}

export default async function MesaiPage({
  searchParams,
}: {
  searchParams: Promise<{ month?: string; ode?: string }>;
}) {
  const user = await requirePagePermission(PAGE_PERMISSIONS.attendance);
  const canManage = hasPermission(user.permissions, "attendance.manage");
  const canAdd = canManage && hasPermission(user.permissions, PAGE_PERMISSIONS.employees);
  const canSeePayroll = hasPermission(user.permissions, "payroll.read");
  const canPay = canSeePayroll && hasPermission(user.permissions, "payroll.manage");
  const { month = currentMonth(), ode } = await searchParams;
  const { attendance, employees, payroll } = await fetchData(month, canAdd, canSeePayroll);
  const summary = payroll?.summary ?? [];
  // Ödeme formunun personel listesi özetten gelir (aktif personel her zaman
  // özette) -- ödeme girmek için ayrıca employees.read gerekmesin. Pasif
  // personel yalnızca o ay verisi varsa özette olur ve listede KALIR: işten
  // ayrılanın son maaşı da ödenebilmeli.
  const payable = summary.map((r) => ({
    id: r.employee_id,
    full_name: r.is_active ? r.full_name : `${r.full_name} (pasif)`,
    remaining: r.wage_basis === "" ? null : r.remaining,
  }));
  const calculated = summary.filter((r) => r.wage_basis !== "");
  const toPay = calculated.reduce((sum, r) => sum + Math.max(0, r.remaining), 0);
  const waiting = calculated.filter((r) => r.remaining > 0).length;
  const earnedTotal = calculated.reduce((sum, r) => sum + r.earned, 0);
  const paidThisMonth = summary.reduce((sum, r) => sum + r.paid_total, 0);
  const paying = ode ? summary.find((r) => r.employee_id === ode) : undefined;

  return (
    <>
      <PageHeader title="Mesai & Maaş" />
      <div className="flex flex-col gap-4 p-8">
        <div className="flex items-center justify-between">
          <div className="flex items-center gap-3 text-sm">
            <Link
              href={`/mesai?month=${shiftMonth(month, -1)}`}
              className="text-gold hover:underline"
            >
              ← Önceki Ay
            </Link>
            <span className="font-semibold">{month}</span>
            <Link
              href={`/mesai?month=${shiftMonth(month, 1)}`}
              className="text-gold hover:underline"
            >
              Sonraki Ay →
            </Link>
          </div>
        </div>

        {payroll && (
          <section className="flex flex-col gap-3">
            <h2 className="text-lg font-semibold">Maaş ve Ödemeler</h2>

            <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
              <StatCard
                label="Ödenecek"
                value={formatTL(toPay)}
                tone={toPay > 0 ? "danger" : null}
                sub={[waiting > 0 ? `${waiting} kişi bekliyor` : "Bekleyen yok"]}
              />
              <StatCard
                label="Hesaplanan"
                value={formatTL(earnedTotal)}
                sub={[`${calculated.length} personel`]}
              />
              <StatCard
                label="Ödenen"
                value={formatTL(paidThisMonth)}
                sub={[`${payroll.payments.length} ödeme`]}
              />
              <StatCard
                label="Durum"
                value={`${calculated.length - waiting}/${calculated.length}`}
                sub={["ödendi"]}
              />
            </div>

            {canPay && (
              <AddPaymentForm
                // "Öde" ile gelince form o personel ve kalanıyla YENİDEN kurulur.
                key={`${month}:${ode ?? ""}`}
                employees={payable}
                month={month}
                initialEmployeeId={paying?.employee_id}
                initialAmount={paying && paying.remaining > 0 ? paying.remaining : undefined}
              />
            )}

            <Card>
              <Table>
                <thead>
                  <tr>
                    <Th>Personel</Th>
                    <Th>Ücret</Th>
                    <Th className="text-right">Çalışılan Gün</Th>
                    <Th className="text-right">Hesaplanan</Th>
                    <Th className="text-right">Ödenen</Th>
                    <Th className="text-right">Kalan</Th>
                    <Th>Durum</Th>
                    <Th />
                  </tr>
                </thead>
                <tbody>
                  {summary.map((r) => (
                    <Tr key={r.employee_id}>
                      <Td className="font-medium">
                        {r.full_name}
                        {!r.is_active && (
                          <span className="ml-2 text-xs text-text-muted">(pasif)</span>
                        )}
                        {r.position && (
                          <div className="text-xs font-normal text-text-muted">{r.position}</div>
                        )}
                      </Td>
                      <Td className="text-text-muted">{wageLabel(r)}</Td>
                      <Td className="text-right">
                        {num.format(r.worked_days)}
                        {r.work_hours > 0 && (
                          <div className="text-xs text-text-muted">
                            {num.format(r.work_hours)} sa
                          </div>
                        )}
                      </Td>
                      <Td className="text-right">
                        {r.wage_basis === "" ? "—" : formatTL(r.earned)}
                      </Td>
                      <Td className="text-right">
                        {r.paid_total > 0 ? formatTL(r.paid_total) : "—"}
                        {r.payment_count > 1 && (
                          <div className="text-xs text-text-muted">{r.payment_count} ödeme</div>
                        )}
                        {r.extra_paid > 0 && (
                          <div className="text-xs text-text-muted">
                            {formatTL(r.extra_paid)} prim/diğer
                          </div>
                        )}
                      </Td>
                      <Td className="text-right font-semibold">
                        {r.wage_basis === ""
                          ? "—"
                          : r.remaining > 0
                            ? formatTL(r.remaining)
                            : formatTL(0)}
                        {r.remaining < 0 && (
                          <div className="text-xs font-normal text-text-muted">
                            {formatTL(-r.remaining)} fazla, sonraki aya devreder
                          </div>
                        )}
                        {r.carry_over > 0 && (
                          <div className="text-xs font-normal text-text-muted">
                            {formatTL(r.carry_over)} devir düşüldü
                          </div>
                        )}
                      </Td>
                      <Td>
                        <PayStatus r={r} />
                      </Td>
                      <Td className="text-right">
                        {canPay && r.wage_basis !== "" && r.remaining > 0 && (
                          <Link
                            href={`/mesai?month=${month}&ode=${r.employee_id}#odeme`}
                            scroll={false}
                            className={buttonClass("primary", "sm")}
                          >
                            Öde
                          </Link>
                        )}
                      </Td>
                    </Tr>
                  ))}
                  {summary.length === 0 && (
                    <tr>
                      <Td colSpan={8} className="text-center text-text-muted">
                        Bu ay için personel yok.
                      </Td>
                    </tr>
                  )}
                </tbody>
              </Table>
            </Card>
            <p className="text-xs text-text-muted">
              Hesaplanan: yevmiye tanımlıysa yevmiye × çalışılan gün (geldi = 1, yarım gün = 0,5),
              değilse aylık maaşın tamamı. Kalan = hesaplanan − bu aya ait maaş, avans ve mesai
              ödemeleri − önceki aydan devir. Prim ve diğer ek ödemedir, kalandan düşmez. Fazla
              ödeme bir sonraki aya devreder.
            </p>

            <Card>
              <Table>
                <thead>
                  <tr>
                    <Th>Ödeme Tarihi</Th>
                    <Th>Personel</Th>
                    <Th>Tür</Th>
                    <Th className="text-right">Tutar</Th>
                    <Th>Açıklama</Th>
                    <Th />
                  </tr>
                </thead>
                <tbody>
                  {payroll.payments.map((p) => (
                    <Tr key={p.id}>
                      <Td className="text-text-muted">{p.paid_date}</Td>
                      <Td className="font-medium">{p.employee_name}</Td>
                      <Td>
                        <Badge tone={PAYMENT_TONE[p.payment_type]}>{p.payment_type}</Badge>
                      </Td>
                      <Td className="text-right font-semibold">{formatTL(p.amount)}</Td>
                      <Td className="text-text-muted">{p.description || "—"}</Td>
                      <Td>{canPay && <PaymentRowActions payment={p} />}</Td>
                    </Tr>
                  ))}
                  {payroll.payments.length === 0 && (
                    <tr>
                      <Td colSpan={6} className="text-center text-text-muted">
                        Bu aya ait ödeme yok.
                      </Td>
                    </tr>
                  )}
                </tbody>
              </Table>
            </Card>
          </section>
        )}

        <section className="flex flex-col gap-3">
          <h2 className="text-lg font-semibold">Puantaj</h2>
          {canAdd && <AddAttendanceForm employees={employees} />}
          <Card>
            <Table>
              <thead>
                <tr>
                  <Th>Tarih</Th>
                  <Th>Personel</Th>
                  <Th>Giriş</Th>
                  <Th>Çıkış</Th>
                  <Th className="text-right">Saat</Th>
                  <Th>Durum</Th>
                  <Th>Not</Th>
                  <Th />
                </tr>
              </thead>
              <tbody>
                {attendance.map((log) => (
                  <Tr key={log.id}>
                    <Td className="text-text-muted">{log.date}</Td>
                    <Td className="font-medium">{log.employee_name}</Td>
                    <Td className="text-text-muted">{log.check_in || "—"}</Td>
                    <Td className="text-text-muted">{log.check_out || "—"}</Td>
                    <Td className="text-right">{log.work_hours}</Td>
                    <Td>
                      <Badge tone={STATUS_TONE[log.status]}>{log.status}</Badge>
                    </Td>
                    <Td className="text-text-muted">{log.note || "—"}</Td>
                    <Td>{canManage && <AttendanceRowActions log={log} />}</Td>
                  </Tr>
                ))}
                {attendance.length === 0 && (
                  <tr>
                    <Td colSpan={8} className="text-center text-text-muted">
                      Bu ay için mesai kaydı yok.
                    </Td>
                  </tr>
                )}
              </tbody>
            </Table>
          </Card>
        </section>
      </div>
    </>
  );
}
