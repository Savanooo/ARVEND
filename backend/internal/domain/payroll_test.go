package domain

import (
	"testing"
	"time"
)

func f(v float64) *float64 { return &v }

func d(s string) time.Time {
	t, err := time.Parse("2006-01-02", s)
	if err != nil {
		panic(err)
	}
	return t
}

func TestPayrollCalculate(t *testing.T) {
	const period, now = "2026-09", "2026-10"
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
			name: "geçen ay fazla ödendiyse fark bu aydan düşülür",
			row: PayrollSummaryRow{DailyWage: f(1000), WorkedDays: 10,
				History: []PayrollMonth{{Period: "2026-08", WorkedDays: 5, SalaryPaid: 6500}}},
			basis: WageBasisDaily, earned: 10000, carryOver: 1500, remaining: 8500,
		},
		{
			name: "geçen ay eksik ödendiyse taşınmaz (o ayın kalanı olarak durur)",
			row: PayrollSummaryRow{DailyWage: f(1000), WorkedDays: 10,
				History: []PayrollMonth{{Period: "2026-08", WorkedDays: 5, SalaryPaid: 1000}}},
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
			name: "ücret tanımsız: hiçbir şey hesaplanmaz, ödeme fazla sayılmaz",
			row: PayrollSummaryRow{WorkedDays: 10, SalaryPaid: 5000,
				History: []PayrollMonth{{Period: "2026-08", SalaryPaid: 5000}}},
			basis: WageBasisNone,
		},
		{
			name: "aylık maaşlı, işe girişinden önceki ay: borç yok, yapılan avans devreder",
			row:  PayrollSummaryRow{Salary: f(30000), StartDate: timePtr(d("2026-10-15")), SalaryPaid: 5000},
			// Eylül, ekimde işe giren için borç değil.
			basis: WageBasisMonthly, earned: 0, remaining: -5000,
		},
		{
			name:  "aylık maaşlı, işe girdiği ay: ayın tamamı (kıst yok)",
			row:   PayrollSummaryRow{Salary: f(30000), StartDate: timePtr(d("2026-09-20"))},
			basis: WageBasisMonthly, earned: 30000, remaining: 30000,
		},
	}
	for _, c := range cases {
		r := c.row
		r.Calculate(period, now)
		if r.WageBasis != c.basis || r.Earned != c.earned || r.CarryOver != c.carryOver || r.Remaining != c.remaining {
			t.Errorf("%s:\n  esas=%q hakediş=%v devir=%v kalan=%v\n  beklenen esas=%q hakediş=%v devir=%v kalan=%v",
				c.name, r.WageBasis, r.Earned, r.CarryOver, r.Remaining, c.basis, c.earned, c.carryOver, c.remaining)
		}
	}
}

func timePtr(t time.Time) *time.Time { return &t }

// Denetimdeki örnek: yevmiye 1000. N ayı 10 gün + 30.000 avans -> 20.000
// fazla. N+1 10 gün, ödeme yok -> 20.000 devir, kalan −10.000. N+2'de
// kalan 10.000 hâlâ devretmeli; eskiden yalnız N+1'e bakıldığı için
// (ödenen 0 − hakediş 10.000 -> 0) kayboluyordu.
func TestPayrollCarryOverChainsAcrossMonths(t *testing.T) {
	history := []PayrollMonth{
		{Period: "2026-07", WorkedDays: 10, SalaryPaid: 30000},
		{Period: "2026-08", WorkedDays: 10, SalaryPaid: 0},
	}
	n1 := PayrollSummaryRow{DailyWage: f(1000), WorkedDays: 10, History: history[:1]}
	n1.Calculate("2026-08", "2026-10")
	if n1.CarryOver != 20000 || n1.Remaining != -10000 {
		t.Fatalf("N+1: devir 20000, kalan -10000 beklendi: %v / %v", n1.CarryOver, n1.Remaining)
	}

	n2 := PayrollSummaryRow{DailyWage: f(1000), WorkedDays: 10, History: history}
	n2.Calculate("2026-09", "2026-10")
	if n2.CarryOver != 10000 {
		t.Errorf("N+2: kalan 10.000 fazla ödeme devretmeli, devir %v", n2.CarryOver)
	}
	if n2.Remaining != 0 {
		t.Errorf("N+2: 10.000 hakediş − 10.000 devir = 0 beklendi, %v", n2.Remaining)
	}

	// N+3: zincir tükendi, artık devir yok.
	n3 := PayrollSummaryRow{DailyWage: f(1000), WorkedDays: 5,
		History: append(history, PayrollMonth{Period: "2026-09", WorkedDays: 10})}
	n3.Calculate("2026-10", "2026-10")
	if n3.CarryOver != 0 || n3.Remaining != 5000 {
		t.Errorf("N+3: devir 0, kalan 5000 beklendi: %v / %v", n3.CarryOver, n3.Remaining)
	}
}

// Kaydı olmayan ara ay da zincirde sayılır: aylık maaşlıda o ayın maaşı
// fazla ödemeyi tüketir, yevmiyelide (çalışılmadıysa) dokunmaz.
func TestPayrollCarryOverSpansEmptyMonths(t *testing.T) {
	monthly := PayrollSummaryRow{Salary: f(30000),
		History: []PayrollMonth{{Period: "2026-06", SalaryPaid: 75000}}}
	monthly.Calculate("2026-09", "2026-10")
	// Haziran +45.000, Temmuz −30.000 -> 15.000, Ağustos −30.000 -> 0.
	if monthly.CarryOver != 0 {
		t.Errorf("aylık: iki boş ay fazla ödemeyi tüketmeli, devir %v", monthly.CarryOver)
	}
	monthly2 := PayrollSummaryRow{Salary: f(30000),
		History: []PayrollMonth{{Period: "2026-07", SalaryPaid: 75000}}}
	monthly2.Calculate("2026-09", "2026-10")
	if monthly2.CarryOver != 15000 {
		t.Errorf("aylık: Temmuz +45.000, Ağustos −30.000 -> 15.000 beklendi, %v", monthly2.CarryOver)
	}

	daily := PayrollSummaryRow{DailyWage: f(1000),
		History: []PayrollMonth{{Period: "2026-06", WorkedDays: 2, SalaryPaid: 5000}}}
	daily.Calculate("2026-09", "2026-10")
	if daily.CarryOver != 3000 {
		t.Errorf("yevmiyeli: çalışılmayan aylar devri tüketmez, 3000 beklendi: %v", daily.CarryOver)
	}
}

// İleri bir ay "borç" değildir: aylık maaş henüz işlemedi.
func TestPayrollFutureMonthNotOwed(t *testing.T) {
	r := PayrollSummaryRow{Salary: f(30000)}
	r.Calculate("2026-12", "2026-10")
	if r.Earned != 0 || r.Remaining != 0 || r.WageBasis != WageBasisMonthly {
		t.Errorf("ileri ay: hakediş 0, kalan 0 beklendi: %+v", r)
	}
	// İçinde bulunulan ay borçtur.
	cur := PayrollSummaryRow{Salary: f(30000)}
	cur.Calculate("2026-10", "2026-10")
	if cur.Earned != 30000 {
		t.Errorf("bu ay: tam maaş beklendi, %v", cur.Earned)
	}
}

// Zam ekimde: tamamı ödenmiş eylül "eksik ödendi"ye dönmez, ekim yeni
// ücretle hesaplanır, devir zinciri de her ayı kendi ücretiyle hesaplar.
func TestPayrollWageHistory(t *testing.T) {
	wages := []WageRate{
		{EffectiveFrom: d("2000-01-01"), Salary: f(30000)},
		{EffectiveFrom: d("2026-10-06"), Salary: f(34000)},
	}
	sep := PayrollSummaryRow{Salary: f(34000), SalaryPaid: 30000, Wages: wages}
	sep.Calculate("2026-09", "2026-10")
	if sep.Earned != 30000 || sep.Remaining != 0 || *sep.Salary != 30000 {
		t.Errorf("eylül eski ücretle kapanmalı: hakediş %v kalan %v ücret %v", sep.Earned, sep.Remaining, *sep.Salary)
	}
	oct := PayrollSummaryRow{Salary: f(34000), Wages: wages,
		History: []PayrollMonth{{Period: "2026-09", SalaryPaid: 30000}}}
	oct.Calculate("2026-10", "2026-10")
	if oct.Earned != 34000 || oct.CarryOver != 0 || oct.Remaining != 34000 {
		t.Errorf("ekim yeni ücretle, devir yok: hakediş %v devir %v kalan %v", oct.Earned, oct.CarryOver, oct.Remaining)
	}

	// İndirim sahte fazla ödeme üretmez: eski ücretle tam ödenen ay devir
	// doğurmaz.
	cut := []WageRate{
		{EffectiveFrom: d("2000-01-01"), DailyWage: f(1500)},
		{EffectiveFrom: d("2026-10-01"), DailyWage: f(1000)},
	}
	afterCut := PayrollSummaryRow{DailyWage: f(1000), WorkedDays: 5, Wages: cut,
		History: []PayrollMonth{{Period: "2026-09", WorkedDays: 10, SalaryPaid: 15000}}}
	afterCut.Calculate("2026-10", "2026-10")
	if afterCut.CarryOver != 0 || afterCut.Earned != 5000 {
		t.Errorf("indirim: devir 0, hakediş 5000 beklendi: %v / %v", afterCut.CarryOver, afterCut.Earned)
	}

	// Ücret geçmişi boşsa güncel ücret kullanılır.
	plain := PayrollSummaryRow{DailyWage: f(1000), WorkedDays: 2}
	plain.Calculate("2026-09", "2026-10")
	if plain.Earned != 2000 {
		t.Errorf("geçmiş yoksa güncel ücret: %v", plain.Earned)
	}
}

func TestWageForPeriod(t *testing.T) {
	rates := []WageRate{
		{EffectiveFrom: d("2026-05-10"), DailyWage: f(1000)},
		{EffectiveFrom: d("2026-08-31"), DailyWage: f(1200)},
		{EffectiveFrom: d("2026-09-01"), DailyWage: f(1300)},
	}
	for period, want := range map[string]float64{
		"2026-01": 1000, // ilk kayıttan önce: bilinen en eski ücret
		"2026-05": 1000, // ay içinde yürürlüğe giren, ayın sonunda geçerli
		"2026-07": 1000,
		"2026-08": 1200, // ayın son günü yürürlüğe giren o ayın tamamına
		"2026-09": 1300,
		"2027-01": 1300,
	} {
		_, daily, ok := WageForPeriod(rates, period)
		if !ok || daily == nil || *daily != want {
			t.Errorf("%s: %v beklendi, %v geldi", period, want, daily)
		}
	}
	if _, _, ok := WageForPeriod(nil, "2026-01"); ok {
		t.Error("boş geçmiş ok=false dönmeli")
	}
}
