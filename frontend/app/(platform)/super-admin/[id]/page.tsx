import { cookies } from "next/headers";

import { PageHeader } from "@/components/layout/PageHeader";
import { StatusBadge } from "@/components/ui/StatusBadge";
import { apiServer } from "@/lib/api";
import { ORG_STATUS } from "@/lib/status";
import type { AuditEvent, Organization, OrganizationRole, Plan, User } from "@/lib/types";

import { OrganizationDetailTabs } from "./OrganizationDetailTabs";

export default async function FirmaDetailPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const cookieHeader = (await cookies()).toString();
  const base = `/api/v1/platform/organizations/${id}`;

  const [organization, plans, usersResult, roles, auditResult] = await Promise.all([
    apiServer<Organization>(base, cookieHeader),
    apiServer<{ plans: Plan[] }>("/api/v1/platform/plans", cookieHeader).then((r) => r.plans),
    apiServer<{ users: User[]; total: number }>(`${base}/users?limit=200`, cookieHeader),
    apiServer<{ roles: OrganizationRole[] }>(`${base}/roles`, cookieHeader).then((r) => r.roles),
    apiServer<{ events: AuditEvent[] }>(`${base}/audit-events?limit=100`, cookieHeader).then((r) => r.events),
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
      <div className="max-w-4xl p-8">
        <OrganizationDetailTabs
          organization={organization}
          plans={plans}
          users={usersResult.users}
          usersTotal={usersResult.total}
          activeOwnerCount={organization.active_owner_count ?? 0}
          roles={roles}
          auditEvents={auditResult}
        />
      </div>
    </>
  );
}
