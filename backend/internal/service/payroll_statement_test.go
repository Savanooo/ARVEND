package service

import (
	"bytes"
	"os"
	"testing"
	"time"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
)

func TestFormatTLAndPeriodLabel(t *testing.T) {
	for in, want := range map[float64]string{
		0: "0,00 TL", 5: "5,00 TL", 1250.5: "1.250,50 TL", 13912: "13.912,00 TL",
		1234567.891: "1.234.567,89 TL", -3462: "-3.462,00 TL",
	} {
		if got := FormatTL(in); got != want {
			t.Errorf("FormatTL(%v) = %q, beklenen %q", in, got, want)
		}
	}
	if got := PeriodLabel("2026-10"); got != "Ekim 2026" {
		t.Errorf("PeriodLabel = %q", got)
	}
	if got := PeriodLabel("2026-02"); got != "Şubat 2026" {
		t.Errorf("PeriodLabel = %q", got)
	}
}

func sampleStatement() *PayrollStatement {
	wage := 3076.0
	day := func(d int) time.Time { return time.Date(2026, 10, d, 0, 0, 0, 0, time.UTC) }
	row := domain.PayrollSummaryRow{
		EmployeeID: "e1", FullName: "Batuhan İnci", DailyWage: &wage, IsActive: true,
		WorkedDays: 12, WorkHours: 120, PaidTotal: 24000, SalaryPaid: 23000,
	}
	row.Calculate("2026-10", "2026-10")
	st := &PayrollStatement{
		CompanyName: "Arvend Yapı", EmployeeName: "Batuhan İnci", Position: "Alçı levha uygulayıcısı",
		Period: "2026-10", Row: row, HasRow: true, GeneratedAt: time.Date(2026, 10, 6, 9, 30, 0, 0, time.UTC),
		Payments: []domain.SalaryPayment{
			{PaymentType: "avans", Amount: 5000, PaidDate: day(3), Description: "Şantiyede elden verildi"},
			{PaymentType: "maaş", Amount: 18000, PaidDate: day(15)},
			{PaymentType: "prim", Amount: 1000, PaidDate: day(15), Description: "Çatı işi primi"},
		},
	}
	statuses := []string{"geldi", "geldi", "yarım gün", "geldi", "gelmedi", "izinli"}
	for i := 0; i < 14; i++ {
		s := statuses[i%len(statuses)]
		h := 10.0
		in, out := "08:00", "18:00"
		if s == "yarım gün" {
			h, out = 4, "12:00"
		}
		if s == "gelmedi" || s == "izinli" {
			h, in, out = 0, "", ""
		}
		st.Attendance = append(st.Attendance, domain.AttendanceLog{
			Date: day(i + 1), Status: s, WorkHours: h, CheckIn: in, CheckOut: out, Note: "Kadıköy Ağaçlı Sk. şantiyesi",
		})
	}
	return st
}

func TestRenderPayrollStatementPDF(t *testing.T) {
	pdf, err := RenderPayrollStatementPDF(sampleStatement())
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.HasPrefix(pdf, []byte("%PDF-")) || len(pdf) < 2000 {
		t.Fatalf("geçerli bir PDF değil (%d bayt)", len(pdf))
	}
	// Elle bakmak için: PDF_OUT=/tmp/d.pdf go test ./internal/service -run TestRenderPayrollStatementPDF
	if out := os.Getenv("PDF_OUT"); out != "" {
		_ = os.WriteFile(out, pdf, 0o644)
	}

	// Özeti olmayan (o ay verisi yok) personelde de üretilir.
	empty := &PayrollStatement{CompanyName: "Arvend Yapı", EmployeeName: "Yeni Çırak", Period: "2026-10"}
	if _, err := RenderPayrollStatementPDF(empty); err != nil {
		t.Fatalf("boş döküm: %v", err)
	}
}
