package service

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

// ErrCommitmentNotActive, ZATEN iptal edilmiş (voided) bir taahhüdü
// tekrar iptal etme girişiminde döner.
var ErrCommitmentNotActive = errors.New("yalnızca aktif bir taahhüt iptal edilebilir")

// ErrCommitmentNotManual, satın alma siparişinden ya da taşeron
// sözleşmesinden doğan bir taahhüdü elle iptal etme girişiminde döner --
// bu taahhütler kaynaklarının yaşam döngüsüyle senkron tutulur.
var ErrCommitmentNotManual = errors.New("satın alma siparişinden veya taşeron sözleşmesinden doğan taahhüt elle iptal edilemez; siparişi iptal edin ya da sözleşmeyi değişiklik/fesih ile güncelleyin")

// CommitmentInput, bu sprintte YALNIZCA MANUEL taahhütler içindir --
// SourceType kasıtlı olarak burada YOKTUR (her zaman domain.
// CommitmentSourceManual sabitlenir): spec'in "sahte PO/taşeron kaydı
// OLUŞTURULMAYACAK" yasağı gereği, source_type/source_id İSTEMCİDEN asla
// kabul edilmez -- şema gelecekteki Procurement/Subcontract modülleri
// için source_type/source_id alanlarını taşır, ama bu API'ler onları hiç
// açığa çıkarmaz.
type CommitmentInput struct {
	CostCodeID      string // zorunlu
	BudgetLineID    string // opsiyonel -- boşsa "bütçe dışı" (unbudgeted) taahhüt
	Description     string
	CommittedAmount float64
	CommittedAt     time.Time
	IdempotencyKey  string
	UserID          string
}

func (s *ProjectService) CreateCommitment(ctx context.Context, projectID, organizationID string, in CommitmentInput) (*domain.Commitment, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	in.Description = strings.TrimSpace(in.Description)
	if in.CommittedAmount <= 0 {
		return nil, ErrInvalidAmount
	}
	if strings.TrimSpace(in.CostCodeID) == "" {
		return nil, ErrInvalidBudgetLineCostCode
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

	key := strings.TrimSpace(in.IdempotencyKey)
	if key != "" {
		if existing, err := txq.GetCommitmentByIdempotencyKey(ctx, sqlc.GetCommitmentByIdempotencyKeyParams{
			ProjectID: pid, IdempotencyKey: &key,
		}); err == nil {
			out := repository.ToDomainCommitment(existing)
			return &out, nil
		} else if !errors.Is(err, pgx.ErrNoRows) {
			return nil, err
		}
	}

	costCodeID, err := resolveCostCodeRef(ctx, txq, in.CostCodeID, orgID)
	if err != nil {
		return nil, err
	}
	budgetLineID, err := resolveBudgetLineRef(ctx, txq, in.BudgetLineID, pid, orgID)
	if err != nil {
		return nil, err
	}
	var keyPtr *string
	if key != "" {
		keyPtr = &key
	}
	row, err := txq.CreateCommitment(ctx, sqlc.CreateCommitmentParams{
		OrganizationID: orgID, ProjectID: pid, BudgetLineID: budgetLineID, CostCodeID: costCodeID,
		SourceType:      domain.CommitmentSourceManual,
		Description:     in.Description,
		CommittedAmount: repository.Float64ToNumeric(in.CommittedAmount),
		Currency:        project.Currency,
		CommittedAt:     repository.TimeToDate(in.CommittedAt),
		IdempotencyKey:  keyPtr,
		CreatedBy:       actorUUID(in.UserID),
	})
	if err != nil {
		if key != "" && isUniqueViolation(err) {
			if existing, gerr := s.q.GetCommitmentByIdempotencyKey(ctx, sqlc.GetCommitmentByIdempotencyKeyParams{
				ProjectID: pid, IdempotencyKey: &key,
			}); gerr == nil {
				out := repository.ToDomainCommitment(existing)
				return &out, nil
			}
		}
		return nil, err
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventCommitmentCreated, actorUUID(in.UserID),
		map[string]any{"commitment_id": row.ID.String(), "amount": in.CommittedAmount}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainCommitment(row)
	return &out, nil
}

func (s *ProjectService) ListCommitments(ctx context.Context, projectID, organizationID string) ([]domain.Commitment, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	rows, err := s.q.ListCommitmentsDetailed(ctx, sqlc.ListCommitmentsDetailedParams{ProjectID: pid, OrganizationID: orgID})
	if err != nil {
		return nil, err
	}
	out := make([]domain.Commitment, len(rows))
	for i, r := range rows {
		out[i] = repository.ToDomainCommitmentDetailed(r)
	}
	return out, nil
}

// VoidCommitment, HARD DELETE DEĞİLDİR -- status='active' koşullu UPDATE
// (bkz. VoidExpense İLE AYNI ilke): iptal edilen taahhüt COMMITTED
// toplamından çıkar (bkz. ListCostControlLines'ın committed_by_line
// CTE'si WHERE status='active'), ama kayıt geçmişte görünür kalır.
func (s *ProjectService) VoidCommitment(ctx context.Context, projectID, commitmentID, organizationID, userID, reason string) (*domain.Commitment, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	cid, err := repository.StringToUUID(commitmentID)
	if err != nil {
		return nil, domain.ErrNotFound
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	// Tamamlanmış/iptal edilmiş projenin rakamları değişmez (bkz.
	// requireOpenProject; tamamlanan proje yeniden aktife alınarak açılır).
	if _, err := s.requireOpenProject(ctx, txq, pid, orgID); err != nil {
		return nil, err
	}

	row, err := txq.VoidCommitment(ctx, sqlc.VoidCommitmentParams{
		ID: cid, OrganizationID: orgID, ProjectID: pid, VoidedBy: actorUUID(userID), VoidReason: strings.TrimSpace(reason),
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			if existing, gerr := txq.GetCommitment(ctx, sqlc.GetCommitmentParams{ID: cid, OrganizationID: orgID, ProjectID: pid}); gerr == nil {
				if existing.Status == domain.CommitmentStatusVoided {
					return nil, ErrCommitmentNotActive
				}
				if existing.SourceType != domain.CommitmentSourceManual {
					return nil, ErrCommitmentNotManual
				}
			}
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventCommitmentVoided, actorUUID(userID),
		map[string]any{"commitment_id": commitmentID, "reason": reason}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainCommitment(row)
	return &out, nil
}

// ---------- Tahmin (Forecast / ETC) ----------

// UpsertForecastETC, spec §14'ün önerdiği "MANUEL ETC override" MVP'sidir
// -- satır YOKSA (kullanıcı hiç override girmemişse), servis katmanı
// (GetProjectCostControlSummary/ListCostControlLines SQL'i) varsayılan
// ETC'yi GREATEST(revised-actual, 0) olarak hesaplar; bu fonksiyon
// yalnızca kullanıcının BİLİNÇLİ bir override GİRDİĞİ durumu kaydeder.
func (s *ProjectService) UpsertForecastETC(ctx context.Context, projectID, lineID, organizationID string, etcAmount float64, note, userID string) (*domain.CostForecast, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	if etcAmount < 0 {
		return nil, ErrInvalidAmount
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	blid, err := resolveBudgetLineRef(ctx, txq, lineID, pid, orgID)
	if err != nil {
		return nil, err
	}
	if strings.TrimSpace(lineID) == "" || !blid.Valid {
		return nil, domain.ErrNotFound
	}
	row, err := txq.UpsertForecast(ctx, sqlc.UpsertForecastParams{
		OrganizationID: orgID, ProjectID: pid, BudgetLineID: blid,
		EtcAmount: repository.Float64ToNumeric(etcAmount), Note: strings.TrimSpace(note), UpdatedBy: actorUUID(userID),
	})
	if err != nil {
		return nil, err
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventForecastUpdated, actorUUID(userID),
		map[string]any{"budget_line_id": lineID, "etc_amount": etcAmount}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainCostForecast(row)
	return &out, nil
}

func (s *ProjectService) ListForecasts(ctx context.Context, projectID, organizationID string) ([]domain.CostForecast, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	rows, err := s.q.ListForecasts(ctx, sqlc.ListForecastsParams{ProjectID: pid, OrganizationID: orgID})
	if err != nil {
		return nil, err
	}
	out := make([]domain.CostForecast, len(rows))
	for i, r := range rows {
		out[i] = repository.ToDomainCostForecast(r)
	}
	return out, nil
}
