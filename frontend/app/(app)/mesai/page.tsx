import Link from "next/link";
import { cookies } from "next/headers";

import { Badge } from "@/components/ui/Badge";
import { Card } from "@/components/ui/Card";
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
  searchParams: Promise<{ month?: string }>;
}) {
  const user = await requirePagePermission(PAGE_PERMISSIONS.attendance);
  const canManage = hasPermission(user.permissions, "attendance.manage");
  const canAdd = canManage && hasPermission(user.permissions, PAGE_PERMISSIONS.employees);
  const canSeePayroll = hasPermission(user.permissions, "payroll.read");
  const canPay = canSeePayroll && hasPermission(user.permissions, "payroll.manage");
  const { month = currentMonth() } = await searchParams;
  const { attendance, employees, payroll } = await fetchData(month, canAdd, canSeePayroll);
  // Ödeme formunun personel listesi özetten gelir (aktif personel her zaman
  // özette) -- ödeme girmek için ayrıca employees.read gerekmesin.
  const payable = (payroll?.summary ?? [])
    .filter((r) => r.is_active)
    .map((r) => ({ id: r.employee_id, full_name: r.full_name }));
  const paidThisMonth = (payroll?.summary ?? []).reduce((sum, r) => sum + r.paid_total, 0);

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
            <div className="flex items-baseline justify-between">
              <h2 className="text-lg font-semibold">Maaş ve Ödemeler</h2>
              <span className="text-sm text-text-muted">
                Bu ay ödenen:{" "}
                <span className="font-semibold text-text">{formatTL(paidThisMonth)}</span>
              </span>
            </div>

            {canPay && <AddPaymentForm employees={payable} month={month} />}

            <Card>
              <Table>
                <thead>
                  <tr>
                    <Th>Personel</Th>
                    <Th>Görev</Th>
                    <Th className="text-right">Aylık Maaş</Th>
                    <Th className="text-right">Yevmiye</Th>
                    <Th className="text-right">Çalışılan Gün</Th>
                    <Th className="text-right">Saat</Th>
                    <Th className="text-right">Bu Ay Ödenen</Th>
                  </tr>
                </thead>
                <tbody>
                  {payroll.summary.map((r) => (
                    <Tr key={r.employee_id}>
                      <Td className="font-medium">
                        {r.full_name}
                        {!r.is_active && (
                          <span className="ml-2 text-xs text-text-muted">(pasif)</span>
                        )}
                      </Td>
                      <Td className="text-text-muted">{r.position || "—"}</Td>
                      <Td className="text-right">{r.salary != null ? formatTL(r.salary) : "—"}</Td>
                      <Td className="text-right">
                        {r.daily_wage != null ? formatTL(r.daily_wage) : "—"}
                      </Td>
                      <Td className="text-right">{num.format(r.worked_days)}</Td>
                      <Td className="text-right">{num.format(r.work_hours)}</Td>
                      <Td className="text-right font-semibold">
                        {r.paid_total > 0 ? formatTL(r.paid_total) : "—"}
                        {r.payment_count > 1 && (
                          <span className="ml-1 text-xs font-normal text-text-muted">
                            ({r.payment_count} ödeme)
                          </span>
                        )}
                      </Td>
                    </Tr>
                  ))}
                  {payroll.summary.length === 0 && (
                    <tr>
                      <Td colSpan={7} className="text-center text-text-muted">
                        Bu ay için personel yok.
                      </Td>
                    </tr>
                  )}
                </tbody>
              </Table>
            </Card>
            <p className="text-xs text-text-muted">
              Çalışılan gün puantajdan hesaplanır: geldi = 1, yarım gün = 0,5.
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
