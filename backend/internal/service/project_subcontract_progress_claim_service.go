package service

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/shopspring/decimal"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

// ARVEND V2 — Sprint 5: Taşeron Hakedişi (Progress Claim). Müşteri hakedişi
// DEĞİLDİR (Sprint 6'ya bırakıldı), Supplier Invoice/Payment DEĞİLDİR (bu
// sprintte yok). Certified bir hakediş Cost Control'ün Actual'ına GİRMEZ
// (spec §23 kararı, bkz. docs/subcontracts.md) — yalnızca ticari/
// operasyonel bir sertifikasyon kaydıdır.

var (
	ErrProgressClaimNotEditable     = errors.New("hakediş yalnızca taslak durumdayken düzenlenebilir")
	ErrProgressClaimNotSubmittable  = errors.New("hakediş yalnızca taslak durumdan gönderilebilir")
	ErrProgressClaimNotCertifiable  = errors.New("hakediş yalnızca gönderilmiş durumdan sertifika edilebilir")
	ErrProgressClaimNotRejectable   = errors.New("hakediş yalnızca gönderilmiş durumdan reddedilebilir")
	ErrProgressClaimNotCancellable  = errors.New("hakediş yalnızca taslak/gönderilmiş durumdan iptal edilebilir")
	ErrProgressClaimItemsRequired   = errors.New("hakedişin en az bir kalemi olmalıdır")
	ErrProgressClaimReasonRequired  = errors.New("red gerekçesi zorunludur")
	ErrProgressClaimOverrun         = errors.New("kümülatif ilerleme, kalemin sözleşme tutarını aşamaz")
	ErrProgressClaimDuplicateItem   = errors.New("aynı SOV kalemi bir hakedişte birden fazla kez yer alamaz; tutarları tek satırda birleştirin")
	ErrProgressClaimStale           = errors.New("bu hakedişten sonra aynı kalemler için başka bir hakediş sertifika edildi — lütfen hakedişi güncelleyip tekrar deneyin")
	ErrSubcontractNotActiveForClaim = errors.New("taşeron sözleşmesi aktif olmadan hakediş oluşturulamaz")
	ErrSubcontractNotCertifiable    = errors.New("feshedilmiş bir taşeron sözleşmesinin hakedişi sertifika edilemez (kalan taahhüt fesihte serbest bırakıldı); hakedişi reddedin veya iptal edin")
)

type ProgressClaimItemInput struct {
	SubcontractItemID     string
	CurrentProgressAmount float64
}

type ProgressClaimInput struct {
	PeriodStart           *time.Time
	PeriodEnd             time.Time
	RetentionPercent      *float64 // nil ise sözleşmenin KENDİ retention_percent'i kullanılır
	AdvanceRecoveryAmount float64
	OtherDeductions       float64
	Notes                 string
	Items                 []ProgressClaimItemInput
	UserID                string
}

func (s *ProjectService) generateSubcontractProgressClaimNo(ctx context.Context, q *sqlc.Queries, orgID pgtype.UUID) (string, error) {
	year := time.Now().Year()
	seq, err := q.NextSubcontractProgressClaimSeq(ctx, sqlc.NextSubcontractProgressClaimSeqParams{OrganizationID: orgID, Year: int32(year)})
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("SPC-%d-%04d", year, seq), nil
}

// insertProgressClaimItems, HER kalem için previous_progress_amount'ı bu
// SOV kaleminin en son SERTİFİKALI kümülatif tutarından OTOMATİK doldurur
// (spec §17), scheduled_value'yu O ANKİ kalem sınırının (SOV tutarı +
// grubun onaylı net eki, bkz. subcontractClaimCaps.itemCap) SNAPSHOT'ı
// olarak alır (retention_percent_snapshot İLE AYNI "geçmiş sessizce
// mutate olmaz" ilkesi) ve kalem/grup/sözleşme sınırlarını Go seviyesinde
// doğrular (kalem sınırı için DB CHECK'i savunma derinliği olarak zaten
// var).
func insertProgressClaimItems(ctx context.Context, txq *sqlc.Queries, orgID, pid, claimID pgtype.UUID, caps *subcontractClaimCaps, items []ProgressClaimItemInput) error {
	if err := txq.DeleteSubcontractProgressClaimItems(ctx, sqlc.DeleteSubcontractProgressClaimItemsParams{ProgressClaimID: claimID, OrganizationID: orgID, ProjectID: pid}); err != nil {
		return err
	}
	cumulative := make(map[string]decimal.Decimal, len(items))
	for i, it := range items {
		sovItem, ok := caps.items[it.SubcontractItemID]
		if !ok {
			return domain.ErrNotFound
		}
		id := sovItem.ID.String()
		// Aynı SOV kalemi bir hakedişte iki kez yer alamaz: her satır aynı
		// "previous"tan hesaplandığı için kümülatif kontrolü satır başına
		// geçiyor, toplamda ise kalem %100'ün üzerinde sertifikalanıyordu
		// (60.000'lik kaleme 2 x 40.000).
		if _, dup := cumulative[id]; dup {
			return ErrProgressClaimDuplicateItem
		}
		if it.CurrentProgressAmount < 0 {
			return ErrInvalidAmount
		}
		// Kuruş karşılaştırması decimal'dir: float64 toplama (ör. 50,10 +
		// 50,20 = 100,30000000000001) tam %100'e çıkan son hakedişi
		// "aşım" diye reddediyordu.
		previous := caps.certified[id]
		scheduled := caps.itemCap(id)
		current := money2(it.CurrentProgressAmount)
		cumulative[id] = previous.Add(current)
		if cumulative[id].Cmp(scheduled) > 0 {
			return ErrProgressClaimOverrun
		}
		if _, err := txq.CreateSubcontractProgressClaimItem(ctx, sqlc.CreateSubcontractProgressClaimItemParams{
			OrganizationID: orgID, ProjectID: pid, ProgressClaimID: claimID, SubcontractItemID: sovItem.ID,
			ScheduledValue: repository.DecimalToNumeric(scheduled), PreviousProgressAmount: repository.DecimalToNumeric(previous),
			CurrentProgressAmount: repository.DecimalToNumeric(current), SortOrder: int32(i),
		}); err != nil {
			return err
		}
	}
	return caps.checkClaim(cumulative)
}

func (s *ProjectService) CreateProgressClaim(ctx context.Context, projectID, subcontractID, organizationID string, in ProgressClaimInput) (*domain.SubcontractProgressClaim, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	scID, err := repository.StringToUUID(subcontractID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	if len(in.Items) == 0 {
		return nil, ErrProgressClaimItemsRequired
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	sc, err := txq.GetSubcontract(ctx, sqlc.GetSubcontractParams{ID: scID, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	if sc.Status != domain.SubcontractStatusActive {
		return nil, ErrSubcontractNotActiveForClaim
	}

	retentionPercent := repository.NumericToFloat64(sc.RetentionPercent)
	if in.RetentionPercent != nil {
		retentionPercent = *in.RetentionPercent
	}

	claimNo, err := s.generateSubcontractProgressClaimNo(ctx, txq, orgID)
	if err != nil {
		return nil, err
	}
	row, err := txq.CreateSubcontractProgressClaim(ctx, sqlc.CreateSubcontractProgressClaimParams{
		OrganizationID: orgID, ProjectID: pid, SubcontractID: scID, ClaimNumber: claimNo,
		PeriodStart: dateFromPtr(in.PeriodStart), PeriodEnd: repository.TimeToDate(in.PeriodEnd),
		RetentionPercentSnapshot: repository.Float64ToNumeric(retentionPercent),
		AdvanceRecoveryAmount:    repository.Float64ToNumeric(in.AdvanceRecoveryAmount),
		OtherDeductions:          repository.Float64ToNumeric(in.OtherDeductions),
		Notes:                    in.Notes, CreatedBy: actorUUID(in.UserID),
	})
	if err != nil {
		return nil, err
	}

	caps, err := loadSubcontractClaimCaps(ctx, txq, orgID, pid, sc)
	if err != nil {
		return nil, err
	}
	if err := insertProgressClaimItems(ctx, txq, orgID, pid, row.ID, caps, in.Items); err != nil {
		return nil, err
	}
	row, err = txq.RecomputeSubcontractProgressClaimTotals(ctx, sqlc.RecomputeSubcontractProgressClaimTotalsParams{ID: row.ID, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		return nil, err
	}

	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventProgressClaimCreated, actorUUID(in.UserID),
		map[string]any{"subcontract_id": subcontractID, "progress_claim_id": row.ID.String()}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainProgressClaim(row)
	return &out, nil
}

func (s *ProjectService) ListProgressClaims(ctx context.Context, projectID, subcontractID, organizationID string) ([]domain.SubcontractProgressClaim, error) {
	if _, err := s.GetSubcontract(ctx, projectID, subcontractID, organizationID); err != nil {
		return nil, err
	}
	id, _ := repository.StringToUUID(subcontractID)
	rows, err := s.q.ListSubcontractProgressClaims(ctx, id)
	if err != nil {
		return nil, err
	}
	out := make([]domain.SubcontractProgressClaim, len(rows))
	for i, r := range rows {
		out[i] = repository.ToDomainProgressClaim(r)
	}
	return out, nil
}

func (s *ProjectService) GetProgressClaim(ctx context.Context, projectID, claimID, organizationID string) (*domain.SubcontractProgressClaim, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	id, err := repository.StringToUUID(claimID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	row, err := s.q.GetSubcontractProgressClaim(ctx, sqlc.GetSubcontractProgressClaimParams{ID: id, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	out := repository.ToDomainProgressClaim(row)
	return &out, nil
}

func (s *ProjectService) ListProgressClaimItems(ctx context.Context, projectID, claimID, organizationID string) ([]domain.SubcontractProgressClaimItem, error) {
	if _, err := s.GetProgressClaim(ctx, projectID, claimID, organizationID); err != nil {
		return nil, err
	}
	id, _ := repository.StringToUUID(claimID)
	rows, err := s.q.ListSubcontractProgressClaimItemsDetailed(ctx, id)
	if err != nil {
		return nil, err
	}
	out := make([]domain.SubcontractProgressClaimItem, len(rows))
	for i, r := range rows {
		out[i] = repository.ToDomainProgressClaimItemDetailed(r)
	}
	return out, nil
}

func (s *ProjectService) UpdateProgressClaimDraft(ctx context.Context, projectID, claimID, organizationID string, in ProgressClaimInput) (*domain.SubcontractProgressClaim, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	id, err := repository.StringToUUID(claimID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	if len(in.Items) == 0 {
		return nil, ErrProgressClaimItemsRequired
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	current, err := txq.GetSubcontractProgressClaimForUpdate(ctx, sqlc.GetSubcontractProgressClaimForUpdateParams{ID: id, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	if current.Status != domain.ProgressClaimStatusDraft {
		return nil, ErrProgressClaimNotEditable
	}

	retentionPercent := repository.NumericToFloat64(current.RetentionPercentSnapshot)
	if in.RetentionPercent != nil {
		retentionPercent = *in.RetentionPercent
	}

	row, err := txq.UpdateSubcontractProgressClaimDraft(ctx, sqlc.UpdateSubcontractProgressClaimDraftParams{
		ID: id, OrganizationID: orgID, ProjectID: pid,
		PeriodStart: dateFromPtr(in.PeriodStart), PeriodEnd: repository.TimeToDate(in.PeriodEnd),
		RetentionPercentSnapshot: repository.Float64ToNumeric(retentionPercent),
		AdvanceRecoveryAmount:    repository.Float64ToNumeric(in.AdvanceRecoveryAmount),
		OtherDeductions:          repository.Float64ToNumeric(in.OtherDeductions), Notes: in.Notes,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrProgressClaimNotEditable
		}
		return nil, err
	}

	sc, err := txq.GetSubcontract(ctx, sqlc.GetSubcontractParams{ID: current.SubcontractID, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		return nil, err
	}
	caps, err := loadSubcontractClaimCaps(ctx, txq, orgID, pid, sc)
	if err != nil {
		return nil, err
	}
	if err := insertProgressClaimItems(ctx, txq, orgID, pid, id, caps, in.Items); err != nil {
		return nil, err
	}
	row, err = txq.RecomputeSubcontractProgressClaimTotals(ctx, sqlc.RecomputeSubcontractProgressClaimTotalsParams{ID: id, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		return nil, err
	}

	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventProgressClaimUpdated, actorUUID(in.UserID),
		map[string]any{"progress_claim_id": claimID}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainProgressClaim(row)
	return &out, nil
}

func (s *ProjectService) SubmitProgressClaim(ctx context.Context, projectID, claimID, organizationID, userID string) (*domain.SubcontractProgressClaim, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	id, err := repository.StringToUUID(claimID)
	if err != nil {
		return nil, domain.ErrNotFound
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	// Hakediş önce URL'deki projeye göre doğrulanır; kalemleri yalnızca
	// claim id ile okunduğu için aksi halde başka projenin hakedişi
	// hakkında bilgi (kalemi var/yok) sızardı.
	if _, err := txq.GetSubcontractProgressClaimForUpdate(ctx, sqlc.GetSubcontractProgressClaimForUpdateParams{ID: id, OrganizationID: orgID, ProjectID: pid}); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	items, err := txq.ListSubcontractProgressClaimItemsDetailed(ctx, id)
	if err != nil {
		return nil, err
	}
	if len(items) == 0 {
		return nil, ErrProgressClaimItemsRequired
	}

	row, err := txq.SubmitSubcontractProgressClaim(ctx, sqlc.SubmitSubcontractProgressClaimParams{ID: id, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrProgressClaimNotSubmittable
		}
		return nil, err
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventProgressClaimSubmitted, actorUUID(userID),
		map[string]any{"progress_claim_id": claimID}); err != nil {
		return nil, err
	}
	approvers, err := resolveProjectApprovers(ctx, txq, orgID, pid, domain.PermProjectsSubcontractClaimsCertify)
	if err != nil {
		return nil, err
	}
	if err := createNotificationsForUsers(ctx, txq, approvers, CreateNotificationInput{
		OrganizationID: orgID, Type: domain.NotificationProgressClaimSubmitted,
		Title: "Onay bekleyen hakediş", Body: row.ClaimNumber,
		EntityType: domain.NotificationEntityProgressClaim, EntityID: id, ProjectID: pid,
		ActionTarget: "/projeler/" + pid.String() + "/taseronlar/" + row.SubcontractID.String() + "/hakedisler/" + claimID,
	}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainProgressClaim(row)
	return &out, nil
}

// CertifySubcontractProgressClaim, spec §18'in "certified immutable"
// kuralını VE §35'in "claim line cumulative overrun race" testini
// karşılar: sertifika ETMEDEN ÖNCE, bu hakedişin HER kalemi için
// previous_progress_amount'ın HÂLÂ doğru olduğunu (aradan başka bir
// hakediş sertifika edilip taban KAYMADIĞINI) yeniden doğrular — kaymışsa
// ErrProgressClaimStale ile REDDEDER (sessizce yanlış sertifikalı rakam
// üretmek yerine, kullanıcıdan hakedişi güncelleyip tekrar denemesini
// ister). Bu, "iki hakediş aynı SOV kalemi için yarışırsa" senaryosunun
// TEK doğru çözümüdür (bkz. docs/subcontracts.md).
func (s *ProjectService) CertifyProgressClaim(ctx context.Context, projectID, claimID, organizationID, userID string) (*domain.SubcontractProgressClaim, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	id, err := repository.StringToUUID(claimID)
	if err != nil {
		return nil, domain.ErrNotFound
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	// Sözleşme satırı, hakedişten ÖNCE kilitlenir (fesih/değişiklik onayı/
	// ödeme de AYNI sözleşme satırını kilitler; sıra her yerde sözleşme ->
	// hakediş). Kilitsiz bir ilk okuma yalnızca sözleşme kimliği içindir.
	// Aksi halde fesih (yalnızca o ana kadar sertifikalı tutarı taahhütte
	// bırakıp kalanı serbest bırakır) ile bu sertifikasyon yarışabilir ya
	// da feshedilmiş sözleşmenin bekleyen hakedişi sonradan sertifikalanıp
	// taahhüt edilenden fazla sertifikalı iş oluşturabilirdi.
	peek, err := txq.GetSubcontractProgressClaim(ctx, sqlc.GetSubcontractProgressClaimParams{ID: id, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	sc, err := txq.GetSubcontractForUpdate(ctx, sqlc.GetSubcontractForUpdateParams{ID: peek.SubcontractID, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}

	current, err := txq.GetSubcontractProgressClaimForUpdate(ctx, sqlc.GetSubcontractProgressClaimForUpdateParams{ID: id, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	if current.Status != domain.ProgressClaimStatusSubmitted {
		return nil, ErrProgressClaimNotCertifiable
	}
	// Tamamlanmış sözleşmenin bekleyen (kesin) hakedişi sertifikalanabilir
	// -- tamamlanma taahhüde dokunmaz. Feshedilmiş sözleşmede ise taahhüt
	// fesih anındaki sertifikalı tutara indirildi; sonradan sertifika o
	// dengeyi bozar.
	if sc.Status != domain.SubcontractStatusActive && sc.Status != domain.SubcontractStatusCompleted {
		return nil, ErrSubcontractNotCertifiable
	}

	items, err := txq.ListSubcontractProgressClaimItemsDetailed(ctx, id)
	if err != nil {
		return nil, err
	}
	caps, err := loadSubcontractClaimCaps(ctx, txq, orgID, pid, sc)
	if err != nil {
		return nil, err
	}
	claimCurrent := make(map[string]decimal.Decimal, len(items))
	for _, it := range items {
		itemID := it.SubcontractItemID.String()
		if caps.certified[itemID].Cmp(repository.NumericToDecimal(it.PreviousProgressAmount)) != 0 {
			return nil, ErrProgressClaimStale
		}
		claimCurrent[itemID] = claimCurrent[itemID].Add(repository.NumericToDecimal(it.CurrentProgressAmount))
	}
	// Hakediş oluşturulduktan SONRA onaylanmış bir eksiltme sınırı
	// düşürmüş olabilir: sertifika anında güncel sınırlar (sözleşme satırı
	// kilitliyken -- değişiklik onayı da aynı satırı kilitler) yeniden
	// kontrol edilir.
	cumulative := make(map[string]decimal.Decimal, len(claimCurrent))
	for itemID, cur := range claimCurrent {
		cumulative[itemID] = caps.certified[itemID].Add(cur)
	}
	if err := caps.checkClaim(cumulative); err != nil {
		return nil, err
	}

	row, err := txq.CertifySubcontractProgressClaim(ctx, sqlc.CertifySubcontractProgressClaimParams{ID: id, OrganizationID: orgID, ProjectID: pid, CertifiedBy: actorUUID(userID)})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrProgressClaimNotCertifiable
		}
		return nil, err
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventProgressClaimCertified, actorUUID(userID),
		map[string]any{"progress_claim_id": claimID, "net_payable": repository.NumericToFloat64(row.NetPayable)}); err != nil {
		return nil, err
	}
	if err := createNotification(ctx, txq, CreateNotificationInput{
		OrganizationID: orgID, UserID: row.CreatedBy, Type: domain.NotificationProgressClaimCertified,
		Title: "Hakediş onaylandı", Body: row.ClaimNumber,
		EntityType: domain.NotificationEntityProgressClaim, EntityID: id, ProjectID: pid,
		ActionTarget: "/projeler/" + pid.String() + "/taseronlar/" + row.SubcontractID.String() + "/hakedisler/" + claimID,
	}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainProgressClaim(row)
	return &out, nil
}

func (s *ProjectService) RejectProgressClaim(ctx context.Context, projectID, claimID, organizationID, userID, reason string) (*domain.SubcontractProgressClaim, error) {
	reason = strings.TrimSpace(reason)
	if reason == "" {
		return nil, ErrProgressClaimReasonRequired
	}
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	id, err := repository.StringToUUID(claimID)
	if err != nil {
		return nil, domain.ErrNotFound
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	row, err := txq.RejectSubcontractProgressClaim(ctx, sqlc.RejectSubcontractProgressClaimParams{
		ID: id, OrganizationID: orgID, ProjectID: pid, RejectedBy: actorUUID(userID), RejectionReason: reason,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrProgressClaimNotRejectable
		}
		return nil, err
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventProgressClaimRejected, actorUUID(userID),
		map[string]any{"progress_claim_id": claimID, "reason": reason}); err != nil {
		return nil, err
	}
	if err := createNotification(ctx, txq, CreateNotificationInput{
		OrganizationID: orgID, UserID: row.CreatedBy, Type: domain.NotificationProgressClaimRejected,
		Title: "Hakediş reddedildi", Body: row.ClaimNumber,
		EntityType: domain.NotificationEntityProgressClaim, EntityID: id, ProjectID: pid,
		ActionTarget: "/projeler/" + pid.String() + "/taseronlar/" + row.SubcontractID.String() + "/hakedisler/" + claimID,
	}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainProgressClaim(row)
	return &out, nil
}

func (s *ProjectService) CancelProgressClaim(ctx context.Context, projectID, claimID, organizationID, userID string) (*domain.SubcontractProgressClaim, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	id, err := repository.StringToUUID(claimID)
	if err != nil {
		return nil, domain.ErrNotFound
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	row, err := txq.CancelSubcontractProgressClaim(ctx, sqlc.CancelSubcontractProgressClaimParams{ID: id, OrganizationID: orgID, ProjectID: pid, CancelledBy: actorUUID(userID)})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrProgressClaimNotCancellable
		}
		return nil, err
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventProgressClaimCancelled, actorUUID(userID),
		map[string]any{"progress_claim_id": claimID}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainProgressClaim(row)
	return &out, nil
}
