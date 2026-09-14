"use client";

import { useRouter } from "next/navigation";
import { FormEvent, useEffect, useState } from "react";

import { Badge } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { apiClient, ApiError } from "@/lib/api";
import { formatMoney, formatSignedMoney } from "@/lib/format";
import {
  CHANGE_ORDER_STATUS_LABELS,
  CHANGE_ORDER_TYPE_LABELS,
  type ChangeOrder,
  type ChangeOrderItemInput,
  type ChangeOrderStatus,
  type ChangeOrderType,
  type Project,
} from "@/lib/types";

const inputClass =
  "rounded-md border border-border bg-surface px-3 py-2 text-sm text-text placeholder:text-text-muted/60 outline-none focus:border-gold";

const STATUS_TONE: Record<ChangeOrderStatus, "muted" | "gold" | "success" | "danger"> = {
  draft: "muted",
  sent: "gold",
  approved: "success",
  rejected: "danger",
  cancelled: "danger",
  superseded: "muted",
};

// Anahtar form ÖRNEĞİ başına bir kez üretilir, yalnızca ONAYLANMIŞ bir
// gönderimden SONRA yenilenir (bkz. FinanceSections.tsx'teki aynı ilke).
function newIdempotencyKey() {
  return crypto.randomUUID();
}

function useChangeOrderAction(locked: boolean) {
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

type ItemDraft = { description: string; quantity: string; unit: string; unit_price: string };

const emptyItem = (): ItemDraft => ({ description: "", quantity: "1", unit: "adet", unit_price: "" });

function ItemsEditor({ items, setItems }: { items: ItemDraft[]; setItems: (items: ItemDraft[]) => void }) {
  return (
    <div className="flex flex-col gap-2">
      {items.map((it, i) => (
        <div key={i} className="grid grid-cols-12 gap-2">
          <input
            className={`${inputClass} col-span-5`}
            placeholder="Kalem açıklaması"
            value={it.description}
            onChange={(e) => setItems(items.map((x, j) => (j === i ? { ...x, description: e.target.value } : x)))}
          />
          <input
            className={`${inputClass} col-span-2`}
            type="number"
            step="0.01"
            placeholder="Miktar"
            value={it.quantity}
            onChange={(e) => setItems(items.map((x, j) => (j === i ? { ...x, quantity: e.target.value } : x)))}
          />
          <input
            className={`${inputClass} col-span-2`}
            placeholder="Birim"
            value={it.unit}
            onChange={(e) => setItems(items.map((x, j) => (j === i ? { ...x, unit: e.target.value } : x)))}
          />
          <input
            className={`${inputClass} col-span-2`}
            type="number"
            step="0.01"
            placeholder="Birim Fiyat"
            value={it.unit_price}
            onChange={(e) => setItems(items.map((x, j) => (j === i ? { ...x, unit_price: e.target.value } : x)))}
          />
          <button
            type="button"
            className="col-span-1 text-xs text-danger disabled:opacity-40"
            disabled={items.length <= 1}
            onClick={() => setItems(items.filter((_, j) => j !== i))}
          >
            Sil
          </button>
        </div>
      ))}
      <Button type="button" variant="ghost" onClick={() => setItems([...items, emptyItem()])}>
        + Kalem Ekle
      </Button>
    </div>
  );
}

function itemsToInput(items: ItemDraft[]): ChangeOrderItemInput[] {
  return items
    .filter((it) => it.description.trim() !== "")
    .map((it) => ({
      description: it.description,
      quantity: Number(it.quantity) || 0,
      unit: it.unit,
      unit_price: Number(it.unit_price) || 0,
    }));
}

function ChangeOrderCard({
  project,
  co,
  locked,
}: {
  project: Project;
  co: ChangeOrder;
  locked: boolean;
}) {
  const { busy, error, run } = useChangeOrderAction(locked);
  const [expanded, setExpanded] = useState(false);
  const [editing, setEditing] = useState(false);
  const [form, setForm] = useState({
    change_type: co.change_type as ChangeOrderType,
    title: co.title,
    vat_rate: String(co.vat_rate),
    customer_notes: co.customer_notes,
    internal_notes: co.internal_notes,
  });
  const [items, setItems] = useState<ItemDraft[]>([emptyItem()]);
  const [emailKey, setEmailKey] = useState(newIdempotencyKey); // yalnızca form-instance'ı zorlamak için
  const [showEmailForm, setShowEmailForm] = useState(false);
  const [mail, setMail] = useState({ to: project.customer_email, subject: "", message: "" });
  const [copied, setCopied] = useState(false);

  // co (liste ucundan gelir) HİÇBİR ZAMAN kalemleri taşımaz -- yalnızca
  // tekil detay ucu (GET .../change-orders/{id}) kalemleri döner. Kart
  // genişletildiğinde GERÇEK kalemleri buradan çekeriz; aksi halde hem
  // salt-okunur kalem tablosu hem de "Düzenle" formu HER ZAMAN boş/tek
  // satırdan başlar ve kaydetmek gerçek kalemleri SESSİZCE siler (bkz.
  // denetim bulgusu -- kritik).
  const [detail, setDetail] = useState<ChangeOrder | null>(null);
  const [loadingDetail, setLoadingDetail] = useState(false);

  async function fetchDetail() {
    setLoadingDetail(true);
    try {
      const full = await apiClient<ChangeOrder>(`/api/v1/projects/${project.id}/change-orders/${co.id}`);
      setDetail(full);
      setItems(
        full.items && full.items.length > 0
          ? full.items.map((it) => ({
              description: it.description,
              quantity: String(it.quantity),
              unit: it.unit,
              unit_price: String(it.unit_price),
            }))
          : [emptyItem()]
      );
    } catch {
      // Sessizce yut: salt-okunur görünüm boş kalem tablosuna düşer,
      // ama "Düzenle" AŞAĞIDA ayrıca korunuyor (detay yüklenmeden
      // düzenleme açılmaz) -- yanlış/eksik veri asla kaydedilmez.
    } finally {
      setLoadingDetail(false);
    }
  }

  useEffect(() => {
    if (!expanded || detail || loadingDetail) return;
    fetchDetail();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [expanded]);

  const displayItems = detail?.items ?? [];

  const c = co.currency;
  const isDraft = co.status === "draft";
  const isSent = co.status === "sent";
  const canRevise = co.status === "sent" || co.status === "rejected";

  async function saveDraft(e: FormEvent) {
    e.preventDefault();
    const body = {
      change_type: form.change_type,
      title: form.title,
      description: "",
      vat_rate: Number(form.vat_rate) || 0,
      customer_notes: form.customer_notes,
      internal_notes: form.internal_notes,
      items: itemsToInput(items),
    };
    const ok = await run(() =>
      apiClient(`/api/v1/projects/${project.id}/change-orders/${co.id}`, { method: "PUT", body: JSON.stringify(body) })
    );
    if (ok) {
      setEditing(false);
      await fetchDetail();
    }
  }

  async function send() {
    await run(() => apiClient(`/api/v1/projects/${project.id}/change-orders/${co.id}/send`, { method: "POST" }));
  }

  async function cancel() {
    if (!confirm("Bu ek işi iptal etmek istediğinize emin misiniz?")) return;
    await run(() => apiClient(`/api/v1/projects/${project.id}/change-orders/${co.id}/cancel`, { method: "POST" }));
  }

  async function revise() {
    await run(() => apiClient(`/api/v1/projects/${project.id}/change-orders/${co.id}/revise`, { method: "POST" }));
  }

  async function sendEmail(e: FormEvent) {
    e.preventDefault();
    const ok = await run(() =>
      apiClient(`/api/v1/projects/${project.id}/change-orders/${co.id}/send-email`, {
        method: "POST",
        body: JSON.stringify(mail),
      })
    );
    if (ok) {
      setEmailKey(newIdempotencyKey());
      setShowEmailForm(false);
    }
  }

  function shareUrl() {
    return `${window.location.origin}/ek-is/${co.active_share_token ?? ""}`;
  }

  return (
    <div className="rounded-md border border-border p-3">
      <button
        type="button"
        className="flex w-full items-center justify-between gap-2 text-left"
        onClick={() => setExpanded(!expanded)}
      >
        <div>
          <span className="font-medium">{co.change_order_no}</span>
          <span className="ml-2 text-text-muted">{co.title}</span>
        </div>
        <div className="flex items-center gap-2">
          <span className={co.change_type === "addition" ? "text-success" : "text-danger"}>
            {formatSignedMoney(co.change_type === "deduction" ? -co.grand_total : co.grand_total, c)}
          </span>
          <Badge tone={STATUS_TONE[co.status]}>{CHANGE_ORDER_STATUS_LABELS[co.status]}</Badge>
        </div>
      </button>

      {expanded && (
        <div className="mt-3 flex flex-col gap-3 border-t border-border pt-3 text-sm">
          {editing ? (
            <form onSubmit={saveDraft} className="flex flex-col gap-2">
              <div className="grid grid-cols-2 gap-2">
                <select
                  className={inputClass}
                  value={form.change_type}
                  onChange={(e) => setForm({ ...form, change_type: e.target.value as ChangeOrderType })}
                >
                  <option value="addition">{CHANGE_ORDER_TYPE_LABELS.addition}</option>
                  <option value="deduction">{CHANGE_ORDER_TYPE_LABELS.deduction}</option>
                </select>
                <input
                  className={inputClass}
                  placeholder="Başlık"
                  value={form.title}
                  onChange={(e) => setForm({ ...form, title: e.target.value })}
                />
              </div>
              <ItemsEditor items={items} setItems={setItems} />
              <div className="grid grid-cols-3 gap-2">
                <input
                  className={inputClass}
                  type="number"
                  step="0.01"
                  placeholder="KDV %"
                  value={form.vat_rate}
                  onChange={(e) => setForm({ ...form, vat_rate: e.target.value })}
                />
                <input
                  className={`${inputClass} col-span-2`}
                  placeholder="Müşteriye görünecek not"
                  value={form.customer_notes}
                  onChange={(e) => setForm({ ...form, customer_notes: e.target.value })}
                />
              </div>
              <textarea
                className={inputClass}
                placeholder="Dahili not (yalnızca ekip görür)"
                value={form.internal_notes}
                onChange={(e) => setForm({ ...form, internal_notes: e.target.value })}
              />
              <div className="flex gap-2">
                <Button type="submit" disabled={busy}>
                  Kaydet
                </Button>
                <Button type="button" variant="ghost" onClick={() => setEditing(false)}>
                  Vazgeç
                </Button>
              </div>
            </form>
          ) : (
            <>
              <table className="w-full text-sm">
                <thead>
                  <tr className="text-left text-xs uppercase tracking-widest text-text-muted">
                    <th className="pb-1">Kalem</th>
                    <th className="pb-1 text-right">Miktar</th>
                    <th className="pb-1 text-right">Birim Fiyat</th>
                    <th className="pb-1 text-right">Tutar</th>
                  </tr>
                </thead>
                <tbody>
                  {loadingDetail && displayItems.length === 0 && (
                    <tr>
                      <td colSpan={4} className="py-1 text-text-muted">
                        Kalemler yükleniyor...
                      </td>
                    </tr>
                  )}
                  {displayItems.map((it) => (
                    <tr key={it.id}>
                      <td className="py-0.5">{it.description}</td>
                      <td className="py-0.5 text-right">
                        {it.quantity} {it.unit}
                      </td>
                      <td className="py-0.5 text-right">{formatMoney(it.unit_price, c)}</td>
                      <td className="py-0.5 text-right">{formatMoney(it.line_total, c)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
              <div className="flex flex-wrap items-center justify-between gap-2 border-t border-border pt-2 text-xs text-text-muted">
                <span>
                  Ara Toplam: {formatMoney(co.subtotal, c)} · KDV (%{co.vat_rate}): {formatMoney(co.vat_amount, c)}
                </span>
                <span className="text-sm font-medium text-text">Toplam: {formatMoney(co.grand_total, c)}</span>
              </div>
              {co.customer_notes && <p className="text-xs text-text-muted">Müşteri notu: {co.customer_notes}</p>}
              {co.internal_notes && <p className="text-xs text-text-muted">Dahili not: {co.internal_notes}</p>}
              {co.profitability && (
                <div className="rounded-md bg-surface-hover p-2 text-xs">
                  <div className="mb-1 font-medium uppercase tracking-widest text-text-muted">Kârlılık (dahili)</div>
                  <div className="grid grid-cols-2 gap-1 sm:grid-cols-4">
                    <span>Gelir Etkisi: {formatSignedMoney(co.profitability.revenue_effect, c)}</span>
                    <span>Gerç. Maliyet: {formatMoney(co.profitability.realized_cost, c)}</span>
                    <span>Gerç. Kâr: {formatSignedMoney(co.profitability.realized_profit, c)}</span>
                    <span>Marj: %{co.profitability.realized_margin_percent}</span>
                  </div>
                </div>
              )}
            </>
          )}

          {!editing && (
            <div className="flex flex-wrap items-center gap-2">
              {isDraft && (
                <>
                  <Button
                    type="button"
                    variant="secondary"
                    disabled={busy || detail === null}
                    onClick={() => setEditing(true)}
                  >
                    {detail === null ? "Yükleniyor..." : "Düzenle"}
                  </Button>
                  <Button type="button" disabled={busy} onClick={send}>
                    Gönder
                  </Button>
                  <Button type="button" variant="danger" disabled={busy} onClick={cancel}>
                    İptal
                  </Button>
                </>
              )}
              {isSent && (
                <>
                  <Button
                    type="button"
                    variant="secondary"
                    disabled={busy}
                    onClick={() => {
                      navigator.clipboard.writeText(shareUrl());
                      setCopied(true);
                      setTimeout(() => setCopied(false), 2000);
                    }}
                  >
                    {copied ? "Kopyalandı" : "Linki Kopyala"}
                  </Button>
                  <Button type="button" variant="secondary" disabled={busy} onClick={() => setShowEmailForm(!showEmailForm)}>
                    Mail Gönder
                  </Button>
                  <Button type="button" variant="secondary" disabled={busy} onClick={revise}>
                    Revize Et
                  </Button>
                  <Button type="button" variant="danger" disabled={busy} onClick={cancel}>
                    İptal
                  </Button>
                </>
              )}
              {canRevise && !isSent && (
                <Button type="button" variant="secondary" disabled={busy} onClick={revise}>
                  Revize Et
                </Button>
              )}
            </div>
          )}

          {showEmailForm && isSent && (
            <form onSubmit={sendEmail} className="flex flex-col gap-2 border-t border-border pt-2" key={emailKey}>
              <input
                className={inputClass}
                placeholder="Kime"
                value={mail.to}
                onChange={(e) => setMail({ ...mail, to: e.target.value })}
              />
              <input
                className={inputClass}
                placeholder="Konu (opsiyonel)"
                value={mail.subject}
                onChange={(e) => setMail({ ...mail, subject: e.target.value })}
              />
              <textarea
                className={inputClass}
                placeholder="Mesaj (opsiyonel)"
                value={mail.message}
                onChange={(e) => setMail({ ...mail, message: e.target.value })}
              />
              <Button type="submit" disabled={busy}>
                Gönder
              </Button>
            </form>
          )}

          {error && <p className="text-xs text-danger">{error}</p>}
        </div>
      )}
    </div>
  );
}

export function ChangeOrdersSection({
  project,
  changeOrders,
  locked,
}: {
  project: Project;
  changeOrders: ChangeOrder[];
  locked: boolean;
}) {
  const { busy, error, run } = useChangeOrderAction(locked);
  const [open, setOpen] = useState(false);
  const [form, setForm] = useState({ change_type: "addition" as ChangeOrderType, title: "", vat_rate: "20" });
  const [items, setItems] = useState<ItemDraft[]>([emptyItem()]);

  async function submit(e: FormEvent) {
    e.preventDefault();
    const ok = await run(() =>
      apiClient(`/api/v1/projects/${project.id}/change-orders`, {
        method: "POST",
        body: JSON.stringify({
          change_type: form.change_type,
          title: form.title,
          description: "",
          vat_rate: Number(form.vat_rate) || 0,
          customer_notes: "",
          internal_notes: "",
          items: itemsToInput(items),
        }),
      })
    );
    if (ok) {
      setForm({ change_type: "addition", title: "", vat_rate: "20" });
      setItems([emptyItem()]);
      setOpen(false);
    }
  }

  return (
    <div className="flex flex-col gap-3">
      {changeOrders.length === 0 ? (
        <p className="text-text-muted">Henüz ek iş/değişiklik emri yok.</p>
      ) : (
        <div className="flex flex-col gap-2">
          {changeOrders.map((co) => (
            <ChangeOrderCard key={co.id} project={project} co={co} locked={locked} />
          ))}
        </div>
      )}

      {open ? (
        <form onSubmit={submit} className="flex flex-col gap-2 rounded-md border border-border p-3">
          <div className="grid grid-cols-2 gap-2">
            <select
              className={inputClass}
              value={form.change_type}
              onChange={(e) => setForm({ ...form, change_type: e.target.value as ChangeOrderType })}
            >
              <option value="addition">{CHANGE_ORDER_TYPE_LABELS.addition}</option>
              <option value="deduction">{CHANGE_ORDER_TYPE_LABELS.deduction}</option>
            </select>
            <input
              className={inputClass}
              placeholder="Başlık"
              value={form.title}
              onChange={(e) => setForm({ ...form, title: e.target.value })}
            />
          </div>
          <ItemsEditor items={items} setItems={setItems} />
          <input
            className={inputClass}
            type="number"
            step="0.01"
            placeholder="KDV %"
            value={form.vat_rate}
            onChange={(e) => setForm({ ...form, vat_rate: e.target.value })}
          />
          <div className="flex gap-2">
            <Button type="submit" disabled={busy || !form.title}>
              Oluştur
            </Button>
            <Button type="button" variant="ghost" onClick={() => setOpen(false)}>
              Vazgeç
            </Button>
          </div>
          {error && <p className="text-xs text-danger">{error}</p>}
        </form>
      ) : (
        <Button type="button" variant="secondary" onClick={() => setOpen(true)} disabled={locked}>
          + Ek İş Oluştur
        </Button>
      )}
    </div>
  );
}
