import { Tabs } from "@/components/ui/Tabs";
import { ORG_STATUS_LABELS, type OrgStatus } from "@/lib/types";

const FILTERS: Array<{ key: string; label: string; value: OrgStatus | "" }> = [
  { key: "all", label: "Tümü", value: "" },
  { key: "active", label: ORG_STATUS_LABELS.active, value: "active" },
  { key: "trial", label: ORG_STATUS_LABELS.trial, value: "trial" },
  { key: "suspended", label: ORG_STATUS_LABELS.suspended, value: "suspended" },
  { key: "cancelled", label: ORG_STATUS_LABELS.cancelled, value: "cancelled" },
];

// Gerçek bir backend parametresine (status query param) karşılık gelir --
// href modu (Server Component'ten güvenle kullanılabilir, bkz. Tabs.tsx
// yorumu), /teklifler'in Aktif/Pasif sekmeleriyle aynı desen.
export function StatusFilterTabs({ current }: { current: OrgStatus | "" }) {
  return (
    <Tabs
      items={FILTERS.map((f) => ({
        key: f.key,
        label: f.label,
        active: f.value === current,
        href: `/super-admin?status=${f.value}&page=1`,
      }))}
    />
  );
}
