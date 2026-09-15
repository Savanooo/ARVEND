"use client";

import { FormEvent, useState } from "react";

import { Button } from "@/components/ui/Button";
import { Input } from "@/components/ui/Input";
import { Textarea } from "@/components/ui/Textarea";
import { apiClient, ApiError } from "@/lib/api";
import type { OnboardingState, OrganizationProfile } from "@/lib/types";

export function BillingStepForm({
  basePath,
  initial,
  onSaved,
  submitLabel = "Kaydet",
  onBack,
}: {
  basePath: string;
  initial: OrganizationProfile;
  onSaved: (state: OnboardingState) => void;
  submitLabel?: string;
  onBack?: () => void;
}) {
  const [form, setForm] = useState({
    legal_name: initial.legal_name,
    tax_office: initial.tax_office,
    tax_number: initial.tax_number,
    invoice_address: initial.invoice_address,
  });
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    setError(null);
    setSaving(true);
    try {
      const state = await apiClient<OnboardingState>(`${basePath}/billing`, {
        method: "PUT",
        body: JSON.stringify(form),
      });
      onSaved(state);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Bağlantı hatası");
    } finally {
      setSaving(false);
    }
  }

  return (
    <form onSubmit={handleSubmit} className="flex flex-col gap-4">
      <Input
        label="Resmi Unvan"
        required
        value={form.legal_name}
        onChange={(e) => setForm({ ...form, legal_name: e.target.value })}
      />
      <div className="grid grid-cols-2 gap-3">
        <Input
          label="Vergi Dairesi"
          value={form.tax_office}
          onChange={(e) => setForm({ ...form, tax_office: e.target.value })}
        />
        <Input
          label="Vergi Numarası"
          required
          value={form.tax_number}
          onChange={(e) => setForm({ ...form, tax_number: e.target.value })}
        />
      </div>
      <Textarea
        label="Fatura Adresi"
        rows={3}
        value={form.invoice_address}
        onChange={(e) => setForm({ ...form, invoice_address: e.target.value })}
      />
      {error && <p className="text-xs text-danger">{error}</p>}
      <div className="flex gap-3 pt-2">
        {onBack && (
          <Button type="button" variant="secondary" onClick={onBack} className="flex-1">
            Geri
          </Button>
        )}
        <Button type="submit" disabled={saving} className="flex-1">
          {saving ? "Kaydediliyor…" : submitLabel}
        </Button>
      </div>
    </form>
  );
}
