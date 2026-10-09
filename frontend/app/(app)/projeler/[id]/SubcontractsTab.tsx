import Link from "next/link";
import { cookies } from "next/headers";

import { Badge } from "@/components/ui/Badge";
import { EmptyState } from "@/components/ui/EmptyState";
import { Table, Td, Th, Tr } from "@/components/ui/Table";
import { buttonClass } from "@/components/ui/styles";
import { apiServer, ApiError } from "@/lib/api";
import { formatDateTR, formatMoney } from "@/lib/format";
import {
  statusMetaFor,
  subcontractHref,
  SUBCONTRACT_STATUS,
  type Subcontract,
  type SubcontractPerms,
} from "@/lib/subcontracts";
import type { Project } from "@/lib/types";

// Sprint 5 — proje detayındaki "Taşeronlar" sekmesi: taşeron SÖZLEŞMELERİ
// (`/subcontracts`, SOV + hakediş + değişiklik emri + ödeme). Mobilde
// Operasyon > Taşeronlar. Finans sekmesindeki "Taşeron Ödemeleri" (legacy
// `/subcontractors` defteri) bundan AYRIDIR.
//
// Kendi verisini kendisi çeker (Server Component): proje sayfasının toplu
// Promise.allSettled'ına bir kaynak daha eklemek yerine -- izni yoksa hiç
// istek atılmaz. Liste yalnızca özet taşır; SOV/hakediş/ödeme detay
// sayfasındadır (subcontractHref).

function formatDay(d: string | null | undefined) {
  return d ? formatDateTR(d) : "—";
}

export async function SubcontractsTab({
  project,
  perms,
  locked,
}: {
  project: Project;
  perms: SubcontractPerms;
  locked: boolean;
}) {
  if (!perms.canRead) {
    return <p className="text-sm text-text-muted">Bu bölümü görüntüleme yetkiniz yok.</p>;
  }

  const cookieHeader = (await cookies()).toString();
  const list = await apiServer<{ subcontracts: Subcontract[] }>(
    `/api/v1/projects/${project.id}/subcontracts`,
    cookieHeader
  ).catch((err: unknown) => (err instanceof ApiError && err.status === 403 ? ("forbidden" as const) : null));

  if (list === "forbidden") {
    return <p className="text-sm text-text-muted">Bu bölümü görüntüleme yetkiniz yok.</p>;
  }
  if (!list) {
    return <p className="text-sm text-text-muted">Taşeron sözleşmeleri yüklenemedi.</p>;
  }

  const subcontracts = list.subcontracts;
  const canCreate = perms.canManage && !locked;
  const newButton = canCreate ? (
    <Link href={`/projeler/${project.id}/taseronlar/yeni`} className={buttonClass("primary")}>
      + Yeni Taşeron Sözleşmesi
    </Link>
  ) : null;

  // Aktif + tamamlanmış sözleşmelerin asıl tutarı (taahhüt edilen iş). Güncel
  // değer (onaylı değişikliklerle) sözleşme detayındadır -- liste ucu onu
  // taşımaz, burada yeniden hesaplanmaz.
  const counts = { draft: 0, active: 0, closed: 0 };
  let committedOriginal = 0;
  for (const sc of subcontracts) {
    if (sc.status === "draft") counts.draft += 1;
    else if (sc.status === "active") counts.active += 1;
    else counts.closed += 1;
    if (sc.status === "active" || sc.status === "completed") committedOriginal += sc.original_amount;
  }

  return (
    <div className="flex flex-col gap-4">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <p className="text-xs text-text-muted">
          Sözleşme → Kalemler (SOV) → Aktifleştir → Değişiklik Emri / Hakediş → Ödeme
        </p>
        {newButton}
      </div>

      {locked && (
        <p className="rounded-md border border-border bg-surface px-3 py-2 text-xs text-text-muted">
          Proje tamamlandı ya da iptal edildi; taşeron işlemleri kilitli. Kayıtlar yalnızca görüntülenebilir.
        </p>
      )}

      {subcontracts.length === 0 ? (
        <div className="rounded-lg border border-border bg-surface">
          <EmptyState
            title="Henüz taşeron sözleşmesi yok"
            description="Sözleşmeyi kalemleriyle (SOV) oluşturup aktifleştirdiğinizde hakediş, değişiklik emri ve ödeme girilebilir."
          />
        </div>
      ) : (
        <>
          <div className="grid grid-cols-2 gap-4 rounded-lg border border-border bg-surface p-4 text-sm md:grid-cols-4">
            <Stat label="Aktif" value={String(counts.active)} />
            <Stat label="Taslak" value={String(counts.draft)} />
            <Stat label="Kapanan" value={String(counts.closed)} />
            <Stat
              label="Aktif + Tamamlanan (asıl tutar)"
              value={<span className="font-medium">{formatMoney(committedOriginal, project.currency)}</span>}
            />
          </div>

          <div className="rounded-lg border border-border bg-surface">
            <Table>
              <thead>
                <tr>
                  <Th>No</Th>
                  <Th>Taşeron</Th>
                  <Th>Başlık</Th>
                  <Th>Durum</Th>
                  <Th className="text-right">Sözleşme Tutarı</Th>
                  <Th>Başlangıç → Bitiş</Th>
                </tr>
              </thead>
              <tbody>
                {subcontracts.map((sc) => {
                  const meta = statusMetaFor(SUBCONTRACT_STATUS, sc.status);
                  return (
                    <Tr key={sc.id}>
                      <Td className="font-medium">
                        <Link href={subcontractHref(project.id, sc.id)} className="hover:text-gold hover:underline">
                          {sc.subcontract_no}
                        </Link>
                      </Td>
                      <Td>{sc.supplier_name || sc.supplier_code || "—"}</Td>
                      <Td className="text-text-muted">{sc.title || "—"}</Td>
                      <Td>
                        <Badge tone={meta.tone}>{meta.label}</Badge>
                      </Td>
                      <Td className="text-right">{formatMoney(sc.original_amount, sc.currency)}</Td>
                      <Td className="whitespace-nowrap text-text-muted">
                        {formatDay(sc.start_date)} → {formatDay(sc.planned_completion_date)}
                      </Td>
                    </Tr>
                  );
                })}
              </tbody>
            </Table>
          </div>
        </>
      )}

      <p className="text-xs text-text-muted">
        Basit taşeron kaydı ve doğrudan ödemeleri (eski defter) Finans sekmesindeki &quot;Taşeron Ödemeleri&quot;
        bölümündedir; bu sözleşmelerle bağlantılı değildir.
      </p>
    </div>
  );
}

function Stat({ label, value }: { label: string; value: React.ReactNode }) {
  return (
    <div className="flex flex-col gap-0.5">
      <span className="text-xs uppercase tracking-widest text-text-muted">{label}</span>
      <span>{value}</span>
    </div>
  );
}
