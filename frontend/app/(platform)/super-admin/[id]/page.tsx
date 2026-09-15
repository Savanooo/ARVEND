import { cookies } from "next/headers";

import { PageHeader } from "@/components/layout/PageHeader";
import { StatusBadge } from "@/components/ui/StatusBadge";
import { apiServer } from "@/lib/api";
import { ORG_STATUS } from "@/lib/status";
import type { AuditEvent, Organization, Plan, User } from "@/lib/types";

import { OrganizationDetailTabs } from "./OrganizationDetailTabs";

export default async function FirmaDetailPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const cookieHeader = (await cookies()).toString();

  const [organization, plans, usersResult, auditResult] = await Promise.all([
    apiServer<Organization>(`/api/v1/platform/organizations/${id}`, cookieHeader),
    apiServer<{ plans: Plan[] }>("/api/v1/platform/plans", cookieHeader).then((r) => r.plans),
    apiServer<{ users: User[]; total: number }>(
      `/api/v1/platform/organizations/${id}/users`,
      cookieHeader
    ),
    apiServer<{ events: AuditEvent[] }>(
      `/api/v1/platform/organizations/${id}/audit-events`,
      cookieHeader
    ).then((r) => r.events),
  ]);

  return (
    <>
      <PageHeader
        title={
          <span className="flex items-center gap-3">
            {organization.name}
            <StatusBadge status={organization.status} registry={ORG_STATUS} />
          </span>
        }
      />
      <div className="max-w-3xl p-8">
        <OrganizationDetailTabs
          organization={organization}
          plans={plans}
          users={usersResult.users}
          auditEvents={auditResult}
        />
      </div>
    </>
  );
}
