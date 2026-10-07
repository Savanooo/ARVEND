import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { hoursBetween, initialTimes, resolveWorkHours, statusHasHours, withTimeChange } from "./attendance.ts";

// Çalıştırma: npm test  (node --test "lib/**/*.test.mts") -- Next'siz.

describe("hoursBetween (mobil ile aynı kural)", () => {
  it("düz fark, mola düşülmez", () => {
    assert.equal(hoursBetween("08:00", "17:00"), 9);
    assert.equal(hoursBetween("08:30", "12:00"), 3.5);
    assert.equal(hoursBetween("8:10", "17:00"), 8.83);
  });

  it("geçersiz ya da ters aralık null", () => {
    assert.equal(hoursBetween("17:00", "08:00"), null);
    assert.equal(hoursBetween("08:00", "08:00"), null);
    assert.equal(hoursBetween("", "17:00"), null);
    assert.equal(hoursBetween("24:00", "25:00"), null);
    assert.equal(hoursBetween("08:00", "17:60"), null);
  });
});

describe("form saatleri", () => {
  it("yeni kayıt mobil gibi 08:00-17:00 ve 9 saatle başlar; düzenlemede kayıtlı değerler korunur", () => {
    assert.deepEqual(initialTimes(), { check_in: "08:00", check_out: "17:00", work_hours: "9", hoursEdited: false });
    assert.deepEqual(initialTimes({ check_in: "09:00", check_out: "13:00", work_hours: 3.5 }), {
      check_in: "09:00",
      check_out: "13:00",
      work_hours: "3.5",
      hoursEdited: false,
    });
  });

  it("giriş/çıkış değişince saat yeniden hesaplanır, elle girilmiş saate dokunulmaz", () => {
    const t = withTimeChange(initialTimes(), { check_out: "12:00" });
    assert.equal(t.work_hours, "4");
    const edited = { ...t, work_hours: "5", hoursEdited: true };
    assert.equal(withTimeChange(edited, { check_out: "18:00" }).work_hours, "5");
  });

  it("boş saat kutusu 0 değil giriş-çıkıştan hesaplanır; virgül ondalık okunur", () => {
    assert.equal(resolveWorkHours({ check_in: "08:00", check_out: "17:00", work_hours: "", hoursEdited: true }), 9);
    assert.equal(resolveWorkHours({ check_in: "", check_out: "", work_hours: "", hoursEdited: false }), 0);
    assert.equal(resolveWorkHours({ check_in: "08:00", check_out: "17:00", work_hours: "7,5", hoursEdited: true }), 7.5);
  });
});

describe("statusHasHours", () => {
  it("yalnızca geldi ve yarım gün saat taşır", () => {
    assert.equal(statusHasHours("geldi"), true);
    assert.equal(statusHasHours("yarım gün"), true);
    assert.equal(statusHasHours("gelmedi"), false);
    assert.equal(statusHasHours("izinli"), false);
  });
});
