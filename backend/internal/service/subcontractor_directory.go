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

// Taşeronlar (migration 0069, ürün sahibinin isteği 2026-10): "taşeron
// menüsünden taşeronu oluşturalım, hem projede hem orada kullanalım;
// projeden ve proje dışı yaptığım ödemeler tek yerde dursun".
//
// Taşeron kartı firmanın tedarikçi kataloğundaki kayıttır
// (suppliers.is_subcontractor). Projedeki basit taşeron kaydı karta bağlıdır
// (project_subcontractors.supplier_id); kart verilmeden açılırsa aynı adlı
// kart bulunur ya da açılır -- aynı kişi farklı projelerde ayrı ayrı
// yazılıp ödemeleri dağılmasın. Proje dışı ödemeler kartın kendisine
// yazılır (subcontractor_direct_payments).

const (
	OrgEventSubcontractorDirectPaymentAdded  = "subcontractor_direct_payment_added"
	OrgEventSubcontractorDirectPaymentVoided = "subcontractor_direct_payment_voided"
	OrgEventSubcontractorMarked              = "subcontractor_marked"
)

var (
	ErrSubcontractorCardNotFound error = &NotFoundError{What: "taşeron"}
	// ErrSubcontractorCardArchived: arşivdeki taşerona ödeme girilemez ve
	// yeni projede kullanılamaz.
	ErrSubcontractorCardArchived       = errors.New("bu taşeron arşivde; önce Taşeronlar'dan arşivden çıkarın")
	ErrSubcontractorNameRequired       = errors.New("taşeron adı zorunludur")
	ErrDirectPaymentNotFound     error = &NotFoundError{What: "ödeme"}
)

// subcontractorCodeFormat: otomatik taşeron kodu (göçle aynı biçim).
const subcontractorCodeFormat = "TSR-%04d"

// ListSubcontractorCards: "Taşeronlar" listesi. withTotals ise (finans
// okuma izni) kart başına ödenen toplamlar da gelir; restrictToUserID
// doluysa projeli ödemeler yalnızca kişinin üyesi olduğu projelerden.
func (s *SupplierService) ListSubcontractorCards(ctx context.Context, organizationID string, withTotals bool, restrictToUserID string) ([]domain.SubcontractorCard, error) {
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	rows, err := s.q.ListSubcontractorCards(ctx, orgID)
	if err != nil {
		return nil, err
	}
	out := make([]domain.SubcontractorCard, len(rows))
	index := make(map[pgtype.UUID]int, len(rows))
	for i, r := range rows {
		out[i] = domain.SubcontractorCard{Supplier: repository.ToDomainSupplier(r)}
		index[r.ID] = i
	}
	if !withTotals || len(rows) == 0 {
		return out, nil
	}
	restrict, _ := repository.StringToUUID(restrictToUserID)
	totals, err := s.q.ListSubcontractorPaidTotals(ctx, sqlc.ListSubcontractorPaidTotalsParams{
		OrganizationID: orgID, RestrictToUserID: restrict,
	})
	if err != nil {
		return nil, err
	}
	for _, t := range totals {
		if i, ok := index[t.SupplierID]; ok {
			out[i].PaidTotals = append(out[i].PaidTotals, domain.MoneyAmount{
				Currency: t.Currency, Amount: repository.NumericToFloat64(t.PaidTotal),
			})
		}
	}
	remaining, err := s.q.ListSubcontractorRemainingTotals(ctx, sqlc.ListSubcontractorRemainingTotalsParams{
		OrganizationID: orgID, RestrictToUserID: restrict,
	})
	if err != nil {
		return nil, err
	}
	for _, t := range remaining {
		amount := repository.NumericToFloat64(t.RemainingTotal)
		if i, ok := index[t.SupplierID]; ok && amount > 0 {
			out[i].RemainingTotals = append(out[i].RemainingTotals, domain.MoneyAmount{Currency: t.Currency, Amount: amount})
		}
	}
	return out, nil
}

// CreateSubcontractorCard: Taşeronlar'dan yeni kart. Kod boşsa TSR-NNNN
// verilir; diğer kurallar tedarikçi kaydıyla aynı (vergi no tekrarı, IBAN
// şifreleme).
func (s *SupplierService) CreateSubcontractorCard(ctx context.Context, organizationID string, in SupplierInput) (*domain.Supplier, error) {
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	if strings.TrimSpace(in.LegalName) == "" {
		return nil, ErrSubcontractorNameRequired
	}
	generated := strings.TrimSpace(in.Code) == ""
	var created *domain.Supplier
	for attempt := 0; attempt < 3; attempt++ {
		if generated {
			n, err := s.q.NextSubcontractorCodeNumber(ctx, orgID)
			if err != nil {
				return nil, err
			}
			in.Code = fmt.Sprintf(subcontractorCodeFormat, int(n)+attempt)
		}
		created, err = s.Create(ctx, organizationID, in)
		if err == nil || !generated || !errors.Is(err, ErrDuplicateSupplierCode) {
			break
		}
	}
	if err != nil {
		return nil, err
	}
	sid, _ := repository.StringToUUID(created.ID)
	if err := s.q.SetSupplierIsSubcontractor(ctx, sqlc.SetSupplierIsSubcontractorParams{ID: sid, OrganizationID: orgID}); err != nil {
		return nil, err
	}
	created.IsSubcontractor = true
	return created, nil
}

// MarkAsSubcontractor: katalogdaki mevcut bir tedarikçiyi Taşeronlar'a
// ekler (malzeme de veren bir firma taşeron olarak da çalışabilir).
func (s *SupplierService) MarkAsSubcontractor(ctx context.Context, organizationID, supplierID, userID string) (*domain.Supplier, error) {
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	sid, err := repository.StringToUUID(supplierID)
	if err != nil {
		return nil, ErrSubcontractorCardNotFound
	}
	row, err := s.q.GetSupplier(ctx, sqlc.GetSupplierParams{ID: sid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrSubcontractorCardNotFound
		}
		return nil, err
	}
	if !row.IsSubcontractor {
		if err := s.q.SetSupplierIsSubcontractor(ctx, sqlc.SetSupplierIsSubcontractorParams{ID: sid, OrganizationID: orgID}); err != nil {
			return nil, err
		}
		if err := logOrgEvent(ctx, s.q, orgID, OrgEventSubcontractorMarked, actorUUID(userID),
			map[string]any{"supplier_id": supplierID}); err != nil {
			return nil, err
		}
		row.IsSubcontractor = true
	}
	out := repository.ToDomainSupplier(row)
	return &out, nil
}

// SubcontractorLedger: taşeronun sayfası -- kart, projelerdeki işleri ve
// bütün ödemeleri (projeli + proje dışı, iptaller dahil).
type SubcontractorLedger struct {
	Card        domain.Supplier
	Engagements []domain.SubcontractorEngagement
	Payments    []domain.SubcontractorLedgerPayment
	// SiteDays: günlük raporlarda sahada göründüğü günler (son 90).
	SiteDays []domain.SubcontractorSiteDay
}

func (s *SupplierService) GetSubcontractorLedger(ctx context.Context, organizationID, supplierID, restrictToUserID string) (*SubcontractorLedger, error) {
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	sid, err := repository.StringToUUID(supplierID)
	if err != nil {
		return nil, ErrSubcontractorCardNotFound
	}
	card, err := s.q.GetSubcontractorCard(ctx, sqlc.GetSubcontractorCardParams{ID: sid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrSubcontractorCardNotFound
		}
		return nil, err
	}
	restrict, _ := repository.StringToUUID(restrictToUserID)
	engRows, err := s.q.ListSubcontractorEngagements(ctx, sqlc.ListSubcontractorEngagementsParams{
		OrganizationID: orgID, SupplierID: sid, RestrictToUserID: restrict,
	})
	if err != nil {
		return nil, err
	}
	payRows, err := s.q.ListSubcontractorLedgerPayments(ctx, sqlc.ListSubcontractorLedgerPaymentsParams{
		OrganizationID: orgID, SupplierID: sid, RestrictToUserID: restrict,
	})
	if err != nil {
		return nil, err
	}
	out := &SubcontractorLedger{
		Card:        repository.ToDomainSupplier(card),
		Engagements: make([]domain.SubcontractorEngagement, len(engRows)),
		Payments:    make([]domain.SubcontractorLedgerPayment, len(payRows)),
	}
	for i, r := range engRows {
		out.Engagements[i] = domain.SubcontractorEngagement{
			Kind: r.Kind, ID: r.ID.String(), ProjectID: r.ProjectID.String(),
			ProjectName: r.ProjectName, ProjectNo: r.ProjectNo, ProjectStatus: r.ProjectStatus,
			Title: r.Title, Status: r.Status, Currency: r.Currency,
			ContractAmount: repository.NumericToFloat64(r.ContractAmount),
			PaidAmount:     repository.NumericToFloat64(r.PaidAmount),
		}
	}
	for i, r := range payRows {
		p := domain.SubcontractorLedgerPayment{
			Source: r.Source, ID: r.ID.String(), ProjectID: r.ProjectID.String(),
			ProjectName: r.ProjectName, ProjectNo: r.ProjectNo, EngagementID: r.EngagementID.String(),
			Amount: repository.NumericToFloat64(r.Amount), Currency: r.Currency,
			PaidDate: r.PaidDate.Time, Description: r.Description, VoidReason: r.VoidReason, Kind: r.Kind,
		}
		if r.VoidedAt.Valid {
			t := r.VoidedAt.Time
			p.VoidedAt = &t
		}
		out.Payments[i] = p
	}
	days, err := s.q.ListSubcontractorSiteDays(ctx, sqlc.ListSubcontractorSiteDaysParams{
		OrganizationID: orgID, SupplierID: sid, RestrictToUserID: restrict,
	})
	if err != nil {
		return nil, err
	}
	out.SiteDays = make([]domain.SubcontractorSiteDay, len(days))
	for i, d := range days {
		out.SiteDays[i] = domain.SubcontractorSiteDay{
			ReportDate: d.ReportDate.Time, ProjectID: d.ProjectID.String(), ProjectName: d.ProjectName,
			ProjectNo: d.ProjectNo, Workers: int(d.Workers), WorkNote: d.WorkNote,
		}
	}
	return out, nil
}

// DirectPaymentInput: proje dışı taşeron ödemesi.
type DirectPaymentInput struct {
	Amount   float64
	Currency string
	PaidDate time.Time
	// PaymentKind: "general" (boşsa) | "advance" -- yalnızca bilgi.
	PaymentKind    string
	Description    string
	IdempotencyKey string
	UserID         string
}

// CreateDirectPayment: taşerona proje dışı ödeme. Para birimi boşsa TRY.
// Aynı kişinin aynı tekrar anahtarı aynı kaydı döner (çift dokunuş).
func (s *SupplierService) CreateDirectPayment(ctx context.Context, organizationID, supplierID string, in DirectPaymentInput) (*domain.SubcontractorLedgerPayment, error) {
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	sid, err := repository.StringToUUID(supplierID)
	if err != nil {
		return nil, ErrSubcontractorCardNotFound
	}
	if in.Amount <= 0 {
		return nil, ErrInvalidAmount
	}
	kind := strings.TrimSpace(in.PaymentKind)
	switch kind {
	case "":
		kind = "general"
	case "general", domain.SubcontractorPaymentKindAdvance:
	default:
		return nil, ErrInvalidPaymentKind
	}
	currency := "TRY"
	if strings.TrimSpace(in.Currency) != "" {
		c, ok := domain.NormalizeCurrency(in.Currency)
		if !ok {
			return nil, ErrInvalidOfferCurrency
		}
		currency = c
	}
	actor := actorUUID(in.UserID)

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	card, err := txq.GetSubcontractorCard(ctx, sqlc.GetSubcontractorCardParams{ID: sid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrSubcontractorCardNotFound
		}
		return nil, err
	}
	if !card.IsActive {
		return nil, ErrSubcontractorCardArchived
	}
	key := strings.TrimSpace(in.IdempotencyKey)
	var keyPtr *string
	if key != "" {
		keyPtr = &key
		existing, err := txq.GetSubcontractorDirectPaymentByIdempotencyKey(ctx, sqlc.GetSubcontractorDirectPaymentByIdempotencyKeyParams{
			OrganizationID: orgID, IdempotencyKey: &key,
		})
		switch {
		case err == nil:
			if existing.CreatedBy != actor || existing.SupplierID != sid {
				return nil, ErrExpenseIdempotencyKeyInUse
			}
			return toDirectLedgerPayment(existing), nil
		case !errors.Is(err, pgx.ErrNoRows):
			return nil, err
		}
	}
	row, err := txq.CreateSubcontractorDirectPayment(ctx, sqlc.CreateSubcontractorDirectPaymentParams{
		OrganizationID: orgID, SupplierID: sid, Amount: repository.Float64ToNumeric(in.Amount),
		Currency: currency, PaidDate: repository.TimeToDate(in.PaidDate),
		Description: truncateRunes(strings.TrimSpace(in.Description), 500), IdempotencyKey: keyPtr, CreatedBy: actor,
		PaymentKind: kind,
	})
	if err != nil {
		return nil, err
	}
	if err := logOrgEvent(ctx, txq, orgID, OrgEventSubcontractorDirectPaymentAdded, actor, map[string]any{
		"supplier_id": supplierID, "payment_id": row.ID.String(), "amount": in.Amount, "payment_kind": kind,
	}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	return toDirectLedgerPayment(row), nil
}

// VoidDirectPayment: proje dışı ödemeyi iptal eder (kayıt silinmez).
func (s *SupplierService) VoidDirectPayment(ctx context.Context, organizationID, supplierID, paymentID, userID, reason string) (*domain.SubcontractorLedgerPayment, error) {
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	sid, err := repository.StringToUUID(supplierID)
	if err != nil {
		return nil, ErrSubcontractorCardNotFound
	}
	pid, err := repository.StringToUUID(paymentID)
	if err != nil {
		return nil, ErrDirectPaymentNotFound
	}
	actor := actorUUID(userID)
	reason = truncateRunes(strings.TrimSpace(reason), 500)
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)
	row, err := txq.VoidSubcontractorDirectPayment(ctx, sqlc.VoidSubcontractorDirectPaymentParams{
		VoidedBy: actor, VoidReason: reason, ID: pid, OrganizationID: orgID, SupplierID: sid,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			// Ya yok ya da zaten iptal: ikisi de "bu ödeme iptal edilemez".
			return nil, ErrDirectPaymentNotFound
		}
		return nil, err
	}
	if err := logOrgEvent(ctx, txq, orgID, OrgEventSubcontractorDirectPaymentVoided, actor, map[string]any{
		"supplier_id": supplierID, "payment_id": paymentID, "reason": reason,
	}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	return toDirectLedgerPayment(row), nil
}

func toDirectLedgerPayment(r sqlc.SubcontractorDirectPayment) *domain.SubcontractorLedgerPayment {
	p := &domain.SubcontractorLedgerPayment{
		Source: "direct", ID: r.ID.String(), Amount: repository.NumericToFloat64(r.Amount),
		Currency: r.Currency, PaidDate: r.PaidDate.Time, Description: r.Description, VoidReason: r.VoidReason,
		Kind: r.PaymentKind,
	}
	if r.VoidedAt.Valid {
		t := r.VoidedAt.Time
		p.VoidedAt = &t
	}
	return p
}

// resolveSubcontractorCard: projedeki basit taşeron kaydının bağlanacağı
// kart. supplierID verilmişse o kart (firmada olmalı, arşivde olmamalı;
// taşeron değilse taşeron yapılır). Verilmemişse aynı adlı kart/tedarikçi
// bulunur ya da yeni kart açılır -- eski istemciler ve web adı elle yazmaya
// devam etse de her kayıt bir karta bağlanır.
func resolveSubcontractorCard(ctx context.Context, txq *sqlc.Queries, orgID pgtype.UUID, supplierID, name, company, phone, email string, actor pgtype.UUID) (sqlc.Supplier, error) {
	if strings.TrimSpace(supplierID) != "" {
		sid, err := repository.StringToUUID(supplierID)
		if err != nil {
			return sqlc.Supplier{}, ErrSubcontractorCardNotFound
		}
		card, err := txq.GetSupplier(ctx, sqlc.GetSupplierParams{ID: sid, OrganizationID: orgID})
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return sqlc.Supplier{}, ErrSubcontractorCardNotFound
			}
			return sqlc.Supplier{}, err
		}
		if !card.IsActive {
			return sqlc.Supplier{}, ErrSubcontractorCardArchived
		}
		if !card.IsSubcontractor {
			if err := txq.SetSupplierIsSubcontractor(ctx, sqlc.SetSupplierIsSubcontractorParams{ID: sid, OrganizationID: orgID}); err != nil {
				return sqlc.Supplier{}, err
			}
			card.IsSubcontractor = true
		}
		return card, nil
	}
	name = strings.Join(strings.Fields(name), " ")
	if name == "" {
		return sqlc.Supplier{}, ErrSubcontractorNameRequired
	}
	card, err := txq.FindSupplierByNormalizedName(ctx, sqlc.FindSupplierByNormalizedNameParams{OrganizationID: orgID, Name: name})
	switch {
	case err == nil:
		if !card.IsSubcontractor {
			if err := txq.SetSupplierIsSubcontractor(ctx, sqlc.SetSupplierIsSubcontractorParams{ID: card.ID, OrganizationID: orgID}); err != nil {
				return sqlc.Supplier{}, err
			}
			card.IsSubcontractor = true
		}
		return card, nil
	case !errors.Is(err, pgx.ErrNoRows):
		return sqlc.Supplier{}, err
	}
	n, err := txq.NextSubcontractorCodeNumber(ctx, orgID)
	if err != nil {
		return sqlc.Supplier{}, err
	}
	card, err = txq.CreateSupplier(ctx, sqlc.CreateSupplierParams{
		OrganizationID: orgID, Code: fmt.Sprintf(subcontractorCodeFormat, n), LegalName: name,
		TradeName: strings.TrimSpace(company), Phone: strings.TrimSpace(phone), Email: strings.TrimSpace(email),
		Country: "Türkiye", CreatedBy: actor,
	})
	if err != nil {
		return sqlc.Supplier{}, err
	}
	if err := txq.SetSupplierIsSubcontractor(ctx, sqlc.SetSupplierIsSubcontractorParams{ID: card.ID, OrganizationID: orgID}); err != nil {
		return sqlc.Supplier{}, err
	}
	card.IsSubcontractor = true
	if err := logOrgEvent(ctx, txq, orgID, domain.OrgEventSupplierCreated, actor,
		map[string]any{"supplier_id": card.ID.String(), "code": card.Code, "auto": true}); err != nil {
		return sqlc.Supplier{}, err
	}
	return card, nil
}
