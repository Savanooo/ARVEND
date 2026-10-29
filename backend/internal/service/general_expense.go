package service

import (
	"context"
	"errors"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

// Genel (projesiz) masraf (migration 0068, ürün sahibinin isteği 2026-10):
// "masraf girerken illa proje seçmeyeyim; masraflar tek yerde olsun".
// Projeli masrafın kuralları aynen geçerlidir (bkz. project_expense_own.go,
// project_expense_approval.go):
//   - herkes (projects.expenses.create) girer, masraf onay bekler;
//   - onayı projects.expenses.approve (Sahip/Yönetici) verir, kimse kendi
//     masrafına karar veremez (Sahip hariç);
//   - projects.finance.manage her genel masrafı düzenler/iptal eder, diğerleri
//     yalnızca kendi bekleyen/reddedilen masrafını.
// Proje bağları (ek iş, maliyet kodu, bütçe kalemi) genel masrafta yoktur.
// Olaylar organization_events'e yazılır (proje yok).

const (
	OrgEventGeneralExpenseAdded    = "general_expense_added"
	OrgEventGeneralExpenseUpdated  = "general_expense_updated"
	OrgEventGeneralExpenseVoided   = "general_expense_voided"
	OrgEventGeneralExpenseApproved = "general_expense_approved"
	OrgEventGeneralExpenseRejected = "general_expense_rejected"
)

// pendingExpensesTarget: onay bildiriminin açtığı yer -- mobil "Masraflar"
// ekranı, "Onay bekliyor" süzgeciyle. Finans okuma izni olmayan onaylayıcı
// da orada karar vereceği masrafları görür (ListExpensesFilter.
// ApproverScope); projenin Finans görünümünü ise göremez.
const pendingExpensesTarget = "/diger/masraflar?durum=pending"

var ErrGeneralExpenseNotFound error = &NotFoundError{What: "genel masraf"}

// CreateGeneralExpense: projesiz masraf girer (onay bekler). Para birimi
// boşsa TRY. Proje bağı gönderilirse reddedilir.
func (s *ProjectService) CreateGeneralExpense(ctx context.Context, organizationID string, in ExpenseInput) (*domain.Expense, error) {
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	currency, err := validateGeneralExpense(in)
	if err != nil {
		return nil, err
	}
	actor := actorUUID(in.UserID)

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	key := strings.TrimSpace(in.IdempotencyKey)
	var keyPtr *string
	if key != "" {
		keyPtr = &key
		existing, err := txq.GetGeneralExpenseByIdempotencyKey(ctx, sqlc.GetGeneralExpenseByIdempotencyKeyParams{
			OrganizationID: orgID, IdempotencyKey: &key,
		})
		switch {
		case err == nil:
			if existing.CreatedBy != actor {
				return nil, ErrExpenseIdempotencyKeyInUse
			}
			out := repository.ToDomainExpense(existing)
			return &out, nil
		case !errors.Is(err, pgx.ErrNoRows):
			return nil, err
		}
	}
	approval := domain.ExpenseApprovalPending
	if in.PreApproved {
		approval = domain.ExpenseApprovalApproved
	}
	row, err := txq.CreateGeneralExpense(ctx, sqlc.CreateGeneralExpenseParams{
		OrganizationID: orgID, Category: in.Category, Description: strings.TrimSpace(in.Description),
		Amount: repository.Float64ToNumeric(in.Amount), Currency: currency,
		ExpenseDate: repository.TimeToDate(in.ExpenseDate), SupplierName: strings.TrimSpace(in.SupplierName),
		InvoiceNo: strings.TrimSpace(in.InvoiceNo), Notes: strings.TrimSpace(in.Notes),
		IdempotencyKey: keyPtr, CreatedBy: actor, ApprovalStatus: approval,
		VatRate: repository.Float64PtrToNumeric(in.VATRate),
	})
	if err != nil {
		if key != "" && isUniqueViolation(err) {
			if existing, gerr := s.q.GetGeneralExpenseByIdempotencyKey(ctx, sqlc.GetGeneralExpenseByIdempotencyKeyParams{
				OrganizationID: orgID, IdempotencyKey: &key,
			}); gerr == nil {
				if existing.CreatedBy != actor {
					return nil, ErrExpenseIdempotencyKeyInUse
				}
				out := repository.ToDomainExpense(existing)
				return &out, nil
			}
		}
		return nil, err
	}
	if err := logOrgEvent(ctx, txq, orgID, OrgEventGeneralExpenseAdded, actor, expenseEventMetadata(row.ID.String(), in)); err != nil {
		return nil, err
	}
	if !in.PreApproved {
		if err := notifyGeneralExpensePending(ctx, txq, orgID, row, actor); err != nil {
			return nil, err
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainExpense(row)
	return &out, nil
}

// UpdateGeneralExpense: satırı bütünüyle yeniden yazar; masraf yeniden onay
// bekler. in.OwnOnly ise yalnızca kişinin kendi bekleyen/reddedilen masrafı.
func (s *ProjectService) UpdateGeneralExpense(ctx context.Context, expenseID, organizationID string, in ExpenseInput) (*domain.Expense, error) {
	eid, orgID, err := generalExpenseIDs(expenseID, organizationID)
	if err != nil {
		return nil, err
	}
	currency, err := validateGeneralExpense(in)
	if err != nil {
		return nil, err
	}
	actor := actorUUID(in.UserID)

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	current, err := lockGeneralExpense(ctx, txq, eid, orgID)
	if err != nil {
		return nil, err
	}
	if err := checkGeneralExpenseWritable(current, actor, in.OwnOnly); err != nil {
		return nil, err
	}
	row, err := txq.UpdateGeneralExpense(ctx, sqlc.UpdateGeneralExpenseParams{
		Category: in.Category, Description: strings.TrimSpace(in.Description),
		Amount: repository.Float64ToNumeric(in.Amount), Currency: currency,
		ExpenseDate: repository.TimeToDate(in.ExpenseDate), SupplierName: strings.TrimSpace(in.SupplierName),
		InvoiceNo: strings.TrimSpace(in.InvoiceNo), Notes: strings.TrimSpace(in.Notes),
		VatRate: repository.Float64PtrToNumeric(in.VATRate), ID: eid, OrganizationID: orgID,
	})
	if err != nil {
		return nil, err
	}
	if err := logOrgEvent(ctx, txq, orgID, OrgEventGeneralExpenseUpdated, actor, expenseEventMetadata(expenseID, in)); err != nil {
		return nil, err
	}
	if err := notifyGeneralExpensePending(ctx, txq, orgID, row, actor); err != nil {
		return nil, err
	}
	out := repository.ToDomainExpense(row)
	if out.Attachments, err = listAttachments(ctx, txq, orgID, eid); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	return &out, nil
}

// VoidGeneralExpense: genel masrafı iptal eder (kayıt silinmez). ownOnly ise
// kişi yalnızca kendi bekleyen/reddedilen masrafını geri çeker.
func (s *ProjectService) VoidGeneralExpense(ctx context.Context, expenseID, organizationID, userID, reason string, ownOnly bool) (*domain.Expense, error) {
	eid, orgID, err := generalExpenseIDs(expenseID, organizationID)
	if err != nil {
		return nil, err
	}
	actor := actorUUID(userID)
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	current, err := lockGeneralExpense(ctx, txq, eid, orgID)
	if err != nil {
		return nil, err
	}
	if err := checkGeneralExpenseWritable(current, actor, ownOnly); err != nil {
		return nil, err
	}
	reason = strings.TrimSpace(reason)
	row, err := txq.VoidGeneralExpense(ctx, sqlc.VoidGeneralExpenseParams{
		VoidedBy: actor, VoidReason: reason, ID: eid, OrganizationID: orgID,
	})
	if err != nil {
		return nil, err
	}
	if err := logOrgEvent(ctx, txq, orgID, OrgEventGeneralExpenseVoided, actor,
		map[string]any{"expense_id": expenseID, "reason": reason, "withdrawn": ownOnly}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainExpense(row)
	return &out, nil
}

// ApproveGeneralExpense / RejectGeneralExpense: projeli masraf kararıyla
// aynı kurallar (ret gerekçesi zorunlu, kendi masrafına karar yok -- Sahip
// hariç).
func (s *ProjectService) ApproveGeneralExpense(ctx context.Context, expenseID, organizationID, userID string) (*domain.Expense, error) {
	return s.decideGeneralExpense(ctx, expenseID, organizationID, userID, true, "")
}

func (s *ProjectService) RejectGeneralExpense(ctx context.Context, expenseID, organizationID, userID, reason string) (*domain.Expense, error) {
	return s.decideGeneralExpense(ctx, expenseID, organizationID, userID, false, reason)
}

func (s *ProjectService) decideGeneralExpense(ctx context.Context, expenseID, organizationID, userID string, approve bool, reason string) (*domain.Expense, error) {
	eid, orgID, err := generalExpenseIDs(expenseID, organizationID)
	if err != nil {
		return nil, err
	}
	reason = strings.TrimSpace(reason)
	status, eventType := domain.ExpenseApprovalApproved, OrgEventGeneralExpenseApproved
	if !approve {
		status, eventType = domain.ExpenseApprovalRejected, OrgEventGeneralExpenseRejected
		if reason == "" {
			return nil, ErrExpenseRejectReasonRequired
		}
		if utf8.RuneCountInString(reason) > domain.ExpenseDecisionNoteMaxLen {
			return nil, ErrExpenseRejectReasonTooLong
		}
	} else {
		reason = ""
	}
	actor := actorUUID(userID)

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	current, err := lockGeneralExpense(ctx, txq, eid, orgID)
	if err != nil {
		return nil, err
	}
	switch {
	case current.VoidedAt.Valid:
		return nil, ErrAlreadyVoided
	case current.ApprovalStatus != domain.ExpenseApprovalPending:
		return nil, ErrExpenseNotPending
	}
	if actor.Valid && current.CreatedBy == actor {
		owner, err := isOrganizationOwner(ctx, txq, actor, orgID)
		if err != nil {
			return nil, err
		}
		if !owner {
			return nil, ErrOwnExpenseDecision
		}
	}
	row, err := txq.DecideGeneralExpense(ctx, sqlc.DecideGeneralExpenseParams{
		ApprovalStatus: status, DecidedBy: actor, DecisionNote: reason, ID: eid, OrganizationID: orgID,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrExpenseNotPending
		}
		return nil, err
	}
	meta := map[string]any{"expense_id": expenseID, "amount": repository.NumericToFloat64(row.Amount)}
	if !approve {
		meta["reason"] = reason
	}
	if err := logOrgEvent(ctx, txq, orgID, eventType, actor, meta); err != nil {
		return nil, err
	}
	if err := notifyGeneralExpenseDecision(ctx, txq, orgID, row, actor); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainExpense(row)
	return &out, nil
}

// ExpenseListFilter: GET /expenses süzgeçleri (bkz. ListExpensesFiltered).
type ExpenseListFilter struct {
	Kind      string // "" | general | project
	Status    string // "" | pending | approved | rejected | voided
	ProjectID string
	DateFrom  *time.Time
	DateTo    *time.Time
	// OnlyCreatedBy doluysa yalnızca o kişinin girdikleri.
	OnlyCreatedBy string
	// ApproverScope (OnlyCreatedBy ile birlikte): finans okuma izni olmayan
	// onaylayıcı -- kendi masraflarına ek olarak karar verebileceği
	// (onay bekleyen) ve son domain.ExpenseApproverRecentDays günde karara
	// bağlanmış masraflar. Bildirim onaylayıcıyı bu listeye getiriyor;
	// eskiden yalnızca kendi masraflarını gördüğü için onaylayacağı masrafı
	// bulamıyordu.
	ApproverScope bool
	// RestrictToUserID: üyelikle sınırlı rolde projeli satırlar yalnızca
	// üyesi olduğu projelerden.
	RestrictToUserID string
}

var ErrInvalidExpenseFilter = errors.New("geçersiz masraf süzgeci")

// ListExpensesAll: "Masraflar" ekranı -- projeli ve genel masraflar,
// en yeni masraf tarihi önce, en fazla domain.ExpensesListLimit.
func (s *ProjectService) ListExpensesAll(ctx context.Context, organizationID string, f ExpenseListFilter) ([]domain.MyExpense, error) {
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	switch f.Kind {
	case "", "general", "project":
	default:
		return nil, ErrInvalidExpenseFilter
	}
	switch f.Status {
	case "", "voided", domain.ExpenseApprovalPending, domain.ExpenseApprovalApproved, domain.ExpenseApprovalRejected:
	default:
		return nil, ErrInvalidExpenseFilter
	}
	params := sqlc.ListExpensesFilteredParams{
		OrganizationID: orgID, Kind: f.Kind, Status: f.Status,
		DateFrom: repository.TimePtrToDate(f.DateFrom), DateTo: repository.TimePtrToDate(f.DateTo),
		RowLimit: domain.ExpensesListLimit,
	}
	for _, p := range []struct {
		raw string
		dst *pgtype.UUID
	}{{f.ProjectID, &params.ProjectID}, {f.OnlyCreatedBy, &params.CreatedBy}, {f.RestrictToUserID, &params.RestrictToUserID}} {
		if strings.TrimSpace(p.raw) == "" {
			continue
		}
		if *p.dst, err = repository.StringToUUID(p.raw); err != nil {
			return nil, ErrInvalidExpenseFilter
		}
	}
	if f.ApproverScope && params.CreatedBy.Valid {
		params.DecidableSince = pgTimestamptz(approverDecidedSince(time.Now()))
	}
	rows, err := s.q.ListExpensesFiltered(ctx, params)
	if err != nil {
		return nil, err
	}
	out := make([]domain.MyExpense, len(rows))
	ptrs := make([]*domain.Expense, len(rows))
	for i, r := range rows {
		out[i] = repository.ToDomainListedExpense(r)
		ptrs[i] = &out[i].Expense
	}
	if err := attachExpenseAttachments(ctx, s.q, orgID, ptrs); err != nil {
		return nil, err
	}
	return out, nil
}

func validateGeneralExpense(in ExpenseInput) (string, error) {
	if !domain.ValidExpenseCategory(in.Category) {
		return "", errors.New("geçersiz masraf kategorisi")
	}
	if strings.TrimSpace(in.Description) == "" {
		return "", errors.New("masraf açıklaması zorunludur")
	}
	if in.Amount <= 0 {
		return "", ErrInvalidAmount
	}
	if !domain.ValidExpenseVATRate(in.VATRate) {
		return "", ErrInvalidExpenseVATRate
	}
	if strings.TrimSpace(in.ChangeOrderID) != "" || strings.TrimSpace(in.CostCodeID) != "" || strings.TrimSpace(in.BudgetLineID) != "" {
		return "", ErrGeneralExpenseProjectLink
	}
	currency := "TRY"
	if strings.TrimSpace(in.Currency) != "" {
		c, ok := domain.NormalizeCurrency(in.Currency)
		if !ok {
			return "", ErrInvalidOfferCurrency
		}
		currency = c
	}
	return currency, nil
}

// ErrGeneralExpenseProjectLink: ek iş / maliyet kodu / bütçe kalemi bir
// projeye aittir; projesiz masrafa bağlanamaz.
var ErrGeneralExpenseProjectLink = errors.New("genel (projesiz) masraf ek işe, bütçe kalemine veya maliyet koduna bağlanamaz; bunun için masrafı bir projeye gir")

func generalExpenseIDs(expenseID, organizationID string) (eid, orgID pgtype.UUID, err error) {
	if eid, err = repository.StringToUUID(expenseID); err != nil {
		return eid, orgID, ErrGeneralExpenseNotFound
	}
	if orgID, err = repository.StringToUUID(organizationID); err != nil {
		return eid, orgID, domain.ErrNotFound
	}
	return eid, orgID, nil
}

func lockGeneralExpense(ctx context.Context, txq *sqlc.Queries, eid, orgID pgtype.UUID) (sqlc.ProjectExpense, error) {
	row, err := txq.GetGeneralExpenseForUpdate(ctx, sqlc.GetGeneralExpenseForUpdateParams{ID: eid, OrganizationID: orgID})
	if errors.Is(err, pgx.ErrNoRows) {
		return row, ErrGeneralExpenseNotFound
	}
	return row, err
}

// checkGeneralExpenseWritable: iptal edilmiş masrafa yazılmaz; kısıtlı yazar
// (ownOnly) yalnızca kendi bekleyen/reddedilen masrafına yazar.
func checkGeneralExpenseWritable(row sqlc.ProjectExpense, actor pgtype.UUID, ownOnly bool) error {
	switch {
	case row.VoidedAt.Valid:
		return ErrAlreadyVoided
	case !ownOnly:
		return nil
	case !actor.Valid || !row.CreatedBy.Valid || row.CreatedBy != actor:
		return ErrExpenseNotOwn
	case row.ApprovalStatus == domain.ExpenseApprovalApproved:
		return ErrExpenseApprovedLocked
	}
	return nil
}

// notifyGeneralExpensePending: onaylayıcılara (projects.expenses.approve
// sahipleri, giren ve işlemi yapan hariç) gruplu bildirim.
func notifyGeneralExpensePending(ctx context.Context, txq *sqlc.Queries, orgID pgtype.UUID, row sqlc.ProjectExpense, actor pgtype.UUID) error {
	holders, err := txq.ListUsersWithPermission(ctx, sqlc.ListUsersWithPermissionParams{OrganizationID: orgID, PermissionCode: domain.PermProjectsExpensesApprove})
	if err != nil {
		return err
	}
	r := newRecipientList(actor)
	for _, h := range holders {
		if row.CreatedBy.Valid && h.ID == row.CreatedBy {
			continue
		}
		r.add(h.ID)
	}
	if len(r.ids) == 0 {
		return nil
	}
	who := ""
	if actor.Valid {
		if u, err := txq.GetUserByID(ctx, actor); err == nil {
			who = u.FullName
		}
	}
	return notifyUsersGrouped(ctx, txq, orgID, pgtype.UUID{}, r.ids, actor, groupedNotice{
		Type: domain.NotificationExpensePendingApproval, EntityType: domain.NotificationEntityProjectExpense,
		EntityID: row.ID, Title: expensePendingTitle,
		Body:   joinNonEmpty(" · ", "Genel masraf", who),
		Target: pendingExpensesTarget,
	})
}

func notifyGeneralExpenseDecision(ctx context.Context, txq *sqlc.Queries, orgID pgtype.UUID, row sqlc.ProjectExpense, actor pgtype.UUID) error {
	if !row.CreatedBy.Valid || (actor.Valid && row.CreatedBy == actor) {
		return nil
	}
	notifType, title := domain.NotificationExpenseApproved, "Masraf onaylandı"
	body := joinNonEmpty(" · ", "Genel masraf", truncateRunes(row.Description, 80))
	if row.ApprovalStatus == domain.ExpenseApprovalRejected {
		notifType, title = domain.NotificationExpenseRejected, "Masraf reddedildi"
		body = joinNonEmpty(" · ", body, "Gerekçe: "+row.DecisionNote)
	}
	return createNotification(ctx, txq, CreateNotificationInput{
		OrganizationID: orgID, UserID: row.CreatedBy, Type: notifType,
		Title: title, Body: truncateRunes(body, 500),
		EntityType: domain.NotificationEntityProjectExpense, EntityID: row.ID,
		// Karar bildirimi masrafı girene gider: Masraflarım o masrafın
		// ayrıntısını (ret nedeni, belgeler, Düzenle) açar -- genel masraf
		// artık orada da listeleniyor.
		ActionTarget: myExpenseTarget(row.ID),
	})
}
