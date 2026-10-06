import { NextResponse } from "next/server";
import type { NextRequest } from "next/server";

import { internalApiBase } from "@/lib/api";
import { LOGIN_PATH, resolveRoleRedirect, safeNextPath } from "@/lib/route-policy";
import {
  ACCESS_COOKIE,
  accessTokenState,
  createRefreshCoordinator,
  decodeJwtPayload,
  REFRESH_COOKIE,
  replaceCookies,
  requestRefresh,
} from "@/lib/session-refresh";
import type { Role } from "@/lib/types";

/*
 * Next.js 16'da "middleware.ts" kaldırıldı, yerine "proxy.ts" geldi (bkz.
 * node_modules/next/dist/docs/.../proxy.md). İki işi var:
 *
 * 1) Oturum yenileme. Access token 15 dk, refresh token 30 gün yaşar.
 *    Access çerezi yoksa/dolmuşsa ve refresh çerezi varsa backend'in
 *    /auth/refresh ucu BURADA, sayfa render edilmeden önce çağrılır: yeni
 *    çift Set-Cookie ile tarayıcıya, istek Cookie başlığıyla da aynı
 *    isteğin Server Component'lerine (apiServer) gider. Böylece boşta
 *    kalan kullanıcı /giris'e atılmaz. Geçerli access token'la gelen
 *    istekte refresh YAPILMAZ.
 *
 * 2) Hızlı rol yönlendirmesi. access_token'daki JWT'nin imzası
 *    DOĞRULANMAZ, yalnızca "role" claim'i okunur (yanlış role giden
 *    kullanıcı doğru kabuğa gitsin diye). Gerçek yetkilendirme sınırı her
 *    zaman Go backend'dir (RequireRole / RequireTenant) -- JWT tamperlanmış
 *    olsa bile veri sızmaz. Karar tablosu lib/route-policy.ts'tedir.
 *
 * Döngü yok: /giris yalnızca refresh'i dener, kendine yönlendirmez; başarısız
 * refresh hiçbir zaman tekrar refresh'e yönlendirmez.
 */

const VALID_ROLES: readonly Role[] = ["admin", "kullanici", "super_admin"];

function decodeRole(token: string): Role | undefined {
  const role = decodeJwtPayload(token)?.role;
  return VALID_ROLES.includes(role as Role) ? (role as Role) : undefined;
}

// Aynı süreçteki eşzamanlı istekler (belge + RSC + prefetch) aynı eski
// refresh token'la gelir; tek kullanımlık token'ı bir kez harcarlar.
const refreshOnce = createRefreshCoordinator({
  refresh: (token) => requestRefresh(internalApiBase(), token),
});

function withSetCookies(response: NextResponse, setCookies: readonly string[]): NextResponse {
  for (const line of setCookies) response.headers.append("set-cookie", line);
  return response;
}

function routeByRole(request: NextRequest, token: string, requestHeaders?: Headers): NextResponse {
  const target = resolveRoleRedirect(request.nextUrl.pathname, decodeRole(token));
  if (target) return NextResponse.redirect(new URL(target, request.url));
  return requestHeaders ? NextResponse.next({ request: { headers: requestHeaders } }) : NextResponse.next();
}

function loginRedirect(request: NextRequest): NextResponse {
  const { pathname, search } = request.nextUrl;
  const url = new URL(LOGIN_PATH, request.url);
  if (pathname !== "/") url.searchParams.set("next", `${pathname}${search}`);
  return NextResponse.redirect(url);
}

export async function proxy(request: NextRequest) {
  const onLogin = request.nextUrl.pathname === LOGIN_PATH;
  const current = request.cookies.get(ACCESS_COOKIE)?.value;
  const state = accessTokenState(current, Date.now());

  if (state === "fresh") {
    // /giris oturumu kendisi doğrular (getCurrentUser), burada imzasız
    // token'a bakıp yönlendirmek döngü riskidir.
    return onLogin ? NextResponse.next() : routeByRole(request, current!);
  }

  const refreshToken = request.cookies.get(REFRESH_COOKIE)?.value;
  const result = refreshToken ? await refreshOnce(refreshToken) : null;

  if (result?.ok) {
    if (onLogin) {
      const next = safeNextPath(request.nextUrl.searchParams.get("next")) ?? "/";
      return withSetCookies(NextResponse.redirect(new URL(next, request.url)), result.setCookies);
    }
    const headers = new Headers(request.headers);
    headers.set(
      "cookie",
      replaceCookies(request.headers.get("cookie"), {
        [ACCESS_COOKIE]: result.accessToken,
        [REFRESH_COOKIE]: result.refreshToken,
      })
    );
    return withSetCookies(routeByRole(request, result.accessToken, headers), result.setCookies);
  }

  // Refresh yok ya da başarısız. 401, başka bir sekmenin/isteğin aynı
  // token'ı az önce yenilemesinden (yarış) de gelebilir: backend'in çerez
  // temizleyen yanıtı iletilirse kazananın yeni çifti silinir ve HER sekme
  // düşer. Bu yüzden korumalı sayfada temizlik yalnızca kesin red (403:
  // pasif kullanıcı / askıdaki firma) için iletilir; 401'de kullanıcı
  // /giris?next=...'e gider -- çerezler o arada yenilendiyse giriş sayfası
  // oturumu tanır ve geri gönderir, yenilenmediyse /giris'teki ikinci deneme
  // eski çerezi temizler.
  const failed = result && !result.ok ? result : null;
  if (onLogin) {
    const clear = failed && (failed.status === 401 || failed.status === 403) ? failed.setCookies : [];
    return withSetCookies(NextResponse.next(), clear);
  }
  const clear = failed?.status === 403 ? failed.setCookies : [];
  if (state === "expiring") {
    // Hâlâ geçerli; geçici bir refresh hatası oturumu düşürmesin.
    return withSetCookies(routeByRole(request, current!), clear);
  }
  return withSetCookies(loginRedirect(request), clear);
}

export const config = {
  matcher: [
    "/",
    "/giris",
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
