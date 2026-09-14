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
// "cancelled" uç (terminal) durumdur. "completed" geri alınabilir ama
// yalnızca "active"e: tamamlanmış projede finans hareketleri kilitlidir,
// hareket girmek gerekiyorsa proje bilinçli olarak yeniden açılır.
var projectTransitions = map[string][]string{
	ProjectStatusPlanned: {ProjectStatusActive, ProjectStatusPaused, ProjectStatusCancelled},
	ProjectStatusActive:  {ProjectStatusPaused, ProjectStatusCompleted, ProjectStatusCancelled},
	ProjectStatusPaused:  {ProjectStatusActive, ProjectStatusCompleted, ProjectStatusCancelled},
	// Tamamlanmış bir proje, finans hareketi girmek için bilinçli olarak
	// yeniden "active" yapılabilir (Faz 6: completed projede hareketler
	// varsayılan olarak kilitlidir, yeniden açılırsa girilebilir).
	ProjectStatusCompleted: {ProjectStatusActive},
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

	// Liste ekranının finans kolonları. projects tablosunda TUTULMAZ;
	// ListProjects sorgusunda hareket tablolarından toplanır (N+1 yok).
	CollectedAmount        float64
	TotalExpenses          float64
	SubcontractorPaid      float64
	SubcontractorRemaining float64
	InvoiceCount           int64
	PaidInvoiceCount       int64
	// ChangeOrderNet, onaylı ek işler/eksiltmelerin işaretli net etkisidir
	// (ek iş: +, eksiltme: -). "Güncel proje bedeli" = ContractAmount +
	// ChangeOrderNet -- projects tablosunda TUTULMAZ (bkz. Faz 8, 0027
	// migration).
	ChangeOrderNet float64
	// HasFinanceAggregates, yukarıdaki finans kolonlarının GERÇEKTEN
	// doldurulduğunu söyler -- yalnızca liste sorgusundan (ListProjects)
	// gelen satırlarda true'dur. Tekil okuma yollarında (Get/GetByOffer/
	// Create/Update) bu alanlar SIFIR kalır çünkü hiç sorgulanmazlar;
	// bu bayrak olmadan API yanıtı "gerçek sıfır" ile "hiç hesaplanmadı"
	// durumunu ayırt edemez ve yanlış finans bilgisi sızdırabilirdi
	// (bkz. denetim bulgusu: detay ucu tüm finans alanlarını 0 olarak
	// dönüyordu, oysa gerçek değerler farklıydı).
	HasFinanceAggregates bool
}

// CurrentContractValue, ana sözleşme bedeline onaylı ek iş/eksiltmelerin
// net etkisini ekler. ContractAmount kendisi ASLA değişmez; bu yalnızca
// bir TÜRETME'dir (Faz 8).
func (p Project) CurrentContractValue() float64 { return p.ContractAmount + p.ChangeOrderNet }

// RemainingReceivable, bakiyedir; negatif olabilir (fazla tahsilat).
// Faz 8'den beri GÜNCEL proje bedeli (ana sözleşme + onaylı ek işler)
// üzerinden hesaplanır -- ana sözleşmenin kendisi üzerinden değil.
func (p Project) RemainingReceivable() float64 { return p.CurrentContractValue() - p.CollectedAmount }

// RealizedCost/RealizedGrossProfit, liste satırı için gerçekleşen
// maliyet ve kârdır -- özet uçtaki (SQL'de hesaplanan) tanımla birebir
// aynı formül.
func (p Project) RealizedCost() float64 { return p.TotalExpenses + p.SubcontractorPaid }

func (p Project) RealizedGrossProfit() float64 { return p.CurrentContractValue() - p.RealizedCost() }
