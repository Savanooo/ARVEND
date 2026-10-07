"use client";

import { RouteErrorView } from "@/components/layout/RouteFallbacks";

export default function PanelError(props: { error: Error & { digest?: string }; retry: () => void }) {
  return <RouteErrorView {...props} />;
}
