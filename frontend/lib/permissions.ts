// Saf (next/* içermeyen) izin yardımcıları -- hem Server Component'ler
// (lib/auth.ts requirePagePermission) hem sidebar (lib/nav.ts) hem de node
// testleri (nav.test.mts) tarafından içe aktarılabilir.
//
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
