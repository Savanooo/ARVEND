import { Card, CardBody, CardHeader } from "@/components/ui/Card";
import { PageHeader } from "@/components/layout/PageHeader";
import { getCurrentUser } from "@/lib/auth";

export default async function AdminOzetPage() {
  const user = await getCurrentUser();
  return (
    <>
      <PageHeader title="Özet" />
      <div className="p-8">
        <Card className="max-w-md">
          <CardHeader>Hoş Geldin</CardHeader>
          <CardBody>
            <p className="text-sm text-text-muted">
              Merhaba <span className="font-semibold text-text">{user?.full_name}</span>,
              Arvend Yapı yönetim paneline hoş geldin. Sistemdeki kullanıcıları
              sol menüdeki <span className="text-gold">Kullanıcılar</span>{" "}
              sekmesinden yönetebilirsin. Diğer modüller (teklif, personel,
              mesai, maaş, borç/alacak) sırayla eklenecek.
            </p>
          </CardBody>
        </Card>
      </div>
    </>
  );
}
