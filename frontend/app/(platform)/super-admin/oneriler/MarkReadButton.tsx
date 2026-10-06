"use client";

import { useRouter } from "next/navigation";
import { useState } from "react";

import { Button } from "@/components/ui/Button";
import { apiClient } from "@/lib/api";

export function MarkReadButton({ id }: { id: string }) {
  const router = useRouter();
  const [loading, setLoading] = useState(false);
  return (
    <Button
      variant="ghost"
      className="px-2 py-1 text-xs"
      loading={loading}
      onClick={async () => {
        setLoading(true);
        try {
          await apiClient(`/api/v1/platform/feedback/${id}/read`, { method: "POST" });
          router.refresh();
        } finally {
          setLoading(false);
        }
      }}
    >
      Okundu
    </Button>
  );
}
