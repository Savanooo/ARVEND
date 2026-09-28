"use client";

import { buttonClass } from "@/components/ui/styles";
import type { ProjectTab } from "@/lib/dashboard";

import { useProjectPicker } from "./ProjectPickerModal";

// Boş durum CTA'sı olarak proje gerektiren bir hızlı işlem (ör. Proje
// Finansı kartında "Tahsilat Gir"): önce proje sorulur, sonra sekmesi açılır.
// disabled YERİNE aria-disabled: odak düğmede kalır, seçici kapanınca
// oraya döner.
export function PickerActionButton({ tab, label }: { tab: ProjectTab; label: string }) {
  const picker = useProjectPicker();
  return (
    <>
      <button
        type="button"
        aria-disabled={picker.busy}
        aria-busy={picker.busy}
        onClick={(e) => void picker.start(tab, e.currentTarget)}
        className={buttonClass("secondary", "sm")}
      >
        {label}
      </button>
      {picker.modal}
    </>
  );
}
