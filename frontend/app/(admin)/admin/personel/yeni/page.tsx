import { cookies } from "next/headers";

import { PageHeader } from "@/components/layout/PageHeader";
import { apiServer } from "@/lib/api";
import type { User } from "@/lib/types";

import { NewEmployeeForm } from "./NewEmployeeForm";

export default async function YeniPersonelPage() {
  const cookieHeader = (await cookies()).toString();
  const usersResult = await apiServer<{ users: User[]; total: number }>("/api/v1/users", cookieHeader);

  return (
    <>
      <PageHeader title="Yeni Personel" />
      <div className="p-8">
        <NewEmployeeForm users={usersResult.users} />
      </div>
    </>
  );
}
