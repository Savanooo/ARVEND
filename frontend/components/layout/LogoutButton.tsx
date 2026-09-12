"use client";

import { useRouter } from "next/navigation";
import { useState } from "react";

import { apiClient } from "@/lib/api";

export function LogoutButton() {
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
      className="sidebar-nav-link text-xs font-semibold uppercase tracking-widest disabled:opacity-50"
    >
      {loading ? "Çıkış yapılıyor…" : "Çıkış Yap"}
    </button>
  );
}
