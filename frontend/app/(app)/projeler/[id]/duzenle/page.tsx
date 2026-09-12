import { cookies } from "next/headers";

import { Topbar } from "@/components/layout/Topbar";
import { apiServer } from "@/lib/api";
import type { Project } from "@/lib/types";

import { ProjectEditForm } from "./ProjectEditForm";

export default async function ProjeDuzenlePage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const cookieHeader = (await cookies()).toString();
  const project = await apiServer<Project>(`/api/v1/projects/${id}`, cookieHeader);

  return (
    <>
      <Topbar title={`${project.project_no} — Düzenle`} />
      <ProjectEditForm project={project} />
    </>
  );
}
