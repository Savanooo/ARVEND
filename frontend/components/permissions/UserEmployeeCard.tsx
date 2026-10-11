"use client";

import { BadgeCheck, Link2, UserPlus } from "lucide-react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { useEffect, useState } from "react";

import { Badge } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { Card, CardBody, CardHeader } from "@/components/ui/Card";
import { Modal } from "@/components/ui/Modal";
import { useToast } from "@/components/ui/Toast";
import { apiClient, ApiError } from "@/lib/api";
import { istanbulDate } from "@/lib/format";
import {
  employeeForUserBody,
  employeeUpdateBody,
  samePersonName,
  unlinkedActiveEmployees,
} from "@/lib/person-link";
import type { Employee, User } from "@/lib/types";

// Kullanıcı detayındaki "Personel Kaydı": hesabın bağlı olduğu personel
// ("kişi = tek kayıt", mobil UserEmployeeCard ile aynı). Bağlıysa personel
// sayfasına götürür; değilse neden önemli olduğunu söyler ve (Personeli
// düzenleme izniyle) kaydı açar ya da mevcut bir personele bağlar -- ayrı
// kalmış eski kayıtlar ("batu" hesabı / "Batuhan İnci" personeli) buradan
// tek adımda birleşir.
export function UserEmployeeCard({
  user,
  canRead,
  canManage,
}: {
  user: User;
  // "Personeli görüntüleme": bağlı personel sayfasını açmak için.
  canRead: boolean;
  // "Personeli görüntüleme" + "Personeli düzenleme": oluştur / bağla.
  canManage: boolean;
}) {
  const router = useRouter();
  const toast = useToast();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [picking, setPicking] = useState(false);

  async function create() {
    setBusy(true);
    setError(null);
    try {
      await apiClient<Employee>("/api/v1/employees", {
        method: "POST",
        body: JSON.stringify(employeeForUserBody(user, istanbulDate(new Date()))),
      });
      toast.success(`${user.full_name} personel kaydı oluşturuldu.`);
      router.refresh();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Bağlantı hatası");
    } finally {
      setBusy(false);
    }
  }

  async function link(picked: Employee) {
    setPicking(false);
    setBusy(true);
    setError(null);
    try {
      // PUT tam-güncellemedir: kayıt "Personeli düzenleme" ile TAZE okunur
      // (ücretler dolu) ve yalnızca bağ değişerek geri yazılır.
      const fresh = await apiClient<Employee>(`/api/v1/employees/${picked.id}`);
      await apiClient(`/api/v1/employees/${fresh.id}`, {
        method: "PUT",
        body: JSON.stringify(employeeUpdateBody(fresh, user.id)),
      });
      toast.success(`${user.username} hesabı ${fresh.full_name} personeline bağlandı.`);
      router.refresh();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Bağlantı hatası");
    } finally {
      setBusy(false);
    }
  }

  return (
    <Card>
      <CardHeader>Personel Kaydı</CardHeader>
      <CardBody className="flex flex-col gap-3">
        {user.employee_id ? (
          <div className="flex items-center justify-between gap-3 text-sm">
            <span className="flex min-w-0 items-center gap-2">
              <BadgeCheck size={16} strokeWidth={1.75} className="shrink-0 text-gold" aria-hidden />
              {canRead ? (
                <Link href={`/admin/personel/${user.employee_id}`} className="truncate hover:text-gold hover:underline">
                  {user.employee_full_name || "Personel kaydı"}
                </Link>
              ) : (
                <span className="truncate">{user.employee_full_name || "Personel kaydı"}</span>
              )}
            </span>
            <Badge tone={user.employee_is_active === false ? "muted" : "success"}>
              {user.employee_is_active === false ? "Pasif" : "Aktif"}
            </Badge>
          </div>
        ) : (
          <>
            <p className="rounded-md border border-gold/40 bg-gold-soft px-3 py-2 text-sm">
              Bu hesabın personel kaydı yok: görev atanamaz, mesai ve maaş listelerinde görünmez.
            </p>
            {canManage && (
              <div className="flex flex-wrap gap-2">
                <Button type="button" onClick={create} loading={busy}>
                  <UserPlus size={14} strokeWidth={1.75} />
                  Personel Kaydı Oluştur
                </Button>
                <Button type="button" variant="secondary" disabled={busy} onClick={() => setPicking(true)}>
                  <Link2 size={14} strokeWidth={1.75} />
                  Mevcut Personele Bağla
                </Button>
              </div>
            )}
          </>
        )}
        {error && <p className="text-xs text-danger">{error}</p>}
      </CardBody>
      {picking && <UnlinkedEmployeePicker userFullName={user.full_name} onClose={() => setPicking(false)} onPick={link} />}
    </Card>
  );
}

// Bağlanabilecek (aktif, hesapsız) personel; kullanıcıyla aynı adı
// taşıyanlar başta.
function UnlinkedEmployeePicker({
  userFullName,
  onClose,
  onPick,
}: {
  userFullName: string;
  onClose: () => void;
  onPick: (e: Employee) => void;
}) {
  const [employees, setEmployees] = useState<Employee[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  // Pencere her açılışta yeniden kurulur: liste taze okunur.
  useEffect(() => {
    let alive = true;
    apiClient<{ employees: Employee[] }>("/api/v1/employees?filter=aktif")
      .then((r) => {
        if (!alive) return;
        setEmployees(
          unlinkedActiveEmployees(r.employees).sort((a, b) => {
            const sa = samePersonName(a.full_name, userFullName) ? 0 : 1;
            const sb = samePersonName(b.full_name, userFullName) ? 0 : 1;
            return sa !== sb ? sa - sb : a.full_name.localeCompare(b.full_name, "tr");
          })
        );
      })
      .catch((err) => {
        if (alive) setError(err instanceof ApiError ? err.message : "Personel listesi alınamadı.");
      });
    return () => {
      alive = false;
    };
  }, [userFullName]);

  return (
    <Modal open onClose={onClose} title="Personele Bağla">
      <p className="mb-3 text-xs text-text-muted">Yalnızca giriş hesabı olmayan aktif personel listelenir.</p>
      {error ? (
        <p className="text-xs text-danger">{error}</p>
      ) : employees === null ? (
        <p className="text-text-muted">Yükleniyor…</p>
      ) : employees.length === 0 ? (
        <p className="text-text-muted">Bağlanabilecek personel yok.</p>
      ) : (
        <ul className="flex flex-col divide-y divide-border">
          {employees.map((e) => {
            const sub = [e.position, samePersonName(e.full_name, userFullName) ? "Aynı ad" : ""].filter(Boolean).join(" · ");
            return (
              <li key={e.id} className="flex items-center justify-between gap-3 py-2">
                <div className="min-w-0">
                  <p className="truncate font-medium">{e.full_name}</p>
                  {sub && <p className="truncate text-xs text-text-muted">{sub}</p>}
                </div>
                <Button type="button" variant="secondary" onClick={() => onPick(e)}>
                  Bağla
                </Button>
              </li>
            );
          })}
        </ul>
      )}
    </Modal>
  );
}
