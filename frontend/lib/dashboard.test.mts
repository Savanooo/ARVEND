import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";

import {
  ATTENTION_MODULES,
  attentionChip,
  attentionCodeFromHash,
  attentionGroupHref,
  attentionPartial,
  attentionMeta,
  attentionRecordLine,
  attentionTitle,
  compactSpanClass,
  type DashboardResponse,
  type DashboardUser,
  kpiGridClass,
  kpiTile,
  layoutBands,
  MODULE_KEYS,
  moduleAttention,
  niceCeil,
  normalizeDashboard,
  ONBOARDING_STEPS,
  onboardingHiddenKey,
  parseProjectTab,
  pickKpis,
  predictKpiCount,
  predictSections,
  quickActionGate,
  quickActionsFor,
  REF_KINDS,
  scopeLine,
  secondaryPanel,
  spanClass,
  summarySentence,
  trendMonths,
  upcomingDayWord,
  visibleModules,
  webHrefFor,
  webHrefForActionTarget,
} from "./dashboard.ts";
import { eventLabel, UNKNOWN_EVENT_LABEL } from "./events.ts";

// Backend, web ve mobilin ORTAK sözleşme örnekleri (backend
// dashboard_contract_test.go bunları Go tiplerine birebir çözer).
// eslint-disable-next-line @typescript-eslint/no-explicit-any -- ham JSON'u bilerek bozmak için
function rawFixture(name: string): any {
  const url = new URL(`../../docs/dashboard/fixtures/${name}.json`, import.meta.url);
  return JSON.parse(readFileSync(url, "utf8"));
}

function fixture(name: string): DashboardResponse {
  const d = normalizeDashboard(rawFixture(name));
  assert.ok(d, `${name}.json normalize edilemedi`);
  return d;
}

const owner = fixture("owner");
const field = fixture("field");
const finance = fixture("finance");
const empty = fixture("empty_company");

// Persona izin kümeleri -- backend internal/service/dashboard_agenda_test.go
// (permsAll/permsField/permsFinance/permsProjectManager) ile aynı.
const PERMS_FIELD = [
  "attendance.read", "notifications.read", "projects.operations.manage", "projects.operations.read",
  "projects.read", "projects.tasks.read", "projects.tasks.update",
];
const PERMS_FINANCE = [
  "notifications.read", "offers.internal_pricing.manage", "offers.internal_pricing.read",
  "organization.cost_codes.manage", "organization.cost_codes.read", "organization.suppliers.manage",
  "organization.suppliers.read", "projects.budget.manage", "projects.budget.read",
  "projects.contracts.lifecycle", "projects.contracts.manage", "projects.contracts.read",
  "projects.cost_control.manage", "projects.cost_control.read", "projects.finance.manage",
  "projects.finance.read", "projects.procurement.approve", "projects.procurement.manage",
  "projects.procurement.read", "projects.read", "projects.subcontract_claims.certify",
  "projects.subcontract_claims.manage", "projects.subcontract_claims.read",
  "projects.subcontract_payments.manage", "projects.subcontract_payments.read",
  "projects.subcontracts.approve", "projects.subcontracts.manage", "projects.subcontracts.read",
];
const PERMS_PM = [
  "calculations.read", "customers.read", "notifications.read", "organization.cost_codes.read",
  "organization.suppliers.read", "products.read", "projects.access.read", "projects.budget.read",
  "projects.contracts.manage", "projects.contracts.read", "projects.cost_control.read",
  "projects.operations.manage", "projects.operations.read", "projects.procurement.manage",
  "projects.procurement.read", "projects.read", "projects.subcontract_claims.manage",
  "projects.subcontract_claims.read", "projects.subcontract_payments.read", "projects.subcontracts.manage",
  "projects.subcontracts.read", "projects.tasks.create", "projects.tasks.read", "projects.tasks.update",
  "projects.update",
];
const PERMS_ALL = [
  "projects.read", "projects.create", "projects.update", "projects.finance.read", "projects.finance.manage",
  "projects.tasks.read", "projects.tasks.create", "projects.tasks.update", "projects.operations.read",
  "projects.operations.manage", "projects.access.read", "projects.access.manage", "offers.read", "offers.create",
  "offers.update", "offers.approve", "offers.delete", "offers.internal_pricing.read", "offers.internal_pricing.manage",
  "calculations.read", "calculations.manage", "products.read", "products.manage", "customers.read", "customers.manage",
  "employees.read", "employees.manage", "attendance.read", "attendance.manage", "organization.users.read",
  "organization.users.manage", "organization.roles.read", "organization.roles.manage", "organization.settings.read",
  "organization.settings.manage", "projects.budget.read", "projects.budget.manage", "projects.cost_control.read",
  "projects.cost_control.manage", "organization.cost_codes.read", "organization.cost_codes.manage",
  "projects.contracts.read", "projects.contracts.manage", "projects.contracts.lifecycle",
  "organization.suppliers.read", "organization.suppliers.manage", "projects.procurement.read",
  "projects.procurement.manage", "projects.procurement.approve", "projects.subcontracts.read",
  "projects.subcontracts.manage", "projects.subcontracts.approve", "projects.subcontract_claims.read",
  "projects.subcontract_claims.manage", "projects.subcontract_claims.certify", "projects.subcontract_payments.read",
  "projects.subcontract_payments.manage", "notifications.read",
];

const ownerUser: DashboardUser = { role: "admin", permissions: PERMS_ALL };
const fieldUser: DashboardUser = { role: "kullanici", permissions: PERMS_FIELD };
const financeUser: DashboardUser = { role: "kullanici", permissions: PERMS_FINANCE };
const pmUser: DashboardUser = { role: "kullanici", permissions: PERMS_PM };

function sectionKeys(d: DashboardResponse): string[] {
  return [...Object.keys(d.sections), ...Object.keys(d.section_errors)].sort();
}

describe("fixture'lar", () => {
  it("dört persona da normalize edilir; sözleşmedeki zorunlu alanlar var", () => {
    for (const d of [owner, field, finance, empty]) {
      assert.equal(d.timezone, "Europe/Istanbul");
      assert.ok(Array.isArray(d.agenda.groups));
      assert.ok(Array.isArray(d.agenda.upcoming));
      assert.equal(typeof d.section_errors, "object");
    }
  });

  it("bozuk yanıt null döner (sayfa çökmez, 'Özet yüklenemedi' gösterir)", () => {
    assert.equal(normalizeDashboard(null), null);
    assert.equal(normalizeDashboard({ error: "x" }), null);
    assert.equal(normalizeDashboard({ today: "2026-09-28", generated_at: "x" }), null);
    assert.equal(normalizeDashboard({ ...rawFixture("owner"), period: undefined }), null);
  });

  it("fixture'ların hiçbir bölümü biçim kontrolüne takılmaz", () => {
    for (const name of ["owner", "field", "finance", "empty_company"]) {
      const raw = rawFixture(name);
      const d = fixture(name);
      assert.deepEqual(d.section_errors, {}, name);
      assert.deepEqual(Object.keys(d.sections).sort(), Object.keys(raw.sections).sort(), name);
      assert.equal(d.agenda.groups.length, raw.agenda.groups.length, name);
      assert.equal(d.agenda.upcoming.length, raw.agenda.upcoming.length, name);
      assert.equal(d.onboarding === null, raw.onboarding === null, name);
    }
  });

  it("biçimi bozuk bölüm atılır ve section_errors'a yazılır; diğerleri kalır", () => {
    const raw = rawFixture("owner");
    const broken = {
      ...raw,
      sections: {
        ...raw.sections,
        offers: { ...raw.sections.offers, by_currency: undefined },
        tasks: { ...raw.sections.tasks, mine: { ...raw.sections.tasks.mine, items: null } },
        finance: { by_currency: [{ ...raw.sections.finance.by_currency[0], month: undefined }] },
        cost_control: { ...raw.sections.cost_control, over_budget: undefined },
        notifications: null,
      },
      agenda: { ...raw.agenda, groups: [...raw.agenda.groups, { code: "x", count: 1 }], upcoming: [...raw.agenda.upcoming, { kind: "x" }] },
    };
    const d = normalizeDashboard(broken);
    assert.ok(d);
    for (const key of ["offers", "tasks", "finance", "cost_control", "notifications"] as const) {
      assert.equal(d.sections[key], undefined, key);
      assert.equal(d.section_errors[key], "malformed", key);
    }
    assert.ok(d.sections.projects);
    assert.equal(d.section_errors.projects, undefined);
    assert.equal(d.agenda.groups.length, raw.agenda.groups.length);
    assert.equal(d.agenda.upcoming.length, raw.agenda.upcoming.length);
    // Sunucunun kendi hata kodu korunur.
    const failed = normalizeDashboard({ ...raw, section_errors: { users: "section_failed" } });
    assert.equal(failed?.section_errors.users, "section_failed");
  });
});

describe("predictSections (iskelet tahmini = sunucu kapıları)", () => {
  it("sahip: 20 bölümün tamamı", () => {
    assert.deepEqual(predictSections(ownerUser).sort(), sectionKeys(owner));
    assert.equal(predictSections(ownerUser).length, 20);
  });

  it("saha ve finans personaları fixture'daki bölüm kümesiyle birebir", () => {
    assert.deepEqual(predictSections(fieldUser).sort(), sectionKeys(field));
    assert.deepEqual(predictSections(financeUser).sort(), sectionKeys(finance));
  });

  it("proje yöneticisi (spec §4.8)", () => {
    assert.deepEqual(predictSections(pmUser).sort(), [
      "activity", "calculations", "contracts", "cost_codes", "cost_control", "customers", "notifications",
      "operations", "procurement", "products", "projects", "subcontracts", "suppliers", "tasks",
    ]);
  });

  it("users bölümü kaba rol admin ister; izin kümesi yoksa yalnızca activity", () => {
    const nonAdmin: DashboardUser = { role: "kullanici", permissions: ["organization.users.read"] };
    assert.equal(predictSections(nonAdmin).includes("users"), false);
    assert.deepEqual(predictSections({ role: "kullanici" }), ["activity"]);
  });

  it("KPI kutusu tahmini", () => {
    assert.equal(predictKpiCount(predictSections(ownerUser)), 4);
    assert.equal(predictKpiCount(predictSections(fieldUser)), 4);
    assert.equal(predictKpiCount(["activity"]), 0);
    assert.equal(predictKpiCount(["projects", "activity"]), 0);
  });
});

describe("pickKpis", () => {
  it("personalara göre KPI seti (spec §3.3)", () => {
    assert.deepEqual(pickKpis(owner), ["receivable", "net_cash", "pipeline", "cash_balance"]);
    assert.deepEqual(pickKpis(finance), ["receivable", "net_cash", "cash_balance", "active_projects"]);
    assert.deepEqual(pickKpis(field), ["active_projects", "my_tasks", "team_overdue", "on_site"]);
  });

  it("hesaplanamayan bölümün KPI'ı düşer, sıradaki gelir", () => {
    const failed: DashboardResponse = {
      ...owner,
      sections: { ...owner.sections, offers: undefined },
      section_errors: { offers: "section_failed" },
    };
    assert.deepEqual(pickKpis(failed), ["receivable", "net_cash", "cash_balance", "active_projects"]);
  });

  it("2'den az aday varsa satır gizlenir", () => {
    const onlyProjects = { sections: { projects: owner.sections.projects } };
    assert.deepEqual(pickKpis(onlyProjects), []);
  });

  it("sahip kutuları: kısa değer, tam değer, diğer para birimi", () => {
    const receivable = kpiTile(owner, "receivable");
    assert.equal(receivable.value, "5,1 Mn TL");
    assert.equal(receivable.valueFull, "5.100.000,00 TL");
    assert.deepEqual(receivable.sub, ["%59,2 tahsil edildi"]);
    assert.equal(receivable.other, "Diğer: 45.000 $");
    assert.equal(receivable.progress?.pct, 59.2);

    const net = kpiTile(owner, "net_cash");
    assert.equal(net.value, "+420.000 TL");
    assert.equal(net.tone, "success");
    assert.deepEqual(net.sub, ["Giriş 950.000 TL", "Çıkış 530.000 TL"]);
    assert.equal(net.href, "#nakit-akisi");

    const pipeline = kpiTile(owner, "pipeline");
    assert.equal(pipeline.value, "2,3 Mn TL");
    assert.deepEqual(pipeline.sub, ["5 teklif yanıt bekliyor", "Kabul oranı %62,5 · 90 gün"]);

    const balance = kpiTile(owner, "cash_balance");
    assert.equal(balance.value, "+2,2 Mn TL");
    // İki satır (§5.5 çizimi): tek satırda dar kutuda harcama kırpılıyordu.
    assert.deepEqual(balance.sub, ["Tahsilat 7,4 Mn TL", "Harcama 5,2 Mn TL"]);
  });

  it("saha kutularında para yok (spec §10 kabul)", () => {
    for (const key of pickKpis(field)) {
      const t = kpiTile(field, key);
      const text = [t.label, t.value, t.valueFull, ...t.sub, t.other ?? ""].join(" ");
      assert.doesNotMatch(text, /\bTL\b|\$|€/, `${key}: ${text}`);
    }
    assert.equal(kpiTile(field, "my_tasks").href, "#gorevlerim");
    assert.deepEqual(kpiTile(field, "on_site").sub, ["Firma geneli · 2 kişi girilmedi"]);
    assert.equal(kpiTile(field, "team_overdue").tone, "danger");
  });
});

describe("secondaryPanel", () => {
  it("finans varsa Nakit Akışı, yoksa bağlı görevlerde Görevlerim", () => {
    assert.equal(secondaryPanel(owner), "cash");
    assert.equal(secondaryPanel(finance), "cash");
    assert.equal(secondaryPanel(field), "my_tasks");
    const unlinked = { sections: { tasks: { ...field.sections.tasks!, mine: { ...field.sections.tasks!.mine, linked_employee: false } } } };
    assert.equal(secondaryPanel(unlinked), null);
  });
});

describe("layoutBands / visibleModules", () => {
  it("sahip: 4 bant, 15 standart + 3 kompakt kart", () => {
    const layout = layoutBands(visibleModules(owner, false), false);
    assert.equal(layout.density, false);
    assert.deepEqual(layout.bands.map((b) => b.title), ["Nakit & Satış", "Proje & Saha", "Tedarik & Maliyet", "Firma kayıtları"]);
    assert.equal(layout.bands.reduce((n, b) => n + b.standard.length, 0), 15);
    assert.equal(layout.bands.reduce((n, b) => n + b.compact.length, 0), 3);
    assert.deepEqual(layout.bands[1].standard, ["projects", "tasks", "operations", "contracts", "attendance"]);
    assert.deepEqual(layout.bands[3].compact, ["calculations", "suppliers", "cost_codes"]);
  });

  it("saha: yoğun mod, 4 standart kart", () => {
    const layout = layoutBands(visibleModules(field, false), false);
    assert.equal(layout.density, true);
    assert.equal(layout.bands.length, 1);
    assert.equal(layout.bands[0].title, "Bölümler");
    assert.deepEqual(layout.bands[0].standard, ["projects", "tasks", "operations", "attendance"]);
    assert.deepEqual(layout.bands[0].compact, []);
  });

  it("finans: 7 standart kart -> bant başlıkları görünür", () => {
    const layout = layoutBands(visibleModules(finance, false), false);
    assert.equal(layout.density, false);
    assert.deepEqual(
      layout.bands.map((b) => [b.key, b.standard, b.compact]),
      [
        ["cash_sales", ["finance", "change_orders"], []],
        ["project_field", ["projects", "contracts"], []],
        ["supply_cost", ["procurement", "subcontracts", "cost_control"], []],
        ["records", [], ["suppliers", "cost_codes"]],
      ]
    );
  });

  it("yeni firma: kurulum yerleşimi, yer tutucu başta", () => {
    const layout = layoutBands(visibleModules(empty, true), true);
    assert.equal(layout.density, true);
    assert.equal(layout.bands.length, 1);
    assert.equal(layout.bands[0].placeholder, true);
    assert.deepEqual(layout.bands[0].standard, ["offers", "attendance", "customers", "employees", "products", "users"]);
    assert.deepEqual(layout.bands[0].compact, ["calculations", "suppliers", "cost_codes"]);
  });

  it("hesaplanamayan bölüm kartı yine çizilir (hata gövdesiyle)", () => {
    const failed: DashboardResponse = {
      ...owner,
      sections: { ...owner.sections, procurement: undefined },
      section_errors: { procurement: "section_failed" },
    };
    assert.ok(visibleModules(failed, false).includes("procurement"));
    assert.equal(visibleModules(field, false).includes("procurement"), false);
  });

  it("MODULE_KEYS 18 modül", () => {
    assert.equal(MODULE_KEYS.length, 18);
  });
});

describe("spanClass / compactSpanClass / kpiGridClass", () => {
  const S12 = "col-span-12";
  const expected: Record<number, string[]> = {
    1: [`${S12} @2xl:col-span-12 @4xl:col-span-12`],
    2: [`${S12} @2xl:col-span-6 @4xl:col-span-6`, `${S12} @2xl:col-span-6 @4xl:col-span-6`],
    3: [
      `${S12} @2xl:col-span-6 @4xl:col-span-4`,
      `${S12} @2xl:col-span-6 @4xl:col-span-4`,
      `${S12} @2xl:col-span-12 @4xl:col-span-4`,
    ],
    4: [
      `${S12} @2xl:col-span-6 @4xl:col-span-4`,
      `${S12} @2xl:col-span-6 @4xl:col-span-4`,
      `${S12} @2xl:col-span-6 @4xl:col-span-4`,
      `${S12} @2xl:col-span-6 @4xl:col-span-12`,
    ],
    5: [
      `${S12} @2xl:col-span-6 @4xl:col-span-4`,
      `${S12} @2xl:col-span-6 @4xl:col-span-4`,
      `${S12} @2xl:col-span-6 @4xl:col-span-4`,
      `${S12} @2xl:col-span-6 @4xl:col-span-6`,
      `${S12} @2xl:col-span-12 @4xl:col-span-6`,
    ],
  };
  for (let n = 1; n <= 5; n++) {
    it(`n=${n}`, () => {
      assert.deepEqual(
        Array.from({ length: n }, (_, i) => spanClass(i, n)),
        expected[n]
      );
      assert.deepEqual(
        Array.from({ length: n }, (_, i) => compactSpanClass(i, n)),
        expected[n].map((c) => c.replace("@2xl:", "@xl:"))
      );
    });
  }

  it("her satır 12 sütunu tam doldurur (T2 ve T3)", () => {
    for (let n = 1; n <= 9; n++) {
      const spans = Array.from({ length: n }, (_, i) => spanClass(i, n));
      for (const [prefix, cols] of [["@2xl:col-span-", 12], ["@4xl:col-span-", 12]] as const) {
        const total = spans.reduce((sum, c) => sum + Number(c.split(" ").find((x) => x.startsWith(prefix))!.slice(prefix.length)), 0);
        assert.equal(total % cols, 0, `n=${n} ${prefix}`);
      }
    }
  });

  it("KPI ızgarası", () => {
    assert.match(kpiGridClass(4), /@4xl:grid-cols-4/);
    assert.match(kpiGridClass(3), /@2xl:grid-cols-3/);
    assert.match(kpiGridClass(2), /@min-\[22rem\]:grid-cols-2/);
    assert.equal(kpiGridClass(1), "");
  });
});

describe("webHrefFor", () => {
  const P = "0b000000-0000-4000-8000-000000000001";
  const ref = (kind: string, id = "x1", action = "open", project_id: string | null = P, parent_id: string | null = null) => ({
    kind,
    id,
    project_id,
    parent_id,
    action,
  });
  const cases: Record<string, string | null> = {
    project: `/projeler/${P}`,
    project_finance: `/projeler/${P}?tab=finans`,
    project_cost: `/projeler/${P}?tab=maliyet`,
    project_operations: `/projeler/${P}?tab=operasyon`,
    offer: "/teklifler/x1",
    task: `/projeler/${P}?tab=operasyon`,
    milestone: `/projeler/${P}?tab=operasyon`,
    purchase_request: `/projeler/${P}?tab=satinalma`,
    rfq: `/projeler/${P}?tab=satinalma`,
    purchase_order: `/projeler/${P}?tab=satinalma`,
    subcontract: `/projeler/${P}?tab=finans`,
    progress_claim: `/projeler/${P}?tab=finans`,
    subcontract_change_order: `/projeler/${P}?tab=finans`,
    change_order: `/projeler/${P}?tab=finans`,
    budget_adjustment: `/projeler/${P}?tab=maliyet`,
    contract: `/projeler/${P}?tab=finans`,
    payment_plan_item: `/projeler/${P}?tab=finans`,
    invoice: `/projeler/${P}?tab=finans`,
    customer: "/musteriler/x1",
    product: "/admin/urunler/x1",
    user: "/admin/kullanicilar/x1",
    price_source: "/admin/urunler",
  };

  it("22 ref türünün hepsi eşlenir", () => {
    assert.equal(REF_KINDS.length, 22);
    assert.deepEqual(Object.keys(cases).sort(), [...REF_KINDS].sort());
    for (const kind of REF_KINDS) {
      // Proje düzeyindeki türlerde id projenin kendisidir.
      const id = kind.startsWith("project") ? P : "x1";
      assert.equal(webHrefFor(ref(kind, id)), cases[kind], kind);
    }
  });

  it("convert ve award aksiyonları", () => {
    assert.equal(webHrefFor(ref("offer", "o1", "convert", null)), "/teklifler/o1/projeye-donustur");
    assert.equal(webHrefFor(ref("offer", "o1", "open", null)), "/teklifler/o1");
    // Web'de RFQ karşılaştırma sayfası yok: karar da satın alma sekmesinde verilir.
    assert.equal(webHrefFor(ref("rfq", "r1", "award")), `/projeler/${P}?tab=satinalma`);
  });

  it("bilinmeyen tür ya da projesiz kayıt düz metin (null)", () => {
    assert.equal(webHrefFor(ref("mystery")), null);
    assert.equal(webHrefFor(ref("task", "t1", "open", null)), null);
  });

  it("fixture'lardaki her kayıt ve yaklaşan için bir hedef var", () => {
    for (const d of [owner, field, finance, empty]) {
      for (const g of d.agenda.groups) for (const r of g.items) assert.ok(webHrefFor(r.ref), `${g.code} ${r.ref.kind}`);
      for (const u of d.agenda.upcoming) assert.ok(webHrefFor(u.ref), u.kind);
    }
  });
});

describe("webHrefForActionTarget (bildirim hedefi mobil yoldur)", () => {
  const P = "p1";
  const cases: [string | null, string | null][] = [
    ["/teklifler/o1", "/teklifler/o1"],
    ["/teklifler/o1/revizyonlar/r2", "/teklifler/o1"],
    [`/projeler/${P}/satin-alma/talepler/t1`, `/projeler/${P}?tab=satinalma`],
    [`/projeler/${P}/satin-alma/rfqlar/r1/karsilastir`, `/projeler/${P}?tab=satinalma`],
    [`/projeler/${P}/gorevler/g1`, `/projeler/${P}?tab=operasyon`],
    [`/projeler/${P}/planlama/s1`, `/projeler/${P}?tab=operasyon`],
    [`/projeler/${P}/taseronlar/s1/hakedisler/h1`, `/projeler/${P}?tab=finans`],
    [`/projeler/${P}?grup=finans&alt=maliyet`, `/projeler/${P}?tab=maliyet`],
    [`/projeler/${P}?grup=finans&alt=ek-isler`, `/projeler/${P}?tab=finans`],
    [`/projeler/${P}?grup=finans`, `/projeler/${P}?tab=finans`],
    [`/projeler/${P}?grup=operasyon&alt=gorevler`, `/projeler/${P}?tab=operasyon`],
    [`/projeler/${P}?grup=operasyon`, `/projeler/${P}?tab=operasyon`],
    [`/projeler/${P}?grup=dokumanlar&alt=dosyalar`, `/projeler/${P}?tab=dosyalar`],
    [`/projeler/${P}`, `/projeler/${P}`],
    [`/projeler/${P}/bilinmeyen`, `/projeler/${P}`],
    ["/diger/musteriler/c1", "/musteriler/c1"],
    ["/diger/mesai", "/mesai"],
    ["/diger/metraj", "/admin/metraj-hesaplama"],
    ["/diger/bildirimler", null],
    ["/gorevler", null],
    ["https://evil.example/x", null],
    ["", null],
    [null, null],
  ];
  for (const [input, want] of cases) {
    it(`${input} -> ${want}`, () => assert.equal(webHrefForActionTarget(input), want));
  }

  it("owner fixture bildirimleri webde açılır", () => {
    for (const n of owner.sections.notifications!.latest) assert.ok(webHrefForActionTarget(n.action_target), n.action_target ?? "");
  });
});

describe("summarySentence / scopeLine", () => {
  it("üç dal", () => {
    assert.equal(summarySentence({ mine_count: 13, mine_danger_count: 7, watching_count: 2 }), "Bugün 13 iş senin sıranda; 7 tanesi acil.");
    assert.equal(summarySentence({ mine_count: 1, mine_danger_count: 0, watching_count: 0 }), "Bugün 1 iş senin sıranda.");
    assert.equal(summarySentence({ mine_count: 0, mine_danger_count: 0, watching_count: 2 }), "Senin sıranda iş yok; 2 konu takipte.");
    assert.equal(summarySentence({ mine_count: 0, mine_danger_count: 0, watching_count: 0 }), "Bugün seni bekleyen bir iş yok.");
  });

  it("fixture cümleleri", () => {
    assert.equal(summarySentence(owner.agenda), "Bugün 13 iş senin sıranda; 7 tanesi acil.");
    assert.equal(summarySentence(field.agenda), "Bugün 4 iş senin sıranda; 3 tanesi acil.");
  });

  it("kapsam satırı yalnızca üyelikle sınırlı izleyicide", () => {
    assert.equal(scopeLine(owner.viewer), null);
    assert.equal(scopeLine(field.viewer), "Üyesi olduğun 2 projenin verileri gösteriliyor.");
    assert.equal(scopeLine(finance.viewer), "Üyesi olduğun 3 projenin verileri gösteriliyor.");
    assert.equal(
      scopeLine({ all_projects: false, accessible_project_count: 0 }),
      "Henüz bir projeye eklenmedin; yöneticin seni eklediğinde proje verileri burada görünür."
    );
  });
});

describe("Dikkat metinleri", () => {
  it("attentionChip: tehlike > aksiyon > bilgi", () => {
    assert.deepEqual(attentionChip([{ severity: "danger", count: 4 }, { severity: "action", count: 2 }, { severity: "danger", count: 1 }]), {
      tone: "danger",
      label: "5 uyarı",
    });
    assert.deepEqual(attentionChip([{ severity: "action", count: 3 }, { severity: "info", count: 1 }]), { tone: "gold", label: "3 bekliyor" });
    assert.deepEqual(attentionChip([{ severity: "info", count: 2 }]), { tone: "info", label: "2 takipte" });
    assert.equal(attentionChip([]), null);
    assert.deepEqual(attentionChip(moduleAttention(owner, "change_orders")), { tone: "info", label: "2 takipte" });
    assert.deepEqual(attentionChip(moduleAttention(owner, "finance")), { tone: "danger", label: "4 uyarı" });
  });

  it("fixture'lardaki her kodun başlığı şablondan gelir", () => {
    for (const d of [owner, field, finance, empty]) {
      for (const g of d.agenda.groups) assert.doesNotMatch(attentionTitle(g), /kayıt dikkat gerektiriyor/, g.code);
    }
    const g = (code: string) => owner.agenda.groups.find((x) => x.code === code)!;
    assert.equal(attentionTitle(g("plan_item_overdue")), "4 ödeme planı kaleminin vadesi geçti");
    assert.equal(attentionTitle(g("change_order_awaiting_customer")), "2 ek iş müşteri onayında");
    assert.equal(attentionTitle(empty.agenda.groups[0]), "Demir Profil fiyat kaynağı hiç senkronlanmadı");
    assert.equal(attentionTitle({ code: "team_task_overdue", count: 7, items: [] }), "Ekipte 7 görev gecikmiş");
    assert.equal(attentionTitle({ code: "yeni_kod", count: 2, items: [] }), "2 kayıt dikkat gerektiriyor");
  });

  it("kayıt satırı: etiket + proje + gün ifadesi", () => {
    const g = (code: string) => owner.agenda.groups.find((x) => x.code === code)!;
    assert.equal(attentionRecordLine(g("plan_item_overdue").items[0], "plan_item_overdue"), "2. Hakediş · Kadıköy Konut Projesi · 21 gün gecikti");
    assert.equal(
      attentionRecordLine(g("purchase_request_approval").items[0], "purchase_request_approval"),
      "PR-2026-0012 · Beton C30 · Kadıköy Konut Projesi · 4 gündür bekliyor"
    );
    // Proje düzeyindeki kayıtta proje adı etikette zaten var, tekrar edilmez.
    assert.equal(attentionRecordLine(g("project_past_end").items[0], "project_past_end"), "PRJ-2026-0003 Beykoz Müstakil Konut · 12 gün geçti");
    assert.equal(attentionRecordLine(g("offer_expired_awaiting").items[0], "offer_expired_awaiting"), "TKF-2026-0031 · Yıldız İnşaat · 6 gün önce doldu");
    assert.equal(attentionRecordLine(g("users_without_project").items[0], "users_without_project"), "Mehmet Kaya · Saha");
    const overBudget = finance.agenda.groups.find((x) => x.code === "over_budget")!;
    assert.match(attentionRecordLine(overBudget.items[0], "over_budget"), /%\d+(,\d)? aşım$/);
  });

  it("grup meta ve hedefi", () => {
    const plan = owner.agenda.groups.find((x) => x.code === "plan_item_overdue")!;
    assert.equal(attentionMeta(plan), "en eski 21 gün");
    assert.equal(attentionGroupHref(plan), null); // 4 kayıt -> açılır liste
    const claim = owner.agenda.groups.find((x) => x.code === "progress_claim_certify")!;
    assert.equal(attentionGroupHref(claim), "/projeler/0b000000-0000-4000-8000-000000000001?tab=finans");
    assert.equal(attentionGroupHref({ count: 3, items: [], module: "attendance" }), "/mesai");
  });

  it("'liste eksik olabilir' notu yalnızca dikkat üreten bölüm hatasında", () => {
    assert.equal(attentionPartial({ section_errors: {} }), false);
    for (const key of ["notifications", "activity", "customers", "employees", "calculations", "suppliers", "cost_codes"] as const) {
      assert.equal(attentionPartial({ section_errors: { [key]: "section_failed" } }), false, key);
    }
    for (const key of ["finance", "procurement", "tasks", "products", "users"] as const) {
      assert.equal(attentionPartial({ section_errors: { [key]: "section_failed" } }), true, key);
    }
    // Liste, fixture'lardaki her grubun modülünü kapsar.
    for (const d of [owner, field, finance, empty]) {
      for (const g of d.agenda.groups) assert.ok(ATTENTION_MODULES.includes(g.module as never), g.module);
    }
  });

  it("#dikkat-<kod> ayrıştırması bozuk parçada çökmez", () => {
    assert.equal(attentionCodeFromHash("#dikkat-plan_item_overdue"), "plan_item_overdue");
    assert.equal(attentionCodeFromHash("#dikkat-%"), null);
    assert.equal(attentionCodeFromHash("#dikkat-%E0%A4%A"), null);
    assert.equal(attentionCodeFromHash("#dikkat-"), null);
    assert.equal(attentionCodeFromHash("#nakit-akisi"), null);
    assert.equal(attentionCodeFromHash(""), null);
  });

  it("yaklaşan: Bugün / Yarın", () => {
    assert.equal(upcomingDayWord("2026-09-28", "2026-09-28"), "Bugün");
    assert.equal(upcomingDayWord("2026-09-29", "2026-09-28"), "Yarın");
    assert.equal(upcomingDayWord("2026-09-30", "2026-09-28"), null);
  });
});

describe("quickActionsFor (spec §3.5, §8)", () => {
  it("sahip: hepsi, sabit sırada", () => {
    assert.deepEqual(
      quickActionsFor(ownerUser).map((a) => a.label),
      [
        "Yeni Teklif", "Tahsilat Gir", "Masraf Gir", "Mesai Gir", "Satın Alma Talebi", "Görev Ekle",
        "Müşteri Ekle", "Metraj Hesapla", "Ürün Ekle", "Personel Ekle", "Kullanıcı Ekle",
      ]
    );
  });

  it("finans: Tahsilat, Masraf, Satın Alma Talebi; saha: hiçbiri", () => {
    assert.deepEqual(quickActionsFor(financeUser).map((a) => a.key), ["collection", "expense", "purchase_request"]);
    assert.deepEqual(quickActionsFor(fieldUser), []);
  });

  it("Mesai Gir iki izin (+ sayfanın attendance.read'i) ister; Kullanıcı Ekle kaba admin ister", () => {
    assert.deepEqual(quickActionsFor({ role: "kullanici", permissions: ["attendance.read", "attendance.manage"] }), []);
    assert.deepEqual(
      quickActionsFor({ role: "kullanici", permissions: ["attendance.read", "attendance.manage", "employees.read"] }).map((a) => a.key),
      ["attendance"]
    );
    assert.deepEqual(quickActionsFor({ role: "kullanici", permissions: ["organization.users.manage"] }), []);
  });

  // Hedef sayfaların kendi kapıları (app/**/page.tsx'teki requirePagePermission
  // + yönlendirme koşulları). Proje seçicisi /dashboard/project-options
  // (projects.read) ve /projeler/{id} (projects.read) açar. Bir hızlı işlem ya
  // da kurulum CTA'sı bu kapının altında görünürse düğme çıkmaz sokak olur.
  const TARGET_GATES: Record<string, readonly string[]> = {
    "/teklifler/yeni": ["offers.read", "offers.create"],
    "/teklifler": ["offers.read"],
    "/mesai": ["attendance.read"],
    "/musteriler/yeni": ["customers.read", "customers.manage"],
    "/admin/metraj-hesaplama": ["calculations.read"],
    "/admin/urunler": ["products.read"],
    "/admin/urunler/yeni": ["products.read", "products.manage"],
    "/admin/personel/yeni": ["employees.read", "employees.manage"],
    "/admin/kullanicilar/yeni": ["organization.users.read", "organization.users.manage", "organization.roles.read"],
    picker: ["projects.read"],
  };
  const covers = (allOf: readonly string[], target: string) => {
    const gate = TARGET_GATES[target];
    assert.ok(gate, `hedef kapısı tanımsız: ${target}`);
    for (const code of gate) assert.ok(allOf.includes(code), `${target}: ${code} eksik`);
  };

  it("her hızlı işlemin kapısı hedef sayfanın kapısını kapsar", () => {
    for (const a of quickActionsFor(ownerUser)) {
      covers(quickActionGate(a.key), a.href ?? "picker");
    }
  });

  it("her kurulum CTA'sının kapısı hedef sayfanın kapısını kapsar", () => {
    for (const step of Object.values(ONBOARDING_STEPS)) covers(step.cta.allOf, step.cta.href);
  });

  it("projects.read olmadan seçicili işlem yok; roles.read olmadan Kullanıcı Ekle yok", () => {
    const noProjectsRead: DashboardUser = {
      role: "kullanici",
      permissions: ["projects.finance.read", "projects.finance.manage", "projects.procurement.read", "projects.procurement.manage"],
    };
    assert.deepEqual(quickActionsFor(noProjectsRead), []);
    const adminNoRoles: DashboardUser = {
      role: "admin",
      permissions: PERMS_ALL.filter((p) => p !== "organization.roles.read"),
    };
    assert.equal(quickActionsFor(adminNoRoles).some((a) => a.key === "user"), false);
    assert.equal(quickActionsFor(ownerUser).some((a) => a.key === "user"), true);
  });

  it("proje gerektirenler seçiciye, diğerleri sayfaya gider", () => {
    const byKey = Object.fromEntries(quickActionsFor(ownerUser).map((a) => [a.key, a]));
    assert.equal(byKey.collection.pickerTab, "finans");
    assert.equal(byKey.purchase_request.pickerTab, "satinalma");
    assert.equal(byKey.task.pickerTab, "operasyon");
    assert.equal(byKey.offer.href, "/teklifler/yeni");
    assert.equal(byKey.offer.pickerTab, null);
  });
});

describe("diğer yardımcılar", () => {
  it("parseProjectTab yalnızca bilinen sekmeleri kabul eder", () => {
    assert.equal(parseProjectTab("finans"), "finans");
    assert.equal(parseProjectTab(["satinalma", "x"]), "satinalma");
    assert.equal(parseProjectTab("yok"), "genel");
    assert.equal(parseProjectTab(undefined), "genel");
  });

  it("niceCeil 1 / 2 / 2,5 / 5 basamakları", () => {
    assert.equal(niceCeil(0), 0);
    assert.equal(niceCeil(950000), 1000000);
    assert.equal(niceCeil(1200000), 2000000);
    assert.equal(niceCeil(2100000), 2500000);
    assert.equal(niceCeil(3000000), 5000000);
    assert.equal(niceCeil(5000000), 5000000);
    assert.equal(niceCeil(25000), 25000);
  });

  it("trendMonths: month_start'la biten 6 ay", () => {
    assert.deepEqual(trendMonths("2026-09-01"), ["2026-04", "2026-05", "2026-06", "2026-07", "2026-08", "2026-09"]);
    assert.deepEqual(trendMonths("2026-02-01"), ["2025-09", "2025-10", "2025-11", "2025-12", "2026-01", "2026-02"]);
    assert.deepEqual(owner.sections.finance!.by_currency[0].trend_6m.map((t) => t.month), trendMonths(owner.period.month_start));
  });

  it("onboarding gizleme anahtarı", () => {
    assert.equal(onboardingHiddenKey("org1", "u1"), "arvend.home.onboarding.hidden.org1.u1");
  });

  it("olay etiketleri: fixture'lardaki her olay tipinin etiketi var", () => {
    for (const d of [owner, field, finance]) {
      for (const item of d.sections.activity?.items ?? []) {
        assert.notEqual(eventLabel(item.source, item.event_type), UNKNOWN_EVENT_LABEL, `${item.source}:${item.event_type}`);
      }
    }
    assert.equal(eventLabel("project", "yepyeni_olay"), UNKNOWN_EVENT_LABEL);
    assert.equal(eventLabel("offer", "customer_viewed"), "Müşteri teklifi görüntüledi");
  });
});
