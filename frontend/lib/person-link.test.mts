import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  NEW_EMPLOYEE_CHOICE,
  employeeForUserBody,
  employeeLoginDisabled,
  employeeOptionLabel,
  employeeUpdateBody,
  normalizePersonName,
  personnelDecision,
  personnelHelper,
  samePersonName,
  unlinkedActiveEmployees,
  userOptionLabel,
} from "./person-link.ts";
import type { Employee } from "./types.ts";

function emp(id: string, full_name: string, extra: Partial<Employee> = {}): Employee {
  return {
    id,
    full_name,
    phone: "",
    position: "",
    salary: null,
    daily_wage: null,
    start_date: null,
    is_active: true,
    description: "",
    user_id: null,
    ...extra,
  };
}

describe("ad normalizasyonu (backend domain.NormalizePersonName aynası)", () => {
  it("Türkçe harfler katlanır, büyük/küçük harf ve boşluk yok sayılır", () => {
    assert.equal(normalizePersonName("  Batuhan   İnci "), "batuhan inci");
    assert.equal(normalizePersonName("BATUHAN INCI"), "batuhan inci");
    assert.equal(normalizePersonName("Şükrü Çağlar Öztürk"), "sukru caglar ozturk");
    assert.equal(normalizePersonName("Âdem Îlhan Ûmit"), "adem ilhan umit");
    // "İ" bazı klavyelerde "I + birleşik nokta" (U+0307) olarak gelir.
    assert.equal(normalizePersonName("İnci"), "inci");
    assert.equal(normalizePersonName(""), "");
  });

  it("aynı kişi adı; boş ad hiçbir adla eşleşmez", () => {
    assert.ok(samePersonName("Batuhan İnci", "batuhan  INCI"));
    assert.ok(samePersonName("Ayşe Işık", "AYSE ISIK"));
    assert.equal(samePersonName("Batu", "Batuhan İnci"), false);
    assert.equal(samePersonName("", ""), false);
    assert.equal(samePersonName("   ", ""), false);
  });
});

describe("Yeni Kullanıcı personel kararı (mobil _personnelChoice aynası)", () => {
  const ali = emp("e1", "Ali Yılmaz", { position: "Usta" });
  const ali2 = emp("e2", "ALI YILMAZ");
  const veli = emp("e3", "Veli Kaya");
  const zeki = emp("e4", "Ayşe Demir");

  it("Personeli düzenleme izni yoksa alan gönderilmez (backend adımı atlar)", () => {
    const d = personnelDecision({ canManage: false, createEmployee: true, unlinked: [ali], fullName: "Ali Yılmaz", choice: null });
    assert.deepEqual(d.body, {});
  });

  it("anahtar kapalıysa create_employee:false", () => {
    const d = personnelDecision({ canManage: true, createEmployee: false, unlinked: [ali], fullName: "Ali Yılmaz", choice: null });
    assert.deepEqual(d.body, { create_employee: false });
  });

  it("liste bilinmiyorsa backend varsayılanı (alan yok)", () => {
    const d = personnelDecision({ canManage: true, createEmployee: true, unlinked: null, fullName: "Ali Yılmaz", choice: null });
    assert.deepEqual(d.body, {});
    assert.equal(d.selected, null);
  });

  it("aynı adlı tek kayıt önceden seçili ve employee_id gönderilir", () => {
    const d = personnelDecision({ canManage: true, createEmployee: true, unlinked: [veli, ali], fullName: "ali yilmaz", choice: null });
    assert.equal(d.selected, "e1");
    assert.deepEqual(d.body, { employee_id: "e1" });
    assert.deepEqual(d.ordered.map((e) => e.id), ["e1", "e3"]);
    assert.equal(personnelHelper(d), "Aynı adlı personel kaydı var; hesap ona bağlanır, ikinci kayıt açılmaz.");
  });

  it("aynı adlı kayıt yoksa yeni kayıt (link_same_name:false)", () => {
    const d = personnelDecision({ canManage: true, createEmployee: true, unlinked: [veli, zeki], fullName: "Ali Yılmaz", choice: null });
    assert.equal(d.selected, NEW_EMPLOYEE_CHOICE);
    assert.deepEqual(d.body, { create_employee: true, link_same_name: false });
    // Aynı adlı yoksa diğerleri ada göre (tr) sıralı.
    assert.deepEqual(d.ordered.map((e) => e.id), ["e4", "e3"]);
    assert.match(personnelHelper(d) ?? "", /ücretsiz bir personel kaydı açılır/);
  });

  it("aynı adlı birden çok kayıt: seçim zorunlu (selected null, alan yok)", () => {
    const d = personnelDecision({ canManage: true, createEmployee: true, unlinked: [ali, ali2, veli], fullName: "Ali Yılmaz", choice: null });
    assert.equal(d.selected, null);
    assert.deepEqual(d.body, {});
    assert.deepEqual(d.matches.map((e) => e.id), ["e1", "e2"]);
    assert.equal(personnelHelper(d), null);
  });

  it("aynı adlı varken 'yeni kayıt' seçilirse sunucu aynı adlıya bağlamasın", () => {
    const d = personnelDecision({
      canManage: true,
      createEmployee: true,
      unlinked: [ali],
      fullName: "Ali Yılmaz",
      choice: NEW_EMPLOYEE_CHOICE,
    });
    assert.deepEqual(d.body, { create_employee: true, link_same_name: false });
    assert.match(personnelHelper(d) ?? "", /yeni kayıt açılacak/);
  });

  it("başka bir personel elle seçilebilir; listeden düşen seçim sıfırlanır", () => {
    const picked = personnelDecision({ canManage: true, createEmployee: true, unlinked: [ali, veli], fullName: "Ali Yılmaz", choice: "e3" });
    assert.deepEqual(picked.body, { employee_id: "e3" });
    assert.equal(personnelHelper(picked), "Hesap seçilen personel kaydına bağlanır.");
    const gone = personnelDecision({ canManage: true, createEmployee: true, unlinked: [ali], fullName: "Ali Yılmaz", choice: "e3" });
    assert.equal(gone.selected, "e1");
  });
});

describe("hesap/personel yardımcıları", () => {
  it("bağlanabilecek personel: aktif ve hesapsız", () => {
    const all = [emp("a", "A"), emp("b", "B", { user_id: "u1" }), emp("c", "C", { is_active: false })];
    assert.deepEqual(unlinkedActiveEmployees(all).map((e) => e.id), ["a"]);
  });

  it("seçici etiketleri", () => {
    assert.equal(employeeOptionLabel(emp("a", "Ali Yılmaz", { position: "Usta" })), "Bağla: Ali Yılmaz · Usta");
    assert.equal(employeeOptionLabel(emp("a", "Ali Yılmaz")), "Bağla: Ali Yılmaz");
    const u = { full_name: "Ali Yılmaz", username: "ali" };
    assert.equal(userOptionLabel(u), "Ali Yılmaz (ali)");
    assert.equal(
      userOptionLabel({ ...u, employee_id: "e9", employee_full_name: "Ali Y." }),
      "Ali Yılmaz (ali) · personel: Ali Y."
    );
    assert.equal(userOptionLabel({ ...u, employee_id: "e9" }), "Ali Yılmaz (ali) · personel: başka kayıt");
    // Kendi personel kaydına bağlı hesap için not düşülmez.
    assert.equal(userOptionLabel({ ...u, employee_id: "e9", employee_full_name: "Ali Y." }, "e9"), "Ali Yılmaz (ali)");
  });

  it("giriş kapalı yalnızca hesap bilgisi geldiyse bilinir", () => {
    assert.equal(employeeLoginDisabled(emp("a", "A")), false);
    assert.equal(employeeLoginDisabled(emp("a", "A", { user_id: "u1" })), false);
    assert.equal(employeeLoginDisabled(emp("a", "A", { user_id: "u1", user_is_active: true })), false);
    assert.equal(employeeLoginDisabled(emp("a", "A", { user_id: "u1", user_is_active: false })), true);
    assert.equal(employeeLoginDisabled(emp("a", "A", { user_id: "u1", user_is_active: true, user_deleted: true })), true);
  });

  it("PUT gövdesi kaydın tam durumunu taşır, yalnızca bağ değişir", () => {
    const e = emp("a", "Ali", { phone: "555", position: "Usta", daily_wage: 1500, start_date: "2026-01-02", description: "x" });
    assert.deepEqual(employeeUpdateBody(e, "u1"), {
      full_name: "Ali",
      phone: "555",
      position: "Usta",
      daily_wage: 1500,
      salary: null,
      start_date: "2026-01-02",
      description: "x",
      is_active: true,
      user_id: "u1",
    });
    assert.equal(employeeUpdateBody(e, null).user_id, "");
  });

  it("hesap için yeni personel: hesabın adı, bugün, ücretsiz", () => {
    assert.deepEqual(employeeForUserBody({ id: "u1", full_name: "Ali Yılmaz" }, "2026-10-09"), {
      full_name: "Ali Yılmaz",
      phone: "",
      position: "",
      daily_wage: null,
      salary: null,
      start_date: "2026-10-09",
      description: "",
      user_id: "u1",
    });
  });
});
