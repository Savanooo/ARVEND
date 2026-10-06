package domain

import (
	"math"
	"regexp"
	"sort"
	"time"
)

// Ödeme türleri -- salary_payments_payment_type_check ile BİREBİR aynı küme.
const (
	PaymentTypeMaas  = "maaş"
	PaymentTypeAvans = "avans"
	PaymentTypeMesai = "mesai"
	PaymentTypePrim  = "prim"
	PaymentTypeDiger = "diğer"
)

var validPaymentTypes = map[string]bool{
	PaymentTypeMaas: true, PaymentTypeAvans: true, PaymentTypeMesai: true,
	PaymentTypePrim: true, PaymentTypeDiger: true,
}

func ValidPaymentType(t string) bool { return validPaymentTypes[t] }

// salary_payments_period_check ile aynı desen.
var periodPattern = regexp.MustCompile(`^[0-9]{4}-(0[1-9]|1[0-2])$`)

// ValidPeriod, 'YYYY-MM' biçiminde geçerli bir ay mı.
func ValidPeriod(p string) bool { return periodPattern.MatchString(p) }

// SalaryPayment, yapılmış bir maaş/avans/mesai/prim ödemesidir. "Ödenmedi"
// durumu yoktur: bir satır, gerçekleşmiş bir ödeme demektir (bkz. migration
// 0048 açıklaması).
type SalaryPayment struct {
	ID             string
	OrganizationID string
	EmployeeID     string
	EmployeeName   string
	Period         string // ödemenin ait olduğu ay, 'YYYY-MM'
	PaymentType    string
	Amount         float64
	PaidDate       time.Time // ödemenin yapıldığı gün
	Description    string
	CreatedAt      time.Time
}

// Ücret esası: personelin o ayki hakedişi neye göre hesaplandı.
const (
	WageBasisDaily   = "günlük" // yevmiye x çalışılan gün
	WageBasisMonthly = "aylık"  // sabit aylık maaş
	WageBasisNone    = ""       // ikisi de tanımsız -- hesaplanamaz
)

// WageRate, personelin bir tarihten itibaren geçerli ücretidir
// (employee_wage_history satırı, bkz. migration 0056).
type WageRate struct {
	EffectiveFrom time.Time
	Salary        *float64
	DailyWage     *float64
}

// WageForPeriod, `period` ayında geçerli ücreti seçer: AYIN SON GÜNÜ
// itibarıyla yürürlükte olan satır o ayın TAMAMINA uygulanır (ay içinde
// gün gün bölüştürme -- kıst -- yapılmaz; maaş bu projede zaten aylık
// kapanıyor ve aylık maaş "ayın tamamı" kuralıyla hesaplanıyor). Ayın
// sonundan önce yürürlüğe giren hiçbir satır yoksa (veri ilk ücret
// kaydından önceye ait) EN ESKİ satır kullanılır: geçmişe ait bilinen tek
// ücret odur. rates boşsa ok=false -- çağıran personelin güncel ücretine
// düşer.
func WageForPeriod(rates []WageRate, period string) (salary, dailyWage *float64, ok bool) {
	if len(rates) == 0 {
		return nil, nil, false
	}
	start, err := time.Parse("2006-01", period)
	if err != nil {
		return nil, nil, false
	}
	monthEnd := start.AddDate(0, 1, -1)
	earliest := rates[0]
	var chosen *WageRate
	for i := range rates {
		r := &rates[i]
		if dateOnly(r.EffectiveFrom).Before(dateOnly(earliest.EffectiveFrom)) {
			earliest = *r
		}
		if dateOnly(r.EffectiveFrom).After(monthEnd) {
			continue
		}
		if chosen == nil || dateOnly(r.EffectiveFrom).After(dateOnly(chosen.EffectiveFrom)) {
			chosen = r
		}
	}
	if chosen == nil {
		return earliest.Salary, earliest.DailyWage, true
	}
	return chosen.Salary, chosen.DailyWage, true
}

// dateOnly, takvim gününü saat/dilimden bağımsız karşılaştırmak içindir
// (date kolonları UTC gece yarısı gelir).
func dateOnly(t time.Time) time.Time {
	y, m, d := t.Date()
	return time.Date(y, m, d, 0, 0, 0, 0, time.UTC)
}

// PayrollSummaryRow, bir ayın ödeme tablosunda personel başına bir satırdır.
// İlk blok veritabanından gelir (PayrollSummaryByPeriod, ücret geçmişi ve
// devir için PayrollHistoryBefore), ikinci blok Calculate ile doldurulur.
type PayrollSummaryRow struct {
	EmployeeID string
	FullName   string
	Position   string
	// Salary/DailyWage: veritabanından personelin GÜNCEL ücreti gelir;
	// Calculate bunları o ayda geçerli ücretle değiştirir (Wages doluysa) --
	// ekranda ve PDF'te görünen ücret hesabın kullandığı ücrettir.
	Salary       *float64
	DailyWage    *float64
	StartDate    *time.Time // işe giriş; aylık maaş bu aydan önce işlemez
	IsActive     bool
	WorkedDays   float64 // geldi = 1, yarım gün = 0.5
	WorkHours    float64
	PaidTotal    float64 // bu aya ait TÜM ödemeler
	SalaryPaid   float64 // bunların maaş/avans/mesai olanları -- kalandan düşülen
	PaymentCount int
	// Wages, personelin ücret geçmişi (bkz. WageForPeriod). Boşsa her ay
	// için güncel ücret kullanılır.
	Wages []WageRate
	// History, bu aydan ÖNCEKİ ayların ham toplamlarıdır (devir zinciri
	// için). Yalnızca ilk maaş/avans/mesai ödemesinin yapıldığı aydan
	// itibaren gelir -- ondan önce devredecek bir şey yoktur.
	History []PayrollMonth

	WageBasis string
	Earned    float64 // hesaplanan hakediş
	CarryOver float64 // önceki ayların fazla ödemesi, bu aydan düşülür
	Remaining float64 // ödenecek; eksi ise fazla ödendi (sonraki aya devreder)
}

// PayrollMonth, bir personelin geçmiş bir ayının ham toplamlarıdır.
type PayrollMonth struct {
	Period     string // 'YYYY-MM'
	WorkedDays float64
	SalaryPaid float64 // maaş/avans/mesai -- prim/diğer hariç
}

// EarnedFor, BYZ'nin calculate_salary kuralıdır (taşınan rakamlar BYZ'de
// görülenle aynı çıksın diye birebir): yevmiye tanımlıysa yevmiye x
// çalışılan gün, değilse aylık maaşın tamamı. İkisi de doluysa YEVMİYE
// esastır (BYZ'den gelen personelin hepsinde ikisi de dolu).
func EarnedFor(salary, dailyWage *float64, workedDays float64) (float64, string) {
	if dailyWage != nil && *dailyWage > 0 {
		return roundKurus(*dailyWage * workedDays), WageBasisDaily
	}
	if salary != nil && *salary > 0 {
		return roundKurus(*salary), WageBasisMonthly
	}
	return 0, WageBasisNone
}

// MonthlySalaryDue, aylık maaşın o ay için borç olup olmadığını söyler.
// Aylık maaş çalışılan günden bağımsız "ayın tamamı" sayıldığı için iki ay
// türünde borç yazılmaz: işe girişten (start_date) ÖNCEKİ aylar ve henüz
// gelmemiş aylar (currentPeriod'dan sonrası). Aksi hâlde ekimde işe giren
// birinin eylül satırı ve takvimde ileri gidilen her ay tam maaş "kalan"
// gösterirdi. currentPeriod boşsa ileri ay sınırı uygulanmaz. Yevmiyeli
// personelde soru anlamsızdır (hakediş puantajdan gelir).
func MonthlySalaryDue(period string, startDate *time.Time, currentPeriod string) bool {
	if currentPeriod != "" && period > currentPeriod {
		return false
	}
	if startDate != nil && period < startDate.Format("2006-01") {
		return false
	}
	return true
}

// earnedInMonth, bir ayın hakedişini o ayda GEÇERLİ ücretle hesaplar.
// Aylık maaş borç olmayan bir ayda (bkz. MonthlySalaryDue) 0 hakediş verir
// ama esas "aylık" kalır -- o aya yapılmış bir ödeme fazla ödeme sayılıp
// devreder.
func (r *PayrollSummaryRow) earnedInMonth(period string, workedDays float64, currentPeriod string) (earned float64, basis string, salary, dailyWage *float64) {
	salary, dailyWage = r.Salary, r.DailyWage
	if s, d, ok := WageForPeriod(r.Wages, period); ok {
		salary, dailyWage = s, d
	}
	earned, basis = EarnedFor(salary, dailyWage, workedDays)
	if basis == WageBasisMonthly && !MonthlySalaryDue(period, r.StartDate, currentPeriod) {
		earned = 0
	}
	return earned, basis, salary, dailyWage
}

// carryOverInto, `period` ayına devreden fazla ödemeyi hesaplar. Devir
// ZİNCİRLEME işler:
//
//	devir(ay) = max(0, ödenen(önceki ay) + devir(önceki ay) − hakediş(önceki ay))
//
// Eskiden yalnızca bir önceki ayın "ödenen − hakediş" farkına bakılıyordu;
// bir ayı tüketmeye yetmeyen fazla ödeme (ör. yevmiye 1000, N ayında 10
// gün + 30.000 avans: 20.000 fazla; N+1'de 10 gün, ödeme yok -> 20.000
// devir, kalan −10.000) N+2'de sıfırlanıyor ve 10.000 TL kayboluyordu --
// ekran ise "sonraki aya devreder" diyordu. Eksik ödeme yine taşınmaz (o
// ayın kendi satırında "kalan" olarak durur) -- max(0, …) bunu sağlar.
//
// Her ayın hakedişi O AYDA geçerli ücretle hesaplanır: ekimdeki zam,
// tamamı ödenmiş eylülü "eksik ödendi"ye çevirmez. Arada kaydı olmayan
// aylar da sayılır (yevmiyelide hakediş 0, aylıkta maaş -- borç olan
// aylarda). Ücreti tanımsız bir ay zinciri değiştirmez: hakedişi
// hesaplanamayan ayın ödemesi fazla ödeme sayılmaz.
func (r *PayrollSummaryRow) carryOverInto(period, currentPeriod string) float64 {
	byPeriod := make(map[string]PayrollMonth, len(r.History))
	months := make([]string, 0, len(r.History))
	for _, m := range r.History {
		if m.Period >= period || !ValidPeriod(m.Period) {
			continue
		}
		byPeriod[m.Period] = m
		months = append(months, m.Period)
	}
	if len(months) == 0 {
		return 0
	}
	sort.Strings(months)
	carry := 0.0
	for p := months[0]; p < period; p = nextPeriod(p) {
		m := byPeriod[p]
		earned, basis, _, _ := r.earnedInMonth(p, m.WorkedDays, currentPeriod)
		if basis == WageBasisNone {
			continue
		}
		carry = roundKurus(math.Max(0, m.SalaryPaid+carry-earned))
	}
	return carry
}

// nextPeriod: "2025-12" -> "2026-01". Geçersiz girişte döngüyü bitirmek
// için "9999-99" döner (her geçerli aydan büyük).
func nextPeriod(p string) string {
	t, err := time.Parse("2006-01", p)
	if err != nil {
		return "9999-99"
	}
	return t.AddDate(0, 1, 0).Format("2006-01")
}

// Calculate, `period` ayı için hesaplanan / devir / kalan alanlarını
// doldurur. currentPeriod, İstanbul takvimine göre içinde bulunulan aydır
// (ileri aylarda aylık maaş borç yazılmaz, bkz. MonthlySalaryDue).
//
// Ücreti tanımsız personelde hiçbir şey hesaplanmaz: hakediş 0 sayılsaydı
// yapılan her ödeme "fazla ödeme" görünür ve sonraki aya devrederdi.
func (r *PayrollSummaryRow) Calculate(period, currentPeriod string) {
	earned, basis, salary, dailyWage := r.earnedInMonth(period, r.WorkedDays, currentPeriod)
	carry := 0.0
	if basis != WageBasisNone {
		carry = r.carryOverInto(period, currentPeriod)
	}
	r.Salary, r.DailyWage = salary, dailyWage
	r.Earned, r.WageBasis = earned, basis
	if basis == WageBasisNone {
		r.CarryOver, r.Remaining = 0, 0
		return
	}
	r.CarryOver = carry
	r.Remaining = roundKurus(earned - r.SalaryPaid - r.CarryOver)
}

// roundKurus, kuruşa yuvarlar. subcontract.go'daki round2 burada
// KULLANILMAZ: o yalnızca artı değerler için yazılmış (int64(v*100+0.5) eksi
// sayıyı yanlış yuvarlar: -500 -> -499.99), "kalan" ise fazla ödemede eksidir.
func roundKurus(v float64) float64 { return math.Round(v*100) / 100 }
