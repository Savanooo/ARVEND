"use client";

import { useRouter } from "next/navigation";
import { FormEvent, useState } from "react";

import { Button } from "@/components/ui/Button";
import { DateInput } from "@/components/ui/DateInput";
import { Input } from "@/components/ui/Input";
import { SearchInput } from "@/components/ui/SearchInput";
import { Select } from "@/components/ui/Select";
import { Tabs } from "@/components/ui/Tabs";
import { PROJECT_STATUS_LABELS } from "@/lib/types";

const STATUS_TABS: { value: string; label: string }[] = [
  { value: "", label: "Tümü" },
  { value: "active", label: PROJECT_STATUS_LABELS.active },
  { value: "planned", label: PROJECT_STATUS_LABELS.planned },
  { value: "paused", label: PROJECT_STATUS_LABELS.paused },
  { value: "completed", label: PROJECT_STATUS_LABELS.completed },
  { value: "cancelled", label: PROJECT_STATUS_LABELS.cancelled },
];

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
      <Tabs
        items={STATUS_TABS.map((tab) => ({
          key: tab.value || "all",
          label: tab.label,
          active: status === tab.value,
          href: buildHref({ status: tab.value }),
        }))}
      />

      <form onSubmit={handleSubmit} className="flex flex-wrap items-end gap-2">
        <div className="w-64">
          <SearchInput
            placeholder="Proje no, ad veya müşteri ara"
            value={form.q}
            onChange={(e) => setForm({ ...form, q: e.target.value })}
            aria-label="Ara"
          />
        </div>
        <div className="w-40">
          <Input
            placeholder="Proje tipi"
            value={form.project_type}
            onChange={(e) => setForm({ ...form, project_type: e.target.value })}
            aria-label="Proje tipi"
          />
        </div>
        <Select
          value={form.currency}
          onChange={(e) => setForm({ ...form, currency: e.target.value })}
          aria-label="Para birimi"
          className="w-40"
        >
          <option value="">Tüm para birimleri</option>
          <option value="TRY">TRY</option>
          <option value="USD">USD</option>
          <option value="EUR">EUR</option>
        </Select>
        <DateInput
          label="Başlangıç (en erken)"
          value={form.start_from}
          onChange={(e) => setForm({ ...form, start_from: e.target.value })}
        />
        <Button type="submit" variant="secondary">
          Filtrele
        </Button>
      </form>
    </div>
  );
}
