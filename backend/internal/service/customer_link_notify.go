package service

import (
	"context"
	"fmt"
	"strings"

	"github.com/jackc/pgx/v5/pgtype"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

// Ürün sahibi (2026-10): "müşteriye teklif linki gönderiyoruz; onaylayınca
// bize bildirim gelsin". Müşterinin paylaşım linkindeki hareketleri --
// teklif/ek iş kararı ve teklifin ilk açılışı -- firmaya bildirim olarak
// düşer; personelin aynı kararı kendisinin kaydetmesi de (teklif durumu,
// ek işte record-decision) aynı alıcılara, kaydeden hariç, gider.
//
// Alıcı kuralının ortak iki ilkesi:
//   - Kimse açamayacağı bir bildirim almaz: herkes kaydın okuma iznini
//     (teklifte offers.read, ek işte projects.finance.read + proje erişimi)
//     taşımalı -- yoksa dokununca "yetkin yok" görür.
//   - "Eski Sistem" (legacy_user) rolü yalnızca kaydın kendi kişisiyse
//     (oluşturan) ya da projenin Erişim listesinde açıkça varsa alır: BYZ'den
//     taşınan firmalarda herkes bu roldeydi ve her izni taşıyor (bkz.
//     resolveProjectAudience).

// recipientList: alıcıları eklendiği sırayla toplar -- aynı kişi bir kez,
// eylemi yapan (actor) hiç.
type recipientList struct {
	actor pgtype.UUID
	seen  map[pgtype.UUID]bool
	ids   []pgtype.UUID
}

func newRecipientList(actor pgtype.UUID) *recipientList {
	return &recipientList{actor: actor, seen: map[pgtype.UUID]bool{}}
}

func (r *recipientList) add(id pgtype.UUID) {
	if !id.Valid || (r.actor.Valid && id == r.actor) || r.seen[id] {
		return
	}
	r.seen[id] = true
	r.ids = append(r.ids, id)
}

func isFirmManagerRole(orgRoleCode string) bool {
	return orgRoleCode == domain.OrgRoleOwner || orgRoleCode == domain.OrgRoleAdmin
}

// permissionHolderSet: permissionCode'u etkin olarak tutan aktif kullanıcılar.
func permissionHolderSet(rows []sqlc.ListUsersWithPermissionRow) map[pgtype.UUID]bool {
	out := make(map[pgtype.UUID]bool, len(rows))
	for _, r := range rows {
		out[r.ID] = true
	}
	return out
}

// ---------- Teklif ----------

// resolveOfferDecisionAudience: teklif kabul/red bildiriminin alıcıları
// (hepsi offers.read taşır, actor hariç):
//   - teklifi oluşturan,
//   - firmanın Sahip ve Yöneticileri (ürün sahibinin "bize" dediği kişiler;
//     BYZ'den gelen tekliflerde oluşturan yok -- eskiden kimse duymuyordu),
//   - offers.update sahipleri (Eski Sistem hariç): teklifi revize edip
//     yeniden gönderen, yani sonucun peşinden koşan kişiler -- özel bir
//     "Satış" rolü ya da kişiye özel yetkiyle teklif işine bakanlar. Teklif
//     firma geneli bir kayıttır (proje yok), daraltacak bir Erişim listesi
//     olmadığı için Eski Sistem dışarıda kalır; yoksa taşınan firmalarda
//     şantiye ekibi dahil herkese gider.
//
// offers.approve (durum değiştirme) ayrıca eklenmez: müşteri kararı
// verildikten sonra yapılacak iş (revize/projeye dönüştürme) onu
// gerektirmez; varsayılan rollerde zaten aynı kişilerdedir.
func resolveOfferDecisionAudience(ctx context.Context, txq *sqlc.Queries, orgID, createdBy, actor pgtype.UUID) ([]pgtype.UUID, error) {
	readerRows, err := txq.ListUsersWithPermission(ctx, sqlc.ListUsersWithPermissionParams{OrganizationID: orgID, PermissionCode: domain.PermOffersRead})
	if err != nil {
		return nil, err
	}
	editorRows, err := txq.ListUsersWithPermission(ctx, sqlc.ListUsersWithPermissionParams{OrganizationID: orgID, PermissionCode: domain.PermOffersUpdate})
	if err != nil {
		return nil, err
	}
	readers := permissionHolderSet(readerRows)
	r := newRecipientList(actor)
	if readers[createdBy] {
		r.add(createdBy)
	}
	for _, h := range readerRows {
		if isFirmManagerRole(h.OrganizationRoleCode) {
			r.add(h.ID)
		}
	}
	for _, h := range editorRows {
		if h.OrganizationRoleCode != domain.OrgRoleLegacyUser && readers[h.ID] {
			r.add(h.ID)
		}
	}
	return r.ids, nil
}

// notifyOfferDecision: teklif "kabul edildi"/"reddedildi"ye geçtiğinde --
// diğer durumlar için hiçbir şey yapmaz. actor geçersizse karar müşterinin
// kendi linkindendir; değilse personel işaretlemiştir (o kişi bildirim
// almaz, kim olduğu gövdeye yazılır). rev, kararın verildiği revizyondur
// (müşteri adı ve tutar ondan okunur).
func notifyOfferDecision(ctx context.Context, txq *sqlc.Queries, offer sqlc.Offer, rev sqlc.OfferRevision, status string, actor pgtype.UUID) error {
	var notifType, title string
	byCustomer := !actor.Valid
	switch {
	case status == domain.OfferStatusKabulEdildi && byCustomer:
		notifType, title = domain.NotificationOfferAccepted, "Müşteri teklifi kabul etti"
	case status == domain.OfferStatusKabulEdildi:
		notifType, title = domain.NotificationOfferAccepted, "Teklif kabul edildi"
	case status == domain.OfferStatusReddedildi && byCustomer:
		notifType, title = domain.NotificationOfferRejected, "Müşteri teklifi reddetti"
	case status == domain.OfferStatusReddedildi:
		notifType, title = domain.NotificationOfferRejected, "Teklif reddedildi"
	default:
		return nil
	}
	recipients, err := resolveOfferDecisionAudience(ctx, txq, offer.OrganizationID, offer.CreatedBy, actor)
	if err != nil || len(recipients) == 0 {
		return err
	}
	body := offerNoticeBody(offer.OfferNo, rev)
	if !byCustomer {
		body = joinNonEmpty(" · ", body, recordedBy(ctx, txq, actor))
	}
	return createNotificationsForUsers(ctx, txq, recipients, CreateNotificationInput{
		OrganizationID: offer.OrganizationID, Type: notifType,
		Title: title, Body: truncateRunes(body, 500),
		EntityType: domain.NotificationEntityOffer, EntityID: offer.ID,
		ActionTarget: offerTarget(offer.ID),
	})
}

// notifyOfferFirstOpen: müşteri teklifi karar beklerken ilk kez açtı (kural
// için bkz. OfferService.recordCustomerView). Satış takibi bilgisidir --
// yalnızca teklifi hazırlayana gider; teklifin oluşturanı yoksa (BYZ'den
// gelen teklif), pasifse ya da artık teklifleri göremiyorsa firmanın Sahip
// ve Yöneticilerine.
func notifyOfferFirstOpen(ctx context.Context, txq *sqlc.Queries, offer sqlc.Offer, rev sqlc.OfferRevision) error {
	readerRows, err := txq.ListUsersWithPermission(ctx, sqlc.ListUsersWithPermissionParams{OrganizationID: offer.OrganizationID, PermissionCode: domain.PermOffersRead})
	if err != nil {
		return err
	}
	r := newRecipientList(pgtype.UUID{})
	if permissionHolderSet(readerRows)[offer.CreatedBy] {
		r.add(offer.CreatedBy)
	} else {
		for _, h := range readerRows {
			if isFirmManagerRole(h.OrganizationRoleCode) {
				r.add(h.ID)
			}
		}
	}
	if len(r.ids) == 0 {
		return nil
	}
	ref := offer.OfferNo
	if rev.RevisionNo > 0 {
		ref = fmt.Sprintf("%s (Revizyon %d)", offer.OfferNo, rev.RevisionNo)
	}
	return createNotificationsForUsers(ctx, txq, r.ids, CreateNotificationInput{
		OrganizationID: offer.OrganizationID, Type: domain.NotificationOfferViewed,
		Title: "Müşteri teklifi açtı", Body: truncateRunes(offerNoticeBody(ref, rev), 500),
		EntityType: domain.NotificationEntityOffer, EntityID: offer.ID,
		ActionTarget: offerTarget(offer.ID),
	})
}

// offerNoticeBody: "TKL-2026-014 · Ahmet Yılmaz · 1.250.000 TL".
func offerNoticeBody(ref string, rev sqlc.OfferRevision) string {
	return joinNonEmpty(" · ", ref, truncateRunes(rev.CustomerName, 80), noticeAmount(rev.GrandTotal, rev.Currency))
}

func offerTarget(offerID pgtype.UUID) string { return "/teklifler/" + offerID.String() }

// ---------- Ek iş ----------

// resolveChangeOrderDecisionAudience: ek işte müşteri kararının alıcıları
// (hepsi projects.finance.read -- ek işi açan izin -- ve projeye erişim
// taşır, actor hariç):
//   - ek işi oluşturan (projeyi hâlâ görebiliyorsa),
//   - firmanın Sahip ve Yöneticileri (her projeyi görürler),
//   - projede projects.change_orders.approve taşıyanlar -- müşteri
//     telefonla yanıt verseydi kararı kaydedecek kişiler; Sahip/Yönetici
//     dışındakiler yalnızca projenin Erişim listesindeyse
//     (resolveProjectAudience: bu bir onay İSTEĞİ değil, sonuç haberidir).
func resolveChangeOrderDecisionAudience(ctx context.Context, txq *sqlc.Queries, co sqlc.ProjectChangeOrder, actor pgtype.UUID) ([]pgtype.UUID, error) {
	readerRows, err := txq.ListUsersWithPermission(ctx, sqlc.ListUsersWithPermissionParams{OrganizationID: co.OrganizationID, PermissionCode: domain.PermProjectsFinanceRead})
	if err != nil {
		return nil, err
	}
	approvers, err := resolveProjectAudience(ctx, txq, co.OrganizationID, co.ProjectID, domain.PermProjectsChangeOrdersApprove)
	if err != nil {
		return nil, err
	}
	readers := permissionHolderSet(readerRows)
	r := newRecipientList(actor)
	if readers[co.CreatedBy] {
		_, access, err := canAccessProject(ctx, txq, co.OrganizationID, co.ProjectID, co.CreatedBy)
		if err != nil {
			return nil, err
		}
		if access {
			r.add(co.CreatedBy)
		}
	}
	for _, h := range readerRows {
		if isFirmManagerRole(h.OrganizationRoleCode) {
			r.add(h.ID)
		}
	}
	for _, id := range approvers {
		if readers[id] {
			r.add(id)
		}
	}
	return r.ids, nil
}

// notifyChangeOrderDecision: applyChangeOrderDecision'ın sonunda (link ve
// personel kaydı aynı yoldan). actor geçersizse karar müşterinin kendi
// linkindendir; değilse kararı personel kaydetmiştir (o kişi bildirim
// almaz, kim kaydettiği gövdeye yazılır).
func notifyChangeOrderDecision(ctx context.Context, txq *sqlc.Queries, co sqlc.ProjectChangeOrder, actor pgtype.UUID) error {
	var notifType, title string
	byCustomer := !actor.Valid
	switch {
	case co.Status == domain.ChangeOrderApproved && byCustomer:
		notifType, title = domain.NotificationChangeOrderApproved, "Müşteri ek işi onayladı"
	case co.Status == domain.ChangeOrderApproved:
		notifType, title = domain.NotificationChangeOrderApproved, "Ek iş onaylandı"
	case co.Status == domain.ChangeOrderRejected && byCustomer:
		notifType, title = domain.NotificationChangeOrderRejected, "Müşteri ek işi reddetti"
	case co.Status == domain.ChangeOrderRejected:
		notifType, title = domain.NotificationChangeOrderRejected, "Ek iş reddedildi"
	default:
		return nil
	}
	recipients, err := resolveChangeOrderDecisionAudience(ctx, txq, co, actor)
	if err != nil || len(recipients) == 0 {
		return err
	}
	// Eksiltme proje bedelini düşürür: tutar işaretiyle yazılır.
	amount := noticeAmount(co.GrandTotal, co.Currency)
	if amount != "" {
		if co.ChangeType == domain.ChangeOrderDeduction {
			amount = "-" + amount
		} else {
			amount = "+" + amount
		}
	}
	body := joinNonEmpty(" · ",
		joinNonEmpty(" ", fmt.Sprintf("EK-%03d", co.SequenceNo), truncateRunes(co.Title, 60)),
		projectNameFor(ctx, txq, co.OrganizationID, co.ProjectID), amount)
	if !byCustomer {
		body = joinNonEmpty(" · ", body, recordedBy(ctx, txq, actor))
	}
	return createNotificationsForUsers(ctx, txq, recipients, CreateNotificationInput{
		OrganizationID: co.OrganizationID, Type: notifType,
		Title: title, Body: truncateRunes(body, 500),
		EntityType: domain.NotificationEntityChangeOrder, EntityID: co.ID, ProjectID: co.ProjectID,
		ActionTarget: "/projeler/" + co.ProjectID.String() + "/ek-isler/" + co.ID.String(),
	})
}

// ---------- Ortak ----------

// recordedBy: personelin kaydettiği kararda "Kaydeden: Ad Soyad" (kişi
// okunamazsa boş -- bildirim yine gider).
func recordedBy(ctx context.Context, txq *sqlc.Queries, actor pgtype.UUID) string {
	u, err := txq.GetUserByID(ctx, actor)
	if err != nil || strings.TrimSpace(u.FullName) == "" {
		return ""
	}
	return "Kaydeden: " + u.FullName
}

// noticeAmount: bildirimdeki tutar -- "1.250.000 TL"; kuruş varsa
// "1.250.000,50 TL", dövizde "12.000 USD". Tutar yoksa boş.
func noticeAmount(n pgtype.Numeric, currency string) string {
	if !n.Valid {
		return ""
	}
	s := strings.TrimSuffix(strings.TrimSuffix(FormatTL(repository.NumericToFloat64(n)), " TL"), ",00")
	return s + " " + currencyLabel(currency)
}
