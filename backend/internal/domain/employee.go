package domain

import "time"

type Employee struct {
	ID             string
	OrganizationID string
	FullName       string
	Phone          string
	Position       string
	Salary         *float64
	DailyWage      *float64
	StartDate      *time.Time
	IsActive       bool
	Description    string
	CreatedAt      time.Time
	UpdatedAt      time.Time
	// UserID, bu personelin bağlı olduğu login hesabıdır (nullable — çoğu
	// personel kaydı bağlantısız kalabilir). Otomatik ad/e-posta/telefon
	// eşleştirmesiyle DOLDURULMAZ, yalnızca açık bir yönetici eylemiyle
	// bağlanır (bkz. EmployeeService.Create/Update). GET /tasks/mine'ın
	// "bana ATANAN görevler" anlamının TEK kaynağıdır.
	UserID *string
	// Login*, bağlı giriş hesabının özetidir (kullanıcı adı, aktif mi,
	// silinmiş mi) -- personel ekranında bağın görünmesi için. Yalnızca
	// EmployeeService.List/Get doldurur, UserID nil ise boştur.
	LoginUsername string
	LoginActive   bool
	LoginDeleted  bool
}

const (
	AttendanceGeldi    = "geldi"
	AttendanceYarimGun = "yarım gün"
	AttendanceGelmedi  = "gelmedi"
	AttendanceIzinli   = "izinli"
)

var validAttendanceStatuses = map[string]bool{
	AttendanceGeldi:    true,
	AttendanceYarimGun: true,
	AttendanceGelmedi:  true,
	AttendanceIzinli:   true,
}

func ValidAttendanceStatus(s string) bool {
	return validAttendanceStatuses[s]
}

type AttendanceLog struct {
	ID             string
	OrganizationID string
	EmployeeID     string
	EmployeeName   string
	Date           time.Time
	CheckIn        string
	CheckOut       string
	WorkHours      float64
	Status         string
	Note           string
	CreatedAt      time.Time
}
