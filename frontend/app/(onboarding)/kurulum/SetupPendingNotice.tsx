"use client";

import { useRouter } from "next/navigation";
import { useState } from "react";

import { Button } from "@/components/ui/Button";
import { Card, CardBody } from "@/components/ui/Card";
import { Logo } from "@/components/layout/Logo";
import { apiClient } from "@/lib/api";

// Firma kurulumu (onboarding) yalnızca Sahip/Yönetici tarafından yapılır
// (backend /onboarding uçları requireAdmin). Kurulum bitmeden giriş yapan
// diğer üyeler buraya düşer; sihirbaz yerine bu bilgi ve çıkış gösterilir.
export function SetupPendingNotice({ organizationName }: { organizationName?: string }) {
  const router = useRouter();
  const [loading, setLoading] = useState(false);

  async function logout() {
    setLoading(true);
    try {
      await apiClient("/api/v1/auth/logout", { method: "POST" });
    } finally {
      router.push("/giris");
      router.refresh();
    }
  }

  return (
    <Card>
      <CardBody className="flex flex-col items-center gap-4 py-10 text-center">
        <Logo size={44} />
        <h1 className="text-base font-semibold">Firma kurulumu henüz tamamlanmadı</h1>
        <p className="max-w-md text-sm text-text-muted">
          {organizationName ? `${organizationName} için ` : ""}firma kurulumu henüz tamamlanmadı; firma sahibinin
          kurulumu bitirmesi gerekiyor. Kurulum tamamlandığında tekrar giriş yaparak devam edebilirsiniz.
        </p>
        <Button variant="secondary" onClick={logout} loading={loading}>
          Çıkış Yap
        </Button>
      </CardBody>
    </Card>
  );
}
