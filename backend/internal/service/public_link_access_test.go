package service_test

import (
	"context"
	"errors"
	"testing"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

// TestPublicLinksRespectOrganizationAndArchive: askıya alınmış/iptal
// edilmiş/silinmiş bir firmanın ve pasife alınmış bir teklifin müşteri
// linkleri artık açılmaz ve karar kabul etmez (eskiden hepsi çalışıyordu).
// Ek iş (değişiklik emri) linkleri de aynı firma kuralına uyar.
func TestPublicLinksRespectOrganizationAndArchive(t *testing.T) {
	dbURL := testDBURL(t)
	ctx := context.Background()
	pool, err := repository.NewPool(ctx, dbURL)
	if err != nil {
		t.Fatalf("veritabanına bağlanılamadı: %v", err)
	}
	t.Cleanup(func() { pool.Close() })
	q := sqlc.New(pool)
	orgSvc := service.NewOrganizationService(q)
	settingsSvc := service.NewSettingsService(q, testSecretBox(t))
	offerSvc := service.NewOfferService(pool, q, settingsSvc, "http://localhost:3000")
	projectSvc := service.NewProjectService(pool, q, mustTestStore(t), settingsSvc, "http://localhost:3000")

	sentOfferLink := func(t *testing.T, orgID string) (*domain.Offer, string) {
		t.Helper()
		o, err := offerSvc.Create(ctx, service.CreateOfferInput{
			OrganizationID: orgID, CustomerName: "Müşteri",
			Items: []service.OfferItemInput{{ProductName: "Kalem", Quantity: 1, UnitPrice: 100}},
		})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := offerSvc.UpdateStatus(ctx, o.ID, orgID, domain.OfferStatusGonderildi, ""); err != nil {
			t.Fatal(err)
		}
		link, err := offerSvc.CreateShareLink(ctx, o.ID, orgID, "", nil)
		if err != nil {
			t.Fatal(err)
		}
		return o, link.Token
	}
	setOrg := func(t *testing.T, orgID, sql string) {
		t.Helper()
		if _, err := pool.Exec(ctx, "UPDATE organizations SET "+sql+" WHERE id = $1", orgID); err != nil {
			t.Fatal(err)
		}
	}

	t.Run("view_carries_organization_name", func(t *testing.T) {
		org := mustCreateOrg(t, ctx, orgSvc, pool, "Görünen Ad Yapı Ltd", "public-link-ad-test")
		_, token := sentOfferLink(t, org.ID)
		v, err := offerSvc.GetPublicView(ctx, token, "", "")
		if err != nil {
			t.Fatal(err)
		}
		if v.OrganizationName != "Görünen Ad Yapı Ltd" || !v.CanRespond {
			t.Errorf("firma adı/karar bilgisi yanlış: %+v", v)
		}
	})

	for name, sql := range map[string]string{
		"suspended": "status = 'suspended'",
		"cancelled": "status = 'cancelled'",
		"deleted":   "deleted_at = now()",
	} {
		t.Run("offer_link_denied_when_org_"+name, func(t *testing.T) {
			org := mustCreateOrg(t, ctx, orgSvc, pool, "Public Link "+name, "public-link-org-"+name)
			o, token := sentOfferLink(t, org.ID)
			setOrg(t, org.ID, sql)
			if _, err := offerSvc.GetPublicView(ctx, token, "", ""); !errors.Is(err, service.ErrPublicLinkUnavailable) {
				t.Errorf("görüntüleme reddedilmeli: %v", err)
			}
			if _, err := offerSvc.RespondByShareLinkToken(ctx, token, domain.OfferStatusKabulEdildi, "", ""); !errors.Is(err, service.ErrPublicLinkUnavailable) {
				t.Errorf("kabul reddedilmeli: %v", err)
			}
			setOrg(t, org.ID, "status = 'active', deleted_at = NULL")
			got, err := offerSvc.Get(ctx, o.ID, org.ID)
			if err != nil || got.Status != domain.OfferStatusGonderildi {
				t.Errorf("teklif durumu değişmemeli: %v err=%v", got, err)
			}
		})
	}

	t.Run("archived_offer_link_denied_until_unarchived", func(t *testing.T) {
		org := mustCreateOrg(t, ctx, orgSvc, pool, "Public Link Arşiv", "public-link-arsiv")
		o, token := sentOfferLink(t, org.ID)
		if err := offerSvc.TogglePassive(ctx, o.ID, org.ID, ""); err != nil {
			t.Fatal(err)
		}
		if _, err := offerSvc.GetPublicView(ctx, token, "", ""); !errors.Is(err, service.ErrPublicLinkUnavailable) {
			t.Errorf("pasif teklifin linki açılmamalı: %v", err)
		}
		if _, err := offerSvc.RespondByShareLinkToken(ctx, token, domain.OfferStatusKabulEdildi, "", ""); !errors.Is(err, service.ErrPublicLinkUnavailable) {
			t.Errorf("pasif teklif kabul edilmemeli: %v", err)
		}
		if err := offerSvc.TogglePassive(ctx, o.ID, org.ID, ""); err != nil {
			t.Fatal(err)
		}
		if _, err := offerSvc.RespondByShareLinkToken(ctx, token, domain.OfferStatusKabulEdildi, "", ""); err != nil {
			t.Errorf("arşivden çıkan teklifin linki yeniden çalışmalı: %v", err)
		}
	})

	t.Run("change_order_link_denied_when_org_suspended", func(t *testing.T) {
		org := mustCreateOrg(t, ctx, orgSvc, pool, "Public Link Ek İş", "public-link-ek-is")
		o, token := sentOfferLink(t, org.ID)
		if _, err := offerSvc.RespondByShareLinkToken(ctx, token, domain.OfferStatusKabulEdildi, "", ""); err != nil {
			t.Fatal(err)
		}
		p, err := projectSvc.CreateFromOffer(ctx, o.ID, org.ID, service.CreateProjectInput{Name: "Ek İş Projesi"})
		if err != nil {
			t.Fatal(err)
		}
		co, err := projectSvc.CreateChangeOrder(ctx, p.ID, org.ID, service.ChangeOrderInput{
			ChangeType: domain.ChangeOrderAddition, Title: "Ek",
			Items: []service.ChangeOrderItemInput{{Description: "Kalem", Quantity: 1, Unit: "adet", UnitPrice: 500}},
		})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := projectSvc.SendChangeOrder(ctx, p.ID, co.ID, org.ID, ""); err != nil {
			t.Fatal(err)
		}
		var coToken string
		if err := pool.QueryRow(ctx, `SELECT token::text FROM project_change_order_share_links
			WHERE change_order_id = $1 AND revoked_at IS NULL ORDER BY created_at DESC LIMIT 1`, co.ID).Scan(&coToken); err != nil {
			t.Fatal(err)
		}
		v, err := projectSvc.GetChangeOrderByShareLinkToken(ctx, coToken, "", "")
		if err != nil || v.OrganizationName != "Public Link Ek İş" {
			t.Fatalf("ek iş görünümü firma adını taşımalı: %+v err=%v", v, err)
		}

		setOrg(t, org.ID, "status = 'suspended'")
		if _, err := projectSvc.GetChangeOrderByShareLinkToken(ctx, coToken, "", ""); !errors.Is(err, service.ErrPublicLinkUnavailable) {
			t.Errorf("askıdaki firmanın ek iş linki açılmamalı: %v", err)
		}
		if _, err := projectSvc.RespondChangeOrderByShareLinkToken(ctx, coToken, domain.ChangeOrderApproved, "", ""); !errors.Is(err, service.ErrPublicLinkUnavailable) {
			t.Errorf("askıdaki firmanın ek işi onaylanmamalı: %v", err)
		}
		setOrg(t, org.ID, "status = 'active'")
	})
}
