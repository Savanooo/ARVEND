import { cookies } from "next/headers";

import { Topbar } from "@/components/layout/Topbar";
import { apiServer } from "@/lib/api";
import type { SmtpSettings } from "@/lib/types";

import { SmtpSettingsForm } from "./SmtpSettingsForm";

export default async function AyarlarPage() {
  const cookieHeader = (await cookies()).toString();
  const settings = await apiServer<SmtpSettings>("/api/v1/settings/smtp", cookieHeader);

  return (
    <>
      <Topbar title="Ayarlar" />
      <div className="flex max-w-md flex-col gap-6 p-8">
        <SmtpSettingsForm settings={settings} />
      </div>
    </>
  );
}
