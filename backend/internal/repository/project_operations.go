package repository

import (
	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

func ToDomainProjectMember(m sqlc.ProjectMember) domain.ProjectMember {
	dm := domain.ProjectMember{
		ID:             m.ID.String(),
		OrganizationID: m.OrganizationID.String(),
		ProjectID:      m.ProjectID.String(),
		EmployeeID:     m.EmployeeID.String(),
		EmployeeName:   m.EmployeeName,
		RoleTitle:      m.RoleTitle,
		Notes:          m.Notes,
		CreatedAt:      m.CreatedAt.Time,
	}
	if m.StartDate.Valid {
		t := m.StartDate.Time
		dm.StartDate = &t
	}
	if m.EndDate.Valid {
		t := m.EndDate.Time
		dm.EndDate = &t
	}
	return dm
}

func ToDomainScheduleItemRow(s sqlc.ProjectScheduleItem) domain.ScheduleItem {
	ds := domain.ScheduleItem{
		ID:             s.ID.String(),
		OrganizationID: s.OrganizationID.String(),
		ProjectID:      s.ProjectID.String(),
		Name:           s.Name,
		Description:    s.Description,
		Status:         s.Status,
		SortOrder:      int(s.SortOrder),
		CreatedAt:      s.CreatedAt.Time,
		AssignedName:   s.AssignedName,
	}
	if s.AssignedEmployeeID.Valid {
		id := s.AssignedEmployeeID.String()
		ds.AssignedEmployeeID = &id
	}
	if s.StartDate.Valid {
		t := s.StartDate.Time
		ds.StartDate = &t
	}
	if s.EndDate.Valid {
		t := s.EndDate.Time
		ds.EndDate = &t
	}
	return ds
}

func ToDomainScheduleItem(r sqlc.ListScheduleItemsRow) domain.ScheduleItem {
	ds := ToDomainScheduleItemRow(sqlc.ProjectScheduleItem{
		ID: r.ID, OrganizationID: r.OrganizationID, ProjectID: r.ProjectID,
		Name: r.Name, Description: r.Description, StartDate: r.StartDate, EndDate: r.EndDate,
		Status: r.Status, SortOrder: r.SortOrder, CreatedBy: r.CreatedBy,
		CreatedAt: r.CreatedAt, UpdatedAt: r.UpdatedAt,
		AssignedEmployeeID: r.AssignedEmployeeID, AssignedName: r.AssignedName,
	})
	ds.TaskCount = r.TaskCount
	ds.CompletedTaskCount = r.CompletedTaskCount
	return ds
}

func ToDomainTask(t sqlc.ProjectTask) domain.ProjectTask {
	dt := domain.ProjectTask{
		ID:             t.ID.String(),
		OrganizationID: t.OrganizationID.String(),
		ProjectID:      t.ProjectID.String(),
		Title:          t.Title,
		Description:    t.Description,
		AssignedName:   t.AssignedName,
		Priority:       t.Priority,
		Status:         t.Status,
		CreatedAt:      t.CreatedAt.Time,
	}
	if t.ScheduleItemID.Valid {
		s := t.ScheduleItemID.String()
		dt.ScheduleItemID = &s
	}
	if t.AssignedEmployeeID.Valid {
		s := t.AssignedEmployeeID.String()
		dt.AssignedEmployeeID = &s
	}
	if t.DueDate.Valid {
		d := t.DueDate.Time
		dt.DueDate = &d
	}
	if t.CompletedAt.Valid {
		d := t.CompletedAt.Time
		dt.CompletedAt = &d
	}
	return dt
}

func ToDomainProjectFile(f sqlc.ProjectFile) domain.ProjectFile {
	df := domain.ProjectFile{
		ID:             f.ID.String(),
		OrganizationID: f.OrganizationID.String(),
		ProjectID:      f.ProjectID.String(),
		OriginalName:   f.OriginalName,
		ObjectKey:      f.ObjectKey,
		MIMEType:       f.MimeType,
		SizeBytes:      f.SizeBytes,
		SHA256:         f.Sha256,
		Category:       f.Category,
		Description:    f.Description,
		CreatedAt:      f.CreatedAt.Time,
	}
	if f.UploadedBy.Valid {
		s := f.UploadedBy.String()
		df.UploadedBy = &s
	}
	return df
}

func ToDomainProjectPhoto(p sqlc.ProjectPhoto) domain.ProjectPhoto {
	dp := domain.ProjectPhoto{
		ID:             p.ID.String(),
		OrganizationID: p.OrganizationID.String(),
		ProjectID:      p.ProjectID.String(),
		OriginalName:   p.OriginalName,
		ObjectKey:      p.ObjectKey,
		MIMEType:       p.MimeType,
		SizeBytes:      p.SizeBytes,
		SHA256:         p.Sha256,
		Stage:          p.Stage,
		Description:    p.Description,
		CreatedAt:      p.CreatedAt.Time,
	}
	if p.TakenAt.Valid {
		t := p.TakenAt.Time
		dp.TakenAt = &t
	}
	if p.UploadedBy.Valid {
		s := p.UploadedBy.String()
		dp.UploadedBy = &s
	}
	return dp
}

func ToDomainProjectNote(n sqlc.ProjectNote) domain.ProjectNote {
	dn := domain.ProjectNote{
		ID:             n.ID.String(),
		OrganizationID: n.OrganizationID.String(),
		ProjectID:      n.ProjectID.String(),
		Content:        n.Content,
		CreatedByName:  n.CreatedByName,
		CreatedAt:      n.CreatedAt.Time,
		UpdatedAt:      n.UpdatedAt.Time,
	}
	if n.CreatedBy.Valid {
		s := n.CreatedBy.String()
		dn.CreatedBy = &s
	}
	return dn
}
