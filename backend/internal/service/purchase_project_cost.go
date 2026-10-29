package service

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

// Satın almalar proje maliyetine girer (migration 0078, docs/maliyet-tanimlari.md
// "Satın almalar"). Ürün sahibi: talep ONAYLANINCA maliyete girsin ve
// onaylarken "proje maliyetine eklensin mi" diye sorulsun -- depo/stok ya da
// genel kullanım için alınan malzeme projenin kârını düşürmemeli. Kuralın
// kendisi görünümlerdedir (project_cost_lines); burada yalnızca karar
// (dahil mi, tahmini tutar) yazılır ve talep/sipariş başına katkı okunur.

var (
	ErrPurchaseRequestCostNotChangeable = errors.New("maliyet kararı yalnızca onaylı bir talepte değiştirilebilir")
	ErrPurchaseOrderCostNotChangeable   = errors.New("maliyet kararı yalnızca açık (taslak ya da onaylı) bir siparişte değiştirilebilir")
	ErrInvalidCostEstimate              = errors.New("tahmini tutar sıfır ya da pozitif olmalıdır")
	ErrPurchaseCostDecisionEmpty        = errors.New("değiştirilecek bir maliyet kararı gönderilmedi")
	// Doğrudan talebe bağlanan sipariş yalnızca onaylı talepten açılır;
	// RFQ'dan gelen sipariş RFQ'nun talebine bağlanır, ikisi çelişemez.
	ErrPurchaseOrderRequestNotApproved = errors.New("sipariş yalnızca bu projenin onaylı bir talebine bağlanabilir")
	ErrPurchaseOrderRequestMismatch    = errors.New("siparişin talebi, kaynak RFQ'nun talebiyle aynı olmalı")
)

// PurchaseCostDecision: "proje maliyetine eklensin mi" kararı. nil alan
// değişmez (onayda: karar evet, tahmin kalemlerin toplamı kalır).
// CostEstimate yalnızca talepte anlamlıdır: kalemlerde fiyat yokken (ya da
// eksikken) maliyete girecek tahmini tutar (KDV dahil).
type PurchaseCostDecision struct {
	Include      *bool
	CostEstimate *float64
}

func (d PurchaseCostDecision) validate() error {
	if d.CostEstimate != nil && *d.CostEstimate < 0 {
		return ErrInvalidCostEstimate
	}
	return nil
}

func (d PurchaseCostDecision) empty() bool { return d.Include == nil && d.CostEstimate == nil }

// eventMetadata: olay kaydına yazılan karar. Tahmini tutar "amount" ile
// yazılır (tutar anahtarı -- finans izni olmayana düşürülür, bkz.
// domain.ProjectEventMoneyKeys).
func (d PurchaseCostDecision) eventMetadata() map[string]any {
	meta := map[string]any{}
	if d.Include != nil {
		meta["included"] = *d.Include
	}
	if d.CostEstimate != nil {
		meta["amount"] = *d.CostEstimate
	}
	return meta
}

// SetPurchaseRequestCost: onaylı talebin maliyet kararını (ya da tahmini
// tutarını) değiştirir; projects.procurement.approve ister (onay ile aynı).
// Karar talepten açılmış AÇIK siparişlere de uygulanır -- talepte "Hayır"
// denince satın almanın tamamı maliyetten çıkar; kapatılmış sipariş
// kesinleşmiştir, değişmez. Proje rakamlarını değiştirdiği için
// tamamlanmış/iptal edilmiş projede yapılamaz.
func (s *ProjectService) SetPurchaseRequestCost(ctx context.Context, projectID, prID, organizationID, userID string, d PurchaseCostDecision) (*domain.PurchaseRequest, error) {
	if err := d.validate(); err != nil {
		return nil, err
	}
	if d.empty() {
		return nil, ErrPurchaseCostDecisionEmpty
	}
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	id, err := repository.StringToUUID(prID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	if _, err := s.requireOpenProject(ctx, txq, pid, orgID); err != nil {
		return nil, err
	}
	current, err := txq.GetPurchaseRequestForUpdate(ctx, sqlc.GetPurchaseRequestForUpdateParams{ID: id, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	if current.Status != domain.PurchaseRequestStatusApproved {
		return nil, ErrPurchaseRequestCostNotChangeable
	}
	row, err := txq.SetPurchaseRequestCostDecision(ctx, sqlc.SetPurchaseRequestCostDecisionParams{
		ID: id, OrganizationID: orgID, ProjectID: pid,
		IncludeInProjectCost: d.Include, CostEstimate: repository.Float64PtrToNumeric(d.CostEstimate),
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrPurchaseRequestCostNotChangeable
		}
		return nil, err
	}
	meta := d.eventMetadata()
	meta["purchase_request_id"] = prID
	if d.Include != nil {
		n, err := txq.CascadePurchaseRequestCostDecision(ctx, sqlc.CascadePurchaseRequestCostDecisionParams{
			PurchaseRequestID: id, OrganizationID: orgID, ProjectID: pid, IncludeInProjectCost: *d.Include,
		})
		if err != nil {
			return nil, err
		}
		meta["orders_updated"] = n
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventPurchaseRequestCostDecision, actorUUID(userID), meta); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainPurchaseRequest(row)
	return &out, nil
}

// SetPurchaseOrderCost: açık (taslak/onaylı) siparişin maliyet kararı;
// projects.procurement.approve ister. Kapatılmış sipariş kesinleşmiştir.
func (s *ProjectService) SetPurchaseOrderCost(ctx context.Context, projectID, poID, organizationID, userID string, include bool) (*domain.PurchaseOrder, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	id, err := repository.StringToUUID(poID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	if _, err := s.requireOpenProject(ctx, txq, pid, orgID); err != nil {
		return nil, err
	}
	if _, err := txq.GetPurchaseOrderForUpdate(ctx, sqlc.GetPurchaseOrderForUpdateParams{ID: id, OrganizationID: orgID, ProjectID: pid}); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	row, err := txq.SetPurchaseOrderCostDecision(ctx, sqlc.SetPurchaseOrderCostDecisionParams{
		ID: id, OrganizationID: orgID, ProjectID: pid, IncludeInProjectCost: include,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrPurchaseOrderCostNotChangeable
		}
		return nil, err
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventPurchaseOrderCostDecision, actorUUID(userID),
		map[string]any{"purchase_order_id": poID, "po_no": row.PoNo, "included": include}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainPurchaseOrder(row)
	return &out, nil
}

// PurchaseRequestCosts: talep başına maliyete katkı (talep kimliğiyle).
// prID boşsa projenin bütün talepleri.
func (s *ProjectService) PurchaseRequestCosts(ctx context.Context, projectID, prID, organizationID string) (map[string]domain.PurchaseCost, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	var filter pgtype.UUID
	if prID != "" {
		if filter, err = repository.StringToUUID(prID); err != nil {
			return nil, domain.ErrNotFound
		}
	}
	rows, err := s.q.ListPurchaseRequestCosts(ctx, sqlc.ListPurchaseRequestCostsParams{
		ProjectID: pid, OrganizationID: orgID, PurchaseRequestID: filter,
	})
	if err != nil {
		return nil, err
	}
	out := make(map[string]domain.PurchaseCost, len(rows))
	for _, r := range rows {
		out[r.PurchaseRequestID.String()] = repository.ToDomainPurchaseRequestCost(r)
	}
	return out, nil
}

// PurchaseOrderCosts: sipariş başına maliyete katkı (sipariş kimliğiyle).
// poID boşsa projenin bütün siparişleri.
func (s *ProjectService) PurchaseOrderCosts(ctx context.Context, projectID, poID, organizationID string) (map[string]domain.PurchaseCost, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	var filter pgtype.UUID
	if poID != "" {
		if filter, err = repository.StringToUUID(poID); err != nil {
			return nil, domain.ErrNotFound
		}
	}
	rows, err := s.q.ListPurchaseOrderCosts(ctx, sqlc.ListPurchaseOrderCostsParams{
		ProjectID: pid, OrganizationID: orgID, PurchaseOrderID: filter,
	})
	if err != nil {
		return nil, err
	}
	out := make(map[string]domain.PurchaseCost, len(rows))
	for _, r := range rows {
		out[r.PurchaseOrderID.String()] = repository.ToDomainPurchaseOrderCost(r)
	}
	return out, nil
}

// resolvePurchaseOrderRequest: siparişin bağlanacağı talep ve devralınan
// maliyet kararı. Doğrudan verilen talep bu projenin ONAYLI talebi olmalı;
// kaynak RFQ bir talepten açıldıysa sipariş o talebe bağlanır (RFQ'nun
// talebi sonradan iptal edilmiş olsa da izlenebilirlik için bağ kalır).
// İkisi birlikte verilip çelişirse reddedilir. Talepsiz sipariş "maliyete
// eklensin" ile başlar. Talep satırı kilitli okunur: aynı anda değişen
// talep kararı (SetPurchaseRequestCost, açık siparişlere de uygular) yeni
// siparişi eski kararla bırakmasın.
func resolvePurchaseOrderRequest(ctx context.Context, txq *sqlc.Queries, requested string, rfqID, pid, orgID pgtype.UUID) (pgtype.UUID, bool, error) {
	var prID pgtype.UUID
	if rfqID.Valid {
		rfq, err := txq.GetRFQ(ctx, sqlc.GetRFQParams{ID: rfqID, OrganizationID: orgID, ProjectID: pid})
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return pgtype.UUID{}, false, ErrSourceRFQRefNotFound
			}
			return pgtype.UUID{}, false, err
		}
		prID = rfq.PurchaseRequestID
	}
	if requested != "" {
		id, err := repository.StringToUUID(requested)
		if err != nil {
			return pgtype.UUID{}, false, ErrPurchaseOrderRequestNotApproved
		}
		if prID.Valid && prID != id {
			return pgtype.UUID{}, false, ErrPurchaseOrderRequestMismatch
		}
		pr, err := txq.GetPurchaseRequestForUpdate(ctx, sqlc.GetPurchaseRequestForUpdateParams{ID: id, OrganizationID: orgID, ProjectID: pid})
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return pgtype.UUID{}, false, ErrPurchaseOrderRequestNotApproved
			}
			return pgtype.UUID{}, false, err
		}
		if pr.Status != domain.PurchaseRequestStatusApproved {
			return pgtype.UUID{}, false, ErrPurchaseOrderRequestNotApproved
		}
		return id, pr.IncludeInProjectCost, nil
	}
	if !prID.Valid {
		return pgtype.UUID{}, true, nil
	}
	pr, err := txq.GetPurchaseRequestForUpdate(ctx, sqlc.GetPurchaseRequestForUpdateParams{ID: prID, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return pgtype.UUID{}, true, nil
		}
		return pgtype.UUID{}, false, err
	}
	return prID, pr.IncludeInProjectCost, nil
}
