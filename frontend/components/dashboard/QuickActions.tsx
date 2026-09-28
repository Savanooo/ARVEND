"use client";

import { MoreHorizontal, Plus } from "lucide-react";
import Link from "next/link";
import { useRef } from "react";

import { DropdownMenu, DropdownMenuItem } from "@/components/ui/DropdownMenu";
import { FOCUS_RING, buttonClass, type ButtonLookVariant } from "@/components/ui/styles";
import { COPY, type QuickAction } from "@/lib/dashboard";

import { useProjectPicker } from "./ProjectPickerModal";

// Başlıktaki hızlı işlemler (yazma izinleriyle sunucuda süzülmüş liste
// gelir, bkz. quickActionsFor). 1. işlem birincil düğme; 2. @2xl'den,
// 3. @4xl'den itibaren ikincil düğme; kalanlar (ve dar genişlikte 2./3.)
// "Diğer işlemler" menüsünde. "Yeni Proje" YOK: projeler kabul edilen
// tekliften dönüştürülür.
export function QuickActions({ actions }: { actions: QuickAction[] }) {
  const picker = useProjectPicker();
  const menuRef = useRef<HTMLDivElement>(null);
  if (actions.length === 0) return null;

  const [first, second, third, ...rest] = actions;

  function actionButton(a: QuickAction, variant: ButtonLookVariant, display: string) {
    const icon = a.key === "offer" ? <Plus size={16} strokeWidth={2} aria-hidden /> : null;
    if (a.href) {
      return (
        <Link key={a.key} href={a.href} className={buttonClass(variant, "md", display)}>
          {icon}
          {a.label}
        </Link>
      );
    }
    const tab = a.pickerTab;
    // disabled YERİNE aria-disabled (picker.start meşgulken zaten döner):
    // odak düğmede kalır, seçici kapanınca oraya geri döner.
    return (
      <button
        key={a.key}
        type="button"
        aria-disabled={picker.busy}
        aria-busy={picker.busy}
        onClick={(e) => tab && void picker.start(tab, e.currentTarget)}
        className={buttonClass(variant, "md", display)}
      >
        {icon}
        {a.label}
      </button>
    );
  }

  function menuItem(a: QuickAction, extra = "") {
    if (a.href) {
      return (
        <DropdownMenuItem key={a.key} href={a.href} className={extra}>
          {a.label}
        </DropdownMenuItem>
      );
    }
    const tab = a.pickerTab;
    // Menü öğesi tıklanınca menü kapanır (öğe DOM'dan çıkar); seçici
    // kapanınca odak "Diğer işlemler" tetiğine döner.
    return (
      <DropdownMenuItem
        key={a.key}
        disabled={picker.busy}
        onClick={() => tab && void picker.start(tab, menuTrigger())}
        className={extra}
      >
        {a.label}
      </DropdownMenuItem>
    );
  }

  function menuTrigger(): HTMLElement | null {
    return menuRef.current?.querySelector<HTMLElement>("button[aria-haspopup='menu']") ?? null;
  }

  // Menü, içinde gösterilecek öğe kalmayan genişlikte tamamen gizlenir.
  const menuWrapper = rest.length > 0 ? "" : third ? "@4xl:hidden" : second ? "@2xl:hidden" : "hidden";

  return (
    <div className="flex flex-wrap items-center gap-2">
      {actionButton(first, "primary", "inline-flex")}
      {second && actionButton(second, "secondary", "hidden @2xl:inline-flex")}
      {third && actionButton(third, "secondary", "hidden @4xl:inline-flex")}
      {second && (
        <div ref={menuRef} className={menuWrapper}>
          <DropdownMenu
            trigger={<MoreHorizontal size={16} strokeWidth={1.75} aria-hidden />}
            triggerLabel={COPY.moreActions}
            triggerClassName={`inline-flex items-center justify-center rounded-md border border-border bg-surface p-2 text-text-muted transition-colors hover:bg-surface-hover hover:text-text ${FOCUS_RING}`}
          >
            {menuItem(second, "@2xl:hidden")}
            {third && menuItem(third, "@4xl:hidden")}
            {rest.map((a) => menuItem(a))}
          </DropdownMenu>
        </div>
      )}
      {picker.modal}
    </div>
  );
}
