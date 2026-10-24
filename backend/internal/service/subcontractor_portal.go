package service

import (
	"context"
	"errors"
	"sort"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/shopspring/decimal"

	"github.com/Savanooo/ARVEND/backend/internal/auth"
	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

// Taşeron Paneli (migration 0075, docs/taseron-paneli.md). Firma, taşeron
// kartından giriş açar ve proje izni verir. Taşeron hesabı yalnızca kendi
// kartının, izin verilen projelerdeki kayıtlarını görür; taşeron her zaman
// oturumdaki hesaptan (users.supplier_id) bulunur, istekten değil.

const (
	OrgEventPortalUserCreated  = "subcontractor_portal_user_created"
	OrgEventPortalUserReset    = "subcontractor_portal_user_password_reset"
	OrgEventPortalUserActive   = "subcontractor_portal_user_active_changed"
	OrgEventPortalAccessUpdate = "subcontractor_portal_access_updated"
)

var (
	ErrPortalUserNotFound   error = &NotFoundError{What: "taşeron girişi"}
	ErrPortalProjectInvalid       = errors.New("proje izni yalnızca bu firmanın projelerine verilebilir")
	ErrPortalFieldsRequired       = errors.New("ad soyad, kullanıcı adı ve geçici şifre zorunludur")
)

type PortalUserInput struct {
	FullName          string
	Username          string
	TemporaryPassword string
	ActorUserID       string
}

// PortalSettings: taşeron kartının giriş ve proje izni ekranı.
type PortalSettings struct {
	Users    []domain.PortalUser
	Projects []domain.PortalProjectChoice
}

func toPortalUser(u sqlc.User) domain.PortalUser {
	out := domain.PortalUser{
		ID: u.ID.String(), Username: u.Username, FullName: u.FullName, IsActive: u.IsActive,
		MustChangePassword: u.MustChangePassword, CreatedAt: u.CreatedAt.Time,
	}
	if u.LastLoginAt.Valid {
		t := u.LastLoginAt.Time
		out.LastLoginAt = &t
	}
	return out
}

// portalCard: firmanın taşeron kartı (taşeron olmalı).
func (s *SupplierService) portalCard(ctx context.Context, q *sqlc.Queries, organizationID, supplierID string) (sqlc.Supplier, pgtype.UUID, pgtype.UUID, error) {
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return sqlc.Supplier{}, pgtype.UUID{}, pgtype.UUID{}, domain.ErrNotFound
	}
	sid, err := repository.StringToUUID(supplierID)
	if err != nil {
		return sqlc.Supplier{}, pgtype.UUID{}, pgtype.UUID{}, ErrSubcontractorCardNotFound
	}
	card, err := q.GetSubcontractorCard(ctx, sqlc.GetSubcontractorCardParams{ID: sid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return sqlc.Supplier{}, pgtype.UUID{}, pgtype.UUID{}, ErrSubcontractorCardNotFound
		}
		return sqlc.Supplier{}, pgtype.UUID{}, pgtype.UUID{}, err
	}
	return card, orgID, sid, nil
}

// GetPortalSettings: kartın girişleri ve proje izin seçenekleri.
func (s *SupplierService) GetPortalSettings(ctx context.Context, organizationID, supplierID string) (*PortalSettings, error) {
	_, orgID, sid, err := s.portalCard(ctx, s.q, organizationID, supplierID)
	if err != nil {
		return nil, err
	}
	return s.portalSettings(ctx, s.q, orgID, sid)
}

func (s *SupplierService) portalSettings(ctx context.Context, q *sqlc.Queries, orgID, sid pgtype.UUID) (*PortalSettings, error) {
	users, err := q.ListSupplierPortalUsers(ctx, sqlc.ListSupplierPortalUsersParams{OrganizationID: orgID, SupplierID: sid})
	if err != nil {
		return nil, err
	}
	projects, err := q.ListPortalProjectChoices(ctx, sqlc.ListPortalProjectChoicesParams{SupplierID: sid, OrganizationID: orgID})
	if err != nil {
		return nil, err
	}
	out := &PortalSettings{
		Users:    make([]domain.PortalUser, len(users)),
		Projects: make([]domain.PortalProjectChoice, len(projects)),
	}
	for i, u := range users {
		out.Users[i] = toPortalUser(u)
	}
	for i, p := range projects {
		out.Projects[i] = domain.PortalProjectChoice{
			ID: p.ID.String(), ProjectNo: p.ProjectNo, Name: p.Name, Status: p.Status,
			Granted: p.Granted, HasEngagement: p.HasEngagement,
		}
	}
	return out, nil
}

// CreatePortalUser: taşeron kartına giriş açar (geçici şifre; taşeron ilk
// girişte kendi şifresini belirler). Arşivdeki karta açılmaz.
func (s *SupplierService) CreatePortalUser(ctx context.Context, organizationID, supplierID string, in PortalUserInput) (*domain.PortalUser, error) {
	fullName, username := strings.TrimSpace(in.FullName), strings.TrimSpace(in.Username)
	if fullName == "" || username == "" || in.TemporaryPassword == "" {
		return nil, ErrPortalFieldsRequired
	}
	if !domain.ValidPasswordLength(in.TemporaryPassword) {
		return nil, domain.ErrPasswordTooShort
	}
	if isReservedUsername(username) {
		return nil, domain.ErrReservedUsername
	}
	// bcrypt transaction'ı açık tutmasın diye önce.
	hash, err := auth.HashPassword(in.TemporaryPassword)
	if err != nil {
		return nil, err
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	card, orgID, sid, err := s.portalCard(ctx, txq, organizationID, supplierID)
	if err != nil {
		return nil, err
	}
	if !card.IsActive {
		return nil, ErrSubcontractorCardArchived
	}
	role, err := txq.GetOrganizationRoleByCode(ctx, sqlc.GetOrganizationRoleByCodeParams{
		OrganizationID: orgID, Code: domain.OrgRoleSubcontractor,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	row, err := txq.CreatePortalUser(ctx, sqlc.CreatePortalUserParams{
		OrganizationID: orgID, Username: username, PasswordHash: hash, FullName: fullName,
		SupplierID: sid, OrganizationRoleID: role.ID,
	})
	if err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" {
			return nil, domain.ErrDuplicateUsername
		}
		return nil, err
	}
	if err := logOrgEvent(ctx, txq, orgID, OrgEventPortalUserCreated, actorUUID(in.ActorUserID), map[string]any{
		"supplier_id": supplierID, "user_id": row.ID.String(), "username": username,
	}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := toPortalUser(row)
	return &out, nil
}

// ResetPortalUserPassword: yeni geçici şifre verir; açık oturumlar kapanır,
// taşeron sonraki girişte şifresini yeniden belirler.
func (s *SupplierService) ResetPortalUserPassword(ctx context.Context, organizationID, supplierID, userID, temporaryPassword, actorUserID string) (*domain.PortalUser, error) {
	if !domain.ValidPasswordLength(temporaryPassword) {
		return nil, domain.ErrPasswordTooShort
	}
	hash, err := auth.HashPassword(temporaryPassword)
	if err != nil {
		return nil, err
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)
	_, orgID, sid, err := s.portalCard(ctx, txq, organizationID, supplierID)
	if err != nil {
		return nil, err
	}
	uid, err := repository.StringToUUID(userID)
	if err != nil {
		return nil, ErrPortalUserNotFound
	}
	row, err := txq.ResetPortalUserPassword(ctx, sqlc.ResetPortalUserPasswordParams{
		PasswordHash: hash, ID: uid, OrganizationID: orgID, SupplierID: sid,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrPortalUserNotFound
		}
		return nil, err
	}
	if err := txq.RevokeAllUserRefreshTokens(ctx, uid); err != nil {
		return nil, err
	}
	if err := logOrgEvent(ctx, txq, orgID, OrgEventPortalUserReset, actorUUID(actorUserID), map[string]any{
		"supplier_id": supplierID, "user_id": userID,
	}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := toPortalUser(row)
	return &out, nil
}

// SetPortalUserActive: girişi kapatır ya da yeniden açar. Kapatınca açık
// oturumlar ve telefon kayıtları silinir (firma kullanıcısını
// pasifleştirmeyle aynı, bkz. endUserAccess).
func (s *SupplierService) SetPortalUserActive(ctx context.Context, organizationID, supplierID, userID string, active bool, actorUserID string) (*domain.PortalUser, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)
	_, orgID, sid, err := s.portalCard(ctx, txq, organizationID, supplierID)
	if err != nil {
		return nil, err
	}
	uid, err := repository.StringToUUID(userID)
	if err != nil {
		return nil, ErrPortalUserNotFound
	}
	row, err := txq.SetPortalUserActive(ctx, sqlc.SetPortalUserActiveParams{
		IsActive: active, ID: uid, OrganizationID: orgID, SupplierID: sid,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrPortalUserNotFound
		}
		return nil, err
	}
	if !active {
		if err := endUserAccess(ctx, txq, uid); err != nil {
			return nil, err
		}
	}
	if err := logOrgEvent(ctx, txq, orgID, OrgEventPortalUserActive, actorUUID(actorUserID), map[string]any{
		"supplier_id": supplierID, "user_id": userID, "active": active,
	}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := toPortalUser(row)
	return &out, nil
}

// SetPortalProjects: taşeronun proje izinlerini verilen kümeyle değiştirir
// (boş küme = hiçbir proje). Projeler bu firmanın olmalı.
func (s *SupplierService) SetPortalProjects(ctx context.Context, organizationID, supplierID string, projectIDs []string, actorUserID string) (*PortalSettings, error) {
	seen := map[string]bool{}
	ids := make([]pgtype.UUID, 0, len(projectIDs))
	for _, raw := range projectIDs {
		id, err := repository.StringToUUID(strings.TrimSpace(raw))
		if err != nil {
			return nil, ErrPortalProjectInvalid
		}
		if !seen[id.String()] {
			seen[id.String()] = true
			ids = append(ids, id)
		}
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)
	_, orgID, sid, err := s.portalCard(ctx, txq, organizationID, supplierID)
	if err != nil {
		return nil, err
	}
	if len(ids) > 0 {
		n, err := txq.CountProjectsInOrg(ctx, sqlc.CountProjectsInOrgParams{OrganizationID: orgID, Ids: ids})
		if err != nil {
			return nil, err
		}
		if int(n) != len(ids) {
			return nil, ErrPortalProjectInvalid
		}
	}
	if err := txq.DeleteSupplierProjectAccess(ctx, sqlc.DeleteSupplierProjectAccessParams{OrganizationID: orgID, SupplierID: sid}); err != nil {
		return nil, err
	}
	actor := actorUUID(actorUserID)
	for _, id := range ids {
		if err := txq.InsertSupplierProjectAccess(ctx, sqlc.InsertSupplierProjectAccessParams{
			OrganizationID: orgID, SupplierID: sid, ProjectID: id, GrantedBy: actor,
		}); err != nil {
			return nil, err
		}
	}
	idStrings := make([]string, len(ids))
	for i, id := range ids {
		idStrings[i] = id.String()
	}
	if err := logOrgEvent(ctx, txq, orgID, OrgEventPortalAccessUpdate, actor, map[string]any{
		"supplier_id": supplierID, "project_ids": idStrings,
	}); err != nil {
		return nil, err
	}
	out, err := s.portalSettings(ctx, txq, orgID, sid)
	if err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	return out, nil
}

// PortalOverview: taşeronun ana ekranı -- izinli projeler, oradaki işleri,
// ödemeleri ve para birimi başına toplamlar. supplierID HER ZAMAN oturumdaki
// hesaptan gelir (middleware.SupplierIDFromContext).
func (s *SupplierService) PortalOverview(ctx context.Context, organizationID, supplierID string) (*domain.PortalOverview, error) {
	card, orgID, sid, err := s.portalCard(ctx, s.q, organizationID, supplierID)
	if err != nil {
		return nil, err
	}
	name := card.LegalName
	if strings.TrimSpace(card.TradeName) != "" {
		name = card.TradeName
	}
	out := &domain.PortalOverview{SupplierID: supplierID, SupplierName: name}

	projects, err := s.q.ListPortalProjects(ctx, sqlc.ListPortalProjectsParams{OrganizationID: orgID, SupplierID: sid})
	if err != nil {
		return nil, err
	}
	out.Projects = make([]domain.PortalProject, len(projects))
	for i, p := range projects {
		out.Projects[i] = domain.PortalProject{ID: p.ID.String(), ProjectNo: p.ProjectNo, Name: p.Name, Status: p.Status}
	}

	type sums struct{ contract, paid, remaining, payable, retention decimal.Decimal }
	totals := map[string]*sums{}
	bucket := func(cur string) *sums {
		if totals[cur] == nil {
			totals[cur] = &sums{}
		}
		return totals[cur]
	}

	engs, err := s.q.ListPortalEngagements(ctx, sqlc.ListPortalEngagementsParams{OrganizationID: orgID, SupplierID: sid})
	if err != nil {
		return nil, err
	}
	out.Engagements = make([]domain.PortalEngagement, len(engs))
	for i, e := range engs {
		contract, paid := repository.NumericToDecimal(e.ContractAmount), repository.NumericToDecimal(e.Paid)
		remaining := contract.Sub(paid)
		if remaining.IsNegative() {
			remaining = decimal.Zero
		}
		pe := domain.PortalEngagement{
			Kind: e.Kind, ID: e.ID.String(), ProjectID: e.ProjectID.String(), ProjectName: e.ProjectName,
			ProjectNo: e.ProjectNo, ProjectStatus: e.ProjectStatus, Title: e.Title, Status: e.Status, Currency: e.Currency,
			ContractAmount: contract.InexactFloat64(), Paid: paid.InexactFloat64(),
			Payable:       repository.NumericToFloat64(e.Payable),
			Retention:     repository.NumericToFloat64(e.Retention),
			AdvanceOpen:   repository.NumericToFloat64(e.AdvanceOpen),
			PendingClaims: repository.NumericToFloat64(e.PendingClaims),
			Remaining:     remaining.InexactFloat64(),
		}
		if e.Certified.Valid {
			v := repository.NumericToFloat64(e.Certified)
			pe.Certified = &v
		}
		out.Engagements[i] = pe
		b := bucket(e.Currency)
		b.contract = b.contract.Add(contract)
		b.remaining = b.remaining.Add(remaining)
		b.payable = b.payable.Add(repository.NumericToDecimal(e.Payable))
		b.retention = b.retention.Add(repository.NumericToDecimal(e.Retention))
	}

	pays, err := s.q.ListPortalPayments(ctx, sqlc.ListPortalPaymentsParams{OrganizationID: orgID, SupplierID: sid})
	if err != nil {
		return nil, err
	}
	out.Payments = make([]domain.PortalPayment, len(pays))
	for i, p := range pays {
		pp := domain.PortalPayment{
			Source: p.Source, ID: p.ID.String(), ProjectName: p.ProjectName, ProjectNo: p.ProjectNo,
			Amount: repository.NumericToFloat64(p.Amount), Currency: p.Currency, PaidDate: p.PaidDate.Time,
			Description: p.Description, Kind: p.Kind,
		}
		if p.ProjectID.Valid {
			id := p.ProjectID.String()
			pp.ProjectID = &id
		}
		out.Payments[i] = pp
		b := bucket(p.Currency)
		b.paid = b.paid.Add(repository.NumericToDecimal(p.Amount))
	}

	currencies := make([]string, 0, len(totals))
	for c := range totals {
		currencies = append(currencies, c)
	}
	sort.Slice(currencies, func(i, j int) bool {
		// TL önce, sonra alfabetik.
		if (currencies[i] == "TRY") != (currencies[j] == "TRY") {
			return currencies[i] == "TRY"
		}
		return currencies[i] < currencies[j]
	})
	out.Totals = make([]domain.PortalTotals, len(currencies))
	for i, c := range currencies {
		b := totals[c]
		out.Totals[i] = domain.PortalTotals{
			Currency: c, ContractAmount: b.contract.InexactFloat64(), Paid: b.paid.InexactFloat64(),
			Remaining: b.remaining.InexactFloat64(), Payable: b.payable.InexactFloat64(), Retention: b.retention.InexactFloat64(),
		}
	}
	return out, nil
}
