// Saf (next/* içermeyen) izin yardımcıları -- hem Server Component'ler
// (lib/auth.ts requirePagePermission) hem sidebar (lib/nav.ts) hem de node
// testleri (nav.test.mts) tarafından içe aktarılabilir.
import type { Role } from "./types";

// Kodlar backend/internal/domain/authorization.go'daki Perm* sabitleriyle
// BİREBİR aynıdır ve her biri, ilgili sayfanın ilk yüklemede çağırdığı liste
// ucunun router.go'da GERÇEKTEN zorladığı okuma iznidir -- izin burada
// yanlış eşlenirse ya erişilebilir bir bölüm gizlenir ya da tıklanınca
// backend 403 döndüğü için sayfa çöker.
export const PAGE_PERMISSIONS = {
  offers: "offers.read",
  projects: "projects.read",
  attendance: "attendance.read",
  customers: "customers.read",
  products: "products.read",
  calculations: "calculations.read",
  employees: "employees.read",
  users: "organization.users.read",
  roles: "organization.roles.read",
  costCodes: "organization.cost_codes.read",
  suppliers: "organization.suppliers.read",
  smtpSettings: "organization.settings.read",
} as const;

export type PagePermission = (typeof PAGE_PERMISSIONS)[keyof typeof PAGE_PERMISSIONS];

// Fail-closed: izin kümesi yoksa (rolü atanmamış kullanıcı) izin YOK kabul
// edilir -- backend de bu durumda ilgili ucu 403 ile reddeder.
export function hasPermission(permissions: readonly string[] | undefined, code: string): boolean {
  return permissions?.includes(code) ?? false;
}

// Uçları izne EK OLARAK kaba requireAdmin kapısının arkasında duran izinler
// (router.go: kullanıcı yönetimi, Roller & Yetkiler, SMTP ayarları).
// Sahip/Yönetici dışındaki birinde bu izinler hiçbir işe yaramaz; backend
// kişiye özel eklenmelerini de reddeder. backend/internal/domain/
// authorization.go'daki adminRoleOnlyPermissions ile BİREBİR aynıdır.
export const ADMIN_ROLE_ONLY_PERMISSIONS: ReadonlySet<string> = new Set([
  "organization.users.read",
  "organization.users.manage",
  "organization.roles.read",
  "organization.roles.manage",
  "organization.settings.read",
  "organization.settings.manage",
]);

// Kaba rolü admin olan (Sahip/Yönetici) organizasyon rolleri --
// backend/internal/service/user_lifecycle.go coarseRoleForOrgRole ile aynı.
export function orgRoleIsAdmin(roleCode: string): boolean {
  return roleCode === "owner" || roleCode === "admin";
}

/**
 * Bir sayfaya/menü öğesine erişim: izin kümesinde olmalı VE izin
 * Yönetici'ye kilitliyse kullanıcı kaba rolde admin olmalı. Ürünler,
 * Personel, Metraj, Maliyet Kodları, Tedarikçiler gibi yalnızca izne bağlı
 * yönetim sayfaları böylece izni olan her üyeye açılır.
 */
export function canAccess(user: { role: Role; permissions?: readonly string[] }, code: string): boolean {
  if (ADMIN_ROLE_ONLY_PERMISSIONS.has(code) && user.role !== "admin") return false;
  return hasPermission(user.permissions, code);
}

// Bir yazma izninin (ör. offers.create, projects.finance.manage) aynı
// kaynağın görüntüleme iznine (offers.read, projects.finance.read) bağlı
// olduğu varsayılır: kaynak = kodun son noktaya kadarki kısmı.
function readSiblingOf(code: string, catalog: ReadonlySet<string>): string | null {
  const dot = code.lastIndexOf(".");
  if (dot < 0) return null;
  const read = `${code.slice(0, dot)}.read`;
  return read !== code && catalog.has(read) ? read : null;
}

/**
 * Detaylı yetki düzenleyicisinde bir kutucuğu çevirir ve kümeyi tutarlı
 * tutar: yazma izni açılınca görüntüleme izni de açılır; görüntüleme
 * kapatılınca ona bağlı yazma izinleri de kapanır. "Oluşturabilir ama
 * göremez" gibi kişiyi çıkmaz sayfalara düşüren kombinasyonlar oluşmaz.
 */
export function togglePermission(
  selected: ReadonlySet<string>,
  code: string,
  catalog: ReadonlySet<string>
): Set<string> {
  const next = new Set(selected);
  if (next.has(code)) {
    next.delete(code);
    for (const other of catalog) {
      if (readSiblingOf(other, catalog) === code) next.delete(other);
    }
  } else {
    next.add(code);
    const read = readSiblingOf(code, catalog);
    if (read) next.add(read);
  }
  return next;
}

/** Bir kategorinin tüm kutucuklarını açar/kapatır -- togglePermission ile AYNI tutarlılık kuralı. */
export function setPermissions(
  selected: ReadonlySet<string>,
  codes: readonly string[],
  on: boolean,
  catalog: ReadonlySet<string>
): Set<string> {
  let next = new Set(selected);
  for (const code of codes) {
    if (next.has(code) !== on) next = togglePermission(next, code, catalog);
  }
  return next;
}
