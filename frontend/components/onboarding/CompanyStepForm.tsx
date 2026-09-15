"use client";

import { FormEvent, useState } from "react";

import { Button } from "@/components/ui/Button";
import { Input } from "@/components/ui/Input";
import { apiClient, ApiError } from "@/lib/api";
import type { OnboardingState, OrganizationProfile } from "@/lib/types";

// Bu bileşen HEM ilk-giriş sihirbazı (/kurulum, basePath=/api/v1/onboarding,
// submitLabel="İleri") HEM DE onboarding sonrası "Firma Ayarları" (/admin/
// firma-ayarlari, basePath=/api/v1/organization/settings, submitLabel=
// "Kaydet") tarafından AYNEN kullanılır -- backend'de AYNI OnboardingHandler
// metodlarını farklı mount path'i üzerinden çağırır (bkz. router.go).
export function CompanyStepForm({
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
    authorized_person: initial.authorized_person,
    phone: initial.phone,
    email: initial.email,
    website: initial.website,
    city: initial.city,
    district: initial.district,
    country: initial.country || "Türkiye",
  });
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    setError(null);
    setSaving(true);
    try {
      const state = await apiClient<OnboardingState>(`${basePath}/company`, {
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
        label="Yetkili Kişi"
        required
        value={form.authorized_person}
        onChange={(e) => setForm({ ...form, authorized_person: e.target.value })}
      />
      <div className="grid grid-cols-2 gap-3">
        <Input
          label="Telefon"
          value={form.phone}
          onChange={(e) => setForm({ ...form, phone: e.target.value })}
        />
        <Input
          label="E-posta"
          type="email"
          value={form.email}
          onChange={(e) => setForm({ ...form, email: e.target.value })}
        />
      </div>
      <Input
        label="Web Sitesi"
        value={form.website}
        onChange={(e) => setForm({ ...form, website: e.target.value })}
      />
      <div className="grid grid-cols-2 gap-3">
        <Input label="Şehir" value={form.city} onChange={(e) => setForm({ ...form, city: e.target.value })} />
        <Input
          label="İlçe"
          value={form.district}
          onChange={(e) => setForm({ ...form, district: e.target.value })}
        />
      </div>
      <Input label="Ülke" value={form.country} onChange={(e) => setForm({ ...form, country: e.target.value })} />
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
