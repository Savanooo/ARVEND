import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { getNavItems, getPlatformNavItems } from "./nav.ts";
import { isPlatformPath, isTenantPath } from "./route-policy.ts";

// Süper Admin kabuğunda ASLA görünmemesi gereken tenant modül etiketleri.
const TENANT_LABELS = ["Teklifler", "Projeler", "Müşteriler", "Mesai", "Metraj", "Tedarik", "Taşeron", "Personel", "Ürünler"];

describe("getNavItems", () => {
  it("super_admin yalnızca platform öğelerini görür, hiçbir tenant modülü yok", () => {
    const items = getNavItems("super_admin");
    assert.deepEqual(items, getPlatformNavItems());
    assert.ok(items.length > 0);
    for (const item of items) {
      assert.ok(isPlatformPath(item.href), `${item.href} platform rotası olmalı`);
      assert.equal(isTenantPath(item.href), false, `${item.href} tenant rotası OLMAMALI`);
      for (const label of TENANT_LABELS) {
        assert.equal(item.label.includes(label), false, `platform menüsünde "${label}" olmamalı`);
      }
    }
  });

  it("organizasyon admin: iş modülleri + firma yönetimi, platform öğesi yok", () => {
    const hrefs = getNavItems("admin").map((i) => i.href);
    for (const h of ["/admin", "/teklifler", "/projeler", "/musteriler", "/mesai", "/admin/kullanicilar", "/admin/roller"]) {
      assert.ok(hrefs.includes(h), `admin menüsünde ${h} olmalı`);
    }
    assert.equal(hrefs.some(isPlatformPath), false, "admin menüsünde platform rotası olmamalı");
  });

  it("operasyonel kullanıcı: iş modülleri var, /admin/* ve platform yok", () => {
    const hrefs = getNavItems("kullanici").map((i) => i.href);
    for (const h of ["/panel", "/teklifler", "/projeler", "/musteriler", "/mesai"]) {
      assert.ok(hrefs.includes(h), `kullanici menüsünde ${h} olmalı`);
    }
    assert.equal(hrefs.some((h) => h === "/admin" || h.startsWith("/admin/")), false);
    assert.equal(hrefs.some(isPlatformPath), false);
  });
});
