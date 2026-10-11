import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { projectEventLabel, isStaffDecisionEvent, UNKNOWN_EVENT_LABEL } from "./events.ts";
import { NOTIFICATION_KIND_LABELS, notificationKind } from "./notifications.ts";

// Çalıştırma: npm test  (node --test "lib/**/*.test.mts") -- Next'siz.

describe("bildirim türü (zil/panel simgesi)", () => {
  it("entity_type asıl kaynak -- bütçe revizyonu dahil", () => {
    assert.equal(notificationKind({ entity_type: "budget_adjustment", type: "budget_adjustment_submitted" }), "budget_adjustment");
    assert.equal(notificationKind({ entity_type: "change_order", type: "change_order_approved" }), "change_order");
    assert.equal(notificationKind({ entity_type: "task", type: "task_updated" }), "task");
    assert.equal(notificationKind({ entity_type: "project_expense", type: "expense_pending_approval" }), "project_expense");
  });

  it("entity_type yoksa (ana sayfa paneli) type'tan türetilir", () => {
    const cases: [string, string][] = [
      ["budget_adjustment_submitted", "budget_adjustment"],
      ["change_order_approved", "change_order"],
      ["change_order_rejected", "change_order"],
      ["subcontract_change_order_submitted", "subcontract_change_order"],
      ["subcontract_activated", "subcontract"],
      ["progress_claim_certified", "progress_claim"],
      ["purchase_request_submitted", "purchase_request"],
      ["rfq_awarded", "rfq"],
      ["purchase_order_cancelled", "purchase_order"],
      ["task_assigned", "task"],
      ["task_completed", "task"],
      ["offer_viewed", "offer"],
      ["schedule_assigned", "schedule_item"],
      ["photo_uploaded", "project_photo"],
      ["file_uploaded", "project_file"],
      ["expense_rejected", "project_expense"],
      ["announcement", "announcement"],
    ];
    for (const [type, kind] of cases) assert.equal(notificationKind({ type }), kind, type);
  });

  it("bilinmeyen tür genel bildirim (çökmez)", () => {
    assert.equal(notificationKind({ entity_type: "yepyeni", type: "yepyeni_olay" }), "other");
    assert.equal(notificationKind({}), "other");
    assert.equal(notificationKind({ entity_type: null, type: null }), "other");
  });

  it("her türün Türkçe etiketi var", () => {
    assert.equal(NOTIFICATION_KIND_LABELS.budget_adjustment, "Bütçe Revizyonu");
    for (const [kind, label] of Object.entries(NOTIFICATION_KIND_LABELS)) assert.ok(label, kind);
  });
});

describe("proje olayı etiketi: personelin kaydettiği ek iş kararı", () => {
  it("source: staff ayrı etiketlenir", () => {
    const meta = { source: "staff", note: "telefonla onay" };
    assert.equal(isStaffDecisionEvent({ metadata: meta }), true);
    assert.equal(
      projectEventLabel({ event_type: "change_order_approved", metadata: meta }),
      "Müşteri onayı ekip tarafından kaydedildi"
    );
    assert.equal(
      projectEventLabel({ event_type: "change_order_rejected", metadata: { source: "staff" } }),
      "Müşteri reddi ekip tarafından kaydedildi"
    );
  });

  it("müşterinin kendi linkinden gelen karar eski etiketiyle", () => {
    assert.equal(projectEventLabel({ event_type: "change_order_approved", metadata: {} }), "Müşteri ek işi onayladı");
    assert.equal(projectEventLabel({ event_type: "change_order_rejected" }), "Müşteri ek işi reddetti");
    assert.equal(isStaffDecisionEvent({ metadata: null }), false);
  });

  it("diğer olaylar eventLabel ile aynı; bilinmeyen tip nötr metin", () => {
    assert.equal(projectEventLabel({ event_type: "budget_adjustment_approved" }), "Bütçe revizyonu onaylandı");
    // source: staff başka bir olayda etiketi değiştirmez.
    assert.equal(projectEventLabel({ event_type: "task_updated", metadata: { source: "staff" } }), "Görev güncellendi");
    assert.equal(projectEventLabel({ event_type: "yepyeni_olay" }), UNKNOWN_EVENT_LABEL);
  });
});
