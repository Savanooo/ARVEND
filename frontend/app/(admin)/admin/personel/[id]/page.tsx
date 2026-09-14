import { cookies } from "next/headers";

import { PageHeader } from "@/components/layout/PageHeader";
import { apiServer } from "@/lib/api";
import type { Employee } from "@/lib/types";

import { EditEmployeeForm } from "./EditEmployeeForm";

export default async function PersonelDetayPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const cookieHeader = (await cookies()).toString();
  const employee = await apiServer<Employee>(`/api/v1/employees/${id}`, cookieHeader);

  return (
    <>
      <PageHeader title={employee.full_name} />
      <div className="flex max-w-md flex-col gap-6 p-8">
        <EditEmployeeForm employee={employee} />
      </div>
    </>
  );
}
