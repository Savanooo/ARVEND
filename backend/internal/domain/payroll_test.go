package domain

import "testing"

func f(v float64) *float64 { return &v }

func TestPayrollCalculate(t *testing.T) {
	cases := []struct {
		name                         string
		row                          PayrollSummaryRow
		basis                        string
		earned, carryOver, remaining float64
	}{
		{
			name:  "yevmiye ve maaş birlikte doluysa yevmiye esastır (BYZ)",
			row:   PayrollSummaryRow{Salary: f(40000), DailyWage: f(1500), WorkedDays: 21.5, SalaryPaid: 10000},
			basis: WageBasisDaily, earned: 32250, remaining: 22250,
		},
		{
			name:  "yalnız aylık maaş: çalışılan günden bağımsız tamamı",
			row:   PayrollSummaryRow{Salary: f(30000), WorkedDays: 3},
			basis: WageBasisMonthly, earned: 30000, remaining: 30000,
		},
		{
			name:  "yevmiye 0 ise aylık maaşa düşer",
			row:   PayrollSummaryRow{Salary: f(30000), DailyWage: f(0)},
			basis: WageBasisMonthly, earned: 30000, remaining: 30000,
		},
		{
			name:  "geçen ay fazla ödendiyse fark bu aydan düşülür",
			row:   PayrollSummaryRow{DailyWage: f(1000), WorkedDays: 10, PrevWorkedDays: 5, PrevSalaryPaid: 6500},
			basis: WageBasisDaily, earned: 10000, carryOver: 1500, remaining: 8500,
		},
		{
			name:  "geçen ay eksik ödendiyse taşınmaz (o ayın kalanı olarak durur)",
			row:   PayrollSummaryRow{DailyWage: f(1000), WorkedDays: 10, PrevWorkedDays: 5, PrevSalaryPaid: 1000},
			basis: WageBasisDaily, earned: 10000, carryOver: 0, remaining: 10000,
		},
		{
			name:  "fazla ödeme kuruşu kuruşuna eksi kalan verir",
			row:   PayrollSummaryRow{DailyWage: f(1000), WorkedDays: 1, SalaryPaid: 1500},
			basis: WageBasisDaily, earned: 1000, remaining: -500,
		},
		{
			name:  "kuruşlu yevmiye yarım günle",
			row:   PayrollSummaryRow{DailyWage: f(1333.33), WorkedDays: 2.5},
			basis: WageBasisDaily, earned: 3333.33, remaining: 3333.33,
		},
		{
			name:  "ücret tanımsız: hiçbir şey hesaplanmaz, ödeme fazla sayılmaz",
			row:   PayrollSummaryRow{WorkedDays: 10, SalaryPaid: 5000, PrevSalaryPaid: 5000},
			basis: WageBasisNone,
		},
	}
	for _, c := range cases {
		r := c.row
		r.Calculate()
		if r.WageBasis != c.basis || r.Earned != c.earned || r.CarryOver != c.carryOver || r.Remaining != c.remaining {
			t.Errorf("%s:\n  esas=%q hakediş=%v devir=%v kalan=%v\n  beklenen esas=%q hakediş=%v devir=%v kalan=%v",
				c.name, r.WageBasis, r.Earned, r.CarryOver, r.Remaining, c.basis, c.earned, c.carryOver, c.remaining)
		}
	}
}
