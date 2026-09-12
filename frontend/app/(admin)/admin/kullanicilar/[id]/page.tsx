import { cookies } from "next/headers";

import { Topbar } from "@/components/layout/Topbar";
import { apiServer } from "@/lib/api";
import type { User } from "@/lib/types";

import { EditUserForm } from "./EditUserForm";

export default async function KullaniciDetayPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const cookieHeader = (await cookies()).toString();
  const user = await apiServer<User>(`/api/v1/users/${id}`, cookieHeader);

  return (
    <>
      <Topbar title={user.full_name} />
      <div className="p-8">
        <EditUserForm user={user} />
      </div>
    </>
  );
}
