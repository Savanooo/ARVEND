import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { projectTaskHref, webHrefForActionTarget } from "./dashboard.ts";
import {
  TASK_FOCUS_PARAM,
  taskEditDraft,
  taskEditRequest,
  taskUpdateRequest,
  taskUpdateStatusChoices,
  taskUpdateStatusLine,
} from "./tasks.ts";
import type { ProjectTask } from "./types.ts";

// Çalıştırma: npm test  (node --test "lib/**/*.test.mts") -- Next'siz.

const task: ProjectTask = {
  id: "t1",
  schedule_item_id: "s1",
  title: "Kalıp sökümü",
  description: "Blok A",
  assigned_employee_id: "e1",
  assigned_name: "Mehmet Usta",
  priority: "high",
  status: "in_progress",
  due_date: "2026-10-20",
  completed_at: null,
  is_overdue: false,
};

describe("Bilgi Ver (POST .../tasks/{id}/updates)", () => {
  it("durum seçenekleri: mevcut durum dışındaki Yapılacak/Devam Ediyor/Tamamlandı", () => {
    assert.deepEqual(taskUpdateStatusChoices("todo"), ["in_progress", "completed"]);
    assert.deepEqual(taskUpdateStatusChoices("in_progress"), ["todo", "completed"]);
    assert.deepEqual(taskUpdateStatusChoices("completed"), ["todo", "in_progress"]);
    // İptal bu pencereden seçilmez; iptal edilmiş görev yeniden açılabilir.
    assert.deepEqual(taskUpdateStatusChoices("cancelled"), ["todo", "in_progress", "completed"]);
  });

  it("not ya da durum değişikliği yoksa istek yok (sunucu da 400 döner)", () => {
    assert.equal(taskUpdateRequest("   ", null, "todo"), null);
    // Mevcut durumla aynı seçim değişiklik sayılmaz.
    assert.equal(taskUpdateRequest("", "todo", "todo"), null);
  });

  it("yalnızca not, yalnızca durum, ikisi birden", () => {
    assert.deepEqual(taskUpdateRequest("  Beton döküldü ", null, "todo"), { body: "Beton döküldü" });
    assert.deepEqual(taskUpdateRequest("", "completed", "in_progress"), { body: "", status: "completed" });
    assert.deepEqual(taskUpdateRequest("Bitti", "completed", "in_progress"), { body: "Bitti", status: "completed" });
    assert.deepEqual(taskUpdateRequest("Not", "in_progress", "in_progress"), { body: "Not" });
  });

  it("durum satırı Türkçe etiketlerle; değişiklik yoksa null", () => {
    assert.equal(taskUpdateStatusLine({ status_from: "todo", status_to: "in_progress" }), "Yapılacak → Devam Ediyor");
    assert.equal(taskUpdateStatusLine({ status_from: "in_progress", status_to: "completed" }), "Devam Ediyor → Tamamlandı");
    assert.equal(taskUpdateStatusLine({ status_from: "", status_to: "" }), null);
    // Bilinmeyen kod ham görünür (çökmesin).
    assert.equal(taskUpdateStatusLine({ status_from: "todo", status_to: "blocked" }), "Yapılacak → blocked");
  });
});

describe("Görev düzenleme (PUT .../tasks/{id} satırı bütünüyle yazar)", () => {
  it("taslak görevin tüm alanlarını taşır", () => {
    assert.deepEqual(taskEditDraft(task), {
      title: "Kalıp sökümü",
      description: "Blok A",
      schedule_item_id: "s1",
      assigned_employee_id: "e1",
      priority: "high",
      status: "in_progress",
      due_date: "2026-10-20",
    });
  });

  it("değiştirilmeyen alanlar da geri gönderilir; boş bağlantılar null", () => {
    assert.deepEqual(taskEditRequest(taskEditDraft(task)), {
      title: "Kalıp sökümü",
      description: "Blok A",
      schedule_item_id: "s1",
      assigned_employee_id: "e1",
      priority: "high",
      status: "in_progress",
      due_date: "2026-10-20",
    });
    const cleared = taskEditRequest({
      ...taskEditDraft(task),
      title: "  Yeni başlık ",
      description: "  ",
      schedule_item_id: "",
      assigned_employee_id: "",
      due_date: "",
    });
    assert.deepEqual(cleared, {
      title: "Yeni başlık",
      description: "",
      schedule_item_id: null,
      assigned_employee_id: null,
      priority: "high",
      status: "in_progress",
      due_date: null,
    });
  });

  it("bağlantısız görev boş taslak alanlarına düşer", () => {
    const d = taskEditDraft({ ...task, schedule_item_id: null, assigned_employee_id: null, due_date: null });
    assert.equal(d.schedule_item_id, "");
    assert.equal(d.assigned_employee_id, "");
    assert.equal(d.due_date, "");
  });
});

describe("görev bağlantısı (bildirim / ana sayfa -> açık görev satırı)", () => {
  it("?gorev= TaskRow'un okuduğu parametreyle aynı", () => {
    const href = projectTaskHref("p1", "t1");
    const url = new URL(href, "http://x");
    assert.equal(url.pathname, "/projeler/p1");
    assert.equal(url.searchParams.get("tab"), "operasyon");
    assert.equal(url.searchParams.get(TASK_FOCUS_PARAM), "t1");
  });

  it("görev bildirimi (.../gorevler/{id}) ve düzenleme yolu o görevi açar", () => {
    assert.equal(webHrefForActionTarget("/projeler/p1/gorevler/t1"), projectTaskHref("p1", "t1"));
    assert.equal(webHrefForActionTarget("/projeler/p1/gorevler/t1/duzenle"), projectTaskHref("p1", "t1"));
  });
});
