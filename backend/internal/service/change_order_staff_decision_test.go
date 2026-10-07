package service_test

// "Müşteri onayladı/reddetti olarak işaretle" (ürün kararı 2026-10-07,
// migration 0063): personelin kaydettiği karar paylaşım linkiyle AYNI kod
// yolundan geçer -- aynı durum kuralları, aynı negatif kontrolü, aynı olay,
// sözleşme bedeline aynı etki. Gerçek PostgreSQL gerektirir.

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

func TestChangeOrderStaffDecision(t *testing.T) {
	dbURL := testDBURL(t)
	box := testSecretBox(t)
	ctx := context.Background()

	pool, err := repository.NewPool(ctx, dbURL)
	if err != nil {
		t.Fatalf("veritabanına bağlanılamadı: %v", err)
	}
	t.Cleanup(func() { pool.Close() })

	q := sqlc.New(pool)
	userSvc := service.NewUserService(pool, q)
	settingsSvc := service.NewSettingsService(q, box)
	offerSvc := service.NewOfferService(pool, q, settingsSvc, "http://localhost:3000")
	projectSvc := service.NewProjectService(pool, q, mustTestStore(t), settingsSvc, "http://localhost:3000")
	platformSvc := service.NewPlatformService(pool, q, userSvc, service.NewCalcService(q), service.NewProductService(q))

	const slug = "ekis-personel-karar-test"
	var existing string
	if pool.QueryRow(ctx, "SELECT id FROM organizations WHERE slug = $1", slug).Scan(&existing) == nil {
		cleanupOrganization(t, pool, existing)
	}
	created, err := platformSvc.CreateOrganizationWithOwner(ctx, service.CreateOrganizationInput{
		Name: "Ek İş Karar Test", Slug: slug,
		OwnerUsername: "owner_" + slug, OwnerPassword: "GeciciSifre123!", OwnerFullName: "Karar Sahibi",
	})
	if err != nil {
		t.Fatalf("firma+sahip oluşturulamadı: %v", err)
	}
	t.Cleanup(func() { cleanupOrganization(t, pool, created.Organization.ID) })
	orgID := created.Organization.ID
	staffID := created.Owner.ID

	newProject := func(t *testing.T, contractAmount float64) *domain.Project {
		t.Helper()
		o, err := offerSvc.Create(ctx, service.CreateOfferInput{
			OrganizationID: orgID, CustomerName: "Karar Müşteri", VatRate: ptrFloat(0),
			Items: []service.OfferItemInput{{ProductName: "İş", Quantity: 1, UnitPrice: contractAmount}},
		})
		if err != nil {
			t.Fatalf("teklif oluşturulamadı: %v", err)
		}
		if _, err := offerSvc.UpdateStatus(ctx, o.ID, orgID, domain.OfferStatusGonderildi, ""); err != nil {
			t.Fatalf("gönderilemedi: %v", err)
		}
		link, err := offerSvc.CreateShareLink(ctx, o.ID, orgID, "", nil)
		if err != nil {
			t.Fatalf("link oluşturulamadı: %v", err)
		}
		if _, err := offerSvc.RespondByShareLinkToken(ctx, link.Token, domain.OfferStatusKabulEdildi, "", ""); err != nil {
			t.Fatalf("kabul edilemedi: %v", err)
		}
		p, err := projectSvc.CreateFromOffer(ctx, o.ID, orgID, service.CreateProjectInput{Name: "Karar Projesi"})
		if err != nil {
			t.Fatalf("proje oluşturulamadı: %v", err)
		}
		return p
	}
	newSent := func(t *testing.T, projectID, changeType string, amount float64) *domain.ChangeOrder {
		t.Helper()
		co, err := projectSvc.CreateChangeOrder(ctx, projectID, orgID, service.ChangeOrderInput{
			ChangeType: changeType, Title: "Telefon onaylı",
			Items: []service.ChangeOrderItemInput{{Description: "Kalem", Quantity: 1, Unit: "adet", UnitPrice: amount}},
		})
		if err != nil {
			t.Fatalf("ek iş oluşturulamadı: %v", err)
		}
		sent, err := projectSvc.SendChangeOrder(ctx, projectID, co.ID, orgID, staffID)
		if err != nil {
			t.Fatalf("ek iş gönderilemedi: %v", err)
		}
		return sent
	}
	contractValue := func(t *testing.T, projectID string) float64 {
		t.Helper()
		s, err := projectSvc.FinancialSummary(ctx, projectID, orgID)
		if err != nil {
			t.Fatalf("finans özeti alınamadı: %v", err)
		}
		return s.CurrentContractValue
	}
	linkToken := func(t *testing.T, changeOrderID string) string {
		t.Helper()
		var token string
		if err := pool.QueryRow(ctx, `SELECT token::text FROM project_change_order_share_links
			WHERE change_order_id = $1 AND revoked_at IS NULL ORDER BY created_at DESC LIMIT 1`, changeOrderID).Scan(&token); err != nil {
			t.Fatalf("aktif link bulunamadı: %v", err)
		}
		return token
	}

	t.Run("approval_recorded_with_actor_note_event_and_contract_effect", func(t *testing.T) {
		p := newProject(t, 100000)
		co := newSent(t, p.ID, domain.ChangeOrderAddition, 15000)
		out, err := projectSvc.RecordChangeOrderDecision(ctx, p.ID, co.ID, orgID, staffID, domain.ChangeOrderApproved, " telefonla onay ")
		if err != nil {
			t.Fatalf("karar kaydedilemedi: %v", err)
		}
		if out.Status != domain.ChangeOrderApproved || out.ApprovedAt == nil || out.RespondedAt == nil {
			t.Errorf("durum/tarih eksik: %+v", out)
		}
		if out.DecisionRecordedBy == nil || *out.DecisionRecordedBy != staffID || out.DecisionNote != "telefonla onay" || out.DecisionRecordedByName != "Karar Sahibi" {
			t.Errorf("kim/not kaydı eksik: by=%v name=%q note=%q", out.DecisionRecordedBy, out.DecisionRecordedByName, out.DecisionNote)
		}
		if got := contractValue(t, p.ID); got != 115000 {
			t.Errorf("güncel proje bedeli = %v, beklenen 115000", got)
		}
		detail, err := projectSvc.GetChangeOrder(ctx, p.ID, co.ID, orgID)
		if err != nil || detail.DecisionRecordedByName != "Karar Sahibi" || detail.DecisionNote != "telefonla onay" {
			t.Errorf("detay: %+v err=%v", detail, err)
		}
		list, err := projectSvc.ListChangeOrders(ctx, p.ID, orgID)
		if err != nil || len(list) != 1 || list[0].DecisionRecordedByName != "Karar Sahibi" {
			t.Errorf("liste: %+v err=%v", list, err)
		}
		events, err := projectSvc.ListProjectEvents(ctx, p.ID, orgID)
		if err != nil {
			t.Fatalf("olaylar alınamadı: %v", err)
		}
		found := false
		for _, ev := range events {
			if ev.EventType == domain.ProjectEventChangeOrderApproved && ev.Metadata["change_order_id"] == co.ID {
				found = true
				if ev.UserID == nil || *ev.UserID != staffID || ev.Metadata["source"] != domain.ChangeOrderDecisionSourceStaff || ev.Metadata["note"] != "telefonla onay" {
					t.Errorf("olay kimi/kaynağı/notu taşımalı: %+v", ev)
				}
			}
		}
		if !found {
			t.Error("change_order_approved olayı yazılmadı")
		}
		// Müşteri linki artık yanıt veremez (karar verildi) -- aynı kural.
		if _, err := projectSvc.RespondChangeOrderByShareLinkToken(ctx, linkToken(t, co.ID), domain.ChangeOrderRejected, "", ""); !errors.Is(err, service.ErrChangeOrderNotRespondable) {
			t.Errorf("personelin kaydettiği karardan sonra link yanıtı: beklenen ErrChangeOrderNotRespondable, geldi %v", err)
		}
	})

	t.Run("rejection_recorded_without_contract_effect", func(t *testing.T) {
		p := newProject(t, 100000)
		co := newSent(t, p.ID, domain.ChangeOrderAddition, 15000)
		out, err := projectSvc.RecordChangeOrderDecision(ctx, p.ID, co.ID, orgID, staffID, domain.ChangeOrderRejected, "")
		if err != nil {
			t.Fatalf("red kaydedilemedi: %v", err)
		}
		if out.Status != domain.ChangeOrderRejected || out.RejectedAt == nil {
			t.Errorf("durum: %+v", out)
		}
		if got := contractValue(t, p.ID); got != 100000 {
			t.Errorf("red proje bedelini değiştirmemeli: %v", got)
		}
		// Reddedilen ek iş, linkten reddedilmiş gibi revize edilebilir.
		if _, err := projectSvc.ReviseChangeOrder(ctx, p.ID, co.ID, orgID, staffID); err != nil {
			t.Errorf("reddedilen ek iş revize edilebilmeli: %v", err)
		}
	})

	t.Run("customer_link_decision_has_no_recorder", func(t *testing.T) {
		p := newProject(t, 100000)
		co := newSent(t, p.ID, domain.ChangeOrderAddition, 1000)
		out, err := projectSvc.RespondChangeOrderByShareLinkToken(ctx, linkToken(t, co.ID), domain.ChangeOrderApproved, "1.2.3.4", "ua")
		if err != nil {
			t.Fatalf("link onayı başarısız: %v", err)
		}
		if out.DecisionRecordedBy != nil || out.DecisionNote != "" {
			t.Errorf("müşteri kararında kaydeden olmamalı: %+v", out)
		}
	})

	t.Run("same_rules_as_share_link", func(t *testing.T) {
		p := newProject(t, 10000)
		// Taslak karara bağlanamaz.
		draft, err := projectSvc.CreateChangeOrder(ctx, p.ID, orgID, service.ChangeOrderInput{
			ChangeType: domain.ChangeOrderAddition, Title: "Taslak",
			Items: []service.ChangeOrderItemInput{{Description: "K", Quantity: 1, UnitPrice: 10}},
		})
		if err != nil {
			t.Fatalf("taslak oluşturulamadı: %v", err)
		}
		if _, err := projectSvc.RecordChangeOrderDecision(ctx, p.ID, draft.ID, orgID, staffID, domain.ChangeOrderApproved, ""); !errors.Is(err, service.ErrChangeOrderNotRespondable) {
			t.Errorf("taslak: beklenen ErrChangeOrderNotRespondable, geldi %v", err)
		}
		// Eksiltme proje bedelini negatife düşüremez.
		ded := newSent(t, p.ID, domain.ChangeOrderDeduction, 10000.01)
		if _, err := projectSvc.RecordChangeOrderDecision(ctx, p.ID, ded.ID, orgID, staffID, domain.ChangeOrderApproved, ""); !errors.Is(err, service.ErrChangeOrderWouldGoNegative) {
			t.Errorf("eksiltme: beklenen ErrChangeOrderWouldGoNegative, geldi %v", err)
		}
		// Geçersiz karar ve uzun not.
		ok := newSent(t, p.ID, domain.ChangeOrderAddition, 10)
		if _, err := projectSvc.RecordChangeOrderDecision(ctx, p.ID, ok.ID, orgID, staffID, "sent", ""); !errors.Is(err, service.ErrInvalidChangeOrderDecision) {
			t.Errorf("geçersiz karar: geldi %v", err)
		}
		if _, err := projectSvc.RecordChangeOrderDecision(ctx, p.ID, ok.ID, orgID, staffID, domain.ChangeOrderApproved, strings.Repeat("ş", 501)); !errors.Is(err, service.ErrProjectFieldTooLong) {
			t.Errorf("uzun not: beklenen ErrProjectFieldTooLong, geldi %v", err)
		}
	})

	t.Run("closed_project_and_cross_project_refused", func(t *testing.T) {
		p := newProject(t, 10000)
		other := newProject(t, 10000)
		co := newSent(t, p.ID, domain.ChangeOrderAddition, 100)
		// Başka projenin URL'si üzerinden (IDOR) -- kayıt bulunamaz.
		if _, err := projectSvc.RecordChangeOrderDecision(ctx, other.ID, co.ID, orgID, staffID, domain.ChangeOrderApproved, ""); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("çapraz proje: beklenen ErrNotFound, geldi %v", err)
		}
		if _, err := pool.Exec(ctx, "UPDATE projects SET status = $2 WHERE id = $1", p.ID, domain.ProjectStatusCompleted); err != nil {
			t.Fatalf("proje kapatılamadı: %v", err)
		}
		if _, err := projectSvc.RecordChangeOrderDecision(ctx, p.ID, co.ID, orgID, staffID, domain.ChangeOrderApproved, ""); !errors.Is(err, service.ErrProjectLocked) {
			t.Errorf("kapalı proje: beklenen ErrProjectLocked, geldi %v", err)
		}
	})
}
