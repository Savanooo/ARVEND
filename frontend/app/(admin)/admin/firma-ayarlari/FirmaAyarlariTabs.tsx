"use client";

import { useState } from "react";

import { Card, CardBody } from "@/components/ui/Card";
import { ControlledTabPanel, ControlledTabs } from "@/components/ui/Tabs";
import { BillingStepForm } from "@/components/onboarding/BillingStepForm";
import { BusinessStepForm } from "@/components/onboarding/BusinessStepForm";
import { CompanyStepForm } from "@/components/onboarding/CompanyStepForm";
import { FinanceStepForm } from "@/components/onboarding/FinanceStepForm";
import { OffersStepForm } from "@/components/onboarding/OffersStepForm";
import type { OnboardingState } from "@/lib/types";

const BASE_PATH = "/api/v1/organization/settings";

// Onboarding SONRASI serbest düzenleme -- AYNI 5 adım bileşenini (bkz.
// components/onboarding/) kullanır, AYNI backend state'ini okur/yazar,
// ama sihirbazın aksine sekmeler arasında SERBEST gezinilir (zorunlu
// ileri/geri yok), her sekme kendi "Kaydet" düğmesiyle bağımsız kaydedilir.
export function FirmaAyarlariTabs({ initialState }: { initialState: OnboardingState }) {
  const [state, setState] = useState(initialState);
  const [savedMessage, setSavedMessage] = useState<string | null>(null);

  function handleSaved(newState: OnboardingState) {
    setState(newState);
    setSavedMessage("Kaydedildi.");
  }

  return (
    <Card>
      <CardBody>
        <ControlledTabs
          defaultTab="company"
          items={[
            { key: "company", label: "Firma" },
            { key: "billing", label: "Resmi / Fatura" },
            { key: "offers", label: "Teklif" },
            { key: "finance", label: "Finans" },
            { key: "business", label: "İşletme" },
          ]}
        >
          {savedMessage && <p className="pt-3 text-xs text-success">{savedMessage}</p>}
          <ControlledTabPanel tab="company">
            <CompanyStepForm basePath={BASE_PATH} initial={state.profile} onSaved={handleSaved} />
          </ControlledTabPanel>
          <ControlledTabPanel tab="billing">
            <BillingStepForm basePath={BASE_PATH} initial={state.profile} onSaved={handleSaved} />
          </ControlledTabPanel>
          <ControlledTabPanel tab="offers">
            <OffersStepForm basePath={BASE_PATH} initial={state.commercial} onSaved={handleSaved} />
          </ControlledTabPanel>
          <ControlledTabPanel tab="finance">
            <FinanceStepForm basePath={BASE_PATH} initial={state.commercial} onSaved={handleSaved} />
          </ControlledTabPanel>
          <ControlledTabPanel tab="business">
            <BusinessStepForm
              basePath={BASE_PATH}
              initial={state.profile}
              onSaved={handleSaved}
              submitLabel="Kaydet"
            />
          </ControlledTabPanel>
        </ControlledTabs>
      </CardBody>
    </Card>
  );
}
