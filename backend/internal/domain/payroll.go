package domain

import (
	"math"
	"regexp"
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

// PayrollSummaryRow, bir ayın ödeme tablosunda personel başına bir satırdır.
// İlk blok veritabanından gelir (PayrollSummaryByPeriod), ikinci blok
// Calculate ile doldurulur.
type PayrollSummaryRow struct {
	EmployeeID     string
	FullName       string
	Position       string
	Salary         *float64
	DailyWage      *float64
	IsActive       bool
	WorkedDays     float64 // geldi = 1, yarım gün = 0.5
	WorkHours      float64
	PaidTotal      float64 // bu aya ait TÜM ödemeler
	SalaryPaid     float64 // bunların maaş/avans/mesai olanları -- kalandan düşülen
	PaymentCount   int
	PrevWorkedDays float64 // bir önceki ay -- devir hesabı için
	PrevSalaryPaid float64

	WageBasis string
	Earned    float64 // hesaplanan hakediş
	CarryOver float64 // önceki ayın fazla ödemesi, bu aydan düşülür
	Remaining float64 // ödenecek; eksi ise fazla ödendi (sonraki aya devreder)
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

// Calculate, hesaplanan / devir / kalan alanlarını doldurur.
//
// Devir yalnızca FAZLA ödemeyi taşır ve yalnızca bir önceki aya bakar (BYZ
// get_carry_over ile aynı): geçen ay hakedişten fazla ödendiyse fark bu
// aydan düşülür. Eksik ödeme taşınmaz -- o ayın kendi satırında "kalan"
// olarak görünmeye devam eder.
//
// Ücreti tanımsız personelde hiçbir şey hesaplanmaz: hakediş 0 sayılsaydı
// yapılan her ödeme "fazla ödeme" görünür ve sonraki aya devrederdi.
func (r *PayrollSummaryRow) Calculate() {
	earned, basis := EarnedFor(r.Salary, r.DailyWage, r.WorkedDays)
	r.Earned, r.WageBasis = earned, basis
	if basis == WageBasisNone {
		r.CarryOver, r.Remaining = 0, 0
		return
	}
	prevEarned, _ := EarnedFor(r.Salary, r.DailyWage, r.PrevWorkedDays)
	r.CarryOver = roundKurus(math.Max(0, r.PrevSalaryPaid-prevEarned))
	r.Remaining = roundKurus(earned - r.SalaryPaid - r.CarryOver)
}

// roundKurus, kuruşa yuvarlar. subcontract.go'daki round2 burada
// KULLANILMAZ: o yalnızca artı değerler için yazılmış (int64(v*100+0.5) eksi
// sayıyı yanlış yuvarlar: -500 -> -499.99), "kalan" ise fazla ödemede eksidir.
func roundKurus(v float64) float64 { return math.Round(v*100) / 100 }
