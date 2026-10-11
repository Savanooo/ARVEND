import { Badge } from "@/components/ui/Badge";
import { formatDateTR } from "@/lib/format";
import { orgTrialBadge } from "@/lib/trial";
import type { Organization } from "@/lib/types";

// Deneme rozeti (kalan gün / bitti, İstanbul günü -- bkz. lib/trial.ts).
// Süre dolsa da firmanın erişimi kesilmez; kesmek Süper Admin'in firma
// durumunu değiştirmesidir (firma detayı > Genel). Firma listesi ve firma
// detayının başlığı kullanır.
export function TrialBadge({
  org,
  now,
}: {
  org: Pick<Organization, "status" | "trial_ends_at">;
  now: Date;
}) {
  const trial = orgTrialBadge(org, now);
  if (!trial) return null;
  return (
    <span title={`Deneme bitişi: ${formatDateTR(trial.endsOn)}`}>
      <Badge tone={trial.tone}>{trial.label}</Badge>
    </span>
  );
}
