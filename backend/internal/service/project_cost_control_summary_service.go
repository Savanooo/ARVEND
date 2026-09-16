package service

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

// CostControlSummary, proje seviyesinde KPI özetini döner. Bütçe HENÜZ
// oluşturulmamış olsa BİLE sorgu ÇALIŞTIRILIR (GetProjectCostControlSummary,
// project_budget_lines/project_budgets'e değil doğrudan projects+
// project_commitments/project_expenses'e dayanır ve tüm toplamları
// COALESCE(sum(...),0) ile sıfıra güvenle indirger) -- böylece bütçesiz
// bir projede BİLE "bütçe dışı" (unbudgeted) taahhüt/gider varsa görünür
// kalır (spec §42 "existing projects without budget must keep working").
// HasBudget, YALNIZCA "bütçe oluşturuldu mu" sorusunu ayrı olarak
// project_budgets üzerinden cevaplar -- UI'nin "bütçe oluştur" CTA'sını
// göstermesi için.
func (s *ProjectService) CostControlSummary(ctx context.Context, projectID, organizationID string) (*domain.CostControlSummary, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	row, err := s.q.GetProjectCostControlSummary(ctx, sqlc.GetProjectCostControlSummaryParams{ID: pid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	summary := repository.ToDomainCostControlSummary(row)

	_, err = s.GetProjectBudget(ctx, projectID, organizationID)
	switch {
	case err == nil:
		summary.HasBudget = true
	case errors.Is(err, ErrBudgetNotFound):
		summary.HasBudget = false
	default:
		return nil, err
	}
	return &summary, nil
}

// CostControlLines, "Maliyet Kontrolü" ana kırılım tablosunu (WBS × Cost
// Code, bütçeli+bütçe dışı satırlar) döner -- AYNI gerekçeyle bütçesiz
// projede de çağrılabilir (bkz. CostControlSummary yorumu), boş bir bütçe
// dizisi + varsa unbudgeted satırlar döner.
func (s *ProjectService) CostControlLines(ctx context.Context, projectID, organizationID string) ([]domain.CostControlLine, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	rows, err := s.q.ListCostControlLines(ctx, sqlc.ListCostControlLinesParams{ProjectID: pid, OrganizationID: orgID})
	if err != nil {
		return nil, err
	}
	out := make([]domain.CostControlLine, len(rows))
	for i, r := range rows {
		out[i] = repository.ToDomainCostControlLine(r)
	}
	return out, nil
}
