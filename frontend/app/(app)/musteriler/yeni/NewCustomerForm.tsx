"use client";

import { useRouter } from "next/navigation";
import { FormEvent, useState } from "react";

import { Button } from "@/components/ui/Button";
import { Card, CardBody } from "@/components/ui/Card";
import { Input } from "@/components/ui/Input";
import { apiClient, ApiError } from "@/lib/api";
import type { Customer } from "@/lib/types";

const EMPTY_FORM = {
  name: "",
  phone: "",
  email: "",
  address: "",
  tax_office: "",
  tax_number: "",
  notes: "",
};

// Müşteri oluşturma formunun kendisi -- hem /musteriler/yeni sayfası hem
// teklif formundaki "+ Yeni Müşteri" penceresi bunu kullanır (teklif
// taslağı kaybolmasın diye orada sayfa değiştirilmez, oluşturulan müşteri
// doğrudan seçilir).
//
// Aynı vergi no/telefonla kayıtlı bir müşteri varsa backend 409 döner
// (müşteri uçlarında 409 YALNIZCA bu durumdur): mesajda mevcut müşterinin
// adı yazar; kullanıcı "Yine de Kaydet" ile bilerek ikinci kaydı açabilir
// (ör. aynı vergi numaralı iki şube).
export function CustomerCreateForm({
  onCreated,
  onCancel,
  initialName = "",
}: {
  onCreated: (customer: Customer) => void;
  onCancel?: () => void;
  initialName?: string;
}) {
  const [form, setForm] = useState({ ...EMPTY_FORM, name: initialName });
  const [error, setError] = useState<string | null>(null);
  const [duplicateWarning, setDuplicateWarning] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  function update(patch: Partial<typeof EMPTY_FORM>) {
    setForm((prev) => ({ ...prev, ...patch }));
    // Bilgi değişince eski çakışma uyarısı geçerliliğini yitirir.
    setDuplicateWarning(null);
  }

  async function save(allowDuplicate: boolean) {
    setError(null);
    setLoading(true);
    try {
      const created = await apiClient<Customer>("/api/v1/customers", {
        method: "POST",
        body: JSON.stringify({ ...form, allow_duplicate: allowDuplicate }),
      });
      onCreated(created);
    } catch (err) {
      if (err instanceof ApiError && err.status === 409) {
        setDuplicateWarning(err.message);
      } else {
        setError(err instanceof ApiError ? err.message : "Bağlantı hatası");
      }
    } finally {
      setLoading(false);
    }
  }

  function handleSubmit(e: FormEvent) {
    e.preventDefault();
    // İç içe form olmasın diye (teklif formunun içindeki pencere) olay
    // yukarı taşınmaz.
    e.stopPropagation();
    void save(false);
  }

  return (
    <form onSubmit={handleSubmit} className="flex flex-col gap-4">
      <Input label="Müşteri Adı" required value={form.name} onChange={(e) => update({ name: e.target.value })} />
      <div className="grid grid-cols-2 gap-3">
        <Input label="Telefon" value={form.phone} onChange={(e) => update({ phone: e.target.value })} />
        <Input label="E-posta" type="email" value={form.email} onChange={(e) => update({ email: e.target.value })} />
      </div>
      <Input label="Adres" value={form.address} onChange={(e) => update({ address: e.target.value })} />
      <div className="grid grid-cols-2 gap-3">
        <Input label="Vergi Dairesi" value={form.tax_office} onChange={(e) => update({ tax_office: e.target.value })} />
        <Input label="Vergi No" value={form.tax_number} onChange={(e) => update({ tax_number: e.target.value })} />
      </div>
      <Input label="Not" value={form.notes} onChange={(e) => update({ notes: e.target.value })} />
      {error && <p className="text-xs text-danger">{error}</p>}
      {duplicateWarning && (
        <div className="flex flex-col gap-2 rounded-md border border-gold/40 bg-gold-soft p-3 text-xs">
          <p>{duplicateWarning}. Yine de yeni bir müşteri kaydı açmak istiyor musunuz?</p>
          <Button type="button" variant="secondary" className="w-fit" disabled={loading} onClick={() => save(true)}>
            Yine de Kaydet
          </Button>
        </div>
      )}
      <div className="flex items-center gap-2">
        <Button type="submit" disabled={loading}>
          {loading ? "Kaydediliyor…" : "Müşteri Ekle"}
        </Button>
        {onCancel && (
          <Button type="button" variant="ghost" disabled={loading} onClick={onCancel}>
            Vazgeç
          </Button>
        )}
      </div>
    </form>
  );
}

export function NewCustomerForm() {
  const router = useRouter();
  return (
    <Card className="max-w-md">
      <CardBody>
        <CustomerCreateForm
          onCreated={() => {
            router.push("/musteriler");
            router.refresh();
          }}
        />
      </CardBody>
    </Card>
  );
}
