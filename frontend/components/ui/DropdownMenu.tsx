"use client";

import Link from "next/link";
import { useEffect, useRef, useState } from "react";

// Basit relative/absolute konumlandırma -- popper/floating-ui gibi bir
// dependency gerekmez, ARVEND'in kullanım alanları (satır işlem menüsü,
// kullanıcı menüsü) için yeterli.
export function DropdownMenu({
  trigger,
  triggerLabel,
  children,
  align = "right",
}: {
  trigger: React.ReactNode;
  triggerLabel: string;
  children: React.ReactNode;
  align?: "left" | "right";
}) {
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!open) return;
    function handleClick(e: MouseEvent) {
      if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false);
    }
    function handleEscape(e: KeyboardEvent) {
      if (e.key === "Escape") setOpen(false);
    }
    document.addEventListener("mousedown", handleClick);
    document.addEventListener("keydown", handleEscape);
    return () => {
      document.removeEventListener("mousedown", handleClick);
      document.removeEventListener("keydown", handleEscape);
    };
  }, [open]);

  return (
    <div ref={ref} className="relative inline-block">
      <button
        type="button"
        onClick={() => setOpen((v) => !v)}
        aria-haspopup="menu"
        aria-expanded={open}
        aria-label={triggerLabel}
        title={triggerLabel}
        className="inline-flex items-center justify-center rounded-md p-2 text-text-muted transition-colors hover:bg-surface-hover hover:text-text"
      >
        {trigger}
      </button>
      {open && (
        <div
          role="menu"
          onClick={() => setOpen(false)}
          className={`absolute z-20 mt-1 min-w-40 rounded-md border border-border bg-surface py-1 text-sm shadow-md ${
            align === "right" ? "right-0" : "left-0"
          }`}
        >
          {children}
        </div>
      )}
    </div>
  );
}

const menuItemClass =
  "flex w-full items-center gap-2 px-3 py-2 text-left text-text hover:bg-surface-hover disabled:opacity-50";

// href verilirse bir gezinme linki (Link), verilmezse bir aksiyon
// butonu render eder -- bir <button>'ı <a>'nın içine SARMAK geçersiz
// HTML olurdu (iç içe etkileşimli içerik), bu yüzden ikisi ayrı dallar.
export function DropdownMenuItem({
  className = "",
  href,
  ...props
}: React.ButtonHTMLAttributes<HTMLButtonElement> & { href?: string }) {
  if (href) {
    return (
      <Link href={href} role="menuitem" className={`${menuItemClass} ${className}`}>
        {props.children}
      </Link>
    );
  }
  return <button type="button" role="menuitem" className={`${menuItemClass} ${className}`} {...props} />;
}
