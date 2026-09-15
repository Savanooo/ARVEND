import { NextResponse } from "next/server";
import type { NextRequest } from "next/server";

/*
 * Next.js 16'da "middleware.ts" kaldırıldı, yerine "proxy.ts" geldi (bkz.
 * node_modules/next/dist/docs/.../proxy.md). Burada yalnızca HIZLI bir ön
 * kontrol yapılır: access_token cookie'sindeki JWT'nin imzası DOĞRULANMAZ,
 * sadece "role" claim'i okunup UX amaçlı yönlendirme yapılır (yanlış role
 * giden kullanıcı doğru sayfaya gitsin diye). Gerçek yetkilendirme sınırı
 * her zaman Go backend'deki RequireRole middleware'idir -- burada JWT
 * tamperlanmış olsa bile hiçbir veri sızmaz, backend isteği zaten 401/403
 * ile reddeder.
 */

interface AccessClaims {
  role?: "admin" | "kullanici" | "super_admin";
}

function decodeRole(token: string): AccessClaims["role"] {
  try {
    const payload = token.split(".")[1];
    const json = JSON.parse(
      Buffer.from(payload, "base64url").toString("utf-8")
    );
    return json.role;
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

  const role = decodeRole(token);
  // SUPER ADMIN ile organization Admin KESİNLİKLE aynı şey değildir --
  // biri diğerinin sayfasına yanlışlıkla düşerse (rol claim'i tamperlanmış
  // olsa bile, gerçek sınır her zaman backend'deki RequireRole'dür) en
  // azından kendi platformuna geri yönlendirilir.
  if (pathname.startsWith("/admin") && role !== "admin") {
    return NextResponse.redirect(new URL(role === "super_admin" ? "/super-admin" : "/panel", request.url));
  }
  if (pathname.startsWith("/super-admin") && role !== "super_admin") {
    return NextResponse.redirect(new URL(role === "admin" ? "/admin" : "/panel", request.url));
  }

  return NextResponse.next();
}

export const config = {
  matcher: ["/admin/:path*", "/panel/:path*", "/super-admin/:path*"],
};
