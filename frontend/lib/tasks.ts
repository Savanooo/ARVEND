// Görev notları ("Bilgi Ver") ve görev düzenlemenin saf yardımcıları --
// Operasyon > Görevler kullanır, node testleri (tasks.test.mts) içe aktarır.
// Davranış mobil task_detail_screen.dart / task_update_sheet.dart /
// task_form_screen.dart ile aynıdır.
import { TASK_STATUS_LABELS, type ProjectTask, type TaskPriority, type TaskStatus } from "./types.ts";

/**
 * GET /projects/{id}/tasks/{taskId}/updates satırı (backend
 * taskUpdateResponse). status_from/status_to yalnızca not durumu da
 * değiştirdiyse dolu; sunucu eskiden yeniye sıralar.
 */
export interface TaskUpdate {
  id: string;
  user_id: string | null;
  author_name: string;
  body: string;
  status_from: string;
  status_to: string;
  created_at: string;
}

/**
 * Proje detayında tek görevi açan sorgu parametresi: ?tab=operasyon&gorev={id}
 * (lib/dashboard.ts projectTaskHref yazar, OperationSections TaskRow okur).
 */
export const TASK_FOCUS_PARAM = "gorev";

/** Sunucudaki sınır (service maxTaskUpdateRunes) ile aynı. */
export const TASK_UPDATE_MAX_LENGTH = 2000;

export const TASK_UPDATE_EMPTY_MESSAGE = "Bir not yaz ya da durumu değiştir.";

/**
 * "Bilgi Ver"deki durum seçenekleri: mevcut durum dışındaki Yapılacak /
 * Devam Ediyor / Tamamlandı (iptal bu pencereden yapılmaz -- mobil ile aynı).
 */
export function taskUpdateStatusChoices(current: TaskStatus): TaskStatus[] {
  return (["todo", "in_progress", "completed"] as const).filter((s) => s !== current);
}

/**
 * POST .../updates gövdesi; ne not ne durum değişikliği varsa null (sunucu
 * da 400 "not ya da durum değişikliği gerekli" döner). status yalnızca
 * seçilip mevcut durumdan farklıysa gönderilir.
 */
export function taskUpdateRequest(
  body: string,
  status: TaskStatus | null,
  current: TaskStatus
): { body: string; status?: TaskStatus } | null {
  const text = body.trim();
  const change = status && status !== current ? status : null;
  if (!text && !change) return null;
  return change ? { body: text, status: change } : { body: text };
}

/** Notun durum satırı: "Yapılacak → Devam Ediyor"; durum değişmediyse null. */
export function taskUpdateStatusLine(u: Pick<TaskUpdate, "status_from" | "status_to">): string | null {
  if (!u.status_to) return null;
  const label = (s: string) => TASK_STATUS_LABELS[s as TaskStatus] ?? s;
  return `${label(u.status_from)} → ${label(u.status_to)}`;
}

// ---------- Düzenleme (PUT /projects/{id}/tasks/{taskId}) ----------

export interface TaskEditDraft {
  title: string;
  description: string;
  schedule_item_id: string;
  assigned_employee_id: string;
  priority: TaskPriority;
  status: TaskStatus;
  due_date: string;
}

export function taskEditDraft(t: ProjectTask): TaskEditDraft {
  return {
    title: t.title,
    description: t.description ?? "",
    schedule_item_id: t.schedule_item_id ?? "",
    assigned_employee_id: t.assigned_employee_id ?? "",
    priority: t.priority,
    status: t.status,
    // Sunucu "YYYY-MM-DD" döner; tarih alanı da bu biçimi ister.
    due_date: t.due_date ? t.due_date.slice(0, 10) : "",
  };
}

/**
 * PUT gövdesi. Uç satırı BÜTÜNÜYLE yeniden yazar: gönderilmeyen alan
 * silinir, bu yüzden her alan (boşsa null) gönderilir.
 */
export function taskEditRequest(d: TaskEditDraft) {
  return {
    title: d.title.trim(),
    description: d.description.trim(),
    schedule_item_id: d.schedule_item_id || null,
    assigned_employee_id: d.assigned_employee_id || null,
    priority: d.priority,
    status: d.status,
    due_date: d.due_date || null,
  };
}
