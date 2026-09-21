import { NextResponse } from "next/server";
import type { NextRequest } from "next/server";

import { resolveRoleRedirect } from "@/lib/route-policy";
import type { Role } from "@/lib/types";

/*
 * Next.js 16'da "middleware.ts" kaldırıldı, yerine "proxy.ts" geldi (bkz.
 * node_modules/next/dist/docs/.../proxy.md). Burada yalnızca HIZLI bir ön
 * kontrol yapılır: access_token cookie'sindeki JWT'nin imzası DOĞRULANMAZ,
 * sadece "role" claim'i okunup UX amaçlı yönlendirme yapılır (yanlış role
 * giden kullanıcı doğru kabuğa gitsin diye). Gerçek yetkilendirme sınırı
 * her zaman Go backend'dir (RequireRole / RequireTenant) -- JWT tamperlanmış
 * olsa bile hiçbir veri sızmaz, backend isteği zaten 401/403 ile reddeder.
 * Karar tablosu lib/route-policy.ts'tedir; layout'lar da aynı kaynağı
 * kullanır (doğrudan URL girişi menü görünürlüğüne bağlı DEĞİLDİR).
 */

const VALID_ROLES: readonly Role[] = ["admin", "kullanici", "super_admin"];

function decodeRole(token: string): Role | undefined {
  try {
    const payload = token.split(".")[1];
    const json = JSON.parse(Buffer.from(payload, "base64url").toString("utf-8"));
    return VALID_ROLES.includes(json.role) ? (json.role as Role) : undefined;
  } catch {
    return undefined;
  }
}

export function proxy(request: NextRequest) {
  const { pathname } = request.nextUrl;
  const token = request.cookies.get("access_token")?.value;

  if (!token) {
    return NextResponse.redirect(new URL("/giris", request.url));
  }

  const target = resolveRoleRedirect(pathname, decodeRole(token));
  if (target) {
    return NextResponse.redirect(new URL(target, request.url));
  }
  return NextResponse.next();
}

export const config = {
  matcher: [
    "/super-admin/:path*",
    "/admin/:path*",
    "/panel/:path*",
    "/teklifler/:path*",
    "/projeler/:path*",
    "/musteriler/:path*",
    "/mesai/:path*",
    "/kurulum/:path*",
    "/sifre-belirle/:path*",
  ],
};
