package domain

import (
	"fmt"
	"time"
)

// --- Ek iş türü ---
//
// Tutarlar HER ZAMAN pozitiftir; "ek iş" mi "eksiltme" mi olduğu bu alanla
// ayrılır. Proje bedeline etkisi (+/-) yalnızca aggregate sırasında
// uygulanır -- negatif tutar kaydı yoktur.
const (
	ChangeOrderAddition  = "addition"
	ChangeOrderDeduction = "deduction"
)

func ValidChangeOrderType(s string) bool {
	return s == ChangeOrderAddition || s == ChangeOrderDeduction
}

// --- Durum makinesi ---
//
// draft -> sent -> {approved, rejected}
// draft -> cancelled
// sent  -> cancelled
// sent, rejected -> superseded (Revize Et ile, yeni bir taslak oluşunca)
//
// approved FİNALDİR: sonradan düzenlenemez, iptal edilemez, revize
// edilemez. Ticari etkisi geri alınacaksa yeni bir deduction change order
// oluşturulur (bkz. offer_revisions'daki "geçmişi mutate etme" ilkesi).
const (
	ChangeOrderDraft      = "draft"
	ChangeOrderSent       = "sent"
	ChangeOrderApproved   = "approved"
	ChangeOrderRejected   = "rejected"
	ChangeOrderCancelled  = "cancelled"
	ChangeOrderSuperseded = "superseded"
)

var validChangeOrderStatuses = map[string]bool{
	ChangeOrderDraft: true, ChangeOrderSent: true, ChangeOrderApproved: true,
	ChangeOrderRejected: true, ChangeOrderCancelled: true, ChangeOrderSuperseded: true,
}

func ValidChangeOrderStatus(s string) bool { return validChangeOrderStatuses[s] }

// Proje olay tipleri (project_events) -- Faz 6/7'nin finans/operasyon
// olaylarıyla AYNI tabloda, tek kronolojik zaman çizelgesi için.
const (
	ProjectEventChangeOrderCreated    = "change_order_created"
	ProjectEventChangeOrderUpdated    = "change_order_updated"
	ProjectEventChangeOrderSent       = "change_order_sent"
	ProjectEventChangeOrderViewed     = "change_order_viewed"
	ProjectEventChangeOrderApproved   = "change_order_approved"
	ProjectEventChangeOrderRejected   = "change_order_rejected"
	ProjectEventChangeOrderCancelled  = "change_order_cancelled"
	ProjectEventChangeOrderSuperseded = "change_order_superseded"
	ProjectEventChangeOrderEmailSent  = "change_order_email_sent"
	ProjectEventChangeOrderEmailFail  = "change_order_email_failed"
)

type ChangeOrderItem struct {
	ID                string
	OrganizationID    string
	ProjectID         string
	ChangeOrderID     string
	ProductID         *string
	Description       string
	Quantity          float64
	Unit              string
	UnitPrice         float64
	LineTotal         float64
	SortOrder         int
	EstimatedUnitCost *float64
	EstimatedCost     *float64
}

type ChangeOrder struct {
	ID             string
	OrganizationID string
	ProjectID      string
	SequenceNo     int
	ChangeType     string
	Title          string
	Description    string
	Status         string
	Subtotal       float64
	VatRate        float64
	VatAmount      float64
	GrandTotal     float64
	Currency       string
	InternalNotes  string
	CustomerNotes  string
	CreatedBy      *string
	CreatedAt      time.Time
	UpdatedAt      time.Time
	SentAt         *time.Time
	RespondedAt    *time.Time
	ApprovedAt     *time.Time
	RejectedAt     *time.Time
	CancelledAt    *time.Time

	SupersedesChangeOrderID *string
	// SupersededByChangeOrderID, JOIN ile doldurulur (bu satırı hangi
	// yeni revizyonun geçersiz kıldığı) -- kolon DEĞİLDİR.
	SupersededByChangeOrderID *string

	Items []ChangeOrderItem

	// ActiveShareToken, "Linki Kopyala"/paylaşım için -- yalnızca status
	// sent iken ve aktif (iptal/süresi dolmamış) bir link varken dolu
	// gelir. Kolon DEĞİLDİR; okuma anında korele edilir.
	ActiveShareToken *string

	// Profitability, YALNIZCA liste/detay okuma yollarında doldurulur
	// (nil ise hiç hesaplanmamıştır) -- proje toplamına zaten bir kez
	// giren, change_order_id ile etiketlenmiş kayıtların filtrelenmiş
	// görünümüdür.
	Profitability *ChangeOrderProfitability
}

// ChangeOrderNo, kullanıcıya gösterilen "EK-003" biçimidir. Kolon olarak
// saklanmaz -- sequence_no'dan türetilir (project_no + revision_no'nun
// "Revizyon N" olarak sunulmasıyla aynı ilke).
func (c ChangeOrder) ChangeOrderNo() string {
	return fmt.Sprintf("EK-%03d", c.SequenceNo)
}

// SignedEffect, onaylandığında proje bedeline etkisini işaretli olarak
// döner (addition: +grand_total, deduction: -grand_total). Yalnızca
// APPROVED bir kayıt için anlamlıdır; çağıran statüsü ayrıca kontrol eder.
func (c ChangeOrder) SignedEffect() float64 {
	if c.ChangeType == ChangeOrderDeduction {
		return -c.GrandTotal
	}
	return c.GrandTotal
}

// IsRevisable, "Revize Et" işleminin bu durumda geçerli olup olmadığını
// söyler -- offer'ın Revise guard'ıyla aynı ilke: yalnızca müşteriye
// ulaşmış (sent) ya da reddedilmiş bir belge revize edilebilir. draft
// zaten düzenlenebilir; approved/cancelled/superseded finaldir.
func (c ChangeOrder) IsRevisable() bool {
	return c.Status == ChangeOrderSent || c.Status == ChangeOrderRejected
}

// ChangeOrderShareLink, offer_share_links ile aynı tasarımdadır.
type ChangeOrderShareLink struct {
	ID             string
	OrganizationID string
	ProjectID      string
	ChangeOrderID  string
	Token          string
	CreatedBy      *string
	CreatedAt      time.Time
	ExpiresAt      *time.Time
	RevokedAt      *time.Time
}

func (l ChangeOrderShareLink) IsActive(now time.Time) bool {
	if l.RevokedAt != nil {
		return false
	}
	if l.ExpiresAt != nil && now.After(*l.ExpiresAt) {
		return false
	}
	return true
}

const (
	ChangeOrderEmailLogStatusSent   = "sent"
	ChangeOrderEmailLogStatusFailed = "failed"
)

type ChangeOrderEmailLog struct {
	ID             string
	OrganizationID string
	ProjectID      string
	ChangeOrderID  string
	ShareLinkID    string
	Recipient      string
	Subject        string
	Status         string
	ErrorMessage   string
	SentBy         *string
	SentAt         time.Time
}

// ChangeOrderProfitability, TEK bir ek işin kendi gelir/maliyet/kâr
// görünümüdür. Maliyetler change_order_id ile etiketlenmiş GERÇEK
// project_expenses/project_subcontractors kayıtlarından süzülür -- proje
// toplamına zaten bir kez giren AYNI kayıtların filtrelenmiş bir
// görünümüdür, ayrı bir para akışı DEĞİLDİR (çift sayım riski yok).
type ChangeOrderProfitability struct {
	RevenueEffect          float64
	RealizedCost           float64
	CommittedCost          float64
	RealizedProfit         float64
	EstimatedProfit        float64
	RealizedMarginPercent  float64
	EstimatedMarginPercent float64
}
