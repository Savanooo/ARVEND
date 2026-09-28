"use client";

import { Smartphone } from "lucide-react";
import { useEffect, useState } from "react";

import { API_BASE } from "@/lib/api";

type AppVersion = { build: number; version?: string; size?: number };

// Android uygulamasının güncel APK'sı (uzaktan güncelleme sunucusu, bkz.
// mobile/RELEASE.md §15). Sürüm ucu herkese açık; indirme ucu oturum
// çereziyle çalışır, bu yüzden bağlantı yalnızca giriş yapmış firma
// kullanıcılarının üst çubuğunda durur. Yayında sürüm yoksa hiç görünmez.
export function AppDownloadLink() {
  const [release, setRelease] = useState<AppVersion | null>(null);

  useEffect(() => {
    let alive = true;
    fetch(`${API_BASE}/api/v1/mobile/app-version?platform=android`, { cache: "no-store" })
      .then((res) => (res.ok ? (res.json() as Promise<AppVersion>) : null))
      .then((data) => {
        if (alive && data && data.build > 0) setRelease(data);
      })
      .catch(() => {});
    return () => {
      alive = false;
    };
  }, []);

  if (!release) return null;
  const size = release.size
    ? ` · ${(release.size / 1_000_000).toLocaleString("tr-TR", { maximumFractionDigits: 1 })} MB`
    : "";
  const label = `Android uygulamasını indir (v${release.version ?? ""}${size})`;

  return (
    <a
      href={`${API_BASE}/api/v1/mobile/app-download?platform=android`}
      title={label}
      aria-label={label}
      className="flex items-center gap-1.5 rounded-md px-2 py-1.5 text-sm text-text-muted hover:bg-surface-hover hover:text-text"
    >
      <Smartphone size={18} strokeWidth={1.75} />
      <span className="hidden md:inline">Uygulamayı indir</span>
    </a>
  );
}
