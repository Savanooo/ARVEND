import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  WHATS_NEW_MAX_ITEMS,
  WHATS_NEW_RELEASES,
  hasUnseenRelease,
  latestWhatsNew,
  whatsNewSeenKey,
  whatsNewSince,
  type WhatsNewRelease,
  type WhatsNewViewer,
} from "./whats-new.ts";

const everyone: WhatsNewViewer = { can: () => true, trialOwnerAdmin: true };
const nobody: WhatsNewViewer = { can: () => false, trialOwnerAdmin: false };

const releases: WhatsNewRelease[] = [
  {
    key: "r3",
    label: "Üç",
    items: [
      { icon: "catalog", title: "c", body: "c", permission: "offers.create" },
      { icon: "trial", title: "t", body: "t", trialOwnerAdminOnly: true },
    ],
  },
  { key: "r2", label: "İki", items: [{ icon: "expenses", title: "b", body: "b" }] },
  { key: "r1", label: "Bir", items: [{ icon: "person", title: "a", body: "a" }] },
];

describe("Yenilikler (web)", () => {
  it("içerik: benzersiz anahtar, her yayında madde, kısa metin", () => {
    const keys = WHATS_NEW_RELEASES.map((r) => r.key);
    assert.equal(new Set(keys).size, keys.length);
    for (const r of WHATS_NEW_RELEASES) {
      assert.ok(r.items.length > 0, r.key);
      for (const item of r.items) {
        assert.ok(item.title.split(" ").length <= 5, item.title);
        assert.ok(item.body.length <= 130, item.body);
      }
    }
  });

  it("en yeni yayın görüldüyse hiçbir şey çıkmaz", () => {
    assert.equal(hasUnseenRelease("r3", releases), false);
    assert.equal(whatsNewSince("r3", everyone, releases), null);
  });

  it("hiç kayıt yoksa yalnızca en yeni yayın", () => {
    const notes = whatsNewSince(null, everyone, releases);
    assert.equal(notes?.key, "r3");
    assert.deepEqual(notes?.items.map((i) => i.title), ["c", "t"]);
  });

  it("atlanan yayınlar en yeni önce birleşir; anahtar en yeninin", () => {
    const notes = whatsNewSince("r1", everyone, releases);
    assert.equal(notes?.key, "r3");
    assert.equal(notes?.label, "Üç");
    assert.deepEqual(notes?.items.map((i) => i.title), ["c", "t", "b"]);
  });

  it("bilinmeyen (silinmiş) anahtar en yeni yayını gösterir", () => {
    assert.deepEqual(whatsNewSince("eski", everyone, releases)?.items.map((i) => i.title), ["c", "t"]);
  });

  it("izni olmayan ve deneme dışındaki kişiye ilgili madde düşer", () => {
    const fieldUser: WhatsNewViewer = { can: (p) => p !== "offers.create", trialOwnerAdmin: false };
    assert.equal(whatsNewSince(null, fieldUser, releases), null);
    assert.deepEqual(whatsNewSince("r1", fieldUser, releases)?.items.map((i) => i.title), ["b"]);
    assert.equal(whatsNewSince(null, nobody, releases), null);
  });

  it("madde sayısı sınırlı", () => {
    const many: WhatsNewRelease[] = [
      {
        key: "x",
        label: "X",
        items: Array.from({ length: WHATS_NEW_MAX_ITEMS + 3 }, (_, i) => ({ icon: "catalog" as const, title: `m${i}`, body: "b" })),
      },
    ];
    assert.equal(whatsNewSince(null, everyone, many)?.items.length, WHATS_NEW_MAX_ITEMS);
  });

  it("menüden açılan: görebileceği maddesi olan en yeni yayın", () => {
    assert.equal(latestWhatsNew(everyone, releases)?.key, "r3");
    const fieldUser: WhatsNewViewer = { can: (p) => p !== "offers.create", trialOwnerAdmin: false };
    assert.equal(latestWhatsNew(fieldUser, releases)?.key, "r2");
    assert.equal(latestWhatsNew({ can: () => false, trialOwnerAdmin: false }, [releases[0]]), null);
  });

  it("gerçek içerik: Sahip hepsini, Saha yalnızca kendi maddelerini görür", () => {
    const owner = whatsNewSince(null, everyone);
    assert.ok(owner && owner.items.length > 0 && owner.items.length <= WHATS_NEW_MAX_ITEMS);
    const field: WhatsNewViewer = {
      can: (p) => ["projects.tasks.read", "projects.tasks.update", "projects.expenses.create"].includes(p),
      trialOwnerAdmin: false,
    };
    const titles = whatsNewSince(null, field)?.items.map((i) => i.title) ?? [];
    assert.deepEqual(titles, ["Masrafta KDV ve Masraflarım", "Görev notları"]);
  });

  it("görüldü kaydı kişi başına", () => {
    assert.equal(whatsNewSeenKey("u1"), "arvend.whats_new.web.last_seen.u1");
  });
});
