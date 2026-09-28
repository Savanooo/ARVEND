import { EMPTY } from "@/lib/dashboard";
import { formatCount } from "@/lib/format";

import { CompactModuleCard } from "../CompactModuleCard";
import type { CardContext } from "../context";

// Metraj (kompakt): grup/kategori sayısı; teklif okuma izniyle son 30 gün
// kullanımı, metraj yönetme izniyle ürüne bağlı olmayan reçete kalemleri.
export function CalculationsCard({ ctx }: { ctx: CardContext }) {
  const s = ctx.data.sections.calculations;
  if (!s) return <CompactModuleCard moduleKey="calculations" ctx={ctx} />;
  if (s.groups === 0) return <CompactModuleCard moduleKey="calculations" ctx={ctx} value={EMPTY.calculations} />;
  const notes: string[] = [];
  if (s.used_in_offer_lines_30d !== null) {
    notes.push(`Son 30 günde ${formatCount(s.used_in_offer_lines_30d)} teklif kaleminde kullanıldı`);
  }
  if (s.recipe_items_unlinked !== null && s.recipe_items_unlinked > 0) {
    notes.push(`${formatCount(s.recipe_items_unlinked)} reçete kalemi ürüne bağlı değil`);
  }
  return (
    <CompactModuleCard
      moduleKey="calculations"
      ctx={ctx}
      value={`${formatCount(s.groups)} grup · ${formatCount(s.categories)} kategori`}
      notes={notes}
    />
  );
}
