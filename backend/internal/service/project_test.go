package service_test

// Faz 5 (Tekliften Projeye Dönüşüm) için otomatik testler -- gerçek bir
// PostgreSQL bağlantısı gerektirir (bkz. tenant_isolation_test.go'daki
// testDBURL/testSecretBox/mustCreateOrg/cleanupOrganization yardımcıları,
// aynı pakette paylaşılır).

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

func TestProjectsFromOffers(t *testing.T) {
	dbURL := testDBURL(t)
	box := testSecretBox(t)
	ctx := context.Background()

	pool, err := repository.NewPool(ctx, dbURL)
	if err != nil {
		t.Fatalf("veritabanına bağlanılamadı: %v", err)
	}
	t.Cleanup(func() { pool.Close() })

	q := sqlc.New(pool)
	orgSvc := service.NewOrganizationService(q)
	settingsSvc := service.NewSettingsService(q, box)
	offerSvc := service.NewOfferService(pool, q, settingsSvc, "http://localhost:3000")
	projectSvc := service.NewProjectService(pool, q, mustTestStore(t))
	customerSvc := service.NewCustomerService(q)

	orgA := mustCreateOrg(t, ctx, orgSvc, pool, "Proje Test Firma A", "proje-test-firma-a")
	orgB := mustCreateOrg(t, ctx, orgSvc, pool, "Proje Test Firma B", "proje-test-firma-b")

	// newOffer, verilen durumda bir teklif üretir. "kabul edildi" için
	// gerçek akış izlenir: gönder -> paylaşım linki -> müşteri kabul eder.
	newOffer := func(t *testing.T, orgID, status string) *domain.Offer {
		t.Helper()
		o, err := offerSvc.Create(ctx, service.CreateOfferInput{
			OrganizationID: orgID,
			CustomerName:   "Proje Test Müşteri",
			CustomerPhone:  "5551112233",
			CustomerEmail:  "proje@example.com",
			Items:          []service.OfferItemInput{{ProductName: "Kaba İnşaat", Quantity: 1, UnitPrice: 1000}},
		})
		if err != nil {
			t.Fatalf("teklif oluşturulamadı: %v", err)
		}
		if status == domain.OfferStatusTaslak {
			return o
		}
		if _, err := offerSvc.UpdateStatus(ctx, o.ID, orgID, domain.OfferStatusGonderildi, ""); err != nil {
			t.Fatalf("teklif gönderilemedi: %v", err)
		}
		if status == domain.OfferStatusGonderildi {
			return o
		}
		link, err := offerSvc.CreateShareLink(ctx, o.ID, orgID, "", nil)
		if err != nil {
			t.Fatalf("link oluşturulamadı: %v", err)
		}
		decided, err := offerSvc.RespondByShareLinkToken(ctx, link.Token, status, "", "")
		if err != nil {
			t.Fatalf("müşteri kararı uygulanamadı (%s): %v", status, err)
		}
		return decided
	}

	t.Run("1_accepted_current_revision_converts", func(t *testing.T) {
		o := newOffer(t, orgA.ID, domain.OfferStatusKabulEdildi)
		start := time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)
		p, err := projectSvc.CreateFromOffer(ctx, o.ID, orgA.ID, service.CreateProjectInput{
			Name: "Villa İnşaatı", ProjectType: "İnşaat", StartDate: &start,
		})
		if err != nil {
			t.Fatalf("proje oluşturulamadı: %v", err)
		}
		if p.ProjectNo == "" || p.Status != domain.ProjectStatusPlanned {
			t.Errorf("beklenmeyen proje: no=%q status=%q", p.ProjectNo, p.Status)
		}
		// Sözleşme bedeli ve müşteri bilgileri kabul edilen revizyondan
		// snapshot alınmalı.
		if p.ContractAmount != o.GrandTotal {
			t.Errorf("contract_amount revizyondan alınmadı: %v want %v", p.ContractAmount, o.GrandTotal)
		}
		if p.CustomerName != o.CustomerName || p.CustomerPhone != o.CustomerPhone {
			t.Errorf("müşteri snapshot'ı kopyalanmadı: %+v", p)
		}
		if p.SourceOfferID != o.ID || p.SourceRevisionID != o.CurrentRevisionID {
			t.Errorf("kaynak teklif/revizyon yanlış: %+v", p)
		}
		if p.SourceOfferNo != o.OfferNo {
			t.Errorf("kaynak teklif numarası doldurulmadı: %q", p.SourceOfferNo)
		}
	})

	t.Run("2_draft_revision_cannot_convert", func(t *testing.T) {
		o := newOffer(t, orgA.ID, domain.OfferStatusTaslak)
		if _, err := projectSvc.CreateFromOffer(ctx, o.ID, orgA.ID, service.CreateProjectInput{}); !errors.Is(err, service.ErrOfferNotAccepted) {
			t.Errorf("taslak teklif projeye dönüştürülebildi: err=%v", err)
		}
	})

	t.Run("3_sent_revision_cannot_convert", func(t *testing.T) {
		o := newOffer(t, orgA.ID, domain.OfferStatusGonderildi)
		if _, err := projectSvc.CreateFromOffer(ctx, o.ID, orgA.ID, service.CreateProjectInput{}); !errors.Is(err, service.ErrOfferNotAccepted) {
			t.Errorf("gönderilmiş teklif projeye dönüştürülebildi: err=%v", err)
		}
	})

	t.Run("4_rejected_revision_cannot_convert", func(t *testing.T) {
		o := newOffer(t, orgA.ID, domain.OfferStatusReddedildi)
		if _, err := projectSvc.CreateFromOffer(ctx, o.ID, orgA.ID, service.CreateProjectInput{}); !errors.Is(err, service.ErrOfferNotAccepted) {
			t.Errorf("reddedilmiş teklif projeye dönüştürülebildi: err=%v", err)
		}
	})

	t.Run("5_same_revision_converts_only_once", func(t *testing.T) {
		o := newOffer(t, orgA.ID, domain.OfferStatusKabulEdildi)
		first, err := projectSvc.CreateFromOffer(ctx, o.ID, orgA.ID, service.CreateProjectInput{Name: "İlk"})
		if err != nil {
			t.Fatalf("ilk proje oluşturulamadı: %v", err)
		}
		second, err := projectSvc.CreateFromOffer(ctx, o.ID, orgA.ID, service.CreateProjectInput{Name: "İkinci"})
		if err != nil {
			t.Fatalf("ikinci çağrı hata verdi (idempotent olmalıydı): %v", err)
		}
		if second.ID != first.ID {
			t.Errorf("aynı revizyondan ikinci bir proje oluştu: %s != %s", second.ID, first.ID)
		}
		if second.Name != first.Name {
			t.Errorf("ikinci çağrı mevcut projeyi değiştirdi: %q -> %q", first.Name, second.Name)
		}
	})

	t.Run("6_concurrent_create_produces_single_project", func(t *testing.T) {
		o := newOffer(t, orgA.ID, domain.OfferStatusKabulEdildi)

		var wg sync.WaitGroup
		results := make([]*domain.Project, 2)
		errs := make([]error, 2)
		for i := range 2 {
			wg.Add(1)
			go func(i int) {
				defer wg.Done()
				results[i], errs[i] = projectSvc.CreateFromOffer(ctx, o.ID, orgA.ID, service.CreateProjectInput{})
			}(i)
		}
		wg.Wait()

		for i, e := range errs {
			if e != nil {
				t.Fatalf("eşzamanlı çağrı #%d hata verdi: %v", i, e)
			}
		}
		if results[0].ID != results[1].ID {
			t.Fatalf("eşzamanlı çift tıklama İKİ proje üretti: %s != %s", results[0].ID, results[1].ID)
		}
		list, err := projectSvc.List(ctx, orgA.ID, service.ProjectListFilter{Limit: 200})
		if err != nil {
			t.Fatalf("liste alınamadı: %v", err)
		}
		count := 0
		for _, p := range list.Projects {
			if p.SourceOfferID == o.ID {
				count++
			}
		}
		if count != 1 {
			t.Errorf("bu teklif için beklenen proje sayısı 1, geldi: %d", count)
		}
	})

	t.Run("7_project_number_is_per_tenant_and_year", func(t *testing.T) {
		oA := newOffer(t, orgA.ID, domain.OfferStatusKabulEdildi)
		oB := newOffer(t, orgB.ID, domain.OfferStatusKabulEdildi)
		pA, err := projectSvc.CreateFromOffer(ctx, oA.ID, orgA.ID, service.CreateProjectInput{})
		if err != nil {
			t.Fatalf("A projesi oluşturulamadı: %v", err)
		}
		pB, err := projectSvc.CreateFromOffer(ctx, oB.ID, orgB.ID, service.CreateProjectInput{})
		if err != nil {
			t.Fatalf("B projesi oluşturulamadı: %v", err)
		}
		year := time.Now().Year()
		// Firma B bu testte ilk projesini oluşturuyor -> her zaman 0001.
		wantB := fmt.Sprintf("PRJ-%d-0001", year)
		if pB.ProjectNo != wantB {
			t.Errorf("firma B'nin sayacı bağımsız değil: %q want %q", pB.ProjectNo, wantB)
		}
		if pA.ProjectNo == pB.ProjectNo {
			t.Errorf("iki firma aynı proje numarasını aldı: %q", pA.ProjectNo)
		}
		if !strings.HasPrefix(pA.ProjectNo, fmt.Sprintf("PRJ-%d-", year)) {
			t.Errorf("proje numarası formatı beklenmedik: %q", pA.ProjectNo)
		}
	})

	t.Run("8_cross_org_project_not_visible", func(t *testing.T) {
		o := newOffer(t, orgA.ID, domain.OfferStatusKabulEdildi)
		p, err := projectSvc.CreateFromOffer(ctx, o.ID, orgA.ID, service.CreateProjectInput{})
		if err != nil {
			t.Fatalf("proje oluşturulamadı: %v", err)
		}
		if _, err := projectSvc.Get(ctx, p.ID, orgB.ID); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("Firma B, Firma A'nın projesini görebildi: err=%v", err)
		}
		if _, err := projectSvc.Update(ctx, p.ID, orgB.ID, service.UpdateProjectInput{Name: "HACKED"}); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("Firma B, Firma A'nın projesini düzenleyebildi: err=%v", err)
		}
	})

	t.Run("9_cross_org_source_offer_cannot_be_used", func(t *testing.T) {
		o := newOffer(t, orgA.ID, domain.OfferStatusKabulEdildi)
		// Firma B, Firma A'nın teklif UUID'sini bilse bile kendi altında
		// proje açamamalı.
		if _, err := projectSvc.CreateFromOffer(ctx, o.ID, orgB.ID, service.CreateProjectInput{}); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("Firma B, Firma A'nın teklifinden proje oluşturabildi: err=%v", err)
		}
	})

	t.Run("10_cross_org_customer_is_not_linked", func(t *testing.T) {
		// Firma B'nin müşteri kartı, Firma A'nın teklifine zaten
		// bağlanamaz (Faz 2 kuralı); dolayısıyla projeye de sızamaz.
		custB, err := customerSvc.Create(ctx, orgB.ID, service.CustomerInput{Name: "Firma B Müşterisi"})
		if err != nil {
			t.Fatalf("müşteri oluşturulamadı: %v", err)
		}
		custBID := custB.ID
		if _, err := offerSvc.Create(ctx, service.CreateOfferInput{
			OrganizationID: orgA.ID,
			CustomerID:     &custBID,
			Items:          []service.OfferItemInput{{ProductName: "X", Quantity: 1, UnitPrice: 1}},
		}); err == nil {
			t.Errorf("Firma A, Firma B'nin müşterisine bağlı teklif oluşturabildi")
		}

		// Kendi müşterisiyle açılan teklifte customer_id projeye doğru taşınmalı.
		custA, err := customerSvc.Create(ctx, orgA.ID, service.CustomerInput{Name: "Firma A Müşterisi", Phone: "555"})
		if err != nil {
			t.Fatalf("müşteri oluşturulamadı: %v", err)
		}
		custAID := custA.ID
		o, err := offerSvc.Create(ctx, service.CreateOfferInput{
			OrganizationID: orgA.ID,
			CustomerID:     &custAID,
			Items:          []service.OfferItemInput{{ProductName: "İş", Quantity: 1, UnitPrice: 500}},
		})
		if err != nil {
			t.Fatalf("teklif oluşturulamadı: %v", err)
		}
		if _, err := offerSvc.UpdateStatus(ctx, o.ID, orgA.ID, domain.OfferStatusGonderildi, ""); err != nil {
			t.Fatalf("gönderilemedi: %v", err)
		}
		link, err := offerSvc.CreateShareLink(ctx, o.ID, orgA.ID, "", nil)
		if err != nil {
			t.Fatalf("link oluşturulamadı: %v", err)
		}
		if _, err := offerSvc.RespondByShareLinkToken(ctx, link.Token, domain.OfferStatusKabulEdildi, "", ""); err != nil {
			t.Fatalf("kabul edilemedi: %v", err)
		}
		p, err := projectSvc.CreateFromOffer(ctx, o.ID, orgA.ID, service.CreateProjectInput{})
		if err != nil {
			t.Fatalf("proje oluşturulamadı: %v", err)
		}
		if p.CustomerID == nil || *p.CustomerID != custAID {
			t.Errorf("kendi müşteri kartı projeye taşınmadı: %v", p.CustomerID)
		}
	})

	t.Run("11_source_revision_frozen_after_conversion", func(t *testing.T) {
		o := newOffer(t, orgA.ID, domain.OfferStatusKabulEdildi)
		p, err := projectSvc.CreateFromOffer(ctx, o.ID, orgA.ID, service.CreateProjectInput{})
		if err != nil {
			t.Fatalf("proje oluşturulamadı: %v", err)
		}
		before, err := offerSvc.GetRevision(ctx, p.SourceRevisionID, orgA.ID)
		if err != nil {
			t.Fatalf("revizyon okunamadı: %v", err)
		}
		// Kabul edilmiş teklif zaten kilitli: ne düzenlenebilir ne revize
		// edilebilir -- yani projenin kaynağı donmuş kalır.
		if _, err := offerSvc.Update(ctx, o.ID, orgA.ID, service.UpdateOfferInput{
			CustomerName: "Değişti",
			Items:        []service.OfferItemInput{{ProductName: "Y", Quantity: 9, UnitPrice: 9}},
		}); !errors.Is(err, service.ErrOfferNotEditable) {
			t.Errorf("kabul edilmiş teklif düzenlenebildi: err=%v", err)
		}
		if _, err := offerSvc.Revise(ctx, o.ID, orgA.ID, ""); !errors.Is(err, service.ErrOfferNotRevisable) {
			t.Errorf("kabul edilmiş teklif revize edilebildi: err=%v", err)
		}
		after, err := offerSvc.GetRevision(ctx, p.SourceRevisionID, orgA.ID)
		if err != nil {
			t.Fatalf("revizyon tekrar okunamadı: %v", err)
		}
		if before.GrandTotal != after.GrandTotal || before.CustomerName != after.CustomerName || before.Status != after.Status {
			t.Errorf("kaynak revizyon değişti: önce=%+v sonra=%+v", before, after)
		}
		// Projenin snapshot'ı da revizyonla tutarlı kalmalı.
		refetched, err := projectSvc.Get(ctx, p.ID, orgA.ID)
		if err != nil {
			t.Fatalf("proje okunamadı: %v", err)
		}
		if refetched.ContractAmount != after.GrandTotal {
			t.Errorf("proje sözleşme bedeli kaynak revizyondan sapmış: %v != %v", refetched.ContractAmount, after.GrandTotal)
		}
	})

	t.Run("12_offer_timeline_gets_project_created_event", func(t *testing.T) {
		o := newOffer(t, orgA.ID, domain.OfferStatusKabulEdildi)
		p, err := projectSvc.CreateFromOffer(ctx, o.ID, orgA.ID, service.CreateProjectInput{})
		if err != nil {
			t.Fatalf("proje oluşturulamadı: %v", err)
		}
		events, err := offerSvc.ListEvents(ctx, o.ID, orgA.ID)
		if err != nil {
			t.Fatalf("olaylar alınamadı: %v", err)
		}
		var found *domain.OfferEvent
		for i, e := range events {
			if e.EventType == domain.EventProjectCreated {
				found = &events[i]
			}
		}
		if found == nil {
			t.Fatalf("teklif zaman çizelgesinde project_created olayı yok")
		}
		if got, _ := found.Metadata["project_id"].(string); got != p.ID {
			t.Errorf("metadata.project_id yanlış: %v want %s", found.Metadata["project_id"], p.ID)
		}
		if got, _ := found.Metadata["project_no"].(string); got != p.ProjectNo {
			t.Errorf("metadata.project_no yanlış: %v want %s", found.Metadata["project_no"], p.ProjectNo)
		}
		if got, _ := found.Metadata["source_revision_id"].(string); got != p.SourceRevisionID {
			t.Errorf("metadata.source_revision_id yanlış: %v", found.Metadata["source_revision_id"])
		}
	})

	t.Run("13_update_cannot_change_immutable_fields", func(t *testing.T) {
		o := newOffer(t, orgA.ID, domain.OfferStatusKabulEdildi)
		p, err := projectSvc.CreateFromOffer(ctx, o.ID, orgA.ID, service.CreateProjectInput{Name: "İlk Ad"})
		if err != nil {
			t.Fatalf("proje oluşturulamadı: %v", err)
		}
		updated, err := projectSvc.Update(ctx, p.ID, orgA.ID, service.UpdateProjectInput{
			Name:        "Yeni Ad",
			ProjectType: "Tadilat",
			Status:      domain.ProjectStatusActive,
			Description: "açıklama",
		})
		if err != nil {
			t.Fatalf("proje düzenlenemedi: %v", err)
		}
		if updated.Name != "Yeni Ad" || updated.Status != domain.ProjectStatusActive {
			t.Errorf("düzenlenebilir alanlar güncellenmedi: %+v", updated)
		}
		// Değiştirilemez alanlar aynı kalmalı -- UpdateProjectInput bunları
		// hiç taşımıyor, yani API üzerinden değiştirmenin bir yolu yok.
		if updated.ProjectNo != p.ProjectNo ||
			updated.SourceOfferID != p.SourceOfferID ||
			updated.SourceRevisionID != p.SourceRevisionID ||
			updated.ContractAmount != p.ContractAmount ||
			updated.Currency != p.Currency {
			t.Errorf("değiştirilemez alanlar değişti:\nönce=%+v\nsonra=%+v", p, updated)
		}

		// Tamamlanmış proje YALNIZCA "active"e dönebilir (Faz 6: finans
		// hareketi girmek için bilinçli yeniden açma); başka bir duruma
		// geçiş reddedilmeli.
		if _, err := projectSvc.Update(ctx, p.ID, orgA.ID, service.UpdateProjectInput{
			Name: "Yeni Ad", Status: domain.ProjectStatusCompleted,
		}); err != nil {
			t.Fatalf("tamamlandı durumuna geçilemedi: %v", err)
		}
		if _, err := projectSvc.Update(ctx, p.ID, orgA.ID, service.UpdateProjectInput{
			Name: "Yeni Ad", Status: domain.ProjectStatusPaused,
		}); !errors.Is(err, service.ErrInvalidProjectState) {
			t.Errorf("tamamlanmış proje beklemeye alınabildi: err=%v", err)
		}
		if _, err := projectSvc.Update(ctx, p.ID, orgA.ID, service.UpdateProjectInput{
			Name: "Yeni Ad", Status: domain.ProjectStatusActive,
		}); err != nil {
			t.Errorf("tamamlanmış proje yeniden açılamadı: %v", err)
		}
	})

	t.Run("14_list_returns_only_active_organization", func(t *testing.T) {
		o := newOffer(t, orgA.ID, domain.OfferStatusKabulEdildi)
		p, err := projectSvc.CreateFromOffer(ctx, o.ID, orgA.ID, service.CreateProjectInput{Name: "Liste Testi"})
		if err != nil {
			t.Fatalf("proje oluşturulamadı: %v", err)
		}
		listB, err := projectSvc.List(ctx, orgB.ID, service.ProjectListFilter{Limit: 200})
		if err != nil {
			t.Fatalf("liste alınamadı: %v", err)
		}
		for _, item := range listB.Projects {
			if item.ID == p.ID {
				t.Fatalf("Firma B'nin listesinde Firma A'nın projesi göründü")
			}
			if item.OrganizationID != orgB.ID {
				t.Fatalf("listede başka organizasyonun kaydı var: %s", item.OrganizationID)
			}
		}
		listA, err := projectSvc.List(ctx, orgA.ID, service.ProjectListFilter{Limit: 200})
		if err != nil {
			t.Fatalf("liste alınamadı: %v", err)
		}
		seen := false
		for _, item := range listA.Projects {
			if item.ID == p.ID {
				seen = true
			}
		}
		if !seen {
			t.Errorf("Firma A kendi projesini listede göremedi")
		}

		// Durum filtresi
		filtered, err := projectSvc.List(ctx, orgA.ID, service.ProjectListFilter{
			Status: domain.ProjectStatusPlanned, Limit: 200,
		})
		if err != nil {
			t.Fatalf("filtreli liste alınamadı: %v", err)
		}
		for _, item := range filtered.Projects {
			if item.Status != domain.ProjectStatusPlanned {
				t.Errorf("durum filtresi çalışmadı: %s", item.Status)
			}
		}
		// Arama filtresi
		searched, err := projectSvc.List(ctx, orgA.ID, service.ProjectListFilter{Search: "Liste Testi", Limit: 200})
		if err != nil {
			t.Fatalf("aramalı liste alınamadı: %v", err)
		}
		if len(searched.Projects) == 0 {
			t.Errorf("arama filtresi projeyi bulamadı")
		}
	})
}
