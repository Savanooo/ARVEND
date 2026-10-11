import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  orgTrialBadge,
  trialNoticeDismissKey,
  trialNoticeDismissedToday,
  trialNoticeFor,
} from "./trial.ts";

const owner = {
  organization_role_code: "owner",
  organization_status: "trial" as const,
  trial_ends_on: "2026-10-12",
  trial_days_left: 3,
  trial_expired: false,
};

describe("deneme uyarısı (mobil trialNoticeFor aynası)", () => {
  it("yalnızca Sahip/Yönetici görür", () => {
    assert.ok(trialNoticeFor(owner));
    assert.ok(trialNoticeFor({ ...owner, organization_role_code: "admin" }));
    for (const role of ["project_manager", "finance", "field", "ozel_rol", undefined]) {
      assert.equal(trialNoticeFor({ ...owner, organization_role_code: role }), null, String(role));
    }
  });

  it("deneme dışındaki firmada ya da gün bilgisi yokken hiçbir şey yok", () => {
    assert.equal(trialNoticeFor(null), null);
    assert.equal(trialNoticeFor({ ...owner, organization_status: "active" }), null);
    assert.equal(trialNoticeFor({ ...owner, organization_status: undefined }), null);
    assert.equal(trialNoticeFor({ ...owner, trial_days_left: undefined }), null);
  });

  it("7 gün ve daha azında kalan gün, son gün 'bugün bitiyor'", () => {
    assert.equal(trialNoticeFor({ ...owner, trial_days_left: 8 }), null);
    assert.deepEqual(trialNoticeFor({ ...owner, trial_days_left: 7 }), {
      expired: false,
      text: "Deneme süreniz 7 gün sonra bitiyor.",
    });
    assert.equal(trialNoticeFor({ ...owner, trial_days_left: 1 })?.text, "Deneme süreniz 1 gün sonra bitiyor.");
    assert.deepEqual(trialNoticeFor({ ...owner, trial_days_left: 0 }), {
      expired: false,
      text: "Deneme süreniz bugün bitiyor.",
    });
  });

  it("süre dolunca bitiş tarihiyle hata uyarısı (erişim kesilmez, yalnızca söylenir)", () => {
    assert.deepEqual(trialNoticeFor({ ...owner, trial_days_left: -2, trial_expired: true, trial_ends_on: "2026-10-07" }), {
      expired: true,
      text: "Deneme süreniz 07.10.2026 tarihinde bitti. Devam etmek için ARVEND ile iletişime geçin.",
    });
    assert.equal(
      trialNoticeFor({ ...owner, trial_days_left: -2, trial_expired: true, trial_ends_on: undefined })?.text,
      "Deneme süreniz bitti. Devam etmek için ARVEND ile iletişime geçin."
    );
  });

  it("'bugün için kapat' yalnızca o İstanbul günü geçerli", () => {
    assert.equal(trialNoticeDismissKey("org1", "u1"), "arvend.home.trial_notice.dismissed.org1.u1");
    // 2026-10-09 21:30 UTC = 10 Ekim 00:30 İstanbul.
    const lateEvening = new Date("2026-10-09T21:30:00Z");
    assert.equal(trialNoticeDismissedToday("2026-10-10", lateEvening), true);
    assert.equal(trialNoticeDismissedToday("2026-10-09", lateEvening), false);
    assert.equal(trialNoticeDismissedToday(null, lateEvening), false);
  });
});

describe("Süper Admin deneme rozeti", () => {
  const now = new Date("2026-10-09T09:00:00Z"); // 9 Ekim, İstanbul

  it("deneme dışındaki ya da bitiş tarihi olmayan firmada rozet yok", () => {
    assert.equal(orgTrialBadge({ status: "active", trial_ends_at: "2026-10-20T10:00:00Z" }, now), null);
    assert.equal(orgTrialBadge({ status: "trial", trial_ends_at: null }, now), null);
    assert.equal(orgTrialBadge({ status: "trial" }, now), null);
    assert.equal(orgTrialBadge({ status: "trial", trial_ends_at: "bozuk" }, now), null);
  });

  it("kalan gün İstanbul takvim günüyle sayılır", () => {
    assert.deepEqual(orgTrialBadge({ status: "trial", trial_ends_at: "2026-10-30T12:00:00Z" }, now), {
      label: "21 gün kaldı",
      tone: "muted",
      daysLeft: 21,
      endsOn: "2026-10-30",
    });
    assert.deepEqual(orgTrialBadge({ status: "trial", trial_ends_at: "2026-10-16T08:00:00Z" }, now), {
      label: "7 gün kaldı",
      tone: "gold",
      daysLeft: 7,
      endsOn: "2026-10-16",
    });
    // 9 Ekim 22:30 UTC = 10 Ekim 01:30 İstanbul -> 1 gün.
    assert.equal(orgTrialBadge({ status: "trial", trial_ends_at: "2026-10-09T22:30:00Z" }, now)?.label, "1 gün kaldı");
  });

  it("bitiş günü 'bugün bitiyor', geçtiyse 'deneme bitti'", () => {
    assert.deepEqual(orgTrialBadge({ status: "trial", trial_ends_at: "2026-10-09T05:00:00+03:00" }, now), {
      label: "Bugün bitiyor",
      tone: "gold",
      daysLeft: 0,
      endsOn: "2026-10-09",
    });
    assert.deepEqual(orgTrialBadge({ status: "trial", trial_ends_at: "2026-10-01T10:00:00Z" }, now), {
      label: "Deneme bitti",
      tone: "danger",
      daysLeft: -8,
      endsOn: "2026-10-01",
    });
  });
});
