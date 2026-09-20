package repository

import (
	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

func ToDomainNotification(n sqlc.Notification) domain.Notification {
	dn := domain.Notification{
		ID:             n.ID.String(),
		OrganizationID: n.OrganizationID.String(),
		UserID:         n.UserID.String(),
		Type:           n.Type,
		Title:          n.Title,
		Body:           n.Body,
		EntityType:     n.EntityType,
		ActionTarget:   n.ActionTarget,
	}
	if n.EntityID.Valid {
		s := n.EntityID.String()
		dn.EntityID = &s
	}
	if n.ProjectID.Valid {
		s := n.ProjectID.String()
		dn.ProjectID = &s
	}
	if n.ReadAt.Valid {
		t := n.ReadAt.Time
		dn.ReadAt = &t
	}
	if n.CreatedAt.Valid {
		dn.CreatedAt = n.CreatedAt.Time
	}
	return dn
}
