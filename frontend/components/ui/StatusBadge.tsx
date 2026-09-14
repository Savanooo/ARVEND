import type { StatusMeta } from "@/lib/status";

import { Badge } from "./Badge";

// Durum -> renk/etiket eşlemesinin TEK tüketicisi -- eşlemenin kendisi
// lib/status.ts'te, domain başına bir registry olarak tutulur.
export function StatusBadge<T extends string>({
  status,
  registry,
}: {
  status: T;
  registry: Record<T, StatusMeta>;
}) {
  const meta = registry[status];
  return <Badge tone={meta.tone}>{meta.label}</Badge>;
}
