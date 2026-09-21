import assert from "node:assert/strict";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, resolve } from "node:path";
import { describe, it } from "node:test";

import { userRoleLabel } from "./types.ts";

// Platform (Süper Admin) arayüzünün kaynak dosyaları üzerinde statik
// koruma: hiçbir tenant operasyon navigasyonu içermez ve "Sil" aksiyonları
// (bilinçli olarak MEVCUTTUR -- "Kullanıcıyı Sil"/"Firmayı Sil", bkz.
// backend/db/migrations/0043) HER ZAMAN YUMUŞAK silmedir: gerçek bir HTTP
// DELETE isteği ASLA kullanılmaz (yalnızca POST .../delete eylem-fiili) ve
// hiçbir etiket "kalıcı"/fiziksel bir kaldırma ima ETMEZ. Bu, ürün
// kuralının ("kayıtlar fiziksel olarak silinmez, yumuşak silme + geri
// yükleme ile yönetilir") regresyona karşı testidir.

const PLATFORM_DIR = resolve(import.meta.dirname, "..", "app", "(platform)");
const SHELL_FILE = resolve(import.meta.dirname, "..", "components", "layout", "PlatformShell.tsx");

function walk(dir: string): string[] {
  return readdirSync(dir).flatMap((name) => {
    const p = join(dir, name);
    return statSync(p).isDirectory() ? walk(p) : p.endsWith(".tsx") || p.endsWith(".ts") ? [p] : [];
  });
}

describe("platform arayüzü koruma kuralları", () => {
  const files = walk(PLATFORM_DIR);

  it("platform kaynaklarında en az bir dosya var", () => {
    assert.ok(files.length >= 5, `bulunan: ${files.length}`);
  });

  it("hiçbir platform ekranı HTTP DELETE metodunu çağırmaz ve hiçbir etiket 'kalıcı' silme ima etmez", () => {
    for (const f of files) {
      const src = readFileSync(f, "utf8");
      assert.equal(/method:\s*["']DELETE["']/.test(src), false, `${f}: HTTP DELETE isteği (yalnızca POST .../delete kullanılmalı)`);
      assert.equal(/kalıcı(\s+olarak)?\s+sil/i.test(src), false, `${f}: "kalıcı sil" ima eden etiket -- silme her zaman yumuşaktır`);
    }
  });

  it("kullanıcı ve firma silme aksiyonları MEVCUTTUR ve her ikisi de bir Geri Yükle karşılığına sahiptir", () => {
    const usersSrc = readFileSync(join(PLATFORM_DIR, "super-admin", "[id]", "UsersTab.tsx"), "utf8");
    assert.ok(/Kullanıcıyı Sil/.test(usersSrc), "UsersTab.tsx: 'Kullanıcıyı Sil' aksiyonu yok");
    assert.ok(usersSrc.includes("/delete`"), "UsersTab.tsx: /delete eylem ucu çağrılmıyor");
    assert.ok(usersSrc.includes("/restore`"), "UsersTab.tsx: /restore eylem ucu çağrılmıyor");
    assert.ok(/Geri Yükle/.test(usersSrc), "UsersTab.tsx: 'Geri Yükle' aksiyonu yok");

    const generalSrc = readFileSync(join(PLATFORM_DIR, "super-admin", "[id]", "GeneralTab.tsx"), "utf8");
    assert.ok(/Firmayı Sil/.test(generalSrc), "GeneralTab.tsx: 'Firmayı Sil' aksiyonu yok");
    assert.ok(generalSrc.includes("/delete`"), "GeneralTab.tsx: /delete eylem ucu çağrılmıyor");
    assert.ok(generalSrc.includes("/restore`"), "GeneralTab.tsx: /restore eylem ucu çağrılmıyor");
    assert.ok(/Geri Yükle/.test(generalSrc), "GeneralTab.tsx: 'Geri Yükle' aksiyonu yok");
    // Tehlikeli İşlemler, görev gereği durum/plan düğmelerinden AYRI,
    // kendi kartında olmalı (bkz. GeneralTab.tsx "Do not place it next to
    // normal plan/status buttons" yorumu) -- görsel ayrım tarayıcı
    // ekran görüntüleriyle doğrulanır, burada yalnızca kendi başlığının
    // gerçekten var olduğu doğrulanır.
    assert.ok(/CardHeader className="text-danger">Tehlikeli İşlemler/.test(generalSrc), "GeneralTab.tsx: ayrı bir 'Tehlikeli İşlemler' kartı yok");
  });

  it("platform ekranları tenant operasyon rotalarına link vermez", () => {
    for (const f of files) {
      const src = readFileSync(f, "utf8");
      for (const route of ['"/teklifler', '"/projeler', '"/musteriler', '"/mesai', '"/admin', '"/panel']) {
        assert.equal(src.includes(route), false, `${f}: ${route}`);
      }
    }
  });

  it("platform kabuğu yalnızca platform menüsünü kullanır", () => {
    const src = readFileSync(SHELL_FILE, "utf8");
    assert.ok(src.includes("getPlatformNavItems"));
    assert.equal(src.includes("getNavItems("), false);
  });

  it("platform kullanıcı tablosu kaba users.role'ü değil organizasyon rolünü gösterir", () => {
    const src = readFileSync(join(PLATFORM_DIR, "super-admin", "[id]", "UsersTab.tsx"), "utf8");
    assert.ok(src.includes("organization_role_name"));
    assert.equal(/u\.role === ["']admin["']/.test(src), false, "kaba rol etiketi kullanılmamalı");
  });
});

describe("kullanıcı rol terminolojisi", () => {
  it("platform hesabı her zaman Süper Admin, tenant hesabı organizasyon rolü", () => {
    assert.equal(userRoleLabel({ role: "super_admin" }), "Süper Admin");
    assert.equal(userRoleLabel({ role: "super_admin", organization_role_name: "Sahip (Owner)" }), "Süper Admin");
    assert.equal(userRoleLabel({ role: "admin", organization_role_name: "Sahip (Owner)" }), "Sahip (Owner)");
    assert.equal(userRoleLabel({ role: "kullanici", organization_role_name: "Proje Yöneticisi" }), "Proje Yöneticisi");
  });

  it("organizasyon rolü olmayan nadir kayıtta kaba etiket yedek olarak kalır", () => {
    assert.equal(userRoleLabel({ role: "admin" }), "Yönetici");
    assert.equal(userRoleLabel({ role: "kullanici", organization_role_name: "" }), "Kullanıcı");
  });
});
