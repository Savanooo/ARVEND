import { redirect } from "next/navigation";
import { cookies } from "next/headers";

import { PageHeader } from "@/components/layout/PageHeader";
import { apiServer } from "@/lib/api";
import { requirePagePermission } from "@/lib/auth";
import { hasPermission, PAGE_PERMISSIONS } from "@/lib/permissions";
import { orNotFound } from "@/lib/server-data";
import type { Project } from "@/lib/types";

import { ProjectEditForm } from "./ProjectEditForm";

export default async function ProjeDuzenlePage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const user = await requirePagePermission(PAGE_PERMISSIONS.projects);
  const { id } = await params;
  if (!hasPermission(user.permissions, "projects.update")) redirect(`/projeler/${id}`);
  const cookieHeader = (await cookies()).toString();
  const project = await orNotFound(apiServer<Project>(`/api/v1/projects/${id}`, cookieHeader));

  return (
    <>
      <PageHeader title={`${project.project_no} — Düzenle`} />
      <ProjectEditForm project={project} />
    </>
  );
}
