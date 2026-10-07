package service

import (
	"context"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgtype"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

// ARVEND V2 — Sprint 4: Procurement Foundation, Tedarikçi Teklifi
// (Supplier Quotation) + Teklif Karşılaştırma. *ProjectService üzerinde
// metodlar. Teklif, RFQ 'issued' durumundayken VE henüz ödüllendirilmemiş
// (awarded_quotation_id IS NULL) iken oluşturulabilir/düzenlenebilir/
// silinebilir -- ödül verildikten SONRA ticari teklif geçmişi
// DONDURULUR (Contract'ın aktivasyon-sonrası kilit ilkesiyle AYNI mantık).
//
// currency, project.currency'den SNAPSHOT alınır (kullanıcı SEÇMEZ) --
// Budget/Contract İLE AYNI desen; cross-currency SORUSU bu yüzden hiç
// ORTAYA ÇIKMAZ (mevcut "FX motoru yok" ilkesiyle uyumlu).

type QuotationItemInput struct {
	RFQItemID string
	Quantity  float64
	UnitPrice float64
	Notes     string
}

type QuotationInput struct {
	SupplierID      string
	QuotationNumber string
	QuotationDate   time.Time
	ValidUntil      *time.Time
	Discount        float64
	TaxRate         float64
	DeliveryDays    *int
	PaymentTerms    string
	Notes           string
	Items           []QuotationItemInput
	UserID          string
}

// requireOpenRFQForQuotation, teklifin girilebileceği/düzenlenebileceği
// tek pencereyi doğrular: status='issued' VE henüz ödüllendirilmemiş.
func requireOpenRFQForQuotation(rfq sqlc.Rfq) error {
	if rfq.Status != domain.RFQStatusIssued || rfq.AwardedQuotationID.Valid {
		return ErrQuotationRFQNotOpen
	}
	return nil
}

func insertQuotationItems(ctx context.Context, txq *sqlc.Queries, orgID, pid, quotationID pgtype.UUID, items []QuotationItemInput) error {
	if err := txq.DeleteQuotationItems(ctx, sqlc.DeleteQuotationItemsParams{QuotationID: quotationID, OrganizationID: orgID, ProjectID: pid}); err != nil {
		return err
	}
	for _, it := range items {
		rfqItemID, err := repository.StringToUUID(strings.TrimSpace(it.RFQItemID))
		if err != nil {
			return domain.ErrNotFound
		}
		if it.Quantity <= 0 || it.UnitPrice <= 0 {
			return ErrInvalidAmount
		}
		if _, err := txq.CreateQuotationItem(ctx, sqlc.CreateQuotationItemParams{
			OrganizationID: orgID, ProjectID: pid, QuotationID: quotationID, RfqItemID: rfqItemID,
			Quantity: repository.Float64ToNumeric(it.Quantity), UnitPrice: repository.Float64ToNumeric(it.UnitPrice), Notes: it.Notes,
		}); err != nil {
			return err
		}
	}
	return nil
}

func (s *ProjectService) CreateQuotation(ctx context.Context, projectID, rfqID, organizationID string, in QuotationInput) (*domain.SupplierQuotation, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	rid, err := repository.StringToUUID(rfqID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	supplierID, err := repository.StringToUUID(strings.TrimSpace(in.SupplierID))
	if err != nil {
		return nil, domain.ErrNotFound
	}
	if len(in.Items) == 0 {
		return nil, ErrQuotationItemsRequired
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	project, err := s.requireOpenProject(ctx, txq, pid, orgID)
	if err != nil {
		return nil, err
	}
	rfq, err := txq.GetRFQ(ctx, sqlc.GetRFQParams{ID: rid, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		return nil, domain.ErrNotFound
	}
	if err := requireOpenRFQForQuotation(rfq); err != nil {
		return nil, err
	}
	invited, err := txq.ListRFQSuppliers(ctx, rid)
	if err != nil {
		return nil, err
	}
	found := false
	for _, is := range invited {
		if is.SupplierID == supplierID {
			found = true
			break
		}
	}
	if !found {
		return nil, ErrQuotationSupplierNotInvited
	}

	row, err := txq.CreateSupplierQuotation(ctx, sqlc.CreateSupplierQuotationParams{
		OrganizationID: orgID, ProjectID: pid, RfqID: rid, SupplierID: supplierID,
		QuotationNumber: in.QuotationNumber, QuotationDate: repository.TimeToDate(in.QuotationDate), ValidUntil: repository.TimePtrToDate(in.ValidUntil),
		Currency: project.Currency, Discount: repository.Float64ToNumeric(in.Discount), TaxRate: repository.Float64ToNumeric(in.TaxRate),
		DeliveryDays: int32PtrFromIntPtr(in.DeliveryDays), PaymentTerms: in.PaymentTerms, Notes: in.Notes,
		CreatedBy: actorUUID(in.UserID),
	})
	if err != nil {
		if isUniqueViolation(err) {
			return nil, ErrQuotationSupplierNotInvited // aynı tedarikçi bu RFQ'ya ZATEN teklif vermiş (UNIQUE(rfq_id,supplier_id))
		}
		return nil, err
	}
	if err := insertQuotationItems(ctx, txq, orgID, pid, row.ID, in.Items); err != nil {
		return nil, err
	}
	row, err = txq.RecomputeSupplierQuotationTotals(ctx, sqlc.RecomputeSupplierQuotationTotalsParams{ID: row.ID, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		return nil, err
	}
	if _, err := txq.MarkRFQSupplierResponded(ctx, sqlc.MarkRFQSupplierRespondedParams{RfqID: rid, SupplierID: supplierID}); err != nil {
		return nil, err
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventQuotationCreated, actorUUID(in.UserID),
		map[string]any{"quotation_id": row.ID.String(), "rfq_id": rfqID, "supplier_id": in.SupplierID}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainSupplierQuotation(row)
	return &out, nil
}

func (s *ProjectService) GetQuotation(ctx context.Context, projectID, quotationID, organizationID string) (*domain.SupplierQuotation, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	id, err := repository.StringToUUID(quotationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	row, err := s.q.GetSupplierQuotation(ctx, sqlc.GetSupplierQuotationParams{ID: id, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		return nil, domain.ErrNotFound
	}
	out := repository.ToDomainSupplierQuotation(row)
	return &out, nil
}

func (s *ProjectService) ListQuotations(ctx context.Context, projectID, rfqID, organizationID string) ([]repository.SupplierQuotationDetailed, error) {
	// RFQ önce URL'deki projeye göre doğrulanır: önceden pid hiç
	// kullanılmıyordu ve Proje A'ya üye bir kullanıcı, Proje B'nin RFQ
	// kimliğiyle B'nin tedarikçi tekliflerini (fiyatlarını) okuyabiliyordu.
	if _, err := s.GetRFQ(ctx, projectID, rfqID, organizationID); err != nil {
		return nil, err
	}
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	rid, err := repository.StringToUUID(rfqID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	rows, err := s.q.ListSupplierQuotations(ctx, sqlc.ListSupplierQuotationsParams{RfqID: rid, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		return nil, err
	}
	out := make([]repository.SupplierQuotationDetailed, len(rows))
	for i, r := range rows {
		out[i] = repository.ToDomainSupplierQuotationDetailed(r)
	}
	return out, nil
}

func (s *ProjectService) ListQuotationItems(ctx context.Context, projectID, quotationID, organizationID string) ([]domain.QuotationItem, error) {
	if _, err := s.GetQuotation(ctx, projectID, quotationID, organizationID); err != nil {
		return nil, err
	}
	id, _ := repository.StringToUUID(quotationID)
	rows, err := s.q.ListQuotationItems(ctx, id)
	if err != nil {
		return nil, err
	}
	out := make([]domain.QuotationItem, len(rows))
	for i, r := range rows {
		out[i] = repository.ToDomainQuotationItem(r)
	}
	return out, nil
}

func (s *ProjectService) UpdateQuotation(ctx context.Context, projectID, quotationID, organizationID string, in QuotationInput) (*domain.SupplierQuotation, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	id, err := repository.StringToUUID(quotationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	if len(in.Items) == 0 {
		return nil, ErrQuotationItemsRequired
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	current, err := txq.GetSupplierQuotationForUpdate(ctx, sqlc.GetSupplierQuotationForUpdateParams{ID: id, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		return nil, domain.ErrNotFound
	}
	rfq, err := txq.GetRFQ(ctx, sqlc.GetRFQParams{ID: current.RfqID, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		return nil, domain.ErrNotFound
	}
	if err := requireOpenRFQForQuotation(rfq); err != nil {
		return nil, err
	}

	row, err := txq.UpdateSupplierQuotationFields(ctx, sqlc.UpdateSupplierQuotationFieldsParams{
		ID: id, OrganizationID: orgID, ProjectID: pid,
		QuotationNumber: in.QuotationNumber, QuotationDate: repository.TimeToDate(in.QuotationDate), ValidUntil: repository.TimePtrToDate(in.ValidUntil),
		Discount: repository.Float64ToNumeric(in.Discount), TaxRate: repository.Float64ToNumeric(in.TaxRate),
		DeliveryDays: int32PtrFromIntPtr(in.DeliveryDays), PaymentTerms: in.PaymentTerms, Notes: in.Notes,
	})
	if err != nil {
		return nil, err
	}
	if err := insertQuotationItems(ctx, txq, orgID, pid, id, in.Items); err != nil {
		return nil, err
	}
	row, err = txq.RecomputeSupplierQuotationTotals(ctx, sqlc.RecomputeSupplierQuotationTotalsParams{ID: id, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		return nil, err
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventQuotationUpdated, actorUUID(in.UserID),
		map[string]any{"quotation_id": quotationID}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainSupplierQuotation(row)
	return &out, nil
}

func (s *ProjectService) DeleteQuotation(ctx context.Context, projectID, quotationID, organizationID, userID string) error {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return err
	}
	id, err := repository.StringToUUID(quotationID)
	if err != nil {
		return domain.ErrNotFound
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	current, err := txq.GetSupplierQuotationForUpdate(ctx, sqlc.GetSupplierQuotationForUpdateParams{ID: id, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		return domain.ErrNotFound
	}
	rfq, err := txq.GetRFQ(ctx, sqlc.GetRFQParams{ID: current.RfqID, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		return domain.ErrNotFound
	}
	if err := requireOpenRFQForQuotation(rfq); err != nil {
		return err
	}
	n, err := txq.DeleteSupplierQuotation(ctx, sqlc.DeleteSupplierQuotationParams{ID: id, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		return err
	}
	if n == 0 {
		return domain.ErrNotFound
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventQuotationDeleted, actorUUID(userID),
		map[string]any{"quotation_id": quotationID}); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// ---------- Teklif Karşılaştırma ----------

// BidComparisonCell, karşılaştırma ızgarasının TEK bir hücresidir (bir
// RFQ kalemi x bir tedarikçi).
type BidComparisonCell struct {
	SupplierID string
	Quantity   float64
	UnitPrice  float64
	LineTotal  float64
	Notes      string
}

// BidComparisonRow, ızgaranın bir SATIRIDIR (bir RFQ kalemi + o kalem
// için TÜM tedarikçilerin tekliflediği hücreler).
type BidComparisonRow struct {
	RFQItem domain.RFQItem
	Cells   map[string]BidComparisonCell // supplierID -> hücre
}

// BidComparison, GERÇEK karşılaştırma verisidir -- "en düşük fiyat"
// yalnızca BİLGİ amaçlı işaretlenir (LowestSupplierID boş olabilir,
// hiçbir teklif yoksa), sistem OTOMATİK bir kazanan SEÇMEZ (spec §10:
// "kullanıcı karar verir").
type BidComparison struct {
	Rows      []BidComparisonRow
	Suppliers []repository.SupplierQuotationDetailed
}

func (s *ProjectService) GetBidComparison(ctx context.Context, projectID, rfqID, organizationID string) (*BidComparison, error) {
	items, err := s.ListRFQItems(ctx, projectID, rfqID, organizationID)
	if err != nil {
		return nil, err
	}
	quotations, err := s.ListQuotations(ctx, projectID, rfqID, organizationID)
	if err != nil {
		return nil, err
	}
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	rid, err := repository.StringToUUID(rfqID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	cellRows, err := s.q.ListQuotationItemsForRFQ(ctx, sqlc.ListQuotationItemsForRFQParams{RfqID: rid, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		return nil, err
	}

	rowsByItem := make(map[string]*BidComparisonRow, len(items))
	rows := make([]BidComparisonRow, len(items))
	for i, it := range items {
		rows[i] = BidComparisonRow{RFQItem: it, Cells: map[string]BidComparisonCell{}}
		rowsByItem[it.ID] = &rows[i]
	}
	for _, c := range cellRows {
		rfqItemID := c.RfqItemID.String()
		row, ok := rowsByItem[rfqItemID]
		if !ok {
			continue
		}
		row.Cells[c.SupplierID.String()] = BidComparisonCell{
			SupplierID: c.SupplierID.String(),
			Quantity:   repository.NumericToFloat64(c.Quantity), UnitPrice: repository.NumericToFloat64(c.UnitPrice),
			LineTotal: repository.NumericToFloat64(c.LineTotal), Notes: c.Notes,
		}
	}
	return &BidComparison{Rows: rows, Suppliers: quotations}, nil
}

func int32PtrFromIntPtr(v *int) *int32 {
	if v == nil {
		return nil
	}
	i := int32(*v)
	return &i
}
