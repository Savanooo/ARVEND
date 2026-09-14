import { cookies } from "next/headers";

import { PageHeader } from "@/components/layout/PageHeader";
import { apiServer } from "@/lib/api";
import type { Customer } from "@/lib/types";

import { EditCustomerForm } from "./EditCustomerForm";

export default async function MusteriDetayPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const cookieHeader = (await cookies()).toString();
  const customer = await apiServer<Customer>(`/api/v1/customers/${id}`, cookieHeader);

  return (
    <>
      <PageHeader title={customer.name} />
      <div className="flex max-w-md flex-col gap-6 p-8">
        <EditCustomerForm customer={customer} />
      </div>
    </>
  );
}
