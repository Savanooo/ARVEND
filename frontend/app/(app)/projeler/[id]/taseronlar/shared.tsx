"use client";

import { useRouter } from "next/navigation";
import { useState } from "react";

import { Badge } from "@/components/ui/Badge";
import { ApiError } from "@/lib/api";
import { formatDateTR, istanbulDate } from "@/lib/format";
import type { StatusMeta } from "@/lib/status";
import { statusMetaFor } from "@/lib/subcontracts";
import type { BudgetLine, OrganizationCostCode, WBSNode } from "@/lib/types";

// Taşeron sözleşme ekranlarının (form + detay) ortak istemci parçaları.

export const inputClass =
  "rounded-md border border-border bg-surface px-3 py-2 text-sm text-text placeholder:text-text-muted/60 outline-none focus:border-gold";

/**
 * Bölüm içi yazma eylemi: hata mesajı sunucudan geldiği gibi gösterilir
 * (403/409 dahil), başarıda sayfa verisi yenilenir. Kapalı projede hiçbir
 * istek atılmaz (düğmeler zaten gizli; bu ikinci emniyettir).
 */
export function useSubcontractAction(locked: boolean) {
  const router = useRouter();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  async function run<T>(fn: () => Promise<T>): Promise<T | null> {
    if (locked) return null;
    setBusy(true);
    setError(null);
    try {
      const out = await fn();
      router.refresh();
      return out ?? (true as T);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Bağlantı hatası");
      return null;
    } finally {
      setBusy(false);
    }
  }
  return { busy, error, setError, run };
}

export function Field({ label, value }: { label: string; value: React.ReactNode }) {
  return (
    <div className="flex flex-col gap-0.5">
      <span className="text-xs uppercase tracking-widest text-text-muted">{label}</span>
      <span>{value}</span>
    </div>
  );
}

export function StatusPill({ registry, status }: { registry: Record<string, StatusMeta>; status: string }) {
  const meta = statusMetaFor(registry, status);
  return <Badge tone={meta.tone}>{meta.label}</Badge>;
}

/** "YYYY-MM-DD" -> "30.09.2026"; boşsa "—". */
export function formatDay(d: string | null | undefined): string {
  return d ? formatDateTR(d) : "—";
}

/** Zaman damgası -> İstanbul günü "30.09.2026"; boşsa "—". */
export function formatTs(ts: string | null | undefined): string {
  if (!ts) return "—";
  const t = new Date(ts);
  return Number.isNaN(t.getTime()) ? "—" : formatDateTR(istanbulDate(t));
}

export function costCodeLabel(c: Pick<OrganizationCostCode, "code" | "name">): string {
  return c.code ? `${c.code} — ${c.name}` : c.name;
}

/** Maliyet kodu seçici: pasif kodlar yalnızca zaten seçiliyse listelenir (mobil gibi). */
export function CostCodeSelect({
  value,
  onChange,
  costCodes,
  className = "",
}: {
  value: string;
  onChange: (v: string) => void;
  costCodes: OrganizationCostCode[];
  className?: string;
}) {
  const options = costCodes.filter((c) => c.is_active || c.id === value);
  const known = value === "" || options.some((c) => c.id === value);
  return (
    <select
      className={`${inputClass} ${className}`}
      value={value}
      onChange={(e) => onChange(e.target.value)}
      aria-label="Maliyet kodu"
    >
      <option value="">Maliyet Kodu (zorunlu)</option>
      {!known && <option value={value}>Bilinmeyen maliyet kodu</option>}
      {options.map((c) => (
        <option key={c.id} value={c.id}>
          {costCodeLabel(c)}
        </option>
      ))}
    </select>
  );
}

/**
 * Bütçe kalemi seçici (opsiyonel): seçili maliyet koduna ait kalemler.
 * Liste okunamıyorsa (projects.budget.read yok) hiç çizilmez; mevcut değer
 * taslakta korunur ve geri gönderilir.
 */
export function BudgetLineSelect({
  value,
  onChange,
  budgetLines,
  costCodeId,
  className = "",
}: {
  value: string;
  onChange: (v: string) => void;
  budgetLines: BudgetLine[] | null;
  costCodeId: string;
  className?: string;
}) {
  if (!budgetLines) return null;
  const options = budgetLines.filter((l) => l.id === value || !costCodeId || l.cost_code_id === costCodeId);
  const known = value === "" || options.some((l) => l.id === value);
  return (
    <select
      className={`${inputClass} ${className}`}
      value={value}
      onChange={(e) => onChange(e.target.value)}
      aria-label="Bütçe kalemi"
    >
      <option value="">Bütçe Kalemi (opsiyonel)</option>
      {!known && <option value={value}>Mevcut bütçe kalemi</option>}
      {options.map((l) => (
        <option key={l.id} value={l.id}>
          {l.wbs_code ? `${l.wbs_code} · ` : ""}
          {l.description}
        </option>
      ))}
    </select>
  );
}

/** WBS seçici (opsiyonel); liste okunamıyorsa çizilmez, mevcut değer korunur. */
export function WbsSelect({
  value,
  onChange,
  wbsNodes,
  className = "",
}: {
  value: string;
  onChange: (v: string) => void;
  wbsNodes: WBSNode[] | null;
  className?: string;
}) {
  if (!wbsNodes) return null;
  const options = wbsNodes.filter((n) => n.is_active || n.id === value);
  const known = value === "" || options.some((n) => n.id === value);
  return (
    <select
      className={`${inputClass} ${className}`}
      value={value}
      onChange={(e) => onChange(e.target.value)}
      aria-label="WBS"
    >
      <option value="">WBS (opsiyonel)</option>
      {!known && <option value={value}>Mevcut WBS düğümü</option>}
      {options.map((n) => (
        <option key={n.id} value={n.id}>
          {n.code} — {n.name}
        </option>
      ))}
    </select>
  );
}
