package repository

import (
	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

func ToDomainPermission(p sqlc.Permission) domain.Permission {
	return domain.Permission{Code: p.Code, Description: p.Description, Category: p.Category}
}

func ToDomainOrganizationRole(r sqlc.OrganizationRole) domain.OrganizationRole {
	return domain.OrganizationRole{
		ID: r.ID.String(), OrganizationID: r.OrganizationID.String(),
		Code: r.Code, Name: r.Name, Description: r.Description, IsSystem: r.IsSystem,
		CreatedAt: r.CreatedAt.Time, UpdatedAt: r.UpdatedAt.Time,
	}
}

func ToDomainProjectUser(pu sqlc.ProjectUser) domain.ProjectUser {
	return domain.ProjectUser{
		ID: pu.ID.String(), OrganizationID: pu.OrganizationID.String(),
		ProjectID: pu.ProjectID.String(), UserID: pu.UserID.String(),
		ProjectRole: pu.ProjectRole, CreatedAt: pu.CreatedAt.Time,
	}
}

func ToDomainProjectUserDetailed(row sqlc.ListProjectUsersDetailedRow) domain.ProjectUser {
	return domain.ProjectUser{
		ID: row.ID.String(), OrganizationID: row.OrganizationID.String(),
		ProjectID: row.ProjectID.String(), UserID: row.UserID.String(),
		ProjectRole: row.ProjectRole, CreatedAt: row.CreatedAt.Time,
		Username: row.Username, FullName: row.FullName, UserIsActive: row.UserIsActive,
		OrganizationRole:     stringOrEmpty(row.OrganizationRoleCode),
		OrganizationRoleName: stringOrEmpty(row.OrganizationRoleName),
	}
}

func stringOrEmpty(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}
