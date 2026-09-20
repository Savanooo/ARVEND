package service

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

// ARVEND V2 — Sprint 5: Taşeron Yönetimi. Subcontract yaşam döngüsü + SOV +
// Cost Control commitment entegrasyonu. Sprint 4'ün
// project_purchase_order_service.go'sundaki desenin (FOR UPDATE kilit +
// durum-korumalı UPDATE + tek transaction) BİREBİR uygulanışı, ama
// commitment entegrasyonu PO'dan BİLİNÇLİ OLARAK FARKLI: bkz.
// syncSubcontractCommitments dosya-içi yorumu ve docs/subcontracts.md.

var (
	ErrSubcontractNotEditable      = errors.New("taşeron sözleşmesi yalnızca taslak durumdayken düzenlenebilir")
	ErrSubcontractNotActivatable   = errors.New("taşeron sözleşmesi yalnızca taslak durumdan aktifleştirilebilir")
	ErrSubcontractNotCompletable   = errors.New("taşeron sözleşmesi yalnızca aktif durumdan tamamlanabilir")
	ErrSubcontractNotCancellable   = errors.New("taşeron sözleşmesi yalnızca taslak durumdan iptal edilebilir")
	ErrSubcontractNotTerminable    = errors.New("taşeron sözleşmesi yalnızca aktif durumdan feshedilebilir")
	ErrSubcontractReasonRequired   = errors.New("iptal/fesih gerekçesi zorunludur")
	ErrSubcontractItemsRequired    = errors.New("taşeron sözleşmesinin en az bir SOV kalemi olmalıdır")
	ErrSubcontractSupplierInactive = errors.New("tedarikçi aktif değil")
)

// SubcontractItemInput, tek bir SOV kalemi girişidir. Quantity/Unit/
// UnitPrice'ın ÜÇÜ de opsiyoneldir (spec §9: toplu/lump-sum kalemler) --
// OriginalAmount HER ZAMAN zorunludur (ikisi de doluysa SQL'de yeniden
// hesaplanır, aksi halde bu değer OLDUĞU GİBİ kullanılır).
type SubcontractItemInput struct {
	WBSNodeID      string
	CostCodeID     string
	BudgetLineID   string
	Description    string
	Quantity       *float64
	Unit           string
	UnitPrice      *float64
	OriginalAmount float64
}

type SubcontractInput struct {
	SupplierID            string
	Title                 string
	ScopeSummary          string
	EffectiveDate         *time.Time
	StartDate             *time.Time
	PlannedCompletionDate *time.Time
	RetentionPercent      *float64
	AdvanceAmount         *float64
	PaymentTerms          string
	Notes                 string
	Items                 []SubcontractItemInput
	UserID                string
}

func (s *ProjectService) generateSubcontractNo(ctx context.Context, q *sqlc.Queries, orgID pgtype.UUID) (string, error) {
	year := time.Now().Year()
	seq, err := q.NextSubcontractSeq(ctx, sqlc.NextSubcontractSeqParams{OrganizationID: orgID, Year: int32(year)})
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("SC-%d-%04d", year, seq), nil
}

func insertSubcontractItems(ctx context.Context, txq *sqlc.Queries, orgID, pid, subcontractID pgtype.UUID, items []SubcontractItemInput) error {
	if err := txq.DeleteSubcontractItems(ctx, sqlc.DeleteSubcontractItemsParams{SubcontractID: subcontractID, OrganizationID: orgID, ProjectID: pid}); err != nil {
		return err
	}
	for i, it := range items {
		wbsID, err := resolveWBSParentRef(ctx, txq, it.WBSNodeID, pid, orgID)
		if err != nil {
			return err
		}
		if strings.TrimSpace(it.CostCodeID) == "" {
			return ErrInvalidBudgetLineCostCode
		}
		costCodeID, err := resolveCostCodeRef(ctx, txq, it.CostCodeID, orgID)
		if err != nil {
			return err
		}
		budgetLineID, err := resolveBudgetLineRef(ctx, txq, it.BudgetLineID, pid, orgID)
		if err != nil {
			return err
		}
		desc := strings.TrimSpace(it.Description)
		// original_amount, quantity+unit_price İKİSİ de doluysa SQL'de
		// yeniden hesaplanır (bkz. CreateSubcontractItem CASE'i) -- bu
		// yüzden Go seviyesindeki doğrulama, İKİSİ birden verilmişse
		// pozitifliği ONLARDAN, aksi halde doğrudan gönderilen
		// OriginalAmount'tan kontrol eder (project_budget_lines İLE AYNI
		// "kısmi doluluk" kuralı, bkz. docs/cost-control.md §6).
		effectiveAmount := it.OriginalAmount
		if it.Quantity != nil && it.UnitPrice != nil {
			effectiveAmount = *it.Quantity * *it.UnitPrice
		}
		if desc == "" || effectiveAmount <= 0 {
			return ErrInvalidAmount
		}
		if _, err := txq.CreateSubcontractItem(ctx, sqlc.CreateSubcontractItemParams{
			OrganizationID: orgID, ProjectID: pid, SubcontractID: subcontractID,
			WbsNodeID: wbsID, CostCodeID: costCodeID, BudgetLineID: budgetLineID,
			Description: desc, Quantity: repository.Float64PtrToNumeric(it.Quantity), Unit: it.Unit,
			UnitPrice: repository.Float64PtrToNumeric(it.UnitPrice), Column11: repository.Float64ToNumeric(it.OriginalAmount),
			SortOrder: int32(i),
		}); err != nil {
			return err
		}
	}
	return nil
}

func (s *ProjectService) CreateSubcontract(ctx context.Context, projectID, organizationID string, in SubcontractInput) (*domain.Subcontract, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	if len(in.Items) == 0 {
		return nil, ErrSubcontractItemsRequired
	}
	supplierID, err := repository.StringToUUID(in.SupplierID)
	if err != nil {
		return nil, domain.ErrNotFound
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

	supplier, err := txq.GetSupplier(ctx, sqlc.GetSupplierParams{ID: supplierID, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	if !supplier.IsActive {
		return nil, ErrSubcontractSupplierInactive
	}

	title := strings.TrimSpace(in.Title)
	if title == "" {
		return nil, ErrInvalidAmount
	}

	scNo, err := s.generateSubcontractNo(ctx, txq, orgID)
	if err != nil {
		return nil, err
	}

	row, err := txq.CreateSubcontract(ctx, sqlc.CreateSubcontractParams{
		OrganizationID: orgID, ProjectID: pid, SubcontractNo: scNo, SupplierID: supplierID,
		Title: title, ScopeSummary: in.ScopeSummary, Currency: project.Currency,
		EffectiveDate: dateFromPtr(in.EffectiveDate), StartDate: dateFromPtr(in.StartDate),
		PlannedCompletionDate: dateFromPtr(in.PlannedCompletionDate),
		RetentionPercent:      repository.Float64PtrToNumeric(in.RetentionPercent),
		AdvanceAmount:         repository.Float64PtrToNumeric(in.AdvanceAmount),
		PaymentTerms:          in.PaymentTerms, Notes: in.Notes, CreatedBy: actorUUID(in.UserID),
	})
	if err != nil {
		return nil, err
	}

	if err := insertSubcontractItems(ctx, txq, orgID, pid, row.ID, in.Items); err != nil {
		return nil, err
	}
	row, err = txq.RecomputeSubcontractTotal(ctx, sqlc.RecomputeSubcontractTotalParams{ID: row.ID, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		return nil, err
	}

	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventSubcontractCreated, actorUUID(in.UserID),
		map[string]any{"subcontract_id": row.ID.String(), "subcontract_no": row.SubcontractNo}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainSubcontract(row)
	return &out, nil
}

func (s *ProjectService) ListSubcontracts(ctx context.Context, projectID, organizationID string) ([]repository.SubcontractDetailed, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	rows, err := s.q.ListSubcontractsDetailed(ctx, sqlc.ListSubcontractsDetailedParams{ProjectID: pid, OrganizationID: orgID})
	if err != nil {
		return nil, err
	}
	out := make([]repository.SubcontractDetailed, len(rows))
	for i, r := range rows {
		out[i] = repository.ToDomainSubcontractDetailedFromList(r)
	}
	return out, nil
}

func (s *ProjectService) GetSubcontract(ctx context.Context, projectID, subcontractID, organizationID string) (*repository.SubcontractDetailed, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	id, err := repository.StringToUUID(subcontractID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	row, err := s.q.GetSubcontractDetailed(ctx, sqlc.GetSubcontractDetailedParams{ID: id, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	out := repository.ToDomainSubcontractDetailedFromGet(row)
	return &out, nil
}

func (s *ProjectService) ListSubcontractItems(ctx context.Context, projectID, subcontractID, organizationID string) ([]domain.SubcontractItem, error) {
	if _, err := s.GetSubcontract(ctx, projectID, subcontractID, organizationID); err != nil {
		return nil, err
	}
	id, _ := repository.StringToUUID(subcontractID)
	rows, err := s.q.ListSubcontractItems(ctx, id)
	if err != nil {
		return nil, err
	}
	out := make([]domain.SubcontractItem, len(rows))
	for i, r := range rows {
		out[i] = repository.ToDomainSubcontractItem(r)
	}
	return out, nil
}

// GetSubcontractValue, current_subcontract_value + kalan taahhüt
// metriklerini döner (spec §8, §24) -- Cost Control'ün Committed'inden
// AYRI, yalnızca bu sözleşmenin kendi detay ekranında gösterilen
// bilgilendirici bir özet.
type SubcontractValueSummary struct {
	repository.SubcontractValue
	CertifiedToDate     float64
	RemainingCommitment float64
	// Sprint 5 follow-up (bkz. migration 0039): PaidToDate = voidlenmemiş
	// subcontract_payments toplamı. RemainingPayable = CertifiedToDate -
	// PaidToDate -- RemainingCommitment'tan (CurrentValue - CertifiedToDate)
	// KASITLI OLARAK FARKLI bir eksendir ve BİLİNÇLİ OLARAK 0'a
	// kelepçelenmez: negatif bir değer avans/fazla ödeme anlamına gelir,
	// bu anlamlı bir sinyaldir (gizlenmemelidir). Sertifikasyon ödeme
	// DEĞİLDİR -- bir hakediş hiç ödenmeden sertifika edilebilir
	// (RemainingPayable o zaman CertifiedToDate'e eşit kalır), bir ödeme de
	// hiçbir hakedişe bağlı olmadan (avans) yapılabilir (PaidToDate o zaman
	// CertifiedToDate'i AŞABİLİR, RemainingPayable negatif olur).
	PaidToDate       float64
	RemainingPayable float64
}

func (s *ProjectService) GetSubcontractValue(ctx context.Context, projectID, subcontractID, organizationID string) (*SubcontractValueSummary, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	id, err := repository.StringToUUID(subcontractID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	valueRow, err := s.q.GetSubcontractCurrentValue(ctx, sqlc.GetSubcontractCurrentValueParams{ID: id, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	certified, err := s.q.GetSubcontractCertifiedToDate(ctx, sqlc.GetSubcontractCertifiedToDateParams{SubcontractID: id, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		return nil, err
	}
	paid, err := s.q.GetSubcontractPaidToDate(ctx, sqlc.GetSubcontractPaidToDateParams{SubcontractID: id, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		return nil, err
	}
	val := repository.ToDomainSubcontractValue(valueRow)
	certifiedF := repository.NumericToFloat64(certified)
	paidF := repository.NumericToFloat64(paid)
	remaining := val.CurrentValue - certifiedF
	if remaining < 0 {
		remaining = 0
	}
	return &SubcontractValueSummary{
		SubcontractValue: val, CertifiedToDate: certifiedF, RemainingCommitment: remaining,
		PaidToDate: paidF, RemainingPayable: certifiedF - paidF,
	}, nil
}

func (s *ProjectService) UpdateSubcontractDraft(ctx context.Context, projectID, subcontractID, organizationID string, in SubcontractInput) (*domain.Subcontract, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	id, err := repository.StringToUUID(subcontractID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	if len(in.Items) == 0 {
		return nil, ErrSubcontractItemsRequired
	}
	supplierID, err := repository.StringToUUID(in.SupplierID)
	if err != nil {
		return nil, domain.ErrNotFound
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	current, err := txq.GetSubcontractForUpdate(ctx, sqlc.GetSubcontractForUpdateParams{ID: id, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	if current.Status != domain.SubcontractStatusDraft {
		return nil, ErrSubcontractNotEditable
	}

	title := strings.TrimSpace(in.Title)
	if title == "" {
		return nil, ErrInvalidAmount
	}

	row, err := txq.UpdateSubcontractDraft(ctx, sqlc.UpdateSubcontractDraftParams{
		ID: id, OrganizationID: orgID, ProjectID: pid, SupplierID: supplierID,
		Title: title, ScopeSummary: in.ScopeSummary, Currency: current.Currency,
		EffectiveDate: dateFromPtr(in.EffectiveDate), StartDate: dateFromPtr(in.StartDate),
		PlannedCompletionDate: dateFromPtr(in.PlannedCompletionDate),
		RetentionPercent:      repository.Float64PtrToNumeric(in.RetentionPercent),
		AdvanceAmount:         repository.Float64PtrToNumeric(in.AdvanceAmount),
		PaymentTerms:          in.PaymentTerms, Notes: in.Notes,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrSubcontractNotEditable
		}
		return nil, err
	}

	if err := insertSubcontractItems(ctx, txq, orgID, pid, id, in.Items); err != nil {
		return nil, err
	}
	row, err = txq.RecomputeSubcontractTotal(ctx, sqlc.RecomputeSubcontractTotalParams{ID: id, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		return nil, err
	}

	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventSubcontractUpdated, actorUUID(in.UserID),
		map[string]any{"subcontract_id": id.String()}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainSubcontract(row)
	return &out, nil
}

// ---------- Cost Control Commitment Senkronizasyonu ----------
//
// PO'nun İTEM-seviyesi, KALICI/tek-seferlik commitment modelinden BİLİNÇLİ
// SAPMA: bir Subcontract'ın taahhüdü değişiklik emirleri/fesihle YAŞAM
// BOYU DEĞİŞEBİLİR. Bu yüzden source_id = project_subcontracts.id
// (SÖZLEŞME seviyesinde, PO'daki gibi kalem seviyesinde DEĞİL) kullanılır
// ve HER ticari olayda (aktivasyon/değişiklik onayı/fesih) bu fonksiyon:
//  1. Bu sözleşmeden doğan TÜM aktif commitment'ları voidler (idempotent --
//     zaten voided olanlar status='active' koşuluyla dışlanır).
//  2. targets'taki HER (cost_code, budget_line) grubu için (yalnızca
//     pozitif net tutarlı gruplar, sorgular zaten bunu garantiler) TEK bir
//     YENİ commitment satırı oluşturur.
//
// Negatif/kısmi commitment MUTASYONU İCAT EDİLMEDİ -- yalnızca var olan
// void+create deseni (PO'nun CancelPurchaseOrder'ı İLE AYNI) tekrar
// kullanılır. Bkz. docs/subcontracts.md §Commitment Entegrasyonu.
func (s *ProjectService) syncSubcontractCommitments(
	ctx context.Context, txq *sqlc.Queries, orgID, pid, subcontractID pgtype.UUID,
	targets []repository.CostCodeTarget, currency, description string, userID string,
) error {
	if _, err := txq.VoidCommitmentsBySourceSubcontract(ctx, sqlc.VoidCommitmentsBySourceSubcontractParams{
		OrganizationID: orgID, ProjectID: pid, SourceID: subcontractID,
		VoidedBy: actorUUID(userID), VoidReason: "Taşeron taahhüdü yeniden senkronize edildi: " + description,
	}); err != nil {
		return err
	}
	now := repository.TimeToDate(time.Now())
	for _, t := range targets {
		if t.Amount <= 0 {
			continue
		}
		costCodeID, err := repository.StringToUUID(t.CostCodeID)
		if err != nil {
			return err
		}
		var budgetLineID pgtype.UUID
		if t.BudgetLineID != nil {
			budgetLineID, err = repository.StringToUUID(*t.BudgetLineID)
			if err != nil {
				return err
			}
		}
		if _, err := txq.CreateCommitmentFromSource(ctx, sqlc.CreateCommitmentFromSourceParams{
			OrganizationID: orgID, ProjectID: pid, BudgetLineID: budgetLineID, CostCodeID: costCodeID,
			SourceType: domain.CommitmentSourceSubcontract, SourceID: subcontractID,
			Description: description, CommittedAmount: repository.Float64ToNumeric(t.Amount),
			Currency: currency, CommittedAt: now, CreatedBy: actorUUID(userID),
		}); err != nil {
			return err
		}
	}
	return nil
}

func (s *ProjectService) currentSubcontractTargets(ctx context.Context, txq *sqlc.Queries, orgID, pid, subcontractID pgtype.UUID) ([]repository.CostCodeTarget, error) {
	itemRows, err := txq.ListSubcontractItemTotalsByCostCode(ctx, sqlc.ListSubcontractItemTotalsByCostCodeParams{
		SubcontractID: subcontractID, OrganizationID: orgID, ProjectID: pid,
	})
	if err != nil {
		return nil, err
	}
	changeRows, err := txq.ListApprovedSubcontractChangeItemTotalsByCostCode(ctx, sqlc.ListApprovedSubcontractChangeItemTotalsByCostCodeParams{
		SubcontractID: subcontractID, OrganizationID: orgID, ProjectID: pid,
	})
	if err != nil {
		return nil, err
	}
	type key struct {
		costCode   string
		budgetLine string
	}
	net := map[key]float64{}
	order := []key{}
	for _, r := range itemRows {
		k := key{costCode: r.CostCodeID.String(), budgetLine: uuidKeyPart(r.BudgetLineID)}
		if _, ok := net[k]; !ok {
			order = append(order, k)
		}
		net[k] += repository.NumericToFloat64(r.Total)
	}
	for _, r := range changeRows {
		k := key{costCode: r.CostCodeID.String(), budgetLine: uuidKeyPart(r.BudgetLineID)}
		if _, ok := net[k]; !ok {
			order = append(order, k)
		}
		net[k] += repository.NumericToFloat64(r.Total)
	}
	out := make([]repository.CostCodeTarget, 0, len(order))
	for _, k := range order {
		amt := net[k]
		if amt <= 0 {
			continue
		}
		t := repository.CostCodeTarget{CostCodeID: k.costCode, Amount: amt}
		if k.budgetLine != "" {
			bl := k.budgetLine
			t.BudgetLineID = &bl
		}
		out = append(out, t)
	}
	return out, nil
}

func uuidKeyPart(id pgtype.UUID) string {
	if !id.Valid {
		return ""
	}
	return id.String()
}

func (s *ProjectService) ActivateSubcontract(ctx context.Context, projectID, subcontractID, organizationID, userID string) (*domain.Subcontract, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	id, err := repository.StringToUUID(subcontractID)
	if err != nil {
		return nil, domain.ErrNotFound
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	current, err := txq.GetSubcontractForUpdate(ctx, sqlc.GetSubcontractForUpdateParams{ID: id, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	if current.Status != domain.SubcontractStatusDraft {
		return nil, ErrSubcontractNotActivatable
	}
	items, err := txq.ListSubcontractItems(ctx, id)
	if err != nil {
		return nil, err
	}
	if len(items) == 0 {
		return nil, ErrSubcontractItemsRequired
	}

	row, err := txq.ActivateSubcontract(ctx, sqlc.ActivateSubcontractParams{ID: id, OrganizationID: orgID, ProjectID: pid, ActivatedBy: actorUUID(userID)})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrSubcontractNotActivatable
		}
		return nil, err
	}

	targets, err := s.currentSubcontractTargets(ctx, txq, orgID, pid, id)
	if err != nil {
		return nil, err
	}
	desc := fmt.Sprintf("Taşeron %s — %s", row.SubcontractNo, row.Title)
	if err := s.syncSubcontractCommitments(ctx, txq, orgID, pid, id, targets, row.Currency, desc, userID); err != nil {
		return nil, err
	}

	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventSubcontractActivated, actorUUID(userID),
		map[string]any{"subcontract_id": subcontractID}); err != nil {
		return nil, err
	}
	if err := createNotification(ctx, txq, CreateNotificationInput{
		OrganizationID: orgID, UserID: row.CreatedBy, Type: domain.NotificationSubcontractActivated,
		Title: "Taşeron sözleşmesi aktifleşti", Body: row.SubcontractNo,
		EntityType: domain.NotificationEntitySubcontract, EntityID: id, ProjectID: pid,
		ActionTarget: "/projeler/" + pid.String() + "/taseronlar/" + subcontractID,
	}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainSubcontract(row)
	return &out, nil
}

func (s *ProjectService) CompleteSubcontract(ctx context.Context, projectID, subcontractID, organizationID, userID string) (*domain.Subcontract, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	id, err := repository.StringToUUID(subcontractID)
	if err != nil {
		return nil, domain.ErrNotFound
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	// Tamamlanma, commitment'a KESİNLİKLE DOKUNMAZ (PO'nun "closed"ıyla AYNI
	// ilke, bkz. docs/subcontracts.md) -- tam güncel değer, gerçek bir
	// Tedarikçi Faturası/AP kaydı onun yerini alana kadar taahhüt olarak
	// kalır.
	row, err := txq.CompleteSubcontract(ctx, sqlc.CompleteSubcontractParams{ID: id, OrganizationID: orgID, ProjectID: pid, CompletedBy: actorUUID(userID)})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			if _, gerr := txq.GetSubcontract(ctx, sqlc.GetSubcontractParams{ID: id, OrganizationID: orgID, ProjectID: pid}); gerr != nil {
				return nil, domain.ErrNotFound
			}
			return nil, ErrSubcontractNotCompletable
		}
		return nil, err
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventSubcontractCompleted, actorUUID(userID),
		map[string]any{"subcontract_id": subcontractID}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainSubcontract(row)
	return &out, nil
}

func (s *ProjectService) CancelSubcontract(ctx context.Context, projectID, subcontractID, organizationID, userID, reason string) (*domain.Subcontract, error) {
	reason = strings.TrimSpace(reason)
	if reason == "" {
		return nil, ErrSubcontractReasonRequired
	}
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	id, err := repository.StringToUUID(subcontractID)
	if err != nil {
		return nil, domain.ErrNotFound
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	// CancelSubcontract SQL'i YALNIZCA status='draft'tan çalışır (spec §7/
	// §15: "DRAFT cancelled: commitment hiç oluşmamış olmalı") -- bu yüzden
	// burada commitment senkronizasyonuna HİÇ gerek yoktur (henüz hiçbiri
	// yok), Sprint 4'ün PO'sundaki "wasApproved" dalının aksine.
	row, err := txq.CancelSubcontract(ctx, sqlc.CancelSubcontractParams{
		ID: id, OrganizationID: orgID, ProjectID: pid, CancelledBy: actorUUID(userID), CancelReason: reason,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrSubcontractNotCancellable
		}
		return nil, err
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventSubcontractCancelled, actorUUID(userID),
		map[string]any{"subcontract_id": subcontractID, "reason": reason}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainSubcontract(row)
	return &out, nil
}

// TerminateSubcontract, spec §15/§39'un tam uygulanışıdır: "earned/
// certified amount korunur, remaining unperformed commitment release
// edilir". Fesih sonrası, yalnızca ŞU ANA KADAR sertifikalı (certified)
// hakedişlerin kümülatif tutarı maliyet-kodu bazında taahhüt olarak
// KALIR — henüz sertifika edilmemiş (performe edilmemiş) kısım tamamen
// SERBEST BIRAKILIR. Sertifikalı hakediş KAYITLARININ KENDİSİ (subcontract_
// progress_claims) bu işlemden HİÇ ETKİLENMEZ, DOKUNULMAZ — yalnızca
// project_commitments senkronize edilir.
func (s *ProjectService) TerminateSubcontract(ctx context.Context, projectID, subcontractID, organizationID, userID, reason string) (*domain.Subcontract, error) {
	reason = strings.TrimSpace(reason)
	if reason == "" {
		return nil, ErrSubcontractReasonRequired
	}
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	id, err := repository.StringToUUID(subcontractID)
	if err != nil {
		return nil, domain.ErrNotFound
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	row, err := txq.TerminateSubcontract(ctx, sqlc.TerminateSubcontractParams{
		ID: id, OrganizationID: orgID, ProjectID: pid, TerminatedBy: actorUUID(userID), TerminationReason: reason,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrSubcontractNotTerminable
		}
		return nil, err
	}

	termRows, err := txq.GetSubcontractTerminationTargets(ctx, sqlc.GetSubcontractTerminationTargetsParams{
		SubcontractID: id, OrganizationID: orgID, ProjectID: pid,
	})
	if err != nil {
		return nil, err
	}
	targets := make([]repository.CostCodeTarget, len(termRows))
	for i, r := range termRows {
		t := repository.CostCodeTarget{CostCodeID: r.CostCodeID.String(), Amount: repository.NumericToFloat64(r.NetAmount)}
		if r.BudgetLineID.Valid {
			bl := r.BudgetLineID.String()
			t.BudgetLineID = &bl
		}
		targets[i] = t
	}
	desc := fmt.Sprintf("Taşeron %s feshedildi — kalan sertifikalı taahhüt: %s", row.SubcontractNo, reason)
	if err := s.syncSubcontractCommitments(ctx, txq, orgID, pid, id, targets, row.Currency, desc, userID); err != nil {
		return nil, err
	}

	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventSubcontractTerminated, actorUUID(userID),
		map[string]any{"subcontract_id": subcontractID, "reason": reason}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainSubcontract(row)
	return &out, nil
}

// ListCommitmentsForSubcontract, sözleşme detay ekranının "bağlı
// taahhütler" bölümünü besler (PO'nun ListCommitmentsForPurchaseOrder'ı
// İLE AYNI şeffaflık ilkesi).
func (s *ProjectService) ListCommitmentsForSubcontract(ctx context.Context, projectID, subcontractID, organizationID string) ([]domain.Commitment, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	id, err := repository.StringToUUID(subcontractID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	rows, err := s.q.ListCommitmentsBySourceSubcontract(ctx, sqlc.ListCommitmentsBySourceSubcontractParams{
		OrganizationID: orgID, ProjectID: pid, SourceID: id,
	})
	if err != nil {
		return nil, err
	}
	out := make([]domain.Commitment, len(rows))
	for i, r := range rows {
		out[i] = repository.ToDomainCommitment(r)
	}
	return out, nil
}

func dateFromPtr(t *time.Time) pgtype.Date {
	if t == nil {
		return pgtype.Date{}
	}
	return repository.TimeToDate(*t)
}
