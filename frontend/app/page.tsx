import { redirect } from "next/navigation";

import { getCurrentUser } from "@/lib/auth";

export default async function RootPage() {
  const user = await getCurrentUser();
  if (!user) redirect("/giris");
  redirect(user.role === "admin" ? "/admin" : "/panel");
}
