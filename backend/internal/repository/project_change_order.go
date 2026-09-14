package repository

import (
	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

func ToDomainChangeOrder(c sqlc.ProjectChangeOrder) domain.ChangeOrder {
	co := domain.ChangeOrder{
		ID:             c.ID.String(),
		OrganizationID: c.OrganizationID.String(),
		ProjectID:      c.ProjectID.String(),
		SequenceNo:     int(c.SequenceNo),
		ChangeType:     c.ChangeType,
		Title:          c.Title,
		Description:    c.Description,
		Status:         c.Status,
		Subtotal:       NumericToFloat64(c.Subtotal),
		VatRate:        NumericToFloat64(c.VatRate),
		VatAmount:      NumericToFloat64(c.VatAmount),
		GrandTotal:     NumericToFloat64(c.GrandTotal),
		Currency:       c.Currency,
		InternalNotes:  c.InternalNotes,
		CustomerNotes:  c.CustomerNotes,
		CreatedAt:      c.CreatedAt.Time,
		UpdatedAt:      c.UpdatedAt.Time,
	}
	if c.CreatedBy.Valid {
		s := c.CreatedBy.String()
		co.CreatedBy = &s
	}
	if c.SentAt.Valid {
		t := c.SentAt.Time
		co.SentAt = &t
	}
	if c.RespondedAt.Valid {
		t := c.RespondedAt.Time
		co.RespondedAt = &t
	}
	if c.ApprovedAt.Valid {
		t := c.ApprovedAt.Time
		co.ApprovedAt = &t
	}
	if c.RejectedAt.Valid {
		t := c.RejectedAt.Time
		co.RejectedAt = &t
	}
	if c.CancelledAt.Valid {
		t := c.CancelledAt.Time
		co.CancelledAt = &t
	}
	if c.SupersedesChangeOrderID.Valid {
		s := c.SupersedesChangeOrderID.String()
		co.SupersedesChangeOrderID = &s
	}
	return co
}

// ToDomainChangeOrderListItem, ListChangeOrders satırını hem temel
// change order alanlarına hem de (bu kayda change_order_id ile
// etiketlenmiş GERÇEK masraf/taşeron kayıtlarından süzülen) kârlılık
// görünümüne çevirir. Kârlılık, proje toplamına zaten bir kez giren AYNI
// kayıtların filtrelenmiş halidir -- çift sayım yoktur.
func ToDomainChangeOrderListItem(r sqlc.ListChangeOrdersRow) (domain.ChangeOrder, domain.ChangeOrderProfitability) {
	co := ToDomainChangeOrder(sqlc.ProjectChangeOrder{
		ID: r.ID, OrganizationID: r.OrganizationID, ProjectID: r.ProjectID, SequenceNo: r.SequenceNo,
		ChangeType: r.ChangeType, Title: r.Title, Description: r.Description, Status: r.Status,
		Subtotal: r.Subtotal, VatRate: r.VatRate, VatAmount: r.VatAmount, GrandTotal: r.GrandTotal,
		Currency: r.Currency, InternalNotes: r.InternalNotes, CustomerNotes: r.CustomerNotes,
		CreatedBy: r.CreatedBy, CreatedAt: r.CreatedAt, UpdatedAt: r.UpdatedAt,
		SentAt: r.SentAt, RespondedAt: r.RespondedAt, ApprovedAt: r.ApprovedAt,
		RejectedAt: r.RejectedAt, CancelledAt: r.CancelledAt,
		SupersedesChangeOrderID: r.SupersedesChangeOrderID,
	})

	realizedCost := NumericToFloat64(r.RealizedExpenseCost) + NumericToFloat64(r.RealizedSubcontractorCost)
	committedCost := realizedCost + NumericToFloat64(r.SubcontractorRemainingCommitment)
	revenueEffect := co.SignedEffect()

	profit := domain.ChangeOrderProfitability{
		RevenueEffect:   revenueEffect,
		RealizedCost:    realizedCost,
		CommittedCost:   committedCost,
		RealizedProfit:  revenueEffect - realizedCost,
		EstimatedProfit: revenueEffect - committedCost,
	}
	denom := revenueEffect
	if denom < 0 {
		denom = -denom
	}
	if denom > 0 {
		profit.RealizedMarginPercent = clampPercent(profit.RealizedProfit * 100 / denom)
		profit.EstimatedMarginPercent = clampPercent(profit.EstimatedProfit * 100 / denom)
	}
	if r.ActiveShareToken.Valid {
		s := r.ActiveShareToken.String()
		co.ActiveShareToken = &s
	}
	return co, profit
}

// clampPercent, GetProjectFinancialSummary'deki GREATEST/LEAST kelepçe
// desenini Go tarafında tekrarlar -- bu değer SQL'de değil, tek bir
// satırın (join gerektirmeyen) basit türetilmiş alanı olduğu için burada
// hesaplanır; büyüklüğü SQL tarafındaki bantla (±99.999.999,99) aynı
// tutulur.
func clampPercent(v float64) float64 {
	const bound = 99999999.99
	if v > bound {
		return bound
	}
	if v < -bound {
		return -bound
	}
	return v
}

func ToDomainChangeOrderItem(i sqlc.ProjectChangeOrderItem) domain.ChangeOrderItem {
	item := domain.ChangeOrderItem{
		ID:             i.ID.String(),
		OrganizationID: i.OrganizationID.String(),
		ProjectID:      i.ProjectID.String(),
		ChangeOrderID:  i.ChangeOrderID.String(),
		Description:    i.Description,
		Quantity:       NumericToFloat64(i.Quantity),
		Unit:           i.Unit,
		UnitPrice:      NumericToFloat64(i.UnitPrice),
		LineTotal:      NumericToFloat64(i.LineTotal),
		SortOrder:      int(i.SortOrder),
	}
	if i.ProductID.Valid {
		s := i.ProductID.String()
		item.ProductID = &s
	}
	item.EstimatedUnitCost = NumericToFloat64Ptr(i.EstimatedUnitCost)
	item.EstimatedCost = NumericToFloat64Ptr(i.EstimatedCost)
	return item
}

func ToDomainChangeOrderShareLink(l sqlc.ProjectChangeOrderShareLink) domain.ChangeOrderShareLink {
	dl := domain.ChangeOrderShareLink{
		ID:             l.ID.String(),
		OrganizationID: l.OrganizationID.String(),
		ProjectID:      l.ProjectID.String(),
		ChangeOrderID:  l.ChangeOrderID.String(),
		Token:          l.Token.String(),
		CreatedAt:      l.CreatedAt.Time,
	}
	if l.CreatedBy.Valid {
		s := l.CreatedBy.String()
		dl.CreatedBy = &s
	}
	if l.ExpiresAt.Valid {
		t := l.ExpiresAt.Time
		dl.ExpiresAt = &t
	}
	if l.RevokedAt.Valid {
		t := l.RevokedAt.Time
		dl.RevokedAt = &t
	}
	return dl
}

func ToDomainChangeOrderEmailLog(e sqlc.ProjectChangeOrderEmailLog) domain.ChangeOrderEmailLog {
	log := domain.ChangeOrderEmailLog{
		ID:             e.ID.String(),
		OrganizationID: e.OrganizationID.String(),
		ProjectID:      e.ProjectID.String(),
		ChangeOrderID:  e.ChangeOrderID.String(),
		ShareLinkID:    e.ShareLinkID.String(),
		Recipient:      e.Recipient,
		Subject:        e.Subject,
		Status:         e.Status,
		ErrorMessage:   e.ErrorMessage,
		SentAt:         e.SentAt.Time,
	}
	if e.SentBy.Valid {
		s := e.SentBy.String()
		log.SentBy = &s
	}
	return log
}
