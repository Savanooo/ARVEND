import { redirect } from "next/navigation";

import { getCurrentUser } from "@/lib/auth";

import { SetInitialPasswordForm } from "./SetInitialPasswordForm";

export default async function SifreBelirlePage() {
  const user = await getCurrentUser();
  if (!user) redirect("/giris");
  // Zaten şifresini belirlemiş bir kullanıcı buraya manuel gelirse (ör.
  // geri tuşu) ana sayfasına döner -- Super Admin bu akışa hiç girmez
  // (CLI ile oluşturulur, must_change_password her zaman false).
  if (!user.must_change_password) {
    redirect(user.role === "admin" ? "/admin" : user.role === "super_admin" ? "/super-admin" : "/panel");
  }

  return <SetInitialPasswordForm />;
}
