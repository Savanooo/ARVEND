import Link from "next/link";
import { cookies } from "next/headers";
import { redirect } from "next/navigation";

import { PageHeader } from "@/components/layout/PageHeader";
import { buttonClass } from "@/components/ui/styles";
import { requirePagePermission } from "@/lib/auth";
import { PAGE_PERMISSIONS } from "@/lib/permissions";
import { projectIsLocked, subcontractPermsFrom, subcontractsTabHref } from "@/lib/subcontracts";

import { loadPickers, loadProject, NoAccess } from "../data";
import { SubcontractForm } from "../SubcontractForm";

export default async function YeniTaseronSozlesmesiPage({ params }: { params: Promise<{ id: string }> }) {
  const user = await requirePagePermission(PAGE_PERMISSIONS.projects);
  const { id } = await params;
  // Oluşturma projects.subcontracts.manage ister (router.go); izni olmayan
  // sekmeye döner (düğme zaten gizli).
  if (!subcontractPermsFrom(user.permissions).canManage) redirect(subcontractsTabHref(id));
  const cookieHeader = (await cookies()).toString();
  const project = await loadProject(id, cookieHeader);
  if (project === "forbidden") {
    return (
      <>
        <PageHeader title="Yeni Taşeron Sözleşmesi" />
        <NoAccess />
      </>
    );
  }

  const back = (
    <Link href={subcontractsTabHref(project.id)} className={buttonClass("secondary")}>
      Taşeronlara Dön
    </Link>
  );

  if (projectIsLocked(project.status)) {
    return (
      <>
        <PageHeader title={`${project.project_no} — Yeni Taşeron Sözleşmesi`} action={back} />
        <NoAccess message="Proje tamamlandı ya da iptal edildi; yeni taşeron sözleşmesi oluşturulamaz." />
      </>
    );
  }

  const pickers = await loadPickers(project.id, cookieHeader);
  return (
    <>
      <PageHeader title={`${project.project_no} — Yeni Taşeron Sözleşmesi`} action={back} />
      <SubcontractForm project={project} {...pickers} />
    </>
  );
}
