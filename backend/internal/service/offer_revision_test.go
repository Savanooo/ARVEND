package service_test

// Faz 3 (Revizyon Sistemi) için 9 senaryonun otomatik testi -- gerçek bir
// PostgreSQL bağlantısı gerektirir (bkz. tenant_isolation_test.go'daki
// testDBURL/mustCreateOrg/cleanupOrganization yardımcıları, aynı pakette
// paylaşılır).

import (
	"context"
	"errors"
	"sync"
	"testing"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

func TestOfferRevisions(t *testing.T) {
	dbURL := testDBURL(t)
	ctx := context.Background()

	pool, err := repository.NewPool(ctx, dbURL)
	if err != nil {
		t.Fatalf("veritabanına bağlanılamadı: %v", err)
	}
	t.Cleanup(func() { pool.Close() })

	q := sqlc.New(pool)
	orgSvc := service.NewOrganizationService(q)
	offerSvc := service.NewOfferService(pool, q)
	productSvc := service.NewProductService(q)

	orgA := mustCreateOrg(t, ctx, orgSvc, pool, "Revizyon Test Firma A", "revizyon-test-firma-a")
	orgB := mustCreateOrg(t, ctx, orgSvc, pool, "Revizyon Test Firma B", "revizyon-test-firma-b")

	newOffer := func(t *testing.T, orgID string) *domain.Offer {
		t.Helper()
		o, err := offerSvc.Create(ctx, service.CreateOfferInput{
			OrganizationID: orgID,
			CustomerName:   "Revizyon Test Müşteri",
			Items:          []service.OfferItemInput{{ProductName: "Kalem", Quantity: 1, UnitPrice: 100}},
		})
		if err != nil {
			t.Fatalf("teklif oluşturulamadı: %v", err)
		}
		return o
	}

	t.Run("1_draft_edit_does_not_increment_revision", func(t *testing.T) {
		o := newOffer(t, orgA.ID)
		if o.RevisionNo != 0 {
			t.Fatalf("yeni tekliflin ilk revizyonu 0 olmalı, geldi: %d", o.RevisionNo)
		}
		updated, err := offerSvc.Update(ctx, o.ID, orgA.ID, service.UpdateOfferInput{
			CustomerName: "Değişti",
			Items:        []service.OfferItemInput{{ProductName: "Kalem", Quantity: 2, UnitPrice: 100}},
		})
		if err != nil {
			t.Fatalf("taslak teklif düzenlenemedi: %v", err)
		}
		if updated.RevisionNo != 0 {
			t.Errorf("taslak düzenlemesi revizyon numarasını artırdı: %d", updated.RevisionNo)
		}
		revisions, err := offerSvc.ListRevisions(ctx, o.ID, orgA.ID)
		if err != nil {
			t.Fatalf("revizyon listesi alınamadı: %v", err)
		}
		if len(revisions) != 1 {
			t.Errorf("taslak düzenlemesi sonrası beklenen revizyon sayısı 1, geldi: %d", len(revisions))
		}
	})

	t.Run("2_sent_offer_cannot_be_edited_directly", func(t *testing.T) {
		o := newOffer(t, orgA.ID)
		if _, err := offerSvc.UpdateStatus(ctx, o.ID, orgA.ID, domain.OfferStatusGonderildi); err != nil {
			t.Fatalf("durum güncellenemedi: %v", err)
		}
		_, err := offerSvc.Update(ctx, o.ID, orgA.ID, service.UpdateOfferInput{
			CustomerName: "Direkt Değişiklik",
			Items:        []service.OfferItemInput{{ProductName: "X", Quantity: 1, UnitPrice: 1}},
		})
		if !errors.Is(err, service.ErrOfferNotEditable) {
			t.Errorf("gönderilmiş teklif doğrudan düzenlenebildi: err=%v", err)
		}
	})

	t.Run("3_revise_creates_new_revision", func(t *testing.T) {
		o := newOffer(t, orgA.ID)
		if _, err := offerSvc.UpdateStatus(ctx, o.ID, orgA.ID, domain.OfferStatusGonderildi); err != nil {
			t.Fatalf("durum güncellenemedi: %v", err)
		}
		revised, err := offerSvc.Revise(ctx, o.ID, orgA.ID, "")
		if err != nil {
			t.Fatalf("revize edilemedi: %v", err)
		}
		if revised.RevisionNo != 1 {
			t.Errorf("beklenen revizyon no 1, geldi: %d", revised.RevisionNo)
		}
		if revised.Status != domain.OfferStatusTaslak {
			t.Errorf("yeni revizyon taslak olarak başlamadı: %s", revised.Status)
		}
		revisions, err := offerSvc.ListRevisions(ctx, o.ID, orgA.ID)
		if err != nil {
			t.Fatalf("revizyon listesi alınamadı: %v", err)
		}
		if len(revisions) != 2 {
			t.Errorf("beklenen revizyon sayısı 2, geldi: %d", len(revisions))
		}
	})

	t.Run("4_old_revision_immutable", func(t *testing.T) {
		o := newOffer(t, orgA.ID)
		rev0ID := o.CurrentRevisionID
		if _, err := offerSvc.UpdateStatus(ctx, o.ID, orgA.ID, domain.OfferStatusGonderildi); err != nil {
			t.Fatalf("durum güncellenemedi: %v", err)
		}
		if _, err := offerSvc.Revise(ctx, o.ID, orgA.ID, ""); err != nil {
			t.Fatalf("revize edilemedi: %v", err)
		}
		before, err := offerSvc.GetRevision(ctx, rev0ID, orgA.ID)
		if err != nil {
			t.Fatalf("eski revizyon okunamadı: %v", err)
		}
		// Update() artık current (revizyon 1) üzerinde çalışır -- rev0'ı
		// hedefleyen hiçbir genel API yolu yoktur.
		if _, err := offerSvc.Update(ctx, o.ID, orgA.ID, service.UpdateOfferInput{
			CustomerName: "Yeni İçerik",
			Items:        []service.OfferItemInput{{ProductName: "Yeni Kalem", Quantity: 5, UnitPrice: 500}},
		}); err != nil {
			t.Fatalf("yeni revizyon düzenlenemedi: %v", err)
		}
		after, err := offerSvc.GetRevision(ctx, rev0ID, orgA.ID)
		if err != nil {
			t.Fatalf("eski revizyon tekrar okunamadı: %v", err)
		}
		if before.CustomerName != after.CustomerName || before.GrandTotal != after.GrandTotal {
			t.Errorf("eski revizyonun içeriği değişti: önce=%+v sonra=%+v", before, after)
		}
	})

	t.Run("5_cross_org_revision_isolation", func(t *testing.T) {
		o := newOffer(t, orgA.ID)
		if _, err := offerSvc.UpdateStatus(ctx, o.ID, orgA.ID, domain.OfferStatusGonderildi); err != nil {
			t.Fatalf("durum güncellenemedi: %v", err)
		}
		if _, err := offerSvc.GetRevision(ctx, o.CurrentRevisionID, orgB.ID); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("Firma B, Firma A'nın revizyonunu görebildi: err=%v", err)
		}
		revisions, err := offerSvc.ListRevisions(ctx, o.ID, orgB.ID)
		if err != nil {
			t.Fatalf("liste alınamadı: %v", err)
		}
		if len(revisions) != 0 {
			t.Errorf("Firma B, Firma A'nın revizyon listesini görebildi")
		}
		if _, err := offerSvc.Revise(ctx, o.ID, orgB.ID, ""); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("Firma B, Firma A'nın teklifini revize edebildi: err=%v", err)
		}
	})

	t.Run("6_cross_org_product_in_revision_item", func(t *testing.T) {
		product, err := productSvc.Create(ctx, orgB.ID, "Firma B Ürünü (Revizyon Testi)", "adet", 10, "", "")
		if err != nil {
			t.Fatalf("ürün oluşturulamadı: %v", err)
		}
		productIDStr := product.ID
		o, err := offerSvc.Create(ctx, service.CreateOfferInput{
			OrganizationID: orgA.ID,
			CustomerName:   "Test",
			Items:          []service.OfferItemInput{{ProductID: &productIDStr, ProductName: "Sizin Ürününüz", Quantity: 1, UnitPrice: 1}},
		})
		if err != nil {
			t.Fatalf("teklif oluşturulamadı: %v", err)
		}
		if len(o.Items) != 1 {
			t.Fatalf("beklenmeyen kalem sayısı: %d", len(o.Items))
		}
		if o.Items[0].ProductID != nil {
			t.Errorf("Firma A'nın teklifi, Firma B'nin product_id'sine referans veriyor: %v", *o.Items[0].ProductID)
		}
	})

	// "Revize Et" çağrıldığı anda teklifi 'taslak'a döndürdüğünden (bir
	// sonraki adım normal Update() ile fiyat değiştirmektir), aynı teklif
	// üzerinde İKİ eşzamanlı Revise() çağrısının İKİSİNİN DE başarılı
	// olması iş kuralına aykırı olurdu -- ikincisi, birincinin commit'i
	// sonrası teklifin artık 'taslak' olduğunu görüp ErrOfferNotRevisable
	// ile TEMİZ biçimde reddedilmelidir. Asıl test edilen şey budur: kilit
	// olmasaydı ikinci istek ya aynı revision_no'yu üretmeye çalışıp
	// UNIQUE ihlaliyle çökerdi ya da birincinin verisini bozardı; kilitle
	// ikinci istek güvenli, öngörülebilir bir iş kuralı hatası alır.
	t.Run("7_concurrent_revise_no_duplicate_revision_no", func(t *testing.T) {
		o := newOffer(t, orgA.ID)
		if _, err := offerSvc.UpdateStatus(ctx, o.ID, orgA.ID, domain.OfferStatusGonderildi); err != nil {
			t.Fatalf("durum güncellenemedi: %v", err)
		}

		var wg sync.WaitGroup
		results := make([]*domain.Offer, 2)
		errs := make([]error, 2)
		for i := range 2 {
			wg.Add(1)
			go func(i int) {
				defer wg.Done()
				results[i], errs[i] = offerSvc.Revise(ctx, o.ID, orgA.ID, "")
			}(i)
		}
		wg.Wait()

		successCount, lockRejectCount := 0, 0
		var successRevisionNo int
		for i, e := range errs {
			switch {
			case e == nil:
				successCount++
				successRevisionNo = results[i].RevisionNo
			case errors.Is(e, service.ErrOfferNotRevisable):
				lockRejectCount++
			default:
				t.Fatalf("eşzamanlı Revise() #%d beklenmeyen hata verdi (kilit çalışmamış olabilir): %v", i, e)
			}
		}
		if successCount != 1 || lockRejectCount != 1 {
			t.Fatalf("beklenen 1 başarı + 1 temiz ret, geldi: %d başarı, %d ret (errs=%v)", successCount, lockRejectCount, errs)
		}
		if successRevisionNo != 1 {
			t.Errorf("beklenen revizyon no 1, geldi: %d", successRevisionNo)
		}
		revisions, err := offerSvc.ListRevisions(ctx, o.ID, orgA.ID)
		if err != nil {
			t.Fatalf("liste alınamadı: %v", err)
		}
		if len(revisions) != 2 { // 0 (ilk) + 1 (başarılı revize)
			t.Errorf("beklenen revizyon sayısı 2, geldi: %d", len(revisions))
		}
		// Aynı (offer_id, revision_no) çiftinin asla iki kez yazılmadığını
		// UNIQUE kısıtının kendisi zaten garanti eder -- ikinci istek
		// çakışan bir INSERT'e hiç ulaşmadan iş kuralında elendi.
	})

	t.Run("8_only_current_revision_respondable", func(t *testing.T) {
		o := newOffer(t, orgA.ID)
		rev0ID := o.CurrentRevisionID
		shareToken := o.ShareToken
		if _, err := offerSvc.UpdateStatus(ctx, o.ID, orgA.ID, domain.OfferStatusGonderildi); err != nil {
			t.Fatalf("durum güncellenemedi: %v", err)
		}
		if _, err := offerSvc.Revise(ctx, o.ID, orgA.ID, ""); err != nil {
			t.Fatalf("revize edilemedi: %v", err)
		}
		// Yeni revizyon henüz taslak -- müşteri karar veremez.
		if _, err := offerSvc.RespondByShareToken(ctx, shareToken, domain.OfferStatusKabulEdildi); !errors.Is(err, service.ErrOfferNotRespondable) {
			t.Errorf("taslak durumundaki yeni revizyona karar verilebildi: err=%v", err)
		}
		if _, err := offerSvc.UpdateStatus(ctx, o.ID, orgA.ID, domain.OfferStatusGonderildi); err != nil {
			t.Fatalf("yeni revizyon gönderilemedi: %v", err)
		}
		accepted, err := offerSvc.RespondByShareToken(ctx, shareToken, domain.OfferStatusKabulEdildi)
		if err != nil {
			t.Fatalf("kabul işlemi başarısız: %v", err)
		}
		if accepted.RevisionNo != 1 {
			t.Errorf("kabul kararı yanlış revizyona uygulandı: revision_no=%d", accepted.RevisionNo)
		}
		rev0, err := offerSvc.GetRevision(ctx, rev0ID, orgA.ID)
		if err != nil {
			t.Fatalf("eski revizyon okunamadı: %v", err)
		}
		if rev0.Status != domain.OfferStatusGonderildi {
			t.Errorf("eski (0.) revizyonun durumu müşteri kararından etkilendi: %s", rev0.Status)
		}
	})

	t.Run("9_accepted_revision_stays_unchanged", func(t *testing.T) {
		o := newOffer(t, orgA.ID)
		if _, err := offerSvc.UpdateStatus(ctx, o.ID, orgA.ID, domain.OfferStatusGonderildi); err != nil {
			t.Fatalf("durum güncellenemedi: %v", err)
		}
		accepted, err := offerSvc.RespondByShareToken(ctx, o.ShareToken, domain.OfferStatusKabulEdildi)
		if err != nil {
			t.Fatalf("kabul işlemi başarısız: %v", err)
		}
		if _, err := offerSvc.UpdateStatus(ctx, o.ID, orgA.ID, domain.OfferStatusReddedildi); !errors.Is(err, service.ErrOfferLocked) {
			t.Errorf("kabul edilmiş teklifin durumu yine de değiştirilebildi: err=%v", err)
		}
		if _, err := offerSvc.Revise(ctx, o.ID, orgA.ID, ""); !errors.Is(err, service.ErrOfferNotRevisable) {
			t.Errorf("kabul edilmiş teklif yine de revize edilebildi: err=%v", err)
		}
		refetched, err := offerSvc.Get(ctx, o.ID, orgA.ID)
		if err != nil {
			t.Fatalf("teklif tekrar okunamadı: %v", err)
		}
		if refetched.GrandTotal != accepted.GrandTotal || refetched.Status != domain.OfferStatusKabulEdildi {
			t.Errorf("kabul edilen teklifin içeriği/durumu değişti: %+v", refetched)
		}
	})
}
