import Link from "next/link";

import { SegmentBar } from "@/components/ui/SegmentBar";
import { FOCUS_RING } from "@/components/ui/styles";
import { EMPTY, priceSourceName, relativeDays, syncStatusLabel, webHrefFor } from "@/lib/dashboard";
import { formatCount, formatPercent } from "@/lib/format";

import { CardLinks, CtaLink, EmptyNote, Metric, Note, Stat, StatGrid } from "../card-parts";
import { canAll, type CardContext } from "../context";
import { MissingModule, ModuleCard } from "../ModuleCard";

const STATUS_DOT: Record<string, string> = {
  success: "bg-success",
  failed: "bg-danger",
  never: "bg-text-muted/40",
};

// Ürünler & Zam: katalog büyüklüğü, kaynak dağılımı, son 30 günün
// tedarikçi zamları, fiyat kaynağı senkron durumu. Kâr oranı / tedarikçi
// alış fiyatı ASLA gösterilmez.
export function ProductsCard({ ctx }: { ctx: CardContext }) {
  const s = ctx.data.sections.products;
  if (!s) return <MissingModule moduleKey="products" ctx={ctx} />;

  const sources =
    s.price_sources.length === 0 ? (
      <Note>{EMPTY.productsNoSource}</Note>
    ) : (
      <ul className="flex flex-wrap gap-1.5">
        {s.price_sources.map((ps) => {
          const name = priceSourceName(ps.source);
          const when = ps.last_status === "never" || ps.days_since_sync === null ? null : relativeDays(ps.days_since_sync);
          return (
            <li
              key={ps.source}
              className="inline-flex items-center gap-1.5 rounded-md border border-border px-2 py-0.5 text-xs text-text-muted"
            >
              <span aria-hidden className={`size-1.5 shrink-0 rounded-full ${STATUS_DOT[ps.last_status] ?? STATUS_DOT.never}`} />
              {[name, when, syncStatusLabel(ps.last_status)].filter(Boolean).join(" · ")}
            </li>
          );
        })}
      </ul>
    );
  // Başarılı ama 7 günden eski senkron: yalnızca kart notu (Dikkat'e girmez).
  const stale = s.price_sources
    .filter((ps) => ps.last_status === "success" && (ps.days_since_sync ?? 0) > 7)
    .map((ps) => `${priceSourceName(ps.source)} fiyatları ${formatCount(ps.days_since_sync ?? 0)} gündür güncellenmedi`);
  const links = [{ href: "/admin/urunler", label: "Ürünler" }];

  if (s.total === 0) {
    return (
      <ModuleCard
        moduleKey="products"
        ctx={ctx}
        main={
          <>
            <EmptyNote
              text={EMPTY.products}
              action={canAll(ctx, ["products.read"]) ? <CtaLink href="/admin/urunler" label="Ürünlere git" /> : undefined}
            />
            {sources}
          </>
        }
      />
    );
  }

  const pc = s.price_changes_30d;
  const max = pc.max_increase;
  const maxHref = max ? webHrefFor(max.ref) : null;
  const maxText = max ? `${formatPercent(max.change_percent)} · ${max.product_name}` : "—";

  return (
    <ModuleCard
      moduleKey="products"
      ctx={ctx}
      main={
        <>
          <Metric label="Ürün" value={formatCount(s.total)} />
          <StatGrid>
            <Stat label="Zamlanan ürün (30 gün)" value={formatCount(pc.products_increased)} />
            <Stat label="Ortalama zam" value={pc.avg_increase_percent === null ? "—" : formatPercent(pc.avg_increase_percent)} />
            <Stat
              wide
              label="En yüksek zam"
              value={
                maxHref ? (
                  <Link href={maxHref} className={`block truncate rounded-sm hover:text-gold hover:underline ${FOCUS_RING}`}>
                    {maxText}
                  </Link>
                ) : (
                  <span className="block truncate">{maxText}</span>
                )
              }
            />
          </StatGrid>
          <SegmentBar
            ariaLabel="Ürünlerin kaynağı"
            segments={[
              { key: "manual", value: s.by_source.manual, tone: "muted", label: "Manuel" },
              { key: "ulas", value: s.by_source.ulas, tone: "graphite", label: "Ulaş" },
              { key: "demirprofil", value: s.by_source.demirprofil, tone: "ink", label: "Demir Profil" },
            ]}
          />
          {sources}
          {stale.map((n) => (
            <Note key={n}>{n}</Note>
          ))}
          <CardLinks links={links} />
        </>
      }
    />
  );
}
