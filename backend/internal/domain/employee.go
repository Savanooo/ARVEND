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
