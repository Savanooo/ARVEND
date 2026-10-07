package service_test

import (
	"context"
	"errors"
	"fmt"
	"math"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

// TestSalaryPayments, maaş/mesai ödemeleri modülünü (migration 0048) gerçek
// bir PostgreSQL üzerinde doğrular: aynı ay için birden çok ödeme, aylık
// özetin puantajla birleşmesi, doğrulama kuralları ve -- en önemlisi --
// tenant sınırı (hem servis hem DB tetikleyicisi katmanında).
func TestSalaryPayments(t *testing.T) {
	ctx := context.Background()
	dbURL := testDBURL(t)

	pool, err := repository.NewPool(ctx, dbURL)
	if err != nil {
		t.Fatalf("pool: %v", err)
	}
	t.Cleanup(func() { pool.Close() })

	q := sqlc.New(pool)
	orgSvc := service.NewOrganizationService(q)
	svc := service.NewSalaryPaymentService(q)

	orgA := mustCreateOrg(t, ctx, orgSvc, pool, "Maaş Test Firma A", "maas-test-firma-a")
	orgB := mustCreateOrg(t, ctx, orgSvc, pool, "Maaş Test Firma B", "maas-test-firma-b")

	empA := mustCreateEmployee(t, ctx, pool, orgA.ID, "Ahmet Usta", true)
	empA2 := mustCreateEmployee(t, ctx, pool, orgA.ID, "Pasif Kalfa", false)
	empB := mustCreateEmployee(t, ctx, pool, orgB.ID, "Başka Firmanın Personeli", true)

	const period = "2026-09"

	t.Run("1_multiple_payments_same_month_are_allowed", func(t *testing.T) {
		for _, in := range []service.SalaryPaymentInput{
			{EmployeeID: empA, Period: period, PaymentType: domain.PaymentTypeAvans, Amount: 5000, PaidDate: day(2026, 9, 15)},
			{EmployeeID: empA, Period: period, PaymentType: domain.PaymentTypeMaas, Amount: 25000.5, PaidDate: day(2026, 10, 5)},
		} {
			if _, err := svc.Create(ctx, orgA.ID, in); err != nil {
				t.Fatalf("ödeme eklenemedi: %v", err)
			}
		}
		list, err := svc.ListByPeriod(ctx, orgA.ID, period)
		if err != nil {
			t.Fatal(err)
		}
		if len(list) != 2 {
			t.Fatalf("2 ödeme beklendi, %d geldi", len(list))
		}
		if list[0].EmployeeName != "Ahmet Usta" {
			t.Errorf("personel adı JOIN'den gelmeli, %q geldi", list[0].EmployeeName)
		}
		// En son ödenen önce.
		if got := list[0].PaidDate.Format("2006-01-02"); got != "2026-10-05" {
			t.Errorf("sıralama: ilk satır 2026-10-05 olmalı, %s geldi", got)
		}
	})

	t.Run("2_summary_joins_attendance_and_payments", func(t *testing.T) {
		mustAttendance(t, ctx, pool, orgA.ID, empA, "2026-09-01", "geldi", 9)
		mustAttendance(t, ctx, pool, orgA.ID, empA, "2026-09-02", "yarım gün", 4)
		mustAttendance(t, ctx, pool, orgA.ID, empA, "2026-09-03", "gelmedi", 0)
		mustAttendance(t, ctx, pool, orgA.ID, empA, "2026-08-31", "geldi", 9) // önceki ay, sayılmamalı

		rows, err := svc.Summary(ctx, orgA.ID, period)
		if err != nil {
			t.Fatal(err)
		}
		var row *domain.PayrollSummaryRow
		for i := range rows {
			if rows[i].EmployeeID == empA {
				row = &rows[i]
			}
			if rows[i].EmployeeID == empA2 {
				t.Errorf("o ay verisi olmayan pasif personel özette görünmemeli")
			}
		}
		if row == nil {
			t.Fatal("aktif personel özette yok")
		}
		if row.WorkedDays != 1.5 {
			t.Errorf("çalışılan gün: geldi(1) + yarım gün(0.5) = 1.5 beklendi, %v geldi", row.WorkedDays)
		}
		if row.WorkHours != 13 {
			t.Errorf("saat: 13 beklendi, %v geldi", row.WorkHours)
		}
		if row.PaidTotal != 30000.5 || row.PaymentCount != 2 {
			t.Errorf("ödenen: 30000.5 / 2 adet beklendi, %v / %d geldi", row.PaidTotal, row.PaymentCount)
		}
	})

	t.Run("3_inactive_employee_with_payment_still_in_summary", func(t *testing.T) {
		if _, err := svc.Create(ctx, orgA.ID, service.SalaryPaymentInput{
			EmployeeID: empA2, Period: period, Amount: 1000, PaidDate: day(2026, 9, 30),
		}); err != nil {
			t.Fatal(err)
		}
		rows, _ := svc.Summary(ctx, orgA.ID, period)
		found := false
		for _, r := range rows {
			if r.EmployeeID == empA2 {
				found = true
			}
		}
		if !found {
			t.Error("işten ayrılan personelin o ayki ödemesi özette kaybolmamalı")
		}
	})

	t.Run("4_validation", func(t *testing.T) {
		cases := []struct {
			name string
			in   service.SalaryPaymentInput
			want error
		}{
			{"ay 13", service.SalaryPaymentInput{EmployeeID: empA, Period: "2026-13", Amount: 1}, service.ErrInvalidPeriod},
			{"ay tek hane", service.SalaryPaymentInput{EmployeeID: empA, Period: "2026-9", Amount: 1}, service.ErrInvalidPeriod},
			{"tür", service.SalaryPaymentInput{EmployeeID: empA, Period: period, PaymentType: "ikramiye", Amount: 1}, service.ErrInvalidPaymentType},
			{"sıfır", service.SalaryPaymentInput{EmployeeID: empA, Period: period, Amount: 0}, service.ErrInvalidAmount},
			{"eksi", service.SalaryPaymentInput{EmployeeID: empA, Period: period, Amount: -5}, service.ErrInvalidAmount},
			{"NaN", service.SalaryPaymentInput{EmployeeID: empA, Period: period, Amount: math.NaN()}, service.ErrInvalidAmount},
			{"çok büyük", service.SalaryPaymentInput{EmployeeID: empA, Period: period, Amount: 1e12}, service.ErrAmountTooLarge},
			{"personel yok", service.SalaryPaymentInput{EmployeeID: "00000000-0000-0000-0000-000000000000", Period: period, Amount: 1}, service.ErrInvalidEmployee},
		}
		for _, c := range cases {
			if _, err := svc.Create(ctx, orgA.ID, c.in); !errors.Is(err, c.want) {
				t.Errorf("%s: %v beklendi, %v geldi", c.name, c.want, err)
			}
		}
		if _, err := svc.ListByPeriod(ctx, orgA.ID, "2026/09"); !errors.Is(err, service.ErrInvalidPeriod) {
			t.Errorf("liste geçersiz ayı reddetmeli, %v geldi", err)
		}
	})

	t.Run("5_default_type_and_paid_date", func(t *testing.T) {
		p, err := svc.Create(ctx, orgA.ID, service.SalaryPaymentInput{EmployeeID: empA, Period: "2026-08", Amount: 10})
		if err != nil {
			t.Fatal(err)
		}
		if p.PaymentType != domain.PaymentTypeMaas {
			t.Errorf("tür verilmezse 'maaş' olmalı, %q geldi", p.PaymentType)
		}
		if p.PaidDate.IsZero() {
			t.Error("ödeme tarihi verilmezse bugün olmalı")
		}
	})

	t.Run("6_tenant_isolation", func(t *testing.T) {
		// B, A'nın personeline ödeme yazamaz.
		if _, err := svc.Create(ctx, orgB.ID, service.SalaryPaymentInput{EmployeeID: empA, Period: period, Amount: 1}); !errors.Is(err, service.ErrInvalidEmployee) {
			t.Errorf("başka firmanın personeline ödeme reddedilmeli, %v geldi", err)
		}
		// B, A'nın ödemelerini göremez.
		list, _ := svc.ListByPeriod(ctx, orgB.ID, period)
		if len(list) != 0 {
			t.Errorf("B, A'nın %d ödemesini görüyor", len(list))
		}
		rows, _ := svc.Summary(ctx, orgB.ID, period)
		for _, r := range rows {
			if r.EmployeeID == empA {
				t.Error("B'nin özetinde A'nın personeli var")
			}
		}
		// B, A'nın ödemesini ID'siyle de silemez.
		aList, _ := svc.ListByPeriod(ctx, orgA.ID, period)
		if err := svc.Delete(ctx, aList[0].ID, orgB.ID); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("B'nin silmesi ErrNotFound olmalı, %v geldi", err)
		}
		after, _ := svc.ListByPeriod(ctx, orgA.ID, period)
		if len(after) != len(aList) {
			t.Error("B'nin silme denemesi A'nın kaydını sildi")
		}
	})

	t.Run("7_db_trigger_blocks_cross_tenant_insert", func(t *testing.T) {
		// Servisi atlayan bir yazıcı (ör. BYZ aktarım aracı) da sınırı geçememeli.
		_, err := pool.Exec(ctx, `
			INSERT INTO salary_payments (organization_id, employee_id, period, amount)
			VALUES ($1, $2, '2026-09', 1)`, orgB.ID, empA)
		if err == nil {
			t.Fatal("DB tetikleyicisi başka firmanın personeline yazmayı engellemeli")
		}
		_ = empB
	})

	t.Run("8_delete", func(t *testing.T) {
		p, err := svc.Create(ctx, orgA.ID, service.SalaryPaymentInput{EmployeeID: empA, Period: "2026-07", Amount: 7})
		if err != nil {
			t.Fatal(err)
		}
		if err := svc.Delete(ctx, p.ID, orgA.ID); err != nil {
			t.Fatalf("silinemedi: %v", err)
		}
		if err := svc.Delete(ctx, p.ID, orgA.ID); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("ikinci silme ErrNotFound olmalı, %v geldi", err)
		}
	})

	t.Run("9_calculation_matches_byz_rule", func(t *testing.T) {
		// Yevmiye 1000. Ağustos: 2 gün çalıştı (hakediş 2000), 3000 maaş
		// ödendi -> 1000 fazla, Eylül'e devir. Ağustostaki 500 prim fazla
		// ödeme SAYILMAZ. Eylül: 3 gün (3000), 1000 avans + 700 prim.
		// Beklenen kalan: 3000 - 1000 (avans) - 1000 (devir) = 1000.
		emp := mustCreateEmployee(t, ctx, pool, orgA.ID, "Yevmiyeli Usta", true)
		if _, err := pool.Exec(ctx, `UPDATE employees SET daily_wage = 1000, salary = 40000 WHERE id = $1`, emp); err != nil {
			t.Fatal(err)
		}
		mustAttendance(t, ctx, pool, orgA.ID, emp, "2026-08-10", "geldi", 9)
		mustAttendance(t, ctx, pool, orgA.ID, emp, "2026-08-11", "geldi", 9)
		for _, d := range []string{"2026-09-01", "2026-09-02", "2026-09-03"} {
			mustAttendance(t, ctx, pool, orgA.ID, emp, d, "geldi", 9)
		}
		for _, in := range []service.SalaryPaymentInput{
			{EmployeeID: emp, Period: "2026-08", PaymentType: domain.PaymentTypeMaas, Amount: 3000},
			{EmployeeID: emp, Period: "2026-08", PaymentType: domain.PaymentTypePrim, Amount: 500},
			{EmployeeID: emp, Period: period, PaymentType: domain.PaymentTypeAvans, Amount: 1000},
			{EmployeeID: emp, Period: period, PaymentType: domain.PaymentTypePrim, Amount: 700},
		} {
			if _, err := svc.Create(ctx, orgA.ID, in); err != nil {
				t.Fatal(err)
			}
		}

		rows, err := svc.Summary(ctx, orgA.ID, period)
		if err != nil {
			t.Fatal(err)
		}
		var r *domain.PayrollSummaryRow
		for i := range rows {
			if rows[i].EmployeeID == emp {
				r = &rows[i]
			}
		}
		if r == nil {
			t.Fatal("personel özette yok")
		}
		if r.WageBasis != domain.WageBasisDaily || r.Earned != 3000 {
			t.Errorf("yevmiye esası, hakediş 3000 beklendi: %q / %v", r.WageBasis, r.Earned)
		}
		if r.PaidTotal != 1700 || r.SalaryPaid != 1000 {
			t.Errorf("ödenen 1700, kalandan düşülen 1000 beklendi: %v / %v", r.PaidTotal, r.SalaryPaid)
		}
		if r.CarryOver != 1000 {
			t.Errorf("devir 1000 beklendi (Ağustos fazla ödemesi, prim hariç): %v", r.CarryOver)
		}
		if r.Remaining != 1000 {
			t.Errorf("kalan 1000 beklendi: %v", r.Remaining)
		}

		// Ocak'ın önceki ayı bir önceki yılın Aralık'ı.
		if _, err := svc.Create(ctx, orgA.ID, service.SalaryPaymentInput{
			EmployeeID: emp, Period: "2025-12", Amount: 250,
		}); err != nil {
			t.Fatal(err)
		}
		jan, err := svc.Summary(ctx, orgA.ID, "2026-01")
		if err != nil {
			t.Fatal(err)
		}
		for _, j := range jan {
			if j.EmployeeID == emp && j.CarryOver != 250 {
				t.Errorf("Aralık 2025'teki 250 fazla ödeme Ocak 2026'ya devretmeli: %v", j.CarryOver)
			}
		}
	})

	t.Run("10_statement_only_this_employee_and_tenant", func(t *testing.T) {
		emp := mustCreateEmployee(t, ctx, pool, orgA.ID, "Döküm Ustası", true)
		other := mustCreateEmployee(t, ctx, pool, orgA.ID, "Başka Usta", true)
		if _, err := pool.Exec(ctx, `UPDATE employees SET daily_wage = 2000 WHERE id = $1`, emp); err != nil {
			t.Fatal(err)
		}
		mustAttendance(t, ctx, pool, orgA.ID, emp, "2026-11-02", "geldi", 9)
		mustAttendance(t, ctx, pool, orgA.ID, emp, "2026-11-03", "yarım gün", 4)
		mustAttendance(t, ctx, pool, orgA.ID, other, "2026-11-02", "geldi", 9)
		for _, in := range []service.SalaryPaymentInput{
			{EmployeeID: emp, Period: "2026-11", PaymentType: domain.PaymentTypeAvans, Amount: 1000, PaidDate: day(2026, 11, 5)},
			{EmployeeID: other, Period: "2026-11", Amount: 777},
		} {
			if _, err := svc.Create(ctx, orgA.ID, in); err != nil {
				t.Fatal(err)
			}
		}

		st, err := svc.Statement(ctx, orgA.ID, emp, "2026-11")
		if err != nil {
			t.Fatal(err)
		}
		if st.EmployeeName != "Döküm Ustası" || st.CompanyName == "" {
			t.Errorf("başlık: %q / %q", st.EmployeeName, st.CompanyName)
		}
		if len(st.Attendance) != 2 || len(st.Payments) != 1 || st.Payments[0].Amount != 1000 {
			t.Errorf("yalnızca bu personelin kayıtları: %d mesai, %d ödeme", len(st.Attendance), len(st.Payments))
		}
		if !st.HasRow || st.Row.Earned != 3000 || st.Row.Remaining != 2000 {
			t.Errorf("hesap ekrandakiyle aynı olmalı: %+v", st.Row)
		}
		if !st.Attendance[0].Date.Before(st.Attendance[1].Date) {
			t.Error("puantaj tarih sırasıyla")
		}
		if _, err := service.RenderPayrollStatementPDF(st); err != nil {
			t.Fatalf("PDF: %v", err)
		}

		// B firması A'nın personelinin dökümünü alamaz (adı bile sızmaz).
		if _, err := svc.Statement(ctx, orgB.ID, emp, "2026-11"); !errors.Is(err, service.ErrInvalidEmployee) {
			t.Errorf("başka firma: ErrInvalidEmployee beklendi, %v geldi", err)
		}
		if _, err := svc.Statement(ctx, orgA.ID, emp, "2026-13"); !errors.Is(err, service.ErrInvalidPeriod) {
			t.Errorf("geçersiz ay: %v", err)
		}
	})

	summaryRow := func(t *testing.T, period, emp string) *domain.PayrollSummaryRow {
		t.Helper()
		rows, err := svc.Summary(ctx, orgA.ID, period)
		if err != nil {
			t.Fatal(err)
		}
		for i := range rows {
			if rows[i].EmployeeID == emp {
				return &rows[i]
			}
		}
		return nil
	}

	t.Run("11_carry_over_chains_across_months", func(t *testing.T) {
		// Denetimdeki örnek: yevmiye 1000; Nisan 10 gün + 30.000 avans
		// (20.000 fazla), Mayıs ve Haziran 10'ar gün, ödeme yok.
		emp := mustCreateEmployee(t, ctx, pool, orgA.ID, "Zincir Usta", true)
		if _, err := pool.Exec(ctx, `UPDATE employees SET daily_wage = 1000 WHERE id = $1`, emp); err != nil {
			t.Fatal(err)
		}
		for _, month := range []string{"2026-04", "2026-05", "2026-06"} {
			for dd := 1; dd <= 10; dd++ {
				mustAttendance(t, ctx, pool, orgA.ID, emp, fmt.Sprintf("%s-%02d", month, dd), "geldi", 9)
			}
		}
		if _, err := svc.Create(ctx, orgA.ID, service.SalaryPaymentInput{
			EmployeeID: emp, Period: "2026-04", PaymentType: domain.PaymentTypeAvans, Amount: 30000,
		}); err != nil {
			t.Fatal(err)
		}
		if r := summaryRow(t, "2026-05", emp); r == nil || r.CarryOver != 20000 || r.Remaining != -10000 {
			t.Fatalf("Mayıs: devir 20000, kalan -10000 beklendi: %+v", r)
		}
		r := summaryRow(t, "2026-06", emp)
		if r == nil || r.CarryOver != 10000 || r.Remaining != 0 {
			t.Fatalf("Haziran: Mayıs'tan kalan 10.000 devretmeli (eskiden kayboluyordu): %+v", r)
		}
		if r := summaryRow(t, "2026-07", emp); r != nil && r.CarryOver != 0 {
			t.Errorf("Temmuz: zincir tükendi, devir 0 beklendi: %v", r.CarryOver)
		}
		// Döküm de aynı hesaptan gelir.
		st, err := svc.Statement(ctx, orgA.ID, emp, "2026-06")
		if err != nil {
			t.Fatal(err)
		}
		if st.Row.CarryOver != 10000 {
			t.Errorf("döküm devri ekranla aynı olmalı: %v", st.Row.CarryOver)
		}
	})

	t.Run("12_monthly_salary_not_owed_before_start_or_in_future", func(t *testing.T) {
		emp := mustCreateEmployee(t, ctx, pool, orgA.ID, "Yeni Giren Kalfa", true)
		if _, err := pool.Exec(ctx, `UPDATE employees SET salary = 30000, start_date = '2026-08-15' WHERE id = $1`, emp); err != nil {
			t.Fatal(err)
		}
		if r := summaryRow(t, "2026-07", emp); r != nil {
			t.Errorf("işe girişten önceki ay (verisi yok) listelenmemeli: %+v", r)
		}
		if r := summaryRow(t, "2026-08", emp); r == nil || r.Earned != 30000 {
			t.Errorf("işe girdiği ay tam maaş beklendi: %+v", r)
		}
		future := service.IstanbulToday().AddDate(0, 2, 0).Format("2006-01")
		if r := summaryRow(t, future, emp); r == nil || r.Earned != 0 || r.Remaining != 0 {
			t.Errorf("ileri ay (%s) borç gösterilmemeli: %+v", future, r)
		}
		// İşe girmeden önceki aya verilen avans o ay listelenir ve devreder.
		if _, err := svc.Create(ctx, orgA.ID, service.SalaryPaymentInput{
			EmployeeID: emp, Period: "2026-07", PaymentType: domain.PaymentTypeAvans, Amount: 5000,
		}); err != nil {
			t.Fatal(err)
		}
		if r := summaryRow(t, "2026-07", emp); r == nil || r.Earned != 0 || r.Remaining != -5000 {
			t.Errorf("girişten önceki ayın avansı: hakediş 0, kalan -5000 beklendi: %+v", r)
		}
		if r := summaryRow(t, "2026-08", emp); r == nil || r.CarryOver != 5000 || r.Remaining != 25000 {
			t.Errorf("avans girişin ilk ayına devretmeli: %+v", r)
		}
	})

	t.Run("13_wage_change_does_not_rewrite_past_months", func(t *testing.T) {
		empSvc := service.NewEmployeeService(pool, q)
		today := service.IstanbulToday()
		thisMonth := today.Format("2006-01")
		lastMonth := time.Date(today.Year(), today.Month()-1, 1, 0, 0, 0, 0, time.UTC).Format("2006-01")
		start := time.Date(today.Year()-1, 1, 1, 0, 0, 0, 0, time.UTC)
		e, err := empSvc.Create(ctx, orgA.ID, service.EmployeeInput{FullName: "Zamlı Usta", Salary: fp(30000), StartDate: &start})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := svc.Create(ctx, orgA.ID, service.SalaryPaymentInput{
			EmployeeID: e.ID, Period: lastMonth, PaymentType: domain.PaymentTypeMaas, Amount: 30000,
		}); err != nil {
			t.Fatal(err)
		}
		if r := summaryRow(t, lastMonth, e.ID); r == nil || r.Remaining != 0 {
			t.Fatalf("zamdan önce geçen ay tamamen ödenmiş olmalı: %+v", r)
		}

		// Bugün zam: 34.000.
		if _, err := empSvc.Update(ctx, e.ID, orgA.ID, service.EmployeeInput{
			FullName: "Zamlı Usta", Salary: fp(34000), StartDate: &start, IsActive: true,
		}); err != nil {
			t.Fatal(err)
		}
		r := summaryRow(t, lastMonth, e.ID)
		if r == nil || r.Earned != 30000 || r.Remaining != 0 || r.Salary == nil || *r.Salary != 30000 {
			t.Errorf("zam geçen ayı değiştirmemeli (hakediş 30000, kalan 0, ücret 30000): %+v", r)
		}
		r = summaryRow(t, thisMonth, e.ID)
		if r == nil || r.Earned != 34000 || r.CarryOver != 0 || r.Remaining != 34000 {
			t.Errorf("bu ay yeni ücretle, sahte devir yok: %+v", r)
		}

		// Ücret değişmeyen bir düzenleme yeni geçmiş satırı yazmaz; geçmiş
		// tenant kapsamlı.
		if _, err := empSvc.Update(ctx, e.ID, orgA.ID, service.EmployeeInput{
			FullName: "Zamlı Usta (düzeltildi)", Salary: fp(34000), StartDate: &start, IsActive: true,
		}); err != nil {
			t.Fatal(err)
		}
		var n int
		if err := pool.QueryRow(ctx, `SELECT count(*) FROM employee_wage_history WHERE employee_id = $1 AND organization_id = $2`, e.ID, orgA.ID).Scan(&n); err != nil {
			t.Fatal(err)
		}
		if n != 2 {
			t.Errorf("başlangıç + zam = 2 geçmiş satırı beklendi, %d", n)
		}
		if _, err := pool.Exec(ctx, `
			INSERT INTO employee_wage_history (organization_id, employee_id, salary, effective_from)
			VALUES ($1, $2, 1, '2026-01-01')`, orgB.ID, e.ID); err == nil {
			t.Error("DB tetikleyicisi başka firmanın personeline ücret geçmişi yazmayı engellemeli")
		}
	})

	t.Run("14_wage_change_for_employee_without_history_keeps_old_rate", func(t *testing.T) {
		// Servisi atlayarak eklenmiş (geçmişi olmayan) personel: ilk
		// değişiklikte eski ücret başlangıç satırı olarak kaydedilmeli.
		empSvc := service.NewEmployeeService(pool, q)
		emp := mustCreateEmployee(t, ctx, pool, orgA.ID, "Aktarılmış Usta", true)
		if _, err := pool.Exec(ctx, `UPDATE employees SET daily_wage = 1000 WHERE id = $1`, emp); err != nil {
			t.Fatal(err)
		}
		mustAttendance(t, ctx, pool, orgA.ID, emp, "2026-03-02", "geldi", 9)
		if _, err := empSvc.Update(ctx, emp, orgA.ID, service.EmployeeInput{
			FullName: "Aktarılmış Usta", DailyWage: fp(1500), IsActive: true,
		}); err != nil {
			t.Fatal(err)
		}
		if r := summaryRow(t, "2026-03", emp); r == nil || r.Earned != 1000 {
			t.Errorf("Mart eski yevmiyeyle (1000) kalmalı: %+v", r)
		}
	})
}

func fp(v float64) *float64 { return &v }

func day(y int, m time.Month, d int) time.Time { return time.Date(y, m, d, 0, 0, 0, 0, time.UTC) }

func mustCreateEmployee(t *testing.T, ctx context.Context, pool *pgxpool.Pool, orgID, name string, active bool) string {
	t.Helper()
	var id string
	if err := pool.QueryRow(ctx,
		`INSERT INTO employees (organization_id, full_name, is_active) VALUES ($1, $2, $3) RETURNING id`,
		orgID, name, active).Scan(&id); err != nil {
		t.Fatalf("personel oluşturulamadı: %v", err)
	}
	return id
}

func mustAttendance(t *testing.T, ctx context.Context, pool *pgxpool.Pool, orgID, empID, date, status string, hours float64) {
	t.Helper()
	if _, err := pool.Exec(ctx, `
		INSERT INTO attendance_logs (organization_id, employee_id, date, status, work_hours)
		VALUES ($1, $2, $3::date, $4, $5)`, orgID, empID, date, status, hours); err != nil {
		t.Fatalf("mesai eklenemedi: %v", err)
	}
}
