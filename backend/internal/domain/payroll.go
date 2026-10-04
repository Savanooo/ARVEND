package domain

import (
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

// PayrollSummaryRow, bir ayın ödeme tablosunda personel başına bir satırdır.
// Kalan borç bilerek HESAPLANMAZ -- bkz. PayrollSummaryByPeriod sorgusu.
type PayrollSummaryRow struct {
	EmployeeID   string
	FullName     string
	Position     string
	Salary       *float64
	DailyWage    *float64
	IsActive     bool
	WorkedDays   float64 // geldi = 1, yarım gün = 0.5
	WorkHours    float64
	PaidTotal    float64
	PaymentCount int
}
