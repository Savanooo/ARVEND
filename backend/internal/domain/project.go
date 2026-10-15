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
	// NewSubcontractPaid, yeni modül (taşeron sözleşmesi) ödemeleridir --
	// SubcontractorPaid yalnızca eski (legacy) taşeron kayıtlarını taşır;
	// finans özetindeki new_subcontract_paid İLE AYNI.
	NewSubcontractPaid float64
	// RealizedCostTotal: gerçekleşen maliyet, finans özetiyle AYNI görünümden
	// (project_cost_basis): onaylı masraflar + basit taşeronun iş ödemeleri +
	// sözleşmeli taşeronun onaylı işi. Ödemelerin toplamı DEĞİLDİR (açık
	// avans hariç, ödenmemiş onaylı hakediş dahil).
	RealizedCostTotal float64
	InvoiceCount      int64
	PaidInvoiceCount  int64
	// ChangeOrderNet, onaylı ek işler/eksiltmelerin işaretli net etkisidir
	// (ek iş: +, eksiltme: -). "Güncel proje bedeli" = ContractAmount +
	// ChangeOrderNet -- projects tablosunda TUTULMAZ (bkz. Faz 8, 0027
	// migration).
	ChangeOrderNet float64
	// KDV (finans özetiyle AYNI kaynaklar): ExpenseVATTotal onaylı, iptal
	// edilmemiş masrafların içindeki KDV; ContractVATAmount güncel proje
	// bedelinin içindeki KDV (kaynak revizyon + onaylı ek işler -
	// eksiltmeler); ContractVATKnown bedelin KDV'sinin bilinip bilinmediği.
	// KDV hariç maliyet/kâr bunlardan domain.VATBasis ile türetilir.
	ExpenseVATTotal   float64
	ContractVATAmount float64
	ContractVATKnown  bool
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
// bir TÜRETME'dir (Faz 8). Go'daki toplamlar kuruşa yuvarlanır: finans
// özetinin SQL numeric sonucuyla BİREBİR aynı float64 çıkar.
func (p Project) CurrentContractValue() float64 {
	return roundKurus(p.ContractAmount + p.ChangeOrderNet)
}

// RemainingReceivable, bakiyedir; negatif olabilir (fazla tahsilat).
// Faz 8'den beri GÜNCEL proje bedeli (ana sözleşme + onaylı ek işler)
// üzerinden hesaplanır -- ana sözleşmenin kendisi üzerinden değil.
func (p Project) RemainingReceivable() float64 {
	return roundKurus(p.CurrentContractValue() - p.CollectedAmount)
}

// RealizedCost/RealizedGrossProfit, liste satırı için gerçekleşen
// maliyet ve kârdır (KDV DAHİL) -- finans özetinin realized_cost/
// realized_gross_profit'iyle aynı kaynak (project_cost_basis, migration 0073).
func (p Project) RealizedCost() float64 {
	return roundKurus(p.RealizedCostTotal)
}

func (p Project) RealizedGrossProfit() float64 {
	return roundKurus(p.CurrentContractValue() - p.RealizedCost())
}

// KDV hariç karşılıklar -- finans özetinin realized_cost_net/
// current_contract_value_net/realized_gross_profit_net'iyle AYNI kural
// (domain.VATBasis): kâr "net"i, bedelin KDV'si bilinmiyorsa KDV dahil
// maliyetle hesaplanır.
func (p Project) contractVATBasis() VATBasis {
	return VATBasis{Value: p.CurrentContractValue(), VAT: p.ContractVATAmount, Known: p.ContractVATKnown}
}

func (p Project) CurrentContractValueNet() float64 { return p.contractVATBasis().Net() }

func (p Project) RealizedCostNet() float64 { return CostNet(p.RealizedCost(), p.ExpenseVATTotal) }

func (p Project) RealizedGrossProfitNet() float64 {
	return p.contractVATBasis().ProfitNet(p.RealizedCost(), p.RealizedCostNet())
}

// ProjectDeleteRequest: projeyi düzenleyebilen ama silme izni olmayan
// kişinin açtığı, projects.delete sahibinin kararını bekleyen talep
// (migration 0070). Onaylanınca projeyle birlikte silinir.
type ProjectDeleteRequest struct {
	ID              string
	ProjectID       string
	RequestedBy     *string
	RequestedByName string
	Reason          string
	CreatedAt       time.Time

	// Liste görünümü için proje özeti.
	ProjectNo    string
	ProjectName  string
	CustomerName string
}

// ProjectDeleted: proje silindiğinde (organization_events) ve kaynak
// teklifin zaman çizelgesinde yazılan olay.
const OrgEventProjectDeleted = "project_deleted"
