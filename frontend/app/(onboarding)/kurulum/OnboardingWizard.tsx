"use client";

import { useRouter } from "next/navigation";
import { useState } from "react";

import { Card, CardBody } from "@/components/ui/Card";
import { BillingStepForm } from "@/components/onboarding/BillingStepForm";
import { BusinessStepForm } from "@/components/onboarding/BusinessStepForm";
import { CompanyStepForm } from "@/components/onboarding/CompanyStepForm";
import { FinanceStepForm } from "@/components/onboarding/FinanceStepForm";
import { OffersStepForm } from "@/components/onboarding/OffersStepForm";
import { ONBOARDING_STEP_LABELS, type OnboardingState, type OnboardingStep } from "@/lib/types";

const BASE_PATH = "/api/v1/onboarding";
const STEP_ORDER: OnboardingStep[] = ["company", "billing", "offers", "finance", "business"];

function stepIndex(step: OnboardingStep): number {
  const i = STEP_ORDER.indexOf(step);
  return i < 0 ? 0 : i;
}

// Server-authoritative, forward-only 5 adımlık sihirbaz -- web/mobil AYNI
// backend state'ini (organizations.onboarding_step/onboarding_completed +
// organization_profile/organization_commercial_settings) okur/yazar. Yerel
// state yalnızca hangi adımın GÖSTERİLDİĞİNİ tutar, hangi adımın
// TAMAMLANDIĞINI değil -- her "İleri" gerçek bir PUT çağrısıdır.
export function OnboardingWizard({ initialState }: { initialState: OnboardingState }) {
  const router = useRouter();
  const [state, setState] = useState(initialState);
  const [visibleStep, setVisibleStep] = useState(() =>
    Math.min(stepIndex(initialState.onboarding_step), STEP_ORDER.length - 1)
  );

  function handleSaved(newState: OnboardingState) {
    setState(newState);
    if (newState.onboarding_completed) {
      // must_change_password/onboarding gibi alanları taşıyan userResponse'u
      // tazelemek için layout zincirini yeniden çalıştır -- sunucu artık
      // ana sayfaya yönlendirecek.
      router.push("/");
      router.refresh();
      return;
    }
    const nextIndex = Math.min(stepIndex(newState.onboarding_step), STEP_ORDER.length - 1);
    setVisibleStep((current) => Math.max(current + 1, nextIndex));
  }

  const step = STEP_ORDER[visibleStep];
  const onBack = visibleStep > 0 ? () => setVisibleStep((v) => v - 1) : undefined;

  return (
    <Card>
      <CardBody className="flex flex-col gap-6">
        <div className="flex flex-col gap-3 text-center">
          <h1 className="text-sm font-bold uppercase tracking-widest">Firma Kurulumu</h1>
          <div className="flex items-center gap-1.5">
            {STEP_ORDER.map((s, i) => (
              <div
                key={s}
                className={`h-1 flex-1 rounded-full ${i <= visibleStep ? "bg-gold" : "bg-border"}`}
              />
            ))}
          </div>
          <p className="text-xs text-text-muted">
            Adım {visibleStep + 1} / {STEP_ORDER.length} · {ONBOARDING_STEP_LABELS[step]}
          </p>
        </div>

        {step === "company" && (
          <CompanyStepForm
            basePath={BASE_PATH}
            initial={state.profile}
            onSaved={handleSaved}
            submitLabel="İleri"
          />
        )}
        {step === "billing" && (
          <BillingStepForm
            basePath={BASE_PATH}
            initial={state.profile}
            onSaved={handleSaved}
            submitLabel="İleri"
            onBack={onBack}
          />
        )}
        {step === "offers" && (
          <OffersStepForm
            basePath={BASE_PATH}
            initial={state.commercial}
            onSaved={handleSaved}
            submitLabel="İleri"
            onBack={onBack}
          />
        )}
        {step === "finance" && (
          <FinanceStepForm
            basePath={BASE_PATH}
            initial={state.commercial}
            onSaved={handleSaved}
            submitLabel="İleri"
            onBack={onBack}
          />
        )}
        {step === "business" && (
          <BusinessStepForm
            basePath={BASE_PATH}
            initial={state.profile}
            onSaved={handleSaved}
            submitLabel="Tamamla"
            onBack={onBack}
          />
        )}
      </CardBody>
    </Card>
  );
}
