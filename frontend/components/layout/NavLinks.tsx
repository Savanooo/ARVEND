"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";

export interface NavItem {
  href: string;
  label: string;
}

export function NavLinks({ items }: { items: NavItem[] }) {
  const pathname = usePathname();
  return (
    <nav className="flex flex-col gap-1">
      {items.map((item) => {
        const active = pathname === item.href || pathname.startsWith(`${item.href}/`);
        return (
          <Link
            key={item.href}
            href={item.href}
            className={`sidebar-nav-link rounded-md px-3 py-2 text-sm font-medium transition-colors ${
              active ? "sidebar-nav-link-active" : ""
            }`}
          >
            {item.label}
          </Link>
        );
      })}
    </nav>
  );
}
