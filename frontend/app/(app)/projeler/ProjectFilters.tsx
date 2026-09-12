"use client";

import { useRouter } from "next/navigation";
import { FormEvent, useState } from "react";

import { Button } from "@/components/ui/Button";
import { PROJECT_STATUS_LABELS, type ProjectStatus } from "@/lib/types";

const STATUS_TABS: { value: string; label: string }[] = [
  { value: "", label: "Tümü" },
  { value: "active", label: PROJECT_STATUS_LABELS.active },
  { value: "planned", label: PROJECT_STATUS_LABELS.planned },
  { value: "paused", label: PROJECT_STATUS_LABELS.paused },
  { value: "completed", label: PROJECT_STATUS_LABELS.completed },
  { value: "cancelled", label: PROJECT_STATUS_LABELS.cancelled },
];

const inputClass =
  "rounded-md border border-border bg-surface px-3 py-2 text-sm text-text placeholder:text-text-muted/60 outline-none focus:border-gold";

export function ProjectFilters({
  status,
  search,
  projectType,
  currency,
  startFrom,
}: {
  status: string;
  search: string;
  projectType: string;
  currency: string;
  startFrom: string;
}) {
  const router = useRouter();
  const [form, setForm] = useState({ q: search, project_type: projectType, currency, start_from: startFrom });

  function buildHref(next: Partial<Record<string, string>>) {
    const params = new URLSearchParams();
    const merged = { status, ...form, ...next };
    for (const [k, v] of Object.entries(merged)) {
      if (v) params.set(k, v);
    }
    const qs = params.toString();
    return qs ? `/projeler?${qs}` : "/projeler";
  }

  function handleSubmit(e: FormEvent) {
    e.preventDefault();
    router.push(buildHref({}));
  }

  return (
    <div className="flex flex-col gap-3">
      <div className="flex flex-wrap items-center gap-2 text-sm">
        {STATUS_TABS.map((tab) => (
          <a
            key={tab.value || "all"}
            href={buildHref({ status: tab.value })}
            className={
              status === tab.value ? "font-semibold text-gold" : "text-text-muted hover:text-text"
            }
          >
            {tab.label}
          </a>
        ))}
      </div>

      <form onSubmit={handleSubmit} className="flex flex-wrap items-end gap-2">
        <input
          className={inputClass}
          placeholder="Proje no, ad veya müşteri ara"
          value={form.q}
          onChange={(e) => setForm({ ...form, q: e.target.value })}
          aria-label="Ara"
        />
        <input
          className={inputClass}
          placeholder="Proje tipi"
          value={form.project_type}
          onChange={(e) => setForm({ ...form, project_type: e.target.value })}
          aria-label="Proje tipi"
        />
        <select
          className={inputClass}
          value={form.currency}
          onChange={(e) => setForm({ ...form, currency: e.target.value })}
          aria-label="Para birimi"
        >
          <option value="">Tüm para birimleri</option>
          <option value="TRY">TRY</option>
          <option value="USD">USD</option>
          <option value="EUR">EUR</option>
        </select>
        <label className="flex flex-col gap-1 text-xs uppercase tracking-widest text-text-muted">
          Başlangıç (en erken)
          <input
            type="date"
            className={inputClass}
            value={form.start_from}
            onChange={(e) => setForm({ ...form, start_from: e.target.value })}
          />
        </label>
        <Button type="submit" variant="secondary">
          Filtrele
        </Button>
      </form>
    </div>
  );
}
