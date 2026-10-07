"use client";

import { RouteErrorView } from "@/components/layout/RouteFallbacks";

// Kabuk dışı sayfalar (platform, kurulum, paylaşım) ve kabuk layout'larının
// kendi hataları için son ağ; kabuk içindeki hatalar (app)/(admin)/(panel)
// grubunun error.tsx'inde, sidebar korunarak gösterilir.
export default function RootError(props: { error: Error & { digest?: string }; retry: () => void }) {
  return (
    <div className="flex min-h-screen">
      <RouteErrorView {...props} />
    </div>
  );
}
