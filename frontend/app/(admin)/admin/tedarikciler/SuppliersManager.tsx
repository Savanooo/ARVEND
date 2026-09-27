"use client";

import { useRouter } from "next/navigation";
import { FormEvent, useMemo, useState } from "react";

import { Badge } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { useConfirmDialog } from "@/components/ui/ConfirmDialog";
import { EmptyState } from "@/components/ui/EmptyState";
import { Input } from "@/components/ui/Input";
import { Modal } from "@/components/ui/Modal";
import { SearchInput } from "@/components/ui/SearchInput";
import { Table, Td, Th, Tr } from "@/components/ui/Table";
import { Textarea } from "@/components/ui/Textarea";
import { apiClient, ApiError } from "@/lib/api";
import type { Supplier } from "@/lib/types";

// Tedarikçi, organizasyon-seviyeli (proje-bağımsız) PAYLAŞILAN bir
// kataloktur -- CostCodesManager İLE AYNI tek-yöneticili desen (liste +
// inline modal form). IBAN, YALNIZCA yazma yönünde gönderilir (boş
// bırakılırsa DEĞİŞTİRİLMEZ) -- API plaintext'i ASLA döndürmez, yalnızca
// iban_set boolean'ı (bkz. docs/procurement.md).
const emptyForm = () => ({
  code: "", legal_name: "", trade_name: "", tax_number: "", tax_office: "",
  contact_name: "", email: "", phone: "", address: "", city: "", country: "Türkiye",
  iban: "", notes: "",
});

export function SuppliersManager({
  initialSuppliers,
  canManage,
}: {
  initialSuppliers: Supplier[];
  // organization.suppliers.manage yoksa liste/arama/filtre açık kalır;
  // oluşturma, düzenleme, arşivleme/etkinleştirme ve modal hiç gösterilmez
  // (backend bu uçları 403 ile reddeder).
  canManage: boolean;
}) {
  const router = useRouter();
  const { confirm, dialog } = useConfirmDialog();
  const [search, setSearch] = useState("");
  const [showArchived, setShowArchived] = useState(false);
  const [modalOpen, setModalOpen] = useState(false);
  const [editing, setEditing] = useState<Supplier | null>(null);
  const [form, setForm] = useState(emptyForm);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const filtered = useMemo(() => {
    const q = search.trim().toLowerCase();
    return initialSuppliers
      .filter((s) => showArchived || s.is_active)
      .filter(
        (s) =>
          q === "" ||
          s.code.toLowerCase().includes(q) ||
          s.legal_name.toLowerCase().includes(q) ||
          s.trade_name.toLowerCase().includes(q)
      );
  }, [initialSuppliers, search, showArchived]);

  function openCreate() {
    setEditing(null);
    setForm(emptyForm());
    setError(null);
    setModalOpen(true);
  }

  function openEdit(s: Supplier) {
    setEditing(s);
    setForm({
      code: s.code, legal_name: s.legal_name, trade_name: s.trade_name,
      tax_number: s.tax_number, tax_office: s.tax_office, contact_name: s.contact_name,
      email: s.email, phone: s.phone, address: s.address, city: s.city, country: s.country,
      iban: "", notes: s.notes,
    });
    setError(null);
    setModalOpen(true);
  }

  async function submit(e: FormEvent) {
    e.preventDefault();
    if (!canManage) return;
    setBusy(true);
    setError(null);
    try {
      const body = {
        code: form.code, legal_name: form.legal_name, trade_name: form.trade_name,
        tax_number: form.tax_number, tax_office: form.tax_office, contact_name: form.contact_name,
        email: form.email, phone: form.phone, address: form.address, city: form.city, country: form.country,
        // Boş bırakılırsa iban alanını gövdeden TAMAMEN çıkar -- backend
        // nil (alan yok) ile "" (bilerek temizle) arasında ayrım yapar.
        ...(form.iban ? { iban: form.iban } : {}),
        notes: form.notes,
      };
      if (editing) {
        await apiClient(`/api/v1/organization/suppliers/${editing.id}`, { method: "PUT", body: JSON.stringify(body) });
      } else {
        await apiClient("/api/v1/organization/suppliers", { method: "POST", body: JSON.stringify(body) });
      }
      setModalOpen(false);
      router.refresh();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Bağlantı hatası");
    } finally {
      setBusy(false);
    }
  }

  async function toggleActive(s: Supplier) {
    const action = s.is_active ? "archive" : "reactivate";
    const ok = await confirm({
      title: s.is_active ? "Tedarikçiyi Arşivle" : "Tedarikçiyi Etkinleştir",
      message: s.is_active
        ? `"${s.legal_name}" (${s.code}) arşivlenecek — yeni PR/RFQ/PO'larda seçilemeyecek, ama mevcut kayıtlarda görünmeye devam edecek.`
        : `"${s.legal_name}" (${s.code}) yeniden etkinleştirilecek.`,
      confirmLabel: s.is_active ? "Arşivle" : "Etkinleştir",
      danger: s.is_active,
    });
    if (!ok) return;
    try {
      await apiClient(`/api/v1/organization/suppliers/${s.id}${action === "reactivate" ? "/reactivate" : ""}`, {
        method: action === "archive" ? "DELETE" : "POST",
      });
      router.refresh();
    } catch (err) {
      alert(err instanceof ApiError ? err.message : "Bağlantı hatası");
    }
  }

  return (
    <div className="flex flex-col gap-4">
      <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <div className="flex flex-1 flex-col gap-3 sm:flex-row sm:items-center">
          <SearchInput
            placeholder="Kod, unvan veya ticari ad ara…"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            className="sm:max-w-xs"
          />
          <label className="flex items-center gap-2 text-xs text-text-muted">
            <input
              type="checkbox"
              checked={showArchived}
              onChange={(e) => setShowArchived(e.target.checked)}
              className="accent-gold"
            />
            Arşivlenmiş tedarikçileri de göster
          </label>
        </div>
        {canManage && <Button onClick={openCreate}>+ Yeni Tedarikçi</Button>}
      </div>

      {!canManage && (
        <p className="text-xs text-text-muted">
          Tedarikçileri yalnızca görüntüleyebilirsin; eklemek veya düzenlemek için rolünde &quot;Tedarikçi
          oluşturma/düzenleme/arşivleme&quot; izni olmalı.
        </p>
      )}

      {filtered.length === 0 ? (
        <EmptyState
          title="Tedarikçi bulunamadı"
          description={
            initialSuppliers.length === 0
              ? "Henüz hiç tedarikçi oluşturulmamış. Satın alma talepleri/RFQ/siparişler bu kataloktan seçilir."
              : "Arama kriterlerinize uyan tedarikçi yok."
          }
          action={canManage && initialSuppliers.length === 0 && <Button onClick={openCreate}>+ Yeni Tedarikçi</Button>}
        />
      ) : (
        <Table>
          <thead>
            <tr>
              <Th>Kod</Th>
              <Th>Unvan</Th>
              <Th>İletişim</Th>
              <Th>Şehir</Th>
              <Th>Durum</Th>
              <Th className="w-32" />
            </tr>
          </thead>
          <tbody>
            {filtered.map((s) => (
              <Tr key={s.id} className={!s.is_active ? "opacity-60" : ""}>
                <Td className="font-medium">{s.code}</Td>
                <Td>
                  {s.legal_name}
                  {s.trade_name && <div className="text-xs text-text-muted">{s.trade_name}</div>}
                </Td>
                <Td className="text-text-muted">{s.contact_name || s.phone || s.email || "—"}</Td>
                <Td className="text-text-muted">{s.city || "—"}</Td>
                <Td>
                  <Badge tone={s.is_active ? "success" : "muted"}>{s.is_active ? "Aktif" : "Arşivlendi"}</Badge>
                </Td>
                <Td className="text-right">
                  <div className="flex justify-end gap-3">
                    <button type="button" onClick={() => openEdit(s)} className="text-xs text-gold hover:underline">
                      {canManage ? "Düzenle" : "Görüntüle"}
                    </button>
                    {canManage && (
                      <button
                        type="button"
                        onClick={() => toggleActive(s)}
                        className={`text-xs hover:underline ${s.is_active ? "text-danger" : "text-success"}`}
                      >
                        {s.is_active ? "Arşivle" : "Etkinleştir"}
                      </button>
                    )}
                  </div>
                </Td>
              </Tr>
            ))}
          </tbody>
        </Table>
      )}

      {/* Görüntüleme izniyle de açılır (tüm alanlar kilitli): vergi no,
          adres, notlar gibi ayrıntıların web'de görüldüğü tek yer burası. */}
      <Modal
        open={modalOpen}
        onClose={() => setModalOpen(false)}
        title={!canManage ? "Tedarikçi" : editing ? "Tedarikçiyi Düzenle" : "Yeni Tedarikçi"}
      >
        <form onSubmit={submit} className="flex flex-col gap-3">
          <fieldset disabled={!canManage} className="contents">
            <div className="grid grid-cols-2 gap-3">
              <Input
                label="Kod" value={form.code} required disabled={!!editing}
                onChange={(e) => setForm({ ...form, code: e.target.value })} placeholder="ör. TED-001"
              />
              <Input
                label="Unvan" value={form.legal_name} required
                onChange={(e) => setForm({ ...form, legal_name: e.target.value })} placeholder="Resmi ticari unvan"
              />
            </div>
            {editing && canManage && (
              <p className="-mt-2 text-xs text-text-muted">
                Kod oluşturulduktan sonra değiştirilemez (geçmiş kayıtlarla bağlantısını korumak için).
              </p>
            )}
            <Input
              label="Ticari Ad" value={form.trade_name}
              onChange={(e) => setForm({ ...form, trade_name: e.target.value })} placeholder="ör. bilinen kısa ad"
            />
            <div className="grid grid-cols-2 gap-3">
              <Input
                label="Vergi No" value={form.tax_number}
                onChange={(e) => setForm({ ...form, tax_number: e.target.value })}
              />
              <Input
                label="Vergi Dairesi" value={form.tax_office}
                onChange={(e) => setForm({ ...form, tax_office: e.target.value })}
              />
            </div>
            <div className="grid grid-cols-2 gap-3">
              <Input
                label="Yetkili Kişi" value={form.contact_name}
                onChange={(e) => setForm({ ...form, contact_name: e.target.value })}
              />
              <Input
                label="Telefon" value={form.phone}
                onChange={(e) => setForm({ ...form, phone: e.target.value })}
              />
            </div>
            <Input
              label="E-posta" type="email" value={form.email}
              onChange={(e) => setForm({ ...form, email: e.target.value })}
            />
            <div className="grid grid-cols-2 gap-3">
              <Input
                label="Şehir" value={form.city}
                onChange={(e) => setForm({ ...form, city: e.target.value })}
              />
              <Input
                label="Ülke" value={form.country}
                onChange={(e) => setForm({ ...form, country: e.target.value })}
              />
            </div>
            <Textarea
              label="Adres" className="min-h-16" value={form.address}
              onChange={(e) => setForm({ ...form, address: e.target.value })}
            />
            {canManage ? (
              <Input
                label={editing ? "IBAN (değiştirmek için doldurun)" : "IBAN"} value={form.iban}
                onChange={(e) => setForm({ ...form, iban: e.target.value })}
                placeholder={editing ? "•••• (kayıtlı, değiştirmemek için boş bırakın)" : "TR.."}
              />
            ) : (
              <p className="text-sm text-text-muted">IBAN: {editing?.iban_set ? "kayıtlı" : "kayıtlı değil"}</p>
            )}
            <Textarea
              label="Notlar" className="min-h-16" value={form.notes}
              onChange={(e) => setForm({ ...form, notes: e.target.value })}
            />
          </fieldset>
          {error && <p className="text-xs text-danger">{error}</p>}
          <div className="flex gap-2 border-t border-border pt-3">
            {canManage && (
              <Button type="submit" loading={busy}>
                Kaydet
              </Button>
            )}
            <Button type="button" variant="ghost" onClick={() => setModalOpen(false)}>
              {canManage ? "Vazgeç" : "Kapat"}
            </Button>
          </div>
        </form>
      </Modal>
      {dialog}
    </div>
  );
}
