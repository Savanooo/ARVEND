import Link from "next/link";
import { cookies } from "next/headers";

import { PageHeader } from "@/components/layout/PageHeader";
import { Card } from "@/components/ui/Card";
import { EmptyState } from "@/components/ui/EmptyState";
import { Pagination } from "@/components/ui/Pagination";
import { apiServer } from "@/lib/api";
import type { FeedbackMessage } from "@/lib/types";

import { MarkReadButton } from "./MarkReadButton";

const PAGE_SIZE = 30;

const CATEGORY_LABELS: Record<FeedbackMessage["category"], string> = {
  oneri: "Öneri",
  hata: "Hata",
  sikayet: "Şikâyet",
  diger: "Diğer",
};

// Firmaların kullanıcılarından gelen öneri/hata/şikâyetler (mobil "Öneri
// Gönder"). Firma yöneticileri bunları görmez; yalnızca platform ekibi.
export default async function OnerilerPage({
  searchParams,
}: {
  searchParams: Promise<{ filtre?: string; page?: string }>;
}) {
  const params = await searchParams;
  const onlyUnread = params.filtre !== "tumu";
  const page = Math.max(1, parseInt(params.page ?? "1") || 1);
  const cookieHeader = (await cookies()).toString();
  const { messages, total, unread } = await apiServer<{ messages: FeedbackMessage[]; total: number; unread: number }>(
    `/api/v1/platform/feedback?unread=${onlyUnread ? 1 : 0}&page=${page}&limit=${PAGE_SIZE}`,
    cookieHeader
  );
  const totalPages = Math.max(1, Math.ceil((onlyUnread ? unread : total) / PAGE_SIZE));

  return (
    <>
      <PageHeader title="Öneriler" />
      <div className="flex flex-col gap-4 p-8">
        <div className="flex gap-2 text-sm">
          <Link
            href="/super-admin/oneriler"
            className={`rounded-md px-3 py-1.5 ${onlyUnread ? "bg-gold-soft font-semibold" : "text-text-muted"}`}
          >
            Okunmamış ({unread})
          </Link>
          <Link
            href="/super-admin/oneriler?filtre=tumu"
            className={`rounded-md px-3 py-1.5 ${!onlyUnread ? "bg-gold-soft font-semibold" : "text-text-muted"}`}
          >
            Tümü ({total})
          </Link>
        </div>
        {messages.length === 0 ? (
          <Card>
            <EmptyState
              title={onlyUnread ? "Okunmamış öneri yok" : "Henüz öneri yok"}
              description="Kullanıcılar mobil uygulamada Diğer > Öneri Gönder'den yazabilir."
            />
          </Card>
        ) : (
          <div className="flex flex-col gap-3">
            {messages.map((m) => (
              <Card key={m.id} className={m.read_at ? "opacity-70" : ""}>
                <div className="flex flex-col gap-2 p-4">
                  <div className="flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-text-muted">
                    <span className="rounded bg-surface-hover px-2 py-0.5 font-semibold text-text">
                      {CATEGORY_LABELS[m.category] ?? m.category}
                    </span>
                    <span className="font-medium text-text">{m.organization_name}</span>
                    <span>{m.user_name || "—"}</span>
                    <span>{new Date(m.created_at).toLocaleString("tr-TR")}</span>
                    {m.app_version && <span>sürüm {m.app_version}</span>}
                    <span className="flex-1" />
                    {!m.read_at && <MarkReadButton id={m.id} />}
                  </div>
                  <p className="whitespace-pre-wrap text-sm">{m.body}</p>
                </div>
              </Card>
            ))}
          </div>
        )}
        {totalPages > 1 && (
          <Pagination
            page={page}
            totalPages={totalPages}
            total={onlyUnread ? unread : total}
            itemLabel="öneri"
            hrefForPage={(p) => `/super-admin/oneriler?${onlyUnread ? "" : "filtre=tumu&"}page=${p}`}
          />
        )}
      </div>
    </>
  );
}
