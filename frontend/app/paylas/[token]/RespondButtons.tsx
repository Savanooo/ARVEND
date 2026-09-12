"use client";

import { useRouter } from "next/navigation";
import { useState } from "react";

import { Button } from "@/components/ui/Button";
import { Card, CardBody } from "@/components/ui/Card";
import { apiClient, ApiError } from "@/lib/api";

function respond(token: string, decision: "kabul edildi" | "reddedildi") {
  return apiClient(`/api/v1/public/offers/${token}/respond`, {
    method: "POST",
    body: JSON.stringify({ decision }),
  });
}

export function RespondButtons({ token }: { token: string }) {
  const router = useRouter();
  const [loading, setLoading] = useState<"kabul" | "red" | null>(null);
  const [error, setError] = useState<string | null>(null);

  async function handle(decision: "kabul edildi" | "reddedildi") {
    setLoading(decision === "kabul edildi" ? "kabul" : "red");
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
        <p className="text-sm text-text-muted">Bu teklifi onaylıyor musunuz?</p>
        <div className="flex gap-3">
          <Button disabled={loading !== null} onClick={() => handle("kabul edildi")}>
            {loading === "kabul" ? "İşleniyor…" : "Kabul Et"}
          </Button>
          <Button
            variant="danger"
            disabled={loading !== null}
            onClick={() => handle("reddedildi")}
          >
            {loading === "red" ? "İşleniyor…" : "Reddet"}
          </Button>
        </div>
        {error && <p className="text-xs text-danger">{error}</p>}
      </CardBody>
    </Card>
  );
}
