package domain

import "time"

// Yapay zekâ görsel işleri (migration 0079; bkz. service/ai_image_service.go).
// Türler migration'daki CHECK kısıtlarıyla birebir aynıdır.
const (
	// AIImageKindBeforeAfter: şantiye/oda fotoğrafı + kısa açıklamadan
	// işin bitmiş halinin görseli ("önce/sonra", müşteriye göstermek için).
	AIImageKindBeforeAfter = "before_after"
	// AIImageKindEnhance: karanlık/bulanık fotoğrafı aydınlatma, netleştirme
	// -- içerik değişmez.
	AIImageKindEnhance = "enhance"
	// AIImageKindGenerate: açıklamadan yeni görsel (isteğe bağlı referans
	// fotoğrafla).
	AIImageKindGenerate = "generate"
)

var validAIImageKinds = map[string]bool{
	AIImageKindBeforeAfter: true, AIImageKindEnhance: true, AIImageKindGenerate: true,
}

func ValidAIImageKind(k string) bool { return validAIImageKinds[k] }

const (
	AIImageJobQueued  = "queued"
	AIImageJobRunning = "running"
	AIImageJobDone    = "done"
	AIImageJobFailed  = "failed"
)

type AIImageJob struct {
	ID             string
	OrganizationID string
	ProjectID      string
	UserID         *string
	Kind           string
	Prompt         string
	SourcePhotoID  *string
	Status         string
	// Error: kullanıcıya gösterilen Türkçe neden (yalnızca failed).
	Error         string
	ResultPhotoID *string
	Model         string
	CreatedAt     time.Time
	StartedAt     *time.Time
	FinishedAt    *time.Time
}

// AIImageQuota: firmanın bu ayki görsel hakkı (İstanbul takvim ayı).
type AIImageQuota struct {
	MonthlyLimit    int
	UsedThisMonth   int
	Remaining       int
	UserHourlyLimit int
	// ResetsAt: yeni hakkın açıldığı an (gelecek ayın ilk günü 00:00 İstanbul).
	ResetsAt time.Time
}

// AIImageUsage: bu ay bir kişinin ürettiği görsel sayısı.
type AIImageUsage struct {
	UserID   *string
	FullName string
	Images   int
}

// AIImageStatus: uygulamanın girişleri göstermesi için. Enabled sunucuda
// anahtar ayarlı mı; CanUse kişinin izni var mı. Quota yalnızca izni olana
// (ya da Sahip/Yönetici'ye), UsageByUser yalnızca Sahip/Yönetici'ye döner.
type AIImageStatus struct {
	Enabled     bool
	CanUse      bool
	Model       string
	Quota       *AIImageQuota
	UsageByUser []AIImageUsage
}
