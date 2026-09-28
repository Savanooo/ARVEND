"use client";

import { useState } from "react";

import { FOCUS_RING } from "@/components/ui/styles";

// Nakit Akışı panelinde birden çok para birimi varsa küçük bir seçici:
// her para biriminin gövdesi sunucuda hazır çizilir, burada yalnızca
// hangisinin görüneceği seçilir (hesap YOK; para birimleri toplanmaz).
export function CurrencyPanels({
  heading,
  labels,
  panels,
}: {
  heading: React.ReactNode;
  labels: string[];
  panels: React.ReactNode[];
}) {
  const [active, setActive] = useState(0);
  return (
    <>
      <header className="flex items-center justify-between gap-3 border-b border-border px-4 py-3 @4xl/home:px-5">
        {heading}
        <div role="group" aria-label="Para birimi" className="inline-flex overflow-hidden rounded-md border border-border">
          {labels.map((label, i) => (
            <button
              key={label}
              type="button"
              aria-pressed={active === i}
              onClick={() => setActive(i)}
              className={`min-w-9 px-2.5 py-1 text-xs font-semibold tabular-nums transition-colors ${
                active === i ? "bg-surface-hover text-text" : "text-text-muted hover:text-text"
              } ${i > 0 ? "border-l border-border" : ""} ${FOCUS_RING}`}
            >
              {label}
            </button>
          ))}
        </div>
      </header>
      {panels.map((panel, i) => (
        <div key={labels[i]} hidden={active !== i} className="flex flex-1 flex-col">
          {panel}
        </div>
      ))}
    </>
  );
}
