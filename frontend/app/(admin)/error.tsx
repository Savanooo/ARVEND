"use client";

import { RouteErrorView } from "@/components/layout/RouteFallbacks";

export default function AdminError(props: { error: Error & { digest?: string }; retry: () => void }) {
  return <RouteErrorView {...props} />;
}
