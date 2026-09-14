"use client";

import Link from "next/link";
import { createContext, useContext, useState } from "react";

// İki modu var: `href` verilirse gerçek bir navigasyon linki olur
// (backend-sürümlü filtreler için -- Teklifler'in Aktif/Pasif'i,
// Projeler'in durum sekmeleri gibi, bir Server Component içinden bile
// güvenle kullanılabilir); `onClick` verilirse client-state ile panel
// değiştiren bir düğme olur (proje detayının 5 sekmesi gibi -- yalnızca
// "use client" bir üst bileşenden çağrılmalıdır, çünkü olay
// dinleyicileri Server Component çıktısına eklenemez).
export interface TabItem {
  key: string;
  label: string;
  active: boolean;
  href?: string;
  onClick?: () => void;
}

export function Tabs({ items }: { items: TabItem[] }) {
  return (
    <div role="tablist" className="flex items-center gap-1 border-b border-border">
      {items.map((item) => {
        const className = `border-b-2 px-3 py-2 text-sm font-medium transition-colors ${
          item.active
            ? "border-gold text-text"
            : "border-transparent text-text-muted hover:text-text"
        }`;
        if (item.href) {
          return (
            <Link key={item.key} href={item.href} role="tab" aria-selected={item.active} className={className}>
              {item.label}
            </Link>
          );
        }
        return (
          <button
            key={item.key}
            type="button"
            role="tab"
            aria-selected={item.active}
            onClick={item.onClick}
            className={className}
          >
            {item.label}
          </button>
        );
      })}
    </div>
  );
}

// ---------- Kontrollü sekme grubu (proje detayı gibi çok panel'li,
// sunucuda önceden çekilmiş veri barındıran durumlar için) ----------
//
// page.tsx (Server Component) tüm sekme içeriğini bir üst bileşenin
// (getNavItems() gibi) DÖNÜŞ DEĞERİ olarak DEĞİL, DOĞRUDAN kendi JSX
// dönüşünde çocuk (children) olarak yazar -- bu, zaten kanıtlanmış
// çalışan "<Section><PaymentPlanSection/></Section>" deseniyle AYNI
// (Server Component'in bir Client Component'e children geçirmesi resmî
// olarak desteklenir). Aktif sekme durumu, panel'lerin görünürlüğünü
// belirlemek için Context ile paylaşılır -- TÜM panel'ler DOM'da kalır
// (unmount edilmez), yalnızca CSS ile gizlenir, böylece sekme
// değişiminde accordion-açık durumu veya form state'i kaybolmaz.
const ControlledTabsContext = createContext<{ active: string; setActive: (v: string) => void } | null>(null);

export function ControlledTabs({
  items,
  defaultTab,
  children,
}: {
  items: { key: string; label: string }[];
  defaultTab: string;
  children: React.ReactNode;
}) {
  const [active, setActive] = useState(defaultTab);
  return (
    <ControlledTabsContext.Provider value={{ active, setActive }}>
      <Tabs
        items={items.map((item) => ({
          key: item.key,
          label: item.label,
          active: active === item.key,
          onClick: () => setActive(item.key),
        }))}
      />
      {children}
    </ControlledTabsContext.Provider>
  );
}

export function ControlledTabPanel({ tab, children }: { tab: string; children: React.ReactNode }) {
  const ctx = useContext(ControlledTabsContext);
  if (!ctx) throw new Error("ControlledTabPanel, ControlledTabs içinde kullanılmalı");
  return (
    <div role="tabpanel" hidden={ctx.active !== tab} className="flex flex-col gap-3 pt-4">
      {children}
    </div>
  );
}
