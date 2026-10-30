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
	// AIImageKindEdit (migration 0080): fotoğrafa serbest düzenleme
	// talimatı ("duvarı griye boya") -- stüdyoda ve proje ucunda; kaynak ve
	// açıklama zorunlu, bitmiş hali gibi.
	AIImageKindEdit = "edit"
)

// validAIImageKinds: proje ucu ve stüdyo aynı türleri kabul eder; eski
// uygulamalar 'edit' göndermez, gönderdikleri türlerin davranışı değişmedi.
var validAIImageKinds = map[string]bool{
	AIImageKindBeforeAfter: true, AIImageKindEnhance: true, AIImageKindGenerate: true, AIImageKindEdit: true,
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
	// ProjectID: proje işinde dolu; "" = Yapay Zekâ Stüdyo işi (0080).
	ProjectID     string
	UserID        *string
	Kind          string
	Prompt        string
	SourcePhotoID *string
	// SourceStorageKey/SourceMIME: stüdyo işinin depodaki kaynak görseli
	// (yüklenen ya da proje fotoğrafından kopyalanan); proje işinde boş.
	SourceStorageKey string
	SourceMIME       string
	// MaskStorageKey: maskeli 'edit' işinde kişinin boyadığı alan (PNG,
	// saydam = değişecek yer); denetim için saklanır.
	MaskStorageKey string
	Status         string
	// Error: kullanıcıya gösterilen Türkçe neden (yalnızca failed).
	Error         string
	ResultPhotoID *string
	// StudioImageID: bitmiş stüdyo işinin görseli (yalnızca stüdyo okumasında dolu).
	StudioImageID *string
	Model         string
	CreatedAt     time.Time
	StartedAt     *time.Time
	FinishedAt    *time.Time
}

// IsStudio: proje dışı (Yapay Zekâ Stüdyo) iş -- sonuç stüdyo görseli olur,
// projeye fotoğraf eklenmez.
func (j AIImageJob) IsStudio() bool { return j.ProjectID == "" }

// AIStudioImage: Yapay Zekâ Stüdyo görseli (migration 0080). Kişinin kendi
// alanındadır; Projects yalnızca listede dolar.
type AIStudioImage struct {
	ID             string
	OrganizationID string
	UserID         *string
	UserName       string
	JobID          *string
	StorageKey     string
	MIMEType       string
	SizeBytes      int64
	Kind           string
	Prompt         string
	CreatedAt      time.Time
	Projects       []AIStudioImageProject
}

// AIStudioImageProject: görselin "Projeye ekle" ile kopyalandığı proje.
type AIStudioImageProject struct {
	ProjectID      string
	ProjectName    string
	ProjectPhotoID string
}

// AIImageQuota: firmanın bu ayki görsel hakkı (İstanbul takvim ayı).
type AIImageQuota struct {
	MonthlyLimit    int
	UsedThisMonth   int
	Remaining       int
	UserHourlyLimit int
	// ResetsAt: yeni hakkın açıldığı an (gelecek ayın ilk günü 00:00 İstanbul).
	ResetsAt time.Time
	// Kişinin kendi aylık hakkı (Yapay Zekâ Ayarları, 0081). UserMonthlyLimit
	// nil = kişi sınırı yok (UserRemaining da nil).
	UserMonthlyLimit  *int
	UserUsedThisMonth int
	UserRemaining     *int
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
	// Enabled = ServerEnabled VE FirmEnabled (eski uygulamalar yalnızca buna bakar).
	Enabled       bool
	ServerEnabled bool
	// FirmEnabled: Yapay Zekâ Ayarları'ndaki firma anahtarı (0081).
	FirmEnabled bool
	CanUse      bool
	// BlockedCode/BlockedReason: kişi şu an iş açamıyorsa nedeni (yönetici
	// kapattı, firmanın ya da kişinin aylık hakkı doldu); boş = açabilir.
	BlockedCode   string
	BlockedReason string
	Model         string
	Quota         *AIImageQuota
	UsageByUser   []AIImageUsage
}

// AISettings: Yapay Zekâ Ayarları (migration 0081) -- yöneticinin ekranı.
// MonthlyLimit/PerUserMonthlyLimit kayıtlı değerdir (nil = sunucu
// varsayılanı / sınırsız); EffectiveMonthlyLimit sunucu tavanına kırpılmış
// gerçek sınır.
type AISettings struct {
	Enabled               bool
	MonthlyLimit          *int
	EffectiveMonthlyLimit int
	ServerMax             int
	PerUserMonthlyLimit   *int
	UsedThisMonth         int
	ResetsAt              time.Time
	Users                 []AISettingsUser
}

// AISettingsUser.Source: etkin iznin nereden geldiği.
const (
	AIAccessSourceRole          = "role"
	AIAccessSourceOverrideAllow = "override_allow"
	AIAccessSourceOverrideDeny  = "override_deny"
)

type AISettingsUser struct {
	UserID        string
	FullName      string
	RoleCode      string
	RoleName      string
	IsOwner       bool
	CanUse        bool
	Source        string
	UsedThisMonth int
}
