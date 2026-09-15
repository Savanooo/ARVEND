"use client";

import { FormEvent, useState } from "react";

import { Button } from "@/components/ui/Button";
import { Input } from "@/components/ui/Input";
import { Textarea } from "@/components/ui/Textarea";
import { apiClient, ApiError } from "@/lib/api";
import type { OnboardingState, OrganizationCommercialSettings } from "@/lib/types";

export function OffersStepForm({
  basePath,
  initial,
  onSaved,
  submitLabel = "Kaydet",
  onBack,
}: {
  basePath: string;
  initial: OrganizationCommercialSettings;
  onSaved: (state: OnboardingState) => void;
  submitLabel?: string;
  onBack?: () => void;
}) {
  const [form, setForm] = useState({
    default_currency: initial.default_currency || "TRY",
    default_vat_rate: initial.default_vat_rate ?? 20,
    offer_prefix: initial.offer_prefix || "TKF",
    offer_validity_days: initial.offer_validity_days || 30,
    default_offer_footer: initial.default_offer_footer,
    default_payment_terms: initial.default_payment_terms,
    default_delivery_terms: initial.default_delivery_terms,
  });
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    setError(null);
    setSaving(true);
    try {
      const state = await apiClient<OnboardingState>(`${basePath}/offers`, {
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
      <div className="grid grid-cols-2 gap-3">
        <Input
          label="Teklif Numarası Öneki"
          required
          placeholder="TKF"
          value={form.offer_prefix}
          onChange={(e) => setForm({ ...form, offer_prefix: e.target.value })}
        />
        <Input
          label="Geçerlilik (gün)"
          type="number"
          min={1}
          required
          value={form.offer_validity_days}
          onChange={(e) => setForm({ ...form, offer_validity_days: parseInt(e.target.value) || 0 })}
        />
      </div>
      <div className="grid grid-cols-2 gap-3">
        <Input
          label="Varsayılan Para Birimi"
          value={form.default_currency}
          onChange={(e) => setForm({ ...form, default_currency: e.target.value })}
        />
        <Input
          label="Varsayılan KDV Oranı (%)"
          type="number"
          min={0}
          step="0.01"
          value={form.default_vat_rate}
          onChange={(e) => setForm({ ...form, default_vat_rate: parseFloat(e.target.value) || 0 })}
        />
      </div>
      <Textarea
        label="Varsayılan Ödeme Koşulları"
        rows={2}
        value={form.default_payment_terms}
        onChange={(e) => setForm({ ...form, default_payment_terms: e.target.value })}
      />
      <Textarea
        label="Varsayılan Teslimat Koşulları"
        rows={2}
        value={form.default_delivery_terms}
        onChange={(e) => setForm({ ...form, default_delivery_terms: e.target.value })}
      />
      <Textarea
        label="Teklif Alt Notu"
        rows={2}
        value={form.default_offer_footer}
        onChange={(e) => setForm({ ...form, default_offer_footer: e.target.value })}
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
