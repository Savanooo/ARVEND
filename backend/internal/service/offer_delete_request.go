package service

import (
	"context"
	"errors"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

// Teklif silme talebi (migration 0067, ürün sahibinin kararı 2026-10):
// "Yönetici direkt silebilir ama alt roller silince onaya düşsün".
// offers.delete taşıyan kişi DELETE /offers/{id} ile direkt siler (bugünkü
// akış); teklifi oluşturup düzenleyebilen ama silme izni olmayan kişi talep
// açar, offers.delete sahibi onaylar (teklif silinir) ya da reddeder. İzin
// kapıları router'dadır; burada durum kuralları ve bildirimler var.

var (
	ErrOfferDeleteAlreadyRequested = errors.New("bu teklif için zaten bekleyen bir silme talebi var")
	ErrOfferDeleteRequestNotFound  = errors.New("bu teklif için bekleyen bir silme talebi yok")
	ErrOfferDeleteRequestNotOwn    = errors.New("silme talebini yalnızca açan kişi geri çekebilir")
)

const offerDeleteNoteMax = 500

// RequestDelete: silme talebi açar ve firmanın silme yetkililerine bildirir.
// Kabul edilmiş teklif zaten silinemez (ErrOfferAccepted) -- talebi de açılmaz.
func (s *OfferService) RequestDelete(ctx context.Context, offerID, organizationID, userID, reason string) (*domain.OfferDeleteRequest, error) {
	oid, orgID, actor, err := offerDeleteIDs(offerID, organizationID, userID)
	if err != nil {
		return nil, err
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	offerRow, err := txq.GetOfferByID(ctx, sqlc.GetOfferByIDParams{ID: oid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	if offerRow.Status == domain.OfferStatusKabulEdildi {
		return nil, ErrOfferAccepted
	}
	reason = truncateRunes(strings.TrimSpace(reason), offerDeleteNoteMax)
	row, err := txq.CreateOfferDeleteRequest(ctx, sqlc.CreateOfferDeleteRequestParams{
		OrganizationID: orgID, OfferID: oid, RequestedBy: actor, Reason: reason,
	})
	if err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" {
			return nil, ErrOfferDeleteAlreadyRequested
		}
		return nil, err
	}
	if err := logOfferEvent(ctx, txq, orgID, oid, pgtype.UUID{}, domain.EventOfferDeleteRequested, actor,
		nonEmptyMeta("reason", reason), "", ""); err != nil {
		return nil, err
	}
	if err := notifyOfferDeleteRequested(ctx, txq, offerRow, actor); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := &domain.OfferDeleteRequest{
		ID: row.ID.String(), OfferID: row.OfferID.String(), Reason: row.Reason,
		Status: row.Status, CreatedAt: row.CreatedAt.Time,
	}
	if actor.Valid {
		id := actor.String()
		out.RequestedBy = &id
		if u, err := s.q.GetUserByID(ctx, actor); err == nil {
			out.RequestedByName = u.FullName
		}
	}
	return out, nil
}

// ApproveDeleteRequest: bekleyen talebi onaylar -- teklif kalıcı olarak
// silinir (talep satırı da onunla gider) ve talep edene bildirilir. Talep
// açıldıktan sonra teklif kabul edildiyse silinmez (ErrOfferAccepted);
// talep reddedilmeli.
func (s *OfferService) ApproveDeleteRequest(ctx context.Context, offerID, organizationID, userID string) error {
	oid, orgID, actor, err := offerDeleteIDs(offerID, organizationID, userID)
	if err != nil {
		return err
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	req, err := lockPendingOfferDeleteRequest(ctx, txq, oid, orgID)
	if err != nil {
		return err
	}
	offerRow, err := txq.GetOfferByID(ctx, sqlc.GetOfferByIDParams{ID: oid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return domain.ErrNotFound
		}
		return err
	}
	if offerRow.Status == domain.OfferStatusKabulEdildi {
		return ErrOfferAccepted
	}
	// Bildirim teklif silinmeden ÖNCE hazırlanır (numara/müşteri ondan okunur).
	if err := notifyOfferDeleteDecision(ctx, txq, offerRow, req, actor, true, ""); err != nil {
		return err
	}
	if err := txq.DeleteOffer(ctx, sqlc.DeleteOfferParams{ID: oid, OrganizationID: orgID}); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// RejectDeleteRequest: talebi reddeder (teklif kalır), gerekçeyle talep
// edene bildirir.
func (s *OfferService) RejectDeleteRequest(ctx context.Context, offerID, organizationID, userID, note string) error {
	oid, orgID, actor, err := offerDeleteIDs(offerID, organizationID, userID)
	if err != nil {
		return err
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	req, err := lockPendingOfferDeleteRequest(ctx, txq, oid, orgID)
	if err != nil {
		return err
	}
	offerRow, err := txq.GetOfferByID(ctx, sqlc.GetOfferByIDParams{ID: oid, OrganizationID: orgID})
	if err != nil {
		return err
	}
	note = truncateRunes(strings.TrimSpace(note), offerDeleteNoteMax)
	if _, err := txq.DecideOfferDeleteRequest(ctx, sqlc.DecideOfferDeleteRequestParams{
		Status: "rejected", DecidedBy: actor, DecisionNote: note, ID: req.ID, OrganizationID: orgID,
	}); err != nil {
		return err
	}
	if err := logOfferEvent(ctx, txq, orgID, oid, pgtype.UUID{}, domain.EventOfferDeleteRejected, actor,
		nonEmptyMeta("note", note), "", ""); err != nil {
		return err
	}
	if err := notifyOfferDeleteDecision(ctx, txq, offerRow, req, actor, false, note); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// WithdrawDeleteRequest: talebi açan kişi vazgeçer.
func (s *OfferService) WithdrawDeleteRequest(ctx context.Context, offerID, organizationID, userID string) error {
	oid, orgID, actor, err := offerDeleteIDs(offerID, organizationID, userID)
	if err != nil {
		return err
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	req, err := lockPendingOfferDeleteRequest(ctx, txq, oid, orgID)
	if err != nil {
		return err
	}
	if !actor.Valid || req.RequestedBy != actor {
		return ErrOfferDeleteRequestNotOwn
	}
	if _, err := txq.DecideOfferDeleteRequest(ctx, sqlc.DecideOfferDeleteRequestParams{
		Status: "withdrawn", DecidedBy: actor, ID: req.ID, OrganizationID: orgID,
	}); err != nil {
		return err
	}
	if err := logOfferEvent(ctx, txq, orgID, oid, pgtype.UUID{}, domain.EventOfferDeleteWithdrawn, actor, nil, "", ""); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// ListPendingDeleteRequests: firmanın onay bekleyen silme talepleri, en
// eskisi önce.
func (s *OfferService) ListPendingDeleteRequests(ctx context.Context, organizationID string) ([]domain.OfferDeleteRequest, error) {
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	rows, err := s.q.ListPendingOfferDeleteRequests(ctx, orgID)
	if err != nil {
		return nil, err
	}
	out := make([]domain.OfferDeleteRequest, len(rows))
	for i, r := range rows {
		out[i] = domain.OfferDeleteRequest{
			ID: r.ID.String(), OfferID: r.OfferID.String(), Reason: r.Reason, Status: "pending",
			RequestedByName: r.RequestedByName, CreatedAt: r.CreatedAt.Time,
			OfferNo: r.OfferNo, CustomerName: r.CustomerName,
			GrandTotal: repository.NumericToFloat64(r.GrandTotal), Currency: r.Currency,
		}
		if r.RequestedBy.Valid {
			id := r.RequestedBy.String()
			out[i].RequestedBy = &id
		}
	}
	return out, nil
}

// pendingDeleteRequest: teklifin bekleyen talebi (yoksa nil) -- Get bunu
// teklif detayına ekler.
func (s *OfferService) pendingDeleteRequest(ctx context.Context, offerID, orgID pgtype.UUID) (*domain.OfferDeleteRequest, error) {
	r, err := s.q.GetPendingOfferDeleteRequest(ctx, sqlc.GetPendingOfferDeleteRequestParams{OfferID: offerID, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, nil
		}
		return nil, err
	}
	out := &domain.OfferDeleteRequest{
		ID: r.ID.String(), OfferID: r.OfferID.String(), Reason: r.Reason, Status: r.Status,
		RequestedByName: r.RequestedByName, CreatedAt: r.CreatedAt.Time,
	}
	if r.RequestedBy.Valid {
		id := r.RequestedBy.String()
		out.RequestedBy = &id
	}
	return out, nil
}

func offerDeleteIDs(offerID, organizationID, userID string) (oid, orgID, actor pgtype.UUID, err error) {
	if oid, err = repository.StringToUUID(offerID); err != nil {
		return oid, orgID, actor, domain.ErrNotFound
	}
	if orgID, err = repository.StringToUUID(organizationID); err != nil {
		return oid, orgID, actor, domain.ErrNotFound
	}
	actor, _ = repository.StringToUUID(userID)
	return oid, orgID, actor, nil
}

func lockPendingOfferDeleteRequest(ctx context.Context, txq *sqlc.Queries, offerID, orgID pgtype.UUID) (sqlc.OfferDeleteRequest, error) {
	req, err := txq.GetPendingOfferDeleteRequestForUpdate(ctx, sqlc.GetPendingOfferDeleteRequestForUpdateParams{OfferID: offerID, OrganizationID: orgID})
	if errors.Is(err, pgx.ErrNoRows) {
		return req, ErrOfferDeleteRequestNotFound
	}
	return req, err
}

func nonEmptyMeta(key, value string) map[string]any {
	if value == "" {
		return nil
	}
	return map[string]any{key: value}
}

// resolveOfferDeleteApprovers: talebe karar verebilecek ve haber alması
// gereken kişiler -- firmanın Sahip ve Yöneticileri ile offers.delete'i
// özel bir rolden ya da kişiye özel yetkiden taşıyanlar. Eski Sistem
// (legacy_user) rolü de silebilir ama bildirim almaz: taşınan firmalarda
// herkes bu roldeydi (bkz. resolveOfferDecisionAudience).
func resolveOfferDeleteApprovers(ctx context.Context, txq *sqlc.Queries, orgID, actor pgtype.UUID) ([]pgtype.UUID, error) {
	holders, err := txq.ListUsersWithPermission(ctx, sqlc.ListUsersWithPermissionParams{OrganizationID: orgID, PermissionCode: domain.PermOffersDelete})
	if err != nil {
		return nil, err
	}
	readers, err := txq.ListUsersWithPermission(ctx, sqlc.ListUsersWithPermissionParams{OrganizationID: orgID, PermissionCode: domain.PermOffersRead})
	if err != nil {
		return nil, err
	}
	canRead := permissionHolderSet(readers)
	r := newRecipientList(actor)
	for _, h := range holders {
		if h.OrganizationRoleCode != domain.OrgRoleLegacyUser && canRead[h.ID] {
			r.add(h.ID)
		}
	}
	return r.ids, nil
}

func notifyOfferDeleteRequested(ctx context.Context, txq *sqlc.Queries, offer sqlc.Offer, actor pgtype.UUID) error {
	recipients, err := resolveOfferDeleteApprovers(ctx, txq, offer.OrganizationID, actor)
	if err != nil || len(recipients) == 0 {
		return err
	}
	body := offer.OfferNo
	if rev, err := txq.GetOfferRevisionByID(ctx, sqlc.GetOfferRevisionByIDParams{ID: offer.CurrentRevisionID, OrganizationID: offer.OrganizationID}); err == nil {
		body = offerNoticeBody(offer.OfferNo, rev)
	}
	if u, err := txq.GetUserByID(ctx, actor); err == nil && strings.TrimSpace(u.FullName) != "" {
		body = joinNonEmpty(" · ", body, "Talep eden: "+u.FullName)
	}
	return createNotificationsForUsers(ctx, txq, recipients, CreateNotificationInput{
		OrganizationID: offer.OrganizationID, Type: domain.NotificationOfferDeleteRequested,
		Title: "Teklif silme onayı bekliyor", Body: truncateRunes(body, 500),
		EntityType: domain.NotificationEntityOffer, EntityID: offer.ID,
		ActionTarget: offerTarget(offer.ID),
	})
}

// notifyOfferDeleteDecision: kararı talep edene bildirir. Onayda teklif
// silindiği için hedef teklif listesidir.
func notifyOfferDeleteDecision(ctx context.Context, txq *sqlc.Queries, offer sqlc.Offer, req sqlc.OfferDeleteRequest, actor pgtype.UUID, approved bool, note string) error {
	if !req.RequestedBy.Valid || (actor.Valid && req.RequestedBy == actor) {
		return nil
	}
	notifType, title, target := domain.NotificationOfferDeleteRejected, "Teklif silme talebin reddedildi", offerTarget(offer.ID)
	body := offer.OfferNo
	if approved {
		notifType, title, target = domain.NotificationOfferDeleteApproved, "Teklif silindi", "/teklifler"
		body = joinNonEmpty(" · ", body, "Silme talebin onaylandı")
	} else if note != "" {
		body = joinNonEmpty(" · ", body, "Gerekçe: "+note)
	}
	return createNotification(ctx, txq, CreateNotificationInput{
		OrganizationID: offer.OrganizationID, UserID: req.RequestedBy, Type: notifType,
		Title: title, Body: truncateRunes(body, 500),
		EntityType: domain.NotificationEntityOffer, EntityID: offer.ID,
		ActionTarget: target,
	})
}
