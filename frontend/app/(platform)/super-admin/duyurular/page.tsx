import { cookies } from "next/headers";

import { PageHeader } from "@/components/layout/PageHeader";
import { apiServer } from "@/lib/api";
import type { Organization } from "@/lib/types";

import { AnnouncementForm } from "./AnnouncementForm";

// Firmaların kullanıcılarına duyuru (POST /platform/announcements). Hedef
// yalnızca aktif/deneme firmaları -- askıdaki/iptal firmalara backend
// zaten göndermez; seçicide de gösterilmez.
export default async function DuyurularPage() {
  const cookieHeader = (await cookies()).toString();
  const { organizations } = await apiServer<{ organizations: Organization[]; total: number }>(
    "/api/v1/platform/organizations?status=&page=1&limit=100",
    cookieHeader
  );
  const reachable = organizations.filter((o) => o.status === "active" || o.status === "trial");

  return (
    <>
      <PageHeader title="Duyurular" />
      <div className="flex flex-col gap-4 p-8">
        <p className="max-w-2xl text-sm text-text-muted">
          Duyuru, seçtiğin firmalardaki her aktif kullanıcının uygulamasında zil bildirimi olarak görünür; bildirim izni
          açık telefonlara ayrıca telefon bildirimi düşer. Gönderilen duyuru geri alınamaz.
        </p>
        <AnnouncementForm organizations={reachable.map((o) => ({ id: o.id, name: o.name }))} />
      </div>
    </>
  );
}
