import assert from "node:assert/strict";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, resolve } from "node:path";
import { describe, it } from "node:test";

import { userRoleLabel } from "./types.ts";

// Platform (Süper Admin) arayüzünün kaynak dosyaları üzerinde statik
// koruma: hiçbir kalıcı silme aksiyonu ve hiçbir tenant operasyon
// navigasyonu içermez. Bu, ürün kuralının ("kayıtlar silinmez, yaşam
// döngüsü durumlarıyla yönetilir") regresyona karşı testidir.

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

  it("hiçbir platform ekranı HTTP DELETE çağırmaz ve 'Sil' aksiyonu sunmaz", () => {
    for (const f of files) {
      const src = readFileSync(f, "utf8");
      assert.equal(/method:\s*["']DELETE["']/.test(src), false, `${f}: DELETE isteği`);
      assert.equal(/>\s*(Sil|Kalıcı Olarak Sil|Firmayı Sil|Kullanıcıyı Sil)\s*</.test(src), false, `${f}: silme düğmesi`);
    }
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
