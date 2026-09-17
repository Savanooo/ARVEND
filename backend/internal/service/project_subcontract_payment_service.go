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

// ARVEND V2 — Sprint 5 follow-up: Taşeron Ödemeleri (Subcontract Payments,
// bkz. migration 0039). project_finance_service.go'daki
// CreateSubcontractorPayment/VoidSubcontractorPayment (legacy) İLE BİREBİR
// AYNI kilit/idempotency/void deseni -- yalnızca kaynak tablo VE ek bir
// durum kapısı (yalnızca active/completed/terminated sözleşmeye ödeme
// yapılabilir) farklıdır. Bkz. docs/subcontracts.md.

var (
	ErrSubcontractNotPayable          = errors.New("taşeron sözleşmesi yalnızca aktif, tamamlanmış veya feshedilmiş durumdayken ödeme kaydedilebilir")
	ErrSubcontractPaymentClaimInvalid = errors.New("geçersiz hakediş: AYNI taşeron sözleşmesine ait VE sertifikalı olmalı")
)

type SubcontractPaymentInput struct {
	ProgressClaimID string
	Amount          float64
	Currency        string
	PaidDate        time.Time
	PaymentMethod   string
	ReferenceNo     string
	Description     string
	IdempotencyKey  string
	UserID          string
}

// CreateSubcontractPayment, GERÇEK bir nakit çıkışı kaydeder. Sertifikasyon
// ödeme DEĞİLDİR -- bu yüzden ProgressClaimID OPSİYONELDİR (avans/
// mobilizasyon ödemesi hiçbir hakedişe bağlı olmadan yapılabilir); VERİLMİŞSE
// AYNI sözleşmeye ait VE certified durumda olmalıdır (draft/submitted/
// rejected/cancelled bir hakedişe karşı ödeme anlamsızdır).
func (s *ProjectService) CreateSubcontractPayment(ctx context.Context, projectID, subcontractID, organizationID string, in SubcontractPaymentInput) (*domain.SubcontractPayment, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	scID, err := repository.StringToUUID(subcontractID)
	if err != nil {
		return nil, domain.ErrNotFound
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	// Sözleşme org+project-scope'lu VE kilitli okunur (IDOR + eşzamanlılık
	// koruması, SubcontractorPayment İLE AYNI gerekçe).
	sc, err := txq.GetSubcontractForUpdate(ctx, sqlc.GetSubcontractForUpdateParams{ID: scID, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	switch sc.Status {
	case domain.SubcontractStatusActive, domain.SubcontractStatusCompleted, domain.SubcontractStatusTerminated:
		// izinli
	default:
		return nil, ErrSubcontractNotPayable
	}

	project, err := s.requireOpenProject(ctx, txq, pid, orgID)
	if err != nil {
		return nil, err
	}
	// Sözleşmenin para birimi HER ZAMAN proje para birimiyle AYNIDIR
	// (CreateSubcontract/UpdateSubcontractDraft ASLA bağımsız bir currency
	// kabul etmez, bkz. project_subcontract_service.go) -- bu yüzden
	// mevcut validateMoney (proje bazlı) doğrudan yeniden kullanılabilir,
	// AYRI bir "sözleşme para birimi" kontrolü İCAT EDİLMEDİ.
	if err := validateMoney(in.Amount, in.Currency, project); err != nil {
		return nil, err
	}

	var claimID pgtype.UUID
	if strings.TrimSpace(in.ProgressClaimID) != "" {
		cid, err := repository.StringToUUID(in.ProgressClaimID)
		if err != nil {
			return nil, ErrSubcontractPaymentClaimInvalid
		}
		claim, err := txq.GetSubcontractProgressClaim(ctx, sqlc.GetSubcontractProgressClaimParams{ID: cid, OrganizationID: orgID, ProjectID: pid})
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return nil, ErrSubcontractPaymentClaimInvalid
			}
			return nil, err
		}
		if claim.SubcontractID != scID || claim.Status != domain.ProgressClaimStatusCertified {
			return nil, ErrSubcontractPaymentClaimInvalid
		}
		claimID = cid
	}

	// İdempotency anahtarı TAŞERON bazında (SubcontractorPayment İLE AYNI
	// ilke, migration 0026 gerekçesi).
	key := strings.TrimSpace(in.IdempotencyKey)
	if key != "" {
		if existing, err := txq.GetSubcontractPaymentByIdempotencyKey(ctx, sqlc.GetSubcontractPaymentByIdempotencyKeyParams{
			SubcontractID: scID, IdempotencyKey: &key,
		}); err == nil {
			out := repository.ToDomainSubcontractPayment(existing)
			return &out, nil
		} else if !errors.Is(err, pgx.ErrNoRows) {
			return nil, err
		}
	}

	var keyPtr *string
	if key != "" {
		keyPtr = &key
	}
	row, err := txq.CreateSubcontractPayment(ctx, sqlc.CreateSubcontractPaymentParams{
		OrganizationID: orgID, ProjectID: pid, SubcontractID: scID, ProgressClaimID: claimID,
		Amount: repository.Float64ToNumeric(in.Amount), Currency: project.Currency,
		PaidDate: repository.TimeToDate(in.PaidDate), PaymentMethod: strings.TrimSpace(in.PaymentMethod),
		ReferenceNo: strings.TrimSpace(in.ReferenceNo), Description: strings.TrimSpace(in.Description),
		IdempotencyKey: keyPtr, CreatedBy: actorUUID(in.UserID),
	})
	if err != nil {
		if key != "" && isUniqueViolation(err) {
			if existing, gerr := s.q.GetSubcontractPaymentByIdempotencyKey(ctx, sqlc.GetSubcontractPaymentByIdempotencyKeyParams{
				SubcontractID: scID, IdempotencyKey: &key,
			}); gerr == nil {
				out := repository.ToDomainSubcontractPayment(existing)
				return &out, nil
			}
		}
		return nil, err
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventSubcontractPaymentMade, actorUUID(in.UserID),
		map[string]any{"payment_id": row.ID.String(), "subcontract_id": subcontractID, "amount": in.Amount}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainSubcontractPayment(row)
	return &out, nil
}

func (s *ProjectService) ListSubcontractPayments(ctx context.Context, projectID, subcontractID, organizationID string) ([]domain.SubcontractPayment, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	scID, err := repository.StringToUUID(subcontractID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	rows, err := s.q.ListSubcontractPayments(ctx, sqlc.ListSubcontractPaymentsParams{SubcontractID: scID, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		return nil, err
	}
	out := make([]domain.SubcontractPayment, len(rows))
	for i, r := range rows {
		out[i] = repository.ToDomainSubcontractPayment(r)
	}
	return out, nil
}

// projectID, URL'deki proje kimliğidir -- paymentID'nin GERÇEKTEN bu
// projeye ait olduğunu sorgu seviyesinde doğrular (SubcontractorPayment
// İLE AYNI IDOR koruması).
func (s *ProjectService) VoidSubcontractPayment(ctx context.Context, projectID, paymentID, organizationID, userID, reason string) (*domain.SubcontractPayment, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	payID, err := repository.StringToUUID(paymentID)
	if err != nil {
		return nil, domain.ErrNotFound
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	row, err := txq.VoidSubcontractPayment(ctx, sqlc.VoidSubcontractPaymentParams{
		ID: payID, OrganizationID: orgID, ProjectID: pid, VoidedBy: actorUUID(userID), VoidReason: strings.TrimSpace(reason),
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			if existing, gerr := txq.GetSubcontractPayment(ctx, sqlc.GetSubcontractPaymentParams{ID: payID, OrganizationID: orgID, ProjectID: pid}); gerr == nil && existing.VoidedAt.Valid {
				return nil, ErrAlreadyVoided
			}
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventSubcontractPaymentVoid, actorUUID(userID),
		map[string]any{"payment_id": paymentID, "reason": reason}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainSubcontractPayment(row)
	return &out, nil
}
