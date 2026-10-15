package service_test

// Günlük şantiye raporu (migration 0071): günde tek rapor, otomatik veriler
// (puantaj önerisi, tamamlanan görevler, fotoğraflar), taşeron kartlarıyla
// ekip, gönderince yöneticilere bildirim, PDF; taşeronun sayfasında sahada
// çalıştığı günler ve listede kalan borç.

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"image"
	"image/color"
	"image/jpeg"
	"testing"
	"time"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

func TestDailyReport(t *testing.T) {
	dbURL := testDBURL(t)
	ctx := context.Background()
	pool, err := repository.NewPool(ctx, dbURL)
	if err != nil {
		t.Fatalf("db: %v", err)
	}
	t.Cleanup(func() { pool.Close() })
	q := sqlc.New(pool)
	box := testSecretBox(t)
	orgSvc := service.NewOrganizationService(q)
	userSvc := service.NewUserService(pool, q)
	notifSvc := service.NewNotificationService(q)
	settingsSvc := service.NewSettingsService(q, box)
	offerSvc := service.NewOfferService(pool, q, settingsSvc, "http://localhost:3000")
	projectSvc := service.NewProjectService(pool, q, mustTestStore(t), settingsSvc, "http://localhost:3000")
	supplierSvc := service.NewSupplierService(pool, q, box)
	employeeSvc := service.NewEmployeeService(pool, q)
	attendanceSvc := service.NewAttendanceService(q)

	org := mustCreateOrg(t, ctx, orgSvc, pool, "Günlük Rapor Org", "gunluk-rapor-test")
	other := mustCreateOrg(t, ctx, orgSvc, pool, "Başka Firma", "gunluk-rapor-diger")
	orgUUID, _ := repository.StringToUUID(org.ID)
	if err := q.SeedSystemRolesForOrg(ctx, orgUUID); err != nil {
		t.Fatalf("rol seed: %v", err)
	}
	suffix := fmt.Sprintf("%d", time.Now().UnixNano()%1_000_000_000)
	owner, err := userSvc.Create(ctx, org.ID, "gr_owner_"+suffix, "GeciciSifre123!", "Firma Sahibi", domain.RoleAdmin, domain.OrgRoleOwner)
	if err != nil {
		t.Fatal(err)
	}
	field, err := userSvc.Create(ctx, org.ID, "gr_field_"+suffix, "GeciciSifre123!", "Saha Şefi", domain.RoleKullanici, domain.OrgRoleField)
	if err != nil {
		t.Fatal(err)
	}
	today := service.IstanbulToday()

	newProject := func(t *testing.T, name string) *domain.Project {
		t.Helper()
		o, err := offerSvc.Create(ctx, service.CreateOfferInput{
			OrganizationID: org.ID, CustomerName: "Müşteri", VatRate: ptrFloat(0),
			Items: []service.OfferItemInput{{ProductName: "İş", Quantity: 1, UnitPrice: 100000}},
		})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := offerSvc.UpdateStatus(ctx, o.ID, org.ID, domain.OfferStatusGonderildi, ""); err != nil {
			t.Fatal(err)
		}
		link, err := offerSvc.CreateShareLink(ctx, o.ID, org.ID, "", nil)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := offerSvc.RespondByShareLinkToken(ctx, link.Token, domain.OfferStatusKabulEdildi, "", ""); err != nil {
			t.Fatal(err)
		}
		p, err := projectSvc.CreateFromOffer(ctx, o.ID, org.ID, service.CreateProjectInput{Name: name})
		if err != nil {
			t.Fatal(err)
		}
		return p
	}
	notifCount := func(t *testing.T, userID string) int {
		t.Helper()
		res, err := notifSvc.List(ctx, userID, org.ID, 1, 100)
		if err != nil {
			t.Fatal(err)
		}
		n := 0
		for _, x := range res.Notifications {
			if x.Type == domain.NotificationDailyReportSubmitted {
				n++
			}
		}
		return n
	}

	p := newProject(t, "Kadıköy Konut")
	hasan, err := supplierSvc.CreateSubcontractorCard(ctx, org.ID, service.SupplierInput{LegalName: "Elektrikçi Hasan", Specialty: "Elektrik"})
	if err != nil {
		t.Fatal(err)
	}
	ali, err := supplierSvc.CreateSubcontractorCard(ctx, org.ID, service.SupplierInput{LegalName: "Boyacı Ali"})
	if err != nil {
		t.Fatal(err)
	}

	t.Run("yazılmamış gün otomatik verilerle döner", func(t *testing.T) {
		came, err := employeeSvc.Create(ctx, org.ID, service.EmployeeInput{FullName: "Gelen Usta", IsActive: true})
		if err != nil {
			t.Fatal(err)
		}
		absent, err := employeeSvc.Create(ctx, org.ID, service.EmployeeInput{FullName: "Gelmeyen Usta", IsActive: true})
		if err != nil {
			t.Fatal(err)
		}
		start := today.AddDate(0, 0, -3)
		for _, e := range []*domain.Employee{came, absent} {
			if _, err := projectSvc.AssignMember(ctx, p.ID, org.ID, service.ProjectMemberInput{EmployeeID: e.ID, StartDate: &start, UserID: owner.ID}); err != nil {
				t.Fatal(err)
			}
		}
		if _, err := attendanceSvc.Create(ctx, org.ID, service.AttendanceInput{EmployeeID: came.ID, Date: today, Status: domain.AttendanceGeldi}); err != nil {
			t.Fatal(err)
		}
		if _, err := attendanceSvc.Create(ctx, org.ID, service.AttendanceInput{EmployeeID: absent.ID, Date: today, Status: domain.AttendanceGelmedi}); err != nil {
			t.Fatal(err)
		}
		task, err := projectSvc.CreateTask(ctx, p.ID, org.ID, service.TaskInput{Title: "Kalıp söküldü", UserID: owner.ID})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := projectSvc.CompleteTask(ctx, p.ID, task.ID, org.ID, owner.ID); err != nil {
			t.Fatal(err)
		}

		rep, err := projectSvc.GetDailyReport(ctx, p.ID, org.ID, today)
		if err != nil {
			t.Fatal(err)
		}
		if rep.Exists || rep.Status != service.DailyReportDraft {
			t.Fatalf("yazılmamış gün: exists=%v status=%s", rep.Exists, rep.Status)
		}
		if len(rep.SubcontractorOptions) != 0 {
			t.Errorf("projeye bağlı taşeron yokken seçenek olmamalı: %+v", rep.SubcontractorOptions)
		}
		if rep.SuggestedOwnWorkers != 1 {
			t.Errorf("öneri yalnızca gelen personeli saymalı: %d", rep.SuggestedOwnWorkers)
		}
		if len(rep.CompletedTasks) != 1 || rep.CompletedTasks[0].Title != "Kalıp söküldü" {
			t.Errorf("bugün tamamlanan görev gelmeli: %+v", rep.CompletedTasks)
		}
		yesterday, err := projectSvc.GetDailyReport(ctx, p.ID, org.ID, today.AddDate(0, 0, -1))
		if err != nil {
			t.Fatal(err)
		}
		if yesterday.SuggestedOwnWorkers != 0 || len(yesterday.CompletedTasks) != 0 {
			t.Errorf("dünün verisi boş olmalı: %+v", yesterday)
		}
	})

	t.Run("kaydetme, taşeronlar ve liste", func(t *testing.T) {
		temp := 18
		rep, err := projectSvc.SaveDailyReport(ctx, p.ID, org.ID, today, service.DailyReportInput{
			Weather: "sunny", TemperatureC: &temp, OwnWorkers: 4, WorkDone: "  3. kat kolon betonu döküldü  ",
			Issues: "Pompa 1 saat gecikti", Materials: "12 m³ beton", UserID: field.ID,
			Subcontractors: []service.DailyReportSubcontractor{
				{SupplierID: hasan.ID, Workers: 3, WorkNote: "kablo çekimi"},
				{SupplierID: ali.ID, Workers: 2},
			},
		})
		if err != nil {
			t.Fatal(err)
		}
		if len(rep.SubcontractorOptions) != 2 {
			t.Errorf("raporda geçen kartlar seçeneklere girmeli: %+v", rep.SubcontractorOptions)
		}
		if !rep.Exists || rep.Status != service.DailyReportDraft || rep.WorkDone != "3. kat kolon betonu döküldü" {
			t.Fatalf("kayıt: %+v", rep)
		}
		if rep.TemperatureC == nil || *rep.TemperatureC != 18 || rep.CreatedByName != "Saha Şefi" {
			t.Errorf("sıcaklık/yazan: %v %q", rep.TemperatureC, rep.CreatedByName)
		}
		if len(rep.Subcontractors) != 2 || rep.Subcontractors[1].Name != "Elektrikçi Hasan" || rep.Subcontractors[1].Specialty != "Elektrik" {
			t.Fatalf("taşeronlar ada göre sıralı gelmeli: %+v", rep.Subcontractors)
		}

		// Yeniden kaydetme taşeron listesini bütünüyle değiştirir.
		rep, err = projectSvc.SaveDailyReport(ctx, p.ID, org.ID, today, service.DailyReportInput{
			Weather: "cloudy", OwnWorkers: 5, WorkDone: "Kolon betonu", UserID: field.ID,
			Subcontractors: []service.DailyReportSubcontractor{{SupplierID: hasan.ID, Workers: 4}},
		})
		if err != nil {
			t.Fatal(err)
		}
		if rep.Weather != "cloudy" || rep.TemperatureC != nil || len(rep.Subcontractors) != 1 || rep.Subcontractors[0].Workers != 4 {
			t.Fatalf("güncelleme: %+v", rep)
		}

		list, err := projectSvc.ListDailyReports(ctx, p.ID, org.ID)
		if err != nil {
			t.Fatal(err)
		}
		if len(list) != 1 || list[0].OwnWorkers != 5 || list[0].SubcontractorWorkers != 4 {
			t.Fatalf("liste: %+v", list)
		}
	})

	t.Run("geçersiz girdiler reddedilir", func(t *testing.T) {
		bad := []struct {
			name string
			date time.Time
			in   service.DailyReportInput
			want error
		}{
			{"ileri tarih", today.AddDate(0, 0, 1), service.DailyReportInput{}, service.ErrDailyReportFutureDate},
			{"hava", today, service.DailyReportInput{Weather: "fırtına"}, service.ErrDailyReportInvalid},
			{"sıcaklık", today, service.DailyReportInput{TemperatureC: ptrInt(75)}, service.ErrDailyReportInvalid},
			{"eksi kişi", today, service.DailyReportInput{OwnWorkers: -1}, service.ErrDailyReportInvalid},
			{"aynı taşeron iki kez", today, service.DailyReportInput{Subcontractors: []service.DailyReportSubcontractor{
				{SupplierID: ali.ID, Workers: 1}, {SupplierID: ali.ID, Workers: 2}}}, service.ErrDailyReportInvalid},
			{"bilinmeyen taşeron", today, service.DailyReportInput{Subcontractors: []service.DailyReportSubcontractor{
				{SupplierID: "00000000-0000-0000-0000-000000000000", Workers: 1}}}, service.ErrSubcontractorCardNotFound},
		}
		for _, c := range bad {
			c.in.UserID = field.ID
			if _, err := projectSvc.SaveDailyReport(ctx, p.ID, org.ID, c.date, c.in); !errors.Is(err, c.want) {
				t.Errorf("%s: %v beklendi, %v geldi", c.name, c.want, err)
			}
		}
		// Reddedilen kayıt mevcut raporu bozmamalı.
		rep, err := projectSvc.GetDailyReport(ctx, p.ID, org.ID, today)
		if err != nil {
			t.Fatal(err)
		}
		if len(rep.Subcontractors) != 1 || rep.OwnWorkers != 5 {
			t.Errorf("rapor değişmemeli: %+v", rep)
		}
	})

	t.Run("başka firmanın taşeron kartı ve projesi kullanılamaz", func(t *testing.T) {
		foreign, err := supplierSvc.CreateSubcontractorCard(ctx, other.ID, service.SupplierInput{LegalName: "Yabancı Usta"})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := projectSvc.SaveDailyReport(ctx, p.ID, org.ID, today, service.DailyReportInput{
			UserID: field.ID, Subcontractors: []service.DailyReportSubcontractor{{SupplierID: foreign.ID, Workers: 1}},
		}); !errors.Is(err, service.ErrSubcontractorCardNotFound) {
			t.Errorf("başka firmanın kartı: %v", err)
		}
		if _, err := projectSvc.GetDailyReport(ctx, p.ID, other.ID, today); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("başka firma okuyamamalı: %v", err)
		}
		if _, err := projectSvc.SaveDailyReport(ctx, p.ID, other.ID, today, service.DailyReportInput{}); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("başka firma yazamamalı: %v", err)
		}
		if _, err := projectSvc.DailyReportPDF(ctx, p.ID, other.ID, today); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("başka firma PDF alamamalı: %v", err)
		}
	})

	t.Run("gönderme yöneticilere bildirir, iki kez gönderilemez", func(t *testing.T) {
		if _, err := projectSvc.SubmitDailyReport(ctx, p.ID, org.ID, field.ID, today.AddDate(0, 0, -2)); !errors.Is(err, service.ErrDailyReportNotFound) {
			t.Errorf("yazılmamış gün gönderilemez: %v", err)
		}
		ownerBefore, fieldBefore := notifCount(t, owner.ID), notifCount(t, field.ID)
		rep, err := projectSvc.SubmitDailyReport(ctx, p.ID, org.ID, field.ID, today)
		if err != nil {
			t.Fatal(err)
		}
		if rep.Status != service.DailyReportSubmitted || rep.SubmittedAt == nil || rep.SubmittedByName != "Saha Şefi" {
			t.Fatalf("gönderildi: %+v", rep)
		}
		if notifCount(t, owner.ID) != ownerBefore+1 {
			t.Error("firma sahibi bildirim almalı")
		}
		if notifCount(t, field.ID) != fieldBefore {
			t.Error("gönderen kendine bildirim almamalı")
		}
		if _, err := projectSvc.SubmitDailyReport(ctx, p.ID, org.ID, field.ID, today); !errors.Is(err, service.ErrDailyReportAlreadySubmitted) {
			t.Errorf("ikinci gönderim: %v", err)
		}
		// Gönderilmiş rapor düzeltilebilir; durumu korunur.
		rep, err = projectSvc.SaveDailyReport(ctx, p.ID, org.ID, today, service.DailyReportInput{
			Weather: "rainy", OwnWorkers: 6, WorkDone: "Düzeltme", UserID: owner.ID,
			Subcontractors: []service.DailyReportSubcontractor{{SupplierID: hasan.ID, Workers: 4, WorkNote: "pano"}},
		})
		if err != nil {
			t.Fatal(err)
		}
		if rep.Status != service.DailyReportSubmitted || rep.OwnWorkers != 6 {
			t.Errorf("düzeltme sonrası: %+v", rep)
		}
	})

	t.Run("PDF fotoğraflarla ya da bozuk fotoğrafa rağmen çıkar", func(t *testing.T) {
		img := image.NewRGBA(image.Rect(0, 0, 40, 30))
		for x := 0; x < 40; x++ {
			for y := 0; y < 30; y++ {
				img.Set(x, y, color.RGBA{R: uint8(x * 6), G: 120, B: uint8(y * 8), A: 255})
			}
		}
		var jpg bytes.Buffer
		if err := jpeg.Encode(&jpg, img, nil); err != nil {
			t.Fatal(err)
		}
		if _, err := projectSvc.UploadPhoto(ctx, p.ID, org.ID, service.UploadInput{
			OriginalName: "kolon.jpg", Reader: bytes.NewReader(jpg.Bytes()), Stage: domain.PhotoStageProgress,
			Description: "3. kat kolonlar", UserID: field.ID,
		}); err != nil {
			t.Fatal(err)
		}
		broken := append([]byte{0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A}, make([]byte, 64)...)
		if _, err := projectSvc.UploadPhoto(ctx, p.ID, org.ID, service.UploadInput{
			OriginalName: "bozuk.png", Reader: bytes.NewReader(broken), Stage: domain.PhotoStageProgress, UserID: field.ID,
		}); err != nil {
			t.Fatal(err)
		}
		rep, err := projectSvc.GetDailyReport(ctx, p.ID, org.ID, today)
		if err != nil {
			t.Fatal(err)
		}
		if len(rep.Photos) != 2 {
			t.Fatalf("bugünün iki fotoğrafı gelmeli: %d", len(rep.Photos))
		}
		list, err := projectSvc.ListDailyReports(ctx, p.ID, org.ID)
		if err != nil {
			t.Fatal(err)
		}
		if list[0].PhotoCount != 2 {
			t.Errorf("liste fotoğraf sayısı: %d", list[0].PhotoCount)
		}
		doc, err := projectSvc.DailyReportPDF(ctx, p.ID, org.ID, today)
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.HasPrefix(doc.Content, []byte("%PDF")) || len(doc.Content) < 2000 {
			t.Fatalf("PDF değil ya da boş: %d bayt", len(doc.Content))
		}
		if want := "Gunluk-Rapor-"; !bytes.HasPrefix([]byte(doc.Filename), []byte(want)) {
			t.Errorf("dosya adı: %s", doc.Filename)
		}
		if _, err := projectSvc.DailyReportPDF(ctx, p.ID, org.ID, today.AddDate(0, 0, -5)); !errors.Is(err, service.ErrDailyReportNotFound) {
			t.Errorf("yazılmamış günün PDF'i: %v", err)
		}
	})

	t.Run("taşeron sayfası sahadaki günleri, liste kalan borcu gösterir", func(t *testing.T) {
		if _, err := projectSvc.CreateSubcontractor(ctx, p.ID, org.ID, service.SubcontractorInput{
			SupplierID: hasan.ID, WorkDescription: "Elektrik tesisatı", ContractAmount: 50000, Currency: "TRY",
		}); err != nil {
			t.Fatal(err)
		}
		ledger, err := supplierSvc.GetSubcontractorLedger(ctx, org.ID, hasan.ID, "")
		if err != nil {
			t.Fatal(err)
		}
		if len(ledger.SiteDays) != 1 || ledger.SiteDays[0].Workers != 4 || ledger.SiteDays[0].WorkNote != "pano" ||
			ledger.SiteDays[0].ProjectID != p.ID {
			t.Fatalf("sahadaki günler: %+v", ledger.SiteDays)
		}
		aliLedger, err := supplierSvc.GetSubcontractorLedger(ctx, org.ID, ali.ID, "")
		if err != nil {
			t.Fatal(err)
		}
		if len(aliLedger.SiteDays) != 0 {
			t.Errorf("rapordan çıkarılan taşeronun günü kalmamalı: %+v", aliLedger.SiteDays)
		}
		// Projeye erişimi olmayan kişi o projenin günlerini görmez.
		restricted, err := supplierSvc.GetSubcontractorLedger(ctx, org.ID, hasan.ID, field.ID)
		if err != nil {
			t.Fatal(err)
		}
		if len(restricted.SiteDays) != 0 {
			t.Errorf("üye olmayan görmemeli: %+v", restricted.SiteDays)
		}

		cards, err := supplierSvc.ListSubcontractorCards(ctx, org.ID, true, "")
		if err != nil {
			t.Fatal(err)
		}
		for _, c := range cards {
			switch c.ID {
			case hasan.ID:
				if len(c.RemainingTotals) != 1 || c.RemainingTotals[0].Amount != 50000 || c.RemainingTotals[0].Currency != "TRY" {
					t.Errorf("Hasan kalan borç: %+v", c.RemainingTotals)
				}
			case ali.ID:
				if len(c.RemainingTotals) != 0 {
					t.Errorf("Ali'nin işi yok, kalan olmamalı: %+v", c.RemainingTotals)
				}
			}
		}
	})

	t.Run("kapalı projeye rapor yazılamaz", func(t *testing.T) {
		closed := newProject(t, "Kapanan Proje")
		if _, err := projectSvc.Update(ctx, closed.ID, org.ID, service.UpdateProjectInput{Name: closed.Name, Status: domain.ProjectStatusCancelled}); err != nil {
			t.Fatal(err)
		}
		if _, err := projectSvc.SaveDailyReport(ctx, closed.ID, org.ID, today, service.DailyReportInput{UserID: owner.ID}); !errors.Is(err, service.ErrProjectLocked) {
			t.Errorf("iptal projede: %v", err)
		}
	})
}

func ptrInt(v int) *int { return &v }
