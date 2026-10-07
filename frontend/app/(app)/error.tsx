"use client";

import { RouteErrorView } from "@/components/layout/RouteFallbacks";

export default function AppError(props: { error: Error & { digest?: string }; retry: () => void }) {
  return <RouteErrorView {...props} />;
}
