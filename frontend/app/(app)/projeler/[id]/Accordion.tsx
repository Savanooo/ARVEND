"use client";

import { useState } from "react";

// Proje detayı, ERP tarzı tek bir geniş çalışma ekranıdır: bölümler
// açılır/kapanır, böylece yoğun bilgi okunabilir kalır.
export function Section({
  title,
  defaultOpen = false,
  placeholder = false,
  children,
}: {
  title: string;
  defaultOpen?: boolean;
  placeholder?: boolean;
  children?: React.ReactNode;
}) {
  const [open, setOpen] = useState(defaultOpen);

  return (
    <div className="overflow-hidden rounded-lg border border-border bg-surface">
      <button
        type="button"
        onClick={() => setOpen((v) => !v)}
        aria-expanded={open}
        className="flex w-full items-center justify-between px-4 py-3 text-left text-sm font-semibold uppercase tracking-widest text-text-muted transition-colors hover:bg-surface-hover"
      >
        <span className="flex items-center gap-2">
          {title}
          {placeholder && (
            <span className="rounded bg-surface-hover px-1.5 py-0.5 text-[10px] font-medium normal-case tracking-normal text-text-muted">
              sonraki faz
            </span>
          )}
        </span>
        <span className="text-text-muted">{open ? "−" : "+"}</span>
      </button>
      {open && (
        <div className="border-t border-border px-4 py-4 text-sm">
          {placeholder ? (
            <p className="text-text-muted">Bu modül sonraki fazda aktif olacak.</p>
          ) : (
            children
          )}
        </div>
      )}
    </div>
  );
}
