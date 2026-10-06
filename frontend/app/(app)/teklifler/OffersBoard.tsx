"use client";

import { FileText } from "lucide-react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { FormEvent, useState } from "react";

import { Button } from "@/components/ui/Button";
import { Card } from "@/components/ui/Card";
import { useConfirmDialog } from "@/components/ui/ConfirmDialog";
import { DateInput } from "@/components/ui/DateInput";
import { EmptyState } from "@/components/ui/EmptyState";
import { Pagination } from "@/components/ui/Pagination";
import { SearchInput } from "@/components/ui/SearchInput";
import { StatusBadge } from "@/components/ui/StatusBadge";
import { Table, Td, Th, Tr } from "@/components/ui/Table";
import { Tabs } from "@/components/ui/Tabs";
import { formatTL } from "@/lib/format";
import { OFFER_STATUS } from "@/lib/status";
import type { Offer, OfferStatus } from "@/lib/types";

import { TeklifRowActions } from "./TeklifRowActions";

const STATUS_FILTERS: { key: "" | OfferStatus; label: string }[] = [
  { key: "", label: "Tümü" },
  { key: "taslak", label: "Taslak" },
  { key: "gönderildi", label: "Gönderildi" },
  { key: "kabul edildi", label: "Kabul Edildi" },
  { key: "reddedildi", label: "Reddedildi" },
];

// URL'deki liste parametreleri -- sayfa (server component) bunlarla
// backend'i sorgular, bu bileşen yalnızca URL'yi değiştirir.
export interface OfferListParams {
  filter: "aktif" | "pasif";
  status: string;
  q: string;
  from: string;
  to: string;
}

function listHref(params: OfferListParams, page = 1) {
  const query = new URLSearchParams({ filter: params.filter });
  if (params.status) query.set("status", params.status);
  if (params.q) query.set("q", params.q);
  if (params.from) query.set("from", params.from);
  if (params.to) query.set("to", params.to);
  if (page > 1) query.set("page", String(page));
  return `/teklifler?${query.toString()}`;
}

// Durum sekmesi, arama ve tarih filtresi backend'de uygulanır (bkz.
// page.tsx); sayaçlar backend'in status_counts'udur ve aynı arama/tarih
// filtresi kapsamında TÜM teklifleri sayar, yalnızca bu sayfadakileri değil.
export function OffersBoard({
  offers,
  total,
  statusCounts,
  params,
  page,
  totalPages,
}: {
  offers: Offer[];
  total: number;
  statusCounts: Record<OfferStatus, number>;
  params: OfferListParams;
  page: number;
  totalPages: number;
}) {
  const router = useRouter();
  const { confirm, dialog } = useConfirmDialog();
  const [form, setForm] = useState({ q: params.q, from: params.from, to: params.to });

  const allCount = Object.values(statusCounts ?? {}).reduce((sum, n) => sum + n, 0);
  const hasFilters = !!(params.status || params.q || params.from || params.to);

  function handleSubmit(e: FormEvent) {
    e.preventDefault();
    router.push(listHref({ ...params, q: form.q.trim(), from: form.from, to: form.to }));
  }

  function clearFilters() {
    setForm({ q: "", from: "", to: "" });
    router.push(listHref({ filter: params.filter, status: "", q: "", from: "", to: "" }));
  }

  return (
    <div className="flex flex-col gap-4">
      <Tabs
        items={STATUS_FILTERS.map((f) => ({
          key: f.key || "all",
          label: `${f.label} (${f.key ? (statusCounts?.[f.key] ?? 0) : allCount})`,
          active: params.status === f.key,
          href: listHref({ ...params, status: f.key }),
        }))}
      />

      <form onSubmit={handleSubmit} className="flex flex-wrap items-center gap-3">
        <div className="w-full max-w-xs">
          <SearchInput
            placeholder="Teklif no veya müşteri ara"
            value={form.q}
            onChange={(e) => setForm({ ...form, q: e.target.value })}
            aria-label="Teklif no veya müşteri ara"
          />
        </div>
        <div className="flex items-center gap-2">
          <DateInput
            value={form.from}
            onChange={(e) => setForm({ ...form, from: e.target.value })}
            aria-label="Başlangıç tarihi"
          />
          <span className="text-xs text-text-muted">—</span>
          <DateInput
            value={form.to}
            onChange={(e) => setForm({ ...form, to: e.target.value })}
            aria-label="Bitiş tarihi"
          />
        </div>
        <Button type="submit" variant="secondary">
          Filtrele
        </Button>
        {hasFilters && (
          <Button type="button" variant="ghost" onClick={clearFilters}>
            Temizle
          </Button>
        )}
      </form>

      <Card>
        <Table>
          <thead>
            <tr>
              <Th>Teklif No</Th>
              <Th>Müşteri</Th>
              <Th>Tarih</Th>
              <Th>Durum</Th>
              <Th className="text-right">Tutar</Th>
              <Th className="w-10" />
            </tr>
          </thead>
          <tbody>
            {offers.map((o) => (
              <Tr key={o.id}>
                <Td>
                  <Link href={`/teklifler/${o.id}`} className="font-medium hover:text-gold hover:underline">
                    {o.offer_no}
                  </Link>
                </Td>
                <Td className="text-text-muted">{o.customer_name}</Td>
                <Td className="text-text-muted">{new Date(o.offer_date).toLocaleDateString("tr-TR")}</Td>
                <Td>
                  <StatusBadge status={o.status} registry={OFFER_STATUS} />
                </Td>
                <Td className="text-right font-medium">{formatTL(o.grand_total)}</Td>
                <Td className="text-right">
                  <TeklifRowActions offer={o} confirm={confirm} />
                </Td>
              </Tr>
            ))}
          </tbody>
        </Table>
        {offers.length === 0 && (
          <EmptyState
            icon={FileText}
            title="Teklif bulunamadı"
            description={
              hasFilters ? "Arama veya filtre kriterlerine uyan teklif yok." : "Bu filtrede henüz teklif yok."
            }
          />
        )}
      </Card>

      <Pagination
        page={page}
        totalPages={totalPages}
        total={total}
        itemLabel="teklif"
        hrefForPage={(target) => listHref(params, target)}
      />

      {dialog}
    </div>
  );
}
