import { Layers } from "lucide-react";

import { COPY } from "@/lib/dashboard";

// Kurulum modunda (yeni firma) proje bağlı 9 kartın yerine tek kart:
// henüz proje yokken sıfırlarla dolu kartlar göstermez.
export function ProjectModulesPlaceholder() {
  return (
    <article
      aria-labelledby="modul-proje-modulleri-baslik"
      className="flex h-full items-start gap-3 rounded-lg border border-dashed border-border bg-surface px-4 py-4 @4xl/home:px-5"
    >
      <span aria-hidden className="flex size-7 shrink-0 items-center justify-center rounded-md bg-surface-hover text-text-muted">
        <Layers size={16} strokeWidth={1.75} />
      </span>
      <div className="min-w-0">
        <h3 id="modul-proje-modulleri-baslik" className="text-sm font-semibold text-text">
          {COPY.projectModules}
        </h3>
        <p className="mt-1 text-sm text-text-muted">{COPY.projectModulesBody}</p>
      </div>
    </article>
  );
}
