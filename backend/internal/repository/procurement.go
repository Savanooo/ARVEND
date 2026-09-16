package repository

import (
	"time"

	"github.com/jackc/pgx/v5/pgtype"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

// nullableDateToPtr/nullableTimestamptzToPtr, nullableUUIDToPtr İLE AYNI
// desen -- Sprint 4'ün 10 tablosunda tarih/zaman-damgası alanlarının
// sayısı fazla olduğu için (ProjectContract mapper'ının tekil "if
// x.Valid {...}" deseni burada aşırı tekrara yol açardı) tek yerde
// toplanmıştır.
func nullableDateToPtr(d pgtype.Date) *time.Time {
	if !d.Valid {
		return nil
	}
	t := d.Time
	return &t
}

func nullableTimestamptzToPtr(ts pgtype.Timestamptz) *time.Time {
	if !ts.Valid {
		return nil
	}
	t := ts.Time
	return &t
}

// ---------- Tedarikçi ----------

func ToDomainSupplier(s sqlc.Supplier) domain.Supplier {
	return domain.Supplier{
		ID: s.ID.String(), OrganizationID: s.OrganizationID.String(),
		Code: s.Code, LegalName: s.LegalName, TradeName: s.TradeName,
		TaxNumber: s.TaxNumber, TaxOffice: s.TaxOffice, ContactName: s.ContactName,
		Email: s.Email, Phone: s.Phone, Address: s.Address, City: s.City, Country: s.Country,
		IBANEncSet: s.IbanEnc != "",
		IsActive:   s.IsActive, Notes: s.Notes,
		CreatedAt: s.CreatedAt.Time, UpdatedAt: s.UpdatedAt.Time,
	}
}

// ---------- Purchase Request ----------

func ToDomainPurchaseRequest(p sqlc.PurchaseRequest) domain.PurchaseRequest {
	return domain.PurchaseRequest{
		ID: p.ID.String(), OrganizationID: p.OrganizationID.String(), ProjectID: p.ProjectID.String(),
		PRNo: p.PrNo, Title: p.Title, Description: p.Description,
		NeededBy: nullableDateToPtr(p.NeededBy), Status: p.Status, EstimatedTotal: NumericToFloat64(p.EstimatedTotal),
		RequestedBy: nullableUUIDToPtr(p.RequestedBy),
		SubmittedAt: nullableTimestamptzToPtr(p.SubmittedAt),
		ApprovedAt:  nullableTimestamptzToPtr(p.ApprovedAt), ApprovedBy: nullableUUIDToPtr(p.ApprovedBy),
		RejectedAt: nullableTimestamptzToPtr(p.RejectedAt), RejectedBy: nullableUUIDToPtr(p.RejectedBy),
		RejectionReason: p.RejectionReason,
		CancelledAt:     nullableTimestamptzToPtr(p.CancelledAt), CancelledBy: nullableUUIDToPtr(p.CancelledBy),
		CancelReason: p.CancelReason,
		CreatedAt:    p.CreatedAt.Time, UpdatedAt: p.UpdatedAt.Time,
	}
}

func ToDomainPurchaseRequestItem(i sqlc.PurchaseRequestItem) domain.PurchaseRequestItem {
	return domain.PurchaseRequestItem{
		ID: i.ID.String(), OrganizationID: i.OrganizationID.String(), ProjectID: i.ProjectID.String(),
		PurchaseRequestID: i.PurchaseRequestID.String(),
		WBSNodeID:         nullableUUIDToPtr(i.WbsNodeID), CostCodeID: nullableUUIDToPtr(i.CostCodeID), BudgetLineID: nullableUUIDToPtr(i.BudgetLineID),
		Description: i.Description, Quantity: NumericToFloat64(i.Quantity), Unit: i.Unit,
		EstimatedUnitCost: NumericToFloat64Ptr(i.EstimatedUnitCost), EstimatedTotal: NumericToFloat64(i.EstimatedTotal),
		Notes: i.Notes, SortOrder: int(i.SortOrder),
	}
}

// ---------- RFQ ----------

func ToDomainRFQ(r sqlc.Rfq) domain.RFQ {
	return domain.RFQ{
		ID: r.ID.String(), OrganizationID: r.OrganizationID.String(), ProjectID: r.ProjectID.String(),
		RFQNo: r.RfqNo, PurchaseRequestID: nullableUUIDToPtr(r.PurchaseRequestID),
		Title: r.Title, IssueDate: r.IssueDate.Time, DueDate: nullableDateToPtr(r.DueDate), Status: r.Status, Notes: r.Notes,
		AwardedQuotationID: nullableUUIDToPtr(r.AwardedQuotationID), AwardedAt: nullableTimestamptzToPtr(r.AwardedAt),
		AwardedBy: nullableUUIDToPtr(r.AwardedBy), AwardNotes: r.AwardNotes,
		CreatedBy: nullableUUIDToPtr(r.CreatedBy), CreatedAt: r.CreatedAt.Time, UpdatedAt: r.UpdatedAt.Time,
	}
}

func ToDomainRFQSupplier(r sqlc.ListRFQSuppliersRow) domain.RFQSupplier {
	return domain.RFQSupplier{
		ID: r.ID.String(), OrganizationID: r.OrganizationID.String(), RFQID: r.RfqID.String(), SupplierID: r.SupplierID.String(),
		SupplierCode: r.SupplierCode, SupplierName: r.SupplierLegalName,
		InvitedAt: r.InvitedAt.Time, ResponseStatus: r.ResponseStatus,
	}
}

func ToDomainRFQItem(i sqlc.RfqItem) domain.RFQItem {
	return domain.RFQItem{
		ID: i.ID.String(), OrganizationID: i.OrganizationID.String(), ProjectID: i.ProjectID.String(), RFQID: i.RfqID.String(),
		SourcePRItemID: nullableUUIDToPtr(i.SourcePrItemID),
		WBSNodeID:      nullableUUIDToPtr(i.WbsNodeID), CostCodeID: nullableUUIDToPtr(i.CostCodeID), BudgetLineID: nullableUUIDToPtr(i.BudgetLineID),
		Description: i.Description, Quantity: NumericToFloat64(i.Quantity), Unit: i.Unit, SortOrder: int(i.SortOrder),
	}
}

// ---------- Tedarikçi Teklifi (Supplier Quotation) ----------

func ToDomainSupplierQuotation(q sqlc.SupplierQuotation) domain.SupplierQuotation {
	return domain.SupplierQuotation{
		ID: q.ID.String(), OrganizationID: q.OrganizationID.String(), ProjectID: q.ProjectID.String(),
		RFQID: q.RfqID.String(), SupplierID: q.SupplierID.String(),
		QuotationNumber: q.QuotationNumber, QuotationDate: q.QuotationDate.Time, ValidUntil: nullableDateToPtr(q.ValidUntil),
		Currency: q.Currency,
		Subtotal: NumericToFloat64(q.Subtotal), Discount: NumericToFloat64(q.Discount), TaxRate: NumericToFloat64(q.TaxRate),
		Tax: NumericToFloat64(q.Tax), Total: NumericToFloat64(q.Total),
		DeliveryDays: int32PtrToIntPtr(q.DeliveryDays), PaymentTerms: q.PaymentTerms, Notes: q.Notes,
		CreatedBy: nullableUUIDToPtr(q.CreatedBy), CreatedAt: q.CreatedAt.Time, UpdatedAt: q.UpdatedAt.Time,
	}
}

// ToDomainSupplierQuotationDetailed, ListSupplierQuotationsRow (tedarikçi
// kimliği JOIN edilmiş liste satırı) için AYRI bir yardımcı struct döner
// -- Teklif Karşılaştırma ekranı tedarikçi adını AYRI bir sorgu OLMADAN
// göstermeli (N+1 yok).
type SupplierQuotationDetailed struct {
	domain.SupplierQuotation
	SupplierCode string
	SupplierName string
}

func ToDomainSupplierQuotationDetailed(q sqlc.ListSupplierQuotationsRow) SupplierQuotationDetailed {
	base := ToDomainSupplierQuotation(sqlc.SupplierQuotation{
		ID: q.ID, OrganizationID: q.OrganizationID, ProjectID: q.ProjectID, RfqID: q.RfqID, SupplierID: q.SupplierID,
		QuotationNumber: q.QuotationNumber, QuotationDate: q.QuotationDate, ValidUntil: q.ValidUntil, Currency: q.Currency,
		Subtotal: q.Subtotal, Discount: q.Discount, TaxRate: q.TaxRate, Tax: q.Tax, Total: q.Total,
		DeliveryDays: q.DeliveryDays, PaymentTerms: q.PaymentTerms, Notes: q.Notes,
		CreatedBy: q.CreatedBy, CreatedAt: q.CreatedAt, UpdatedAt: q.UpdatedAt,
	})
	return SupplierQuotationDetailed{SupplierQuotation: base, SupplierCode: q.SupplierCode, SupplierName: q.SupplierLegalName}
}

func ToDomainQuotationItem(i sqlc.QuotationItem) domain.QuotationItem {
	return domain.QuotationItem{
		ID: i.ID.String(), OrganizationID: i.OrganizationID.String(), ProjectID: i.ProjectID.String(),
		QuotationID: i.QuotationID.String(), RFQItemID: i.RfqItemID.String(),
		Quantity: NumericToFloat64(i.Quantity), UnitPrice: NumericToFloat64(i.UnitPrice), LineTotal: NumericToFloat64(i.LineTotal),
		Notes: i.Notes,
	}
}

// ---------- Purchase Order ----------

func ToDomainPurchaseOrder(p sqlc.PurchaseOrder) domain.PurchaseOrder {
	return domain.PurchaseOrder{
		ID: p.ID.String(), OrganizationID: p.OrganizationID.String(), ProjectID: p.ProjectID.String(),
		PONo: p.PoNo, SupplierID: p.SupplierID.String(),
		SourceRFQID: nullableUUIDToPtr(p.SourceRfqID), SourceQuotationID: nullableUUIDToPtr(p.SourceQuotationID),
		Currency: p.Currency, Status: p.Status,
		IssueDate: p.IssueDate.Time, ExpectedDeliveryDate: nullableDateToPtr(p.ExpectedDeliveryDate),
		PaymentTerms: p.PaymentTerms, DeliveryAddress: p.DeliveryAddress, Notes: p.Notes,
		Subtotal: NumericToFloat64(p.Subtotal), TaxRate: NumericToFloat64(p.TaxRate), Tax: NumericToFloat64(p.Tax), Total: NumericToFloat64(p.Total),
		CreatedBy:  nullableUUIDToPtr(p.CreatedBy),
		ApprovedBy: nullableUUIDToPtr(p.ApprovedBy), ApprovedAt: nullableTimestamptzToPtr(p.ApprovedAt),
		CancelledBy: nullableUUIDToPtr(p.CancelledBy), CancelledAt: nullableTimestamptzToPtr(p.CancelledAt), CancelReason: p.CancelReason,
		ClosedBy: nullableUUIDToPtr(p.ClosedBy), ClosedAt: nullableTimestamptzToPtr(p.ClosedAt),
		CreatedAt: p.CreatedAt.Time, UpdatedAt: p.UpdatedAt.Time,
	}
}

// PurchaseOrderDetailed, ListPurchaseOrdersRow (tedarikçi kimliği JOIN
// edilmiş) için SupplierQuotationDetailed İLE AYNI desen.
type PurchaseOrderDetailed struct {
	domain.PurchaseOrder
	SupplierCode string
	SupplierName string
}

func ToDomainPurchaseOrderDetailed(p sqlc.ListPurchaseOrdersRow) PurchaseOrderDetailed {
	base := ToDomainPurchaseOrder(sqlc.PurchaseOrder{
		ID: p.ID, OrganizationID: p.OrganizationID, ProjectID: p.ProjectID, PoNo: p.PoNo, SupplierID: p.SupplierID,
		SourceRfqID: p.SourceRfqID, SourceQuotationID: p.SourceQuotationID, Currency: p.Currency, Status: p.Status,
		IssueDate: p.IssueDate, ExpectedDeliveryDate: p.ExpectedDeliveryDate, PaymentTerms: p.PaymentTerms,
		DeliveryAddress: p.DeliveryAddress, Notes: p.Notes, Subtotal: p.Subtotal, TaxRate: p.TaxRate, Tax: p.Tax, Total: p.Total,
		CreatedBy: p.CreatedBy, ApprovedBy: p.ApprovedBy, ApprovedAt: p.ApprovedAt,
		CancelledBy: p.CancelledBy, CancelledAt: p.CancelledAt, CancelReason: p.CancelReason,
		ClosedBy: p.ClosedBy, ClosedAt: p.ClosedAt, CreatedAt: p.CreatedAt, UpdatedAt: p.UpdatedAt,
	})
	return PurchaseOrderDetailed{PurchaseOrder: base, SupplierCode: p.SupplierCode, SupplierName: p.SupplierLegalName}
}

func ToDomainPurchaseOrderItem(i sqlc.PurchaseOrderItem) domain.PurchaseOrderItem {
	return domain.PurchaseOrderItem{
		ID: i.ID.String(), OrganizationID: i.OrganizationID.String(), ProjectID: i.ProjectID.String(),
		PurchaseOrderID: i.PurchaseOrderID.String(),
		WBSNodeID:       nullableUUIDToPtr(i.WbsNodeID), CostCodeID: i.CostCodeID.String(), BudgetLineID: nullableUUIDToPtr(i.BudgetLineID),
		Description: i.Description, Quantity: NumericToFloat64(i.Quantity), Unit: i.Unit,
		UnitPrice: NumericToFloat64(i.UnitPrice), LineTotal: NumericToFloat64(i.LineTotal), SortOrder: int(i.SortOrder),
	}
}

func int32PtrToIntPtr(v *int32) *int {
	if v == nil {
		return nil
	}
	i := int(*v)
	return &i
}
