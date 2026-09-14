import type { LucideIcon } from "lucide-react";

// Ad-hoc "<tr><Td colSpan>Bulunamadı</Td></tr>" desenlerinin yerini alır.
export function EmptyState({
  icon: Icon,
  title,
  description,
  action,
}: {
  icon?: LucideIcon;
  title: string;
  description?: string;
  action?: React.ReactNode;
}) {
  return (
    <div className="flex flex-col items-center gap-2 px-6 py-12 text-center">
      {Icon && <Icon size={28} strokeWidth={1.5} className="text-text-muted" />}
      <p className="text-sm font-medium text-text">{title}</p>
      {description && <p className="text-xs text-text-muted">{description}</p>}
      {action && <div className="mt-2">{action}</div>}
    </div>
  );
}
