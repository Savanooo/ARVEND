"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useState } from "react";

import { ExpenseEditModal, ExpenseStatusBadge, ExpenseVatCell } from "@/components/expenses/ExpenseParts";
import { useExpenseMutations } from "@/components/expenses/useExpenseMutations";
import { Button } from "@/components/ui/Button";
import { Modal } from "@/components/ui/Modal";
import { Table, Td, Th, Tr } from "@/components/ui/Table";
import { Tabs } from "@/components/ui/Tabs";
import { projectHref } from "@/lib/dashboard";
import {
  EXPENSE_OWN_DECISION_TEXT,
  expenseActionsFor,
  expenseIsWithdrawn,
  expenseProjectLabel,
  expenseVatPercent,
  MY_EXPENSE_FILTERS,
  MY_EXPENSES_PATH,
  myExpenseMatches,
  myExpensesHref,
  projectLedgerOpen,
  type ExpenseActor,
  type MyExpenseFilter,
} from "@/lib/expenses";
import { formatDateTR, formatHm, formatMoney, istanbulDate } from "@/lib/format";
import { EXPENSE_CATEGORY_LABELS, type MyExpense } from "@/lib/types";

function categoryLabel(category: string): string {
  return EXPENSE_CATEGORY_LABELS[category as keyof typeof EXPENSE_CATEGORY_LABELS] ?? category;
}

function formatTimestamp(ts: string): string {
  const t = new Date(ts);
  if (Number.isNaN(t.getTime())) return ts;
  return `${formatDateTR(istanbulDate(t))} ${formatHm(ts)}`;
}

// Masraflarım listesi: süzgeçler (Tümü / Onay bekliyor / Reddedildi /
// Onaylandı), satırda durum rozeti (Geri çekildi dahil) ve kırmızı ret
// nedeni, TOPLAM YOK. Satıra tıklayınca ayrıntı; işlemler mobil
// expenseActionsFor ile aynı kuraldan (kendi bekleyen/reddedilen masrafında
// Düzenle / Geri Çek; kapalı projede hiçbiri).
export function MyExpensesView({
  rows,
  limit,
  actor,
  projectId,
  initialExpenseId,
  canOpenProjects,
}: {
  rows: MyExpense[];
  limit: number;
  actor: ExpenseActor;
  projectId: string | null;
  initialExpenseId: string | null;
  // projects.read: proje adı proje sayfasına bağlanır (yoksa düz metin).
  canOpenProjects: boolean;
}) {
  const router = useRouter();
  const [filter, setFilter] = useState<MyExpenseFilter>("all");
  // ?masraf= ayrıntıyı bir kez açar: ilk açılışta ve Masraflarım zaten
  // açıkken bildirimden yeniden gelindiğinde (sayfa yeniden kurulmaz, yalnızca
  // prop değişir -- liste sunucudan taze gelir). Adresten düşünce (null)
  // açık ayrıntıya dokunulmaz.
  const openable = (id: string | null) => (id && rows.some((r) => r.id === id) ? id : null);
  const [detailId, setDetailId] = useState<string | null>(() => openable(initialExpenseId));
  const [seenInitialId, setSeenInitialId] = useState(initialExpenseId);
  if (initialExpenseId !== seenInitialId) {
    setSeenInitialId(initialExpenseId);
    const target = openable(initialExpenseId);
    if (target) setDetailId(target);
  }
  const [editing, setEditing] = useState<MyExpense | null>(null);
  const mutations = useExpenseMutations();

  const visible = rows.filter((r) => myExpenseMatches(filter, r));
  const detail = detailId ? (rows.find((r) => r.id === detailId) ?? null) : null;
  const filteredProjectLabel = projectId && rows.length > 0 ? expenseProjectLabel(rows[0].project_no, rows[0].project_name) : null;

  function closeDetail() {
    setDetailId(null);
    mutations.clearError();
    // Bildirimden gelinen ?masraf= adresten düşer: sayfa yenilenince ayrıntı
    // yeniden açılmasın (proje süzgeci korunur).
    if (initialExpenseId) router.replace(myExpensesHref({ projectId }), { scroll: false });
  }

  async function act(fn: () => Promise<boolean>) {
    if (await fn()) closeDetail();
  }

  return (
    <div className="flex flex-col gap-4">
      {mutations.dialogs}
      {projectId && (
        <div className="flex flex-wrap items-center justify-between gap-2 rounded-md border border-border bg-surface px-4 py-3 text-sm">
          <span className="text-text-muted">
            {filteredProjectLabel ? (
              <>
                Bu projedeki masrafların: <span className="font-medium text-text">{filteredProjectLabel}</span>
              </>
            ) : (
              "Bu projedeki masrafların"
            )}
          </span>
          <Link href={MY_EXPENSES_PATH} className="text-text-muted hover:text-gold hover:underline">
            Tüm projeler
          </Link>
        </div>
      )}

      {/* Dar ekranda süzgeçler kendi içinde kayar (sayfa yatay kaymasın). */}
      <div className="overflow-x-auto whitespace-nowrap">
        <Tabs
          items={MY_EXPENSE_FILTERS.map((f) => ({
            key: f.key,
            label: `${f.label} (${rows.filter((r) => myExpenseMatches(f.key, r)).length})`,
            active: filter === f.key,
            onClick: () => setFilter(f.key),
          }))}
        />
      </div>

      {visible.length === 0 ? (
        <div className="rounded-lg border border-border bg-surface p-6 text-sm text-text-muted">
          {rows.length === 0
            ? "Henüz masraf girmedin. \"Masraf Gir\" ile masrafını gir; onaylanınca projenin maliyetine işlenir."
            : "Bu durumda masrafın yok."}
        </div>
      ) : (
        <div className="rounded-lg border border-border bg-surface">
          <Table>
            <thead>
              <tr>
                <Th>Tarih</Th>
                <Th>Proje</Th>
                <Th>Masraf</Th>
                <Th>Durum</Th>
                <Th>KDV</Th>
                <Th className="text-right">Tutar</Th>
                <Th className="w-20" />
              </tr>
            </thead>
            <tbody>
              {visible.map((e) => (
                <Tr key={e.id} className={e.voided_at ? "opacity-60" : ""}>
                  <Td className="whitespace-nowrap text-text-muted">{formatDateTR(e.expense_date)}</Td>
                  <Td>
                    {canOpenProjects ? (
                      <Link href={projectHref(e.project_id)} className="hover:text-gold hover:underline">
                        {expenseProjectLabel(e.project_no, e.project_name)}
                      </Link>
                    ) : (
                      expenseProjectLabel(e.project_no, e.project_name)
                    )}
                  </Td>
                  <Td>
                    {/* Dar ekranda sağdaki "Ayrıntı" kaydırmadan görünmeyebilir: kategori de açar. */}
                    <button
                      type="button"
                      onClick={() => setDetailId(e.id)}
                      className="text-left font-medium hover:text-gold hover:underline"
                    >
                      {categoryLabel(e.category)}
                    </button>
                    {e.description && <div className="text-xs text-text-muted">{e.description}</div>}
                    {e.approval_status === "rejected" && !e.voided_at && e.decision_note && (
                      <div className="text-xs text-danger">Red nedeni: {e.decision_note}</div>
                    )}
                  </Td>
                  <Td className="whitespace-nowrap">
                    <ExpenseStatusBadge expense={e} />
                  </Td>
                  <Td className="whitespace-nowrap">
                    <ExpenseVatCell expense={e} />
                  </Td>
                  <Td className={`whitespace-nowrap text-right font-medium ${e.voided_at ? "line-through" : ""}`}>
                    {formatMoney(e.amount, e.currency)}
                  </Td>
                  <Td className="text-right">
                    <button
                      type="button"
                      onClick={() => setDetailId(e.id)}
                      className="text-xs text-text-muted hover:text-text hover:underline"
                    >
                      Ayrıntı
                    </button>
                  </Td>
                </Tr>
              ))}
            </tbody>
          </Table>
        </div>
      )}

      {rows.length >= limit && (
        <p className="text-xs text-text-muted">Son {limit} masrafın gösteriliyor.</p>
      )}
      <p className="text-xs text-text-muted">
        Girdiğin masraf yönetici onaylayınca projenin maliyetine işlenir. Reddedilen masrafı nedenine bakıp
        düzeltebilir ya da geri çekebilirsin.
      </p>

      {detail && (
        <ExpenseDetailModal
          row={detail}
          actor={actor}
          busy={mutations.busy}
          error={mutations.error}
          onClose={closeDetail}
          onEdit={() => {
            setEditing(detail);
            closeDetail();
          }}
          onApprove={() => act(() => mutations.approve(detail.project_id, detail))}
          onReject={() => act(() => mutations.reject(detail.project_id, detail))}
          onWithdraw={() => act(() => mutations.withdraw(detail.project_id, detail))}
          onVoid={() => act(() => mutations.voidExpense(detail.project_id, detail))}
        />
      )}
      {editing && (
        <ExpenseEditModal
          projectId={editing.project_id}
          expense={editing}
          // Seçici listeleri burada yüklenmez: finans yöneticisinde okunan
          // bağlar aynen geri gider, diğerinde boş ("kayıttakini koru").
          canLink={actor.canManageFinance}
          onClose={() => setEditing(null)}
        />
      )}
    </div>
  );
}

function DetailRow({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="flex justify-between gap-4 border-b border-border py-2 last:border-b-0">
      <span className="shrink-0 text-text-muted">{label}</span>
      <span className="text-right">{children}</span>
    </div>
  );
}

// Masraf ayrıntısı (mobil showExpenseDetailSheet): durum, proje, karar
// tarihi, ret nedeni, alanlar, KDV kırılımı; işlemler expenseActionsFor'dan.
function ExpenseDetailModal({
  row,
  actor,
  busy,
  error,
  onClose,
  onEdit,
  onApprove,
  onReject,
  onWithdraw,
  onVoid,
}: {
  row: MyExpense;
  actor: ExpenseActor;
  busy: boolean;
  error: string | null;
  onClose: () => void;
  onEdit: () => void;
  onApprove: () => void;
  onReject: () => void;
  onWithdraw: () => void;
  onVoid: () => void;
}) {
  const e = row;
  const a = expenseActionsFor(actor, e, projectLedgerOpen(e.project_status));
  const money = (v: number) => formatMoney(v, e.currency);
  return (
    <Modal open onClose={onClose} title="Masraf" widthClassName="max-w-lg">
      <div className="flex flex-col gap-3">
        <div className="flex items-baseline justify-between gap-3">
          <span className="font-semibold">{categoryLabel(e.category)}</span>
          <span className={`text-base font-semibold ${e.voided_at ? "line-through" : ""}`}>{money(e.amount)}</span>
        </div>
        {e.voided_at && (
          <p className="text-xs font-semibold text-danger">
            {expenseIsWithdrawn(e) ? "GERİ ÇEKİLDİ" : "İPTAL"}
            {e.void_reason && ` · ${e.void_reason}`}
          </p>
        )}
        <div className="flex flex-col">
          <DetailRow label="Durum">
            <ExpenseStatusBadge expense={e} />
          </DetailRow>
          <DetailRow label="Proje">{expenseProjectLabel(e.project_no, e.project_name)}</DetailRow>
          {e.decided_at && (
            <DetailRow label={e.approval_status === "rejected" ? "Reddedilme" : "Onaylanma"}>
              {formatTimestamp(e.decided_at)}
            </DetailRow>
          )}
          {e.approval_status === "rejected" && e.decision_note && (
            <DetailRow label="Red nedeni">
              <span className="text-danger">{e.decision_note}</span>
            </DetailRow>
          )}
          <DetailRow label="Tarih">{formatDateTR(e.expense_date)}</DetailRow>
          <DetailRow label="Açıklama">{e.description || "—"}</DetailRow>
          <DetailRow label="Kime ödendi">{e.supplier_name || "—"}</DetailRow>
          <DetailRow label="Fatura No">{e.invoice_no || "—"}</DetailRow>
          {e.vat_rate != null ? (
            <>
              <DetailRow label={`KDV (${expenseVatPercent(e.vat_rate)})`}>
                {e.vat_amount == null ? "—" : money(e.vat_amount)}
              </DetailRow>
              {e.net_amount != null && <DetailRow label="KDV hariç">{money(e.net_amount)}</DetailRow>}
            </>
          ) : (
            <DetailRow label="KDV">Belirtilmedi</DetailRow>
          )}
          {e.notes && <DetailRow label="Not">{e.notes}</DetailRow>}
        </div>
        {a.ownDecisionBlocked && (
          <p className="rounded-md border border-border bg-surface-hover px-3 py-2 text-xs text-text-muted">
            {EXPENSE_OWN_DECISION_TEXT}
          </p>
        )}
        {error && <p className="text-xs text-danger">{error}</p>}
        {(a.canDecide || a.canEdit || a.canWithdraw || a.canVoid) && (
          <div className="flex flex-wrap gap-2 border-t border-border pt-3">
            {a.canDecide && (
              <>
                <Button type="button" onClick={onApprove} disabled={busy}>
                  Onayla
                </Button>
                <Button type="button" variant="secondary" onClick={onReject} disabled={busy}>
                  Reddet
                </Button>
              </>
            )}
            {a.canEdit && (
              <Button type="button" variant="secondary" onClick={onEdit} disabled={busy}>
                Düzenle
              </Button>
            )}
            {a.canWithdraw && (
              <Button type="button" variant="danger" onClick={onWithdraw} disabled={busy}>
                Geri Çek
              </Button>
            )}
            {a.canVoid && (
              <Button type="button" variant="danger" onClick={onVoid} disabled={busy}>
                İptal Et
              </Button>
            )}
          </div>
        )}
      </div>
    </Modal>
  );
}
