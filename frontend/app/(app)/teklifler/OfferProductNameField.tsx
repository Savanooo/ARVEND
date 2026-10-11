"use client";

import { useEffect, useRef, useState } from "react";

import { Input } from "@/components/ui/Input";
import { apiClient, ApiError } from "@/lib/api";
import { formatTL } from "@/lib/format";
import {
  catalogCurrencyNote,
  moreProductsNote,
  PRODUCT_SUGGEST_DEBOUNCE_MS,
  productSuggestionMeta,
  productSuggestPath,
  productSuggestQuery,
} from "@/lib/offers";
import type { Product } from "@/lib/types";

type Status = "idle" | "loading" | "results" | "empty" | "offline" | "failed";

// Teklif kalemindeki "Ürün / Hizmet" alanı + katalog önerileri (mobil
// product_suggestions.dart ile aynı kurallar). Eskiden ad bir <datalist>'ten
// seçiliyor ve form açılırken TÜM katalog (~4000 ürün, 40 sayfa) çekiliyordu;
// tarayıcının datalist süzmesi tek alt dize ve yalnızca ad olduğundan
// "demir" ya da "kutu 40" hiçbir şey bulmuyordu. Şimdi 2+ karakterde, 300 ms
// beklemeyle GET /products?q=…&limit=6 (kelime bazlı arama) istenir; süren
// eski istek iptal edilir.
//
// Öneri seçmek ZORUNLU DEĞİL: eşleşme yoksa ya da istek başarısızsa yazılan
// ad serbest kalem olarak kalır. catalogEnabled false ise (products.read yok)
// düz alandır ve hiç istek atmaz -- izinsiz kullanıcı her harfte 403 almasın.
// Seçim kimlikle yapılır (onPick ürünün kendisini verir); bağı ve ad
// değişince düşmesini çağıran yönetir (bkz. lib/offers.ts).
export function OfferProductNameField({
  value,
  label,
  catalogEnabled,
  currency,
  onChange,
  onPick,
}: {
  value: string;
  label?: string;
  catalogEnabled: boolean;
  // Teklifin para birimi: TL değilse önerilerin üstünde kur uyarısı çıkar.
  currency: string;
  onChange: (name: string) => void;
  onPick: (product: Product) => void;
}) {
  const [status, setStatus] = useState<Status>("idle");
  const [results, setResults] = useState<Product[]>([]);
  const [total, setTotal] = useState(0);
  const [active, setActive] = useState(-1);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const inflight = useRef<AbortController | null>(null);
  // Her aramanın sırası: geç dönen eski bir yanıt yenisinin üstüne yazmasın.
  const seq = useRef(0);
  // Seçilen ürünün adı: alan bu metni taşıdığı sürece yeniden aranmaz.
  const pickedName = useRef<string | null>(null);

  // Bileşen kalkarken (satır silindi) bekleyen istek/zamanlayıcı kalmasın.
  useEffect(
    () => () => {
      if (timer.current) clearTimeout(timer.current);
      inflight.current?.abort();
    },
    []
  );

  function reset() {
    if (timer.current) clearTimeout(timer.current);
    inflight.current?.abort();
    inflight.current = null;
    seq.current += 1;
    setStatus("idle");
    setResults([]);
    setTotal(0);
    setActive(-1);
  }

  async function search(q: string) {
    inflight.current?.abort();
    const controller = new AbortController();
    inflight.current = controller;
    const mySeq = ++seq.current;
    setStatus("loading");
    try {
      const page = await apiClient<{ products: Product[]; total: number }>(productSuggestPath(q), {
        signal: controller.signal,
      });
      if (mySeq !== seq.current) return;
      setResults(page.products);
      setTotal(page.total);
      setActive(-1);
      setStatus(page.products.length === 0 ? "empty" : "results");
    } catch (err) {
      if (mySeq !== seq.current || controller.signal.aborted) return;
      setResults([]);
      setTotal(0);
      // ApiError = sunucu yanıt verdi ama hata; diğerleri (TypeError) ağ.
      setStatus(err instanceof ApiError ? "failed" : "offline");
    } finally {
      if (inflight.current === controller) inflight.current = null;
    }
  }

  function handleChange(next: string) {
    onChange(next);
    if (!catalogEnabled) return;
    const q = productSuggestQuery(next, pickedName.current);
    if (q === null) {
      reset();
      return;
    }
    pickedName.current = null;
    if (timer.current) clearTimeout(timer.current);
    timer.current = setTimeout(() => void search(q), PRODUCT_SUGGEST_DEBOUNCE_MS);
  }

  function pick(p: Product) {
    pickedName.current = p.name.trim();
    reset();
    onPick(p);
  }

  function handleKeyDown(e: React.KeyboardEvent<HTMLInputElement>) {
    if (status !== "results" || results.length === 0) {
      if (e.key === "Escape" && status !== "idle") reset();
      return;
    }
    if (e.key === "ArrowDown") {
      e.preventDefault();
      setActive((i) => (i + 1) % results.length);
    } else if (e.key === "ArrowUp") {
      e.preventDefault();
      setActive((i) => (i <= 0 ? results.length - 1 : i - 1));
    } else if (e.key === "Enter" && active >= 0) {
      // Seçim formu göndermesin.
      e.preventDefault();
      pick(results[active]);
    } else if (e.key === "Escape") {
      e.preventDefault();
      reset();
    }
  }

  const currencyNote = catalogCurrencyNote(currency);
  const more = moreProductsNote(total, results.length);

  return (
    <div className="relative">
      <Input
        label={label}
        value={value}
        autoComplete="off"
        role={catalogEnabled ? "combobox" : undefined}
        aria-expanded={catalogEnabled ? status !== "idle" : undefined}
        aria-autocomplete={catalogEnabled ? "list" : undefined}
        onChange={(e) => handleChange(e.target.value)}
        onKeyDown={catalogEnabled ? handleKeyDown : undefined}
        // Başka alana geçince öneriler kapanır; tıklama (onMouseDown) önce işlenir.
        onBlur={catalogEnabled ? () => setTimeout(reset, 150) : undefined}
        placeholder={catalogEnabled ? "Katalogda arayın ya da serbest yazın" : "Ürün / hizmet adı"}
      />
      {catalogEnabled && status !== "idle" && (
        <div className="absolute left-0 z-20 mt-1 w-full min-w-[22rem] overflow-hidden rounded-md border border-border bg-surface shadow-lg">
          {status === "loading" && results.length === 0 && <Note>Katalogda aranıyor…</Note>}
          {status === "empty" && <Note>Katalogda eşleşen ürün yok. Yazdığınız ad serbest kalem olarak eklenir.</Note>}
          {status === "offline" && (
            <Note>Bağlantı yok: katalog önerileri gösterilemiyor. Yazdığınız ad serbest kalem olarak kalır.</Note>
          )}
          {status === "failed" && <Note>Katalog önerileri alınamadı. Yazdığınız ad serbest kalem olarak kalır.</Note>}
          {(status === "results" || (status === "loading" && results.length > 0)) && (
            <>
              {currencyNote && <Note tone="warning">{currencyNote}</Note>}
              <ul role="listbox" className="max-h-72 overflow-y-auto">
                {results.map((p, i) => {
                  const meta = productSuggestionMeta(p);
                  return (
                    <li key={p.id} className="border-t border-border first:border-t-0">
                      <button
                        type="button"
                        role="option"
                        aria-selected={i === active}
                        // onMouseDown: input blur olmadan seçim yapılsın.
                        onMouseDown={(e) => {
                          e.preventDefault();
                          pick(p);
                        }}
                        onMouseEnter={() => setActive(i)}
                        className={`flex w-full items-start justify-between gap-3 px-3 py-2 text-left text-sm ${
                          i === active ? "bg-surface-hover" : "hover:bg-surface-hover"
                        }`}
                      >
                        <span className="flex min-w-0 flex-col">
                          <span className="line-clamp-2 font-medium">{p.name}</span>
                          {meta && <span className="truncate text-xs text-text-muted">{meta}</span>}
                        </span>
                        <span className="flex shrink-0 flex-col items-end">
                          <span className="font-semibold">{formatTL(p.unit_price)}</span>
                          {p.unit && <span className="text-xs text-text-muted">/ {p.unit}</span>}
                        </span>
                      </button>
                    </li>
                  );
                })}
              </ul>
              {more && <p className="border-t border-border px-3 py-1.5 text-xs text-text-muted">{more}</p>}
            </>
          )}
        </div>
      )}
    </div>
  );
}

function Note({ children, tone }: { children: React.ReactNode; tone?: "warning" }) {
  return (
    <p className={`px-3 py-2 text-xs ${tone === "warning" ? "bg-gold-soft/40 text-text" : "text-text-muted"}`}>
      {children}
    </p>
  );
}
