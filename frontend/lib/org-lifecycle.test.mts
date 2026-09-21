import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { canTransition, orgLifecycleActions } from "./org-lifecycle.ts";
import type { OrgStatus } from "./types.ts";

const ALL: OrgStatus[] = ["trial", "active", "suspended", "cancelled"];

describe("firma yaşam döngüsü (backend CanTransitionTo aynası)", () => {
  it("izin verilen geçişler backend tablosuyla aynı", () => {
    assert.deepEqual(orgLifecycleActions("trial").map((a) => a.target), ["active", "suspended", "cancelled"]);
    assert.deepEqual(orgLifecycleActions("active").map((a) => a.target), ["suspended", "cancelled"]);
    assert.deepEqual(orgLifecycleActions("suspended").map((a) => a.target), ["active", "cancelled"]);
    assert.deepEqual(orgLifecycleActions("cancelled").map((a) => a.target), ["active"]);
  });

  it("hiçbir durumdan trial'a dönülmez ve aynı duruma geçiş sunulmaz", () => {
    for (const s of ALL) {
      assert.equal(canTransition(s, "trial"), false, `${s} -> trial`);
      assert.equal(canTransition(s, s), false, `${s} -> ${s}`);
      assert.equal(
        orgLifecycleActions(s).some((a) => a.target === "trial" || a.target === s),
        false
      );
    }
  });

  it("silme/arşiv-silme diye bir aksiyon yoktur; iptal ve askı 'tehlikeli' onay ister", () => {
    for (const s of ALL) {
      for (const a of orgLifecycleActions(s)) {
        assert.equal(/sil|delete|kalıcı/i.test(a.label), false, a.label);
        if (a.target === "suspended" || a.target === "cancelled") assert.equal(a.danger, true, a.label);
        if (a.target === "active") assert.equal(a.danger, false, a.label);
      }
    }
  });

  it("kalıcı kart düğmesi hiyerarşisi: yalnızca İptal Et 'danger' görünür, Askıya Al nötr kalır", () => {
    for (const s of ALL) {
      for (const a of orgLifecycleActions(s)) {
        if (a.target === "active") assert.equal(a.buttonVariant, "primary", a.label);
        if (a.target === "suspended") assert.equal(a.buttonVariant, "secondary", a.label);
        if (a.target === "cancelled") assert.equal(a.buttonVariant, "danger", a.label);
      }
    }
  });

  it("askı/iptalden çıkış 'Yeniden Aktifleştir', denemeden çıkış 'Aktifleştir'", () => {
    assert.equal(orgLifecycleActions("suspended").find((a) => a.target === "active")?.label, "Yeniden Aktifleştir");
    assert.equal(orgLifecycleActions("cancelled").find((a) => a.target === "active")?.label, "Yeniden Aktifleştir");
    assert.equal(orgLifecycleActions("trial").find((a) => a.target === "active")?.label, "Aktifleştir");
  });
});
