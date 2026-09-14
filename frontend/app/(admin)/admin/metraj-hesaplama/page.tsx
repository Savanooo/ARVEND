import Link from "next/link";
import { cookies } from "next/headers";

import { PageHeader } from "@/components/layout/PageHeader";
import { Card } from "@/components/ui/Card";
import { StatusBadge } from "@/components/ui/StatusBadge";
import { Table, Td, Th, Tr } from "@/components/ui/Table";
import { apiServer } from "@/lib/api";
import type { CalcGroup } from "@/lib/types";

import { NewGroupButton } from "./NewGroupButton";

async function fetchGroups() {
  const cookieHeader = (await cookies()).toString();
  return apiServer<{ groups: CalcGroup[] }>("/api/v1/calculations/groups", cookieHeader);
}

// Metraj Hesaplama admin ekranı: Grup -> Kategori -> Reçete Kalemi
// üç seviyeli bir yönetimdir (Ürünler admin ekranıyla aynı liste/detay
// deseni, bir seviye daha derin). Son kullanıcı reçete katsayılarını
// değiştiremez -- bu ekranın tamamı yalnızca admin'e açık route grubunda
// (app/(admin)) yaşar, backend de aynı kuralı requireAdmin ile uygular.
export default async function MetrajHesaplamaPage() {
  const { groups } = await fetchGroups();

  return (
    <>
      <PageHeader title="Metraj Hesaplama — Gruplar" action={<NewGroupButton />} />
      <div className="flex flex-col gap-4 p-8">
        <p className="text-sm text-text-muted">
          Teklif oluştururken kullanılan hesaplama gruplarını ve altındaki hesaplama türlerini
          (kategorileri) buradan yönetin. Her kategorinin kendi malzeme reçetesi vardır.
        </p>
        <Card>
          <Table>
            <thead>
              <tr>
                <Th>Grup</Th>
                <Th>Slug</Th>
                <Th>Sıra</Th>
                <Th>Durum</Th>
                <Th />
              </tr>
            </thead>
            <tbody>
              {groups.map((g) => (
                <Tr key={g.id}>
                  <Td className="font-medium">{g.name}</Td>
                  <Td className="text-text-muted">{g.slug}</Td>
                  <Td className="text-text-muted">{g.sort_order}</Td>
                  <Td>
                    <StatusBadge status={g.is_active ? "active" : "inactive"} registry={GROUP_STATUS} />
                  </Td>
                  <Td className="text-right">
                    <Link
                      href={`/admin/metraj-hesaplama/${g.id}`}
                      className="text-xs font-semibold uppercase tracking-widest text-gold hover:underline"
                    >
                      Kategoriler →
                    </Link>
                  </Td>
                </Tr>
              ))}
              {groups.length === 0 && (
                <tr>
                  <Td colSpan={5} className="text-center text-text-muted">
                    Henüz hesaplama grubu yok.
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

const GROUP_STATUS = {
  active: { label: "Aktif", tone: "success" as const },
  inactive: { label: "Pasif", tone: "muted" as const },
};
