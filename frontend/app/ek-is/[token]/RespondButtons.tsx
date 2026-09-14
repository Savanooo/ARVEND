"use client";

import { useRouter } from "next/navigation";
import { useState } from "react";

import { Button } from "@/components/ui/Button";
import { Card, CardBody } from "@/components/ui/Card";
import { apiClient, ApiError } from "@/lib/api";

function respond(token: string, decision: "approved" | "rejected") {
  return apiClient(`/api/v1/public/change-orders/${token}/respond`, {
    method: "POST",
    body: JSON.stringify({ decision }),
  });
}

export function RespondButtons({ token }: { token: string }) {
  const router = useRouter();
  const [loading, setLoading] = useState<"approved" | "rejected" | null>(null);
  const [error, setError] = useState<string | null>(null);

  async function handle(decision: "approved" | "rejected") {
    setLoading(decision);
    setError(null);
    try {
      await respond(token, decision);
      router.refresh();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Bağlantı hatası");
    } finally {
      setLoading(null);
    }
  }

  return (
    <Card>
      <CardBody className="flex flex-col items-center gap-3">
        <p className="text-sm text-text-muted">Bu ek işi/eksiltmeyi onaylıyor musunuz?</p>
        <div className="flex gap-3">
          <Button disabled={loading !== null} onClick={() => handle("approved")}>
            {loading === "approved" ? "İşleniyor…" : "Kabul Et"}
          </Button>
          <Button variant="danger" disabled={loading !== null} onClick={() => handle("rejected")}>
            {loading === "rejected" ? "İşleniyor…" : "Reddet"}
          </Button>
        </div>
        {error && <p className="text-xs text-danger">{error}</p>}
      </CardBody>
    </Card>
  );
}
