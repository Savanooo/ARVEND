import { Tabs } from "@/components/ui/Tabs";
import { ORG_STATUS_LABELS, type OrgStatus } from "@/lib/types";

// "deleted" GERÇEK bir OrgStatus DEĞİLDİR (bkz. lib/types.ts Organization.
// deleted_at yorumu -- silme, status'ten TAMAMEN AYRI bir eksendir) --
// yalnızca BU filtre listesinin kendi sözde-durumu, backend'de ayrı bir
// sorguya (ListDeletedOrganizations) yönlendirilir.
export type OrgListFilter = OrgStatus | "" | "deleted";

const FILTERS: Array<{ key: string; label: string; value: OrgListFilter }> = [
  { key: "all", label: "Tümü", value: "" },
  { key: "active", label: ORG_STATUS_LABELS.active, value: "active" },
  { key: "trial", label: ORG_STATUS_LABELS.trial, value: "trial" },
  { key: "suspended", label: ORG_STATUS_LABELS.suspended, value: "suspended" },
  { key: "cancelled", label: ORG_STATUS_LABELS.cancelled, value: "cancelled" },
  { key: "deleted", label: "Silinenler", value: "deleted" },
];

// Gerçek bir backend parametresine (status query param) karşılık gelir --
// href modu (Server Component'ten güvenle kullanılabilir, bkz. Tabs.tsx
// yorumu), /teklifler'in Aktif/Pasif sekmeleriyle aynı desen.
export function StatusFilterTabs({ current }: { current: OrgListFilter }) {
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
