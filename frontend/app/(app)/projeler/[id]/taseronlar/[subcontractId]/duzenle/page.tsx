import Link from "next/link";
import { cookies } from "next/headers";
import { notFound, redirect } from "next/navigation";

import { PageHeader } from "@/components/layout/PageHeader";
import { buttonClass } from "@/components/ui/styles";
import { apiServer, ApiError } from "@/lib/api";
import { requirePagePermission } from "@/lib/auth";
import { PAGE_PERMISSIONS } from "@/lib/permissions";
import {
  projectIsLocked,
  subcontractHref,
  subcontractPermsFrom,
  type SubcontractDetail,
} from "@/lib/subcontracts";

import { loadPickers, loadProject, NoAccess } from "../../data";
import { SubcontractForm } from "../../SubcontractForm";

export default async function TaseronSozlesmesiDuzenlePage({
  params,
}: {
  params: Promise<{ id: string; subcontractId: string }>;
}) {
  const user = await requirePagePermission(PAGE_PERMISSIONS.projects);
  const { id, subcontractId } = await params;
  if (!subcontractPermsFrom(user.permissions).canManage) redirect(subcontractHref(id, subcontractId));
  const cookieHeader = (await cookies()).toString();
  const project = await loadProject(id, cookieHeader);
  if (project === "forbidden") {
    return (
      <>
        <PageHeader title="Taşeron Sözleşmesini Düzenle" />
        <NoAccess />
      </>
    );
  }
  const detail = await apiServer<SubcontractDetail>(
    `/api/v1/projects/${project.id}/subcontracts/${subcontractId}`,
    cookieHeader
  ).catch((err: unknown) => {
    if (err instanceof ApiError && err.status === 404) notFound();
    return null;
  });
  if (!detail) {
    return (
      <>
        <PageHeader title="Taşeron Sözleşmesini Düzenle" />
        <NoAccess />
      </>
    );
  }

  const sc = detail.subcontract;
  const back = (
    <Link href={subcontractHref(project.id, sc.id)} className={buttonClass("secondary")}>
      Sözleşmeye Dön
    </Link>
  );
  const title = `${sc.subcontract_no} — Düzenle`;

  // Backend yalnızca taslağı düzenler (ErrSubcontractNotEditable); kapalı
  // projede de yazma yok.
  if (sc.status !== "draft" || projectIsLocked(project.status)) {
    return (
      <>
        <PageHeader title={title} action={back} />
        <NoAccess
          message={
            sc.status !== "draft"
              ? "Bu sözleşme yalnızca taslak durumdayken düzenlenebilir. Aktif sözleşmede değişiklik, değişiklik emriyle yapılır."
              : "Proje tamamlandı ya da iptal edildi; sözleşme düzenlenemez."
          }
        />
      </>
    );
  }

  const pickers = await loadPickers(project.id, cookieHeader);
  return (
    <>
      <PageHeader title={title} action={back} />
      <SubcontractForm project={project} subcontract={sc} items={detail.items} {...pickers} />
    </>
  );
}
