"use client";

import { FormEvent, useState } from "react";

import { Button } from "@/components/ui/Button";
import { Select } from "@/components/ui/Select";
import { apiClient, ApiError } from "@/lib/api";
import { BUSINESS_TYPE_OPTIONS, type OnboardingState, type OrganizationProfile } from "@/lib/types";

// Sihirbaz bağlamında bu adım onboarding'i de TAMAMLAR (bkz. backend
// SaveBusinessStep) -- Firma Ayarları bağlamında da AYNI uçtur, tekrar
// çağrılırsa (kullanıcı sonradan işletme türünü değiştirirse) zararsızdır
// (idempotent).
export function BusinessStepForm({
  basePath,
  initial,
  onSaved,
  submitLabel = "Tamamla",
  onBack,
}: {
  basePath: string;
  initial: OrganizationProfile;
  onSaved: (state: OnboardingState) => void;
  submitLabel?: string;
  onBack?: () => void;
}) {
  const [businessType, setBusinessType] = useState(initial.business_type);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    if (!businessType) {
      setError("İşletme türü seçin");
      return;
    }
    setError(null);
    setSaving(true);
    try {
      const state = await apiClient<OnboardingState>(`${basePath}/business`, {
        method: "PUT",
        body: JSON.stringify({ business_type: businessType }),
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
      <Select label="İşletme Türü" required value={businessType} onChange={(e) => setBusinessType(e.target.value)}>
        <option value="" disabled>
          Seçiniz…
        </option>
        {Object.entries(BUSINESS_TYPE_OPTIONS).map(([value, label]) => (
          <option key={value} value={value}>
            {label}
          </option>
        ))}
      </Select>
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
