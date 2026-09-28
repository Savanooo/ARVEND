import { CircleAlert } from "lucide-react";

import { COPY } from "@/lib/dashboard";

import { RetryButton } from "./RetryButton";

// Bir bölüm o an hesaplanamadığında (section_errors) kartın gövdesi: kart
// başlığı ve "Aç" bağlantısı yerinde kalır, diğer kartlar etkilenmez.
export function SectionError() {
  return (
    <div className="flex flex-wrap items-center justify-between gap-2 rounded-md bg-danger-soft px-3 py-2 text-sm text-danger">
      <span className="inline-flex items-center gap-2">
        <CircleAlert size={14} strokeWidth={2} aria-hidden />
        {COPY.sectionError}
      </span>
      <RetryButton />
    </div>
  );
}
