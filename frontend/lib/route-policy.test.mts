import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  homeFor,
  isPlatformPath,
  isTenantPath,
  loginDestination,
  nextDestination,
  resolveRoleRedirect,
  safeNextPath,
} from "./route-policy.ts";
import type { User } from "./types.ts";

// Çalıştırma: npm test  (node --test "lib/**/*.test.mts") -- Next'siz.

function user(overrides: Partial<User>): User {
  return {
    id: "u1",
    organization_id: "org1",
    organization_name: "Test Firma",
    username: "u",
    full_name: "U",
    role: "admin",
    must_change_password: false,
    onboarding_completed: true,
    onboarding_step: "completed",
    ...overrides,
  };
}

const TENANT_PATHS = [
  "/teklifler",
  "/teklifler/abc",
  "/projeler",
  "/projeler/p1/finans",
  "/musteriler",
  "/mesai",
  "/admin",
  "/admin/urunler",
  "/panel",
  "/panel/profil",
  "/kurulum",
  "/sifre-belirle",
];

const PLATFORM_PATHS = ["/super-admin", "/super-admin/yeni", "/super-admin/planlar", "/super-admin/org-id"];

describe("nextDestination (giriş sonrası hedef)", () => {
  it("super_admin -> /super-admin; şifre/onboarding bayraklarından bağımsız, /panel'e DÜŞMEZ", () => {
    assert.equal(nextDestination(user({ role: "super_admin", organization_id: null })), "/super-admin");
    assert.equal(
      nextDestination(user({ role: "super_admin", organization_id: null, must_change_password: true, onboarding_completed: false })),
      "/super-admin"
    );
  });

  it("organizasyon admin: şifre belirleme -> firma kurulumu -> /admin sırası", () => {
    assert.equal(nextDestination(user({ must_change_password: true, onboarding_completed: false })), "/sifre-belirle");
    assert.equal(nextDestination(user({ onboarding_completed: false })), "/kurulum");
    assert.equal(nextDestination(user({})), "/admin");
  });

  it("operasyonel kullanıcı hazırsa -> /panel", () => {
    assert.equal(nextDestination(user({ role: "kullanici" })), "/panel");
    assert.equal(nextDestination(user({ role: "kullanici", must_change_password: true })), "/sifre-belirle");
  });
});

describe("resolveRoleRedirect (proxy/layout ortak karar)", () => {
  it("super_admin her tenant rotasından /super-admin'e yönlendirilir", () => {
    for (const p of TENANT_PATHS) {
      assert.equal(resolveRoleRedirect(p, "super_admin"), "/super-admin", p);
    }
  });

  it("super_admin platform rotalarında serbesttir", () => {
    for (const p of PLATFORM_PATHS) {
      assert.equal(resolveRoleRedirect(p, "super_admin"), null, p);
    }
  });

  it("organizasyon hesapları /super-admin'e giremez, kendi ana sayfasına döner", () => {
    for (const p of PLATFORM_PATHS) {
      assert.equal(resolveRoleRedirect(p, "admin"), "/admin", p);
      assert.equal(resolveRoleRedirect(p, "kullanici"), "/panel", p);
      assert.equal(resolveRoleRedirect(p, undefined), "/panel", `${p} (çözülemeyen rol)`);
    }
  });

  it("tenant hesapları kendi iş rotalarında serbesttir; kullanici /admin'e giremez", () => {
    for (const p of ["/teklifler", "/projeler/p1", "/musteriler", "/mesai", "/kurulum", "/sifre-belirle"]) {
      assert.equal(resolveRoleRedirect(p, "admin"), null, p);
      assert.equal(resolveRoleRedirect(p, "kullanici"), null, p);
    }
    assert.equal(resolveRoleRedirect("/admin", "admin"), null);
    assert.equal(resolveRoleRedirect("/admin/kullanicilar", "kullanici"), "/panel");
    assert.equal(resolveRoleRedirect("/panel/profil", "kullanici"), null);
  });

  it("izne bağlı yönetim bölümleri kullanici'ye açık (sayfa kendi iznini doğrular), Sahip/Yönetici bölümleri kapalı", () => {
    for (const p of [
      "/admin/urunler",
      "/admin/urunler/yeni",
      "/admin/metraj-hesaplama/g1/c1",
      "/admin/personel",
      "/admin/personel/e1",
      "/admin/maliyet-kodlari",
      "/admin/tedarikciler",
    ]) {
      assert.equal(resolveRoleRedirect(p, "kullanici"), null, p);
      assert.equal(resolveRoleRedirect(p, "admin"), null, p);
    }
    for (const p of [
      "/admin",
      "/admin/kullanicilar",
      "/admin/kullanicilar/yeni",
      "/admin/roller",
      "/admin/firma-ayarlari",
      "/admin/ayarlar",
      "/admin/urunlerx",
      "/admin/personelx",
    ]) {
      assert.equal(resolveRoleRedirect(p, "kullanici"), "/panel", p);
    }
    assert.equal(resolveRoleRedirect("/admin/personel", "super_admin"), "/super-admin");
  });
});

describe("yol sınıflandırma", () => {
  it("önek eşleşmesi segment sınırına saygı duyar", () => {
    assert.equal(isTenantPath("/tekliflerx"), false);
    assert.equal(isTenantPath("/teklifler"), true);
    assert.equal(isPlatformPath("/super-adminx"), false);
    assert.equal(isPlatformPath("/super-admin/yeni"), true);
  });

  it("homeFor rol -> kabuk ana sayfası", () => {
    assert.equal(homeFor("super_admin"), "/super-admin");
    assert.equal(homeFor("admin"), "/admin");
    assert.equal(homeFor("kullanici"), "/panel");
  });
});

describe("safeNextPath (giriş sonrası dönüş yolu)", () => {
  it("uygulama içi göreli yolu sorgu/hash ile korur", () => {
    assert.equal(safeNextPath("/projeler/p1?tab=finans"), "/projeler/p1?tab=finans");
    assert.equal(safeNextPath(["/teklifler", "/mesai"]), "/teklifler");
  });

  it("açık yönlendirme ve giriş döngüsü reddedilir", () => {
    for (const bad of [
      "//evil.com/x",
      "/\\evil.com",
      "https://evil.com",
      "javascript:alert(1)",
      "projeler",
      "",
      "/giris",
      "/giris?next=/x",
      "/giris/",
    ]) {
      assert.equal(safeNextPath(bad), null, bad);
    }
    assert.equal(safeNextPath(undefined), null);
    assert.equal(safeNextPath(null), null);
  });
});

describe("loginDestination", () => {
  it("hazır kullanıcı kendi kabuğundaki next'e döner", () => {
    assert.equal(loginDestination(user({}), "/projeler/p1?tab=finans"), "/projeler/p1?tab=finans");
    assert.equal(loginDestination(user({ role: "kullanici" }), "/admin/urunler"), "/admin/urunler");
    assert.equal(
      loginDestination(user({ role: "super_admin", organization_id: null }), "/super-admin/org1"),
      "/super-admin/org1"
    );
  });

  it("zorunlu akış next'ten önce gelir", () => {
    assert.equal(loginDestination(user({ must_change_password: true }), "/projeler/p1"), "/sifre-belirle");
    assert.equal(loginDestination(user({ onboarding_completed: false }), "/projeler/p1"), "/kurulum");
  });

  it("başka kabuğun ya da yetkisiz bölümün yolu yok sayılır", () => {
    assert.equal(loginDestination(user({ role: "kullanici" }), "/admin/kullanicilar"), "/panel");
    assert.equal(loginDestination(user({}), "/super-admin"), "/admin");
    assert.equal(loginDestination(user({ role: "super_admin", organization_id: null }), "/projeler/p1"), "/super-admin");
    assert.equal(loginDestination(user({}), "/paylas/abc"), "/admin");
    assert.equal(loginDestination(user({}), null), "/admin");
  });
});
