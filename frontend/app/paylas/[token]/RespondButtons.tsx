"use client";

import { useRouter } from "next/navigation";
import { useState } from "react";

import { Button } from "@/components/ui/Button";
import { Card, CardBody } from "@/components/ui/Card";
import { apiClient, ApiError } from "@/lib/api";

type Decision = "kabul edildi" | "reddedildi";

function respond(token: string, decision: Decision) {
  return apiClient(`/api/v1/public/offers/${token}/respond`, {
    method: "POST",
    body: JSON.stringify({ decision }),
  });
}

// Müşterinin cevabı geri alınamaz (teklif kabul/ret olarak kilitlenir), bu
// yüzden tek tıkla gönderilmez: önce hangi kararın verileceği açıkça
// sorulur. Giriş yapmamış müşteri için çalışsın diye modal değil, aynı
// kartta basit bir ikinci adım.
export function RespondButtons({ token }: { token: string }) {
  const router = useRouter();
  const [pending, setPending] = useState<Decision | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function confirmDecision() {
    if (!pending) return;
    setLoading(true);
    setError(null);
    try {
      await respond(token, pending);
      router.refresh();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Bağlantı hatası");
    } finally {
      setLoading(false);
    }
  }

  return (
    <Card>
      <CardBody className="flex flex-col items-center gap-3 text-center">
        {pending ? (
          <>
            <p className="text-sm text-text">
              {pending === "kabul edildi"
                ? "Teklifi kabul etmek üzeresiniz. Onayladıktan sonra cevabınız değiştirilemez."
                : "Teklifi reddetmek üzeresiniz. Onayladıktan sonra cevabınız değiştirilemez."}
            </p>
            <div className="flex flex-wrap justify-center gap-3">
              <Button variant="ghost" disabled={loading} onClick={() => setPending(null)}>
                Vazgeç
              </Button>
              <Button
                variant={pending === "kabul edildi" ? "primary" : "danger"}
                disabled={loading}
                onClick={confirmDecision}
              >
                {loading
                  ? "İşleniyor…"
                  : pending === "kabul edildi"
                    ? "Evet, Kabul Ediyorum"
                    : "Evet, Reddediyorum"}
              </Button>
            </div>
          </>
        ) : (
          <>
            <p className="text-sm text-text-muted">Bu teklifi onaylıyor musunuz?</p>
            <div className="flex gap-3">
              <Button onClick={() => setPending("kabul edildi")}>Kabul Et</Button>
              <Button variant="danger" onClick={() => setPending("reddedildi")}>
                Reddet
              </Button>
            </div>
          </>
        )}
        {error && <p className="text-xs text-danger">{error}</p>}
      </CardBody>
    </Card>
  );
}
