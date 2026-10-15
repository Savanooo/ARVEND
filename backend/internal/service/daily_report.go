package service

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"image"
	"image/color"
	"image/jpeg"
	_ "image/png" // image.Decode PNG
	"io"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/go-pdf/fpdf"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/platform/pdffont"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

// Günlük şantiye raporu (migration 0071, ürün sahibinin seçimi 2026-10):
// proje başına günde bir rapor. Saha şefi hava, ekip ve taşeron sayıları,
// yapılan işler, sorunlar, gelen malzeme ve notları girer; o gün tamamlanan
// görevler ve çekilen fotoğraflar tarihle okunup rapora eklenir. "Gönder"
// yöneticilere bildirir; rapor PDF olarak paylaşılır. İzinler operasyon
// izinleridir (router'da).

const (
	DailyReportDraft     = "draft"
	DailyReportSubmitted = "submitted"

	dailyReportListLimit         = 120
	dailyReportMaxText           = 4000
	dailyReportMaxSubcontractors = 30
	dailyReportPDFMaxPhotos      = 6
	dailyReportPhotoMaxSide      = 1400
)

var (
	ErrDailyReportNotFound         error = &NotFoundError{What: "günlük rapor"}
	ErrDailyReportAlreadySubmitted       = errors.New("bu günün raporu zaten gönderildi")
	ErrDailyReportFutureDate             = errors.New("ileri bir tarihin raporu yazılamaz")
	ErrDailyReportInvalid                = errors.New("geçersiz rapor bilgisi")
)

var dailyReportWeathers = map[string]string{
	"": "", "sunny": "Güneşli", "cloudy": "Bulutlu", "rainy": "Yağmurlu", "snowy": "Karlı", "windy": "Rüzgârlı",
}

type DailyReportSubcontractor struct {
	SupplierID string
	Name       string
	Specialty  string
	Workers    int
	WorkNote   string
}

type DailyReportTask struct {
	ID, Title, AssignedName string
}

type DailyReportPhoto struct {
	ID, Stage, Description string
	objectKey, mimeType    string
}

// DailyReport: raporun kendisi (Exists false ise henüz yazılmamış gün) ve o
// günün otomatik verileri.
type DailyReport struct {
	Exists          bool
	ID              string
	ProjectID       string
	ReportDate      time.Time
	Weather         string
	TemperatureC    *int
	OwnWorkers      int
	WorkDone        string
	Issues          string
	Materials       string
	Notes           string
	Status          string
	SubmittedAt     *time.Time
	SubmittedByName string
	CreatedByName   string
	UpdatedAt       *time.Time
	Subcontractors  []DailyReportSubcontractor

	// Otomatik: ekipten o gün puantajı girilenler (öneri), tamamlanan
	// görevler, o gün çekilen fotoğraflar.
	SuggestedOwnWorkers int
	CompletedTasks      []DailyReportTask
	Photos              []DailyReportPhoto
	// SubcontractorOptions: formun taşeron seçicisi -- projeye bağlı ya da
	// projenin önceki raporlarında geçen aktif kartlar (Workers boş).
	SubcontractorOptions []DailyReportSubcontractor
}

type DailyReportListItem struct {
	ID                   string
	ReportDate           time.Time
	Weather              string
	TemperatureC         *int
	OwnWorkers           int
	SubcontractorWorkers int
	Status               string
	WorkDone             string
	CreatedByName        string
	PhotoCount           int
}

type DailyReportInput struct {
	Weather        string
	TemperatureC   *int
	OwnWorkers     int
	WorkDone       string
	Issues         string
	Materials      string
	Notes          string
	Subcontractors []DailyReportSubcontractor
	UserID         string
}

func (s *ProjectService) ListDailyReports(ctx context.Context, projectID, organizationID string) ([]DailyReportListItem, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	if err := s.requireProjectInOrg(ctx, pid, orgID); err != nil {
		return nil, err
	}
	rows, err := s.q.ListDailyReports(ctx, sqlc.ListDailyReportsParams{ProjectID: pid, OrganizationID: orgID, RowLimit: dailyReportListLimit})
	if err != nil {
		return nil, err
	}
	out := make([]DailyReportListItem, len(rows))
	for i, r := range rows {
		out[i] = DailyReportListItem{
			ID: r.ID.String(), ReportDate: r.ReportDate.Time, Weather: r.Weather, TemperatureC: intPtr16(r.TemperatureC),
			OwnWorkers: int(r.OwnWorkers), SubcontractorWorkers: int(r.SubcontractorWorkers), Status: r.Status,
			WorkDone: r.WorkDone, CreatedByName: r.CreatedByName, PhotoCount: int(r.PhotoCount),
		}
	}
	return out, nil
}

// GetDailyReport: günün raporu ve otomatik verileri. Rapor yazılmamışsa
// Exists false ve yalnızca otomatik veriler dolu döner (form önerisi).
func (s *ProjectService) GetDailyReport(ctx context.Context, projectID, organizationID string, date time.Time) (*DailyReport, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	if err := s.requireProjectInOrg(ctx, pid, orgID); err != nil {
		return nil, err
	}
	return loadDailyReport(ctx, s.q, pid, orgID, date)
}

// requireProjectInOrg: proje bu firmanın değilse domain.ErrNotFound (başka
// firmanın proje kimliğiyle boş liste yerine 404).
func (s *ProjectService) requireProjectInOrg(ctx context.Context, pid, orgID pgtype.UUID) error {
	if _, err := s.q.GetProjectByID(ctx, sqlc.GetProjectByIDParams{ID: pid, OrganizationID: orgID}); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return domain.ErrNotFound
		}
		return err
	}
	return nil
}

func loadDailyReport(ctx context.Context, q *sqlc.Queries, pid, orgID pgtype.UUID, date time.Time) (*DailyReport, error) {
	d := repository.TimeToDate(date)
	out := &DailyReport{ProjectID: pid.String(), ReportDate: d.Time, Status: DailyReportDraft}
	row, err := q.GetDailyReport(ctx, sqlc.GetDailyReportParams{ProjectID: pid, OrganizationID: orgID, ReportDate: d})
	switch {
	case err == nil:
		out.Exists = true
		out.ID = row.ID.String()
		out.Weather, out.TemperatureC, out.OwnWorkers = row.Weather, intPtr16(row.TemperatureC), int(row.OwnWorkers)
		out.WorkDone, out.Issues, out.Materials, out.Notes = row.WorkDone, row.Issues, row.Materials, row.Notes
		out.Status, out.CreatedByName, out.SubmittedByName = row.Status, row.CreatedByName, row.SubmittedByName
		if row.SubmittedAt.Valid {
			t := row.SubmittedAt.Time
			out.SubmittedAt = &t
		}
		if row.UpdatedAt.Valid {
			t := row.UpdatedAt.Time
			out.UpdatedAt = &t
		}
		subs, err := q.ListDailyReportSubcontractors(ctx, row.ID)
		if err != nil {
			return nil, err
		}
		for _, sr := range subs {
			out.Subcontractors = append(out.Subcontractors, DailyReportSubcontractor{
				SupplierID: sr.SupplierID.String(), Name: sr.LegalName, Specialty: sr.Specialty,
				Workers: int(sr.Workers), WorkNote: sr.WorkNote,
			})
		}
	case !errors.Is(err, pgx.ErrNoRows):
		return nil, err
	}
	suggested, err := q.DailyReportOwnWorkersSuggestion(ctx, sqlc.DailyReportOwnWorkersSuggestionParams{
		ReportDate: d, ProjectID: pid, OrganizationID: orgID,
	})
	if err != nil {
		return nil, err
	}
	out.SuggestedOwnWorkers = int(suggested)
	tasks, err := q.ListTasksCompletedOn(ctx, sqlc.ListTasksCompletedOnParams{ProjectID: pid, OrganizationID: orgID, ReportDate: d})
	if err != nil {
		return nil, err
	}
	for _, t := range tasks {
		out.CompletedTasks = append(out.CompletedTasks, DailyReportTask{ID: t.ID.String(), Title: t.Title, AssignedName: t.AssignedName})
	}
	options, err := q.ListDailyReportSubcontractorOptions(ctx, sqlc.ListDailyReportSubcontractorOptionsParams{
		OrganizationID: orgID, ProjectID: pid,
	})
	if err != nil {
		return nil, err
	}
	for _, o := range options {
		out.SubcontractorOptions = append(out.SubcontractorOptions, DailyReportSubcontractor{
			SupplierID: o.ID.String(), Name: o.LegalName, Specialty: o.Specialty,
		})
	}
	photos, err := q.ListPhotosTakenOn(ctx, sqlc.ListPhotosTakenOnParams{ProjectID: pid, OrganizationID: orgID, ReportDate: d})
	if err != nil {
		return nil, err
	}
	for _, p := range photos {
		out.Photos = append(out.Photos, DailyReportPhoto{
			ID: p.ID.String(), Stage: p.Stage, Description: p.Description, objectKey: p.ObjectKey, mimeType: p.MimeType,
		})
	}
	return out, nil
}

// SaveDailyReport: günün raporunu yazar ya da günceller (gönderilmiş rapor
// da düzeltilebilir; durumu "gönderildi" kalır). Taşeron satırları bütünüyle
// yeniden yazılır; her taşeron firmanın Taşeronlar kartı olmalı.
func (s *ProjectService) SaveDailyReport(ctx context.Context, projectID, organizationID string, date time.Time, in DailyReportInput) (*DailyReport, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	if err := validateDailyReport(date, &in); err != nil {
		return nil, err
	}
	actor := actorUUID(in.UserID)
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	if _, err := s.requireOpenProjectForOps(ctx, txq, pid, orgID); err != nil {
		return nil, err
	}
	var temp *int16
	if in.TemperatureC != nil {
		v := int16(*in.TemperatureC)
		temp = &v
	}
	row, err := txq.UpsertDailyReport(ctx, sqlc.UpsertDailyReportParams{
		OrganizationID: orgID, ProjectID: pid, ReportDate: repository.TimeToDate(date), Weather: in.Weather,
		TemperatureC: temp, OwnWorkers: int32(in.OwnWorkers), WorkDone: in.WorkDone, Issues: in.Issues,
		Materials: in.Materials, Notes: in.Notes, Actor: actor,
	})
	if err != nil {
		return nil, err
	}
	if err := txq.DeleteDailyReportSubcontractors(ctx, row.ID); err != nil {
		return nil, err
	}
	for _, sub := range in.Subcontractors {
		sid, err := repository.StringToUUID(sub.SupplierID)
		if err != nil {
			return nil, ErrSubcontractorCardNotFound
		}
		if _, err := txq.GetSubcontractorCard(ctx, sqlc.GetSubcontractorCardParams{ID: sid, OrganizationID: orgID}); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return nil, ErrSubcontractorCardNotFound
			}
			return nil, err
		}
		if err := txq.AddDailyReportSubcontractor(ctx, sqlc.AddDailyReportSubcontractorParams{
			ReportID: row.ID, OrganizationID: orgID, SupplierID: sid, Workers: int32(sub.Workers), WorkNote: sub.WorkNote,
		}); err != nil {
			if isUniqueViolation(err) {
				return nil, fmt.Errorf("%w: aynı taşeron iki kez eklenmiş", ErrDailyReportInvalid)
			}
			return nil, err
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	return loadDailyReport(ctx, s.q, pid, orgID, date)
}

// SubmitDailyReport: taslak raporu "gönderildi" yapar ve projenin
// yöneticilerine bildirir.
func (s *ProjectService) SubmitDailyReport(ctx context.Context, projectID, organizationID, userID string, date time.Time) (*DailyReport, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	actor := actorUUID(userID)
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	project, err := s.requireOpenProjectForOps(ctx, txq, pid, orgID)
	if err != nil {
		return nil, err
	}
	d := repository.TimeToDate(date)
	if _, err := txq.SubmitDailyReport(ctx, sqlc.SubmitDailyReportParams{
		Actor: actor, ProjectID: pid, OrganizationID: orgID, ReportDate: d,
	}); err != nil {
		if !errors.Is(err, pgx.ErrNoRows) {
			return nil, err
		}
		if _, gerr := txq.GetDailyReport(ctx, sqlc.GetDailyReportParams{ProjectID: pid, OrganizationID: orgID, ReportDate: d}); gerr == nil {
			return nil, ErrDailyReportAlreadySubmitted
		}
		return nil, ErrDailyReportNotFound
	}
	dateText := date.Format("02.01.2006")
	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventDailyReportSubmitted, actor,
		map[string]any{"report_date": date.Format("2006-01-02")}); err != nil {
		return nil, err
	}
	if err := notifyDailyReportSubmitted(ctx, txq, project, actor, dateText, "/projeler/"+pid.String()+"/gunluk-rapor/"+date.Format("2006-01-02")); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	return loadDailyReport(ctx, s.q, pid, orgID, date)
}

func validateDailyReport(date time.Time, in *DailyReportInput) error {
	if date.After(istanbulDay(time.Now())) {
		return ErrDailyReportFutureDate
	}
	if _, ok := dailyReportWeathers[in.Weather]; !ok {
		return fmt.Errorf("%w: hava durumu", ErrDailyReportInvalid)
	}
	if in.TemperatureC != nil && (*in.TemperatureC < -50 || *in.TemperatureC > 60) {
		return fmt.Errorf("%w: sıcaklık -50 ile 60 arasında olmalı", ErrDailyReportInvalid)
	}
	if in.OwnWorkers < 0 || in.OwnWorkers > 10000 {
		return fmt.Errorf("%w: kişi sayısı", ErrDailyReportInvalid)
	}
	if len(in.Subcontractors) > dailyReportMaxSubcontractors {
		return fmt.Errorf("%w: en fazla %d taşeron", ErrDailyReportInvalid, dailyReportMaxSubcontractors)
	}
	for _, p := range []*string{&in.WorkDone, &in.Issues, &in.Materials, &in.Notes} {
		*p = strings.TrimSpace(*p)
		if utf8.RuneCountInString(*p) > dailyReportMaxText {
			return fmt.Errorf("%w: metin en fazla %d karakter", ErrDailyReportInvalid, dailyReportMaxText)
		}
	}
	for i := range in.Subcontractors {
		sub := &in.Subcontractors[i]
		if sub.Workers < 0 || sub.Workers > 10000 {
			return fmt.Errorf("%w: taşeron kişi sayısı", ErrDailyReportInvalid)
		}
		sub.WorkNote = truncateRunes(strings.TrimSpace(sub.WorkNote), 300)
	}
	return nil
}

func intPtr16(v *int16) *int {
	if v == nil {
		return nil
	}
	i := int(*v)
	return &i
}

// notifyDailyReportSubmitted: projenin yöneticileri (resolveProjectAudience:
// firmanın Sahip/Yöneticileri ve Erişim listesindeki projects.update
// sahipleri), gönderen hariç.
func notifyDailyReportSubmitted(ctx context.Context, txq *sqlc.Queries, p sqlc.Project, actor pgtype.UUID, dateText, target string) error {
	managers, err := resolveProjectAudience(ctx, txq, p.OrganizationID, p.ID, domain.PermProjectsUpdate)
	if err != nil {
		return err
	}
	r := newRecipientList(actor)
	for _, id := range managers {
		r.add(id)
	}
	if len(r.ids) == 0 {
		return nil
	}
	who := ""
	if u, err := txq.GetUserByID(ctx, actor); err == nil {
		who = u.FullName
	}
	return createNotificationsForUsers(ctx, txq, r.ids, CreateNotificationInput{
		OrganizationID: p.OrganizationID, Type: domain.NotificationDailyReportSubmitted,
		Title: "Günlük rapor gönderildi", Body: truncateRunes(joinNonEmpty(" · ", projectNoticeLabel(p), dateText, who), 500),
		EntityType: domain.NotificationEntityProject, EntityID: p.ID, ProjectID: p.ID, ActionTarget: target,
	})
}

// ---------- PDF ----------

// DailyReportPDF: paylaşılacak rapor.
type DailyReportPDF struct {
	Filename string
	Content  []byte
}

// DailyReportPDF: raporu PDF'e döker -- firma, proje, tarih, hava, ekip ve
// taşeronlar, metinler, tamamlanan görevler ve o günün fotoğraflarından en
// fazla altısı (JPEG/PNG). Yazılmamış gün ErrDailyReportNotFound.
func (s *ProjectService) DailyReportPDF(ctx context.Context, projectID, organizationID string, date time.Time) (*DailyReportPDF, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	project, err := s.q.GetProjectByID(ctx, sqlc.GetProjectByIDParams{ID: pid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	rep, err := loadDailyReport(ctx, s.q, pid, orgID, date)
	if err != nil {
		return nil, err
	}
	if !rep.Exists {
		return nil, ErrDailyReportNotFound
	}
	company := ""
	if org, err := s.q.GetOrganizationByID(ctx, orgID); err == nil {
		company = org.Name
	}
	if p, err := s.q.GetOrganizationProfile(ctx, orgID); err == nil && strings.TrimSpace(p.LegalName) != "" {
		company = strings.TrimSpace(p.LegalName)
	}

	const left, width = 15.0, 180.0
	pdf := fpdf.New("P", "mm", "A4", "")
	pdf.AddUTF8FontFromBytes(pdffont.Family, "", pdffont.Regular)
	pdf.AddUTF8FontFromBytes(pdffont.Family, "B", pdffont.Bold)
	pdf.SetMargins(left, 15, 15)
	pdf.SetAutoPageBreak(true, 18)
	pdf.AliasNbPages("{nb}")
	dateText := date.Format("02.01.2006")
	pdf.SetTitle(fmt.Sprintf("Günlük Rapor %s %s", project.ProjectNo, dateText), true)
	font := func(size float64, bold bool) {
		style := ""
		if bold {
			style = "B"
		}
		pdf.SetFont(pdffont.Family, style, size)
	}
	ink := func() { pdf.SetTextColor(25, 25, 25) }
	muted := func() { pdf.SetTextColor(110, 110, 110) }
	pdf.SetFooterFunc(func() {
		pdf.SetY(-12)
		font(7.5, false)
		muted()
		pdf.CellFormat(0, 5, fmt.Sprintf("%s · Günlük Rapor %s · sayfa %d/{nb}", company, dateText, pdf.PageNo()), "", 0, "C", false, 0, "")
	})
	pdf.AddPage()

	font(14, true)
	ink()
	pdf.MultiCell(width, 6.5, nonEmpty(company, "ARVEND"), "", "L", false)
	font(15, true)
	pdf.CellFormat(width, 8, "GÜNLÜK ŞANTİYE RAPORU", "", 1, "L", false, 0, "")
	font(9.5, false)
	muted()
	pdf.MultiCell(width, 5, joinNonEmpty(" · ", project.ProjectNo, project.Name, project.CustomerName), "", "L", false)
	pdf.MultiCell(width, 5, "Tarih: "+dateText+dailyReportStatusLine(rep), "", "L", false)
	pdf.SetDrawColor(200, 160, 60)
	pdf.SetLineWidth(0.6)
	y := pdf.GetY() + 2
	pdf.Line(left, y, left+width, y)
	pdf.SetY(y + 4)

	section := func(title string) {
		pdf.Ln(2)
		font(8.5, true)
		muted()
		pdf.CellFormat(width, 5, strings.ToUpperSpecial(unicode.TurkishCase, title), "", 1, "L", false, 0, "")
		ink()
		font(10, false)
	}
	weather := dailyReportWeathers[rep.Weather]
	if rep.TemperatureC != nil {
		weather = joinNonEmpty(" · ", weather, fmt.Sprintf("%d °C", *rep.TemperatureC))
	}
	section("Hava")
	pdf.MultiCell(width, 5.5, nonEmpty(weather, "—"), "", "L", false)

	section("Sahadaki ekip")
	subTotal := 0
	for _, sub := range rep.Subcontractors {
		subTotal += sub.Workers
	}
	pdf.MultiCell(width, 5.5, fmt.Sprintf("Kendi ekibimiz: %d kişi · Taşeronlar: %d kişi · Toplam: %d kişi",
		rep.OwnWorkers, subTotal, rep.OwnWorkers+subTotal), "", "L", false)
	for _, sub := range rep.Subcontractors {
		line := fmt.Sprintf("• %s: %d kişi", sub.Name, sub.Workers)
		if sub.WorkNote != "" {
			line += " -- " + sub.WorkNote
		}
		pdf.MultiCell(width, 5.2, line, "", "L", false)
	}
	for _, block := range []struct{ title, text string }{
		{"Yapılan işler", rep.WorkDone}, {"Sorunlar / gecikmeler", rep.Issues},
		{"Gelen malzeme", rep.Materials}, {"Notlar", rep.Notes},
	} {
		if strings.TrimSpace(block.text) == "" {
			continue
		}
		section(block.title)
		pdf.MultiCell(width, 5.5, block.text, "", "L", false)
	}
	if len(rep.CompletedTasks) > 0 {
		section("Tamamlanan görevler")
		for _, t := range rep.CompletedTasks {
			pdf.MultiCell(width, 5.2, "• "+joinNonEmpty(" -- ", t.Title, t.AssignedName), "", "L", false)
		}
	}
	if err := s.drawDailyReportPhotos(ctx, pdf, rep.Photos, section, left, width); err != nil {
		return nil, err
	}
	if err := pdf.Error(); err != nil {
		return nil, err
	}
	var buf bytes.Buffer
	if err := pdf.Output(&buf); err != nil {
		return nil, err
	}
	no := strings.NewReplacer("/", "-", " ", "-").Replace(project.ProjectNo)
	return &DailyReportPDF{Filename: fmt.Sprintf("Gunluk-Rapor-%s-%s.pdf", no, date.Format("2006-01-02")), Content: buf.Bytes()}, nil
}

func dailyReportStatusLine(rep *DailyReport) string {
	if rep.Status == DailyReportSubmitted {
		if rep.SubmittedByName == "" {
			return " · Gönderildi"
		}
		return " · Gönderen: " + rep.SubmittedByName
	}
	return " · Taslak"
}

// drawDailyReportPhotos: JPEG/PNG fotoğraflardan en fazla altısını ikişerli
// sıralar; her biri en fazla dailyReportPhotoMaxSide piksele küçültülüp
// JPEG olarak gömülür (telefon fotoğrafı PDF'i şişirmesin), oranı korunur.
// Okunamayan ya da başka biçimdeki fotoğraf atlanır (rapor yine çıkar).
func (s *ProjectService) drawDailyReportPhotos(ctx context.Context, pdf *fpdf.Fpdf, photos []DailyReportPhoto, section func(string), left, width float64) error {
	type img struct {
		name, caption string
		w, h          float64
	}
	var imgs []img
	for _, p := range photos {
		if len(imgs) == dailyReportPDFMaxPhotos {
			break
		}
		switch strings.ToLower(p.mimeType) {
		case "image/jpeg", "image/jpg", "image/png":
		default:
			continue
		}
		rc, err := s.store.Open(ctx, p.objectKey)
		if err != nil {
			continue
		}
		decoded, _, err := image.Decode(io.LimitReader(rc, 26<<20))
		rc.Close()
		if err != nil {
			continue
		}
		small := downscaleOnWhite(decoded, dailyReportPhotoMaxSide)
		var buf bytes.Buffer
		if err := jpeg.Encode(&buf, small, &jpeg.Options{Quality: 78}); err != nil {
			continue
		}
		name := "photo-" + p.ID
		info := pdf.RegisterImageOptionsReader(name, fpdf.ImageOptions{ImageType: "JPG"}, &buf)
		if pdf.Error() != nil || info == nil {
			pdf.ClearError()
			continue
		}
		b := small.Bounds()
		imgs = append(imgs, img{name: name, caption: p.Description, w: float64(b.Dx()), h: float64(b.Dy())})
	}
	if len(imgs) == 0 {
		return nil
	}
	title := fmt.Sprintf("Fotoğraflar (%d)", len(imgs))
	if len(photos) > len(imgs) {
		title = fmt.Sprintf("Fotoğraflar (%d / %d)", len(imgs), len(photos))
	}
	section(title)
	const gap = 6.0
	cellW := (width - gap) / 2
	const cellH = 62.0
	_, pageH := pdf.GetPageSize()
	for i, im := range imgs {
		col := i % 2
		if col == 0 && pdf.GetY()+cellH+8 > pageH-18 {
			pdf.AddPage()
		}
		y := pdf.GetY()
		x := left + float64(col)*(cellW+gap)
		// Kutuya sığdır, oranı koru, ortala.
		w, h := cellW, cellW*im.h/im.w
		if h > cellH {
			w, h = cellH*im.w/im.h, cellH
		}
		pdf.ImageOptions(im.name, x+(cellW-w)/2, y+(cellH-h)/2, w, h, false, fpdf.ImageOptions{ImageType: "JPG"}, 0, "")
		if im.caption != "" {
			pdf.SetXY(x, y+cellH+0.5)
			pdf.SetFont(pdffont.Family, "", 7.5)
			pdf.CellFormat(cellW, 4, truncateRunes(im.caption, 60), "", 0, "C", false, 0, "")
		}
		if col == 1 || i == len(imgs)-1 {
			pdf.SetXY(left, y+cellH+6)
		}
	}
	return nil
}

// downscaleOnWhite: uzun kenarı maxSide'ı aşan resmi kutu ortalamasıyla
// küçültür (bağımlılıksız; kutu başına en fazla 3x3 örnek) ve saydamlığı
// beyaz zemine basar (JPEG'de saydamlık yok).
func downscaleOnWhite(src image.Image, maxSide int) image.Image {
	b := src.Bounds()
	w, h := b.Dx(), b.Dy()
	nw, nh := w, h
	if w > maxSide || h > maxSide {
		if w >= h {
			nw, nh = maxSide, max(1, h*maxSide/w)
		} else {
			nw, nh = max(1, w*maxSide/h), maxSide
		}
	}
	dst := image.NewRGBA(image.Rect(0, 0, nw, nh))
	for y := 0; y < nh; y++ {
		y0, y1 := b.Min.Y+y*h/nh, b.Min.Y+max((y+1)*h/nh, y*h/nh+1)
		for x := 0; x < nw; x++ {
			x0, x1 := b.Min.X+x*w/nw, b.Min.X+max((x+1)*w/nw, x*w/nw+1)
			var r, g, bl, n uint32
			for _, yy := range samplePoints(y0, y1) {
				for _, xx := range samplePoints(x0, x1) {
					cr, cg, cb, ca := src.At(xx, yy).RGBA()
					r += cr + 0xffff - ca
					g += cg + 0xffff - ca
					bl += cb + 0xffff - ca
					n++
				}
			}
			dst.SetRGBA(x, y, color.RGBA{R: uint8(r / n >> 8), G: uint8(g / n >> 8), B: uint8(bl / n >> 8), A: 0xff})
		}
	}
	return dst
}

// samplePoints: [a, b) aralığından en fazla üç örnek nokta.
func samplePoints(a, b int) []int {
	switch n := b - a; {
	case n <= 1:
		return []int{a}
	case n == 2:
		return []int{a, a + 1}
	default:
		return []int{a, a + n/2, b - 1}
	}
}
