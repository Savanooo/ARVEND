"use client";

import { FormEvent, useState } from "react";

import { Button } from "@/components/ui/Button";
import { Input } from "@/components/ui/Input";
import { apiClient, ApiError } from "@/lib/api";
import type { OnboardingState, OrganizationCommercialSettings } from "@/lib/types";

// IBAN alanı BİLİNÇLİ OLARAK önceden doldurulmaz -- backend hiçbir zaman
// plaintext IBAN döndürmez (bkz. lib/types.ts OrganizationCommercialSettings
// yorumu). Boş bırakılırsa mevcut IBAN korunur (SMTP şifresiyle aynı
// konvansiyon, bkz. SmtpSettingsForm.tsx).
export function FinanceStepForm({
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
  const [bankName, setBankName] = useState(initial.bank_name);
  const [accountHolder, setAccountHolder] = useState(initial.account_holder);
  const [iban, setIban] = useState("");
  const [paymentDueDays, setPaymentDueDays] = useState(initial.payment_due_days?.toString() ?? "");
  const [ibanSet, setIbanSet] = useState(initial.iban_set);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    setError(null);
    setSaving(true);
    try {
      const state = await apiClient<OnboardingState>(`${basePath}/finance`, {
        method: "PUT",
        body: JSON.stringify({
          bank_name: bankName,
          account_holder: accountHolder,
          iban: iban || null,
          payment_due_days: paymentDueDays ? parseInt(paymentDueDays) : null,
        }),
      });
      setIbanSet(state.commercial.iban_set);
      setIban("");
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
        <Input label="Banka Adı" value={bankName} onChange={(e) => setBankName(e.target.value)} />
        <Input label="Hesap Sahibi" value={accountHolder} onChange={(e) => setAccountHolder(e.target.value)} />
      </div>
      <Input
        label="IBAN"
        placeholder={ibanSet ? "Kayıtlı IBAN korunuyor -- değiştirmek için girin" : "TR.."}
        value={iban}
        onChange={(e) => setIban(e.target.value)}
      />
      <Input
        label="Ödeme Vadesi (gün, opsiyonel)"
        type="number"
        min={0}
        value={paymentDueDays}
        onChange={(e) => setPaymentDueDays(e.target.value)}
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
