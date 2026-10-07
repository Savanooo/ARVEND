package repository

import (
	"encoding/json"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

func ToDomainPaymentPlanItem(r sqlc.ListPaymentPlanItemsRow) domain.PaymentPlanItem {
	item := domain.PaymentPlanItem{
		ID:              r.ID.String(),
		OrganizationID:  r.OrganizationID.String(),
		ProjectID:       r.ProjectID.String(),
		SortOrder:       int(r.SortOrder),
		Name:            r.Name,
		PlannedAmount:   NumericToFloat64(r.PlannedAmount),
		Notes:           r.Notes,
		CreatedAt:       r.CreatedAt.Time,
		UpdatedAt:       r.UpdatedAt.Time,
		CollectedAmount: NumericToFloat64(r.CollectedAmount),
		Status:          r.Status,
	}
	if r.Percentage.Valid {
		v := NumericToFloat64(r.Percentage)
		item.Percentage = &v
	}
	if r.DueDate.Valid {
		t := r.DueDate.Time
		item.DueDate = &t
	}
	return item
}

func ToDomainPaymentPlanItemRow(p sqlc.ProjectPaymentPlanItem) domain.PaymentPlanItem {
	item := domain.PaymentPlanItem{
		ID:             p.ID.String(),
		OrganizationID: p.OrganizationID.String(),
		ProjectID:      p.ProjectID.String(),
		SortOrder:      int(p.SortOrder),
		Name:           p.Name,
		PlannedAmount:  NumericToFloat64(p.PlannedAmount),
		Notes:          p.Notes,
		CreatedAt:      p.CreatedAt.Time,
		UpdatedAt:      p.UpdatedAt.Time,
		Status:         p.Status,
	}
	if p.Percentage.Valid {
		v := NumericToFloat64(p.Percentage)
		item.Percentage = &v
	}
	if p.DueDate.Valid {
		t := p.DueDate.Time
		item.DueDate = &t
	}
	return item
}

func ToDomainCollection(c sqlc.ProjectCollection) domain.Collection {
	col := domain.Collection{
		ID:             c.ID.String(),
		OrganizationID: c.OrganizationID.String(),
		ProjectID:      c.ProjectID.String(),
		Amount:         NumericToFloat64(c.Amount),
		Currency:       c.Currency,
		ReceivedDate:   c.ReceivedDate.Time,
		PaymentMethod:  c.PaymentMethod,
		Description:    c.Description,
		ReferenceNo:    c.ReferenceNo,
		VoidReason:     c.VoidReason,
		CreatedAt:      c.CreatedAt.Time,
	}
	if c.PaymentPlanItemID.Valid {
		s := c.PaymentPlanItemID.String()
		col.PaymentPlanItemID = &s
	}
	if c.InvoiceID.Valid {
		s := c.InvoiceID.String()
		col.InvoiceID = &s
	}
	if c.CreatedBy.Valid {
		s := c.CreatedBy.String()
		col.CreatedBy = &s
	}
	if c.VoidedAt.Valid {
		t := c.VoidedAt.Time
		col.VoidedAt = &t
	}
	if c.VoidedBy.Valid {
		s := c.VoidedBy.String()
		col.VoidedBy = &s
	}
	return col
}

func ToDomainExpense(e sqlc.ProjectExpense) domain.Expense {
	exp := domain.Expense{
		ID:             e.ID.String(),
		OrganizationID: e.OrganizationID.String(),
		ProjectID:      e.ProjectID.String(),
		Category:       e.Category,
		Description:    e.Description,
		Amount:         NumericToFloat64(e.Amount),
		Currency:       e.Currency,
		ExpenseDate:    e.ExpenseDate.Time,
		SupplierName:   e.SupplierName,
		InvoiceNo:      e.InvoiceNo,
		Notes:          e.Notes,
		VoidReason:     e.VoidReason,
		CreatedAt:      e.CreatedAt.Time,
	}
	if e.CreatedBy.Valid {
		s := e.CreatedBy.String()
		exp.CreatedBy = &s
	}
	if e.VoidedAt.Valid {
		t := e.VoidedAt.Time
		exp.VoidedAt = &t
	}
	if e.VoidedBy.Valid {
		s := e.VoidedBy.String()
		exp.VoidedBy = &s
	}
	if e.ChangeOrderID.Valid {
		s := e.ChangeOrderID.String()
		exp.ChangeOrderID = &s
	}
	if e.CostCodeID.Valid {
		s := e.CostCodeID.String()
		exp.CostCodeID = &s
	}
	if e.BudgetLineID.Valid {
		s := e.BudgetLineID.String()
		exp.BudgetLineID = &s
	}
	return exp
}

func ToDomainProjectInvoice(i sqlc.ProjectInvoice) domain.ProjectInvoice {
	inv := domain.ProjectInvoice{
		ID:             i.ID.String(),
		OrganizationID: i.OrganizationID.String(),
		ProjectID:      i.ProjectID.String(),
		InvoiceNo:      i.InvoiceNo,
		InvoiceType:    i.InvoiceType,
		InvoiceDate:    i.InvoiceDate.Time,
		Amount:         NumericToFloat64(i.Amount),
		Currency:       i.Currency,
		Status:         i.Status,
		CustomerName:   i.CustomerName,
		Notes:          i.Notes,
		CreatedAt:      i.CreatedAt.Time,
	}
	if i.DueDate.Valid {
		t := i.DueDate.Time
		inv.DueDate = &t
	}
	if i.CreatedBy.Valid {
		s := i.CreatedBy.String()
		inv.CreatedBy = &s
	}
	return inv
}

func ToDomainSubcontractor(r sqlc.ListSubcontractorsRow) domain.Subcontractor {
	paid := NumericToFloat64(r.PaidAmount)
	contract := NumericToFloat64(r.ContractAmount)
	remaining := contract - paid
	if remaining < 0 {
		remaining = 0
	}
	sub := domain.Subcontractor{
		ID:              r.ID.String(),
		OrganizationID:  r.OrganizationID.String(),
		ProjectID:       r.ProjectID.String(),
		Name:            r.Name,
		CompanyName:     r.CompanyName,
		Phone:           r.Phone,
		Email:           r.Email,
		WorkDescription: r.WorkDescription,
		ContractAmount:  contract,
		Currency:        r.Currency,
		Status:          r.Status,
		Notes:           r.Notes,
		CreatedAt:       r.CreatedAt.Time,
		PaidAmount:      paid,
		RemainingAmount: remaining,
		ProfitPercent:   NumericToFloat64Ptr(r.ProfitPercent),
	}
	if r.StartDate.Valid {
		t := r.StartDate.Time
		sub.StartDate = &t
	}
	if r.EndDate.Valid {
		t := r.EndDate.Time
		sub.EndDate = &t
	}
	if r.ChangeOrderID.Valid {
		s := r.ChangeOrderID.String()
		sub.ChangeOrderID = &s
	}
	if r.CostCodeID.Valid {
		s := r.CostCodeID.String()
		sub.CostCodeID = &s
	}
	return sub
}

func ToDomainSubcontractorRow(s sqlc.ProjectSubcontractor) domain.Subcontractor {
	sub := domain.Subcontractor{
		ID:              s.ID.String(),
		OrganizationID:  s.OrganizationID.String(),
		ProjectID:       s.ProjectID.String(),
		Name:            s.Name,
		CompanyName:     s.CompanyName,
		Phone:           s.Phone,
		Email:           s.Email,
		WorkDescription: s.WorkDescription,
		ContractAmount:  NumericToFloat64(s.ContractAmount),
		Currency:        s.Currency,
		Status:          s.Status,
		Notes:           s.Notes,
		CreatedAt:       s.CreatedAt.Time,
		ProfitPercent:   NumericToFloat64Ptr(s.ProfitPercent),
	}
	if s.StartDate.Valid {
		t := s.StartDate.Time
		sub.StartDate = &t
	}
	if s.EndDate.Valid {
		t := s.EndDate.Time
		sub.EndDate = &t
	}
	if s.ChangeOrderID.Valid {
		v := s.ChangeOrderID.String()
		sub.ChangeOrderID = &v
	}
	if s.CostCodeID.Valid {
		v := s.CostCodeID.String()
		sub.CostCodeID = &v
	}
	return sub
}

func ToDomainSubcontractorPayment(p sqlc.ProjectSubcontractorPayment) domain.SubcontractorPayment {
	pay := domain.SubcontractorPayment{
		ID:              p.ID.String(),
		OrganizationID:  p.OrganizationID.String(),
		ProjectID:       p.ProjectID.String(),
		SubcontractorID: p.SubcontractorID.String(),
		Amount:          NumericToFloat64(p.Amount),
		Currency:        p.Currency,
		PaidDate:        p.PaidDate.Time,
		Description:     p.Description,
		VoidReason:      p.VoidReason,
		CreatedAt:       p.CreatedAt.Time,
	}
	if p.CreatedBy.Valid {
		s := p.CreatedBy.String()
		pay.CreatedBy = &s
	}
	if p.VoidedAt.Valid {
		t := p.VoidedAt.Time
		pay.VoidedAt = &t
	}
	if p.VoidedBy.Valid {
		s := p.VoidedBy.String()
		pay.VoidedBy = &s
	}
	return pay
}

func ToDomainFinancialSummary(r sqlc.GetProjectFinancialSummaryRow) domain.ProjectFinancialSummary {
	return domain.ProjectFinancialSummary{
		BaseContractAmount:           NumericToFloat64(r.BaseContractAmount),
		ContractAmount:               NumericToFloat64(r.ContractAmount),
		Currency:                     r.Currency,
		ApprovedAdditions:            NumericToFloat64(r.ApprovedAdditions),
		ApprovedDeductions:           NumericToFloat64(r.ApprovedDeductions),
		CurrentContractValue:         NumericToFloat64(r.CurrentContractValue),
		PendingAdditions:             NumericToFloat64(r.PendingAdditions),
		PendingDeductions:            NumericToFloat64(r.PendingDeductions),
		PotentialContractValue:       NumericToFloat64(r.PotentialContractValue),
		PlannedCollections:           NumericToFloat64(r.PlannedCollections),
		CollectedAmount:              NumericToFloat64(r.CollectedAmount),
		RemainingReceivable:          NumericToFloat64(r.RemainingReceivable),
		TotalExpenses:                NumericToFloat64(r.TotalExpenses),
		TotalSubcontractorCommitment: NumericToFloat64(r.TotalSubcontractorCommitment),
		SubcontractorPaid:            NumericToFloat64(r.SubcontractorPaid),
		SubcontractorRemaining:       NumericToFloat64(r.SubcontractorRemaining),
		NewSubcontractPaid:           NumericToFloat64(r.NewSubcontractPaid),
		NewSubcontractRemaining:      NumericToFloat64(r.NewSubcontractRemaining),
		IssuedInvoiceTotal:           NumericToFloat64(r.IssuedInvoiceTotal),
		PaidInvoiceTotal:             NumericToFloat64(r.PaidInvoiceTotal),
		RealizedCost:                 NumericToFloat64(r.RealizedCost),
		CommittedCost:                NumericToFloat64(r.CommittedCost),
		RealizedGrossProfit:          NumericToFloat64(r.RealizedGrossProfit),
		EstimatedGrossProfit:         NumericToFloat64(r.EstimatedGrossProfit),
		RealizedMarginPercent:        NumericToFloat64(r.RealizedMarginPercent),
		EstimatedMarginPercent:       NumericToFloat64(r.EstimatedMarginPercent),
		ContractVATAmount:            NumericToFloat64(r.ContractVatAmount),
		ContractVATKnown:             r.ContractVatKnown,
	}
}

func ToDomainProjectEvent(e sqlc.ProjectEvent) domain.ProjectEvent {
	de := domain.ProjectEvent{
		ID:             e.ID.String(),
		OrganizationID: e.OrganizationID.String(),
		ProjectID:      e.ProjectID.String(),
		EventType:      e.EventType,
		CreatedAt:      e.CreatedAt.Time,
	}
	if e.UserID.Valid {
		s := e.UserID.String()
		de.UserID = &s
	}
	if len(e.Metadata) > 0 {
		var meta map[string]any
		if err := json.Unmarshal(e.Metadata, &meta); err == nil {
			de.Metadata = meta
		}
	}
	return de
}
