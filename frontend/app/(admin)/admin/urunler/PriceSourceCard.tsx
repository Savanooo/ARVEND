"use client";

import { RefreshCw, Settings2 } from "lucide-react";
import { useRouter } from "next/navigation";
import { FormEvent, useState } from "react";

import { Badge } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { Card, CardBody, CardHeader } from "@/components/ui/Card";
import { Input } from "@/components/ui/Input";
import { Modal } from "@/components/ui/Modal";
import { Table, Td, Th, Tr } from "@/components/ui/Table";
import { apiClient, ApiError } from "@/lib/api";
import { formatTL } from "@/lib/format";
import {
  applyMarkup,
  asSentence,
  buildSettingsBody,
  categoryMarkupRows,
  EXAMPLE_SOURCE_PRICE,
  formatMarkupInput,
  formatPercent,
  formatSyncTime,
  parseMarkupInput,
  PRICE_SOURCES_PATH,
  priceSyncErrorMessage,
  settingsSavedMessage,
  summarizeSyncCounts,
  syncErrorUpdatesStatus,
  type CategoryMarkupRow,
} from "@/lib/price-sources";
import type { PriceSource, PriceSourceUpdateResponse, PriceSyncResponse } from "@/lib/types";

type Notice = { tone: "success" | "danger"; text: string };

type SettingsForm = { markup: string; autoSync: boolean; rows: CategoryMarkupRow[] };

function formFrom(ps: PriceSource): SettingsForm {
  return {
    markup: ps.markup_percent === null ? "" : formatMarkupInput(ps.markup_percent),
    autoSync: ps.auto_sync,
    rows: categoryMarkupRows(ps),
  };
}

/**
 * Ürünler listesinin üstündeki "Fiyat Kaynağı: Ulaş" kartı. Durum bilgisi
 * products.read olan herkese görünür; "Ulaş'tan Güncelle" ve kâr oranı
 * ayarları yalnızca products.manage ile (backend PUT/POST uçlarını da bu
 * izinle korur, oranları da yalnızca bu izne döndürür).
 */
export function PriceSourceCard({
  priceSource,
  canManage,
}: {
  // null: GET /products/price-sources başarısız oldu (ürün listesi yine açılır).
  priceSource: PriceSource | null;
  canManage: boolean;
}) {
  const router = useRouter();
  const [syncing, setSyncing] = useState(false);
  const [notice, setNotice] = useState<Notice | null>(null);
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [form, setForm] = useState<SettingsForm | null>(null);
  const [saving, setSaving] = useState(false);
  const [formError, setFormError] = useState<string | null>(null);
  const [markupError, setMarkupError] = useState<string | null>(null);
  const [rowErrors, setRowErrors] = useState<Record<string, string>>({});

  if (!priceSource) {
    return (
      <Card>
        <CardHeader>Fiyat Kaynağı</CardHeader>
        <CardBody className="text-sm text-text-muted">Fiyat kaynağı bilgisi şu anda alınamadı.</CardBody>
      </Card>
    );
  }

  const ps = priceSource;
  const name = ps.name;
  // Backend oranı products.manage olmayana zaten null döndürür.
  const markupPercent = canManage ? ps.markup_percent : null;

  async function sync() {
    setSyncing(true);
    setNotice(null);
    try {
      const res = await apiClient<PriceSyncResponse>(`${PRICE_SOURCES_PATH}/${ps.source}/sync`, { method: "POST" });
      setNotice({ tone: "success", text: `${name} listesi güncellendi: ${summarizeSyncCounts(res)}.` });
      router.refresh();
    } catch (err) {
      const status = err instanceof ApiError ? err.status : null;
      setNotice({ tone: "danger", text: priceSyncErrorMessage(status, err instanceof ApiError ? err.message : "", name) });
      // Backend başarısız indirmeyi (502) ve listeyi kataloğa uygulama
      // hatasını (500/400) last_status/last_error'a yazar -- kartın durum
      // alanı da güncellensin (409 ve ağ hatası hariç).
      if (syncErrorUpdatesStatus(status)) router.refresh();
    } finally {
      setSyncing(false);
    }
  }

  function openSettings() {
    setForm(formFrom(ps));
    setFormError(null);
    setMarkupError(null);
    setRowErrors({});
    setSettingsOpen(true);
  }

  function setRowMarkup(index: number, markup: string) {
    setForm((f) => (f ? { ...f, rows: f.rows.map((r, i) => (i === index ? { ...r, markup } : r)) } : f));
  }

  async function saveSettings(e: FormEvent) {
    e.preventDefault();
    if (!form) return;
    const built = buildSettingsBody(form);
    if (!built.ok) {
      setMarkupError(built.markupError);
      setRowErrors(built.rowErrors);
      setFormError("Lütfen işaretli alanları düzeltin.");
      return;
    }
    setMarkupError(null);
    setRowErrors({});
    setFormError(null);
    setSaving(true);
    try {
      const res = await apiClient<PriceSourceUpdateResponse>(`${PRICE_SOURCES_PATH}/${ps.source}`, {
        method: "PUT",
        body: JSON.stringify(built.body),
      });
      setSettingsOpen(false);
      setNotice({
        tone: "success",
        text: settingsSavedMessage(res.recomputed, res.price_source.last_synced_at, name),
      });
      router.refresh();
    } catch (err) {
      setFormError(err instanceof ApiError ? err.message : "Bağlantı hatası");
      // Kayıt sürerken pencere kapatılamaz (dismissible), ama tarayıcı ESC'yi
      // zorla uygulamış olabilir: hata gizli bir pencerede kaybolmasın, form
      // yazılanlarla birlikte yeniden açılsın (açıksa değişiklik yok).
      setSettingsOpen(true);
    } finally {
      setSaving(false);
    }
  }

  const statusBadge =
    ps.last_status === "success" ? (
      <Badge tone="success">Başarılı</Badge>
    ) : ps.last_status === "failed" ? (
      <Badge tone="danger">Başarısız</Badge>
    ) : (
      <Badge tone="muted">Hiç çekilmedi</Badge>
    );

  const counts: [string, number][] = [
    ["Toplam", ps.last_result.total],
    ["Yeni", ps.last_result.created],
    ["Güncellenen", ps.last_result.updated],
    ["Değişmeyen", ps.last_result.unchanged],
    ["Listede artık olmayan", ps.last_result.missing],
  ];

  const overrideCount = ps.category_markups?.length ?? 0;
  const parsedDefault = form ? parseMarkupInput(form.markup) : null;

  return (
    <Card>
      <CardHeader className="flex items-center justify-between gap-3">
        <span>Fiyat Kaynağı: {name}</span>
        {statusBadge}
      </CardHeader>
      <CardBody className="flex flex-col gap-4">
        <dl className="grid gap-x-8 gap-y-2 text-sm sm:grid-cols-2">
          <div className="flex flex-wrap gap-x-2">
            <dt className="text-text-muted">Son başarılı güncelleme:</dt>
            <dd className="font-medium">{ps.last_synced_at ? formatSyncTime(ps.last_synced_at) : "Hiç çekilmedi"}</dd>
          </div>
          <div className="flex flex-wrap gap-x-2">
            <dt className="text-text-muted">Otomatik güncelleme:</dt>
            <dd className="font-medium">{ps.auto_sync ? "Açık · her gece 00:05" : "Kapalı"}</dd>
          </div>
          <div className="flex flex-wrap gap-x-2">
            <dt className="text-text-muted">Katalogdaki {name} ürünü:</dt>
            <dd className="font-medium">
              {ps.product_count}
              {ps.missing_count > 0 && (
                <span className="font-normal text-text-muted"> ({ps.missing_count} tanesi son listede yok)</span>
              )}
            </dd>
          </div>
          {markupPercent !== null && (
            <div className="flex flex-wrap gap-x-2">
              <dt className="text-text-muted">Kâr oranı:</dt>
              <dd className="font-medium">
                {formatPercent(markupPercent)}
                {overrideCount > 0 && (
                  <span className="font-normal text-text-muted"> · {overrideCount} kategoride özel oran</span>
                )}
              </dd>
            </div>
          )}
        </dl>

        {ps.last_status === "failed" && (
          <p className="rounded-md bg-danger-soft px-3 py-2 text-sm text-danger">
            {/* Backend hata metinleri noktasızdır: asSentence, sonraki cümleyle birleşmesini önler. */}
            Son deneme başarısız{ps.last_error ? `: ${asSentence(ps.last_error)}` : "."} Ürünlerde değişiklik yapılmadı
            {ps.last_synced_at ? "; aşağıdaki sayılar son başarılı güncellemeye aittir." : "."}
          </p>
        )}

        {ps.last_synced_at && (
          <div>
            <p className="mb-2 text-xs font-semibold uppercase tracking-widest text-text-muted">
              Son güncellemenin sonucu
            </p>
            <div className="grid grid-cols-2 gap-2 sm:grid-cols-5">
              {counts.map(([label, value]) => (
                <div key={label} className="rounded-md border border-border px-3 py-2">
                  <div className="text-xs text-text-muted">{label}</div>
                  <div className="text-lg font-semibold">{value}</div>
                </div>
              ))}
            </div>
          </div>
        )}

        <ul className="list-disc space-y-1 pl-5 text-xs text-text-muted">
          {canManage && (
            <li>
              Satış fiyatı = {name} fiyatı × (1 + kâr oranı). Kâr oranı değişince {name} fiyatı bilinen (en az bir
              kez {name}&apos;tan güncellenmiş) ürünlerin fiyatı hemen yeniden hesaplanır.
              {!ps.last_synced_at && (
                <>
                  {" "}
                  Henüz başarılı bir {name} güncellemesi olmadığı için kaydedilen oranlar ilk güncellemede
                  uygulanır.
                </>
              )}
            </li>
          )}
          <li>Elle eklenen ürünlere dokunulmaz.</li>
          <li>
            {name} listesinden düşen ürünler silinmez; &quot;{name} listesinde yok&quot; olarak işaretlenir.
          </li>
        </ul>

        {notice && (
          <p
            role="status"
            className={`rounded-md px-3 py-2 text-sm ${
              notice.tone === "success" ? "bg-success-soft text-success" : "bg-danger-soft text-danger"
            }`}
          >
            {notice.text}
          </p>
        )}

        {canManage && (
          <div className="flex flex-wrap gap-3">
            <Button onClick={sync} loading={syncing} disabled={saving}>
              {!syncing && <RefreshCw size={14} strokeWidth={2} />}
              {syncing ? "Güncelleniyor…" : `${name}'tan Güncelle`}
            </Button>
            {/* Kayıt sürerken yeniden açılmasın: form eski değerlerle kurulur, geç gelen başarı da onu kapatırdı. */}
            <Button variant="secondary" onClick={openSettings} disabled={syncing || saving}>
              <Settings2 size={14} strokeWidth={2} />
              Kâr oranı ayarları
            </Button>
          </div>
        )}
      </CardBody>

      {canManage && form && (
        <Modal
          open={settingsOpen}
          // Koşulsuz: dismissible=false kullanıcının kapatmasını zaten engeller;
          // tarayıcı yine de kapatırsa durum dialog'la uyumlu kalmalı.
          onClose={() => setSettingsOpen(false)}
          dismissible={!saving}
          title={`${name} kâr oranı ayarları`}
          widthClassName="max-w-2xl"
        >
          <form onSubmit={saveSettings} className="flex flex-col gap-4">
            <div className="grid gap-4 sm:grid-cols-2">
              <Input
                label="Varsayılan kâr oranı (%)"
                name="markup_percent"
                inputMode="decimal"
                autoComplete="off"
                required
                value={form.markup}
                error={markupError ?? undefined}
                onChange={(e) => setForm({ ...form, markup: e.target.value })}
                placeholder="ör. 15 veya 12,5"
              />
              <div className="flex flex-col justify-end gap-1 text-sm">
                <span className="text-xs font-semibold uppercase tracking-widest text-text-muted">Örnek</span>
                <span>
                  {parsedDefault?.ok
                    ? `${formatTL(EXAMPLE_SOURCE_PRICE)} ${name} fiyatı → ${formatTL(
                        applyMarkup(EXAMPLE_SOURCE_PRICE, parsedDefault.value)
                      )} satış`
                    : "—"}
                </span>
              </div>
            </div>
            <p className="-mt-2 text-xs text-text-muted">
              0 ile 1000 arasında, en fazla iki ondalık. Satış fiyatı = {name} fiyatı × (1 + oran).
            </p>
            {!ps.last_synced_at && (
              <p className="rounded-md bg-info-soft px-3 py-2 text-xs text-info">
                Henüz başarılı bir {name} güncellemesi yok, bu yüzden hiçbir ürünün {name} fiyatı bilinmiyor.
                Kaydettiğiniz oranlar şimdi hiçbir fiyatı değiştirmez; ilk &quot;{name}&apos;tan Güncelle&quot; ile
                uygulanır.
              </p>
            )}

            <label className="flex items-center gap-2 text-sm">
              <input
                type="checkbox"
                checked={form.autoSync}
                onChange={(e) => setForm({ ...form, autoSync: e.target.checked })}
                className="accent-gold"
              />
              Her gece 00:05&apos;te otomatik güncelle
            </label>

            <div className="flex flex-col gap-2">
              <p className="text-xs font-semibold uppercase tracking-widest text-text-muted">
                Kategoriye özel kâr oranları
              </p>
              <p className="text-xs text-text-muted">
                Boş bırakılan kategorilerde varsayılan oran kullanılır.
              </p>
              {form.rows.length === 0 ? (
                <p className="text-sm text-text-muted">
                  Henüz {name} kategorisi yok; kategoriler ilk güncellemeden sonra burada listelenir.
                </p>
              ) : (
                <Table>
                  <thead>
                    <tr>
                      <Th>Kategori</Th>
                      <Th className="text-right">Ürün</Th>
                      <Th className="w-40">Oran (%)</Th>
                    </tr>
                  </thead>
                  <tbody>
                    {form.rows.map((row, i) => (
                      <Tr key={row.category}>
                        <Td className="py-2">
                          {row.category}
                          {row.productCount === 0 && (
                            <div className="text-xs text-text-muted">Bu kategoride artık ürün yok</div>
                          )}
                        </Td>
                        <Td className="py-2 text-right text-text-muted">{row.productCount}</Td>
                        <Td className="py-2">
                          <Input
                            aria-label={`${row.category} kâr oranı`}
                            inputMode="decimal"
                            autoComplete="off"
                            value={row.markup}
                            error={rowErrors[row.category]}
                            onChange={(e) => setRowMarkup(i, e.target.value)}
                            placeholder={
                              parsedDefault?.ok ? `Varsayılan (${formatPercent(parsedDefault.value)})` : "Varsayılan"
                            }
                            className="w-full"
                          />
                        </Td>
                      </Tr>
                    ))}
                  </tbody>
                </Table>
              )}
            </div>

            {formError && <p className="text-sm text-danger">{formError}</p>}

            <div className="flex justify-end gap-2">
              <Button type="button" variant="secondary" onClick={() => setSettingsOpen(false)} disabled={saving}>
                Vazgeç
              </Button>
              <Button type="submit" loading={saving}>
                Kaydet
              </Button>
            </div>
          </form>
        </Modal>
      )}
    </Card>
  );
}
