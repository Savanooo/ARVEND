import Link from "next/link";
import { cookies } from "next/headers";

import { Badge } from "@/components/ui/Badge";
import { Card } from "@/components/ui/Card";
import { Table, Td, Th, Tr } from "@/components/ui/Table";
import { PageHeader } from "@/components/layout/PageHeader";
import { apiServer } from "@/lib/api";
import { requirePagePermission } from "@/lib/auth";
import { PAGE_PERMISSIONS } from "@/lib/permissions";
import type { AttendanceLog, AttendanceStatus, Employee } from "@/lib/types";

import { AddAttendanceForm } from "./AddAttendanceForm";
import { AttendanceRowActions } from "./AttendanceRowActions";

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

async function fetchData(month: string) {
  const cookieHeader = (await cookies()).toString();
  const [attendanceRes, employeesRes] = await Promise.all([
    apiServer<{ attendance: AttendanceLog[] }>(
      `/api/v1/attendance?month=${month}`,
      cookieHeader
    ),
    apiServer<{ employees: Employee[] }>("/api/v1/employees?filter=aktif", cookieHeader),
  ]);
  return { attendance: attendanceRes.attendance, employees: employeesRes.employees };
}

export default async function MesaiPage({
  searchParams,
}: {
  searchParams: Promise<{ month?: string }>;
}) {
  await requirePagePermission(PAGE_PERMISSIONS.attendance);
  const { month = currentMonth() } = await searchParams;
  const { attendance, employees } = await fetchData(month);

  return (
    <>
      <PageHeader title="Mesai" />
      <div className="flex flex-col gap-4 p-8">
        <AddAttendanceForm employees={employees} />

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
                  <Td>
                    <AttendanceRowActions log={log} />
                  </Td>
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
      </div>
    </>
  );
}
