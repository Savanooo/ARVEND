import { redirect } from "next/navigation";
import { cookies } from "next/headers";

import { PageHeader } from "@/components/layout/PageHeader";
import { apiServer, ApiError } from "@/lib/api";
import type { Offer, Project } from "@/lib/types";

import { ConvertForm } from "./ConvertForm";

export default async function ProjeyeDonusturPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const cookieHeader = (await cookies()).toString();
  const offer = await apiServer<Offer>(`/api/v1/offers/${id}`, cookieHeader);

  // Yalnızca kabul edilmiş teklif dönüştürülebilir -- backend zaten bunu
  // zorunlu kılıyor (409), burada gereksiz bir form gösterimini önlemek
  // için erken yönlendirme.
  if (offer.status !== "kabul edildi") {
    redirect(`/teklifler/${id}`);
  }

  // Zaten dönüştürülmüşse doğrudan projeye götür (ikinci proje oluşmaz).
  try {
    const existing = await apiServer<Project>(`/api/v1/offers/${id}/project`, cookieHeader);
    redirect(`/projeler/${existing.id}`);
  } catch (err) {
    // 404 = henüz dönüştürülmemiş, formu göster. redirect() içeride bir
    // hata fırlatarak çalıştığı için onu yeniden fırlatmalıyız.
    if (!(err instanceof ApiError)) throw err;
  }

  return (
    <>
      <PageHeader title={`${offer.offer_no} — Projeye Dönüştür`} />
      <ConvertForm offer={offer} />
    </>
  );
}
