"use client";

import { useState } from "react";

// Proje detayı, ERP tarzı tek bir geniş çalışma ekranıdır: bölümler
// açılır/kapanır, böylece yoğun bilgi okunabilir kalır.
//
// `action`: başlığın sağında, başlığın kendisinden BAĞIMSIZ bir aksiyon
// (ör. "+ Masraf Ekle"). Başlık bir <button> olduğundan aksiyon onun
// İÇİNE değil YANINA konur -- iç içe etkileşimli içerik geçersiz HTML
// olurdu.
// `open`/`onOpenChange`: verilirse bölüm kontrollü çalışır (çağıran,
// ör. bir aksiyonla bölümü programatik olarak açabilir); verilmezse
// önceki gibi kendi iç state'iyle çalışır.
export function Section({
  title,
  defaultOpen = false,
  open: controlledOpen,
  onOpenChange,
  action,
  placeholder = false,
  children,
}: {
  title: string;
  defaultOpen?: boolean;
  open?: boolean;
  onOpenChange?: (open: boolean) => void;
  action?: React.ReactNode;
  placeholder?: boolean;
  children?: React.ReactNode;
}) {
  const [internalOpen, setInternalOpen] = useState(defaultOpen);
  const isControlled = controlledOpen !== undefined;
  const open = isControlled ? controlledOpen : internalOpen;

  function toggle() {
    const next = !open;
    if (!isControlled) setInternalOpen(next);
    onOpenChange?.(next);
  }

  return (
    <div className="overflow-hidden rounded-lg border border-border bg-surface">
      <div className="flex items-center gap-3 px-4 py-3 transition-colors hover:bg-surface-hover">
        <button
          type="button"
          onClick={toggle}
          aria-expanded={open}
          className="flex flex-1 items-center gap-2 text-left text-sm font-semibold uppercase tracking-widest text-text-muted"
        >
          {title}
          {placeholder && (
            <span className="rounded bg-surface-hover px-1.5 py-0.5 text-[10px] font-medium normal-case tracking-normal text-text-muted">
              sonraki faz
            </span>
          )}
        </button>
        {action && <div className="shrink-0">{action}</div>}
        <button
          type="button"
          onClick={toggle}
          tabIndex={-1}
          aria-hidden
          className="shrink-0 px-1 text-text-muted"
        >
          {open ? "−" : "+"}
        </button>
      </div>
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
