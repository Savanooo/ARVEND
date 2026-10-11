import { redirect } from "next/navigation";

import { webHrefForActionTarget } from "@/lib/dashboard";
import { subcontractHref } from "@/lib/subcontracts";

// Mobilin hakediş / değişiklik emri alt yolları (.../hakedisler/{id},
// .../degisiklik-emirleri/{id}[/duzenle], .../hakedisler/yeni) web'de
// ayrı sayfa değildir: sözleşme detayına, ilgili kayıt açık yönlendirilir
// (bildirim eşlemesiyle aynı kural, lib/dashboard.ts).
export default async function TaseronAltYolPage({
  params,
}: {
  params: Promise<{ id: string; subcontractId: string; rest: string[] }>;
}) {
  const { id, subcontractId, rest } = await params;
  const path = ["", "projeler", id, "taseronlar", subcontractId, ...rest].join("/");
  redirect(webHrefForActionTarget(path) ?? subcontractHref(id, subcontractId));
}
