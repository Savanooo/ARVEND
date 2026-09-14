"use client";

import { useRouter } from "next/navigation";
import { FormEvent, useState } from "react";

import { Button } from "@/components/ui/Button";
import { Input } from "@/components/ui/Input";
import { Modal } from "@/components/ui/Modal";
import { Textarea } from "@/components/ui/Textarea";
import { apiClient, ApiError } from "@/lib/api";

function slugify(name: string): string {
  return name
    .toLocaleLowerCase("tr-TR")
    .replace(/ğ/g, "g")
    .replace(/ü/g, "u")
    .replace(/ş/g, "s")
    .replace(/ı/g, "i")
    .replace(/ö/g, "o")
    .replace(/ç/g, "c")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/(^-|-$)/g, "");
}

export function NewCategoryButton({ groupId }: { groupId: string }) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [name, setName] = useState("");
  const [slug, setSlug] = useState("");
  const [description, setDescription] = useState("");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    setSaving(true);
    setError(null);
    try {
      await apiClient("/api/v1/calculations/categories", {
        method: "POST",
        body: JSON.stringify({
          group_id: groupId,
          slug: slug || slugify(name),
          name,
          description,
          sort_order: 0,
        }),
      });
      setOpen(false);
      setName("");
      setSlug("");
      setDescription("");
      router.refresh();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Bağlantı hatası");
    } finally {
      setSaving(false);
    }
  }

  return (
    <>
      <Button onClick={() => setOpen(true)}>+ Yeni Kategori</Button>
      <Modal open={open} onClose={() => setOpen(false)} title="Yeni Hesaplama Türü (Kategori)">
        <form onSubmit={handleSubmit} className="flex flex-col gap-4">
          <Input
            label="Ad"
            required
            value={name}
            onChange={(e) => {
              setName(e.target.value);
              setSlug((prev) => (prev === "" || prev === slugify(name) ? slugify(e.target.value) : prev));
            }}
            placeholder="ör. 10x10 Petek Tavan"
          />
          <Input label="Slug" required value={slug} onChange={(e) => setSlug(e.target.value)} />
          <Textarea
            label="Açıklama"
            value={description}
            onChange={(e) => setDescription(e.target.value)}
          />
          {error && <p className="text-xs text-danger">{error}</p>}
          <Button type="submit" disabled={saving}>
            {saving ? "Kaydediliyor…" : "Oluştur"}
          </Button>
        </form>
      </Modal>
    </>
  );
}
