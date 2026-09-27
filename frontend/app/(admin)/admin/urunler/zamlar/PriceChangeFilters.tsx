"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { FormEvent, useState } from "react";

import { Button } from "@/components/ui/Button";
import { Card, CardBody } from "@/components/ui/Card";
import { DateInput } from "@/components/ui/DateInput";
import { Input } from "@/components/ui/Input";
import { Select } from "@/components/ui/Select";
import {
  applyFilterForm,
  DEFAULT_ZAMLAR_PARAMS,
  DIRECTION_OPTIONS,
  filterFormFrom,
  MAX_FILTER_TEXT,
  PERIOD_OPTIONS,
  periodHref,
  REASON_OPTIONS,
  SORT_OPTIONS,
  ZAMLAR_PATH,
  zamlarHref,
  type DirectionFilter,
  type FilterForm,
  type ReasonFilter,
  type SortKey,
  type ZamlarParams,
} from "@/lib/price-changes";

/**
 * Zam Geçmişi'nin dönem seçici + filtre formu. Durum yalnızca URL'dedir:
 * dönemler bağlantıdır, form gönderilince yeni URL'e gidilir (sayfa
 * sunucuda yeniden çizilir). Sayfa bu bileşeni URL'e göre key'ler; URL
 * değişince (olay/dönem bağlantısı) form yeni değerlerle yeniden kurulur.
 */
export function PriceChangeFilters({
  params,
  range,
  sources,
  categories,
}: {
  params: ZamlarParams;
  // Etkin gün aralığı (özel aralık formunu doldurmak için).
  range: { from: string; to: string };
  sources: { code: string; name: string }[];
  categories: string[];
}) {
  const router = useRouter();
  const [form, setForm] = useState<FilterForm>(() => filterFormFrom(params, range));
  const custom = params.period === "ozel";

  function set<K extends keyof FilterForm>(key: K, value: FilterForm[K]) {
    setForm((f) => ({ ...f, [key]: value }));
  }

  function submit(e: FormEvent) {
    e.preventDefault();
    router.push(zamlarHref(applyFilterForm(params, range, form)));
  }

  return (
    <Card>
      <CardBody className="flex flex-col gap-4">
        <nav aria-label="Dönem" className="flex flex-wrap gap-1.5">
          {PERIOD_OPTIONS.map((o) => {
            const active = params.period === o.key;
            return (
              <Link
                key={o.key}
                href={periodHref(params, range, o.key)}
                aria-current={active ? "page" : undefined}
                className={`rounded-md border px-3 py-1.5 text-sm font-medium transition-colors ${
                  active
                    ? "border-gold bg-gold-soft text-text"
                    : "border-border text-text-muted hover:bg-surface-hover hover:text-text"
                }`}
              >
                {o.label}
              </Link>
            );
          })}
        </nav>

        <form onSubmit={submit} className="flex flex-col gap-3">
          <div className="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-4">
            {custom && (
              <>
                <DateInput
                  label="Başlangıç"
                  name="from"
                  required
                  value={form.from}
                  max={form.to || undefined}
                  onChange={(e) => set("from", e.target.value)}
                />
                <DateInput
                  label="Bitiş (dahil)"
                  name="to"
                  value={form.to}
                  min={form.from || undefined}
                  onChange={(e) => set("to", e.target.value)}
                />
              </>
            )}
            <Select label="Kaynak" name="source" value={form.source} onChange={(e) => set("source", e.target.value)}>
              <option value="">Tüm kaynaklar</option>
              {sources.map((s) => (
                <option key={s.code} value={s.code}>
                  {s.name}
                </option>
              ))}
            </Select>
            <Select
              label="Neden"
              name="reason"
              value={form.reason}
              onChange={(e) => set("reason", e.target.value as ReasonFilter)}
            >
              {REASON_OPTIONS.map((o) => (
                <option key={o.value} value={o.value}>
                  {o.label}
                </option>
              ))}
            </Select>
            <Select
              label="Yön"
              name="direction"
              value={form.direction}
              onChange={(e) => set("direction", e.target.value as DirectionFilter)}
            >
              {DIRECTION_OPTIONS.map((o) => (
                <option key={o.value} value={o.value}>
                  {o.label}
                </option>
              ))}
            </Select>
            <Select label="Sıralama" name="sort" value={form.sort} onChange={(e) => set("sort", e.target.value as SortKey)}>
              {SORT_OPTIONS.map((o) => (
                <option key={o.value} value={o.value}>
                  {o.label}
                </option>
              ))}
            </Select>
            <Input
              label="Kategori"
              name="category"
              list="zam-kategorileri"
              autoComplete="off"
              maxLength={MAX_FILTER_TEXT}
              placeholder="Tüm kategoriler"
              value={form.category}
              onChange={(e) => set("category", e.target.value)}
            />
            <datalist id="zam-kategorileri">
              {categories.map((c) => (
                <option key={c} value={c} />
              ))}
            </datalist>
            <Input
              label="Ürün adı"
              name="q"
              type="search"
              autoComplete="off"
              maxLength={MAX_FILTER_TEXT}
              placeholder="Ürün adında ara…"
              value={form.q}
              onChange={(e) => set("q", e.target.value)}
            />
          </div>
          <div className="flex flex-wrap items-center gap-x-3 gap-y-2">
            <Button type="submit">Uygula</Button>
            <Link
              href={ZAMLAR_PATH}
              // Zaten varsayılan URL'deyken bağlantı bileşeni yeniden kurmaz (key
              // aynı kalır): uygulanmamış form değerleri de burada temizlenir.
              // Yeni sekmede açma (değiştirici tuş) bu sekmenin formuna dokunmaz.
              onClick={(e) => {
                if (e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
                setForm(filterFormFrom(DEFAULT_ZAMLAR_PARAMS, { from: "", to: "" }));
              }}
              className="text-sm text-text-muted hover:text-text hover:underline"
            >
              Filtreleri sıfırla
            </Link>
            <span className="text-xs text-text-muted">
              Kaynak ve neden özeti de süzer; yön, kategori, arama ve sıralama yalnızca tabloya uygulanır.
            </span>
          </div>
        </form>
      </CardBody>
    </Card>
  );
}
