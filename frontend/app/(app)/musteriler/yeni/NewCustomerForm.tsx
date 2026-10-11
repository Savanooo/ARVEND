"use client";

import { useRouter } from "next/navigation";
import { FormEvent, useState } from "react";

import { Button } from "@/components/ui/Button";
import { Card, CardBody } from "@/components/ui/Card";
import { Input } from "@/components/ui/Input";
import { apiClient, ApiError } from "@/lib/api";
import { duplicateCustomerFromError, type DuplicateCustomer } from "@/lib/customers";
import type { Customer } from "@/lib/types";

import { DuplicateCustomerDialog, type DuplicateCustomerChoice } from "../DuplicateCustomerDialog";

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
// Aynı vergi no/telefonla kayıtlı bir müşteri varsa backend 409
// duplicate_customer döner: pencere çakışan müşteriyi gösterir ve mobildeki
// gibi "Mevcut müşteriyi aç / Yine de kaydet (allow_duplicate) / Vazgeç"
// sorar (ör. aynı vergi numaralı iki şube bilerek ayrı kaydedilebilir).
//
// openExistingInNewTab: teklif formundaki pencerede mevcut müşteri YENİ
// SEKMEDE açılır -- teklif taslağı kaybolmasın.
export function CustomerCreateForm({
  onCreated,
  onCancel,
  initialName = "",
  openExistingInNewTab = false,
}: {
  onCreated: (customer: Customer) => void;
  onCancel?: () => void;
  initialName?: string;
  openExistingInNewTab?: boolean;
}) {
  const router = useRouter();
  const [form, setForm] = useState({ ...EMPTY_FORM, name: initialName });
  const [error, setError] = useState<string | null>(null);
  const [duplicate, setDuplicate] = useState<DuplicateCustomer | null>(null);
  const [loading, setLoading] = useState(false);

  function update(patch: Partial<typeof EMPTY_FORM>) {
    setForm((prev) => ({ ...prev, ...patch }));
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
      const dup = allowDuplicate ? null : duplicateCustomerFromError(err);
      if (dup) {
        setDuplicate(dup);
      } else {
        setError(err instanceof ApiError ? err.message : "Bağlantı hatası");
      }
    } finally {
      setLoading(false);
    }
  }

  function handleDuplicateChoice(choice: DuplicateCustomerChoice) {
    const dup = duplicate;
    setDuplicate(null);
    if (!dup) return;
    if (choice === "saveAnyway") {
      void save(true);
    } else if (choice === "open") {
      const href = `/musteriler/${encodeURIComponent(dup.id)}`;
      if (openExistingInNewTab) window.open(href, "_blank", "noopener,noreferrer");
      else router.push(href);
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
      {/* Yalnızca type="button" düğmeleri var: formu göndermez. */}
      <DuplicateCustomerDialog duplicate={duplicate} onChoice={handleDuplicateChoice} />
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
