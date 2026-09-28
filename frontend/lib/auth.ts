import { cookies } from "next/headers";
import { redirect } from "next/navigation";
import { cache } from "react";

import { apiServer, ApiError } from "./api";
import { canAccess } from "./permissions";
import { homeFor } from "./route-policy";
import type { User } from "./types";

/**
 * Server Component'lerde oturum sahibini okur; oturum yoksa/geçersizse null
 * döner. React cache() ile sarılıdır: aynı istekte layout ve sayfa (ana
 * sayfa, requirePagePermission...) /auth/me'yi TEK kez çağırır.
 */
export const getCurrentUser = cache(async (): Promise<User | null> => {
  const cookieStore = await cookies();
  const cookieHeader = cookieStore.toString();
  if (!cookieHeader) return null;

  try {
    return await apiServer<User>("/api/v1/auth/me", cookieHeader);
  } catch (err) {
    if (err instanceof ApiError && (err.status === 401 || err.status === 403)) {
      return null;
    }
    throw err;
  }
});

/**
 * Bir sayfanın asıl verisini çekmeden ÖNCE çağrılır: kullanıcının rolünde
 * (Roller & Yetkiler) bu izin yoksa kendi ana sayfasına yönlendirilir.
 * Menü zaten bu bölümü gizler (bkz. lib/nav.ts); bu, URL'e doğrudan
 * girildiğinde backend'in 403'ünün sayfayı çökertmesini önleyen güvenlik
 * ağıdır -- asıl yetki sınırı yine backend'dedir.
 */
export async function requirePagePermission(code: string): Promise<User> {
  const user = await getCurrentUser();
  if (!user) redirect("/giris");
  if (!canAccess(user, code)) redirect(homeFor(user.role));
  return user;
}

/**
 * Yönetici kabuğu izin tabanlı sayfalar için Sahip/Yönetici dışındaki
 * üyelere de açıktır (bkz. lib/route-policy.ts); izin kodu olmayan ve
 * backend'de yalnızca kaba requireAdmin ile korunan sayfalar (Özet, Firma
 * Ayarları) bunu çağırır.
 */
export async function requireAdminRole(): Promise<User> {
  const user = await getCurrentUser();
  if (!user) redirect("/giris");
  if (user.role !== "admin") redirect(homeFor(user.role));
  return user;
}
