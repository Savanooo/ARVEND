import { redirect } from "next/navigation";

import { getCurrentUser } from "@/lib/auth";
import { loginDestination, safeNextPath } from "@/lib/route-policy";
import type { User } from "@/lib/types";

import { LoginForm } from "./LoginForm";

// Oturumu zaten geçerli olan (backend /auth/me ile DOĞRULANMIŞ -- proxy'deki
// imzasız JWT'ye bakılmaz, yönlendirme döngüsü olmasın) kullanıcı formu
// görmez, next'e ya da ana sayfasına döner. Bu, başka bir sekmenin oturumu
// yenilediği yarışta /giris'e düşen isteği de sessizce geri gönderir. Oturum
// açık değilse (ya da backend'e ulaşılamıyorsa) form gösterilir.
export default async function GirisPage({
  searchParams,
}: {
  searchParams: Promise<{ next?: string | string[] }>;
}) {
  const next = safeNextPath((await searchParams).next);
  let user: User | null = null;
  try {
    user = await getCurrentUser();
  } catch {
    user = null;
  }
  if (user) redirect(loginDestination(user, next));

  return <LoginForm next={next} />;
}
