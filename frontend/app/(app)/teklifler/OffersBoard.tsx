"use client";

import { FileText } from "lucide-react";
import Link from "next/link";
import { useMemo, useState } from "react";

import { Card } from "@/components/ui/Card";
import { useConfirmDialog } from "@/components/ui/ConfirmDialog";
import { DateInput } from "@/components/ui/DateInput";
import { EmptyState } from "@/components/ui/EmptyState";
import { SearchInput } from "@/components/ui/SearchInput";
import { StatusBadge } from "@/components/ui/StatusBadge";
import { Table, Td, Th, Tr } from "@/components/ui/Table";
import { Tabs } from "@/components/ui/Tabs";
import { formatTL } from "@/lib/format";
import { OFFER_STATUS } from "@/lib/status";
import type { Offer, OfferStatus } from "@/lib/types";

import { TeklifRowActions } from "./TeklifRowActions";

const STATUS_FILTERS: { key: "all" | OfferStatus; label: string }[] = [
  { key: "all", label: "Tümü" },
  { key: "taslak", label: "Taslak" },
  { key: "gönderildi", label: "Gönderildi" },
  { key: "kabul edildi", label: "Kabul Edildi" },
  { key: "reddedildi", label: "Reddedildi" },
];

// Durum sekmesi/arama/tarih filtreleri backend'de desteklenmiyor (offers
// listesi ucu yalnızca filter/page/limit kabul ediyor) -- bu yüzden
// GERÇEK, zaten çekilmiş satırlar üzerinde client-side uygulanır. Sahte
// veri YOK; yalnızca hesaplama sunucu yerine tarayıcıda yapılıyor.
// Sayaçlar da aynı diziden türetilir, şu anki Aktif/Pasif filtresi
// kapsamındadır (üstteki Aktif/Pasif sekmesiyle bağlamı zaten belli).
export function OffersBoard({ offers }: { offers: Offer[] }) {
  const [statusFilter, setStatusFilter] = useState<"all" | OfferStatus>("all");
  const [search, setSearch] = useState("");
  const [dateFrom, setDateFrom] = useState("");
  const [dateTo, setDateTo] = useState("");
  const { confirm, dialog } = useConfirmDialog();

  const counts = useMemo(() => {
    const base: Record<"all" | OfferStatus, number> = {
      all: offers.length,
      taslak: 0,
      gönderildi: 0,
      "kabul edildi": 0,
      reddedildi: 0,
    };
    for (const o of offers) base[o.status]++;
    return base;
  }, [offers]);

  const filtered = useMemo(() => {
    const q = search.trim().toLocaleLowerCase("tr-TR");
    return offers.filter((o) => {
      if (statusFilter !== "all" && o.status !== statusFilter) return false;
      if (q) {
        const hay = `${o.offer_no} ${o.customer_name}`.toLocaleLowerCase("tr-TR");
        if (!hay.includes(q)) return false;
      }
      if (dateFrom && o.offer_date < dateFrom) return false;
      if (dateTo && o.offer_date > dateTo) return false;
      return true;
    });
  }, [offers, statusFilter, search, dateFrom, dateTo]);

  return (
    <div className="flex flex-col gap-4">
      <Tabs
        items={STATUS_FILTERS.map((f) => ({
          key: f.key,
          label: `${f.label} (${counts[f.key]})`,
          active: statusFilter === f.key,
          onClick: () => setStatusFilter(f.key),
        }))}
      />

      <div className="flex flex-wrap items-center gap-3">
        <div className="w-full max-w-xs">
          <SearchInput
            placeholder="Teklif no veya müşteri ara"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            aria-label="Teklif no veya müşteri ara"
          />
        </div>
        <div className="flex items-center gap-2">
          <DateInput value={dateFrom} onChange={(e) => setDateFrom(e.target.value)} aria-label="Başlangıç tarihi" />
          <span className="text-xs text-text-muted">—</span>
          <DateInput value={dateTo} onChange={(e) => setDateTo(e.target.value)} aria-label="Bitiş tarihi" />
        </div>
      </div>

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
            {filtered.map((o) => (
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
        {filtered.length === 0 && (
          <EmptyState
            icon={FileText}
            title="Teklif bulunamadı"
            description={
              offers.length === 0
                ? "Bu filtrede henüz teklif yok."
                : "Arama veya filtre kriterlerine uyan teklif yok."
            }
          />
        )}
      </Card>

      <p className="text-xs text-text-muted">
        {filtered.length === offers.length ? `${offers.length} teklif` : `${filtered.length} / ${offers.length} teklif`}
      </p>

      {dialog}
    </div>
  );
}
