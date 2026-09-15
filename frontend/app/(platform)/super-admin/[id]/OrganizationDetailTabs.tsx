"use client";

import { ControlledTabPanel, ControlledTabs } from "@/components/ui/Tabs";
import type { AuditEvent, Organization, Plan, User } from "@/lib/types";

import { AuditTab } from "./AuditTab";
import { GeneralTab } from "./GeneralTab";
import { UsersTab } from "./UsersTab";

export function OrganizationDetailTabs({
  organization,
  plans,
  users,
  auditEvents,
}: {
  organization: Organization;
  plans: Plan[];
  users: User[];
  auditEvents: AuditEvent[];
}) {
  return (
    <ControlledTabs
      defaultTab="general"
      items={[
        { key: "general", label: "Genel" },
        { key: "users", label: "Kullanıcılar" },
        { key: "audit", label: "Audit" },
      ]}
    >
      <ControlledTabPanel tab="general">
        <GeneralTab organization={organization} plans={plans} />
      </ControlledTabPanel>
      <ControlledTabPanel tab="users">
        <UsersTab users={users} />
      </ControlledTabPanel>
      <ControlledTabPanel tab="audit">
        <AuditTab events={auditEvents} />
      </ControlledTabPanel>
    </ControlledTabs>
  );
}
