"use client";

import { PanelLeftClose, PanelLeftOpen } from "lucide-react";
import { useRouter } from "next/navigation";
import { useTransition } from "react";

import { setSidebarCollapsed } from "./sidebar-actions";

export function SidebarCollapseToggle({ collapsed }: { collapsed: boolean }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();

  function toggle() {
    startTransition(async () => {
      await setSidebarCollapsed(!collapsed);
      router.refresh();
    });
  }

  return (
    <button
      type="button"
      onClick={toggle}
      disabled={pending}
      title={collapsed ? "Menüyü genişlet" : "Menüyü daralt"}
      aria-label={collapsed ? "Menüyü genişlet" : "Menüyü daralt"}
      className="sidebar-nav-link sidebar-collapse-toggle flex items-center justify-center rounded-md p-2 disabled:opacity-50"
    >
      {collapsed ? (
        <PanelLeftOpen size={18} strokeWidth={1.75} />
      ) : (
        <PanelLeftClose size={18} strokeWidth={1.75} />
      )}
    </button>
  );
}
