package repository

import (
	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

// ToDomainProjectContract, ToDomainOfferBase/ToDomainProjectBudget İLE
// AYNI nullable-alan dönüşüm desenini izler (bkz. pool.go/authorization.go).
func ToDomainProjectContract(c sqlc.ProjectContract) domain.ProjectContract {
	dc := domain.ProjectContract{
		ID: c.ID.String(), OrganizationID: c.OrganizationID.String(), ProjectID: c.ProjectID.String(),
		Currency: c.Currency, Status: c.Status,
		Scope: c.Scope, PaymentTerms: c.PaymentTerms, RetentionTerms: c.RetentionTerms, AdvanceTerms: c.AdvanceTerms,
		InternalNotes:     c.InternalNotes,
		CreatedBy:         nullableUUIDToPtr(c.CreatedBy),
		CreatedAt:         c.CreatedAt.Time,
		UpdatedAt:         c.UpdatedAt.Time,
		ActivatedBy:       nullableUUIDToPtr(c.ActivatedBy),
		CompletedBy:       nullableUUIDToPtr(c.CompletedBy),
		CancelledBy:       nullableUUIDToPtr(c.CancelledBy),
		CancelReason:      c.CancelReason,
		TerminatedBy:      nullableUUIDToPtr(c.TerminatedBy),
		TerminationReason: c.TerminationReason,
	}
	if c.EffectiveDate.Valid {
		t := c.EffectiveDate.Time
		dc.EffectiveDate = &t
	}
	if c.PlannedCompletionDate.Valid {
		t := c.PlannedCompletionDate.Time
		dc.PlannedCompletionDate = &t
	}
	if c.ActivatedAt.Valid {
		t := c.ActivatedAt.Time
		dc.ActivatedAt = &t
	}
	if c.CompletedAt.Valid {
		t := c.CompletedAt.Time
		dc.CompletedAt = &t
	}
	if c.CancelledAt.Valid {
		t := c.CancelledAt.Time
		dc.CancelledAt = &t
	}
	if c.TerminatedAt.Valid {
		t := c.TerminatedAt.Time
		dc.TerminatedAt = &t
	}
	return dc
}
