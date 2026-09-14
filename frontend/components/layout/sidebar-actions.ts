"use server";

import { cookies } from "next/headers";

import { SIDEBAR_COLLAPSED_COOKIE } from "@/lib/sidebar";

// AppShell bunu sunucu tarafında okuyup ilk render'da doğru genişliği
// verir (flash yok). Sadece bu cookie'yi yazar -- oturum/yetki ile
// ilgisi yoktur.
export async function setSidebarCollapsed(collapsed: boolean) {
  const cookieStore = await cookies();
  cookieStore.set(SIDEBAR_COLLAPSED_COOKIE, collapsed ? "1" : "0", {
    path: "/",
    maxAge: 60 * 60 * 24 * 365,
    sameSite: "lax",
  });
}
