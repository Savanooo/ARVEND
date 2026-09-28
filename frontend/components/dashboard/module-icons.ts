import {
  AlarmClock,
  ArrowDownUp,
  Bell,
  Building2,
  ClipboardCheck,
  Clock,
  Coins,
  Construction,
  FilePlus,
  FileText,
  Handshake,
  HardHat,
  Hourglass,
  Landmark,
  ListChecks,
  type LucideIcon,
  Package,
  Ruler,
  Scale,
  ScrollText,
  ShoppingCart,
  TriangleAlert,
  Truck,
  UserCog,
  Users,
  Wallet,
} from "lucide-react";

import type { KpiKey, ModuleKey, Severity } from "@/lib/dashboard";

// Ana sayfa ikonları (lucide 16/1.75). "use client" OLMAYAN saf eşleme:
// Server ve Client Component'ler kendileri içe aktarır (ikon bileşeni prop
// olarak sunucudan istemciye geçirilmez).
export const MODULE_ICONS: Record<ModuleKey, LucideIcon> = {
  finance: Wallet,
  offers: FileText,
  change_orders: FilePlus,
  projects: Building2,
  tasks: ListChecks,
  operations: Construction,
  contracts: ScrollText,
  attendance: Clock,
  procurement: ShoppingCart,
  subcontracts: Handshake,
  cost_control: Scale,
  customers: Users,
  employees: HardHat,
  products: Package,
  users: UserCog,
  calculations: Ruler,
  suppliers: Truck,
  cost_codes: Coins,
};

export const KPI_ICONS: Record<KpiKey, LucideIcon> = {
  receivable: Wallet,
  net_cash: ArrowDownUp,
  pipeline: FileText,
  cash_balance: Landmark,
  active_projects: Building2,
  my_tasks: ListChecks,
  team_overdue: AlarmClock,
  on_site: HardHat,
  unread: Bell,
};

export const SEVERITY_ICONS: Record<Severity, LucideIcon> = {
  danger: TriangleAlert,
  action: ClipboardCheck,
  info: Hourglass,
};

// Önem rengi: tehlike kırmızı, aksiyon altın (yalnızca ikon/çubuk -- küçük
// metinde altın kullanılmaz, kontrast), bilgi mavi.
export const SEVERITY_TEXT: Record<Severity, string> = {
  danger: "text-danger",
  action: "text-gold",
  info: "text-info",
};

export const SEVERITY_BAR: Record<Severity, string> = {
  danger: "bg-danger",
  action: "bg-gold",
  info: "bg-info",
};
