"use client";

import { useRouter } from "next/navigation";
import { FormEvent, useState } from "react";

import { useConfirmDialog } from "@/components/ui/ConfirmDialog";
import { Button } from "@/components/ui/Button";
import { DateInput } from "@/components/ui/DateInput";
import { Input } from "@/components/ui/Input";
import { Select } from "@/components/ui/Select";
import { StatusBadge } from "@/components/ui/StatusBadge";
import { Textarea } from "@/components/ui/Textarea";
import { API_BASE, apiClient, ApiError } from "@/lib/api";
import { SCHEDULE_STATUS, TASK_STATUS } from "@/lib/status";
import {
  FILE_CATEGORY_LABELS,
  PHOTO_STAGE_LABELS,
  SCHEDULE_STATUS_LABELS,
  TASK_PRIORITY_LABELS,
  TASK_STATUS_LABELS,
  type Employee,
  type FileCategory,
  type PhotoStage,
  type Project,
  type ProjectFile,
  type ProjectMember,
  type ProjectNote,
  type ProjectPhoto,
  type ProjectTask,
  type ScheduleItem,
  type TaskPriority,
} from "@/lib/types";

function useAction(locked: boolean) {
  const router = useRouter();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function run(fn: () => Promise<unknown>) {
    if (locked) return false;
    setBusy(true);
    setError(null);
    try {
      await fn();
      router.refresh();
      return true;
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Bağlantı hatası");
      return false;
    } finally {
      setBusy(false);
    }
  }
  return { busy, error, run };
}

function LockedNote() {
  return (
    <p className="text-xs text-text-muted">
      Proje tamamlandı veya iptal edildi; yeni kayıt eklenemez. Geçmiş kayıtlar görüntülenebilir.
    </p>
  );
}

// ---------- Personel / Ekip ----------

export function MembersSection({
  project,
  members,
  employees,
  locked,
}: {
  project: Project;
  members: ProjectMember[];
  employees: Employee[];
  locked: boolean;
}) {
  const { busy, error, run } = useAction(locked);
  const [form, setForm] = useState({ employee_id: "", role_title: "" });

  const active = members.filter((m) => m.is_active);
  const past = members.filter((m) => !m.is_active);
  const assignedIds = new Set(active.map((m) => m.employee_id));
  const available = employees.filter((e) => !assignedIds.has(e.id));

  async function submit(e: FormEvent) {
    e.preventDefault();
    const ok = await run(() =>
      apiClient(`/api/v1/projects/${project.id}/members`, {
        method: "POST",
        body: JSON.stringify(form),
      })
    );
    if (ok) setForm({ employee_id: "", role_title: "" });
  }

  return (
    <div className="flex flex-col gap-4">
      <div>
        <div className="mb-2 text-xs font-semibold uppercase tracking-widest text-text-muted">
          Aktif Ekip ({active.length})
        </div>
        {active.length === 0 ? (
          <p className="text-text-muted">Henüz ekip üyesi atanmamış.</p>
        ) : (
          <ul className="flex flex-col gap-1.5">
            {active.map((m) => (
              <li key={m.id} className="flex items-center justify-between rounded-md border border-border px-3 py-2">
                <span>
                  <span className="font-medium">{m.employee_name}</span>
                  {m.role_title && <span className="ml-2 text-text-muted">{m.role_title}</span>}
                  {m.start_date && (
                    <span className="ml-2 text-xs text-text-muted">
                      {new Date(m.start_date).toLocaleDateString("tr-TR")} —
                    </span>
                  )}
                </span>
                {!locked && (
                  <button
                    type="button"
                    disabled={busy}
                    onClick={() =>
                      run(() =>
                        apiClient(`/api/v1/projects/${project.id}/members/${m.id}`, { method: "DELETE" })
                      )
                    }
                    className="text-xs text-danger hover:underline"
                  >
                    Ekipten Çıkar
                  </button>
                )}
              </li>
            ))}
          </ul>
        )}
      </div>

      {past.length > 0 && (
        <details className="text-sm">
          <summary className="cursor-pointer text-xs font-semibold uppercase tracking-widest text-text-muted">
            Geçmiş Ekip ({past.length})
          </summary>
          <ul className="mt-2 flex flex-col gap-1 text-text-muted">
            {past.map((m) => (
              <li key={m.id}>
                {m.employee_name}
                {m.role_title && ` · ${m.role_title}`}
                {m.end_date && ` · ayrıldı ${new Date(m.end_date).toLocaleDateString("tr-TR")}`}
              </li>
            ))}
          </ul>
        </details>
      )}

      {locked ? (
        <LockedNote />
      ) : (
        <form onSubmit={submit} className="flex flex-wrap items-end gap-2 border-t border-border pt-3">
          <Select
            required
            value={form.employee_id}
            onChange={(e) => setForm({ ...form, employee_id: e.target.value })}
            aria-label="Personel"
            className="w-56"
          >
            <option value="">Personel seçin</option>
            {available.map((e) => (
              <option key={e.id} value={e.id}>
                {e.full_name}
                {e.position ? ` — ${e.position}` : ""}
              </option>
            ))}
          </Select>
          <Input
            placeholder="Görev/rol (ör. Şantiye Şefi)"
            value={form.role_title}
            onChange={(e) => setForm({ ...form, role_title: e.target.value })}
          />
          <Button type="submit" loading={busy} disabled={!form.employee_id}>
            Ekibe Ekle
          </Button>
        </form>
      )}
      {error && <p className="text-xs text-danger">{error}</p>}
    </div>
  );
}

// ---------- Planlama ----------

export function ScheduleSection({
  project,
  items,
  locked,
}: {
  project: Project;
  items: ScheduleItem[];
  locked: boolean;
}) {
  const { busy, error, run } = useAction(locked);
  const [form, setForm] = useState({ name: "", start_date: "", end_date: "" });

  async function submit(e: FormEvent) {
    e.preventDefault();
    const ok = await run(() =>
      apiClient(`/api/v1/projects/${project.id}/schedule`, {
        method: "POST",
        body: JSON.stringify({
          name: form.name,
          start_date: form.start_date || null,
          end_date: form.end_date || null,
          sort_order: items.length,
        }),
      })
    );
    if (ok) setForm({ name: "", start_date: "", end_date: "" });
  }

  return (
    <div className="flex flex-col gap-3">
      {items.length === 0 ? (
        <p className="text-text-muted">Henüz planlama aşaması yok.</p>
      ) : (
        <ol className="flex flex-col gap-2">
          {items.map((it) => (
            <li key={it.id} className="rounded-md border border-border px-3 py-2">
              <div className="flex flex-wrap items-center justify-between gap-2">
                <span className="font-medium">{it.name}</span>
                <div className="flex items-center gap-2">
                  {it.task_count > 0 && (
                    <span className="text-xs text-text-muted">
                      {it.completed_task_count}/{it.task_count} görev
                    </span>
                  )}
                  {locked ? (
                    <StatusBadge status={it.status} registry={SCHEDULE_STATUS} />
                  ) : (
                    <Select
                      value={it.status}
                      disabled={busy}
                      onChange={(e) =>
                        run(() =>
                          apiClient(`/api/v1/projects/${project.id}/schedule/${it.id}`, {
                            method: "PUT",
                            body: JSON.stringify({
                              name: it.name,
                              description: it.description,
                              start_date: it.start_date,
                              end_date: it.end_date,
                              status: e.target.value,
                              sort_order: it.sort_order,
                            }),
                          })
                        )
                      }
                      aria-label="Aşama durumu"
                      className="py-1 text-xs"
                    >
                      {Object.entries(SCHEDULE_STATUS_LABELS).map(([k, label]) => (
                        <option key={k} value={k}>
                          {label}
                        </option>
                      ))}
                    </Select>
                  )}
                </div>
              </div>
              {(it.start_date || it.end_date) && (
                <div className="mt-1 text-xs text-text-muted">
                  {it.start_date ? new Date(it.start_date).toLocaleDateString("tr-TR") : "—"}
                  {" → "}
                  {it.end_date ? new Date(it.end_date).toLocaleDateString("tr-TR") : "—"}
                </div>
              )}
            </li>
          ))}
        </ol>
      )}

      {locked ? (
        <LockedNote />
      ) : (
        <form onSubmit={submit} className="flex flex-wrap items-end gap-2 border-t border-border pt-3">
          <Input
            placeholder="Aşama adı (ör. Kaba İnşaat)"
            required
            value={form.name}
            onChange={(e) => setForm({ ...form, name: e.target.value })}
          />
          <DateInput
            value={form.start_date}
            onChange={(e) => setForm({ ...form, start_date: e.target.value })}
            aria-label="Başlangıç"
          />
          <DateInput
            value={form.end_date}
            onChange={(e) => setForm({ ...form, end_date: e.target.value })}
            aria-label="Bitiş"
          />
          <Button type="submit" loading={busy}>
            Aşama Ekle
          </Button>
        </form>
      )}
      {error && <p className="text-xs text-danger">{error}</p>}
    </div>
  );
}

// ---------- Görevler ----------

export function TasksSection({
  project,
  tasks,
  scheduleItems,
  members,
  locked,
}: {
  project: Project;
  tasks: ProjectTask[];
  scheduleItems: ScheduleItem[];
  members: ProjectMember[];
  locked: boolean;
}) {
  const { busy, error, run } = useAction(locked);
  const [form, setForm] = useState({
    title: "",
    schedule_item_id: "",
    assigned_employee_id: "",
    priority: "normal" as TaskPriority,
    due_date: "",
  });

  const activeMembers = members.filter((m) => m.is_active);

  async function submit(e: FormEvent) {
    e.preventDefault();
    const ok = await run(() =>
      apiClient(`/api/v1/projects/${project.id}/tasks`, {
        method: "POST",
        body: JSON.stringify({
          title: form.title,
          schedule_item_id: form.schedule_item_id || null,
          assigned_employee_id: form.assigned_employee_id || null,
          priority: form.priority,
          due_date: form.due_date || null,
        }),
      })
    );
    if (ok) setForm({ ...form, title: "", due_date: "" });
  }

  function updateStatus(t: ProjectTask, status: string) {
    if (status === "completed") {
      return run(() =>
        apiClient(`/api/v1/projects/${project.id}/tasks/${t.id}/complete`, { method: "POST" })
      );
    }
    return run(() =>
      apiClient(`/api/v1/projects/${project.id}/tasks/${t.id}`, {
        method: "PUT",
        body: JSON.stringify({
          title: t.title,
          description: t.description,
          schedule_item_id: t.schedule_item_id,
          assigned_employee_id: t.assigned_employee_id,
          priority: t.priority,
          status,
          due_date: t.due_date,
        }),
      })
    );
  }

  return (
    <div className="flex flex-col gap-3">
      {tasks.length === 0 ? (
        <p className="text-text-muted">Henüz görev yok.</p>
      ) : (
        <ul className="flex flex-col gap-2">
          {tasks.map((t) => (
            <li key={t.id} className="rounded-md border border-border px-3 py-2">
              <div className="flex flex-wrap items-center justify-between gap-2">
                <span>
                  <span className={t.status === "completed" ? "text-text-muted line-through" : "font-medium"}>
                    {t.title}
                  </span>
                  {t.priority !== "normal" && (
                    <span
                      className={`ml-2 text-xs ${t.priority === "urgent" || t.priority === "high" ? "text-danger" : "text-text-muted"}`}
                    >
                      {TASK_PRIORITY_LABELS[t.priority]}
                    </span>
                  )}
                  {t.assigned_name && <span className="ml-2 text-text-muted">· {t.assigned_name}</span>}
                </span>
                <div className="flex items-center gap-2">
                  {t.due_date && (
                    <span className={`text-xs ${t.is_overdue ? "text-danger" : "text-text-muted"}`}>
                      {new Date(t.due_date).toLocaleDateString("tr-TR")}
                      {t.is_overdue && " · gecikti"}
                    </span>
                  )}
                  {locked ? (
                    <StatusBadge status={t.status} registry={TASK_STATUS} />
                  ) : (
                    <Select
                      value={t.status}
                      disabled={busy}
                      onChange={(e) => updateStatus(t, e.target.value)}
                      aria-label="Görev durumu"
                      className="py-1 text-xs"
                    >
                      {Object.entries(TASK_STATUS_LABELS).map(([k, label]) => (
                        <option key={k} value={k}>
                          {label}
                        </option>
                      ))}
                    </Select>
                  )}
                </div>
              </div>
            </li>
          ))}
        </ul>
      )}

      {locked ? (
        <LockedNote />
      ) : (
        <form onSubmit={submit} className="flex flex-wrap items-end gap-2 border-t border-border pt-3">
          <Input
            placeholder="Görev başlığı"
            required
            value={form.title}
            onChange={(e) => setForm({ ...form, title: e.target.value })}
          />
          <Select
            value={form.schedule_item_id}
            onChange={(e) => setForm({ ...form, schedule_item_id: e.target.value })}
            aria-label="Aşama"
            className="w-44"
          >
            <option value="">Aşama (opsiyonel)</option>
            {scheduleItems.map((s) => (
              <option key={s.id} value={s.id}>
                {s.name}
              </option>
            ))}
          </Select>
          <Select
            value={form.assigned_employee_id}
            onChange={(e) => setForm({ ...form, assigned_employee_id: e.target.value })}
            aria-label="Atanan"
            className="w-44"
          >
            <option value="">Atanan (opsiyonel)</option>
            {activeMembers.map((m) => (
              <option key={m.employee_id} value={m.employee_id}>
                {m.employee_name}
              </option>
            ))}
          </Select>
          <Select
            value={form.priority}
            onChange={(e) => setForm({ ...form, priority: e.target.value as TaskPriority })}
            aria-label="Öncelik"
            className="w-32"
          >
            {Object.entries(TASK_PRIORITY_LABELS).map(([k, label]) => (
              <option key={k} value={k}>
                {label}
              </option>
            ))}
          </Select>
          <DateInput
            value={form.due_date}
            onChange={(e) => setForm({ ...form, due_date: e.target.value })}
            aria-label="Termin"
          />
          <Button type="submit" loading={busy}>
            Görev Ekle
          </Button>
        </form>
      )}
      {error && <p className="text-xs text-danger">{error}</p>}
    </div>
  );
}

// ---------- Dosyalar ----------

const fileInputClass =
  "rounded-md border border-border bg-surface px-3 py-2 text-sm text-text file:mr-3 file:rounded file:border-0 file:bg-surface-hover file:px-2 file:py-1 file:text-xs";

function formatSize(bytes: number) {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}

// Yükleme multipart olduğu için apiClient (JSON) yerine doğrudan fetch;
// credentials: "include" oturum çerezini taşır.
async function uploadMultipart(path: string, form: FormData) {
  const res = await fetch(`${API_BASE}${path}`, {
    method: "POST",
    credentials: "include",
    body: form,
  });
  const text = await res.text();
  const body = text ? JSON.parse(text) : null;
  if (!res.ok) {
    throw new ApiError(res.status, body?.error ?? "Yükleme başarısız");
  }
  return body;
}

export function FilesSection({
  project,
  files,
  locked,
}: {
  project: Project;
  files: ProjectFile[];
  locked: boolean;
}) {
  const { busy, error, run } = useAction(locked);
  const [category, setCategory] = useState<FileCategory>("other");
  const [description, setDescription] = useState("");
  const { confirm, dialog } = useConfirmDialog();

  function upload(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const input = e.currentTarget.elements.namedItem("file") as HTMLInputElement;
    const file = input.files?.[0];
    if (!file) return;
    const fd = new FormData();
    fd.append("file", file);
    fd.append("category", category);
    fd.append("description", description);
    run(() => uploadMultipart(`/api/v1/projects/${project.id}/files`, fd)).then((ok) => {
      if (ok) {
        input.value = "";
        setDescription("");
      }
    });
  }

  async function handleDelete(f: ProjectFile) {
    const ok = await confirm({ title: "Dosyayı Sil", message: `${f.original_name} silinsin mi?`, danger: true });
    if (!ok) return;
    run(() => apiClient(`/api/v1/projects/${project.id}/files/${f.id}`, { method: "DELETE" }));
  }

  return (
    <div className="flex flex-col gap-3">
      {files.length === 0 ? (
        <p className="text-text-muted">Henüz belge yüklenmemiş.</p>
      ) : (
        <ul className="flex flex-col gap-1.5">
          {files.map((f) => (
            <li key={f.id} className="flex flex-wrap items-center justify-between gap-2 rounded-md border border-border px-3 py-2">
              <span>
                <a
                  href={`${API_BASE}/api/v1/projects/${project.id}/files/${f.id}/download`}
                  className="font-medium hover:text-gold hover:underline"
                >
                  {f.original_name}
                </a>
                <span className="ml-2 text-xs text-text-muted">
                  {FILE_CATEGORY_LABELS[f.category]} · {formatSize(f.size_bytes)}
                </span>
                {f.description && <div className="text-xs text-text-muted">{f.description}</div>}
              </span>
              {!locked && (
                <button
                  type="button"
                  disabled={busy}
                  onClick={() => handleDelete(f)}
                  className="text-xs text-danger hover:underline"
                >
                  Sil
                </button>
              )}
            </li>
          ))}
        </ul>
      )}

      {locked ? (
        <LockedNote />
      ) : (
        <form onSubmit={upload} className="flex flex-wrap items-end gap-2 border-t border-border pt-3">
          <input type="file" name="file" required className={fileInputClass} aria-label="Dosya" />
          <Select
            value={category}
            onChange={(e) => setCategory(e.target.value as FileCategory)}
            aria-label="Kategori"
            className="w-40"
          >
            {Object.entries(FILE_CATEGORY_LABELS).map(([k, label]) => (
              <option key={k} value={k}>
                {label}
              </option>
            ))}
          </Select>
          <Input
            placeholder="Açıklama"
            value={description}
            onChange={(e) => setDescription(e.target.value)}
          />
          <Button type="submit" loading={busy}>
            Yükle
          </Button>
        </form>
      )}
      {error && <p className="text-xs text-danger">{error}</p>}
      {dialog}
    </div>
  );
}

// ---------- Şantiye Fotoğrafları ----------

export function PhotosSection({
  project,
  photos,
  locked,
}: {
  project: Project;
  photos: ProjectPhoto[];
  locked: boolean;
}) {
  const { busy, error, run } = useAction(locked);
  const [stage, setStage] = useState<PhotoStage>("progress");
  const [description, setDescription] = useState("");

  function upload(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const input = e.currentTarget.elements.namedItem("file") as HTMLInputElement;
    const file = input.files?.[0];
    if (!file) return;
    const fd = new FormData();
    fd.append("file", file);
    fd.append("stage", stage);
    fd.append("description", description);
    run(() => uploadMultipart(`/api/v1/projects/${project.id}/photos`, fd)).then((ok) => {
      if (ok) {
        input.value = "";
        setDescription("");
      }
    });
  }

  const stages: PhotoStage[] = ["before", "progress", "after"];

  return (
    <div className="flex flex-col gap-4">
      {photos.length === 0 ? (
        <p className="text-text-muted">Henüz şantiye fotoğrafı yok.</p>
      ) : (
        stages.map((st) => {
          const group = photos.filter((p) => p.stage === st);
          if (group.length === 0) return null;
          return (
            <div key={st}>
              <div className="mb-2 text-xs font-semibold uppercase tracking-widest text-text-muted">
                {PHOTO_STAGE_LABELS[st]} ({group.length})
              </div>
              <div className="grid grid-cols-2 gap-2 sm:grid-cols-3 md:grid-cols-4">
                {group.map((p) => (
                  <figure key={p.id} className="overflow-hidden rounded-md border border-border">
                    <a
                      href={`${API_BASE}/api/v1/projects/${project.id}/photos/${p.id}/content`}
                      target="_blank"
                      rel="noreferrer"
                    >
                      {/* eslint-disable-next-line @next/next/no-img-element */}
                      <img
                        src={`${API_BASE}/api/v1/projects/${project.id}/photos/${p.id}/content`}
                        alt={p.description || p.original_name}
                        className="h-32 w-full object-cover"
                      />
                    </a>
                    <figcaption className="flex items-center justify-between gap-1 px-2 py-1 text-xs text-text-muted">
                      <span className="truncate">{p.description || p.original_name}</span>
                      {!locked && (
                        <button
                          type="button"
                          disabled={busy}
                          onClick={() =>
                            run(() =>
                              apiClient(`/api/v1/projects/${project.id}/photos/${p.id}`, {
                                method: "DELETE",
                              })
                            )
                          }
                          className="shrink-0 text-danger hover:underline"
                        >
                          Sil
                        </button>
                      )}
                    </figcaption>
                  </figure>
                ))}
              </div>
            </div>
          );
        })
      )}

      {locked ? (
        <LockedNote />
      ) : (
        <form onSubmit={upload} className="flex flex-wrap items-end gap-2 border-t border-border pt-3">
          <input type="file" name="file" accept="image/*" required className={fileInputClass} aria-label="Fotoğraf" />
          <Select
            value={stage}
            onChange={(e) => setStage(e.target.value as PhotoStage)}
            aria-label="Aşama"
            className="w-32"
          >
            {Object.entries(PHOTO_STAGE_LABELS).map(([k, label]) => (
              <option key={k} value={k}>
                {label}
              </option>
            ))}
          </Select>
          <Input
            placeholder="Açıklama"
            value={description}
            onChange={(e) => setDescription(e.target.value)}
          />
          <Button type="submit" loading={busy}>
            Fotoğraf Yükle
          </Button>
        </form>
      )}
      {error && <p className="text-xs text-danger">{error}</p>}
    </div>
  );
}

// ---------- Notlar ----------

export function NotesSection({
  project,
  notes,
  locked,
}: {
  project: Project;
  notes: ProjectNote[];
  locked: boolean;
}) {
  const { busy, error, run } = useAction(locked);
  const [content, setContent] = useState("");

  async function submit(e: FormEvent) {
    e.preventDefault();
    const ok = await run(() =>
      apiClient(`/api/v1/projects/${project.id}/notes`, {
        method: "POST",
        body: JSON.stringify({ content }),
      })
    );
    if (ok) setContent("");
  }

  return (
    <div className="flex flex-col gap-3">
      {notes.length === 0 ? (
        <p className="text-text-muted">Henüz not yok.</p>
      ) : (
        <ul className="flex flex-col gap-2">
          {notes.map((n) => (
            <li key={n.id} className="rounded-md border border-border px-3 py-2">
              <div className="whitespace-pre-wrap">{n.content}</div>
              <div className="mt-1 text-xs text-text-muted">
                {n.created_by_name || "Bilinmeyen"} · {new Date(n.created_at).toLocaleString("tr-TR")}
              </div>
            </li>
          ))}
        </ul>
      )}

      {locked ? (
        <LockedNote />
      ) : (
        <form onSubmit={submit} className="flex flex-col gap-2 border-t border-border pt-3">
          <Textarea
            className="min-h-20"
            placeholder="Proje notu yazın…"
            required
            value={content}
            onChange={(e) => setContent(e.target.value)}
          />
          <div>
            <Button type="submit" loading={busy}>
              Not Ekle
            </Button>
          </div>
        </form>
      )}
      {error && <p className="text-xs text-danger">{error}</p>}
    </div>
  );
}
