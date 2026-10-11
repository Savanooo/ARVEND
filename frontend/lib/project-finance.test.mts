import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { formatMoney } from "./format.ts";
import { canSeeProjectFinance, formatOptionalMoney, isMoney, NO_MONEY } from "./project-finance.ts";

describe("canSeeProjectFinance", () => {
  it("yalnızca projects.finance.read ile", () => {
    assert.equal(canSeeProjectFinance(["projects.read", "projects.finance.read"]), true);
    assert.equal(canSeeProjectFinance(["projects.read", "projects.cost_control.read"]), false);
    // finance.manage tek başına okuma değildir (backend de yalnızca read'e bakar).
    assert.equal(canSeeProjectFinance(["projects.finance.manage"]), false);
    assert.equal(canSeeProjectFinance(undefined), false);
    assert.equal(canSeeProjectFinance([]), false);
  });
});

describe("formatOptionalMoney", () => {
  it("tutar varsa formatMoney ile aynı", () => {
    assert.equal(formatOptionalMoney(12500, "TRY"), formatMoney(12500, "TRY"));
    assert.equal(formatOptionalMoney(0, "USD"), formatMoney(0, "USD"));
  });

  it("finans izni olmayana gelen null/eksik alan 0 ya da NaN değil — yazılır", () => {
    assert.equal(formatOptionalMoney(null, "TRY"), NO_MONEY);
    assert.equal(formatOptionalMoney(undefined, "TRY"), NO_MONEY);
    assert.equal(formatOptionalMoney(Number.NaN, "TRY"), NO_MONEY);
    assert.equal(NO_MONEY, "—");
  });
});

describe("isMoney", () => {
  it("yalnızca sonlu sayılar", () => {
    assert.equal(isMoney(0), true);
    assert.equal(isMoney(-5), true);
    assert.equal(isMoney(null), false);
    assert.equal(isMoney(undefined), false);
    assert.equal(isMoney(Number.POSITIVE_INFINITY), false);
  });
});
