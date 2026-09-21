import { EmptyState } from "@/components/ui/EmptyState";
import { Table, Td, Th, Tr } from "@/components/ui/Table";
import { ORG_ROLE_LABELS, ORG_STATUS_LABELS, type AuditEvent, type OrgRoleCode, type OrgStatus } from "@/lib/types";

// Yalnızca backend'in platform_audit_events'e YAZDIĞI işlemler -- burada
// tenant operasyonu (teklif/proje/finans) yoktur, üretilmez.
const ACTION_LABELS: Record<string, string> = {
  organization_created: "Firma oluşturuldu",
  organization_suspended: "Firma askıya alındı",
  organization_activated: "Firma aktifleştirildi",
  organization_cancelled: "Firma iptal edildi",
  organization_plan_changed: "Plan değiştirildi",
  calc_catalog_reprovisioned: "Metraj kataloğu kontrol edildi",
  user_provisioned: "Kullanıcı tanımlandı",
  user_deactivated: "Kullanıcı pasifleştirildi",
  user_reactivated: "Kullanıcı aktifleştirildi",
  user_role_changed: "Kullanıcı rolü değiştirildi",
  user_password_reset: "Geçici şifre verildi",
};

const META_LABELS: Record<string, string> = {
  organization_name: "Firma",
  slug: "Slug",
  plan_code: "Plan",
  status: "Durum",
  from: "Önceki durum",
  owner_username: "Sahip",
  username: "Kullanıcı adı",
  role_code: "Rol",
  groups_created: "Grup",
  categories_created: "Kategori",
  items_created: "Kalem",
};

// status/from ve role_code, backend'de dahili enum kodlarıdır ("suspended",
// "owner"); denetim geçmişinde de ürünün geri kalanıyla AYNI Türkçe
// etiketlerle gösterilir -- ham kodlar hiçbir ekranda kullanıcıya
// gösterilmez (terminoloji ilkesi, bkz. docs/super-admin-provisioning.md).
const VALUE_LABELS: Partial<Record<string, (v: string) => string>> = {
  status: (v) => ORG_STATUS_LABELS[v as OrgStatus] ?? v,
  from: (v) => ORG_STATUS_LABELS[v as OrgStatus] ?? v,
  role_code: (v) => ORG_ROLE_LABELS[v as OrgRoleCode] ?? v,
};

function describe(metadata: Record<string, unknown>): string {
  const parts = Object.entries(metadata).map(([k, v]) => {
    const raw = String(v);
    const label = VALUE_LABELS[k]?.(raw) ?? raw;
    return `${META_LABELS[k] ?? k}: ${label}`;
  });
  return parts.join(" · ");
}

export function AuditTab({ events }: { events: AuditEvent[] }) {
  if (events.length === 0) {
    return <EmptyState title="Henüz denetim kaydı yok" />;
  }
  return (
    <div className="pt-2">
      <Table>
        <thead>
          <tr>
            <Th>İşlem</Th>
            <Th>Detay</Th>
            <Th>Tarih</Th>
          </tr>
        </thead>
        <tbody>
          {events.map((e) => (
            <Tr key={e.id}>
              <Td className="font-medium">{ACTION_LABELS[e.action] ?? e.action}</Td>
              <Td className="max-w-md truncate text-xs text-text-muted" title={describe(e.metadata)}>
                {describe(e.metadata) || "—"}
              </Td>
              <Td className="whitespace-nowrap text-text-muted">{new Date(e.created_at).toLocaleString("tr-TR")}</Td>
            </Tr>
          ))}
        </tbody>
      </Table>
    </div>
  );
}
