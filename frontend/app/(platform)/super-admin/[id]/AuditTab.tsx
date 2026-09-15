import { EmptyState } from "@/components/ui/EmptyState";
import { Table, Td, Th, Tr } from "@/components/ui/Table";
import type { AuditEvent } from "@/lib/types";

const ACTION_LABELS: Record<string, string> = {
  organization_created: "Firma oluşturuldu",
  organization_suspended: "Firma askıya alındı",
  organization_activated: "Firma aktive edildi",
  organization_plan_changed: "Plan değiştirildi",
  calc_catalog_reprovisioned: "Metraj kataloğu kontrol edildi",
};

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
              <Td className="max-w-xs truncate text-xs text-text-muted" title={JSON.stringify(e.metadata)}>
                {JSON.stringify(e.metadata)}
              </Td>
              <Td className="text-text-muted">{new Date(e.created_at).toLocaleString("tr-TR")}</Td>
            </Tr>
          ))}
        </tbody>
      </Table>
    </div>
  );
}
