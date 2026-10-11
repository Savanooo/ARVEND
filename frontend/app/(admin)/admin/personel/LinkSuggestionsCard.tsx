"use client";

import { KeyRound } from "lucide-react";
import { useRouter } from "next/navigation";
import { useState } from "react";

import { Button } from "@/components/ui/Button";
import { Card, CardBody, CardHeader } from "@/components/ui/Card";
import { useToast } from "@/components/ui/Toast";
import { apiClient, ApiError } from "@/lib/api";
import { employeeUpdateBody } from "@/lib/person-link";
import type { Employee, EmployeeLinkSuggestion } from "@/lib/types";

// Personel listesinin üstünde: personel kaydı olmayan giriş hesapları ile
// BİREBİR aynı adı taşıyan bağlantısız personel ("kişi = tek kayıt" öncesi
// açılmış kayıtlar; mobil EmployeeLinkSuggestionsCard ile aynı). Sunucu
// hiçbirini kendiliğinden bağlamaz -- "batu" ile "Batuhan İnci" gibi farklı
// yazılmış adlar burada çıkmaz, onlar personel formundan elle bağlanır.
// Öneri yoksa sayfa bu kartı hiç çizmez.
export function LinkSuggestionsCard({ suggestions }: { suggestions: EmployeeLinkSuggestion[] }) {
  const router = useRouter();
  const toast = useToast();
  const [linkingId, setLinkingId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  async function link(s: EmployeeLinkSuggestion) {
    setLinkingId(s.employee_id);
    setError(null);
    try {
      // PUT tam-güncellemedir: kayıt taze okunur (ücretler dolu -- bu kart
      // yalnızca "Personeli düzenleme" ile görünür) ve yalnızca bağ
      // değişerek geri yazılır.
      const fresh = await apiClient<Employee>(`/api/v1/employees/${s.employee_id}`);
      await apiClient(`/api/v1/employees/${fresh.id}`, {
        method: "PUT",
        body: JSON.stringify(employeeUpdateBody(fresh, s.user_id)),
      });
      toast.success(`${fresh.full_name} personeli ${s.username} hesabına bağlandı.`);
      router.refresh();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Bağlantı hatası");
    } finally {
      setLinkingId(null);
    }
  }

  return (
    <Card>
      <CardHeader>Bağlanmamış hesaplar ({suggestions.length})</CardHeader>
      <CardBody className="flex flex-col gap-3">
        <p className="text-sm text-text-muted">
          Bu giriş hesaplarıyla aynı adı taşıyan personel kayıtları var. Bağlarsan kişi tek kayıt olur: göreve
          atandığında bildirim alır.
        </p>
        <ul className="flex flex-col divide-y divide-border">
          {suggestions.map((s) => (
            <li key={`${s.user_id}-${s.employee_id}`} className="flex items-center justify-between gap-3 py-2">
              <div className="min-w-0 text-sm">
                <p className="truncate font-medium">
                  {[s.employee_full_name, s.employee_position].filter(Boolean).join(" · ")}
                </p>
                <p className="flex items-center gap-1 truncate text-xs text-text-muted">
                  <KeyRound size={12} strokeWidth={1.75} aria-hidden />
                  {s.username}
                </p>
              </div>
              <Button
                type="button"
                variant="secondary"
                loading={linkingId === s.employee_id}
                disabled={linkingId !== null}
                onClick={() => link(s)}
              >
                Bağla
              </Button>
            </li>
          ))}
        </ul>
        {error && <p className="text-xs text-danger">{error}</p>}
      </CardBody>
    </Card>
  );
}
