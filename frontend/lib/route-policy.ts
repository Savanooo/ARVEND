import type { Role, User } from "./types";

/*
 * Platform / tenant rota politikası -- TEK kaynak. Next'e bağımlılığı YOK
 * (redirect/NextResponse burada değil) ki proxy.ts, layout'lar ve giriş
 * sayfası AYNI kararı kullansın ve node --test ile doğrudan test edilebilsin.
 *
 * Üç katman:
 *   A) super_admin  -> yalnızca /super-admin/** (platform yönetimi); hiçbir
 *      organizasyona bağlı değildir, tenant rotalarına ASLA girmez.
 *   B) admin        -> organizasyon Owner/Admin (Yönetici): /admin/** + iş
 *      rotaları (/teklifler, /projeler, /musteriler, /mesai).
 *   C) kullanici    -> operasyonel organizasyon kullanıcısı: /panel/** + iş
 *      rotaları (izinleri ölçüsünde).
 */

export const PLATFORM_HOME = "/super-admin";

export const TENANT_ROUTE_PREFIXES = [
  "/admin",
  "/panel",
  "/teklifler",
  "/projeler",
  "/musteriler",
  "/mesai",
  "/kurulum",
  "/sifre-belirle",
] as const;

function matchesPrefix(pathname: string, prefix: string): boolean {
  return pathname === prefix || pathname.startsWith(`${prefix}/`);
}

export function isPlatformPath(pathname: string): boolean {
  return matchesPrefix(pathname, PLATFORM_HOME);
}

export function isTenantPath(pathname: string): boolean {
  return TENANT_ROUTE_PREFIXES.some((prefix) => matchesPrefix(pathname, prefix));
}

export function homeFor(role: Role): string {
  if (role === "super_admin") return PLATFORM_HOME;
  return role === "admin" ? "/admin" : "/panel";
}

/**
 * Giriş sonrası (ve root "/") hedefi. super_admin ÖNCE ele alınır: ona
 * must-change-password/onboarding akışı uygulanmaz (organizasyonu yok, şifre
 * yönetimi CLI ile), /panel veya /teklifler'e DÜŞMEZ. Tenant kullanıcıları
 * için sıra: şifre belirleme -> firma kurulumu -> rol ana sayfası.
 */
export function nextDestination(user: User): string {
  if (user.role === "super_admin") return PLATFORM_HOME;
  if (user.must_change_password) return "/sifre-belirle";
  if (!user.onboarding_completed) return "/kurulum";
  return homeFor(user.role);
}

/**
 * Yol + rol için yönlendirme hedefi; yönlendirme gerekmiyorsa null.
 * proxy.ts'in hızlı ön kontrolü bunu kullanır (JWT imzası orada
 * doğrulanmaz, rol tamperlanmış olsa bile asıl sınır backend'dedir).
 */
export function resolveRoleRedirect(pathname: string, role: Role | undefined): string | null {
  if (role === "super_admin") {
    return isTenantPath(pathname) ? PLATFORM_HOME : null;
  }
  const fallbackRole: Role = role ?? "kullanici";
  if (isPlatformPath(pathname)) return homeFor(fallbackRole);
  if (matchesPrefix(pathname, "/admin") && role !== "admin") return homeFor(fallbackRole);
  return null;
}
