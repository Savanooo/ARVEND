import { Card, CardBody, CardHeader } from "@/components/ui/Card";
import { Topbar } from "@/components/layout/Topbar";
import { getCurrentUser } from "@/lib/auth";

export default async function PanelPage() {
  const user = await getCurrentUser();
  return (
    <>
      <Topbar title="Ana Sayfa" />
      <div className="p-8">
        <Card className="max-w-md">
          <CardHeader>Hoş Geldin</CardHeader>
          <CardBody>
            <p className="text-sm text-text-muted">
              Merhaba <span className="font-semibold text-text">{user?.full_name}</span>,
              Arvend Yapı sistemine hoş geldin.
            </p>
          </CardBody>
        </Card>
      </div>
    </>
  );
}
