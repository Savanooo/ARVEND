package service

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

// ARVEND V2 -- Sprint 3: Proje Sözleşmesi (Contract) servis katmanı.
// Durum makinesi ve "ticari temel" (baseline) kilit gerekçesi için bkz.
// domain/project_contract.go başlık yorumu ve docs/contracts.md.

var (
	// ErrContractAlreadyExists, bir projede ZATEN bir sözleşme VARKEN
	// ikinci bir sözleşme oluşturma girişiminde döner (bkz. migration
	// 0036 UNIQUE(project_id)).
	ErrContractAlreadyExists = errors.New("bu projenin zaten bir sözleşmesi var")
	// ErrContractNotFound, bu proje için HENÜZ bir sözleşme
	// OLUŞTURULMAMIŞSA döner -- "sözleşmesiz proje" geçerli bir durumdur
	// (Sprint 3 ÖNCESİ projeler İÇİN, backfill YOK), handler katmanı bunu
	// 404 olarak ele alır, web CTA gösterir.
	ErrContractNotFound = errors.New("bu proje için henüz bir sözleşme oluşturulmamış")
	// ErrContractNotEditable, ticari temel alanları (scope/payment_terms/
	// retention_terms/advance_terms/effective_date/planned_completion_
	// date) DRAFT DIŞINDA düzenlenmeye çalışılırsa döner -- bu alanlar
	// aktivasyonla KİLİTLENİR (bkz. domain/project_contract.go).
	ErrContractNotEditable = errors.New("sözleşme şartları yalnızca taslak durumdayken düzenlenebilir")
	// ErrContractNotesNotEditable, internal_notes bir TERMİNAL durumda
	// (completed/cancelled/terminated) düzenlenmeye çalışılırsa döner --
	// draft VE active'te serbesttir, yalnızca kapanış SONRASI kilitlenir.
	ErrContractNotesNotEditable = errors.New("sözleşme notu bu durumda düzenlenemez")
	ErrContractNotActivatable   = errors.New("yalnızca taslak durumundaki bir sözleşme aktive edilebilir")
	// ErrContractNotCancellable, DRAFT DIŞINDAN Cancel çağrılırsa döner --
	// yalnızca draft'tan cancel edilebilir (hiç yürürlüğe girmemiş bir
	// sözleşme feshedilemez, yalnızca iptal edilebilir).
	ErrContractNotCancellable = errors.New("yalnızca taslak durumundaki bir sözleşme iptal edilebilir")
	ErrContractNotCompletable = errors.New("yalnızca aktif durumundaki bir sözleşme tamamlanabilir")
	// ErrContractNotTerminable, ACTIVE DIŞINDAN (özellikle DRAFT'tan)
	// Terminate çağrılırsa döner -- draft bir sözleşme ASLA terminate
	// edilemez, yalnızca cancel edilebilir.
	ErrContractNotTerminable  = errors.New("yalnızca aktif durumundaki bir sözleşme feshedilebilir")
	ErrContractReasonRequired = errors.New("gerekçe zorunludur")
)

// ContractDraftInput, YALNIZCA "ticari temel" alanlarını taşır --
// internal_notes AYRI bir uçla (UpdateProjectContractNotes) düzenlenir
// (farklı kilitlenme kuralı taşıdığı için, bkz. domain notu).
type ContractDraftInput struct {
	Scope                 string
	PaymentTerms          string
	RetentionTerms        string
	AdvanceTerms          string
	EffectiveDate         *time.Time
	PlannedCompletionDate *time.Time
	UserID                string
}

func (s *ProjectService) loadProjectContract(ctx context.Context, q *sqlc.Queries, pid, orgID pgtype.UUID) (sqlc.ProjectContract, error) {
	c, err := q.GetProjectContract(ctx, sqlc.GetProjectContractParams{ProjectID: pid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return sqlc.ProjectContract{}, ErrContractNotFound
		}
		return sqlc.ProjectContract{}, err
	}
	return c, nil
}

// CreateProjectContract, MEVCUT (Sprint 3 ÖNCESİ) bir proje için manuel
// sözleşme oluşturma ucudur -- "Sözleşme Oluştur" CTA'sı bunu çağırır
// (backfill YOK, bkz. plan §2.1). YENİ projeler için otomatik oluşturma
// AYRI bir yerdedir (ProjectService.CreateFromOffer, aynı transaction
// içinde, sessizce -- bkz. o fonksiyonun düzenlemesi).
func (s *ProjectService) CreateProjectContract(ctx context.Context, projectID, organizationID, userID string) (*domain.ProjectContract, error) {
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
	row, err := txq.CreateProjectContract(ctx, sqlc.CreateProjectContractParams{
		OrganizationID: orgID, ProjectID: pid, Currency: project.Currency, CreatedBy: actorUUID(userID),
	})
	if err != nil {
		if isUniqueViolation(err) {
			return nil, ErrContractAlreadyExists
		}
		return nil, err
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventContractCreated, actorUUID(userID),
		map[string]any{"contract_id": row.ID.String()}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainProjectContract(row)
	return &out, nil
}

func (s *ProjectService) GetProjectContract(ctx context.Context, projectID, organizationID string) (*domain.ProjectContract, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	row, err := s.loadProjectContract(ctx, s.q, pid, orgID)
	if err != nil {
		return nil, err
	}
	out := repository.ToDomainProjectContract(row)
	return &out, nil
}

// UpdateProjectContractDraft, ticari temel alanlarını YALNIZCA draft
// durumdayken günceller -- aktivasyon sonrası ErrContractNotEditable.
func (s *ProjectService) UpdateProjectContractDraft(ctx context.Context, projectID, organizationID string, in ContractDraftInput) (*domain.ProjectContract, error) {
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

	current, err := s.loadProjectContract(ctx, txq, pid, orgID)
	if err != nil {
		return nil, err
	}
	row, err := txq.UpdateProjectContractDraftFields(ctx, sqlc.UpdateProjectContractDraftFieldsParams{
		ID: current.ID, OrganizationID: orgID, ProjectID: pid,
		Scope: strings.TrimSpace(in.Scope), PaymentTerms: strings.TrimSpace(in.PaymentTerms),
		RetentionTerms: strings.TrimSpace(in.RetentionTerms), AdvanceTerms: strings.TrimSpace(in.AdvanceTerms),
		EffectiveDate: repository.TimePtrToDate(in.EffectiveDate), PlannedCompletionDate: repository.TimePtrToDate(in.PlannedCompletionDate),
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrContractNotEditable
		}
		return nil, err
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventContractUpdated, actorUUID(in.UserID),
		map[string]any{"contract_id": current.ID.String()}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainProjectContract(row)
	return &out, nil
}

// UpdateProjectContractNotes, "ticari olmayan" internal_notes alanını
// günceller -- draft VE active'te serbest, terminal durumlarda kilitli
// (bkz. ErrContractNotesNotEditable notu).
func (s *ProjectService) UpdateProjectContractNotes(ctx context.Context, projectID, organizationID, userID, notes string) (*domain.ProjectContract, error) {
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

	current, err := s.loadProjectContract(ctx, txq, pid, orgID)
	if err != nil {
		return nil, err
	}
	row, err := txq.UpdateProjectContractNotes(ctx, sqlc.UpdateProjectContractNotesParams{
		ID: current.ID, OrganizationID: orgID, ProjectID: pid, InternalNotes: strings.TrimSpace(notes),
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrContractNotesNotEditable
		}
		return nil, err
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventContractNotesUpdated, actorUUID(userID),
		map[string]any{"contract_id": current.ID.String()}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainProjectContract(row)
	return &out, nil
}

// ---------- Durum geçişleri ----------
//
// Dördü de AYNI eşzamanlılık deseni: pool.Begin -> scopedIDs ->
// loadProjectContract (kilitsiz, yalnızca ID'yi öğrenmek için) ->
// GetProjectContractForUpdate (satır kilidi) -> Go-seviyeli durum
// kontrolü -> UPDATE ... WHERE status='<beklenen>' (ikinci, savunma-
// derinliği katmanı) -> logProjectEvent -> commit. project_change_
// orders'daki SendChangeOrder/RespondChangeOrderByShareLinkToken İLE
// BİREBİR AYNI ilke (bkz. docs/cost-control.md §16) -- yeni bir
// eşzamanlılık ilkesi İCAT EDİLMEDİ. requireOpenProject'e BİLİNÇLİ
// OLARAK bağlı DEĞİLLER (CreateProjectContract'ın aksine) -- bir
// sözleşmeyi Complete/Terminate etmek, projenin KENDİSİ zaten
// completed/cancelled olsa bile anlamlı bir "kapanış" eylemidir
// (BaselineProjectBudget'ın AYNI tasarım kararı).

func (s *ProjectService) ActivateProjectContract(ctx context.Context, projectID, organizationID, userID string) (*domain.ProjectContract, error) {
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

	current, err := s.loadProjectContract(ctx, txq, pid, orgID)
	if err != nil {
		return nil, err
	}
	locked, err := txq.GetProjectContractForUpdate(ctx, sqlc.GetProjectContractForUpdateParams{ID: current.ID, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrContractNotFound
		}
		return nil, err
	}
	if locked.Status != domain.ContractStatusDraft {
		return nil, ErrContractNotActivatable
	}
	row, err := txq.ActivateProjectContract(ctx, sqlc.ActivateProjectContractParams{ID: locked.ID, OrganizationID: orgID, ProjectID: pid, ActivatedBy: actorUUID(userID)})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrContractNotActivatable
		}
		return nil, err
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventContractActivated, actorUUID(userID),
		map[string]any{"contract_id": row.ID.String()}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainProjectContract(row)
	return &out, nil
}

func (s *ProjectService) CancelProjectContract(ctx context.Context, projectID, organizationID, userID, reason string) (*domain.ProjectContract, error) {
	reason = strings.TrimSpace(reason)
	if reason == "" {
		return nil, ErrContractReasonRequired
	}
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

	current, err := s.loadProjectContract(ctx, txq, pid, orgID)
	if err != nil {
		return nil, err
	}
	locked, err := txq.GetProjectContractForUpdate(ctx, sqlc.GetProjectContractForUpdateParams{ID: current.ID, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrContractNotFound
		}
		return nil, err
	}
	// Yalnızca DRAFT'tan -- ACTIVE'ten Cancel ASLA kabul edilmez (yürürlüğe
	// girmiş bir sözleşme yalnızca Terminate edilebilir).
	if locked.Status != domain.ContractStatusDraft {
		return nil, ErrContractNotCancellable
	}
	row, err := txq.CancelProjectContract(ctx, sqlc.CancelProjectContractParams{
		ID: locked.ID, OrganizationID: orgID, ProjectID: pid, CancelledBy: actorUUID(userID), CancelReason: reason,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrContractNotCancellable
		}
		return nil, err
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventContractCancelled, actorUUID(userID),
		map[string]any{"contract_id": row.ID.String(), "reason": reason}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainProjectContract(row)
	return &out, nil
}

func (s *ProjectService) CompleteProjectContract(ctx context.Context, projectID, organizationID, userID string) (*domain.ProjectContract, error) {
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

	current, err := s.loadProjectContract(ctx, txq, pid, orgID)
	if err != nil {
		return nil, err
	}
	locked, err := txq.GetProjectContractForUpdate(ctx, sqlc.GetProjectContractForUpdateParams{ID: current.ID, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrContractNotFound
		}
		return nil, err
	}
	if locked.Status != domain.ContractStatusActive {
		return nil, ErrContractNotCompletable
	}
	row, err := txq.CompleteProjectContract(ctx, sqlc.CompleteProjectContractParams{ID: locked.ID, OrganizationID: orgID, ProjectID: pid, CompletedBy: actorUUID(userID)})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrContractNotCompletable
		}
		return nil, err
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventContractCompleted, actorUUID(userID),
		map[string]any{"contract_id": row.ID.String()}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainProjectContract(row)
	return &out, nil
}

func (s *ProjectService) TerminateProjectContract(ctx context.Context, projectID, organizationID, userID, reason string) (*domain.ProjectContract, error) {
	reason = strings.TrimSpace(reason)
	if reason == "" {
		return nil, ErrContractReasonRequired
	}
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

	current, err := s.loadProjectContract(ctx, txq, pid, orgID)
	if err != nil {
		return nil, err
	}
	locked, err := txq.GetProjectContractForUpdate(ctx, sqlc.GetProjectContractForUpdateParams{ID: current.ID, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrContractNotFound
		}
		return nil, err
	}
	// Yalnızca ACTIVE'ten -- DRAFT bir sözleşme ASLA terminate edilemez
	// (hiç yürürlüğe girmemiş bir şey feshedilemez, yalnızca Cancel edilir).
	if locked.Status != domain.ContractStatusActive {
		return nil, ErrContractNotTerminable
	}
	row, err := txq.TerminateProjectContract(ctx, sqlc.TerminateProjectContractParams{
		ID: locked.ID, OrganizationID: orgID, ProjectID: pid, TerminatedBy: actorUUID(userID), TerminationReason: reason,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrContractNotTerminable
		}
		return nil, err
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventContractTerminated, actorUUID(userID),
		map[string]any{"contract_id": row.ID.String(), "reason": reason}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainProjectContract(row)
	return &out, nil
}
