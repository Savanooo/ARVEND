package repository

import (
	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

// ARVEND V2 — Sprint 5: Taşeron Yönetimi. sqlc satırlarından domain
// struct'larına dönüşüm — Sprint 4'ün procurement.go'suyla AYNI desen.

// ---------- Subcontract ----------

func ToDomainSubcontract(sc sqlc.ProjectSubcontract) domain.Subcontract {
	return domain.Subcontract{
		ID: sc.ID.String(), OrganizationID: sc.OrganizationID.String(), ProjectID: sc.ProjectID.String(),
		SubcontractNo: sc.SubcontractNo, SupplierID: sc.SupplierID.String(),
		Title: sc.Title, ScopeSummary: sc.ScopeSummary, OriginalAmount: NumericToFloat64(sc.OriginalAmount),
		Currency: sc.Currency, Status: sc.Status,
		EffectiveDate: nullableDateToPtr(sc.EffectiveDate), StartDate: nullableDateToPtr(sc.StartDate),
		PlannedCompletionDate: nullableDateToPtr(sc.PlannedCompletionDate),
		RetentionPercent:      NumericToFloat64Ptr(sc.RetentionPercent), AdvanceAmount: NumericToFloat64Ptr(sc.AdvanceAmount),
		PaymentTerms: sc.PaymentTerms, Notes: sc.Notes,
		CreatedBy:   nullableUUIDToPtr(sc.CreatedBy),
		ActivatedAt: nullableTimestamptzToPtr(sc.ActivatedAt), ActivatedBy: nullableUUIDToPtr(sc.ActivatedBy),
		CompletedAt: nullableTimestamptzToPtr(sc.CompletedAt), CompletedBy: nullableUUIDToPtr(sc.CompletedBy),
		CancelledAt: nullableTimestamptzToPtr(sc.CancelledAt), CancelledBy: nullableUUIDToPtr(sc.CancelledBy),
		CancelReason: sc.CancelReason,
		TerminatedAt: nullableTimestamptzToPtr(sc.TerminatedAt), TerminatedBy: nullableUUIDToPtr(sc.TerminatedBy),
		TerminationReason: sc.TerminationReason,
		CreatedAt:         sc.CreatedAt.Time, UpdatedAt: sc.UpdatedAt.Time,
	}
}

// SubcontractDetailed, ListSubcontractsDetailedRow/GetSubcontractDetailedRow
// (tedarikçi kimliği JOIN edilmiş) için PurchaseOrderDetailed İLE AYNI desen.
type SubcontractDetailed struct {
	domain.Subcontract
	SupplierCode string
	SupplierName string
}

func ToDomainSubcontractDetailedFromList(sc sqlc.ListSubcontractsDetailedRow) SubcontractDetailed {
	base := ToDomainSubcontract(sqlc.ProjectSubcontract{
		ID: sc.ID, OrganizationID: sc.OrganizationID, ProjectID: sc.ProjectID, SubcontractNo: sc.SubcontractNo,
		SupplierID: sc.SupplierID, Title: sc.Title, ScopeSummary: sc.ScopeSummary, OriginalAmount: sc.OriginalAmount,
		Currency: sc.Currency, Status: sc.Status, EffectiveDate: sc.EffectiveDate, StartDate: sc.StartDate,
		PlannedCompletionDate: sc.PlannedCompletionDate, RetentionPercent: sc.RetentionPercent, AdvanceAmount: sc.AdvanceAmount,
		PaymentTerms: sc.PaymentTerms, Notes: sc.Notes, CreatedBy: sc.CreatedBy, CreatedAt: sc.CreatedAt, UpdatedAt: sc.UpdatedAt,
		ActivatedAt: sc.ActivatedAt, ActivatedBy: sc.ActivatedBy, CompletedAt: sc.CompletedAt, CompletedBy: sc.CompletedBy,
		CancelledAt: sc.CancelledAt, CancelledBy: sc.CancelledBy, CancelReason: sc.CancelReason,
		TerminatedAt: sc.TerminatedAt, TerminatedBy: sc.TerminatedBy, TerminationReason: sc.TerminationReason,
	})
	return SubcontractDetailed{Subcontract: base, SupplierCode: sc.SupplierCode, SupplierName: sc.SupplierLegalName}
}

func ToDomainSubcontractDetailedFromGet(sc sqlc.GetSubcontractDetailedRow) SubcontractDetailed {
	base := ToDomainSubcontract(sqlc.ProjectSubcontract{
		ID: sc.ID, OrganizationID: sc.OrganizationID, ProjectID: sc.ProjectID, SubcontractNo: sc.SubcontractNo,
		SupplierID: sc.SupplierID, Title: sc.Title, ScopeSummary: sc.ScopeSummary, OriginalAmount: sc.OriginalAmount,
		Currency: sc.Currency, Status: sc.Status, EffectiveDate: sc.EffectiveDate, StartDate: sc.StartDate,
		PlannedCompletionDate: sc.PlannedCompletionDate, RetentionPercent: sc.RetentionPercent, AdvanceAmount: sc.AdvanceAmount,
		PaymentTerms: sc.PaymentTerms, Notes: sc.Notes, CreatedBy: sc.CreatedBy, CreatedAt: sc.CreatedAt, UpdatedAt: sc.UpdatedAt,
		ActivatedAt: sc.ActivatedAt, ActivatedBy: sc.ActivatedBy, CompletedAt: sc.CompletedAt, CompletedBy: sc.CompletedBy,
		CancelledAt: sc.CancelledAt, CancelledBy: sc.CancelledBy, CancelReason: sc.CancelReason,
		TerminatedAt: sc.TerminatedAt, TerminatedBy: sc.TerminatedBy, TerminationReason: sc.TerminationReason,
	})
	return SubcontractDetailed{Subcontract: base, SupplierCode: sc.SupplierCode, SupplierName: sc.SupplierLegalName}
}

// SubcontractValue, GetSubcontractCurrentValueRow'un domain karşılığıdır --
// current_subcontract_value = original + onaylı ekler - onaylı eksiltmeler
// (bkz. docs/subcontracts.md, projects.ChangeOrderNet İLE AYNI ilke).
type SubcontractValue struct {
	OriginalAmount     float64
	ApprovedAdditions  float64
	ApprovedDeductions float64
	PendingAdditions   float64
	PendingDeductions  float64
	CurrentValue       float64
}

func ToDomainSubcontractValue(r sqlc.GetSubcontractCurrentValueRow) SubcontractValue {
	return SubcontractValue{
		OriginalAmount: NumericToFloat64(r.OriginalAmount), ApprovedAdditions: NumericToFloat64(r.ApprovedAdditions),
		ApprovedDeductions: NumericToFloat64(r.ApprovedDeductions), PendingAdditions: NumericToFloat64(r.PendingAdditions),
		PendingDeductions: NumericToFloat64(r.PendingDeductions), CurrentValue: NumericToFloat64(r.CurrentValue),
	}
}

func ToDomainSubcontractItem(i sqlc.SubcontractItem) domain.SubcontractItem {
	return domain.SubcontractItem{
		ID: i.ID.String(), OrganizationID: i.OrganizationID.String(), ProjectID: i.ProjectID.String(),
		SubcontractID: i.SubcontractID.String(), WBSNodeID: nullableUUIDToPtr(i.WbsNodeID), CostCodeID: i.CostCodeID.String(),
		BudgetLineID: nullableUUIDToPtr(i.BudgetLineID), Description: i.Description,
		Quantity: NumericToFloat64Ptr(i.Quantity), Unit: i.Unit, UnitPrice: NumericToFloat64Ptr(i.UnitPrice),
		OriginalAmount: NumericToFloat64(i.OriginalAmount), SortOrder: int(i.SortOrder),
	}
}

// ---------- Subcontract Change Order ----------

func ToDomainSubcontractChangeOrder(co sqlc.SubcontractChangeOrder) domain.SubcontractChangeOrder {
	return domain.SubcontractChangeOrder{
		ID: co.ID.String(), OrganizationID: co.OrganizationID.String(), ProjectID: co.ProjectID.String(),
		SubcontractID: co.SubcontractID.String(), Number: co.Number,
		Title: co.Title, Description: co.Description, ChangeType: co.ChangeType, Amount: NumericToFloat64(co.Amount),
		Status: co.Status, Reason: co.Reason,
		RequestedAt: nullableTimestamptzToPtr(co.RequestedAt),
		ApprovedAt:  nullableTimestamptzToPtr(co.ApprovedAt), ApprovedBy: nullableUUIDToPtr(co.ApprovedBy),
		RejectedAt: nullableTimestamptzToPtr(co.RejectedAt), RejectedBy: nullableUUIDToPtr(co.RejectedBy),
		RejectionReason: co.RejectionReason,
		CancelledAt:     nullableTimestamptzToPtr(co.CancelledAt), CancelledBy: nullableUUIDToPtr(co.CancelledBy),
		CreatedBy: nullableUUIDToPtr(co.CreatedBy), CreatedAt: co.CreatedAt.Time, UpdatedAt: co.UpdatedAt.Time,
	}
}

func ToDomainSubcontractChangeOrderItem(i sqlc.SubcontractChangeOrderItem) domain.SubcontractChangeOrderItem {
	return domain.SubcontractChangeOrderItem{
		ID: i.ID.String(), OrganizationID: i.OrganizationID.String(), ProjectID: i.ProjectID.String(),
		ChangeOrderID: i.ChangeOrderID.String(), WBSNodeID: nullableUUIDToPtr(i.WbsNodeID), CostCodeID: i.CostCodeID.String(),
		BudgetLineID: nullableUUIDToPtr(i.BudgetLineID), Description: i.Description,
		Amount: NumericToFloat64(i.Amount), SortOrder: int(i.SortOrder),
	}
}

// ---------- Subcontract Progress Claim (Hakediş) ----------

func ToDomainProgressClaim(pc sqlc.SubcontractProgressClaim) domain.SubcontractProgressClaim {
	return domain.SubcontractProgressClaim{
		ID: pc.ID.String(), OrganizationID: pc.OrganizationID.String(), ProjectID: pc.ProjectID.String(),
		SubcontractID: pc.SubcontractID.String(), ClaimNumber: pc.ClaimNumber,
		PeriodStart: nullableDateToPtr(pc.PeriodStart), PeriodEnd: pc.PeriodEnd.Time, Status: pc.Status,
		GrossWorkAmount: NumericToFloat64(pc.GrossWorkAmount), RetentionPercentSnapshot: NumericToFloat64(pc.RetentionPercentSnapshot),
		RetentionAmount: NumericToFloat64(pc.RetentionAmount), AdvanceRecoveryAmount: NumericToFloat64(pc.AdvanceRecoveryAmount),
		OtherDeductions: NumericToFloat64(pc.OtherDeductions), PreviousCertifiedAmount: NumericToFloat64(pc.PreviousCertifiedAmount),
		CurrentCertifiedAmount: NumericToFloat64(pc.CurrentCertifiedAmount), NetPayable: NumericToFloat64(pc.NetPayable),
		SubmittedAt: nullableTimestamptzToPtr(pc.SubmittedAt),
		CertifiedAt: nullableTimestamptzToPtr(pc.CertifiedAt), CertifiedBy: nullableUUIDToPtr(pc.CertifiedBy),
		RejectedAt: nullableTimestamptzToPtr(pc.RejectedAt), RejectedBy: nullableUUIDToPtr(pc.RejectedBy),
		RejectionReason: pc.RejectionReason,
		CancelledAt:     nullableTimestamptzToPtr(pc.CancelledAt), CancelledBy: nullableUUIDToPtr(pc.CancelledBy),
		Notes: pc.Notes, CreatedBy: nullableUUIDToPtr(pc.CreatedBy), CreatedAt: pc.CreatedAt.Time, UpdatedAt: pc.UpdatedAt.Time,
	}
}

func ToDomainProgressClaimItemDetailed(i sqlc.ListSubcontractProgressClaimItemsDetailedRow) domain.SubcontractProgressClaimItem {
	return domain.SubcontractProgressClaimItem{
		ID: i.ID.String(), OrganizationID: i.OrganizationID.String(), ProjectID: i.ProjectID.String(),
		ProgressClaimID: i.ProgressClaimID.String(), SubcontractItemID: i.SubcontractItemID.String(),
		ScheduledValue: NumericToFloat64(i.ScheduledValue), PreviousProgressAmount: NumericToFloat64(i.PreviousProgressAmount),
		CurrentProgressAmount: NumericToFloat64(i.CurrentProgressAmount), CumulativeProgressAmount: NumericToFloat64(i.CumulativeProgressAmount),
		SortOrder: int(i.SortOrder), ItemDescription: i.ItemDescription, ItemUnit: i.ItemUnit,
	}
}

// ---------- Subcontract Payment (Gerçek Ödeme) ----------

func ToDomainSubcontractPayment(p sqlc.SubcontractPayment) domain.SubcontractPayment {
	return domain.SubcontractPayment{
		ID: p.ID.String(), OrganizationID: p.OrganizationID.String(), ProjectID: p.ProjectID.String(),
		SubcontractID: p.SubcontractID.String(), ProgressClaimID: nullableUUIDToPtr(p.ProgressClaimID),
		Amount: NumericToFloat64(p.Amount), Currency: p.Currency, PaidDate: p.PaidDate.Time,
		PaymentMethod: p.PaymentMethod, ReferenceNo: p.ReferenceNo, Description: p.Description,
		CreatedBy: nullableUUIDToPtr(p.CreatedBy), CreatedAt: p.CreatedAt.Time,
		VoidedAt: nullableTimestamptzToPtr(p.VoidedAt), VoidedBy: nullableUUIDToPtr(p.VoidedBy),
		VoidReason: p.VoidReason,
	}
}

// CostCodeTarget, syncSubcontractCommitments'ın maliyet-kodu bazında
// NETLENMİŞ hedef satırıdır (bkz. docs/subcontracts.md §Commitment
// Entegrasyonu) -- ListSubcontractItemTotalsByCostCode/
// ListApprovedSubcontractChangeItemTotalsByCostCode/
// GetSubcontractTerminationTargets'ın ORTAK domain karşılığı.
type CostCodeTarget struct {
	CostCodeID   string
	BudgetLineID *string
	Amount       float64
}
