package service_test

// Faz 4 (Paylaşım Linkleri + Görüntüleme Takibi + Audit/Event + Mail
// Logları) için otomatik testler -- gerçek bir PostgreSQL bağlantısı
// gerektirir (bkz. tenant_isolation_test.go'daki testDBURL/testSecretBox/
// mustCreateOrg/cleanupOrganization yardımcıları, aynı pakette paylaşılır).

import (
	"context"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/platform/mailer"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

func TestOfferShareLinksEventsAndEmail(t *testing.T) {
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

	orgA := mustCreateOrg(t, ctx, orgSvc, pool, "Paylaşım Test Firma A", "paylasim-test-firma-a")
	orgB := mustCreateOrg(t, ctx, orgSvc, pool, "Paylaşım Test Firma B", "paylasim-test-firma-b")

	newOffer := func(t *testing.T, orgID string) *domain.Offer {
		t.Helper()
		o, err := offerSvc.Create(ctx, service.CreateOfferInput{
			OrganizationID: orgID,
			CustomerName:   "Paylaşım Test Müşteri",
			Items:          []service.OfferItemInput{{ProductName: "Kalem", Quantity: 1, UnitPrice: 100}},
		})
		if err != nil {
			t.Fatalf("teklif oluşturulamadı: %v", err)
		}
		return o
	}

	t.Run("1_link_bound_to_specific_revision", func(t *testing.T) {
		o := newOffer(t, orgA.ID)
		link, err := offerSvc.CreateShareLink(ctx, o.ID, orgA.ID, "", nil)
		if err != nil {
			t.Fatalf("link oluşturulamadı: %v", err)
		}
		if link.RevisionID != o.CurrentRevisionID {
			t.Errorf("link teklifin o anki revizyonuna bağlanmadı: link=%s want=%s", link.RevisionID, o.CurrentRevisionID)
		}
		if link.OfferID != o.ID {
			t.Errorf("link yanlış teklife bağlandı: %s", link.OfferID)
		}
	})

	t.Run("2_new_revision_does_not_change_old_link_content", func(t *testing.T) {
		o := newOffer(t, orgA.ID)
		link0, err := offerSvc.CreateShareLink(ctx, o.ID, orgA.ID, "", nil)
		if err != nil {
			t.Fatalf("link oluşturulamadı: %v", err)
		}
		before, _, err := offerSvc.GetByShareLinkToken(ctx, link0.Token, "", "")
		if err != nil {
			t.Fatalf("link görüntülenemedi: %v", err)
		}

		if _, err := offerSvc.UpdateStatus(ctx, o.ID, orgA.ID, domain.OfferStatusGonderildi, ""); err != nil {
			t.Fatalf("durum güncellenemedi: %v", err)
		}
		if _, err := offerSvc.Revise(ctx, o.ID, orgA.ID, ""); err != nil {
			t.Fatalf("revize edilemedi: %v", err)
		}
		// Yeni revizyonda fiyatı değiştir -- link0'ın gösterdiği eski
		// revizyon bundan ETKİLENMEMELİ.
		if _, err := offerSvc.Update(ctx, o.ID, orgA.ID, service.UpdateOfferInput{
			CustomerName: "Paylaşım Test Müşteri",
			Items:        []service.OfferItemInput{{ProductName: "Kalem", Quantity: 1, UnitPrice: 999}},
		}); err != nil {
			t.Fatalf("yeni revizyon düzenlenemedi: %v", err)
		}

		// Yeni revizyon henüz GÖNDERİLMEDİ (Revise sonrası taslak) --
		// dolayısıyla link0 henüz otomatik iptal edilmemiş olmalı, hâlâ
		// eski (revizyon 0) içeriği görüntülenebilmeli, değişmemiş halde.
		after, _, err := offerSvc.GetByShareLinkToken(ctx, link0.Token, "", "")
		if err != nil {
			t.Fatalf("link0 hâlâ görüntülenebilir olmalıydı: %v", err)
		}
		if after.GrandTotal != before.GrandTotal || after.RevisionNo != before.RevisionNo {
			t.Errorf("eski linkin içeriği değişti: önce=%+v sonra=%+v", before, after)
		}
		if after.GrandTotal == 999 {
			t.Errorf("eski link yeni revizyonun (değiştirilmiş) fiyatını gösteriyor")
		}
	})

	t.Run("3_revoked_link_inaccessible", func(t *testing.T) {
		o := newOffer(t, orgA.ID)
		link, err := offerSvc.CreateShareLink(ctx, o.ID, orgA.ID, "", nil)
		if err != nil {
			t.Fatalf("link oluşturulamadı: %v", err)
		}
		if err := offerSvc.RevokeShareLink(ctx, link.ID, orgA.ID, ""); err != nil {
			t.Fatalf("link iptal edilemedi: %v", err)
		}
		if _, _, err := offerSvc.GetByShareLinkToken(ctx, link.Token, "", ""); !errors.Is(err, service.ErrShareLinkRevoked) {
			t.Errorf("iptal edilmiş link hâlâ görüntülenebildi: err=%v", err)
		}
		if _, err := offerSvc.RespondByShareLinkToken(ctx, link.Token, domain.OfferStatusKabulEdildi, "", ""); !errors.Is(err, service.ErrShareLinkRevoked) {
			t.Errorf("iptal edilmiş linkten karar verilebildi: err=%v", err)
		}
	})

	t.Run("4_expired_link_inaccessible", func(t *testing.T) {
		o := newOffer(t, orgA.ID)
		past := time.Now().Add(-1 * time.Hour)
		link, err := offerSvc.CreateShareLink(ctx, o.ID, orgA.ID, "", &past)
		if err != nil {
			t.Fatalf("link oluşturulamadı: %v", err)
		}
		if _, _, err := offerSvc.GetByShareLinkToken(ctx, link.Token, "", ""); !errors.Is(err, service.ErrShareLinkExpired) {
			t.Errorf("süresi dolmuş link hâlâ görüntülenebildi: err=%v", err)
		}
		if _, err := offerSvc.RespondByShareLinkToken(ctx, link.Token, domain.OfferStatusKabulEdildi, "", ""); !errors.Is(err, service.ErrShareLinkExpired) {
			t.Errorf("süresi dolmuş linkten karar verilebildi: err=%v", err)
		}
	})

	t.Run("5_cross_org_isolation_for_links_events_email_logs", func(t *testing.T) {
		o := newOffer(t, orgA.ID)
		link, err := offerSvc.CreateShareLink(ctx, o.ID, orgA.ID, "", nil)
		if err != nil {
			t.Fatalf("link oluşturulamadı: %v", err)
		}

		linksB, err := offerSvc.ListShareLinks(ctx, o.ID, orgB.ID)
		if err != nil {
			t.Fatalf("liste alınamadı: %v", err)
		}
		if len(linksB) != 0 {
			t.Errorf("Firma B, Firma A'nın paylaşım linklerini görebildi")
		}
		if err := offerSvc.RevokeShareLink(ctx, link.ID, orgB.ID, ""); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("Firma B, Firma A'nın linkini iptal edebildi: err=%v", err)
		}

		eventsB, err := offerSvc.ListEvents(ctx, o.ID, orgB.ID)
		if err != nil {
			t.Fatalf("liste alınamadı: %v", err)
		}
		if len(eventsB) != 0 {
			t.Errorf("Firma B, Firma A'nın olaylarını görebildi")
		}

		logsB, err := offerSvc.ListEmailLogs(ctx, o.ID, orgB.ID)
		if err != nil {
			t.Fatalf("liste alınamadı: %v", err)
		}
		if len(logsB) != 0 {
			t.Errorf("Firma B, Firma A'nın mail loglarını görebildi")
		}

		// Firma A kendi verisini normal şekilde görebilmeli (negatif testin
		// yanlışlıkla her şeyi engellemediğini doğrular).
		linksA, err := offerSvc.ListShareLinks(ctx, o.ID, orgA.ID)
		if err != nil || len(linksA) != 1 {
			t.Errorf("Firma A kendi linkini göremedi: links=%v err=%v", linksA, err)
		}
	})

	t.Run("6_public_view_creates_customer_viewed_event", func(t *testing.T) {
		o := newOffer(t, orgA.ID)
		link, err := offerSvc.CreateShareLink(ctx, o.ID, orgA.ID, "", nil)
		if err != nil {
			t.Fatalf("link oluşturulamadı: %v", err)
		}
		before, err := offerSvc.ListEvents(ctx, o.ID, orgA.ID)
		if err != nil {
			t.Fatalf("liste alınamadı: %v", err)
		}
		if _, _, err := offerSvc.GetByShareLinkToken(ctx, link.Token, "203.0.113.5", "TestAgent/1.0"); err != nil {
			t.Fatalf("link görüntülenemedi: %v", err)
		}
		after, err := offerSvc.ListEvents(ctx, o.ID, orgA.ID)
		if err != nil {
			t.Fatalf("liste alınamadı: %v", err)
		}
		if len(after) != len(before)+1 {
			t.Fatalf("customer_viewed olayı üretilmedi: önce=%d sonra=%d", len(before), len(after))
		}
		last := after[len(after)-1]
		if last.EventType != domain.EventCustomerViewed {
			t.Errorf("beklenen event_type customer_viewed, geldi: %s", last.EventType)
		}
		if last.IPAddress != "203.0.113.5" || last.UserAgent != "TestAgent/1.0" {
			t.Errorf("ip/user-agent kaydedilmedi: ip=%s ua=%s", last.IPAddress, last.UserAgent)
		}
		if last.RevisionID == nil || *last.RevisionID != link.RevisionID {
			t.Errorf("customer_viewed olayı yanlış revizyona bağlandı: %+v", last.RevisionID)
		}
	})

	t.Run("7_email_sent_creates_log_and_sends_revision", func(t *testing.T) {
		o := newOffer(t, orgA.ID)
		offerSvc.SendMailFunc = func(domain.SmtpSettings, mailer.Message) error { return nil }
		defer func() { offerSvc.SendMailFunc = mailer.Send }()

		result, err := offerSvc.SendOfferEmail(ctx, o.ID, orgA.ID, "", service.SendOfferEmailInput{To: "musteri@example.com"})
		if err != nil {
			t.Fatalf("mail gönderilemedi: %v", err)
		}
		if result.Status != domain.OfferStatusGonderildi {
			t.Errorf("mail başarılı olduğunda revizyon 'gönderildi' olmadı: %s", result.Status)
		}
		logs, err := offerSvc.ListEmailLogs(ctx, o.ID, orgA.ID)
		if err != nil {
			t.Fatalf("liste alınamadı: %v", err)
		}
		if len(logs) != 1 || logs[0].Status != domain.EmailLogStatusSent || logs[0].ErrorMessage != "" {
			t.Fatalf("email_sent kaydı doğru oluşmadı: %+v", logs)
		}
		if logs[0].ShareLinkID == "" || logs[0].RevisionID != o.CurrentRevisionID {
			t.Errorf("mail logu belirli bir revizyon/paylaşım linkine bağlanmadı: %+v", logs[0])
		}
		events, err := offerSvc.ListEvents(ctx, o.ID, orgA.ID)
		if err != nil {
			t.Fatalf("liste alınamadı: %v", err)
		}
		found := false
		for _, e := range events {
			if e.EventType == domain.EventEmailSent {
				found = true
			}
		}
		if !found {
			t.Errorf("email_sent olayı üretilmedi")
		}
	})

	t.Run("8_email_failed_keeps_revision_draft", func(t *testing.T) {
		o := newOffer(t, orgA.ID)
		fakeErr := errors.New("bağlantı zaman aşımına uğradı")
		offerSvc.SendMailFunc = func(domain.SmtpSettings, mailer.Message) error { return fakeErr }
		defer func() { offerSvc.SendMailFunc = mailer.Send }()

		if _, err := offerSvc.SendOfferEmail(ctx, o.ID, orgA.ID, "", service.SendOfferEmailInput{To: "musteri@example.com"}); err == nil {
			t.Fatalf("başarısız gönderim hata döndürmedi")
		}
		refetched, err := offerSvc.Get(ctx, o.ID, orgA.ID)
		if err != nil {
			t.Fatalf("teklif okunamadı: %v", err)
		}
		if refetched.Status != domain.OfferStatusTaslak {
			t.Errorf("mail başarısız olduğunda revizyon durumu değişti: %s", refetched.Status)
		}
		logs, err := offerSvc.ListEmailLogs(ctx, o.ID, orgA.ID)
		if err != nil {
			t.Fatalf("liste alınamadı: %v", err)
		}
		if len(logs) != 1 || logs[0].Status != domain.EmailLogStatusFailed || logs[0].ErrorMessage == "" {
			t.Fatalf("email_failed kaydı doğru oluşmadı: %+v", logs)
		}
		events, err := offerSvc.ListEvents(ctx, o.ID, orgA.ID)
		if err != nil {
			t.Fatalf("liste alınamadı: %v", err)
		}
		found := false
		for _, e := range events {
			if e.EventType == domain.EventEmailFailed {
				found = true
			}
		}
		if !found {
			t.Errorf("email_failed olayı üretilmedi")
		}
	})

	t.Run("9_customer_acceptance_written_to_correct_revision", func(t *testing.T) {
		o := newOffer(t, orgA.ID)
		if _, err := offerSvc.UpdateStatus(ctx, o.ID, orgA.ID, domain.OfferStatusGonderildi, ""); err != nil {
			t.Fatalf("durum güncellenemedi: %v", err)
		}
		link, err := offerSvc.CreateShareLink(ctx, o.ID, orgA.ID, "", nil)
		if err != nil {
			t.Fatalf("link oluşturulamadı: %v", err)
		}
		if _, err := offerSvc.RespondByShareLinkToken(ctx, link.Token, domain.OfferStatusKabulEdildi, "", ""); err != nil {
			t.Fatalf("kabul işlemi başarısız: %v", err)
		}
		rev, err := offerSvc.GetRevision(ctx, link.RevisionID, orgA.ID)
		if err != nil {
			t.Fatalf("revizyon okunamadı: %v", err)
		}
		if rev.Status != domain.OfferStatusKabulEdildi {
			t.Errorf("kabul, linkin bağlı olduğu revision_id'ye yazılmadı: %s", rev.Status)
		}
	})

	// Kullanıcının tarif ettiği tam senaryo: müşteri Revizyon 0'ı açtı,
	// personel TAM O SIRADA Revizyon 1'i oluşturup gönderiyor, müşteri
	// eski sekmeden "Kabul Et"e basıyor. Sonuç KESİNLİKLE Revizyon 0'ın
	// kabul edilmesi OLAMAZ -- ya müşterinin isteği ErrOfferSuperseded ile
	// reddedilir (personel kazandı) ya da müşteri kilidi önce alıp kabul
	// eder ve personelin Revise() çağrısı (offer artık "kabul edildi"
	// olduğu için) ErrOfferNotRevisable ile reddedilir. Üçüncü bir sonuç
	// (ikisi de başarılı, ya da Revizyon 0 sessizce kabul edilmiş görünmesi)
	// KABUL EDİLEMEZ -- iki gerçek goroutine ile yarış penceresini olabildiğince
	// daraltıyoruz.
	t.Run("10_concurrent_customer_accept_vs_staff_revise_race", func(t *testing.T) {
		o := newOffer(t, orgA.ID)
		if _, err := offerSvc.UpdateStatus(ctx, o.ID, orgA.ID, domain.OfferStatusGonderildi, ""); err != nil {
			t.Fatalf("durum güncellenemedi: %v", err)
		}
		link0, err := offerSvc.CreateShareLink(ctx, o.ID, orgA.ID, "", nil)
		if err != nil {
			t.Fatalf("link oluşturulamadı: %v", err)
		}

		var wg sync.WaitGroup
		var respondErr, reviseErr error
		var respondResult *domain.Offer
		wg.Add(2)
		go func() {
			defer wg.Done()
			respondResult, respondErr = offerSvc.RespondByShareLinkToken(ctx, link0.Token, domain.OfferStatusKabulEdildi, "", "")
		}()
		go func() {
			defer wg.Done()
			_, reviseErr = offerSvc.Revise(ctx, o.ID, orgA.ID, "")
		}()
		wg.Wait()

		switch {
		case respondErr == nil && reviseErr != nil:
			// Müşteri kazandı: kabul Revizyon 0'a işlendi, revize temiz
			// biçimde reddedildi.
			t.Logf("yarış sonucu: müşteri kazandı (kabul işlendi, revize reddedildi)")
			if !errors.Is(reviseErr, service.ErrOfferNotRevisable) {
				t.Fatalf("revize beklenmeyen bir hatayla reddedildi (kilit çalışmamış olabilir): %v", reviseErr)
			}
			if respondResult.RevisionNo != 0 || respondResult.Status != domain.OfferStatusKabulEdildi {
				t.Fatalf("kabul beklenmeyen bir revizyona/duruma uygulandı: revision_no=%d status=%s",
					respondResult.RevisionNo, respondResult.Status)
			}
		case respondErr != nil && reviseErr == nil:
			// Personel kazandı: yeni revizyon oluştu, müşterinin eski
			// linkten kararı artık current olmadığı için reddedildi.
			t.Logf("yarış sonucu: personel kazandı (revize işlendi, kabul reddedildi)")
			if !errors.Is(respondErr, service.ErrOfferSuperseded) {
				t.Fatalf("kabul isteği beklenmeyen bir hatayla reddedildi: %v", respondErr)
			}
		default:
			t.Fatalf("KRİTİK: beklenmeyen sonuç kombinasyonu (respondErr=%v, reviseErr=%v) -- her ikisi de başarılı ya da her ikisi de başarısız olmamalıydı", respondErr, reviseErr)
		}

		// Ek kesinlik: Revizyon 0'ın son hâli, yalnızca müşteri gerçekten
		// kazandıysa "kabul edildi" olabilir -- personel kazandıysa Revizyon
		// 0 hâlâ "gönderildi" (donmuş) kalmalı, asla sessizce "kabul edildi"
		// olmamalı.
		rev0, err := offerSvc.GetRevision(ctx, link0.RevisionID, orgA.ID)
		if err != nil {
			t.Fatalf("revizyon 0 okunamadı: %v", err)
		}
		if reviseErr == nil && rev0.Status == domain.OfferStatusKabulEdildi {
			t.Fatalf("KRİTİK: personel kazandığı halde Revizyon 0 kabul edilmiş görünüyor")
		}
	})

	// Kararın dayandığı her şeyin KİLİT ALTINDA taze okunduğunu kanıtlar.
	// Kurgu deterministiktir: advisory lock'u önce biz elimizde tutarız,
	// Respond çağrısı linki (henüz iptal edilmemiş halde) okuyup kilitte
	// bloke olur; tam o sırada linki iptal edip kilidi bırakırız. Respond,
	// kilidi aldıktan sonra linki YENİDEN okumazsa bu testi geçemez --
	// iptal edilmiş bir bağlantı üzerinden kabul işlemiş olur.
	t.Run("12_revoke_during_in_flight_decision_wins", func(t *testing.T) {
		o := newOffer(t, orgA.ID)
		if _, err := offerSvc.UpdateStatus(ctx, o.ID, orgA.ID, domain.OfferStatusGonderildi, ""); err != nil {
			t.Fatalf("durum güncellenemedi: %v", err)
		}
		link, err := offerSvc.CreateShareLink(ctx, o.ID, orgA.ID, "", nil)
		if err != nil {
			t.Fatalf("link oluşturulamadı: %v", err)
		}

		conn, err := pool.Acquire(ctx)
		if err != nil {
			t.Fatalf("bağlantı alınamadı: %v", err)
		}
		defer conn.Release()
		blocker, err := conn.Begin(ctx)
		if err != nil {
			t.Fatalf("transaction açılamadı: %v", err)
		}
		defer blocker.Rollback(ctx)
		if _, err := blocker.Exec(ctx, "SELECT pg_advisory_xact_lock(hashtext($1))", o.ID); err != nil {
			t.Fatalf("kilit alınamadı: %v", err)
		}

		respondDone := make(chan error, 1)
		go func() {
			_, err := offerSvc.RespondByShareLinkToken(ctx, link.Token, domain.OfferStatusKabulEdildi, "", "")
			respondDone <- err
		}()

		// Respond'un linki okuyup kilitte bloke olmasına fırsat ver.
		time.Sleep(300 * time.Millisecond)
		if _, err := blocker.Exec(ctx, "UPDATE offer_share_links SET revoked_at = now() WHERE id = $1", link.ID); err != nil {
			t.Fatalf("link iptal edilemedi: %v", err)
		}
		if err := blocker.Commit(ctx); err != nil { // kilit burada serbest kalır
			t.Fatalf("commit başarısız: %v", err)
		}

		if err := <-respondDone; !errors.Is(err, service.ErrShareLinkRevoked) {
			t.Errorf("kilidi beklerken iptal edilen bağlantı üzerinden karar verilebildi: err=%v", err)
		}
		refetched, err := offerSvc.Get(ctx, o.ID, orgA.ID)
		if err != nil {
			t.Fatalf("teklif okunamadı: %v", err)
		}
		if refetched.Status != domain.OfferStatusGonderildi {
			t.Errorf("iptal edilmiş bağlantıdan gelen karar yine de uygulandı: %s", refetched.Status)
		}
	})

	// ip_address varchar(45) / user_agent varchar(500) sınırlarını aşan
	// girdiler denetim kaydını -- dolayısıyla MÜŞTERİNİN KARARINI --
	// düşürmemeli: Respond'da olay kaydı kararın transaction'ı içindedir,
	// yani kısaltma olmasaydı Cloudflare+nginx arkasındaki (zincirli
	// X-Forwarded-For) hiçbir müşteri teklifi kabul edemezdi.
	t.Run("13_oversized_ip_and_user_agent_do_not_break_decision", func(t *testing.T) {
		o := newOffer(t, orgA.ID)
		if _, err := offerSvc.UpdateStatus(ctx, o.ID, orgA.ID, domain.OfferStatusGonderildi, ""); err != nil {
			t.Fatalf("durum güncellenemedi: %v", err)
		}
		link, err := offerSvc.CreateShareLink(ctx, o.ID, orgA.ID, "", nil)
		if err != nil {
			t.Fatalf("link oluşturulamadı: %v", err)
		}

		// 52 karakterlik gerçekçi iki hop'lu IPv6 zinciri + aşırı uzun UA.
		longIP := "2a02:c7f:8e0a:ef00:1c4c:1a0e:bb18:ee2b, 172.70.130.5"
		longUA := strings.Repeat("Mozilla/5.0 ", 80)

		if _, _, err := offerSvc.GetByShareLinkToken(ctx, link.Token, longIP, longUA); err != nil {
			t.Fatalf("uzun ip/user-agent ile görüntüleme başarısız: %v", err)
		}
		accepted, err := offerSvc.RespondByShareLinkToken(ctx, link.Token, domain.OfferStatusKabulEdildi, longIP, longUA)
		if err != nil {
			t.Fatalf("uzun ip/user-agent ile kabul başarısız: %v", err)
		}
		if accepted.Status != domain.OfferStatusKabulEdildi {
			t.Errorf("kabul uygulanmadı: %s", accepted.Status)
		}
		events, err := offerSvc.ListEvents(ctx, o.ID, orgA.ID)
		if err != nil {
			t.Fatalf("liste alınamadı: %v", err)
		}
		var viewed *domain.OfferEvent
		for i, e := range events {
			if e.EventType == domain.EventCustomerViewed {
				viewed = &events[i]
			}
		}
		if viewed == nil {
			t.Fatalf("customer_viewed olayı yazılmadı (kısaltma çalışmıyor olabilir)")
		}
		if len([]rune(viewed.IPAddress)) > 45 || len([]rune(viewed.UserAgent)) > 500 {
			t.Errorf("ip/user-agent kısaltılmadı: ip=%d ua=%d karakter",
				len([]rune(viewed.IPAddress)), len([]rune(viewed.UserAgent)))
		}
	})

	// UpdateStatus (personelin durum seçicisi) da Revise/Respond ile aynı
	// kilidi almalı ve teklifi kilit ALTINDA taze okumalıdır. Aksi halde
	// senkronize edilmemiş tek yazar olur: aşağıdaki kurguda müşterinin
	// kabulü kilit altında commit edilirken, kilitsiz bir UpdateStatus
	// güncelliğini yitirmiş "gönderildi" anlık görüntüsüne bakarak
	// ErrOfferLocked kontrolünü geçer ve commit edilmiş kabulü ezerdi.
	t.Run("14_status_update_cannot_overwrite_committed_acceptance", func(t *testing.T) {
		o := newOffer(t, orgA.ID)
		if _, err := offerSvc.UpdateStatus(ctx, o.ID, orgA.ID, domain.OfferStatusGonderildi, ""); err != nil {
			t.Fatalf("durum güncellenemedi: %v", err)
		}

		conn, err := pool.Acquire(ctx)
		if err != nil {
			t.Fatalf("bağlantı alınamadı: %v", err)
		}
		defer conn.Release()
		blocker, err := conn.Begin(ctx)
		if err != nil {
			t.Fatalf("transaction açılamadı: %v", err)
		}
		defer blocker.Rollback(ctx)
		// Müşterinin kabulünü taklit et: kilidi al, kabulü yaz, ama HENÜZ
		// commit etme.
		if _, err := blocker.Exec(ctx, "SELECT pg_advisory_xact_lock(hashtext($1))", o.ID); err != nil {
			t.Fatalf("kilit alınamadı: %v", err)
		}

		statusDone := make(chan error, 1)
		go func() {
			_, err := offerSvc.UpdateStatus(ctx, o.ID, orgA.ID, domain.OfferStatusReddedildi, "")
			statusDone <- err
		}()

		// UpdateStatus'un kilitte bloke olmasına fırsat ver (kilitsiz bir
		// uygulamada burada teklifi çoktan okumuş olurdu).
		time.Sleep(300 * time.Millisecond)
		if _, err := blocker.Exec(ctx,
			"UPDATE offer_revisions SET status = $2 WHERE id = $1", o.CurrentRevisionID, domain.OfferStatusKabulEdildi); err != nil {
			t.Fatalf("revizyon güncellenemedi: %v", err)
		}
		if _, err := blocker.Exec(ctx,
			"UPDATE offers SET status = $2 WHERE id = $1", o.ID, domain.OfferStatusKabulEdildi); err != nil {
			t.Fatalf("teklif güncellenemedi: %v", err)
		}
		if err := blocker.Commit(ctx); err != nil { // kilit burada serbest kalır
			t.Fatalf("commit başarısız: %v", err)
		}

		if err := <-statusDone; !errors.Is(err, service.ErrOfferLocked) {
			t.Errorf("kabul edilmiş teklifin durumu yine de değiştirilebildi: err=%v", err)
		}
		final, err := offerSvc.Get(ctx, o.ID, orgA.ID)
		if err != nil {
			t.Fatalf("teklif okunamadı: %v", err)
		}
		if final.Status != domain.OfferStatusKabulEdildi {
			t.Errorf("commit edilmiş müşteri kabulü ezildi: durum=%s", final.Status)
		}
	})

	t.Run("11_idempotent_second_response_protected", func(t *testing.T) {
		o := newOffer(t, orgA.ID)
		if _, err := offerSvc.UpdateStatus(ctx, o.ID, orgA.ID, domain.OfferStatusGonderildi, ""); err != nil {
			t.Fatalf("durum güncellenemedi: %v", err)
		}
		link, err := offerSvc.CreateShareLink(ctx, o.ID, orgA.ID, "", nil)
		if err != nil {
			t.Fatalf("link oluşturulamadı: %v", err)
		}
		if _, err := offerSvc.RespondByShareLinkToken(ctx, link.Token, domain.OfferStatusKabulEdildi, "", ""); err != nil {
			t.Fatalf("ilk kabul başarısız: %v", err)
		}
		if _, err := offerSvc.RespondByShareLinkToken(ctx, link.Token, domain.OfferStatusReddedildi, "", ""); !errors.Is(err, service.ErrOfferNotRespondable) {
			t.Errorf("aynı link üzerinden ikinci (çelişen) karar işlendi: err=%v", err)
		}
		refetched, err := offerSvc.Get(ctx, o.ID, orgA.ID)
		if err != nil {
			t.Fatalf("teklif okunamadı: %v", err)
		}
		if refetched.Status != domain.OfferStatusKabulEdildi {
			t.Errorf("ilk karardan sonra durum değişti: %s", refetched.Status)
		}
	})
}
