package repository

import (
	"encoding/json"

	"github.com/jackc/pgx/v5/pgtype"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

// nullableUUIDToPtr, opsiyonel bir sqlc UUID kolonunu (parent_id, created_by,
// approved_by, budget_line_id vb. -- bu dosyada çok sayıda) *string'e çevirir
// -- ToDomainOfferBase'teki tekil `if x.Valid {...}` deseninin, alan sayısı
// fazla olduğu için burada tek yerde toplanmış hâli.
func nullableUUIDToPtr(id pgtype.UUID) *string {
	if !id.Valid {
		return nil
	}
	s := id.String()
	return &s
}

// nullableStringPtrToPtr, sqlc'nin *string olarak ürettiği (LEFT JOIN'den
// gelen, örn. wbs_code/wbs_name) opsiyonel metin kolonlarını olduğu gibi
// geçirir (zaten *string) -- ayrı bir dönüşüm gerekmez, isimlendirme
// netliği için ayrı fonksiyon.
func nullableStringOrEmpty(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}

func ToDomainOrganizationCostCode(c sqlc.OrganizationCostCode) domain.OrganizationCostCode {
	return domain.OrganizationCostCode{
		ID:             c.ID.String(),
		OrganizationID: c.OrganizationID.String(),
		Code:           c.Code,
		Name:           c.Name,
		Description:    c.Description,
		Category:       c.Category,
		IsActive:       c.IsActive,
		CreatedAt:      c.CreatedAt.Time,
		UpdatedAt:      c.UpdatedAt.Time,
	}
}

func ToDomainWBSNode(n sqlc.ProjectWbsNode) domain.WBSNode {
	return domain.WBSNode{
		ID:             n.ID.String(),
		OrganizationID: n.OrganizationID.String(),
		ProjectID:      n.ProjectID.String(),
		ParentID:       nullableUUIDToPtr(n.ParentID),
		Code:           n.Code,
		Name:           n.Name,
		SortOrder:      int(n.SortOrder),
		IsActive:       n.IsActive,
		CreatedAt:      n.CreatedAt.Time,
		UpdatedAt:      n.UpdatedAt.Time,
	}
}

func ToDomainProjectBudget(b sqlc.ProjectBudget) domain.ProjectBudget {
	db := domain.ProjectBudget{
		ID:             b.ID.String(),
		OrganizationID: b.OrganizationID.String(),
		ProjectID:      b.ProjectID.String(),
		Currency:       b.Currency,
		Status:         b.Status,
		Version:        int(b.Version),
		CreatedBy:      nullableUUIDToPtr(b.CreatedBy),
		CreatedAt:      b.CreatedAt.Time,
		UpdatedAt:      b.UpdatedAt.Time,
		BaselinedBy:    nullableUUIDToPtr(b.BaselinedBy),
	}
	if b.BaselinedAt.Valid {
		t := b.BaselinedAt.Time
		db.BaselinedAt = &t
	}
	return db
}

func ToDomainBudgetLine(l sqlc.ProjectBudgetLine) domain.BudgetLine {
	return domain.BudgetLine{
		ID:             l.ID.String(),
		OrganizationID: l.OrganizationID.String(),
		ProjectID:      l.ProjectID.String(),
		BudgetID:       l.BudgetID.String(),
		WBSNodeID:      nullableUUIDToPtr(l.WbsNodeID),
		CostCodeID:     l.CostCodeID.String(),
		Description:    l.Description,
		Quantity:       NumericToFloat64Ptr(l.Quantity),
		Unit:           l.Unit,
		UnitCost:       NumericToFloat64Ptr(l.UnitCost),
		OriginalAmount: NumericToFloat64(l.OriginalAmount),
		Notes:          l.Notes,
		CreatedAt:      l.CreatedAt.Time,
		UpdatedAt:      l.UpdatedAt.Time,
	}
}

// ToDomainBudgetLineDetailed, ListBudgetLinesDetailed satırını (WBS/cost-
// code adları dahil) dönüştürür -- Bütçe düzenleme ekranının liste
// görünümü içindir.
func ToDomainBudgetLineDetailed(row sqlc.ListBudgetLinesDetailedRow) domain.BudgetLine {
	bl := ToDomainBudgetLine(sqlc.ProjectBudgetLine{
		ID: row.ID, OrganizationID: row.OrganizationID, ProjectID: row.ProjectID,
		BudgetID: row.BudgetID, WbsNodeID: row.WbsNodeID, CostCodeID: row.CostCodeID,
		Description: row.Description, Quantity: row.Quantity, Unit: row.Unit,
		UnitCost: row.UnitCost, OriginalAmount: row.OriginalAmount, Notes: row.Notes,
		CreatedAt: row.CreatedAt, UpdatedAt: row.UpdatedAt,
	})
	bl.WBSCode = nullableStringOrEmpty(row.WbsCode)
	bl.WBSName = nullableStringOrEmpty(row.WbsName)
	bl.CostCodeCode = row.CostCodeCode
	bl.CostCodeName = row.CostCodeName
	return bl
}

func ToDomainBudgetAdjustment(a sqlc.ProjectBudgetAdjustment) domain.BudgetAdjustment {
	da := domain.BudgetAdjustment{
		ID:             a.ID.String(),
		OrganizationID: a.OrganizationID.String(),
		ProjectID:      a.ProjectID.String(),
		BudgetID:       a.BudgetID.String(),
		BudgetLineID:   a.BudgetLineID.String(),
		Amount:         NumericToFloat64(a.Amount),
		Reason:         a.Reason,
		Status:         a.Status,
		CreatedBy:      nullableUUIDToPtr(a.CreatedBy),
		ApprovedBy:     nullableUUIDToPtr(a.ApprovedBy),
		CreatedAt:      a.CreatedAt.Time,
		UpdatedAt:      a.UpdatedAt.Time,
	}
	if a.ApprovedAt.Valid {
		t := a.ApprovedAt.Time
		da.ApprovedAt = &t
	}
	return da
}

func ToDomainCommitment(c sqlc.ProjectCommitment) domain.Commitment {
	dc := domain.Commitment{
		ID:              c.ID.String(),
		OrganizationID:  c.OrganizationID.String(),
		ProjectID:       c.ProjectID.String(),
		BudgetLineID:    nullableUUIDToPtr(c.BudgetLineID),
		CostCodeID:      c.CostCodeID.String(),
		SourceType:      c.SourceType,
		SourceID:        nullableUUIDToPtr(c.SourceID),
		Description:     c.Description,
		CommittedAmount: NumericToFloat64(c.CommittedAmount),
		Currency:        c.Currency,
		Status:          c.Status,
		CommittedAt:     c.CommittedAt.Time,
		CreatedBy:       nullableUUIDToPtr(c.CreatedBy),
		VoidedBy:        nullableUUIDToPtr(c.VoidedBy),
		VoidReason:      c.VoidReason,
		CreatedAt:       c.CreatedAt.Time,
		UpdatedAt:       c.UpdatedAt.Time,
	}
	if c.VoidedAt.Valid {
		t := c.VoidedAt.Time
		dc.VoidedAt = &t
	}
	return dc
}

// ToDomainCommitmentDetailed, ListCommitmentsDetailed satırını (cost-code
// adı dahil) dönüştürür.
func ToDomainCommitmentDetailed(row sqlc.ListCommitmentsDetailedRow) domain.Commitment {
	dc := ToDomainCommitment(sqlc.ProjectCommitment{
		ID: row.ID, OrganizationID: row.OrganizationID, ProjectID: row.ProjectID,
		BudgetLineID: row.BudgetLineID, CostCodeID: row.CostCodeID, SourceType: row.SourceType,
		SourceID: row.SourceID, Description: row.Description, CommittedAmount: row.CommittedAmount,
		Currency: row.Currency, Status: row.Status, CommittedAt: row.CommittedAt,
		IdempotencyKey: row.IdempotencyKey, CreatedBy: row.CreatedBy, VoidedAt: row.VoidedAt,
		VoidedBy: row.VoidedBy, VoidReason: row.VoidReason, CreatedAt: row.CreatedAt, UpdatedAt: row.UpdatedAt,
	})
	dc.CostCodeCode = row.CostCodeCode
	dc.CostCodeName = row.CostCodeName
	return dc
}

func ToDomainCostForecast(f sqlc.ProjectCostForecast) domain.CostForecast {
	return domain.CostForecast{
		ID:             f.ID.String(),
		OrganizationID: f.OrganizationID.String(),
		ProjectID:      f.ProjectID.String(),
		BudgetLineID:   f.BudgetLineID.String(),
		ETCAmount:      NumericToFloat64(f.EtcAmount),
		Note:           f.Note,
		UpdatedBy:      nullableUUIDToPtr(f.UpdatedBy),
		UpdatedAt:      f.UpdatedAt.Time,
	}
}

// ToDomainCostControlLine, ListCostControlLines satırını dönüştürür --
// budget_line_id/wbs_node_id NULL ise satır "bütçe dışı" (IsUnbudgeted)
// demektir (bkz. domain.CostControlLine yorumu).
func ToDomainCostControlLine(row sqlc.ListCostControlLinesRow) domain.CostControlLine {
	return domain.CostControlLine{
		BudgetLineID:        nullableUUIDToPtr(row.BudgetLineID),
		WBSNodeID:           nullableUUIDToPtr(row.WbsNodeID),
		WBSCode:             nullableStringOrEmpty(row.WbsCode),
		WBSName:             nullableStringOrEmpty(row.WbsName),
		CostCodeID:          row.CostCodeID.String(),
		CostCodeCode:        row.CostCodeCode,
		CostCodeName:        row.CostCodeName,
		Description:         row.Description,
		OriginalAmount:      NumericToFloat64(row.OriginalAmount),
		ApprovedAdjustments: NumericToFloat64(row.ApprovedAdjustments),
		RevisedBudget:       NumericToFloat64(row.RevisedBudget),
		CommittedCost:       NumericToFloat64(row.CommittedCost),
		ActualCost:          NumericToFloat64(row.ActualCost),
		ETCAmount:           NumericToFloat64(row.EtcAmount),
		EAC:                 NumericToFloat64(row.Eac),
		Variance:            NumericToFloat64(row.Variance),
		IsUnbudgeted:        row.IsUnbudgeted,
	}
}

// ToDomainCostControlSummary, GetProjectCostControlSummary satırını
// dönüştürür. HasBudget her zaman true'ya sabitlenir -- bütçesiz proje
// durumu (spec §42) servis katmanında AYRI olarak, sorgu hiç
// ÇALIŞTIRILMADAN ele alınır (bkz. CostControlService), bu yüzden bu
// mapper'a asla "bütçesiz" bir satır ulaşmaz.
func ToDomainCostControlSummary(row sqlc.GetProjectCostControlSummaryRow) domain.CostControlSummary {
	return domain.CostControlSummary{
		Currency:              row.Currency,
		ContractValue:         NumericToFloat64(row.ContractValue),
		OriginalBudget:        NumericToFloat64(row.OriginalBudget),
		ApprovedAdjustments:   NumericToFloat64(row.ApprovedAdjustments),
		RevisedBudget:         NumericToFloat64(row.RevisedBudget),
		CommittedCost:         NumericToFloat64(row.CommittedCost),
		ActualCost:            NumericToFloat64(row.ActualCost),
		ETCTotal:              NumericToFloat64(row.EtcTotal),
		EACTotal:              NumericToFloat64(row.EacTotal),
		Variance:              NumericToFloat64(row.Variance),
		ForecastProfit:        NumericToFloat64(row.ForecastProfit),
		ForecastMarginPercent: NumericToFloat64(row.ForecastMarginPercent),
		HasBudget:             true,
	}
}

// ToDomainOrganizationEvent, domain.ProjectEvent İLE AYNI mapper desenini
// (ToDomainProjectEvent, internal/repository/project_finance.go) izler.
func ToDomainOrganizationEvent(e sqlc.OrganizationEvent) domain.OrganizationEvent {
	de := domain.OrganizationEvent{
		ID:             e.ID.String(),
		OrganizationID: e.OrganizationID.String(),
		EventType:      e.EventType,
		UserID:         nullableUUIDToPtr(e.UserID),
		CreatedAt:      e.CreatedAt.Time,
	}
	if len(e.Metadata) > 0 {
		var meta map[string]any
		if err := json.Unmarshal(e.Metadata, &meta); err == nil {
			de.Metadata = meta
		}
	}
	return de
}
