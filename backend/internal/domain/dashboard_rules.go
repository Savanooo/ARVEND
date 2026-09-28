package domain

import "slices"

// Ana sayfa "Dikkat Gerektirenler" kural kataloğu (spec §3.1) ve "Son
// Hareketler" olay->izin haritası (spec §4.9). İkisi de SAF veridir;
// şerit (lane) ataması ve sıralama service/dashboard_agenda.go'dadır.

// ---------- Dikkat kodları ----------

const (
	AttnPlanItemOverdue           = "plan_item_overdue"
	AttnSalesInvoiceOverdue       = "sales_invoice_overdue"
	AttnChangeOrderAwaitingCust   = "change_order_awaiting_customer"
	AttnOfferExpiredAwaiting      = "offer_expired_awaiting"
	AttnOfferAcceptedNotConverted = "offer_accepted_not_converted"
	AttnPurchaseRequestApproval   = "purchase_request_approval"
	AttnPurchaseOrderDraft        = "purchase_order_draft"
	AttnRFQAward                  = "rfq_award"
	AttnRFQNoQuote                = "rfq_no_quote"
	AttnPOLateDelivery            = "po_late_delivery"
	AttnProgressClaimCertify      = "progress_claim_certify"
	AttnClaimCertifiedUnpaid      = "claim_certified_unpaid"
	AttnSubcontractCOApproval     = "subcontract_co_approval"
	AttnBudgetAdjustmentApproval  = "budget_adjustment_approval"
	AttnOverBudget                = "over_budget"
	AttnActiveWithoutBudget       = "active_without_budget"
	AttnContractActivation        = "contract_activation"
	AttnContractPastCompletion    = "contract_past_completion"
	AttnActiveWithoutContract     = "active_without_contract"
	AttnProjectPastEnd            = "project_past_end"
	AttnMyTaskOverdue             = "my_task_overdue"
	AttnMyTaskDueToday            = "my_task_due_today"
	AttnTeamTaskOverdue           = "team_task_overdue"
	AttnTeamTaskUnassigned        = "team_task_unassigned"
	AttnMilestoneOverdue          = "milestone_overdue"
	AttnAttendanceNotRecorded     = "attendance_not_recorded"
	AttnPriceSyncFailed           = "price_sync_failed"
	AttnPriceSyncNever            = "price_sync_never"
	AttnUsersWithoutProject       = "users_without_project"
)

// AttentionRule, bir dikkat kodunun sabit tanımıdır.
//   - Visible: kodun üretilebilmesi için GEREKEN okuma izinleri (hepsi).
//     Bölüm kapısı zaten bunları gerektirir; gündem yine de tekrar bakar.
//   - Act: kaydı ilerletebilmek için gereken izinler (hepsi). Boşsa kimse
//     aksiyon alamaz (ör. ek işte kararı müşteri verir) -> her zaman
//     WhenCannotAct uygulanır.
//   - AlwaysMine: kişinin kendi görevleri -- izinden bağımsız "senin sıran".
//   - WhenCannotAct: LaneWatching ("Takipte") ya da "" (gizle -- rakam
//     yalnızca modül kartında görünür).
type AttentionRule struct {
	Module        string
	Severity      string
	Visible       []string
	Act           []string
	AlwaysMine    bool
	WhenCannotAct string
}

// AttentionRules: spec §3.1 tablosunun birebir karşılığı.
var AttentionRules = map[string]AttentionRule{
	AttnPlanItemOverdue: {Module: DashSectionFinance, Severity: SeverityDanger,
		Visible: []string{PermProjectsFinanceRead}, Act: []string{PermProjectsFinanceManage}, WhenCannotAct: LaneWatching},
	AttnSalesInvoiceOverdue: {Module: DashSectionFinance, Severity: SeverityDanger,
		Visible: []string{PermProjectsFinanceRead}, Act: []string{PermProjectsFinanceManage}, WhenCannotAct: LaneWatching},
	AttnChangeOrderAwaitingCust: {Module: DashSectionChangeOrders, Severity: SeverityInfo,
		Visible: []string{PermProjectsFinanceRead}, Act: nil, WhenCannotAct: LaneWatching},
	AttnOfferExpiredAwaiting: {Module: DashSectionOffers, Severity: SeverityDanger,
		Visible: []string{PermOffersRead}, Act: []string{PermOffersUpdate}, WhenCannotAct: LaneWatching},
	AttnOfferAcceptedNotConverted: {Module: DashSectionOffers, Severity: SeverityAction,
		Visible: []string{PermOffersRead}, Act: []string{PermProjectsCreate}, WhenCannotAct: LaneWatching},
	AttnPurchaseRequestApproval: {Module: DashSectionProcurement, Severity: SeverityAction,
		Visible: []string{PermProjectsProcurementRead}, Act: []string{PermProjectsProcurementApprove}, WhenCannotAct: LaneWatching},
	AttnPurchaseOrderDraft: {Module: DashSectionProcurement, Severity: SeverityAction,
		Visible: []string{PermProjectsProcurementRead}, Act: []string{PermProjectsProcurementApprove}, WhenCannotAct: LaneWatching},
	AttnRFQAward: {Module: DashSectionProcurement, Severity: SeverityAction,
		Visible: []string{PermProjectsProcurementRead}, Act: []string{PermProjectsProcurementApprove}, WhenCannotAct: LaneWatching},
	AttnRFQNoQuote: {Module: DashSectionProcurement, Severity: SeverityAction,
		Visible: []string{PermProjectsProcurementRead}, Act: []string{PermProjectsProcurementManage}, WhenCannotAct: ""},
	AttnPOLateDelivery: {Module: DashSectionProcurement, Severity: SeverityDanger,
		Visible: []string{PermProjectsProcurementRead}, Act: []string{PermProjectsProcurementManage}, WhenCannotAct: LaneWatching},
	AttnProgressClaimCertify: {Module: DashSectionSubcontracts, Severity: SeverityAction,
		Visible: []string{PermProjectsSubcontractClaimsRead}, Act: []string{PermProjectsSubcontractClaimsCertify}, WhenCannotAct: LaneWatching},
	AttnClaimCertifiedUnpaid: {Module: DashSectionSubcontracts, Severity: SeverityAction,
		Visible: []string{PermProjectsSubcontractClaimsRead, PermProjectsSubcontractPaymentsRead},
		Act:     []string{PermProjectsSubcontractPaymentsManage}, WhenCannotAct: LaneWatching},
	AttnSubcontractCOApproval: {Module: DashSectionSubcontracts, Severity: SeverityAction,
		Visible: []string{PermProjectsSubcontractsRead}, Act: []string{PermProjectsSubcontractsApprove}, WhenCannotAct: LaneWatching},
	AttnBudgetAdjustmentApproval: {Module: DashSectionCostControl, Severity: SeverityAction,
		Visible: []string{PermProjectsBudgetRead}, Act: []string{PermProjectsBudgetManage}, WhenCannotAct: LaneWatching},
	AttnOverBudget: {Module: DashSectionCostControl, Severity: SeverityDanger,
		Visible: []string{PermProjectsCostControlRead}, Act: []string{PermProjectsCostControlManage}, WhenCannotAct: LaneWatching},
	AttnActiveWithoutBudget: {Module: DashSectionCostControl, Severity: SeverityAction,
		Visible: []string{PermProjectsBudgetRead}, Act: []string{PermProjectsBudgetManage}, WhenCannotAct: ""},
	AttnContractActivation: {Module: DashSectionContracts, Severity: SeverityAction,
		Visible: []string{PermProjectsContractsRead}, Act: []string{PermProjectsContractsLifecycle}, WhenCannotAct: LaneWatching},
	AttnContractPastCompletion: {Module: DashSectionContracts, Severity: SeverityDanger,
		Visible: []string{PermProjectsContractsRead}, Act: []string{PermProjectsContractsLifecycle}, WhenCannotAct: LaneWatching},
	AttnActiveWithoutContract: {Module: DashSectionContracts, Severity: SeverityAction,
		Visible: []string{PermProjectsContractsRead}, Act: []string{PermProjectsContractsManage}, WhenCannotAct: ""},
	AttnProjectPastEnd: {Module: DashSectionProjects, Severity: SeverityDanger,
		Visible: []string{PermProjectsRead}, Act: []string{PermProjectsUpdate}, WhenCannotAct: ""},
	AttnMyTaskOverdue: {Module: DashSectionTasks, Severity: SeverityDanger,
		Visible: []string{PermProjectsTasksRead}, AlwaysMine: true},
	AttnMyTaskDueToday: {Module: DashSectionTasks, Severity: SeverityAction,
		Visible: []string{PermProjectsTasksRead}, AlwaysMine: true},
	// team_task_*: projects.tasks.update DEĞİL create -- saha rolü update
	// taşır, ekip satırları onun şeridine düşmemeli (spec §3.1 notu).
	AttnTeamTaskOverdue: {Module: DashSectionTasks, Severity: SeverityDanger,
		Visible: []string{PermProjectsTasksRead}, Act: []string{PermProjectsTasksCreate}, WhenCannotAct: ""},
	AttnTeamTaskUnassigned: {Module: DashSectionTasks, Severity: SeverityAction,
		Visible: []string{PermProjectsTasksRead}, Act: []string{PermProjectsTasksCreate}, WhenCannotAct: ""},
	AttnMilestoneOverdue: {Module: DashSectionOperations, Severity: SeverityDanger,
		Visible: []string{PermProjectsOperationsRead}, Act: []string{PermProjectsOperationsManage}, WhenCannotAct: ""},
	AttnAttendanceNotRecorded: {Module: DashSectionAttendance, Severity: SeverityAction,
		Visible: []string{PermAttendanceRead}, Act: []string{PermAttendanceManage, PermEmployeesRead}, WhenCannotAct: ""},
	AttnPriceSyncFailed: {Module: DashSectionProducts, Severity: SeverityDanger,
		Visible: []string{PermProductsRead}, Act: []string{PermProductsManage}, WhenCannotAct: LaneWatching},
	AttnPriceSyncNever: {Module: DashSectionProducts, Severity: SeverityAction,
		Visible: []string{PermProductsRead}, Act: []string{PermProductsManage}, WhenCannotAct: ""},
	AttnUsersWithoutProject: {Module: DashSectionUsers, Severity: SeverityAction,
		Visible: []string{PermOrganizationUsersRead}, Act: []string{PermProjectsAccessManage}, WhenCannotAct: ""},
}

// ---------- Son Hareketler: olay -> izin ----------

// ActivityEventPermissions, project_events'e yazılan HER olay tipinin
// ana sayfa akışında görünmesi için gereken okuma iznidir. Haritada
// OLMAYAN tip akışa ASLA girmez (fail-closed). Yeni bir ProjectEvent*
// sabiti eklendiğinde buraya ya da ActivityEventExcluded'a eklenmelidir
// -- dashboard_rules_test.go domain kaynağını tarayıp bunu zorlar.
// Akış yalnızca olay tipini, kimlikleri, kullanıcı adını ve zamanı taşır;
// metadata (tutarlar) ASLA seçilmez.
var ActivityEventPermissions = map[string]string{
	ProjectEventCreated:       PermProjectsRead,
	ProjectEventUpdated:       PermProjectsRead,
	ProjectEventStatusChanged: PermProjectsRead,

	ProjectEventCollectionReceived:       PermProjectsFinanceRead,
	ProjectEventCollectionVoided:         PermProjectsFinanceRead,
	ProjectEventExpenseAdded:             PermProjectsFinanceRead,
	ProjectEventExpenseUpdated:           PermProjectsFinanceRead,
	ProjectEventExpenseVoided:            PermProjectsFinanceRead,
	ProjectEventPaymentPlanCreated:       PermProjectsFinanceRead,
	ProjectEventPaymentPlanUpdated:       PermProjectsFinanceRead,
	ProjectEventPaymentPlanCancelled:     PermProjectsFinanceRead,
	ProjectEventInvoiceCreated:           PermProjectsFinanceRead,
	ProjectEventInvoiceStatusChanged:     PermProjectsFinanceRead,
	ProjectEventSubcontractorAdded:       PermProjectsFinanceRead,
	ProjectEventSubcontractorUpdated:     PermProjectsFinanceRead,
	ProjectEventSubcontractorPaymentMade: PermProjectsFinanceRead,
	ProjectEventSubcontractorPaymentVoid: PermProjectsFinanceRead,
	ProjectEventChangeOrderCreated:       PermProjectsFinanceRead,
	ProjectEventChangeOrderUpdated:       PermProjectsFinanceRead,
	ProjectEventChangeOrderSent:          PermProjectsFinanceRead,
	ProjectEventChangeOrderViewed:        PermProjectsFinanceRead,
	ProjectEventChangeOrderApproved:      PermProjectsFinanceRead,
	ProjectEventChangeOrderRejected:      PermProjectsFinanceRead,
	ProjectEventChangeOrderCancelled:     PermProjectsFinanceRead,
	ProjectEventChangeOrderSuperseded:    PermProjectsFinanceRead,
	ProjectEventChangeOrderEmailSent:     PermProjectsFinanceRead,
	ProjectEventChangeOrderEmailFail:     PermProjectsFinanceRead,

	ProjectEventPurchaseRequestCreated:   PermProjectsProcurementRead,
	ProjectEventPurchaseRequestUpdated:   PermProjectsProcurementRead,
	ProjectEventPurchaseRequestSubmitted: PermProjectsProcurementRead,
	ProjectEventPurchaseRequestWithdrawn: PermProjectsProcurementRead,
	ProjectEventPurchaseRequestApproved:  PermProjectsProcurementRead,
	ProjectEventPurchaseRequestRejected:  PermProjectsProcurementRead,
	ProjectEventPurchaseRequestCancelled: PermProjectsProcurementRead,
	ProjectEventPurchaseOrderCreated:     PermProjectsProcurementRead,
	ProjectEventPurchaseOrderUpdated:     PermProjectsProcurementRead,
	ProjectEventPurchaseOrderApproved:    PermProjectsProcurementRead,
	ProjectEventPurchaseOrderCancelled:   PermProjectsProcurementRead,
	ProjectEventPurchaseOrderClosed:      PermProjectsProcurementRead,
	ProjectEventRFQCreated:               PermProjectsProcurementRead,
	ProjectEventRFQUpdated:               PermProjectsProcurementRead,
	ProjectEventRFQIssued:                PermProjectsProcurementRead,
	ProjectEventRFQClosed:                PermProjectsProcurementRead,
	ProjectEventRFQCancelled:             PermProjectsProcurementRead,
	ProjectEventRFQAwarded:               PermProjectsProcurementRead,
	ProjectEventQuotationCreated:         PermProjectsProcurementRead,
	ProjectEventQuotationUpdated:         PermProjectsProcurementRead,
	ProjectEventQuotationDeleted:         PermProjectsProcurementRead,

	ProjectEventBudgetCreated:      PermProjectsBudgetRead,
	ProjectEventBudgetBaselined:    PermProjectsBudgetRead,
	ProjectEventAdjustmentCreated:  PermProjectsBudgetRead,
	ProjectEventAdjustmentApproved: PermProjectsBudgetRead,
	ProjectEventAdjustmentRejected: PermProjectsBudgetRead,
	ProjectEventBudgetLineCreated:  PermProjectsBudgetRead,
	ProjectEventBudgetLineUpdated:  PermProjectsBudgetRead,
	ProjectEventBudgetLineDeleted:  PermProjectsBudgetRead,
	ProjectEventWBSCreated:         PermProjectsBudgetRead,
	ProjectEventWBSUpdated:         PermProjectsBudgetRead,
	ProjectEventWBSArchived:        PermProjectsBudgetRead,

	ProjectEventCommitmentCreated: PermProjectsCostControlRead,
	ProjectEventCommitmentVoided:  PermProjectsCostControlRead,
	ProjectEventForecastUpdated:   PermProjectsCostControlRead,

	ProjectEventContractCreated:      PermProjectsContractsRead,
	ProjectEventContractUpdated:      PermProjectsContractsRead,
	ProjectEventContractNotesUpdated: PermProjectsContractsRead,
	ProjectEventContractActivated:    PermProjectsContractsRead,
	ProjectEventContractCompleted:    PermProjectsContractsRead,
	ProjectEventContractCancelled:    PermProjectsContractsRead,
	ProjectEventContractTerminated:   PermProjectsContractsRead,

	ProjectEventSubcontractCreated:              PermProjectsSubcontractsRead,
	ProjectEventSubcontractUpdated:              PermProjectsSubcontractsRead,
	ProjectEventSubcontractActivated:            PermProjectsSubcontractsRead,
	ProjectEventSubcontractCompleted:            PermProjectsSubcontractsRead,
	ProjectEventSubcontractCancelled:            PermProjectsSubcontractsRead,
	ProjectEventSubcontractTerminated:           PermProjectsSubcontractsRead,
	ProjectEventSubcontractChangeOrderCreated:   PermProjectsSubcontractsRead,
	ProjectEventSubcontractChangeOrderUpdated:   PermProjectsSubcontractsRead,
	ProjectEventSubcontractChangeOrderSubmitted: PermProjectsSubcontractsRead,
	ProjectEventSubcontractChangeOrderApproved:  PermProjectsSubcontractsRead,
	ProjectEventSubcontractChangeOrderRejected:  PermProjectsSubcontractsRead,
	ProjectEventSubcontractChangeOrderCancelled: PermProjectsSubcontractsRead,

	ProjectEventProgressClaimCreated:   PermProjectsSubcontractClaimsRead,
	ProjectEventProgressClaimUpdated:   PermProjectsSubcontractClaimsRead,
	ProjectEventProgressClaimSubmitted: PermProjectsSubcontractClaimsRead,
	ProjectEventProgressClaimCertified: PermProjectsSubcontractClaimsRead,
	ProjectEventProgressClaimRejected:  PermProjectsSubcontractClaimsRead,
	ProjectEventProgressClaimCancelled: PermProjectsSubcontractClaimsRead,

	ProjectEventSubcontractPaymentMade: PermProjectsSubcontractPaymentsRead,
	ProjectEventSubcontractPaymentVoid: PermProjectsSubcontractPaymentsRead,

	ProjectEventTaskCreated:   PermProjectsTasksRead,
	ProjectEventTaskUpdated:   PermProjectsTasksRead,
	ProjectEventTaskAssigned:  PermProjectsTasksRead,
	ProjectEventTaskCompleted: PermProjectsTasksRead,

	ProjectEventScheduleCreated:   PermProjectsOperationsRead,
	ProjectEventScheduleUpdated:   PermProjectsOperationsRead,
	ProjectEventScheduleCompleted: PermProjectsOperationsRead,
	ProjectEventMemberAssigned:    PermProjectsOperationsRead,
	ProjectEventMemberRemoved:     PermProjectsOperationsRead,
	ProjectEventFileUploaded:      PermProjectsOperationsRead,
	ProjectEventFileRemoved:       PermProjectsOperationsRead,
	ProjectEventPhotoUploaded:     PermProjectsOperationsRead,
	ProjectEventPhotoRemoved:      PermProjectsOperationsRead,
	ProjectEventNoteAdded:         PermProjectsOperationsRead,
}

// ActivityEventExcluded, project_events'e yazılan ama ana sayfa akışına
// BİLİNÇLİ OLARAK alınmayan tiplerdir (şu an yok). Tarama testi bir
// ProjectEvent* sabitinin ya haritada ya burada olmasını ister.
var ActivityEventExcluded = map[string]bool{}

// OfferActivityEvents, offer_events'ten akışa alınan tiplerdir (hepsi
// offers.read ister; arşivlenmiş teklifler dahil edilmez). Paylaşım
// linki/e-posta/revizyon taslağı gibi iç ayrıntılar alınmaz.
var OfferActivityEvents = []string{
	EventOfferCreated, EventRevisionSent, EventCustomerViewed,
	EventCustomerAccepted, EventCustomerRejected, EventOfferCancelled, EventProjectCreated,
}

// AllowedProjectActivityTypes, izin kontrolcüsüne göre akışta görünebilecek
// project_events tiplerini (deterministik sırada) döner.
func AllowedProjectActivityTypes(can func(string) bool) []string {
	out := make([]string, 0, len(ActivityEventPermissions))
	for eventType, perm := range ActivityEventPermissions {
		if can(perm) {
			out = append(out, eventType)
		}
	}
	slices.Sort(out)
	return out
}
