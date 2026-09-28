"use client";

import { LogOut } from "lucide-react";
import { useRouter } from "next/navigation";
import { useState } from "react";

import { apiClient } from "@/lib/api";

export function LogoutButton({ collapsed = false }: { collapsed?: boolean }) {
  const router = useRouter();
  const [loading, setLoading] = useState(false);

  async function handleLogout() {
    setLoading(true);
    try {
      await apiClient("/api/v1/auth/logout", { method: "POST" });
    } finally {
      router.push("/giris");
      router.refresh();
    }
  }

  return (
    <button
      onClick={handleLogout}
      disabled={loading}
      title={collapsed ? "Çıkış Yap" : undefined}
      aria-label="Çıkış Yap"
      className="sidebar-nav-link flex items-center gap-2 rounded-md px-2 py-1.5 text-xs font-semibold uppercase tracking-widest disabled:opacity-50"
    >
      <LogOut size={16} strokeWidth={1.75} />
      {!collapsed && <span className="sidebar-label">{loading ? "Çıkış yapılıyor…" : "Çıkış Yap"}</span>}
    </button>
  );
}
