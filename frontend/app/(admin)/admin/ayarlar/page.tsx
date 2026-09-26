import { cookies } from "next/headers";

import { PageHeader } from "@/components/layout/PageHeader";
import { apiServer } from "@/lib/api";
import { requirePagePermission } from "@/lib/auth";
import { PAGE_PERMISSIONS } from "@/lib/permissions";
import type { SmtpSettings } from "@/lib/types";

import { SmtpSettingsForm } from "./SmtpSettingsForm";

export default async function AyarlarPage() {
  await requirePagePermission(PAGE_PERMISSIONS.smtpSettings);
  const cookieHeader = (await cookies()).toString();
  const settings = await apiServer<SmtpSettings>("/api/v1/settings/smtp", cookieHeader);

  return (
    <>
      <PageHeader title="Ayarlar" />
      <div className="flex max-w-md flex-col gap-6 p-8">
        <SmtpSettingsForm settings={settings} />
      </div>
    </>
  );
}
