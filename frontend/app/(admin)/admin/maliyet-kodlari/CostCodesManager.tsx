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
import type { OrganizationCostCode } from "@/lib/types";

// Maliyet kodu, organizasyon-seviyeli (proje-bağımsız) PAYLAŞILAN bir
// kataloktur -- WBS (proje-özel ağaç) İLE KARIŞTIRILMAMALI (bkz. docs/
// cost-control.md "WBS ≠ Cost Code"). Roller & Yetkiler İLE AYNI tek-
// yöneticili basit desen: liste + inline modal form, ayrı bir "yeni/
// düzenle" route'u yok (spec: "bulk import gerekli değil", sadelik).
const emptyForm = () => ({ code: "", name: "", description: "", category: "" });

export function CostCodesManager({ initialCostCodes }: { initialCostCodes: OrganizationCostCode[] }) {
  const router = useRouter();
  const { confirm, dialog } = useConfirmDialog();
  const [search, setSearch] = useState("");
  const [showArchived, setShowArchived] = useState(false);
  const [modalOpen, setModalOpen] = useState(false);
  const [editing, setEditing] = useState<OrganizationCostCode | null>(null);
  const [form, setForm] = useState(emptyForm);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const filtered = useMemo(() => {
    const q = search.trim().toLowerCase();
    return initialCostCodes
      .filter((c) => showArchived || c.is_active)
      .filter(
        (c) =>
          q === "" ||
          c.code.toLowerCase().includes(q) ||
          c.name.toLowerCase().includes(q) ||
          c.category.toLowerCase().includes(q)
      );
  }, [initialCostCodes, search, showArchived]);

  function openCreate() {
    setEditing(null);
    setForm(emptyForm());
    setError(null);
    setModalOpen(true);
  }

  function openEdit(c: OrganizationCostCode) {
    setEditing(c);
    setForm({ code: c.code, name: c.name, description: c.description, category: c.category });
    setError(null);
    setModalOpen(true);
  }

  async function submit(e: FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError(null);
    try {
      if (editing) {
        await apiClient(`/api/v1/organization/cost-codes/${editing.id}`, {
          method: "PUT",
          body: JSON.stringify({ name: form.name, description: form.description, category: form.category }),
        });
      } else {
        await apiClient("/api/v1/organization/cost-codes", {
          method: "POST",
          body: JSON.stringify(form),
        });
      }
      setModalOpen(false);
      router.refresh();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Bağlantı hatası");
    } finally {
      setBusy(false);
    }
  }

  async function toggleActive(c: OrganizationCostCode) {
    const action = c.is_active ? "archive" : "reactivate";
    const ok = await confirm({
      title: c.is_active ? "Maliyet Kodunu Arşivle" : "Maliyet Kodunu Etkinleştir",
      message: c.is_active
        ? `"${c.name}" (${c.code}) arşivlenecek — yeni bütçe/taahhüt kayıtlarında seçilemeyecek, ama mevcut kayıtlarda görünmeye devam edecek.`
        : `"${c.name}" (${c.code}) yeniden etkinleştirilecek.`,
      confirmLabel: c.is_active ? "Arşivle" : "Etkinleştir",
      danger: c.is_active,
    });
    if (!ok) return;
    try {
      await apiClient(
        `/api/v1/organization/cost-codes/${c.id}${action === "reactivate" ? "/reactivate" : ""}`,
        { method: action === "archive" ? "DELETE" : "POST" }
      );
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
            placeholder="Kod, ad veya kategori ara…"
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
            Arşivlenmiş kodları da göster
          </label>
        </div>
        <Button onClick={openCreate}>+ Yeni Maliyet Kodu</Button>
      </div>

      {filtered.length === 0 ? (
        <EmptyState
          title="Maliyet kodu bulunamadı"
          description={
            initialCostCodes.length === 0
              ? "Henüz hiç maliyet kodu oluşturulmamış. Bütçe kalemleri ve taahhütler bu kodlarla sınıflandırılır."
              : "Arama kriterlerinize uyan kod yok."
          }
          action={initialCostCodes.length === 0 && <Button onClick={openCreate}>+ Yeni Maliyet Kodu</Button>}
        />
      ) : (
        <Table>
          <thead>
            <tr>
              <Th>Kod</Th>
              <Th>Ad</Th>
              <Th>Kategori</Th>
              <Th>Durum</Th>
              <Th className="w-32" />
            </tr>
          </thead>
          <tbody>
            {filtered.map((c) => (
              <Tr key={c.id} className={!c.is_active ? "opacity-60" : ""}>
                <Td className="font-medium">{c.code}</Td>
                <Td>
                  {c.name}
                  {c.description && <div className="text-xs text-text-muted">{c.description}</div>}
                </Td>
                <Td className="text-text-muted">{c.category || "—"}</Td>
                <Td>
                  <Badge tone={c.is_active ? "success" : "muted"}>{c.is_active ? "Aktif" : "Arşivlendi"}</Badge>
                </Td>
                <Td className="text-right">
                  <div className="flex justify-end gap-3">
                    <button type="button" onClick={() => openEdit(c)} className="text-xs text-gold hover:underline">
                      Düzenle
                    </button>
                    <button
                      type="button"
                      onClick={() => toggleActive(c)}
                      className={`text-xs hover:underline ${c.is_active ? "text-danger" : "text-success"}`}
                    >
                      {c.is_active ? "Arşivle" : "Etkinleştir"}
                    </button>
                  </div>
                </Td>
              </Tr>
            ))}
          </tbody>
        </Table>
      )}

      <Modal
        open={modalOpen}
        onClose={() => setModalOpen(false)}
        title={editing ? "Maliyet Kodunu Düzenle" : "Yeni Maliyet Kodu"}
      >
        <form onSubmit={submit} className="flex flex-col gap-3">
          <Input
            label="Kod"
            value={form.code}
            required
            disabled={!!editing}
            onChange={(e) => setForm({ ...form, code: e.target.value })}
            placeholder="ör. MLZ-001"
          />
          {editing && (
            <p className="-mt-2 text-xs text-text-muted">
              Kod oluşturulduktan sonra değiştirilemez (geçmiş kayıtlarla bağlantısını korumak için).
            </p>
          )}
          <Input
            label="Ad"
            value={form.name}
            required
            onChange={(e) => setForm({ ...form, name: e.target.value })}
            placeholder="ör. Hazır Beton"
          />
          <Input
            label="Kategori"
            value={form.category}
            onChange={(e) => setForm({ ...form, category: e.target.value })}
            placeholder="ör. Malzeme, İşçilik, Ekipman, Taşeron"
          />
          <Textarea
            label="Açıklama"
            className="min-h-16"
            value={form.description}
            onChange={(e) => setForm({ ...form, description: e.target.value })}
          />
          {error && <p className="text-xs text-danger">{error}</p>}
          <div className="flex gap-2 border-t border-border pt-3">
            <Button type="submit" loading={busy}>
              Kaydet
            </Button>
            <Button type="button" variant="ghost" onClick={() => setModalOpen(false)}>
              Vazgeç
            </Button>
          </div>
        </form>
      </Modal>
      {dialog}
    </div>
  );
}
