package domain

import "time"

const (
	ProjectStatusPlanned   = "planned"
	ProjectStatusActive    = "active"
	ProjectStatusPaused    = "paused"
	ProjectStatusCompleted = "completed"
	ProjectStatusCancelled = "cancelled"
)

var validProjectStatuses = map[string]bool{
	ProjectStatusPlanned:   true,
	ProjectStatusActive:    true,
	ProjectStatusPaused:    true,
	ProjectStatusCompleted: true,
	ProjectStatusCancelled: true,
}

func ValidProjectStatus(s string) bool {
	return validProjectStatuses[s]
}

// projectTransitions, hangi durumdan hangilerine geçilebileceğini tanımlar.
// "completed" ve "cancelled" uç (terminal) durumlardır: bir proje bittiyse
// ya da iptal edildiyse geri açılmaz -- yanlışlıkla tamamlanmış bir projeyi
// düzeltmek gerekirse bu bilinçli bir karar olmalı, sessiz bir durum
// değişikliği değil.
var projectTransitions = map[string][]string{
	ProjectStatusPlanned:   {ProjectStatusActive, ProjectStatusPaused, ProjectStatusCancelled},
	ProjectStatusActive:    {ProjectStatusPaused, ProjectStatusCompleted, ProjectStatusCancelled},
	ProjectStatusPaused:    {ProjectStatusActive, ProjectStatusCompleted, ProjectStatusCancelled},
	ProjectStatusCompleted: {},
	ProjectStatusCancelled: {},
}

// CanTransitionProjectStatus, aynı duruma geçişi (no-op güncelleme) her
// zaman kabul eder; aksi halde yalnızca tanımlı geçişlere izin verir.
func CanTransitionProjectStatus(from, to string) bool {
	if from == to {
		return true
	}
	for _, allowed := range projectTransitions[from] {
		if allowed == to {
			return true
		}
	}
	return false
}

// Project, kabul edilmiş bir teklif revizyonundan doğan iştir. Müşteri
// bilgileri ve ContractAmount, kaynak revizyondan alınmış DONDURULMUŞ
// anlık görüntülerdir -- teklif tarafında sonradan ne olursa olsun proje
// bunlardan etkilenmez.
type Project struct {
	ID               string
	OrganizationID   string
	ProjectNo        string
	Name             string
	ProjectType      string
	SourceOfferID    string
	SourceRevisionID string
	CustomerID       *string
	CustomerName     string
	CustomerPhone    string
	CustomerEmail    string
	CustomerAddress  string
	ContractAmount   float64
	Currency         string
	Status           string
	StartDate        *time.Time
	EndDate          *time.Time
	Description      string
	InternalNotes    string
	CreatedBy        *string
	CreatedAt        time.Time
	UpdatedAt        time.Time

	// Liste/detay görünümü için kaynak teklifden doldurulan alanlar --
	// projects tablosunda tutulmaz, JOIN ile gelir.
	SourceOfferNo    string
	SourceRevisionNo int
}
