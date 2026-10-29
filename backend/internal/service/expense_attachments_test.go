package service_test

// Genel masrafın görünürlüğü ve masraf fişi / belgesi (migration 0076) --
// gerçek bir PostgreSQL bağlantısı gerektirir. Kullanıcı geri bildirimleri:
// "genel giren masraflar hiç gözükmüyor" (Masraflarım genel masrafı
// listelemiyordu; finans okuması olmayan onaylayıcı onaylayacağı masrafı
// göremiyordu) ve "masraf girme yerine resim ve dosya ekleme gibi bir yer
// olsun". İzin kapıları HTTP katmanında:
// middleware/expense_attachments_security_test.go.

import (
	"bytes"
	"context"
	"errors"
	"io"
	"testing"
	"time"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/platform/storage"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

// Test içerikleri: türü içerikten tespit edilecek kadar gerçek başlıklar.
func testPNG(seed byte) []byte {
	return append([]byte{0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A, seed}, bytes.Repeat([]byte{seed}, 64)...)
}

var (
	testPDF  = []byte("%PDF-1.4\n1 0 obj << /Type /Catalog >> endobj\ntrailer << >>\n%%EOF\n")
	testHEIC = append([]byte{0x00, 0x00, 0x00, 0x18, 'f', 't', 'y', 'p', 'h', 'e', 'i', 'c', 0, 0, 0, 0, 'm', 'i', 'f', '1', 'h', 'e', 'i', 'c'}, bytes.Repeat([]byte{7}, 40)...)
)

func TestExpenseAttachmentsAndVisibility(t *testing.T) {
	dbURL := testDBURL(t)
	box := testSecretBox(t)
	ctx := context.Background()

	pool, err := repository.NewPool(ctx, dbURL)
	if err != nil {
		t.Fatalf("veritabanına bağlanılamadı: %v", err)
	}
	t.Cleanup(func() { pool.Close() })

	q := sqlc.New(pool)
	store := mustTestStore(t)
	userSvc := service.NewUserService(pool, q)
	authzSvc := service.NewAuthorizationService(pool, q)
	settingsSvc := service.NewSettingsService(q, box)
	offerSvc := service.NewOfferService(pool, q, settingsSvc, "http://localhost:3000")
	projectSvc := service.NewProjectService(pool, q, store, settingsSvc, "http://localhost:3000")
	notifSvc := service.NewNotificationService(q)
	platformSvc := service.NewPlatformService(pool, q, userSvc, service.NewCalcService(q), service.NewProductService(q))

	readyOrg := func(t *testing.T, slug string) *service.CreateOrganizationResult {
		t.Helper()
		var existingID string
		if err := pool.QueryRow(ctx, "SELECT id FROM organizations WHERE slug = $1", slug).Scan(&existingID); err == nil {
			cleanupOrganization(t, pool, existingID)
		}
		res, err := platformSvc.CreateOrganizationWithOwner(ctx, service.CreateOrganizationInput{
			Name: "Masraf Belge " + slug, Slug: slug,
			OwnerUsername: "owner_" + slug, OwnerPassword: "GeciciSifre123!", OwnerFullName: "Firma Sahibi",
		})
		if err != nil {
			t.Fatalf("firma oluşturulamadı: %v", err)
		}
		t.Cleanup(func() { cleanupOrganization(t, pool, res.Organization.ID) })
		return res
	}
	orgARes := readyOrg(t, "masraf-belge-a")
	orgA := orgARes.Organization
	orgB := readyOrg(t, "masraf-belge-b").Organization

	roleUser := func(t *testing.T, orgID, username, roleCode string) *domain.User {
		t.Helper()
		u, err := userSvc.Create(ctx, orgID, username, "GeciciSifre123!", username, domain.RoleKullanici, "")
		if err != nil {
			t.Fatalf("%s oluşturulamadı: %v", username, err)
		}
		if _, err := authzSvc.SetUserOrganizationRole(ctx, u.ID, orgID, "", roleCode); err != nil {
			t.Fatalf("%s rolü atanamadı: %v", username, err)
		}
		return u
	}
	admin := roleUser(t, orgA.ID, "att_admin", domain.OrgRoleAdmin)
	field := roleUser(t, orgA.ID, "att_field", domain.OrgRoleField)
	field2 := roleUser(t, orgA.ID, "att_field2", domain.OrgRoleField)
	// Eski Sistem: finance.read + finance.manage.
	clerk := roleUser(t, orgA.ID, "att_clerk", domain.OrgRoleLegacyUser)
	// Onaylayıcı ama finans okuması yok: Saha rolü + kişiye özel onay izni.
	approver := roleUser(t, orgA.ID, "att_approver", domain.OrgRoleField)
	if _, err := pool.Exec(ctx, `INSERT INTO user_permission_overrides (user_id, organization_id, permission_code, effect)
		VALUES ($1, $2, $3, 'grant')`, approver.ID, orgA.ID, domain.PermProjectsExpensesApprove); err != nil {
		t.Fatalf("onay izni verilemedi: %v", err)
	}

	newProject := func(t *testing.T, members ...*domain.User) *domain.Project {
		t.Helper()
		o, err := offerSvc.Create(ctx, service.CreateOfferInput{
			OrganizationID: orgA.ID, CustomerName: "Belge Müşteri", VatRate: ptrFloat(0),
			Items: []service.OfferItemInput{{ProductName: "İş", Quantity: 1, UnitPrice: 100000}},
		})
		if err != nil {
			t.Fatalf("teklif: %v", err)
		}
		if _, err := offerSvc.UpdateStatus(ctx, o.ID, orgA.ID, domain.OfferStatusGonderildi, ""); err != nil {
			t.Fatalf("gönderilemedi: %v", err)
		}
		link, err := offerSvc.CreateShareLink(ctx, o.ID, orgA.ID, "", nil)
		if err != nil {
			t.Fatalf("link: %v", err)
		}
		if _, err := offerSvc.RespondByShareLinkToken(ctx, link.Token, domain.OfferStatusKabulEdildi, "", ""); err != nil {
			t.Fatalf("kabul: %v", err)
		}
		p, err := projectSvc.CreateFromOffer(ctx, o.ID, orgA.ID, service.CreateProjectInput{Name: "Belge Projesi"})
		if err != nil {
			t.Fatalf("proje: %v", err)
		}
		for _, u := range members {
			if _, err := authzSvc.AddProjectUser(ctx, p.ID, orgA.ID, service.ProjectUserInput{
				UserID: u.ID, ProjectRole: domain.ProjectRoleMember,
			}); err != nil {
				t.Fatalf("proje erişimi: %v", err)
			}
		}
		return p
	}
	input := func(by *domain.User, desc string) service.ExpenseInput {
		return service.ExpenseInput{
			Category: domain.ExpenseMaterial, Description: desc, Amount: 450, Currency: "TRY",
			ExpenseDate: time.Now(), VATRate: ptrFloat(20), UserID: by.ID, OwnOnly: true,
		}
	}
	general := func(t *testing.T, by *domain.User, desc string) *domain.Expense {
		t.Helper()
		e, err := projectSvc.CreateGeneralExpense(ctx, orgA.ID, input(by, desc))
		if err != nil {
			t.Fatalf("genel masraf: %v", err)
		}
		return e
	}
	projectExpense := func(t *testing.T, p *domain.Project, by *domain.User, desc string) *domain.Expense {
		t.Helper()
		e, err := projectSvc.CreateExpense(ctx, p.ID, orgA.ID, input(by, desc))
		if err != nil {
			t.Fatalf("projeli masraf: %v", err)
		}
		return e
	}
	viewer := func(u *domain.User) service.ExpenseViewer { return service.ExpenseViewer{UserID: u.ID} }
	approverV := service.ExpenseViewer{UserID: approver.ID, Approve: true}
	clerkV := service.ExpenseViewer{UserID: clerk.ID, FinanceRead: true, FinanceManage: true}
	upload := func(t *testing.T, projectID, expenseID string, v service.ExpenseViewer, name string, body []byte) (*domain.ExpenseAttachment, bool, error) {
		t.Helper()
		return projectSvc.UploadExpenseAttachment(ctx, orgA.ID, projectID, expenseID, v, name, bytes.NewReader(body))
	}
	isNotFound := func(err error) bool {
		var nf *service.NotFoundError
		return errors.As(err, &nf)
	}

	p := newProject(t, field, field2, approver)

	t.Run("01_my_expenses_lists_general_expenses_too", func(t *testing.T) {
		g := general(t, field, "Ofis kırtasiye")
		pe := projectExpense(t, p, field, "Çimento")
		rows, err := projectSvc.ListMyExpenses(ctx, orgA.ID, field.ID, "", field.ID)
		if err != nil {
			t.Fatal(err)
		}
		var gotGeneral, gotProject *domain.MyExpense
		for i := range rows {
			switch rows[i].ID {
			case g.ID:
				gotGeneral = &rows[i]
			case pe.ID:
				gotProject = &rows[i]
			}
		}
		if gotGeneral == nil || !gotGeneral.IsGeneral() || gotGeneral.ProjectName != "" || gotGeneral.ProjectStatus != "" {
			t.Fatalf("genel masraf Masraflarım'da projesiz görünmeli: %+v", gotGeneral)
		}
		if gotProject == nil || gotProject.ProjectName == "" {
			t.Fatalf("projeli masraf da görünmeli: %+v", gotProject)
		}
		if gotGeneral.Attachments == nil || len(gotGeneral.Attachments) != 0 {
			t.Errorf("liste satırı belgeleri taşımalı (boş dilim): %v", gotGeneral.Attachments)
		}
		// Proje süzgeci genel masrafı düşürür.
		rows, err = projectSvc.ListMyExpenses(ctx, orgA.ID, field.ID, p.ID, field.ID)
		if err != nil {
			t.Fatal(err)
		}
		for _, r := range rows {
			if r.ID == g.ID {
				t.Fatal("proje süzgecinde genel masraf görünmemeli")
			}
		}
		// Başkasının genel masrafı görünmez.
		rows, err = projectSvc.ListMyExpenses(ctx, orgA.ID, field2.ID, "", field2.ID)
		if err != nil {
			t.Fatal(err)
		}
		for _, r := range rows {
			if r.ID == g.ID {
				t.Fatal("başkasının genel masrafı Masraflarım'da görünmemeli")
			}
		}
	})

	t.Run("02_approver_without_finance_read_lists_what_they_can_decide", func(t *testing.T) {
		pendingG := general(t, field, "Yakıt (bekliyor)")
		pendingP := projectExpense(t, p, field, "Kum (bekliyor)")
		withdrawn := general(t, field, "Geri çekilen")
		if _, err := projectSvc.VoidGeneralExpense(ctx, withdrawn.ID, orgA.ID, field.ID, "", true); err != nil {
			t.Fatal(err)
		}
		recent := general(t, field, "Yeni onaylanan")
		if _, err := projectSvc.ApproveGeneralExpense(ctx, recent.ID, orgA.ID, admin.ID); err != nil {
			t.Fatal(err)
		}
		old := general(t, field, "Eski onaylanan")
		if _, err := projectSvc.ApproveGeneralExpense(ctx, old.ID, orgA.ID, admin.ID); err != nil {
			t.Fatal(err)
		}
		if _, err := pool.Exec(ctx, "UPDATE project_expenses SET decided_at = now() - interval '40 days' WHERE id = $1", old.ID); err != nil {
			t.Fatal(err)
		}
		// Onaylayıcının üyesi olmadığı projedeki masraf görünmez.
		other := newProject(t, field)
		hidden := projectExpense(t, other, field, "Üye olmadığı proje")

		list := func(t *testing.T, approverScope bool) map[string]bool {
			t.Helper()
			rows, err := projectSvc.ListExpensesAll(ctx, orgA.ID, service.ExpenseListFilter{
				OnlyCreatedBy: approver.ID, ApproverScope: approverScope, RestrictToUserID: approver.ID,
			})
			if err != nil {
				t.Fatal(err)
			}
			seen := map[string]bool{}
			for _, r := range rows {
				seen[r.ID] = true
				if r.Attachments == nil {
					t.Errorf("Masraflar satırı belgeleri taşımalı: %s", r.ID)
				}
			}
			return seen
		}
		seen := list(t, true)
		for _, e := range []*domain.Expense{pendingG, pendingP, recent} {
			if !seen[e.ID] {
				t.Errorf("onaylayıcı %q masrafını görmeli", e.Description)
			}
		}
		for _, e := range []*domain.Expense{withdrawn, old, hidden} {
			if seen[e.ID] {
				t.Errorf("onaylayıcı %q masrafını görmemeli", e.Description)
			}
		}
		// Kapsam kapalıyken (yalnızca kendi) hiçbiri görünmez.
		seen = list(t, false)
		if seen[pendingG.ID] || seen[pendingP.ID] {
			t.Error("kapsam kapalıyken başkasının masrafı görünmemeli")
		}
		// Ve onaylayıcı buradan karar verebilir.
		if _, err := projectSvc.ApproveGeneralExpense(ctx, pendingG.ID, orgA.ID, approver.ID); err != nil {
			t.Fatalf("onaylayıcı genel masrafı onaylayabilmeli: %v", err)
		}
	})

	t.Run("03_notifications_open_a_screen_the_approver_can_use", func(t *testing.T) {
		target := func(userID, typ, entityID string) string {
			t.Helper()
			res, err := notifSvc.List(ctx, userID, orgA.ID, 1, 200)
			if err != nil {
				t.Fatal(err)
			}
			for _, n := range res.Notifications {
				if n.Type == typ && n.EntityID != nil && *n.EntityID == entityID {
					return n.ActionTarget
				}
			}
			return ""
		}
		// Gruplu bildirim: aynı türde okunmamış bildirim varsa yenisi açılmaz
		// (o güncellenir, kimliği ilk masrafta kalır) -- her adımdan önce
		// okunmuş sayılır.
		markRead := func(t *testing.T) {
			t.Helper()
			for _, u := range []*domain.User{approver, admin, field} {
				if err := notifSvc.MarkAllRead(ctx, u.ID, orgA.ID, nil); err != nil {
					t.Fatal(err)
				}
			}
		}
		markRead(t)
		g := general(t, field, "Bildirim genel")
		if got := target(approver.ID, domain.NotificationExpensePendingApproval, g.ID); got != "/diger/masraflar?durum=pending" {
			t.Errorf("genel masraf onay bildirimi Masraflar'ın onay bekleyenlerini açmalı: %q", got)
		}
		markRead(t)
		pe := projectExpense(t, p, field, "Bildirim projeli")
		if got := target(approver.ID, domain.NotificationExpensePendingApproval, pe.ID); got != "/diger/masraflar?durum=pending" {
			t.Errorf("finans okuması olmayan onaylayıcı projeli masrafta da Masraflar'a gitmeli: %q", got)
		}
		if got := target(admin.ID, domain.NotificationExpensePendingApproval, pe.ID); got != "/projeler/"+p.ID+"?grup=finans&alt=finans" {
			t.Errorf("finans okuyabilen onaylayıcı projenin Finans görünümüne gitmeli: %q", got)
		}
		if _, err := projectSvc.RejectGeneralExpense(ctx, g.ID, orgA.ID, admin.ID, "Fiş okunmuyor"); err != nil {
			t.Fatal(err)
		}
		if got := target(field.ID, domain.NotificationExpenseRejected, g.ID); got != "/diger/masraflarim?masraf="+g.ID {
			t.Errorf("genel masraf kararı Masraflarım'da o masrafı açmalı: %q", got)
		}
	})

	t.Run("04_creator_uploads_lists_and_opens_receipts", func(t *testing.T) {
		g := general(t, field, "Belge genel")
		a, created, err := upload(t, "", g.ID, viewer(field), "fis.png", testPNG(1))
		if err != nil || !created || a.MIMEType != "image/png" || a.OriginalName != "fis.png" || a.UploadedBy == nil || *a.UploadedBy != field.ID {
			t.Fatalf("giren kendi masrafına fiş eklemeli: %+v %v %v", a, created, err)
		}
		// Aynı içerik ikinci kez: mevcut kayıt (yeniden deneme mükerrer açmaz).
		again, created, err := upload(t, "", g.ID, viewer(field), "fis-kopya.png", testPNG(1))
		if err != nil || created || again.ID != a.ID {
			t.Fatalf("aynı içerik mevcut kaydı dönmeli: %+v %v %v", again, created, err)
		}
		pdf, _, err := upload(t, "", g.ID, viewer(field), "fatura.pdf", testPDF)
		if err != nil || pdf.MIMEType != "application/pdf" {
			t.Fatalf("PDF eklenmeli: %+v %v", pdf, err)
		}
		heic, _, err := upload(t, "", g.ID, viewer(field), "IMG_0001.HEIC", testHEIC)
		if err != nil || heic.MIMEType != "image/heic" {
			t.Fatalf("HEIC eklenmeli: %+v %v", heic, err)
		}
		if _, _, err := upload(t, "", g.ID, viewer(field), "not.txt", []byte("düz metin, fiş değil")); !errors.Is(err, service.ErrUnsupportedType) {
			t.Errorf("metin dosyası reddedilmeli: %v", err)
		}
		if _, _, err := upload(t, "", g.ID, viewer(field), "bos.png", nil); !errors.Is(err, service.ErrEmptyFile) {
			t.Errorf("boş dosya reddedilmeli: %v", err)
		}
		list, err := projectSvc.ListExpenseAttachments(ctx, orgA.ID, "", g.ID, viewer(field))
		if err != nil || len(list) != 3 || list[0].ID != a.ID {
			t.Fatalf("üç belge eklenme sırasıyla listelenmeli: %+v %v", list, err)
		}
		// Masraflarım satırı belgeleri taşır.
		rows, err := projectSvc.ListMyExpenses(ctx, orgA.ID, field.ID, "", field.ID)
		if err != nil {
			t.Fatal(err)
		}
		for _, r := range rows {
			if r.ID == g.ID && len(r.Attachments) != 3 {
				t.Errorf("Masraflarım satırında 3 belge olmalı: %d", len(r.Attachments))
			}
		}
		// Giren, onaylayıcı ve finans okuyucusu açar; başka saha çalışanı
		// masrafı bile bulamaz.
		for name, v := range map[string]service.ExpenseViewer{"giren": viewer(field), "onaylayıcı": approverV, "finans": clerkV} {
			got, rc, err := projectSvc.OpenExpenseAttachment(ctx, orgA.ID, "", g.ID, a.ID, v)
			if err != nil {
				t.Errorf("%s fişi açabilmeli: %v", name, err)
				continue
			}
			body, _ := io.ReadAll(rc)
			rc.Close()
			if got.MIMEType != "image/png" || !bytes.Equal(body, testPNG(1)) {
				t.Errorf("%s: içerik/tür yanlış: %s", name, got.MIMEType)
			}
		}
		if _, _, err := projectSvc.OpenExpenseAttachment(ctx, orgA.ID, "", g.ID, a.ID, viewer(field2)); !isNotFound(err) {
			t.Errorf("başkasının masrafının fişi açılmamalı: %v", err)
		}
		if _, err := projectSvc.ListExpenseAttachments(ctx, orgA.ID, "", g.ID, viewer(field2)); !isNotFound(err) {
			t.Errorf("başkasının masrafının belge listesi açılmamalı: %v", err)
		}
	})

	t.Run("05_scope_project_url_and_general_url_do_not_mix", func(t *testing.T) {
		pe := projectExpense(t, p, field, "Kapsam projeli")
		a, _, err := upload(t, p.ID, pe.ID, viewer(field), "irsaliye.jpg", testPNG(2))
		if err != nil {
			t.Fatalf("projeli masrafa belge eklenmeli: %v", err)
		}
		if _, err := projectSvc.ListExpenseAttachments(ctx, orgA.ID, "", pe.ID, clerkV); !errors.Is(err, service.ErrGeneralExpenseNotFound) {
			t.Errorf("projeli masraf genel uçtan açılmamalı: %v", err)
		}
		other := newProject(t)
		if _, _, err := projectSvc.OpenExpenseAttachment(ctx, orgA.ID, other.ID, pe.ID, a.ID, clerkV); !errors.Is(err, service.ErrExpenseNotFound) {
			t.Errorf("başka projenin URL'sinden açılmamalı: %v", err)
		}
		g := general(t, field, "Kapsam genel")
		if _, _, err := projectSvc.OpenExpenseAttachment(ctx, orgA.ID, "", g.ID, a.ID, clerkV); !errors.Is(err, service.ErrExpenseAttachmentNotFound) {
			t.Errorf("başka masrafın belgesi bu masraftan açılmamalı: %v", err)
		}
		// Proje kalıcı silinirse (cmd/purge-project) belge dosyası da listelenir.
		pid, _ := repository.StringToUUID(p.ID)
		keys, err := q.ListProjectObjectKeys(ctx, pid)
		if err != nil {
			t.Fatal(err)
		}
		var key string
		if err := pool.QueryRow(ctx, "SELECT object_key FROM expense_attachments WHERE id = $1", a.ID).Scan(&key); err != nil {
			t.Fatal(err)
		}
		found := false
		for _, k := range keys {
			found = found || k == key
		}
		if !found {
			t.Error("proje temizliği masraf belgesinin dosyasını da silmeli")
		}
	})

	t.Run("06_who_may_add_or_remove", func(t *testing.T) {
		g := general(t, field, "Yazma kuralları")
		// Okuyabilen ama sahibi olmayan onaylayıcı ekleyemez.
		if _, _, err := upload(t, "", g.ID, approverV, "x.png", testPNG(3)); !errors.Is(err, service.ErrExpenseAttachmentNotOwn) {
			t.Errorf("onaylayıcı başkasının masrafına belge ekleyememeli: %v", err)
		}
		// Okuyamayan saha çalışanına masraf "bulunamadı".
		if _, _, err := upload(t, "", g.ID, viewer(field2), "x.png", testPNG(3)); !isNotFound(err) {
			t.Errorf("başka saha çalışanı masrafı bulamamalı: %v", err)
		}
		// Finans yöneticisi ekler ve siler.
		a, _, err := upload(t, "", g.ID, clerkV, "muhasebe.pdf", testPDF)
		if err != nil {
			t.Fatalf("finans yöneticisi belge eklemeli: %v", err)
		}
		if err := projectSvc.DeleteExpenseAttachment(ctx, orgA.ID, "", g.ID, a.ID, clerkV); err != nil {
			t.Fatalf("finans yöneticisi belge silmeli: %v", err)
		}
		// Reddedilen masrafta giren ekleyip siler.
		if _, err := projectSvc.RejectGeneralExpense(ctx, g.ID, orgA.ID, admin.ID, "Fiş yok"); err != nil {
			t.Fatal(err)
		}
		mine, _, err := upload(t, "", g.ID, viewer(field), "fis.png", testPNG(4))
		if err != nil {
			t.Fatalf("reddedilen masrafa giren fiş eklemeli: %v", err)
		}
		var key string
		if err := pool.QueryRow(ctx, "SELECT object_key FROM expense_attachments WHERE id = $1", mine.ID).Scan(&key); err != nil {
			t.Fatal(err)
		}
		if err := projectSvc.DeleteExpenseAttachment(ctx, orgA.ID, "", g.ID, mine.ID, viewer(field)); err != nil {
			t.Fatalf("giren kendi fişini silmeli: %v", err)
		}
		if _, err := store.Open(ctx, key); !errors.Is(err, storage.ErrNotFound) {
			t.Errorf("silinen belgenin dosyası depoda kalmamalı: %v", err)
		}
		if _, _, err := projectSvc.OpenExpenseAttachment(ctx, orgA.ID, "", g.ID, mine.ID, viewer(field)); !errors.Is(err, service.ErrExpenseAttachmentNotFound) {
			t.Errorf("silinen belge açılmamalı: %v", err)
		}
	})

	t.Run("07_approved_and_voided_expenses_are_read_only", func(t *testing.T) {
		pe := projectExpense(t, p, field, "Onaylanacak")
		a, _, err := upload(t, p.ID, pe.ID, viewer(field), "fis.png", testPNG(5))
		if err != nil {
			t.Fatal(err)
		}
		// Onaylayıcı karar vermeden fişi görür.
		if list, err := projectSvc.ListExpenseAttachments(ctx, orgA.ID, p.ID, pe.ID, approverV); err != nil || len(list) != 1 {
			t.Fatalf("onaylayıcı karar öncesi fişi görmeli: %v %v", list, err)
		}
		if _, err := projectSvc.ApproveExpense(ctx, p.ID, pe.ID, orgA.ID, approver.ID); err != nil {
			t.Fatal(err)
		}
		for name, v := range map[string]service.ExpenseViewer{"giren": viewer(field), "finans": clerkV} {
			if _, _, err := upload(t, p.ID, pe.ID, v, "sonra.png", testPNG(6)); !errors.Is(err, service.ErrExpenseAttachmentsApproved) {
				t.Errorf("%s onaylanmış masrafa belge ekleyememeli: %v", name, err)
			}
			if err := projectSvc.DeleteExpenseAttachment(ctx, orgA.ID, p.ID, pe.ID, a.ID, v); !errors.Is(err, service.ErrExpenseAttachmentsApproved) {
				t.Errorf("%s onaylanmış masrafın belgesini silememeli: %v", name, err)
			}
		}
		// Onaylanmış masrafın belgesi okunur kalır.
		if _, rc, err := projectSvc.OpenExpenseAttachment(ctx, orgA.ID, p.ID, pe.ID, a.ID, viewer(field)); err != nil {
			t.Errorf("onaylanmış masrafın fişi okunmalı: %v", err)
		} else {
			rc.Close()
		}

		g := general(t, field, "Geri çekilecek")
		ga, _, err := upload(t, "", g.ID, viewer(field), "fis.png", testPNG(7))
		if err != nil {
			t.Fatal(err)
		}
		if _, err := projectSvc.VoidGeneralExpense(ctx, g.ID, orgA.ID, field.ID, "", true); err != nil {
			t.Fatal(err)
		}
		if _, _, err := upload(t, "", g.ID, viewer(field), "yeni.png", testPNG(8)); !errors.Is(err, service.ErrExpenseAttachmentsVoided) {
			t.Errorf("iptal edilmiş masrafa belge eklenmemeli: %v", err)
		}
		if err := projectSvc.DeleteExpenseAttachment(ctx, orgA.ID, "", g.ID, ga.ID, clerkV); !errors.Is(err, service.ErrExpenseAttachmentsVoided) {
			t.Errorf("iptal edilmiş masrafın belgesi silinmemeli: %v", err)
		}
		// Giren geri çektiği masrafın fişini görür; onaylayıcı (karar
		// verecek bir şey yok) artık görmez.
		if _, rc, err := projectSvc.OpenExpenseAttachment(ctx, orgA.ID, "", g.ID, ga.ID, viewer(field)); err != nil {
			t.Errorf("giren geri çektiği masrafın fişini görmeli: %v", err)
		} else {
			rc.Close()
		}
		if _, _, err := projectSvc.OpenExpenseAttachment(ctx, orgA.ID, "", g.ID, ga.ID, approverV); !isNotFound(err) {
			t.Errorf("onaylayıcı iptal edilmiş başkasının masrafını görmemeli: %v", err)
		}
	})

	t.Run("08_limit_per_expense", func(t *testing.T) {
		g := general(t, field, "Sınır")
		for i := 0; i < domain.ExpenseAttachmentsMax; i++ {
			if _, _, err := upload(t, "", g.ID, viewer(field), "s.png", testPNG(byte(20+i))); err != nil {
				t.Fatalf("%d. belge: %v", i+1, err)
			}
		}
		if _, _, err := upload(t, "", g.ID, viewer(field), "fazla.png", testPNG(99)); !errors.Is(err, service.ErrExpenseAttachmentLimit) {
			t.Errorf("sınırın üstü reddedilmeli: %v", err)
		}
	})

	t.Run("09_tenant_isolation", func(t *testing.T) {
		g := general(t, field, "Firma A")
		a, _, err := upload(t, "", g.ID, viewer(field), "fis.png", testPNG(42))
		if err != nil {
			t.Fatal(err)
		}
		ownerB := service.ExpenseViewer{UserID: admin.ID, FinanceRead: true, FinanceManage: true, Approve: true}
		if _, err := projectSvc.ListExpenseAttachments(ctx, orgB.ID, "", g.ID, ownerB); !isNotFound(err) {
			t.Errorf("başka firma belge listesine ulaşmamalı: %v", err)
		}
		if _, _, err := projectSvc.OpenExpenseAttachment(ctx, orgB.ID, "", g.ID, a.ID, ownerB); !isNotFound(err) {
			t.Errorf("başka firma belgeyi açmamalı: %v", err)
		}
		if _, _, err := projectSvc.UploadExpenseAttachment(ctx, orgB.ID, "", g.ID, ownerB, "x.png", bytes.NewReader(testPNG(43))); !isNotFound(err) {
			t.Errorf("başka firma belge eklememeli: %v", err)
		}
		if err := projectSvc.DeleteExpenseAttachment(ctx, orgB.ID, "", g.ID, a.ID, ownerB); !isNotFound(err) {
			t.Errorf("başka firma belge silmemeli: %v", err)
		}
		// Veritabanı da başka firmanın masrafına belge bağlamayı reddeder.
		if _, err := pool.Exec(ctx, `INSERT INTO expense_attachments (organization_id, expense_id, object_key, original_name, mime_type, size_bytes, sha256)
			VALUES ($1, $2, 'expenses/x/y/z.png', 'z.png', 'image/png', 1, repeat('a', 64))`, orgB.ID, g.ID); err == nil {
			t.Error("başka firmanın masrafına belge satırı yazılabildi")
		}
	})
}
