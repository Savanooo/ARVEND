"use client";

import { ControlledTabPanel, ControlledTabs } from "@/components/ui/Tabs";
import type { AuditEvent, Organization, OrganizationRole, Plan, User } from "@/lib/types";

import { AuditTab } from "./AuditTab";
import { GeneralTab } from "./GeneralTab";
import { UsersTab } from "./UsersTab";

export function OrganizationDetailTabs({
  organization,
  plans,
  users,
  usersTotal,
  activeOwnerCount,
  roles,
  auditEvents,
}: {
  organization: Organization;
  plans: Plan[];
  users: User[];
  usersTotal: number;
  activeOwnerCount: number;
  roles: OrganizationRole[];
  auditEvents: AuditEvent[];
}) {
  return (
    <ControlledTabs
      defaultTab="general"
      items={[
        { key: "general", label: "Genel" },
        { key: "users", label: "Kullanıcılar" },
        { key: "audit", label: "Denetim Kayıtları" },
      ]}
    >
      <ControlledTabPanel tab="general">
        <GeneralTab organization={organization} plans={plans} userCount={usersTotal} activeOwnerCount={activeOwnerCount} />
      </ControlledTabPanel>
      <ControlledTabPanel tab="users">
        <UsersTab organization={organization} users={users} roles={roles} activeOwnerCount={activeOwnerCount} />
      </ControlledTabPanel>
      <ControlledTabPanel tab="audit">
        <AuditTab events={auditEvents} />
      </ControlledTabPanel>
    </ControlledTabs>
  );
}
