import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  homeFor,
  isPlatformPath,
  isTenantPath,
  nextDestination,
  resolveRoleRedirect,
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
