package domain

// Ana sayfa özeti (GET /api/v1/dashboard) -- web ve mobilin ORTAK
// sözleşmesi. Alan adları/json etiketleri docs/dashboard/fixtures/*.json
// ile BİREBİR aynıdır (bkz. service/dashboard_contract_test.go:
// fixture'lar DisallowUnknownFields ile bu tiplere çözülür ve geri
// yazıldığında aynı JSON'u vermelidir).
//
// Kurallar (spec §4.4):
//   - Yetkisi olmayan bölümün anahtarı "sections" içinde HİÇ yoktur
//     (sıfırlarla doldurulmaz); bölüm içindeki izne bağlı alt blok null'dır.
//   - Diziler asla null değildir ([]); null olabilen dizi yalnızca
//     sözleşmede "| null" yazan alanlardır (ör. committed_active).
//   - Para JSON number'dır (numeric(18,2) -> float64 taşıma); istemciler
//     toplama/yeniden hesaplama YAPMAZ, yalnızca biçimlendirir.
//   - Farklı para birimleri ASLA toplanmaz: by_currency dizileri sunucuda
//     birincil para birimi önce, sonra ana tutar azalan sıralanır.

// ---------- Bölüm anahtarları ----------

const (
	DashSectionFinance       = "finance"
	DashSectionOffers        = "offers"
	DashSectionChangeOrders  = "change_orders"
	DashSectionProjects      = "projects"
	DashSectionTasks         = "tasks"
	DashSectionOperations    = "operations"
	DashSectionContracts     = "contracts"
	DashSectionAttendance    = "attendance"
	DashSectionProcurement   = "procurement"
	DashSectionSubcontracts  = "subcontracts"
	DashSectionCostControl   = "cost_control"
	DashSectionCustomers     = "customers"
	DashSectionEmployees     = "employees"
	DashSectionProducts      = "products"
	DashSectionUsers         = "users"
	DashSectionCalculations  = "calculations"
	DashSectionSuppliers     = "suppliers"
	DashSectionCostCodes     = "cost_codes"
	DashSectionNotifications = "notifications"
	DashSectionActivity      = "activity"
)

// DashboardSectionKeys, 20 bölümün tamamı (18 modül kartı + bildirimler +
// son hareketler), sunucunun çalıştırma sırasıyla.
var DashboardSectionKeys = []string{
	DashSectionProjects, DashSectionFinance, DashSectionChangeOrders, DashSectionOffers,
	DashSectionProcurement, DashSectionSubcontracts, DashSectionCostControl, DashSectionContracts,
	DashSectionTasks, DashSectionOperations, DashSectionAttendance, DashSectionEmployees,
	DashSectionCustomers, DashSectionProducts, DashSectionCalculations, DashSectionSuppliers,
	DashSectionCostCodes, DashSectionUsers, DashSectionNotifications, DashSectionActivity,
}

// DashSectionFailed, section_errors değerlerinin TEK geçerli değeridir.
const DashSectionFailed = "section_failed"

// ---------- Ref (istemci rotasına çevrilen nötr bağlantı) ----------

const (
	RefKindProject                = "project"
	RefKindProjectFinance         = "project_finance"
	RefKindProjectCost            = "project_cost"
	RefKindProjectOperations      = "project_operations"
	RefKindOffer                  = "offer"
	RefKindTask                   = "task"
	RefKindMilestone              = "milestone"
	RefKindPurchaseRequest        = "purchase_request"
	RefKindRFQ                    = "rfq"
	RefKindPurchaseOrder          = "purchase_order"
	RefKindSubcontract            = "subcontract"
	RefKindProgressClaim          = "progress_claim"
	RefKindSubcontractChangeOrder = "subcontract_change_order"
	RefKindChangeOrder            = "change_order"
	RefKindBudgetAdjustment       = "budget_adjustment"
	RefKindContract               = "contract"
	RefKindPaymentPlanItem        = "payment_plan_item"
	RefKindInvoice                = "invoice"
	RefKindCustomer               = "customer"
	RefKindProduct                = "product"
	RefKindUser                   = "user"
	RefKindPriceSource            = "price_source"
)

const (
	RefActionOpen    = "open"
	RefActionAward   = "award"
	RefActionConvert = "convert"
)

// DashboardRef: sunucu ASLA web/mobil yolu göndermez; istemciler
// webHrefFor/mobileRouteFor ile çevirir. parent_id, taşeron hakedişi ve
// taşeron değişiklik emri için sözleşme (subcontract) kimliğidir; fiyat
// kaynağında id = "ulas" | "demirprofil".
type DashboardRef struct {
	Kind      string  `json:"kind"`
	ID        string  `json:"id"`
	ProjectID *string `json:"project_id"`
	ParentID  *string `json:"parent_id"`
	Action    string  `json:"action"`
}

// ---------- Ortak para tipleri ----------

type MoneyAmount struct {
	Currency string  `json:"currency"`
	Amount   float64 `json:"amount"`
}

// CountAmount: tek para birimli bağlam (by_currency satırının içinde).
type CountAmount struct {
	Count  int     `json:"count"`
	Amount float64 `json:"amount"`
}

// CountAmounts: çok para birimli bağlam; Count 0 ise Amounts [].
type CountAmounts struct {
	Count   int           `json:"count"`
	Amounts []MoneyAmount `json:"amounts"`
}

// ---------- Yanıt ----------

type Dashboard struct {
	GeneratedAt     string               `json:"generated_at"`
	Today           string               `json:"today"`
	Timezone        string               `json:"timezone"`
	IsWorkday       bool                 `json:"is_workday"`
	Period          DashboardPeriod      `json:"period"`
	PrimaryCurrency string               `json:"primary_currency"`
	Viewer          DashboardViewer      `json:"viewer"`
	Onboarding      *DashboardOnboarding `json:"onboarding"`
	Agenda          DashboardAgenda      `json:"agenda"`
	Sections        DashboardSections    `json:"sections"`
	// SectionErrors: yalnızca İZNİ OLAN ama o an hesaplanamayan bölümler
	// (değer her zaman DashSectionFailed). İzni olmayan bölüm burada da
	// görünmez.
	SectionErrors map[string]string `json:"section_errors"`
}

type DashboardPeriod struct {
	MonthStart     string `json:"month_start"`
	NextMonthStart string `json:"next_month_start"`
	UpcomingEnd    string `json:"upcoming_end"`
}

type DashboardViewer struct {
	UserID                 string `json:"user_id"`
	OrganizationRoleCode   string `json:"organization_role_code"`
	IsAdmin                bool   `json:"is_admin"`
	AllProjects            bool   `json:"all_projects"`
	AccessibleProjectCount int    `json:"accessible_project_count"`
}

// Kurulum adımları (spec §3.6) -- yalnızca kaba admin + 0 proje + 0 aktif
// teklif olan firmada dolu, aksi hâlde null.
const (
	OnboardingStepCustomer   = "customer"
	OnboardingStepCatalog    = "catalog"
	OnboardingStepEmployee   = "employee"
	OnboardingStepTeam       = "team"
	OnboardingStepFirstOffer = "first_offer"
	OnboardingStepConvert    = "convert"
)

type DashboardOnboarding struct {
	Steps     []DashboardOnboardingStep `json:"steps"`
	DoneCount int                       `json:"done_count"`
	Total     int                       `json:"total"`
}

type DashboardOnboardingStep struct {
	Key    string  `json:"key"`
	Done   bool    `json:"done"`
	Detail *string `json:"detail"`
}

// ---------- Gündem (Dikkat Gerektirenler + Yaklaşan) ----------

const (
	LaneMine     = "mine"
	LaneWatching = "watching"

	SeverityDanger = "danger"
	SeverityAction = "action"
	SeverityInfo   = "info"
)

type DashboardAgenda struct {
	Groups          []AttentionGroup `json:"groups"`
	Upcoming        []UpcomingItem   `json:"upcoming"`
	MineCount       int              `json:"mine_count"`
	MineDangerCount int              `json:"mine_danger_count"`
	WatchingCount   int              `json:"watching_count"`
}

type AttentionGroup struct {
	Code       string            `json:"code"`
	Module     string            `json:"module"`
	Lane       string            `json:"lane"`
	Severity   string            `json:"severity"`
	Count      int               `json:"count"`
	Amounts    []MoneyAmount     `json:"amounts"`
	OldestDays *int              `json:"oldest_days"`
	Items      []AttentionRecord `json:"items"`
}

// AttentionRecord: Label kaydın KENDİ metnidir (kalem adı, belge no ·
// başlık, teklif no · müşteri ...); proje adı ve gün sayısı ayrı alanlarda
// gelir, satır cümlesini istemci §3.1 şablonuyla kurar.
type AttentionRecord struct {
	Ref         DashboardRef `json:"ref"`
	Label       string       `json:"label"`
	ProjectName *string      `json:"project_name"`
	Amount      *MoneyAmount `json:"amount"`
	Date        *string      `json:"date"`
	Days        *int         `json:"days"`
	Pct         *float64     `json:"pct"`
}

const (
	UpcomingPlanItemDue  = "plan_item_due"
	UpcomingOfferExpiry  = "offer_expiry"
	UpcomingPODelivery   = "po_delivery"
	UpcomingMilestoneEnd = "milestone_end"
	UpcomingProjectEnd   = "project_end"
	UpcomingMyTaskDue    = "my_task_due"
)

// UpcomingKindOrder, aynı günün kalemlerini sıralarken kullanılan tür
// sırasıdır (spec §3.2 tablosunun sırası).
var UpcomingKindOrder = map[string]int{
	UpcomingPlanItemDue: 0, UpcomingOfferExpiry: 1, UpcomingPODelivery: 2,
	UpcomingMilestoneEnd: 3, UpcomingProjectEnd: 4, UpcomingMyTaskDue: 5,
}

type UpcomingItem struct {
	Kind        string       `json:"kind"`
	Date        string       `json:"date"`
	Ref         DashboardRef `json:"ref"`
	Title       string       `json:"title"`
	ProjectName *string      `json:"project_name"`
	Amount      *MoneyAmount `json:"amount"`
}

// ---------- Bölümler ----------

// DashboardSections: nil bölüm = anahtar yok (izin yok ya da bölüm
// hesaplanamadı -- ikincisi section_errors'ta görünür).
type DashboardSections struct {
	Projects      *DashProjects      `json:"projects,omitempty"`
	Finance       *DashFinance       `json:"finance,omitempty"`
	ChangeOrders  *DashChangeOrders  `json:"change_orders,omitempty"`
	Offers        *DashOffers        `json:"offers,omitempty"`
	Procurement   *DashProcurement   `json:"procurement,omitempty"`
	Subcontracts  *DashSubcontracts  `json:"subcontracts,omitempty"`
	CostControl   *DashCostControl   `json:"cost_control,omitempty"`
	Contracts     *DashContracts     `json:"contracts,omitempty"`
	Tasks         *DashTasks         `json:"tasks,omitempty"`
	Operations    *DashOperations    `json:"operations,omitempty"`
	Attendance    *DashAttendance    `json:"attendance,omitempty"`
	Employees     *DashEmployees     `json:"employees,omitempty"`
	Customers     *DashCustomers     `json:"customers,omitempty"`
	Products      *DashProducts      `json:"products,omitempty"`
	Calculations  *DashCalculations  `json:"calculations,omitempty"`
	Suppliers     *DashSuppliers     `json:"suppliers,omitempty"`
	CostCodes     *DashCostCodes     `json:"cost_codes,omitempty"`
	Users         *DashUsers         `json:"users,omitempty"`
	Notifications *DashNotifications `json:"notifications,omitempty"`
	Activity      *DashActivity      `json:"activity,omitempty"`
}

// --- projects ---

type DashProjects struct {
	Counts          DashProjectCounts `json:"counts"`
	PastEndDate     int               `json:"past_end_date"`
	EndingWithin30d int               `json:"ending_within_30d"`
	Top             []DashProjectRow  `json:"top"`
}

type DashProjectCounts struct {
	Planned   int `json:"planned"`
	Active    int `json:"active"`
	Paused    int `json:"paused"`
	Completed int `json:"completed"`
	Cancelled int `json:"cancelled"`
	Total     int `json:"total"`
}

// Proje satırı bayrakları -- her biri yalnızca geldiği bloğun okuma izni
// varsa üretilir (spec §4.4 "flag leak rule").
const (
	ProjectFlagPastEnd      = "past_end"
	ProjectFlagEndingSoon   = "ending_soon"
	ProjectFlagOverdueTasks = "overdue_tasks"
	ProjectFlagOverduePlan  = "overdue_plan"
	ProjectFlagOverBudget   = "over_budget"
	ProjectFlagNoContract   = "no_contract"
)

// DashProjectRow: GET /projects satır eşleyicisi BİLİNÇLİ OLARAK
// kullanılmaz (o uç parayı projects.read ile döner). Para alanları
// yalnızca projects.finance.read ile doludur.
type DashProjectRow struct {
	Ref              DashboardRef `json:"ref"`
	ProjectNo        string       `json:"project_no"`
	Name             string       `json:"name"`
	Status           string       `json:"status"`
	CustomerName     string       `json:"customer_name"`
	StartDate        *string      `json:"start_date"`
	EndDate          *string      `json:"end_date"`
	DaysToEnd        *int         `json:"days_to_end"`
	TimeProgressPct  *float64     `json:"time_progress_pct"`
	TaskProgressPct  *float64     `json:"task_progress_pct"`
	OverdueTaskCount *int         `json:"overdue_task_count"`
	CollectionPct    *float64     `json:"collection_pct"`
	CurrentValue     *MoneyAmount `json:"current_value"`
	Flags            []string     `json:"flags"`
}

// --- finance ---

type DashFinance struct {
	ByCurrency []DashFinanceCurrency `json:"by_currency"`
}

type DashFinanceCurrency struct {
	Currency             string             `json:"currency"`
	PortfolioValue       float64            `json:"portfolio_value"`
	CollectedTotal       float64            `json:"collected_total"`
	OpenReceivable       float64            `json:"open_receivable"`
	CollectionPct        *float64           `json:"collection_pct"`
	RealizedCost         float64            `json:"realized_cost"`
	CashBalance          float64            `json:"cash_balance"`
	Month                DashFinanceMonth   `json:"month"`
	OverduePlan          CountAmount        `json:"overdue_plan"`
	OverdueSalesInvoices CountAmount        `json:"overdue_sales_invoices"`
	Trend6m              []DashFinanceTrend `json:"trend_6m"`
}

type DashFinanceMonth struct {
	Collections         float64 `json:"collections"`
	Expenses            float64 `json:"expenses"`
	SubcontractPayments float64 `json:"subcontract_payments"`
	Outflows            float64 `json:"outflows"`
	NetCash             float64 `json:"net_cash"`
}

type DashFinanceTrend struct {
	Month       string  `json:"month"` // "2026-04"
	Collections float64 `json:"collections"`
	Outflows    float64 `json:"outflows"`
	Net         float64 `json:"net"`
}

// --- change_orders ---

type DashChangeOrders struct {
	ByCurrency []DashChangeOrderCurrency `json:"by_currency"`
}

type DashChangeOrderCurrency struct {
	Currency             string      `json:"currency"`
	AwaitingCustomer     CountAmount `json:"awaiting_customer"`
	Draft                CountAmount `json:"draft"`
	ApprovedNetThisMonth float64     `json:"approved_net_this_month"`
}

// --- offers ---

type DashOffers struct {
	TotalActive          int                 `json:"total_active"`
	ByCurrency           []DashOfferCurrency `json:"by_currency"`
	ExpiringWithin7d     int                 `json:"expiring_within_7d"`
	ExpiredAwaiting      int                 `json:"expired_awaiting"`
	ViewedByCustomer7d   int                 `json:"viewed_by_customer_7d"`
	AcceptedNotConverted int                 `json:"accepted_not_converted"`
	ConversionRate90dPct *float64            `json:"conversion_rate_90d_pct"`
}

type DashOfferCurrency struct {
	Currency         string      `json:"currency"`
	Draft            CountAmount `json:"draft"`
	AwaitingCustomer CountAmount `json:"awaiting_customer"`
	Accepted90d      CountAmount `json:"accepted_90d"`
	Rejected90d      CountAmount `json:"rejected_90d"`
}

// --- procurement ---

type DashProcurement struct {
	PurchaseRequests  DashPurchaseRequestCounts `json:"purchase_requests"`
	RFQs              DashRFQCounts             `json:"rfqs"`
	PurchaseOrders    DashPurchaseOrderCounts   `json:"purchase_orders"`
	ApprovedThisMonth []DashCurrencyCountAmount `json:"approved_this_month"`
}

type DashPurchaseRequestCounts struct {
	Draft     int `json:"draft"`
	Submitted int `json:"submitted"`
}

type DashRFQCounts struct {
	Issued         int `json:"issued"`
	AwaitingAward  int `json:"awaiting_award"`
	PastDueNoQuote int `json:"past_due_no_quote"`
}

type DashPurchaseOrderCounts struct {
	Draft        int `json:"draft"`
	ApprovedOpen int `json:"approved_open"`
	LateDelivery int `json:"late_delivery"`
}

type DashCurrencyCountAmount struct {
	Currency string  `json:"currency"`
	Count    int     `json:"count"`
	Amount   float64 `json:"amount"`
}

// --- subcontracts ---

type DashSubcontracts struct {
	ActiveCount           int                       `json:"active_count"`
	ByCurrency            []DashSubcontractCurrency `json:"by_currency"`
	Claims                *DashSubcontractClaims    `json:"claims"`
	ChangeOrdersSubmitted CountAmounts              `json:"change_orders_submitted"`
}

// DashSubcontractCurrency: PaidToDate/PaidPct yalnızca
// projects.subcontract_payments.read ile doludur.
type DashSubcontractCurrency struct {
	Currency     string   `json:"currency"`
	CurrentValue float64  `json:"current_value"`
	PaidToDate   *float64 `json:"paid_to_date"`
	PaidPct      *float64 `json:"paid_pct"`
}

type DashSubcontractClaims struct {
	Submitted       CountAmounts  `json:"submitted"`
	CertifiedUnpaid *CountAmounts `json:"certified_unpaid"`
}

// --- cost_control ---

type DashCostControl struct {
	Budgets            *DashBudgetCounts `json:"budgets"`
	PendingAdjustments *CountAmounts     `json:"pending_adjustments"`
	// CommittedActive: projects.cost_control.read yoksa null, varsa en az [].
	CommittedActive []MoneyAmount   `json:"committed_active"`
	OverBudget      *DashOverBudget `json:"over_budget"`
}

type DashBudgetCounts struct {
	None         int `json:"none"`
	Draft        int `json:"draft"`
	Baselined    int `json:"baselined"`
	OpenProjects int `json:"open_projects"`
}

type DashOverBudget struct {
	Count int                  `json:"count"`
	Worst *DashOverBudgetWorst `json:"worst"`
}

type DashOverBudgetWorst struct {
	Ref         DashboardRef `json:"ref"`
	ProjectName string       `json:"project_name"`
	OverrunPct  float64      `json:"overrun_pct"`
}

// --- contracts ---

type DashContracts struct {
	Counts                        DashContractCounts `json:"counts"`
	ActiveProjectsWithoutContract int                `json:"active_projects_without_contract"`
	PastPlannedCompletion         int                `json:"past_planned_completion"`
}

type DashContractCounts struct {
	Draft      int `json:"draft"`
	Active     int `json:"active"`
	Completed  int `json:"completed"`
	Cancelled  int `json:"cancelled"`
	Terminated int `json:"terminated"`
}

// --- tasks ---

type DashTasks struct {
	Mine DashMyTasks   `json:"mine"`
	Team DashTeamTasks `json:"team"`
}

type DashMyTasks struct {
	LinkedEmployee bool         `json:"linked_employee"`
	Open           int          `json:"open"`
	Overdue        int          `json:"overdue"`
	DueToday       int          `json:"due_today"`
	Items          []DashMyTask `json:"items"`
}

type DashMyTask struct {
	Ref         DashboardRef `json:"ref"`
	Title       string       `json:"title"`
	ProjectName string       `json:"project_name"`
	DueDate     *string      `json:"due_date"`
	DaysOverdue *int         `json:"days_overdue"`
	Priority    string       `json:"priority"`
	Status      string       `json:"status"`
}

type DashTeamTasks struct {
	Open        int `json:"open"`
	Overdue     int `json:"overdue"`
	DueToday    int `json:"due_today"`
	Unassigned  int `json:"unassigned"`
	Completed7d int `json:"completed_7d"`
}

// --- operations ---

type DashOperations struct {
	ActiveCrew int                `json:"active_crew"`
	Milestones DashMilestoneCount `json:"milestones"`
	Photos7d   int                `json:"photos_7d"`
}

type DashMilestoneCount struct {
	Due7d   int `json:"due_7d"`
	Overdue int `json:"overdue"`
}

// --- attendance (firma geneli) ---

const DashAttendanceScopeOrganization = "organization"

type DashAttendance struct {
	Date            string  `json:"date"`
	Scope           string  `json:"scope"`
	ActiveEmployees int     `json:"active_employees"`
	Present         int     `json:"present"`
	HalfDay         int     `json:"half_day"`
	Absent          int     `json:"absent"`
	OnLeave         int     `json:"on_leave"`
	NotRecorded     int     `json:"not_recorded"`
	OnSite          int     `json:"on_site"`
	MonthWorkHours  float64 `json:"month_work_hours"`
}

// --- employees (maaş/yevmiye ASLA) ---

type DashEmployees struct {
	Active          int `json:"active"`
	Inactive        int `json:"inactive"`
	WithUserAccount int `json:"with_user_account"`
	NewThisMonth    int `json:"new_this_month"`
}

// --- customers ---

type DashCustomers struct {
	Active             int `json:"active"`
	NewThisMonth       int `json:"new_this_month"`
	WithActiveProjects int `json:"with_active_projects"`
}

// --- products (kâr oranı / tedarikçi fiyatı ASLA) ---

type DashProducts struct {
	Total           int                  `json:"total"`
	BySource        DashProductsBySource `json:"by_source"`
	PriceChanges30d DashPriceChanges     `json:"price_changes_30d"`
	PriceSources    []DashPriceSource    `json:"price_sources"`
}

type DashProductsBySource struct {
	Manual      int `json:"manual"`
	Ulas        int `json:"ulas"`
	DemirProfil int `json:"demirprofil"`
}

type DashPriceChanges struct {
	IncreasedCount     int                   `json:"increased_count"`
	DecreasedCount     int                   `json:"decreased_count"`
	ProductsIncreased  int                   `json:"products_increased"`
	AvgIncreasePercent *float64              `json:"avg_increase_percent"`
	MaxIncrease        *DashPriceMaxIncrease `json:"max_increase"`
}

type DashPriceMaxIncrease struct {
	Ref           DashboardRef `json:"ref"`
	ProductName   string       `json:"product_name"`
	ChangePercent float64      `json:"change_percent"`
}

type DashPriceSource struct {
	Source        string  `json:"source"`
	LastSyncedAt  *string `json:"last_synced_at"`
	LastStatus    string  `json:"last_status"`
	AutoSync      bool    `json:"auto_sync"`
	DaysSinceSync *int    `json:"days_since_sync"`
}

// --- kompakt kayıt kartları ---

type DashCalculations struct {
	Groups              int  `json:"groups"`
	Categories          int  `json:"categories"`
	UsedInOfferLines30d *int `json:"used_in_offer_lines_30d"`
	RecipeItemsUnlinked *int `json:"recipe_items_unlinked"`
}

type DashSuppliers struct {
	Active           int  `json:"active"`
	Inactive         int  `json:"inactive"`
	OrderedThisMonth *int `json:"ordered_this_month"`
}

type DashCostCodes struct {
	Active                   int  `json:"active"`
	Inactive                 int  `json:"inactive"`
	ExpensesWithoutCodeMonth *int `json:"expenses_without_code_month"`
}

// --- users (kaba admin + organization.users.read) ---

type DashUsers struct {
	Active                   int              `json:"active"`
	Inactive                 int              `json:"inactive"`
	NeverLoggedIn            int              `json:"never_logged_in"`
	RestrictedWithoutProject int              `json:"restricted_without_project"`
	WithoutEmployeeLink      int              `json:"without_employee_link"`
	ByRole                   []DashUserByRole `json:"by_role"`
	WithPersonalOverrides    *int             `json:"with_personal_overrides"`
}

type DashUserByRole struct {
	Code  string `json:"code"`
	Name  string `json:"name"`
	Count int    `json:"count"`
}

// --- notifications (çağıranın kendi kayıtları) ---

type DashNotifications struct {
	Unread int                     `json:"unread"`
	Latest []DashNotificationEntry `json:"latest"`
}

type DashNotificationEntry struct {
	ID           string  `json:"id"`
	Type         string  `json:"type"`
	Title        string  `json:"title"`
	Body         string  `json:"body"`
	ActionTarget *string `json:"action_target"`
	CreatedAt    string  `json:"created_at"`
	ReadAt       *string `json:"read_at"`
}

// --- activity (tutar/metadata ASLA) ---

const (
	ActivitySourceProject = "project"
	ActivitySourceOffer   = "offer"
)

type DashActivity struct {
	Items []DashActivityItem `json:"items"`
}

type DashActivityItem struct {
	Source      string       `json:"source"`
	EventType   string       `json:"event_type"`
	Ref         DashboardRef `json:"ref"`
	ProjectNo   *string      `json:"project_no"`
	ProjectName *string      `json:"project_name"`
	OfferNo     *string      `json:"offer_no"`
	UserName    *string      `json:"user_name"`
	CreatedAt   string       `json:"created_at"`
}

// ---------- Proje seçici (GET /dashboard/project-options) ----------

// DashboardProjectOption: hızlı işlem proje seçicisinin satırı -- GET
// /projects'in aksine HİÇBİR para alanı taşımaz.
type DashboardProjectOption struct {
	ID           string `json:"id"`
	ProjectNo    string `json:"project_no"`
	Name         string `json:"name"`
	CustomerName string `json:"customer_name"`
	Currency     string `json:"currency"`
	Status       string `json:"status"`
}
