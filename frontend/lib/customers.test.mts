import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { ApiError } from "./api.ts";
import { duplicateCustomerFromError, duplicateCustomerIntro } from "./customers.ts";

const BODY = {
  error: "aynı vergi numarasıyla kayıtlı müşteri var: Acme Yapı",
  code: "duplicate_customer",
  field: "tax_number",
  existing_customer: { id: "c1", name: "Acme Yapı", is_active: false },
};

describe("duplicateCustomerFromError", () => {
  it("409 duplicate_customer çakışan müşteriyi verir", () => {
    const dup = duplicateCustomerFromError(new ApiError(409, BODY.error, BODY));
    assert.deepEqual(dup, {
      id: "c1",
      name: "Acme Yapı",
      isActive: false,
      field: "tax_number",
      message: BODY.error,
    });
  });

  it("başka 409, başka durum kodu ya da eksik gövde null", () => {
    assert.equal(duplicateCustomerFromError(new ApiError(409, "kapalı", { error: "kapalı" })), null);
    assert.equal(duplicateCustomerFromError(new ApiError(400, BODY.error, BODY)), null);
    assert.equal(
      duplicateCustomerFromError(new ApiError(409, BODY.error, { ...BODY, existing_customer: undefined })),
      null
    );
    assert.equal(duplicateCustomerFromError(new Error("ağ")), null);
    assert.equal(duplicateCustomerFromError(null), null);
  });

  it("is_active yoksa aktif sayılır; giriş cümlesi alana göre", () => {
    const dup = duplicateCustomerFromError(
      new ApiError(409, "x", { ...BODY, field: "phone", existing_customer: { id: "c2", name: "B" } })
    );
    assert.equal(dup?.isActive, true);
    assert.equal(dup?.field, "phone");
    assert.equal(duplicateCustomerIntro("phone"), "Aynı telefon numarasıyla kayıtlı bir müşteri var:");
    assert.equal(duplicateCustomerIntro("tax_number"), "Aynı vergi numarasıyla kayıtlı bir müşteri var:");
  });
});
