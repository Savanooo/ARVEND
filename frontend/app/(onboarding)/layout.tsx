import { redirect } from "next/navigation";

import { getCurrentUser } from "@/lib/auth";
import { PLATFORM_HOME } from "@/lib/route-policy";

// /sifre-belirle ve /kurulum -- sidebar'sız, tam ekran zorunlu akış
// sayfaları (bkz. (auth) layout'unun merkezi kart deseniyle aynı fikir,
// ama daha geniş bir içerik alanı için). Rol/onboarding koşulunun kendisi
// (ör. "zaten tamamlanmış, buraya gerek yok") her sayfanın kendi
// page.tsx'inde kontrol edilir -- ikisinin "zaten yapıldı" koşulu farklı
// olduğu için burada ortak değildir. Bu akışlar TENANT hesaplarına aittir:
// super_admin'in organizasyonu/onboarding'i yoktur, platforma döner.
export default async function OnboardingLayout({ children }: { children: React.ReactNode }) {
  const user = await getCurrentUser();
  if (!user) redirect("/giris");
  if (user.role === "super_admin") redirect(PLATFORM_HOME);

  return (
    <div className="min-h-screen bg-bg">
      <div className="mx-auto max-w-2xl px-6 py-12">{children}</div>
    </div>
  );
}
