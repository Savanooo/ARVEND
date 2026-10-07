package service_test

// Faz 7 (Proje Operasyon Yönetimi) testleri.

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

func TestProjectOperations(t *testing.T) {
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
	employeeSvc := service.NewEmployeeService(q)

	orgA := mustCreateOrg(t, ctx, orgSvc, pool, "Operasyon Test A", "operasyon-test-a")
	orgB := mustCreateOrg(t, ctx, orgSvc, pool, "Operasyon Test B", "operasyon-test-b")

	today := time.Now()

	newProject := func(t *testing.T, orgID string) *domain.Project {
		t.Helper()
		o, err := offerSvc.Create(ctx, service.CreateOfferInput{
			OrganizationID: orgID,
			CustomerName:   "Operasyon Müşteri",
			Items:          []service.OfferItemInput{{ProductName: "İş", Quantity: 1, UnitPrice: 100000}},
		})
		if err != nil {
			t.Fatalf("teklif: %v", err)
		}
		if _, err := offerSvc.UpdateStatus(ctx, o.ID, orgID, domain.OfferStatusGonderildi, ""); err != nil {
			t.Fatalf("gönderim: %v", err)
		}
		link, err := offerSvc.CreateShareLink(ctx, o.ID, orgID, "", nil)
		if err != nil {
			t.Fatalf("link: %v", err)
		}
		if _, err := offerSvc.RespondByShareLinkToken(ctx, link.Token, domain.OfferStatusKabulEdildi, "", ""); err != nil {
			t.Fatalf("kabul: %v", err)
		}
		p, err := projectSvc.CreateFromOffer(ctx, o.ID, orgID, service.CreateProjectInput{Name: "Operasyon Projesi"})
		if err != nil {
			t.Fatalf("proje: %v", err)
		}
		return p
	}

	newEmployee := func(t *testing.T, orgID, name string) *domain.Employee {
		t.Helper()
		e, err := employeeSvc.Create(ctx, orgID, service.EmployeeInput{FullName: name, Position: "Usta"})
		if err != nil {
			t.Fatalf("personel: %v", err)
		}
		return e
	}

	t.Run("1_member_assignment_with_snapshot", func(t *testing.T) {
		p := newProject(t, orgA.ID)
		emp := newEmployee(t, orgA.ID, "Ahmet Usta")

		m, err := projectSvc.AssignMember(ctx, p.ID, orgA.ID, service.ProjectMemberInput{
			EmployeeID: emp.ID, RoleTitle: "Şantiye Şefi", StartDate: &today,
		})
		if err != nil {
			t.Fatalf("atama: %v", err)
		}
		if m.EmployeeName != "Ahmet Usta" || !m.IsActive() {
			t.Errorf("beklenmeyen üye: %+v", m)
		}

		// Personel kartı sonradan değişse bile atama snapshot'ı korunmalı.
		if _, err := employeeSvc.Update(ctx, emp.ID, orgA.ID, service.EmployeeInput{
			FullName: "Ahmet Yılmaz (değişti)", Position: "Usta",
		}); err != nil {
			t.Fatalf("personel güncellenemedi: %v", err)
		}
		members, err := projectSvc.ListMembers(ctx, p.ID, orgA.ID)
		if err != nil {
			t.Fatalf("liste: %v", err)
		}
		if members[0].EmployeeName != "Ahmet Usta" {
			t.Errorf("atama anındaki isim snapshot'ı kayboldu: %q", members[0].EmployeeName)
		}
	})

	t.Run("2_duplicate_active_member_rejected", func(t *testing.T) {
		p := newProject(t, orgA.ID)
		emp := newEmployee(t, orgA.ID, "Mehmet")
		if _, err := projectSvc.AssignMember(ctx, p.ID, orgA.ID, service.ProjectMemberInput{EmployeeID: emp.ID}); err != nil {
			t.Fatalf("ilk atama: %v", err)
		}
		if _, err := projectSvc.AssignMember(ctx, p.ID, orgA.ID, service.ProjectMemberInput{EmployeeID: emp.ID}); !errors.Is(err, service.ErrDuplicateMember) {
			t.Errorf("aynı personel ikinci kez atanabildi: err=%v", err)
		}
	})

	t.Run("3_concurrent_duplicate_assignment_creates_one", func(t *testing.T) {
		p := newProject(t, orgA.ID)
		emp := newEmployee(t, orgA.ID, "Eşzamanlı")

		var wg sync.WaitGroup
		errs := make([]error, 2)
		for i := range 2 {
			wg.Add(1)
			go func(i int) {
				defer wg.Done()
				_, errs[i] = projectSvc.AssignMember(ctx, p.ID, orgA.ID, service.ProjectMemberInput{EmployeeID: emp.ID})
			}(i)
		}
		wg.Wait()

		ok, dup := 0, 0
		for _, e := range errs {
			switch {
			case e == nil:
				ok++
			case errors.Is(e, service.ErrDuplicateMember):
				dup++
			default:
				t.Fatalf("beklenmeyen hata: %v", e)
			}
		}
		if ok != 1 || dup != 1 {
			t.Errorf("beklenen 1 başarı + 1 duplicate reddi, geldi: %d/%d", ok, dup)
		}
		members, _ := projectSvc.ListMembers(ctx, p.ID, orgA.ID)
		active := 0
		for _, m := range members {
			if m.IsActive() {
				active++
			}
		}
		if active != 1 {
			t.Errorf("aktif üye sayısı 1 olmalı, geldi: %d", active)
		}
	})

	t.Run("4_member_history_survives_removal_and_reassignment", func(t *testing.T) {
		p := newProject(t, orgA.ID)
		emp := newEmployee(t, orgA.ID, "Geçmiş")
		m1, err := projectSvc.AssignMember(ctx, p.ID, orgA.ID, service.ProjectMemberInput{EmployeeID: emp.ID})
		if err != nil {
			t.Fatalf("atama: %v", err)
		}
		if _, err := projectSvc.EndMembership(ctx, p.ID, m1.ID, orgA.ID, "", nil); err != nil {
			t.Fatalf("çıkarma: %v", err)
		}
		// Çıkarıldıktan sonra yeniden atanabilmeli (kısmi unique indeks
		// yalnızca AKTİF atamaları kapsar).
		if _, err := projectSvc.AssignMember(ctx, p.ID, orgA.ID, service.ProjectMemberInput{EmployeeID: emp.ID}); err != nil {
			t.Fatalf("yeniden atama: %v", err)
		}
		members, _ := projectSvc.ListMembers(ctx, p.ID, orgA.ID)
		if len(members) != 2 {
			t.Errorf("geçmiş kayıt kayboldu, beklenen 2 kayıt: %d", len(members))
		}
	})

	t.Run("5_cross_tenant_employee_cannot_be_assigned", func(t *testing.T) {
		p := newProject(t, orgA.ID)
		empB := newEmployee(t, orgB.ID, "Firma B Personeli")
		if _, err := projectSvc.AssignMember(ctx, p.ID, orgA.ID, service.ProjectMemberInput{
			EmployeeID: empB.ID,
		}); !errors.Is(err, service.ErrInvalidEmployee) {
			t.Errorf("başka firmanın personeli atanabildi: err=%v", err)
		}
	})

	t.Run("6_schedule_and_task_lifecycle", func(t *testing.T) {
		p := newProject(t, orgA.ID)
		emp := newEmployee(t, orgA.ID, "Görevli")

		item, err := projectSvc.CreateScheduleItem(ctx, p.ID, orgA.ID, service.ScheduleItemInput{
			Name: "Kaba İnşaat", StartDate: &today, SortOrder: 0,
		})
		if err != nil {
			t.Fatalf("aşama: %v", err)
		}
		task, err := projectSvc.CreateTask(ctx, p.ID, orgA.ID, service.TaskInput{
			Title: "Kalıp sökümü", ScheduleItemID: &item.ID, AssignedEmployeeID: &emp.ID,
			Priority: domain.TaskPriorityHigh,
		})
		if err != nil {
			t.Fatalf("görev: %v", err)
		}
		if task.Status != domain.TaskStatusTodo || task.AssignedName != "Görevli" {
			t.Errorf("beklenmeyen görev: %+v", task)
		}
		if task.CompletedAt != nil {
			t.Errorf("yeni görevde completed_at dolu")
		}

		done, err := projectSvc.CompleteTask(ctx, p.ID, task.ID, orgA.ID, "")
		if err != nil {
			t.Fatalf("tamamlama: %v", err)
		}
		if done.Status != domain.TaskStatusCompleted || done.CompletedAt == nil {
			t.Errorf("tamamlanan görevde durum/tarih tutarsız: %+v", done)
		}

		items, _ := projectSvc.ListScheduleItems(ctx, p.ID, orgA.ID)
		if items[0].TaskCount != 1 || items[0].CompletedTaskCount != 1 {
			t.Errorf("aşama görev sayacı yanlış: %+v", items[0])
		}
	})

	t.Run("7_concurrent_task_completion_is_idempotent", func(t *testing.T) {
		p := newProject(t, orgA.ID)
		task, err := projectSvc.CreateTask(ctx, p.ID, orgA.ID, service.TaskInput{Title: "Tek seferlik"})
		if err != nil {
			t.Fatalf("görev: %v", err)
		}

		var wg sync.WaitGroup
		results := make([]*domain.ProjectTask, 2)
		for i := range 2 {
			wg.Add(1)
			go func(i int) {
				defer wg.Done()
				results[i], _ = projectSvc.CompleteTask(ctx, p.ID, task.ID, orgA.ID, "")
			}(i)
		}
		wg.Wait()

		for i, r := range results {
			if r == nil || r.Status != domain.TaskStatusCompleted {
				t.Fatalf("istek #%d tamamlanmış görev döndürmedi: %+v", i, r)
			}
		}
		// İkinci tamamlama İKİNCİ bir olay yazmamalı.
		events, err := projectSvc.ListProjectEvents(ctx, p.ID, orgA.ID)
		if err != nil {
			t.Fatalf("olaylar: %v", err)
		}
		completed := 0
		for _, e := range events {
			if e.EventType == domain.ProjectEventTaskCompleted {
				completed++
			}
		}
		if completed != 1 {
			t.Errorf("task_completed olayı %d kez yazıldı (1 olmalı)", completed)
		}
	})

	t.Run("8_cross_tenant_task_relations_blocked", func(t *testing.T) {
		pA := newProject(t, orgA.ID)
		pB := newProject(t, orgB.ID)
		empB := newEmployee(t, orgB.ID, "B Personeli")
		itemB, err := projectSvc.CreateScheduleItem(ctx, pB.ID, orgB.ID, service.ScheduleItemInput{Name: "B Aşaması"})
		if err != nil {
			t.Fatalf("aşama: %v", err)
		}

		// Firma A'nın projesine Firma B'nin aşaması bağlanamaz.
		if _, err := projectSvc.CreateTask(ctx, pA.ID, orgA.ID, service.TaskInput{
			Title: "X", ScheduleItemID: &itemB.ID,
		}); !errors.Is(err, service.ErrInvalidSchedule) {
			t.Errorf("cross-tenant aşama bağlanabildi: err=%v", err)
		}
		// Firma B'nin personeli atanamaz.
		if _, err := projectSvc.CreateTask(ctx, pA.ID, orgA.ID, service.TaskInput{
			Title: "X", AssignedEmployeeID: &empB.ID,
		}); !errors.Is(err, service.ErrInvalidEmployee) {
			t.Errorf("cross-tenant personel atanabildi: err=%v", err)
		}
		// Firma B, Firma A'nın projesine görev ekleyemez.
		if _, err := projectSvc.CreateTask(ctx, pA.ID, orgB.ID, service.TaskInput{Title: "X"}); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("cross-tenant görev oluşturulabildi: err=%v", err)
		}
	})

	t.Run("9_file_upload_download_and_dedup", func(t *testing.T) {
		p := newProject(t, orgA.ID)
		content := "%PDF-1.4\nsözleşme içeriği\n"

		f, err := projectSvc.UploadFile(ctx, p.ID, orgA.ID, service.UploadInput{
			OriginalName: "sozlesme.pdf", Reader: strings.NewReader(content),
			Category: domain.FileCategoryContract,
		})
		if err != nil {
			t.Fatalf("yükleme: %v", err)
		}
		if f.SizeBytes != int64(len(content)) || f.SHA256 == "" {
			t.Errorf("beklenmeyen dosya: %+v", f)
		}
		// Nesne anahtarı SUNUCU tarafında üretilmeli: kullanıcının verdiği
		// ad anahtarın içinde geçmemeli.
		if strings.Contains(f.ObjectKey, "sozlesme") {
			t.Errorf("nesne anahtarı kullanıcı girdisinden türetilmiş: %q", f.ObjectKey)
		}

		_, rc, err := projectSvc.OpenFile(ctx, p.ID, f.ID, orgA.ID)
		if err != nil {
			t.Fatalf("indirme: %v", err)
		}
		rc.Close()

		// Aynı içerik ikinci kez yüklenince yeni kayıt açılmamalı ve bu
		// SESSİZCE "başarılı" görünmemeli: 409 (ErrDuplicateContent),
		// mevcut dosyanın adıyla.
		_, err = projectSvc.UploadFile(ctx, p.ID, orgA.ID, service.UploadInput{
			OriginalName: "sozlesme-kopya.pdf", Reader: strings.NewReader(content),
			Category: domain.FileCategoryContract,
		})
		if !errors.Is(err, service.ErrDuplicateContent) || !strings.Contains(err.Error(), "sozlesme.pdf") {
			t.Fatalf("ikinci yükleme ErrDuplicateContent (mevcut adla) dönmeli: %v", err)
		}
		files, err := projectSvc.ListFiles(ctx, p.ID, orgA.ID)
		if err != nil || len(files) != 1 {
			t.Errorf("aynı içerik iki kez kaydedildi: %d %v", len(files), err)
		}
	})

	t.Run("10_cross_tenant_file_download_blocked", func(t *testing.T) {
		p := newProject(t, orgA.ID)
		f, err := projectSvc.UploadFile(ctx, p.ID, orgA.ID, service.UploadInput{
			OriginalName: "gizli.pdf", Reader: strings.NewReader("%PDF-1.4\ngizli\n"),
		})
		if err != nil {
			t.Fatalf("yükleme: %v", err)
		}
		// Firma B dosya UUID'sini bilse bile TEK BAYT okuyamamalı.
		if _, _, err := projectSvc.OpenFile(ctx, p.ID, f.ID, orgB.ID); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("başka firmanın dosyası indirilebildi: err=%v", err)
		}
		if rows, _ := projectSvc.ListFiles(ctx, p.ID, orgB.ID); len(rows) != 0 {
			t.Errorf("başka firmanın dosya listesi görülebildi")
		}
	})

	t.Run("11_photo_requires_real_image_content", func(t *testing.T) {
		p := newProject(t, orgA.ID)
		// Uzantı .jpg ama içerik PDF: içerikten tespit edilen tür
		// image/* olmadığı için reddedilmeli (MIME spoofing).
		if _, err := projectSvc.UploadPhoto(ctx, p.ID, orgA.ID, service.UploadInput{
			OriginalName: "sahte.jpg", Reader: strings.NewReader("%PDF-1.4\nbu bir pdf\n"),
		}); !errors.Is(err, service.ErrUnsupportedType) {
			t.Errorf("uzantısı jpg olan PDF fotoğraf olarak kabul edildi: err=%v", err)
		}

		// Gerçek PNG imzası kabul edilmeli.
		png := append([]byte{0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A}, make([]byte, 64)...)
		ph, err := projectSvc.UploadPhoto(ctx, p.ID, orgA.ID, service.UploadInput{
			OriginalName: "santiye.png", Reader: strings.NewReader(string(png)),
			Stage: domain.PhotoStageProgress,
		})
		if err != nil {
			t.Fatalf("gerçek png reddedildi: %v", err)
		}
		if ph.MIMEType != "image/png" {
			t.Errorf("mime içerikten tespit edilmedi: %q", ph.MIMEType)
		}
	})

	t.Run("12_executable_content_rejected", func(t *testing.T) {
		p := newProject(t, orgA.ID)
		// ELF imzası: izin verilen türler listesinde yok.
		elf := append([]byte{0x7F, 'E', 'L', 'F'}, make([]byte, 64)...)
		if _, err := projectSvc.UploadFile(ctx, p.ID, orgA.ID, service.UploadInput{
			OriginalName: "rapor.pdf", Reader: strings.NewReader(string(elf)),
		}); !errors.Is(err, service.ErrUnsupportedType) {
			t.Errorf("çalıştırılabilir içerik .pdf adıyla kabul edildi: err=%v", err)
		}
	})

	t.Run("13_notes_keep_author_and_history", func(t *testing.T) {
		p := newProject(t, orgA.ID)
		if _, err := projectSvc.CreateNote(ctx, p.ID, orgA.ID, "İlk not", ""); err != nil {
			t.Fatalf("not: %v", err)
		}
		if _, err := projectSvc.CreateNote(ctx, p.ID, orgA.ID, "İkinci not", ""); err != nil {
			t.Fatalf("not: %v", err)
		}
		notes, err := projectSvc.ListNotes(ctx, p.ID, orgA.ID)
		if err != nil {
			t.Fatalf("liste: %v", err)
		}
		if len(notes) != 2 {
			t.Errorf("iki ayrı not bekleniyordu: %d", len(notes))
		}
		if _, err := projectSvc.CreateNote(ctx, p.ID, orgA.ID, "   ", ""); err == nil {
			t.Errorf("boş not kabul edildi")
		}
		if rows, _ := projectSvc.ListNotes(ctx, p.ID, orgB.ID); len(rows) != 0 {
			t.Errorf("başka firmanın notları görülebildi")
		}
	})

	t.Run("14_operations_summary", func(t *testing.T) {
		p := newProject(t, orgA.ID)
		emp := newEmployee(t, orgA.ID, "Özet Personeli")
		if _, err := projectSvc.AssignMember(ctx, p.ID, orgA.ID, service.ProjectMemberInput{EmployeeID: emp.ID}); err != nil {
			t.Fatalf("atama: %v", err)
		}
		past := today.AddDate(0, 0, -5)
		if _, err := projectSvc.CreateTask(ctx, p.ID, orgA.ID, service.TaskInput{Title: "Geciken", DueDate: &past}); err != nil {
			t.Fatalf("görev: %v", err)
		}
		done, err := projectSvc.CreateTask(ctx, p.ID, orgA.ID, service.TaskInput{Title: "Bitecek"})
		if err != nil {
			t.Fatalf("görev: %v", err)
		}
		if _, err := projectSvc.CompleteTask(ctx, p.ID, done.ID, orgA.ID, ""); err != nil {
			t.Fatalf("tamamlama: %v", err)
		}

		s, err := projectSvc.OperationsSummary(ctx, p.ID, orgA.ID)
		if err != nil {
			t.Fatalf("özet: %v", err)
		}
		if s.ActiveMemberCount != 1 || s.TotalTaskCount != 2 || s.OpenTaskCount != 1 ||
			s.OverdueTaskCount != 1 || s.CompletedTaskCount != 1 {
			t.Errorf("özet yanlış: %+v", s)
		}
		if fmt.Sprintf("%.0f", s.TaskCompletionRatio) != "50" {
			t.Errorf("tamamlanma oranı yanlış: %v", s.TaskCompletionRatio)
		}
	})

	t.Run("15_locked_project_blocks_new_operations", func(t *testing.T) {
		p := newProject(t, orgA.ID)
		emp := newEmployee(t, orgA.ID, "Kilitli")
		if _, err := projectSvc.Update(ctx, p.ID, orgA.ID, service.UpdateProjectInput{
			Name: p.Name, Status: domain.ProjectStatusCancelled,
		}); err != nil {
			t.Fatalf("iptal: %v", err)
		}
		if _, err := projectSvc.CreateTask(ctx, p.ID, orgA.ID, service.TaskInput{Title: "X"}); !errors.Is(err, service.ErrProjectLocked) {
			t.Errorf("iptal edilmiş projeye görev eklenebildi: err=%v", err)
		}
		if _, err := projectSvc.AssignMember(ctx, p.ID, orgA.ID, service.ProjectMemberInput{EmployeeID: emp.ID}); !errors.Is(err, service.ErrProjectLocked) {
			t.Errorf("iptal edilmiş projeye personel atanabildi: err=%v", err)
		}
		if _, err := projectSvc.UploadFile(ctx, p.ID, orgA.ID, service.UploadInput{
			OriginalName: "x.pdf", Reader: strings.NewReader("%PDF-1.4\nx\n"),
		}); !errors.Is(err, service.ErrProjectLocked) {
			t.Errorf("iptal edilmiş projeye dosya yüklenebildi: err=%v", err)
		}
	})

	t.Run("16_operation_events_share_one_timeline", func(t *testing.T) {
		p := newProject(t, orgA.ID)
		emp := newEmployee(t, orgA.ID, "Olay Personeli")
		if _, err := projectSvc.AssignMember(ctx, p.ID, orgA.ID, service.ProjectMemberInput{EmployeeID: emp.ID}); err != nil {
			t.Fatalf("atama: %v", err)
		}
		item, _ := projectSvc.CreateScheduleItem(ctx, p.ID, orgA.ID, service.ScheduleItemInput{Name: "Aşama"})
		task, _ := projectSvc.CreateTask(ctx, p.ID, orgA.ID, service.TaskInput{
			Title: "Görev", ScheduleItemID: &item.ID, AssignedEmployeeID: &emp.ID,
		})
		if _, err := projectSvc.CompleteTask(ctx, p.ID, task.ID, orgA.ID, ""); err != nil {
			t.Fatalf("tamamlama: %v", err)
		}
		if _, err := projectSvc.UploadFile(ctx, p.ID, orgA.ID, service.UploadInput{
			OriginalName: "belge.pdf", Reader: strings.NewReader("%PDF-1.4\nbelge\n"),
		}); err != nil {
			t.Fatalf("dosya: %v", err)
		}
		png := append([]byte{0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A}, make([]byte, 32)...)
		if _, err := projectSvc.UploadPhoto(ctx, p.ID, orgA.ID, service.UploadInput{
			OriginalName: "foto.png", Reader: strings.NewReader(string(png)),
		}); err != nil {
			t.Fatalf("foto: %v", err)
		}
		if _, err := projectSvc.CreateNote(ctx, p.ID, orgA.ID, "Not", ""); err != nil {
			t.Fatalf("not: %v", err)
		}
		// Finans olayı da aynı zaman çizelgesinde olmalı.
		if _, err := projectSvc.CreateExpense(ctx, p.ID, orgA.ID, service.ExpenseInput{
			Category: domain.ExpenseMaterial, Description: "Malzeme", Amount: 100,
			Currency: "TRY", ExpenseDate: today,
		}); err != nil {
			t.Fatalf("masraf: %v", err)
		}

		events, err := projectSvc.ListProjectEvents(ctx, p.ID, orgA.ID)
		if err != nil {
			t.Fatalf("olaylar: %v", err)
		}
		seen := map[string]bool{}
		for _, e := range events {
			seen[e.EventType] = true
		}
		for _, want := range []string{
			domain.ProjectEventCreated,
			domain.ProjectEventMemberAssigned,
			domain.ProjectEventScheduleCreated,
			domain.ProjectEventTaskCreated,
			domain.ProjectEventTaskAssigned,
			domain.ProjectEventTaskCompleted,
			domain.ProjectEventFileUploaded,
			domain.ProjectEventPhotoUploaded,
			domain.ProjectEventNoteAdded,
			domain.ProjectEventExpenseAdded, // Faz 6 olayı, aynı çizelgede
		} {
			if !seen[want] {
				t.Errorf("%s olayı yok (üretilenler: %v)", want, seen)
			}
		}
		// Kronolojik sıra korunmalı.
		for i := 1; i < len(events); i++ {
			if events[i].CreatedAt.Before(events[i-1].CreatedAt) {
				t.Errorf("olaylar kronolojik sırada değil (%d)", i)
				break
			}
		}
	})

	t.Run("17_cross_tenant_operation_reads_are_empty", func(t *testing.T) {
		p := newProject(t, orgA.ID)
		emp := newEmployee(t, orgA.ID, "Gizli")
		if _, err := projectSvc.AssignMember(ctx, p.ID, orgA.ID, service.ProjectMemberInput{EmployeeID: emp.ID}); err != nil {
			t.Fatalf("atama: %v", err)
		}
		if _, err := projectSvc.CreateScheduleItem(ctx, p.ID, orgA.ID, service.ScheduleItemInput{Name: "Gizli aşama"}); err != nil {
			t.Fatalf("aşama: %v", err)
		}
		if _, err := projectSvc.CreateTask(ctx, p.ID, orgA.ID, service.TaskInput{Title: "Gizli görev"}); err != nil {
			t.Fatalf("görev: %v", err)
		}

		if rows, _ := projectSvc.ListMembers(ctx, p.ID, orgB.ID); len(rows) != 0 {
			t.Errorf("üyeler sızdı")
		}
		if rows, _ := projectSvc.ListScheduleItems(ctx, p.ID, orgB.ID); len(rows) != 0 {
			t.Errorf("aşamalar sızdı")
		}
		if rows, _ := projectSvc.ListTasks(ctx, p.ID, orgB.ID); len(rows) != 0 {
			t.Errorf("görevler sızdı")
		}
		if rows, _ := projectSvc.ListPhotos(ctx, p.ID, orgB.ID); len(rows) != 0 {
			t.Errorf("fotoğraflar sızdı")
		}
		if _, err := projectSvc.OperationsSummary(ctx, p.ID, orgB.ID); err != nil {
			t.Fatalf("özet hata verdi: %v", err)
		}
		sB, _ := projectSvc.OperationsSummary(ctx, p.ID, orgB.ID)
		if sB.ActiveMemberCount != 0 || sB.TotalTaskCount != 0 {
			t.Errorf("özet başka firmaya veri sızdırdı: %+v", sB)
		}
	})

	// RBAC/Project Membership sprint'inin child-resource IDOR sıkılaştırması
	// (bkz. migration 0034 öncesi denetim): AYNI organizasyon içinde bile,
	// Proje A'nın URL'si üzerinden Proje B'ye ait bir görev/dosya/fotoğraf/
	// ekip üyesi/aşama UUID'si verilse, işlem BAŞARISIZ olmalı (404) --
	// yalnızca organization_id eşleşmesi yeterli DEĞİLDİR, project_id de
	// eşleşmelidir.
	t.Run("18_cross_project_child_resource_idor_blocked", func(t *testing.T) {
		pA := newProject(t, orgA.ID)
		pB := newProject(t, orgA.ID) // AYNI organizasyon, FARKLI proje.
		emp := newEmployee(t, orgA.ID, "IDOR Testi")

		mB, err := projectSvc.AssignMember(ctx, pB.ID, orgA.ID, service.ProjectMemberInput{EmployeeID: emp.ID})
		if err != nil {
			t.Fatalf("B'ye atama: %v", err)
		}
		itemB, err := projectSvc.CreateScheduleItem(ctx, pB.ID, orgA.ID, service.ScheduleItemInput{Name: "B Aşaması"})
		if err != nil {
			t.Fatalf("B aşaması: %v", err)
		}
		taskB, err := projectSvc.CreateTask(ctx, pB.ID, orgA.ID, service.TaskInput{Title: "B Görevi"})
		if err != nil {
			t.Fatalf("B görevi: %v", err)
		}
		fileB, err := projectSvc.UploadFile(ctx, pB.ID, orgA.ID, service.UploadInput{
			OriginalName: "b-dosyasi.pdf", Reader: strings.NewReader("%PDF-1.4\nB\n"),
		})
		if err != nil {
			t.Fatalf("B dosyası: %v", err)
		}
		png := append([]byte{0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A}, make([]byte, 32)...)
		photoB, err := projectSvc.UploadPhoto(ctx, pB.ID, orgA.ID, service.UploadInput{
			OriginalName: "b-foto.png", Reader: strings.NewReader(string(png)),
		})
		if err != nil {
			t.Fatalf("B fotoğrafı: %v", err)
		}

		// Proje A'ya yetkili biri, Proje A URL'si üzerinden Proje B'nin
		// kayıtlarına ASLA ulaşamamalı -- ne okuma ne yazma.
		if _, err := projectSvc.EndMembership(ctx, pA.ID, mB.ID, orgA.ID, "", nil); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("A projesi üzerinden B'nin ekip üyesi sonlandırılabildi: err=%v", err)
		}
		if _, err := projectSvc.UpdateScheduleItem(ctx, pA.ID, itemB.ID, orgA.ID, service.ScheduleItemInput{Name: "X", Status: domain.ScheduleStatusPlanned}); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("A projesi üzerinden B'nin aşaması güncellenebildi: err=%v", err)
		}
		if _, err := projectSvc.UpdateTask(ctx, pA.ID, taskB.ID, orgA.ID, service.TaskInput{Title: "X", Status: domain.TaskStatusTodo, Priority: domain.TaskPriorityNormal}); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("A projesi üzerinden B'nin görevi güncellenebildi: err=%v", err)
		}
		if _, err := projectSvc.CompleteTask(ctx, pA.ID, taskB.ID, orgA.ID, ""); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("A projesi üzerinden B'nin görevi tamamlanabildi: err=%v", err)
		}
		if _, _, err := projectSvc.OpenFile(ctx, pA.ID, fileB.ID, orgA.ID); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("A projesi üzerinden B'nin dosyası indirilebildi: err=%v", err)
		}
		if err := projectSvc.DeleteFile(ctx, pA.ID, fileB.ID, orgA.ID, ""); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("A projesi üzerinden B'nin dosyası silinebildi: err=%v", err)
		}
		if _, _, err := projectSvc.OpenPhoto(ctx, pA.ID, photoB.ID, orgA.ID); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("A projesi üzerinden B'nin fotoğrafı indirilebildi: err=%v", err)
		}
		if err := projectSvc.DeletePhoto(ctx, pA.ID, photoB.ID, orgA.ID, ""); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("A projesi üzerinden B'nin fotoğrafı silinebildi: err=%v", err)
		}

		// Doğru proje id'siyle (pB) AYNI işlemler başarılı olmalı --
		// düzeltmenin aşırı-kısıtlayıcı olmadığını (false positive
		// üretmediğini) doğrular.
		if _, err := projectSvc.UpdateTask(ctx, pB.ID, taskB.ID, orgA.ID, service.TaskInput{Title: "Y", Status: domain.TaskStatusTodo, Priority: domain.TaskPriorityNormal}); err != nil {
			t.Errorf("doğru proje id'siyle görev güncellenemedi: %v", err)
		}
	})
}
