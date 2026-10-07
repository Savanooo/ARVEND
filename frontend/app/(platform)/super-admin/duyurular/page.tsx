import { cookies } from "next/headers";

import { PageHeader } from "@/components/layout/PageHeader";
import { apiServer } from "@/lib/api";
import type { Organization } from "@/lib/types";

import { AnnouncementForm } from "./AnnouncementForm";

// Liste ucu sayfa başına en çok 100 firma döner (platform_service.go);
// seçicide HEPSİ olmalı, yoksa 101. firmadan sonrakiler hiç seçilemezdi.
const PAGE_SIZE = 100;
const MAX_PAGES = 50;

async function fetchAllOrganizations(cookieHeader: string): Promise<Organization[]> {
  const all: Organization[] = [];
  for (let page = 1; page <= MAX_PAGES; page++) {
    const { organizations, total } = await apiServer<{ organizations: Organization[]; total: number }>(
      `/api/v1/platform/organizations?status=&page=${page}&limit=${PAGE_SIZE}`,
      cookieHeader
    );
    all.push(...organizations);
    if (organizations.length < PAGE_SIZE || all.length >= total) break;
  }
  return all;
}

// Firmaların kullanıcılarına duyuru (POST /platform/announcements). Hedef
// yalnızca aktif/deneme firmaları -- askıdaki/iptal firmalara backend
// zaten göndermez; seçicide de gösterilmez.
export default async function DuyurularPage() {
  const cookieHeader = (await cookies()).toString();
  const organizations = await fetchAllOrganizations(cookieHeader);
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
