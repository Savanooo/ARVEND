package service

import (
	"bytes"
	"context"
	"fmt"
	"math"
	"sort"
	"strings"
	"time"

	"github.com/go-pdf/fpdf"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/platform/pdffont"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

// PayrollStatement, bir personelin bir ayının maaş dökümü (BYZ'deki
// salary_print / "PDF İndir"in karşılığı): hesap özeti, o aya ait ödemeler
// ve gün gün puantaj. Rakamlar Summary ile AYNI hesaptan gelir -- ekranda
// görülen kalan ile dökümdeki kalan ayrışamaz.
type PayrollStatement struct {
	CompanyName  string
	EmployeeName string
	Position     string
	Period       string
	Row          domain.PayrollSummaryRow
	HasRow       bool // personel o ay özette yoksa (ör. pasif, verisi yok) false
	Payments     []domain.SalaryPayment
	Attendance   []domain.AttendanceLog
	GeneratedAt  time.Time
}

// Statement, dökümün verisini toplar. Personel bu firmaya ait değilse
// ErrInvalidEmployee (başka firmanın personelinin adı bile sızmaz).
func (s *SalaryPaymentService) Statement(ctx context.Context, organizationID, employeeID, period string) (*PayrollStatement, error) {
	if !domain.ValidPeriod(period) {
		return nil, ErrInvalidPeriod
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	empID, err := repository.StringToUUID(employeeID)
	if err != nil {
		return nil, ErrInvalidEmployee
	}
	emp, err := s.q.GetEmployeeByID(ctx, sqlc.GetEmployeeByIDParams{ID: empID, OrganizationID: orgID})
	if err != nil {
		return nil, ErrInvalidEmployee
	}
	org, err := s.q.GetOrganizationByID(ctx, orgID)
	if err != nil {
		return nil, err
	}

	st := &PayrollStatement{
		CompanyName:  org.Name,
		EmployeeName: emp.FullName,
		Position:     emp.Position,
		Period:       period,
		GeneratedAt:  time.Now(),
	}

	summary, err := s.Summary(ctx, organizationID, period)
	if err != nil {
		return nil, err
	}
	for _, r := range summary {
		if r.EmployeeID == employeeID {
			st.Row, st.HasRow = r, true
			break
		}
	}

	payments, err := s.ListByPeriod(ctx, organizationID, period)
	if err != nil {
		return nil, err
	}
	for _, p := range payments {
		if p.EmployeeID == employeeID {
			st.Payments = append(st.Payments, p)
		}
	}
	// Dökümde ödemeler tarih sırasıyla (liste en yeniyi önce verir).
	sort.SliceStable(st.Payments, func(i, j int) bool { return st.Payments[i].PaidDate.Before(st.Payments[j].PaidDate) })

	month, _ := time.Parse("2006-01", period)
	logs, err := s.q.ListAttendanceByMonth(ctx, sqlc.ListAttendanceByMonthParams{
		OrganizationID: orgID,
		Column2:        repository.TimeToDate(month),
	})
	if err != nil {
		return nil, err
	}
	for _, l := range logs {
		if l.EmployeeID == empID {
			st.Attendance = append(st.Attendance, repository.ToDomainAttendanceRow(l))
		}
	}
	sort.SliceStable(st.Attendance, func(i, j int) bool { return st.Attendance[i].Date.Before(st.Attendance[j].Date) })
	return st, nil
}

var (
	trMonths   = [...]string{"Ocak", "Şubat", "Mart", "Nisan", "Mayıs", "Haziran", "Temmuz", "Ağustos", "Eylül", "Ekim", "Kasım", "Aralık"}
	trWeekdays = [...]string{"Paz", "Pzt", "Sal", "Çar", "Per", "Cum", "Cmt"}
	trStatus   = map[string]string{"geldi": "Geldi", "yarım gün": "Yarım gün", "gelmedi": "Gelmedi", "izinli": "İzinli"}
	trPayType  = map[string]string{"maaş": "Maaş", "avans": "Avans", "mesai": "Mesai", "prim": "Prim", "diğer": "Diğer"}
)

// PeriodLabel: "2026-10" -> "Ekim 2026".
func PeriodLabel(period string) string {
	t, err := time.Parse("2006-01", period)
	if err != nil {
		return period
	}
	return fmt.Sprintf("%s %d", trMonths[t.Month()-1], t.Year())
}

// FormatTL: 13912.5 -> "13.912,50 TL" (eksi işaret korunur).
func FormatTL(v float64) string {
	neg := v < 0
	cents := int64(math.Round(math.Abs(v) * 100))
	whole, frac := cents/100, cents%100
	digits := fmt.Sprintf("%d", whole)
	var b strings.Builder
	for i, ch := range digits {
		if i > 0 && (len(digits)-i)%3 == 0 {
			b.WriteByte('.')
		}
		b.WriteRune(ch)
	}
	sign := ""
	if neg {
		sign = "-"
	}
	return fmt.Sprintf("%s%s,%02d TL", sign, b.String(), frac)
}

func formatNum(v float64) string {
	if v == math.Trunc(v) {
		return fmt.Sprintf("%d", int64(v))
	}
	return strings.ReplaceAll(fmt.Sprintf("%.1f", v), ".", ",")
}

// istanbul, oluşturulma saatini Türkiye saatiyle basmak için; sunucuda
// tzdata yoksa sabit +03:00.
func istanbul() *time.Location {
	if loc, err := time.LoadLocation("Europe/Istanbul"); err == nil {
		return loc
	}
	return time.FixedZone("TRT", 3*3600)
}

// RenderPayrollStatementPDF, dökümü A4 PDF olarak üretir.
func RenderPayrollStatementPDF(st *PayrollStatement) ([]byte, error) {
	pdf := fpdf.New("P", "mm", "A4", "")
	pdf.AddUTF8FontFromBytes(pdffont.Family, "", pdffont.Regular)
	pdf.AddUTF8FontFromBytes(pdffont.Family, "B", pdffont.Bold)
	pdf.SetMargins(15, 15, 15)
	pdf.SetAutoPageBreak(true, 18)
	pdf.AliasNbPages("{nb}")
	generated := st.GeneratedAt.In(istanbul()).Format("02.01.2006 15:04")
	pdf.SetFooterFunc(func() {
		pdf.SetY(-12)
		pdf.SetFont(pdffont.Family, "", 7.5)
		pdf.SetTextColor(120, 120, 120)
		pdf.CellFormat(0, 5, fmt.Sprintf("%s · Maaş dökümü · oluşturulma %s · sayfa %d/{nb}", st.CompanyName, generated, pdf.PageNo()),
			"", 0, "C", false, 0, "")
	})
	pdf.AddPage()

	const w = 180.0
	text := func(size float64, bold bool) {
		style := ""
		if bold {
			style = "B"
		}
		pdf.SetFont(pdffont.Family, style, size)
		pdf.SetTextColor(20, 20, 20)
	}

	// Başlık
	text(15, true)
	pdf.CellFormat(w*0.6, 8, st.CompanyName, "", 0, "L", false, 0, "")
	text(12, true)
	pdf.CellFormat(w*0.4, 8, "MAAŞ DÖKÜMÜ", "", 1, "R", false, 0, "")
	text(10, false)
	pdf.CellFormat(w*0.6, 6, "", "", 0, "L", false, 0, "")
	pdf.CellFormat(w*0.4, 6, PeriodLabel(st.Period), "", 1, "R", false, 0, "")
	pdf.SetDrawColor(200, 160, 60)
	pdf.SetLineWidth(0.6)
	pdf.Line(15, pdf.GetY()+2, 15+w, pdf.GetY()+2)
	pdf.Ln(6)

	// Personel
	text(10, false)
	kv := func(label, value string, bold bool) {
		text(10, false)
		pdf.SetTextColor(100, 100, 100)
		pdf.CellFormat(55, 6.5, label, "", 0, "L", false, 0, "")
		text(10, bold)
		pdf.CellFormat(w-55, 6.5, value, "", 1, "L", false, 0, "")
	}
	kv("Personel", st.EmployeeName, true)
	if st.Position != "" {
		kv("Görev", st.Position, false)
	}
	kv("Dönem", PeriodLabel(st.Period), false)
	pdf.Ln(3)

	// Hesap özeti
	section := func(title string) {
		pdf.Ln(2)
		text(11, true)
		pdf.CellFormat(w, 7, title, "", 1, "L", false, 0, "")
		pdf.SetDrawColor(220, 220, 220)
		pdf.SetLineWidth(0.2)
		pdf.Line(15, pdf.GetY(), 15+w, pdf.GetY())
		pdf.Ln(1.5)
	}
	section("Hesap özeti")
	r := st.Row
	if !st.HasRow {
		text(10, false)
		pdf.MultiCell(w, 6, "Bu ay için hesap bilgisi yok.", "", "L", false)
	} else {
		wage := "Tanımsız"
		switch r.WageBasis {
		case domain.WageBasisDaily:
			if r.DailyWage != nil {
				wage = FormatTL(*r.DailyWage) + " / gün (yevmiye)"
			}
		case domain.WageBasisMonthly:
			if r.Salary != nil {
				wage = FormatTL(*r.Salary) + " / ay"
			}
		}
		kv("Ücret", wage, false)
		kv("Çalışılan", fmt.Sprintf("%s gün · %s saat", formatNum(r.WorkedDays), formatNum(r.WorkHours)), false)
		if r.WageBasis != domain.WageBasisNone {
			kv("Hesaplanan", FormatTL(r.Earned), false)
			if r.CarryOver > 0 {
				kv("Önceki aydan devir", "-"+FormatTL(r.CarryOver), false)
			}
		}
		kv("Ödenen (maaş/avans/mesai)", FormatTL(r.SalaryPaid), false)
		if extra := math.Round((r.PaidTotal-r.SalaryPaid)*100) / 100; extra > 0 {
			kv("Ek ödeme (prim/diğer)", FormatTL(extra), false)
		}
		if r.WageBasis != domain.WageBasisNone {
			switch {
			case r.Remaining > 0:
				kv("KALAN", FormatTL(r.Remaining), true)
			case r.Remaining < 0:
				kv("FAZLA ÖDENDİ", FormatTL(-r.Remaining)+" (sonraki aya devreder)", true)
			default:
				kv("KALAN", "Yok — tamamı ödendi", true)
			}
		}
	}

	// Tablo yardımcısı
	table := func(headers []string, widths []float64, aligns []string, rows [][]string, total []string) {
		pdf.SetFillColor(245, 240, 228)
		text(9, true)
		for i, h := range headers {
			pdf.CellFormat(widths[i], 7, h, "B", 0, aligns[i], true, 0, "")
		}
		pdf.Ln(-1)
		text(9, false)
		for _, row := range rows {
			for i, c := range row {
				pdf.CellFormat(widths[i], 6.2, c, "B", 0, aligns[i], false, 0, "")
			}
			pdf.Ln(-1)
		}
		if total != nil {
			text(9, true)
			for i, c := range total {
				pdf.CellFormat(widths[i], 7, c, "", 0, aligns[i], false, 0, "")
			}
			pdf.Ln(-1)
		}
	}
	// Uzun açıklama/not tablo hücresinden taşmasın.
	clip := func(s string, n int) string {
		rs := []rune(s)
		if len(rs) <= n {
			return s
		}
		return string(rs[:n-1]) + "…"
	}

	section(fmt.Sprintf("Ödemeler (%d)", len(st.Payments)))
	if len(st.Payments) == 0 {
		text(10, false)
		pdf.MultiCell(w, 6, "Bu aya ait ödeme yok.", "", "L", false)
	} else {
		var rows [][]string
		var sum float64
		for _, p := range st.Payments {
			typ := trPayType[p.PaymentType]
			if typ == "" {
				typ = p.PaymentType
			}
			rows = append(rows, []string{p.PaidDate.Format("02.01.2006"), typ, clip(p.Description, 48), FormatTL(p.Amount)})
			sum += p.Amount
		}
		table([]string{"Tarih", "Tür", "Açıklama", "Tutar"}, []float64{28, 25, 87, 40},
			[]string{"L", "L", "L", "R"}, rows, []string{"", "", "Toplam", FormatTL(sum)})
	}

	section(fmt.Sprintf("Puantaj (%d kayıt)", len(st.Attendance)))
	if len(st.Attendance) == 0 {
		text(10, false)
		pdf.MultiCell(w, 6, "Bu ay mesai kaydı yok.", "", "L", false)
	} else {
		var rows [][]string
		var days, hours float64
		for _, a := range st.Attendance {
			status := trStatus[a.Status]
			if status == "" {
				status = a.Status
			}
			span := "-"
			if a.CheckIn != "" || a.CheckOut != "" {
				span = strings.Trim(a.CheckIn+"–"+a.CheckOut, "–")
			}
			rows = append(rows, []string{
				a.Date.Format("02.01.2006"), trWeekdays[a.Date.Weekday()], status, span, formatNum(a.WorkHours), clip(a.Note, 34),
			})
			switch a.Status {
			case "geldi":
				days++
			case "yarım gün":
				days += 0.5
			}
			hours += a.WorkHours
		}
		table([]string{"Tarih", "Gün", "Durum", "Giriş–Çıkış", "Saat", "Not"}, []float64{26, 14, 24, 30, 16, 70},
			[]string{"L", "L", "L", "L", "R", "L"}, rows,
			[]string{"", "", formatNum(days) + " gün", "", formatNum(hours), ""})
	}

	// İmza
	if pdf.GetY() > 250 {
		pdf.AddPage()
	}
	pdf.Ln(14)
	text(9, false)
	pdf.SetDrawColor(150, 150, 150)
	y := pdf.GetY()
	pdf.Line(20, y, 85, y)
	pdf.Line(110, y, 175, y)
	pdf.SetXY(20, y+1)
	pdf.CellFormat(65, 5, "Ödeyen", "", 0, "C", false, 0, "")
	pdf.SetXY(110, y+1)
	pdf.CellFormat(65, 5, "Teslim alan ("+st.EmployeeName+")", "", 1, "C", false, 0, "")

	var buf bytes.Buffer
	if err := pdf.Output(&buf); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}
