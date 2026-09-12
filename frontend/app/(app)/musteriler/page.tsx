import Link from "next/link";
import { cookies } from "next/headers";

import { Badge } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { Card } from "@/components/ui/Card";
import { Input } from "@/components/ui/Input";
import { Table, Td, Th, Tr } from "@/components/ui/Table";
import { Topbar } from "@/components/layout/Topbar";
import { apiServer } from "@/lib/api";
import type { Customer } from "@/lib/types";

async function fetchCustomers(q: string) {
  const cookieHeader = (await cookies()).toString();
  const qs = q ? `?q=${encodeURIComponent(q)}` : "";
  return apiServer<{ customers: Customer[] }>(`/api/v1/customers${qs}`, cookieHeader);
}

export default async function MusterilerPage({
  searchParams,
}: {
  searchParams: Promise<{ q?: string }>;
}) {
  const { q = "" } = await searchParams;
  const { customers } = await fetchCustomers(q);

  return (
    <>
      <Topbar
        title="Müşteriler"
        action={
          <Link href="/musteriler/yeni">
            <Button>+ Yeni Müşteri</Button>
          </Link>
        }
      />
      <div className="flex flex-col gap-4 p-8">
        <form className="max-w-xs">
          <Input name="q" defaultValue={q} placeholder="Müşteri adında ara…" />
        </form>
        <Card>
          <Table>
            <thead>
              <tr>
                <Th>Müşteri</Th>
                <Th>Telefon</Th>
                <Th>E-posta</Th>
                <Th>Durum</Th>
                <Th />
              </tr>
            </thead>
            <tbody>
              {customers.map((c) => (
                <Tr key={c.id}>
                  <Td className="font-medium">{c.name}</Td>
                  <Td className="text-text-muted">{c.phone || "—"}</Td>
                  <Td className="text-text-muted">{c.email || "—"}</Td>
                  <Td>
                    <Badge tone={c.is_active ? "success" : "muted"}>
                      {c.is_active ? "Aktif" : "Pasif"}
                    </Badge>
                  </Td>
                  <Td className="text-right">
                    <Link
                      href={`/musteriler/${c.id}`}
                      className="text-xs font-semibold uppercase tracking-widest text-gold hover:underline"
                    >
                      Düzenle
                    </Link>
                  </Td>
                </Tr>
              ))}
              {customers.length === 0 && (
                <tr>
                  <Td colSpan={5} className="text-center text-text-muted">
                    Müşteri bulunamadı.
                  </Td>
                </tr>
              )}
            </tbody>
          </Table>
        </Card>
      </div>
    </>
  );
}
