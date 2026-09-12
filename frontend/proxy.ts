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
  role?: "admin" | "kullanici";
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
  if (pathname.startsWith("/admin") && role !== "admin") {
    return NextResponse.redirect(new URL("/panel", request.url));
  }

  return NextResponse.next();
}

export const config = {
  matcher: ["/admin/:path*", "/panel/:path*"],
};
