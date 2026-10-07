package service

import (
	"context"
	"errors"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

var (
	// ErrBudgetAlreadyExists, bir projede ZATEN bir bütçe VARKEN ikinci bir
	// bütçe oluşturma girişiminde döner (bkz. migration 0035
	// UNIQUE(project_id) -- spec: "gereksiz workflow karmaşıklığından
	// kaçının, bir projede bir aktif bütçe tercih edilir").
	ErrBudgetAlreadyExists = errors.New("bu projenin zaten bir bütçesi var")
	// ErrBudgetNotFound, bu proje için HENÜZ bir bütçe OLUŞTURULMAMIŞSA
	// döner -- "bütçesiz proje" geçerli bir durumdur (spec §42), handler
	// katmanı bunu 404 yerine boş/HasBudget=false bir yanıtla ele alır.
	ErrBudgetNotFound = errors.New("bu proje için henüz bir bütçe oluşturulmamış")
	// ErrBudgetNotBaselinable, YALNIZCA draft durumundaki bir bütçe
	// baseline alınabilir döner -- ikinci bir baseline denemesi (spec:
	// "baseline iki kez olmamalı") burada engellenir.
	ErrBudgetNotBaselinable = errors.New("yalnızca taslak durumundaki bir bütçe baseline alınabilir")
	// ErrBudgetBaselined, baseline SONRASI bir bütçenin kalemlerini
	// doğrudan (Adjustment DIŞINDA) değiştirme girişiminde döner -- spec'in
	// "post-baseline sessiz üzerine yazma YOK, TÜM değişiklikler Budget
	// Adjustment üzerinden" kuralının somutlaşmasıdır. Baseline SONRASI
	// yeni bir bütçe kalemi de EKLENEMEZ/SİLİNEMEZ (bkz. docs/cost-
	// control.md "baseline sonrası kapsam genişlemesi" kararı): kapsam
	// dışı yeni harcamalar, ListCostControlLines'ın "bütçe dışı" (is_
	// unbudgeted) satırları olarak otomatik görünür hâle gelir.
	ErrBudgetBaselined = errors.New("baseline alınmış bir bütçenin kalemleri yalnızca bütçe revizyonu (adjustment) ile değiştirilebilir")
	// ErrInvalidBudgetLineCostCode, verilen cost_code_id bu organizasyonda
	// MEVCUT DEĞİLSE döner.
	ErrInvalidBudgetLineCostCode = errors.New("maliyet kodu bulunamadı")
)

// resolveCostCodeRef, resolveChangeOrderRef/resolveWBSParentRef İLE AYNI
// IDOR-güvenli desendir: boş ise (opsiyonel kullanım -- masraf/taşeron
// eşlemesi) NULL, doluysa kodun GERÇEKTEN bu organizasyona ait olduğunu
// sorgu seviyesinde doğrular.
func resolveCostCodeRef(ctx context.Context, q *sqlc.Queries, costCodeID string, orgID pgtype.UUID) (pgtype.UUID, error) {
	costCodeID = strings.TrimSpace(costCodeID)
	if costCodeID == "" {
		return pgtype.UUID{}, nil
	}
	cid, err := repository.StringToUUID(costCodeID)
	if err != nil {
		return pgtype.UUID{}, ErrInvalidBudgetLineCostCode
	}
	if _, err := q.GetOrganizationCostCode(ctx, sqlc.GetOrganizationCostCodeParams{ID: cid, OrganizationID: orgID}); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return pgtype.UUID{}, ErrInvalidBudgetLineCostCode
		}
		return pgtype.UUID{}, err
	}
	return cid, nil
}

// resolveBudgetLineRef, AYNI desen -- opsiyonel bir bütçe kalemi
// referansının GERÇEKTEN bu proje+organizasyona ait olduğunu doğrular
// (masraf/taşeron eşlemesinde cross-project IDOR'u engellemek için, bkz.
// Sprint 1'deki gerçek cross-project IDOR bulgusu İLE AYNI sınıf risk).
func resolveBudgetLineRef(ctx context.Context, q *sqlc.Queries, budgetLineID string, pid, orgID pgtype.UUID) (pgtype.UUID, error) {
	budgetLineID = strings.TrimSpace(budgetLineID)
	if budgetLineID == "" {
		return pgtype.UUID{}, nil
	}
	blid, err := repository.StringToUUID(budgetLineID)
	if err != nil {
		return pgtype.UUID{}, domain.ErrNotFound
	}
	if _, err := q.GetBudgetLine(ctx, sqlc.GetBudgetLineParams{ID: blid, OrganizationID: orgID, ProjectID: pid}); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return pgtype.UUID{}, domain.ErrNotFound
		}
		return pgtype.UUID{}, err
	}
	return blid, nil
}

// resolveCostAllocation, masraf/taşeron eşlemesi için ORTAK karardır
// (spec: "budget-line seçilince cost code otomatik doldurulmalı") --
// budgetLineID DOLUYSA, o kalemin cost_code_id'si OTORİTER olarak
// kullanılır (istemcinin AYRI gönderdiği costCodeID YOK SAYILIR, iki
// alanın senkron kalmasını istemciye YÜKLEMEMEK için); budgetLineID BOŞSA
// yalnızca costCodeID (varsa) çözümlenir -- her ikisi de opsiyoneldir
// (bkz. domain.Expense.CostCodeID notu, eski kayıtlar NULL kalır).
func resolveCostAllocation(ctx context.Context, q *sqlc.Queries, costCodeID, budgetLineID string, pid, orgID pgtype.UUID) (costCodeUUID, budgetLineUUID pgtype.UUID, err error) {
	budgetLineID = strings.TrimSpace(budgetLineID)
	if budgetLineID != "" {
		blid, err := repository.StringToUUID(budgetLineID)
		if err != nil {
			return pgtype.UUID{}, pgtype.UUID{}, domain.ErrNotFound
		}
		line, err := q.GetBudgetLine(ctx, sqlc.GetBudgetLineParams{ID: blid, OrganizationID: orgID, ProjectID: pid})
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return pgtype.UUID{}, pgtype.UUID{}, domain.ErrNotFound
			}
			return pgtype.UUID{}, pgtype.UUID{}, err
		}
		return line.CostCodeID, blid, nil
	}
	costCodeUUID, err = resolveCostCodeRef(ctx, q, costCodeID, orgID)
	if err != nil {
		return pgtype.UUID{}, pgtype.UUID{}, err
	}
	return costCodeUUID, pgtype.UUID{}, nil
}

// ---------- Proje Bütçesi ----------

func (s *ProjectService) CreateProjectBudget(ctx context.Context, projectID, organizationID, userID string) (*domain.ProjectBudget, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
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
	row, err := txq.CreateProjectBudget(ctx, sqlc.CreateProjectBudgetParams{
		OrganizationID: orgID, ProjectID: pid, Currency: project.Currency, CreatedBy: actorUUID(userID),
	})
	if err != nil {
		if isUniqueViolation(err) {
			return nil, ErrBudgetAlreadyExists
		}
		return nil, err
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventBudgetCreated, actorUUID(userID),
		map[string]any{"budget_id": row.ID.String(), "currency": project.Currency}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainProjectBudget(row)
	return &out, nil
}

// GetProjectBudget, ErrBudgetNotFound döner eğer bu proje için HENÜZ bir
// bütçe oluşturulmamışsa -- çağıran taraf (handler/CostControlSummary)
// bunu 404 yerine "bütçesiz proje" olarak ele almalıdır.
func (s *ProjectService) GetProjectBudget(ctx context.Context, projectID, organizationID string) (*domain.ProjectBudget, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	row, err := s.q.GetProjectBudget(ctx, sqlc.GetProjectBudgetParams{ProjectID: pid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrBudgetNotFound
		}
		return nil, err
	}
	out := repository.ToDomainProjectBudget(row)
	return &out, nil
}

// BaselineProjectBudget, TEK YÖNLÜ bir geçiştir (draft -> baselined) --
// geri dönüş YOKTUR. FOR UPDATE + status='draft' koşullu UPDATE (bkz.
// SendChangeOrder İLE AYNI ilke, project_change_order_service.go): eşzamanlı
// iki "baseline al" isteğinden yalnızca biri başarılı olur.
func (s *ProjectService) BaselineProjectBudget(ctx context.Context, projectID, organizationID, userID string) (*domain.ProjectBudget, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	current, err := txq.GetProjectBudget(ctx, sqlc.GetProjectBudgetParams{ProjectID: pid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrBudgetNotFound
		}
		return nil, err
	}
	locked, err := txq.GetProjectBudgetForUpdate(ctx, sqlc.GetProjectBudgetForUpdateParams{ID: current.ID, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrBudgetNotFound
		}
		return nil, err
	}
	if locked.Status != domain.BudgetStatusDraft {
		return nil, ErrBudgetNotBaselinable
	}
	row, err := txq.BaselineProjectBudget(ctx, sqlc.BaselineProjectBudgetParams{
		ID: locked.ID, OrganizationID: orgID, ProjectID: pid, BaselinedBy: actorUUID(userID),
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrBudgetNotBaselinable
		}
		return nil, err
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventBudgetBaselined, actorUUID(userID),
		map[string]any{"budget_id": row.ID.String()}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainProjectBudget(row)
	return &out, nil
}

// ---------- Bütçe Kalemleri ----------

type BudgetLineInput struct {
	WBSNodeID      string // opsiyonel
	CostCodeID     string // zorunlu
	Description    string
	Quantity       *float64
	Unit           string
	UnitCost       *float64
	OriginalAmount float64 // Quantity+UnitCost'un İKİSİ de doluysa YOK SAYILIR (bkz. computeLineAmount)
	Notes          string
	UserID         string
}

// computeLineAmount, spec'in "quantity×unit_cost her ikisi de verildiğinde
// backend TARAFINDAN hesaplanır, istemcinin gönderdiği toplama ASLA
// güvenilmez" kuralını uygular -- yalnızca biri veya hiçbiri verilmemişse
// istemcinin gönderdiği OriginalAmount kullanılır (bu durumda hesaplanacak
// bir çarpım YOKTUR).
func computeLineAmount(quantity, unitCost *float64, clientAmount float64) float64 {
	if quantity != nil && unitCost != nil {
		return round2(*quantity * *unitCost)
	}
	return clientAmount
}

func (s *ProjectService) requireDraftBudget(ctx context.Context, q *sqlc.Queries, pid, orgID pgtype.UUID) (sqlc.ProjectBudget, error) {
	b, err := q.GetProjectBudget(ctx, sqlc.GetProjectBudgetParams{ProjectID: pid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return sqlc.ProjectBudget{}, ErrBudgetNotFound
		}
		return sqlc.ProjectBudget{}, err
	}
	if b.Status != domain.BudgetStatusDraft {
		return sqlc.ProjectBudget{}, ErrBudgetBaselined
	}
	return b, nil
}

func (s *ProjectService) CreateBudgetLine(ctx context.Context, projectID, organizationID string, in BudgetLineInput) (*domain.BudgetLine, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	in.Description = strings.TrimSpace(in.Description)
	if in.Description == "" {
		return nil, errors.New("bütçe kalemi açıklaması zorunludur")
	}
	amount := computeLineAmount(in.Quantity, in.UnitCost, in.OriginalAmount)
	if amount < 0 {
		return nil, ErrInvalidAmount
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	budget, err := s.requireDraftBudget(ctx, txq, pid, orgID)
	if err != nil {
		return nil, err
	}
	if strings.TrimSpace(in.CostCodeID) == "" {
		return nil, ErrInvalidBudgetLineCostCode
	}
	costCodeID, err := resolveCostCodeRef(ctx, txq, in.CostCodeID, orgID)
	if err != nil {
		return nil, err
	}
	wbsNodeID, err := resolveBudgetLineWBSRef(ctx, txq, in.WBSNodeID, pid, orgID, pgtype.UUID{})
	if err != nil {
		return nil, err
	}
	row, err := txq.CreateBudgetLine(ctx, sqlc.CreateBudgetLineParams{
		OrganizationID: orgID, ProjectID: pid, BudgetID: budget.ID,
		WbsNodeID: wbsNodeID, CostCodeID: costCodeID,
		Description:    in.Description,
		Quantity:       repository.Float64PtrToNumeric(in.Quantity),
		Unit:           strings.TrimSpace(in.Unit),
		UnitCost:       repository.Float64PtrToNumeric(in.UnitCost),
		OriginalAmount: repository.Float64ToNumeric(amount),
		Notes:          strings.TrimSpace(in.Notes),
	})
	if err != nil {
		return nil, err
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventBudgetLineCreated, actorUUID(in.UserID),
		map[string]any{"budget_line_id": row.ID.String(), "amount": amount}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainBudgetLine(row)
	return &out, nil
}

// ListBudgetLines, projenin bütçesi (varsa) İÇİN detaylı (WBS/cost-code
// adları dahil) kalem listesini döner -- bütçe HENÜZ yoksa ErrBudgetNotFound.
func (s *ProjectService) ListBudgetLines(ctx context.Context, projectID, organizationID string) ([]domain.BudgetLine, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	budget, err := s.q.GetProjectBudget(ctx, sqlc.GetProjectBudgetParams{ProjectID: pid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrBudgetNotFound
		}
		return nil, err
	}
	rows, err := s.q.ListBudgetLinesDetailed(ctx, sqlc.ListBudgetLinesDetailedParams{BudgetID: budget.ID, OrganizationID: orgID})
	if err != nil {
		return nil, err
	}
	out := make([]domain.BudgetLine, len(rows))
	for i, r := range rows {
		out[i] = repository.ToDomainBudgetLineDetailed(r)
	}
	return out, nil
}

// UpdateBudgetLine, YALNIZCA draft bütçelerde çalışır -- baseline SONRASI
// ErrBudgetBaselined döner (bkz. dosya başındaki karar notu).
func (s *ProjectService) UpdateBudgetLine(ctx context.Context, projectID, lineID, organizationID string, in BudgetLineInput) (*domain.BudgetLine, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	lid, err := repository.StringToUUID(lineID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	in.Description = strings.TrimSpace(in.Description)
	if in.Description == "" {
		return nil, errors.New("bütçe kalemi açıklaması zorunludur")
	}
	amount := computeLineAmount(in.Quantity, in.UnitCost, in.OriginalAmount)
	if amount < 0 {
		return nil, ErrInvalidAmount
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	if _, err := s.requireDraftBudget(ctx, txq, pid, orgID); err != nil {
		return nil, err
	}
	if strings.TrimSpace(in.CostCodeID) == "" {
		return nil, ErrInvalidBudgetLineCostCode
	}
	costCodeID, err := resolveCostCodeRef(ctx, txq, in.CostCodeID, orgID)
	if err != nil {
		return nil, err
	}
	// Kalemin MEVCUT düğümü sonradan arşivlenmiş olabilir: kalem başka
	// alanları için düzenlenebilsin, yalnızca YENİ bir arşiv düğümü seçilemez.
	currentLine, err := txq.GetBudgetLine(ctx, sqlc.GetBudgetLineParams{ID: lid, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	wbsNodeID, err := resolveBudgetLineWBSRef(ctx, txq, in.WBSNodeID, pid, orgID, currentLine.WbsNodeID)
	if err != nil {
		return nil, err
	}
	row, err := txq.UpdateBudgetLine(ctx, sqlc.UpdateBudgetLineParams{
		ID: lid, OrganizationID: orgID, ProjectID: pid,
		WbsNodeID: wbsNodeID, CostCodeID: costCodeID,
		Description:    in.Description,
		Quantity:       repository.Float64PtrToNumeric(in.Quantity),
		Unit:           strings.TrimSpace(in.Unit),
		UnitCost:       repository.Float64PtrToNumeric(in.UnitCost),
		OriginalAmount: repository.Float64ToNumeric(amount),
		Notes:          strings.TrimSpace(in.Notes),
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventBudgetLineUpdated, actorUUID(in.UserID),
		map[string]any{"budget_line_id": lineID, "amount": amount}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainBudgetLine(row)
	return &out, nil
}

// DeleteBudgetLine, YALNIZCA draft bütçelerde çalışır (bkz. UpdateBudgetLine
// yorumu) -- gerçek bir hard-delete'tir (draft'ta henüz hiçbir taahhüt/
// gider/adjustment bu satıra bağlanmış OLAMAZ, çünkü onlar da draft'ta
// bağlanabilir olsa bile spec'in "committed/actual budget_line_id'si
// NULLABLE" tasarımı gereği satır silindiğinde onlar etkilenmez -- ama
// pratikte adjustment SADECE baseline SONRASI oluşturulabildiği için
// draft'ta bu satıra bağlı bir adjustment hiç YOKTUR).
func (s *ProjectService) DeleteBudgetLine(ctx context.Context, projectID, lineID, organizationID, userID string) error {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return err
	}
	lid, err := repository.StringToUUID(lineID)
	if err != nil {
		return domain.ErrNotFound
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	if _, err := s.requireDraftBudget(ctx, txq, pid, orgID); err != nil {
		return err
	}
	rows, err := txq.DeleteBudgetLine(ctx, sqlc.DeleteBudgetLineParams{ID: lid, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		return err
	}
	if rows == 0 {
		return domain.ErrNotFound
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventBudgetLineDeleted, actorUUID(userID),
		map[string]any{"budget_line_id": lineID}); err != nil {
		return err
	}
	return tx.Commit(ctx)
}
