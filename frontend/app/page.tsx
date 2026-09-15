import { redirect } from "next/navigation";

import { nextDestination } from "@/lib/auth-guards";
import { getCurrentUser } from "@/lib/auth";

export default async function RootPage() {
  const user = await getCurrentUser();
  if (!user) redirect("/giris");
  redirect(nextDestination(user));
}
