import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { getNavItems, getPlatformNavItems } from "./nav.ts";
import { ADMIN_ROLE_ONLY_PERMISSIONS, PAGE_PERMISSIONS } from "./permissions.ts";
import { isPlatformPath, isTenantPath, PERMISSION_GATED_ADMIN_PREFIXES, resolveRoleRedirect } from "./route-policy.ts";

// Süper Admin kabuğunda ASLA görünmemesi gereken tenant modül etiketleri.
const TENANT_LABELS = ["Teklifler", "Projeler", "Müşteriler", "Mesai & Maaş", "Metraj", "Tedarik", "Taşeron", "Personel", "Ürünler"];

// Bir rolün Roller & Yetkiler'de TÜM sayfa okuma izinlerine sahip olduğu durum.
const ALL_PAGE_PERMISSIONS = Object.values(PAGE_PERMISSIONS);

describe("getNavItems", () => {
  it("super_admin yalnızca platform öğelerini görür, hiçbir tenant modülü yok", () => {
    const items = getNavItems("super_admin", []);
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

  it("organizasyon admin (tüm izinler): iş modülleri + firma yönetimi, platform öğesi yok", () => {
    const hrefs = getNavItems("admin", ALL_PAGE_PERMISSIONS).map((i) => i.href);
    for (const h of ["/admin", "/teklifler", "/projeler", "/musteriler", "/mesai", "/admin/kullanicilar", "/admin/roller"]) {
      assert.ok(hrefs.includes(h), `admin menüsünde ${h} olmalı`);
    }
    assert.equal(hrefs.some(isPlatformPath), false, "admin menüsünde platform rotası olmamalı");
  });

  it("operasyonel kullanıcı (tüm izinler): iş modülleri + izne bağlı yönetim bölümleri; Sahip/Yönetici bölümleri ve platform yok", () => {
    const hrefs = getNavItems("kullanici", ALL_PAGE_PERMISSIONS).map((i) => i.href);
    for (const h of ["/panel", "/teklifler", "/projeler", "/musteriler", "/mesai", ...PERMISSION_GATED_ADMIN_PREFIXES]) {
      assert.ok(hrefs.includes(h), `kullanici menüsünde ${h} olmalı`);
    }
    for (const h of ["/admin", "/admin/kullanicilar", "/admin/roller", "/admin/firma-ayarlari", "/admin/ayarlar"]) {
      assert.equal(hrefs.includes(h), false, `kullanici menüsünde ${h} OLMAMALI`);
    }
    assert.equal(hrefs.some(isPlatformPath), false);
  });

  it("menüdeki her /admin öğesi kullanici için yönlendirme politikasından da geçer", () => {
    for (const { href } of getNavItems("kullanici", ALL_PAGE_PERMISSIONS)) {
      assert.equal(resolveRoleRedirect(href, "kullanici"), null, href);
    }
  });
});

describe("getNavItems — Roller & Yetkiler izin süzmesi", () => {
  it("Saha benzeri rol: izni olmayan Teklifler/Müşteriler GİZLENİR, izinli Projeler/Mesai görünür", () => {
    const hrefs = getNavItems("kullanici", [PAGE_PERMISSIONS.projects, PAGE_PERMISSIONS.attendance]).map((i) => i.href);
    assert.deepEqual(hrefs, ["/panel", "/projeler", "/mesai", "/panel/profil"]);
  });

  it("Ana Sayfa ve Profilim izinden bağımsız HER ZAMAN görünür", () => {
    const hrefs = getNavItems("kullanici", []).map((i) => i.href);
    assert.deepEqual(hrefs, ["/panel", "/panel/profil"]);
  });

  it("izin kümesi hiç yoksa (rol atanmamış) fail-closed: yalnızca izinsiz öğeler", () => {
    const hrefs = getNavItems("kullanici", undefined).map((i) => i.href);
    assert.deepEqual(hrefs, ["/panel", "/panel/profil"]);
  });

  it("admin kabuğu da süzülür: teklif okuma izni kaldırılan Yönetici Teklifler'i görmez", () => {
    const withoutOffers = ALL_PAGE_PERMISSIONS.filter((p) => p !== PAGE_PERMISSIONS.offers);
    const hrefs = getNavItems("admin", withoutOffers).map((i) => i.href);
    assert.equal(hrefs.includes("/teklifler"), false);
    assert.ok(hrefs.includes("/projeler"));
  });

  it("kişiye özel izinle Saha üyesi yalnızca izni olan yönetim bölümünü görür", () => {
    const hrefs = getNavItems("kullanici", [PAGE_PERMISSIONS.attendance, PAGE_PERMISSIONS.employees]).map((i) => i.href);
    assert.deepEqual(hrefs, ["/panel", "/mesai", "/admin/personel", "/panel/profil"]);
  });

  it("Yönetici'ye kilitli izinler kullanici menüsüne hiçbir öğe eklemez", () => {
    const hrefs = getNavItems("kullanici", [...ADMIN_ROLE_ONLY_PERMISSIONS]).map((i) => i.href);
    assert.deepEqual(hrefs, ["/panel", "/panel/profil"]);
  });

  it("Firma Ayarları backend'de yalnızca kaba requireAdmin ile korunur: izin kümesinden bağımsız görünür", () => {
    const hrefs = getNavItems("admin", []).map((i) => i.href);
    assert.deepEqual(hrefs, ["/admin", "/admin/firma-ayarlari"]);
  });

  it("döndürülen öğeler dahili izin alanını SIZDIRMAZ (Sidebar'a yalnızca href/label gider)", () => {
    for (const item of getNavItems("admin", ALL_PAGE_PERMISSIONS)) {
      assert.deepEqual(Object.keys(item).sort(), ["href", "label"]);
    }
  });
});
