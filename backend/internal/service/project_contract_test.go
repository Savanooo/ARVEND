package service_test

// ARVEND V2 -- Sprint 3 (Proje Sözleşmesi / Contract) için otomatik
// testler -- gerçek bir PostgreSQL bağlantısı gerektirir (bkz.
// tenant_isolation_test.go'daki testDBURL/testSecretBox/mustCreateOrg/
// cleanupOrganization yardımcıları, aynı pakette paylaşılır). Plan'ın
// (dynamic-dazzling-metcalfe.md) §7'sindeki senaryo listesini uygular.

import (
	"context"
	"errors"
	"testing"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

func TestProjectContract(t *testing.T) {
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
	projectSvc := service.NewProjectService(pool, q, mustTestStore(t), settingsSvc, "http://localhost:3000")

	orgA := mustCreateOrg(t, ctx, orgSvc, pool, "Sözleşme Test Firma A", "sozlesme-test-firma-a")
	orgB := mustCreateOrg(t, ctx, orgSvc, pool, "Sözleşme Test Firma B", "sozlesme-test-firma-b")

	newProject := func(t *testing.T, orgID string) *domain.Project {
		t.Helper()
		o, err := offerSvc.Create(ctx, service.CreateOfferInput{
			OrganizationID: orgID,
			CustomerName:   "Sözleşme Test Müşteri",
			Items:          []service.OfferItemInput{{ProductName: "İş", Quantity: 1, UnitPrice: 100000}},
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
		p, err := projectSvc.CreateFromOffer(ctx, o.ID, orgID, service.CreateProjectInput{Name: "Sözleşme Test Projesi"})
		if err != nil {
			t.Fatalf("proje oluşturulamadı: %v", err)
		}
		return p
	}

	// newProjectWithContract, Sprint 4'ten itibaren tüm projelerin doğal
	// hali olan "proje var, sözleşme YOK" durumunun ÜZERİNE, testin
	// ihtiyaç duyduğu taslak sözleşmeyi AÇIKÇA (kullanıcının "Sözleşme
	// Oluştur" CTA'sını tetiklemesiyle AYNI çağrı) ekler -- otomatik
	// oluşturma SİMÜLE EDİLMEZ, gerçek API çağrısı kullanılır.
	newProjectWithContract := func(t *testing.T, orgID string) (*domain.Project, *domain.ProjectContract) {
		t.Helper()
		p := newProject(t, orgID)
		c, err := projectSvc.CreateProjectContract(ctx, p.ID, orgID, "")
		if err != nil {
			t.Fatalf("sözleşme oluşturulamadı: %v", err)
		}
		return p, c
	}

	// activated, draft->active geçişini tamamlamış bir proje+sözleşme
	// döner (Complete/Terminate testleri için ortak kurulum).
	activated := func(t *testing.T, orgID string) (*domain.Project, *domain.ProjectContract) {
		t.Helper()
		p, _ := newProjectWithContract(t, orgID)
		c, err := projectSvc.ActivateProjectContract(ctx, p.ID, orgID, "")
		if err != nil {
			t.Fatalf("aktive edilemedi: %v", err)
		}
		return p, c
	}

	t.Run("1_offer_conversion_does_not_auto_create_contract", func(t *testing.T) {
		// Sprint 4 düzeltmesi: Contract gerçek bir ticari nesnedir, salt
		// proje var diye "hayalet" bir boş taslak sözleşme YARATILMAZ --
		// offer'ın ticari anlık görüntüsü (contract_amount/currency/vb.)
		// projenin KENDİSİNDE zaten korunur, project_contracts BOŞ kalır.
		p := newProject(t, orgA.ID)
		if p.ContractAmount <= 0 {
			t.Fatalf("proje üzerindeki ticari anlık görüntü (contract_amount) korunmalı: %v", p.ContractAmount)
		}
		if _, err := projectSvc.GetProjectContract(ctx, p.ID, orgA.ID); !errors.Is(err, service.ErrContractNotFound) {
			t.Fatalf("offer dönüşümü project_contracts satırı OLUŞTURMAMALI, beklenen ErrContractNotFound, geldi: %v", err)
		}
	})

	t.Run("2_manual_create_after_offer_conversion", func(t *testing.T) {
		// Kullanıcının web'deki "Sözleşme Oluştur" CTA'sını tetiklemesiyle
		// AYNI akış -- artık TEK yol budur, "mevcut proje" için özel bir
		// durum değildir (Sprint 4 öncesi yalnızca eski projeler için
		// geçerliydi, şimdi TÜM projeler için geçerli).
		p := newProject(t, orgA.ID)
		c, err := projectSvc.CreateProjectContract(ctx, p.ID, orgA.ID, "")
		if err != nil {
			t.Fatalf("manuel oluşturma başarısız: %v", err)
		}
		if c.Status != domain.ContractStatusDraft {
			t.Errorf("beklenen draft, geldi: %s", c.Status)
		}
		if c.Currency != p.Currency {
			t.Errorf("currency snapshot projeninkiyle eşleşmeli: %s != %s", c.Currency, p.Currency)
		}
	})

	t.Run("3_duplicate_create_rejected", func(t *testing.T) {
		p, _ := newProjectWithContract(t, orgA.ID)
		_, err := projectSvc.CreateProjectContract(ctx, p.ID, orgA.ID, "")
		if !errors.Is(err, service.ErrContractAlreadyExists) {
			t.Errorf("beklenen ErrContractAlreadyExists, geldi: %v", err)
		}
	})

	t.Run("4_update_draft_fields_allowed_in_draft", func(t *testing.T) {
		p, _ := newProjectWithContract(t, orgA.ID)
		c, err := projectSvc.UpdateProjectContractDraft(ctx, p.ID, orgA.ID, service.ContractDraftInput{
			Scope: "Kaba+ince inşaat", PaymentTerms: "Aylık hakediş", RetentionTerms: "%5 teminat kesintisi",
			AdvanceTerms: "%10 avans", UserID: "",
		})
		if err != nil {
			t.Fatalf("draft güncelleme başarısız: %v", err)
		}
		if c.Scope != "Kaba+ince inşaat" || c.RetentionTerms != "%5 teminat kesintisi" {
			t.Errorf("beklenen alanlar kaydedilmedi: %+v", c)
		}
	})

	t.Run("5_update_draft_fields_rejected_after_activation", func(t *testing.T) {
		p, _ := activated(t, orgA.ID)
		_, err := projectSvc.UpdateProjectContractDraft(ctx, p.ID, orgA.ID, service.ContractDraftInput{Scope: "Değişmemeli"})
		if !errors.Is(err, service.ErrContractNotEditable) {
			t.Errorf("beklenen ErrContractNotEditable, geldi: %v", err)
		}
	})

	t.Run("6_update_notes_allowed_in_draft_and_active", func(t *testing.T) {
		p, _ := newProjectWithContract(t, orgA.ID)
		if _, err := projectSvc.UpdateProjectContractNotes(ctx, p.ID, orgA.ID, "", "draft notu"); err != nil {
			t.Errorf("draft'ta not güncellenebilmeli: %v", err)
		}
		if _, err := projectSvc.ActivateProjectContract(ctx, p.ID, orgA.ID, ""); err != nil {
			t.Fatalf("aktive edilemedi: %v", err)
		}
		c, err := projectSvc.UpdateProjectContractNotes(ctx, p.ID, orgA.ID, "", "active notu")
		if err != nil {
			t.Errorf("active'te not güncellenebilmeli: %v", err)
		}
		if c.InternalNotes != "active notu" {
			t.Errorf("not kaydedilmedi: %+v", c)
		}
	})

	t.Run("7_update_notes_rejected_in_terminal_state", func(t *testing.T) {
		p, _ := newProjectWithContract(t, orgA.ID)
		if _, err := projectSvc.CancelProjectContract(ctx, p.ID, orgA.ID, "", "vazgeçildi"); err != nil {
			t.Fatalf("iptal edilemedi: %v", err)
		}
		_, err := projectSvc.UpdateProjectContractNotes(ctx, p.ID, orgA.ID, "", "iptal sonrası not")
		if !errors.Is(err, service.ErrContractNotesNotEditable) {
			t.Errorf("beklenen ErrContractNotesNotEditable, geldi: %v", err)
		}
	})

	t.Run("8_activate_transitions_draft_to_active", func(t *testing.T) {
		p, _ := newProjectWithContract(t, orgA.ID)
		c, err := projectSvc.ActivateProjectContract(ctx, p.ID, orgA.ID, "")
		if err != nil {
			t.Fatalf("aktive edilemedi: %v", err)
		}
		if c.Status != domain.ContractStatusActive || c.ActivatedAt == nil {
			t.Errorf("beklenen active + activated_at dolu, geldi: %+v", c)
		}
	})

	t.Run("9_double_activate_rejected", func(t *testing.T) {
		p, _ := activated(t, orgA.ID)
		_, err := projectSvc.ActivateProjectContract(ctx, p.ID, orgA.ID, "")
		if !errors.Is(err, service.ErrContractNotActivatable) {
			t.Errorf("beklenen ErrContractNotActivatable, geldi: %v", err)
		}
	})

	t.Run("10_cancel_from_draft_allowed_requires_reason", func(t *testing.T) {
		p, _ := newProjectWithContract(t, orgA.ID)
		_, err := projectSvc.CancelProjectContract(ctx, p.ID, orgA.ID, "", "")
		if !errors.Is(err, service.ErrContractReasonRequired) {
			t.Errorf("beklenen ErrContractReasonRequired, geldi: %v", err)
		}
		c, err := projectSvc.CancelProjectContract(ctx, p.ID, orgA.ID, "", "müşteri vazgeçti")
		if err != nil {
			t.Fatalf("iptal edilemedi: %v", err)
		}
		if c.Status != domain.ContractStatusCancelled || c.CancelReason != "müşteri vazgeçti" {
			t.Errorf("beklenen cancelled + gerekçe kaydı, geldi: %+v", c)
		}
	})

	t.Run("11_cancel_rejected_from_active", func(t *testing.T) {
		// KRİTİK: draft dışından (özellikle active'ten) Cancel ASLA kabul
		// edilmemeli -- yürürlüğe girmiş bir sözleşme yalnızca Terminate
		// edilebilir.
		p, _ := activated(t, orgA.ID)
		_, err := projectSvc.CancelProjectContract(ctx, p.ID, orgA.ID, "", "gerekçe")
		if !errors.Is(err, service.ErrContractNotCancellable) {
			t.Errorf("beklenen ErrContractNotCancellable, geldi: %v", err)
		}
	})

	t.Run("12_complete_transitions_active_to_completed", func(t *testing.T) {
		p, _ := activated(t, orgA.ID)
		c, err := projectSvc.CompleteProjectContract(ctx, p.ID, orgA.ID, "")
		if err != nil {
			t.Fatalf("tamamlanamadı: %v", err)
		}
		if c.Status != domain.ContractStatusCompleted || c.CompletedAt == nil {
			t.Errorf("beklenen completed + completed_at dolu, geldi: %+v", c)
		}
	})

	t.Run("13_complete_rejected_from_draft", func(t *testing.T) {
		p, _ := newProjectWithContract(t, orgA.ID)
		_, err := projectSvc.CompleteProjectContract(ctx, p.ID, orgA.ID, "")
		if !errors.Is(err, service.ErrContractNotCompletable) {
			t.Errorf("beklenen ErrContractNotCompletable, geldi: %v", err)
		}
	})

	t.Run("14_terminate_transitions_active_to_terminated_requires_reason", func(t *testing.T) {
		p, _ := activated(t, orgA.ID)
		_, err := projectSvc.TerminateProjectContract(ctx, p.ID, orgA.ID, "", "")
		if !errors.Is(err, service.ErrContractReasonRequired) {
			t.Errorf("beklenen ErrContractReasonRequired, geldi: %v", err)
		}
		c, err := projectSvc.TerminateProjectContract(ctx, p.ID, orgA.ID, "", "işveren erken fesih talep etti")
		if err != nil {
			t.Fatalf("feshedilemedi: %v", err)
		}
		if c.Status != domain.ContractStatusTerminated || c.TerminationReason != "işveren erken fesih talep etti" {
			t.Errorf("beklenen terminated + gerekçe kaydı, geldi: %+v", c)
		}
	})

	t.Run("15_terminate_rejected_from_draft", func(t *testing.T) {
		// KRİTİK: hiç yürürlüğe girmemiş (draft) bir sözleşme ASLA
		// terminate edilemez -- yalnızca cancel edilebilir.
		p, _ := newProjectWithContract(t, orgA.ID)
		_, err := projectSvc.TerminateProjectContract(ctx, p.ID, orgA.ID, "", "gerekçe")
		if !errors.Is(err, service.ErrContractNotTerminable) {
			t.Errorf("beklenen ErrContractNotTerminable, geldi: %v", err)
		}
	})

	t.Run("16_no_reactivation_from_any_terminal_state", func(t *testing.T) {
		pCompleted, _ := activated(t, orgA.ID)
		if _, err := projectSvc.CompleteProjectContract(ctx, pCompleted.ID, orgA.ID, ""); err != nil {
			t.Fatalf("tamamlanamadı: %v", err)
		}
		if _, err := projectSvc.ActivateProjectContract(ctx, pCompleted.ID, orgA.ID, ""); !errors.Is(err, service.ErrContractNotActivatable) {
			t.Errorf("completed'ten activate reddedilmeli, geldi: %v", err)
		}

		pCancelled, _ := newProjectWithContract(t, orgA.ID)
		if _, err := projectSvc.CancelProjectContract(ctx, pCancelled.ID, orgA.ID, "", "gerekçe"); err != nil {
			t.Fatalf("iptal edilemedi: %v", err)
		}
		if _, err := projectSvc.ActivateProjectContract(ctx, pCancelled.ID, orgA.ID, ""); !errors.Is(err, service.ErrContractNotActivatable) {
			t.Errorf("cancelled'ten activate reddedilmeli, geldi: %v", err)
		}

		pTerminated, _ := activated(t, orgA.ID)
		if _, err := projectSvc.TerminateProjectContract(ctx, pTerminated.ID, orgA.ID, "", "gerekçe"); err != nil {
			t.Fatalf("feshedilemedi: %v", err)
		}
		if _, err := projectSvc.CompleteProjectContract(ctx, pTerminated.ID, orgA.ID, ""); !errors.Is(err, service.ErrContractNotCompletable) {
			t.Errorf("terminated'ten complete reddedilmeli, geldi: %v", err)
		}
	})

	t.Run("17_cross_project_contract_get_denied", func(t *testing.T) {
		pA, _ := newProjectWithContract(t, orgA.ID)
		pB, _ := newProjectWithContract(t, orgA.ID)
		// pB'nin bağlamında pA'nın sözleşmesine erişim yok -- her proje
		// yalnızca KENDİ project_id'sine bağlı sözleşmeyi görür.
		_, err := projectSvc.GetProjectContract(ctx, pB.ID, orgA.ID)
		if err != nil {
			t.Fatalf("pB'nin kendi sözleşmesi okunabilmeli: %v", err)
		}
		cA, err := projectSvc.GetProjectContract(ctx, pA.ID, orgA.ID)
		if err != nil {
			t.Fatalf("pA'nın kendi sözleşmesi okunabilmeli: %v", err)
		}
		cB, _ := projectSvc.GetProjectContract(ctx, pB.ID, orgA.ID)
		if cA.ID == cB.ID {
			t.Errorf("iki farklı projenin sözleşmesi AYNI olamaz")
		}
	})

	t.Run("18_cross_tenant_contract_get_denied", func(t *testing.T) {
		pA, _ := newProjectWithContract(t, orgA.ID)
		// orgB bağlamında, orgA'nın proje id'siyle sözleşme okuma denemesi
		// -- organization_id eşleşmediği için bulunamaz.
		_, err := projectSvc.GetProjectContract(ctx, pA.ID, orgB.ID)
		if !errors.Is(err, service.ErrContractNotFound) {
			t.Errorf("beklenen ErrContractNotFound (çapraz kiracı), geldi: %v", err)
		}
	})

	t.Run("golden_path_draft_to_active_to_completed", func(t *testing.T) {
		p, _ := newProjectWithContract(t, orgA.ID)
		if _, err := projectSvc.UpdateProjectContractDraft(ctx, p.ID, orgA.ID, service.ContractDraftInput{
			Scope: "Tam kapsam", PaymentTerms: "Hakediş", RetentionTerms: "%5", AdvanceTerms: "%10",
		}); err != nil {
			t.Fatalf("draft güncelleme: %v", err)
		}
		if _, err := projectSvc.ActivateProjectContract(ctx, p.ID, orgA.ID, ""); err != nil {
			t.Fatalf("aktivasyon: %v", err)
		}
		c, err := projectSvc.CompleteProjectContract(ctx, p.ID, orgA.ID, "")
		if err != nil {
			t.Fatalf("tamamlama: %v", err)
		}
		if c.Status != domain.ContractStatusCompleted || c.Scope != "Tam kapsam" {
			t.Errorf("golden path sonucu beklenmedik: %+v", c)
		}
	})

	t.Run("golden_path_draft_to_cancelled", func(t *testing.T) {
		p, _ := newProjectWithContract(t, orgA.ID)
		c, err := projectSvc.CancelProjectContract(ctx, p.ID, orgA.ID, "", "teklif iptal edildi")
		if err != nil {
			t.Fatalf("iptal: %v", err)
		}
		if c.Status != domain.ContractStatusCancelled {
			t.Errorf("beklenen cancelled, geldi: %s", c.Status)
		}
	})

	t.Run("golden_path_draft_to_active_to_terminated", func(t *testing.T) {
		p, _ := activated(t, orgA.ID)
		c, err := projectSvc.TerminateProjectContract(ctx, p.ID, orgA.ID, "", "sözleşme feshedildi")
		if err != nil {
			t.Fatalf("fesih: %v", err)
		}
		if c.Status != domain.ContractStatusTerminated {
			t.Errorf("beklenen terminated, geldi: %s", c.Status)
		}
	})
}
