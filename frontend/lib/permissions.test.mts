import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { canAccess, hasPermission, orgRoleIsAdmin, setPermissions, togglePermission } from "./permissions.ts";

const CATALOG = new Set([
  "offers.read",
  "offers.create",
  "offers.update",
  "offers.internal_pricing.read",
  "offers.internal_pricing.manage",
  "projects.read",
  "projects.update",
  "projects.finance.read",
  "projects.finance.manage",
  "notifications.read",
]);

const sorted = (s: Set<string>) => [...s].sort();

describe("togglePermission — detaylı yetki kümesini tutarlı tutar", () => {
  it("yazma izni açılınca aynı kaynağın görüntüleme izni de açılır", () => {
    assert.deepEqual(sorted(togglePermission(new Set(), "offers.create", CATALOG)), ["offers.create", "offers.read"]);
    assert.deepEqual(sorted(togglePermission(new Set(), "projects.finance.manage", CATALOG)), [
      "projects.finance.manage",
      "projects.finance.read",
    ]);
  });

  it("görüntüleme kapatılınca yalnızca ona bağlı yazma izinleri kapanır", () => {
    const start = new Set(["offers.read", "offers.create", "offers.update", "offers.internal_pricing.read", "projects.read"]);
    assert.deepEqual(sorted(togglePermission(start, "offers.read", CATALOG)), ["offers.internal_pricing.read", "projects.read"]);
  });

  it("alt kaynak üst kaynağa bağlanmaz: projects.finance.manage, projects.read'i açmaz", () => {
    assert.equal(togglePermission(new Set(), "projects.finance.manage", CATALOG).has("projects.read"), false);
  });

  it("görüntüleme izninin kendisi açılıp kapanınca başka bir şey değişmez", () => {
    assert.deepEqual(sorted(togglePermission(new Set(), "notifications.read", CATALOG)), ["notifications.read"]);
    assert.deepEqual(sorted(togglePermission(new Set(["notifications.read"]), "notifications.read", CATALOG)), []);
  });

  it("girdi kümesini değiştirmez", () => {
    const start = new Set(["offers.read"]);
    togglePermission(start, "offers.create", CATALOG);
    assert.deepEqual(sorted(start), ["offers.read"]);
  });
});

describe("setPermissions — kategori toplu seçimi aynı kuralı izler", () => {
  it("kategoriyi kapatmak yalnızca ona bağlı yazma izinlerini kapatır, alt kaynaklara (finans) dokunmaz", () => {
    const start = new Set(["projects.read", "projects.update", "projects.finance.read", "projects.finance.manage"]);
    assert.deepEqual(sorted(setPermissions(start, ["projects.read", "projects.update"], false, CATALOG)), [
      "projects.finance.manage",
      "projects.finance.read",
    ]);
  });

  it("kategoriyi açmak yazma izinlerinin görüntüleme kardeşlerini de açar", () => {
    assert.deepEqual(sorted(setPermissions(new Set(), ["offers.create"], true, CATALOG)), ["offers.create", "offers.read"]);
  });
});

describe("hasPermission", () => {
  it("izin kümesi yoksa fail-closed", () => {
    assert.equal(hasPermission(undefined, "offers.read"), false);
    assert.equal(hasPermission(["offers.read"], "offers.read"), true);
  });
});

describe("canAccess (menü + sayfa koruması ortak kararı)", () => {
  it("izne bağlı yönetim sayfası: izni olan kullanici erişir, olmayan erişemez", () => {
    assert.equal(canAccess({ role: "kullanici", permissions: ["employees.read"] }, "employees.read"), true);
    assert.equal(canAccess({ role: "kullanici", permissions: [] }, "employees.read"), false);
  });

  it("Yönetici'ye kilitli izin: kullanici'de izin kümesinde olsa bile erişim yok, admin'de var", () => {
    for (const code of ["organization.users.read", "organization.roles.read", "organization.settings.read"]) {
      assert.equal(canAccess({ role: "kullanici", permissions: [code] }, code), false, code);
      assert.equal(canAccess({ role: "admin", permissions: [code] }, code), true, code);
      assert.equal(canAccess({ role: "admin", permissions: [] }, code), false, `${code} (revoke edilmiş Yönetici)`);
    }
  });

  it("kaba rolü admin olan organizasyon rolleri yalnızca Sahip ve Yönetici", () => {
    assert.deepEqual(
      ["owner", "admin", "project_manager", "finance", "field", "legacy_user"].filter(orgRoleIsAdmin),
      ["owner", "admin"]
    );
  });
});
