/// GET /api/v1/dashboard yanıtının değişmez modelleri -- backend
/// `internal/domain/dashboard.go` ve `docs/dashboard/fixtures/*.json` ile
/// BİREBİR (spec §4.4). Kurallar:
///   - "sections" içinde OLMAYAN anahtar = izin yok -> ilgili alan null,
///     kart çizilmez (spec D2). Bölüm içindeki izne bağlı alt blok null.
///   - Para JSON number'dır; mobil HİÇBİR toplamı yeniden hesaplamaz,
///     yalnızca biçimlendirir (spec D1). Farklı para birimleri toplanmaz;
///     by_currency dizileri sunucuda birincil para birimi önce sıralıdır.
///   - Tanınmayan dikkat kodu / ref türü düz string olarak saklanır ve
///     genel bir metinle gösterilir (çökme yok).
library;

double _d(Object? v) => (v as num?)?.toDouble() ?? 0;
double? _dn(Object? v) => (v as num?)?.toDouble();
int _i(Object? v) => (v as num?)?.toInt() ?? 0;
int? _in(Object? v) => (v as num?)?.toInt();
String _s(Object? v) => v as String? ?? '';
Map<String, dynamic> _m(Object? v) => (v as Map?)?.cast<String, dynamic>() ?? const {};
Map<String, dynamic>? _mn(Object? v) => (v as Map?)?.cast<String, dynamic>();
List<T> _list<T>(Object? v, T Function(Map<String, dynamic>) parse) => [
  for (final e in (v as List<dynamic>? ?? const [])) parse((e as Map).cast<String, dynamic>()),
];

// ---------- Ortak tipler ----------

/// Nötr bağlantı (spec D3) -- sunucu ASLA mobil yol göndermez;
/// `mobileRouteFor` (mobile_routes.dart) bunu rotaya çevirir. Riverpod'un
/// `Ref` tipiyle çakışmasın diye adı `DashRef`.
class DashRef {
  const DashRef({required this.kind, required this.id, this.projectId, this.parentId, this.action = 'open'});

  final String kind;
  final String id;
  final String? projectId;

  /// Taşeron hakedişi / taşeron değişiklik emri için sözleşme kimliği.
  final String? parentId;

  /// "open" | "award" | "convert".
  final String action;

  factory DashRef.fromJson(Map<String, dynamic> j) => DashRef(
    kind: _s(j['kind']),
    id: _s(j['id']),
    projectId: j['project_id'] as String?,
    parentId: j['parent_id'] as String?,
    action: j['action'] as String? ?? 'open',
  );
}

class MoneyAmount {
  const MoneyAmount({required this.currency, required this.amount});
  final String currency;
  final double amount;

  factory MoneyAmount.fromJson(Map<String, dynamic> j) =>
      MoneyAmount(currency: _s(j['currency']), amount: _d(j['amount']));
}

/// Tek para birimli bağlam (by_currency satırının içinde).
class CountAmount {
  const CountAmount({required this.count, required this.amount});
  final int count;
  final double amount;

  factory CountAmount.fromJson(Map<String, dynamic> j) => CountAmount(count: _i(j['count']), amount: _d(j['amount']));
}

/// Çok para birimli bağlam; count 0 ise amounts [].
class CountAmounts {
  const CountAmounts({required this.count, required this.amounts});
  final int count;
  final List<MoneyAmount> amounts;

  factory CountAmounts.fromJson(Map<String, dynamic> j) =>
      CountAmounts(count: _i(j['count']), amounts: _list(j['amounts'], MoneyAmount.fromJson));
}

// ---------- Üst seviye ----------

class DashboardPeriod {
  const DashboardPeriod({required this.monthStart, required this.nextMonthStart, required this.upcomingEnd});
  final String monthStart;
  final String nextMonthStart;
  final String upcomingEnd;

  factory DashboardPeriod.fromJson(Map<String, dynamic> j) => DashboardPeriod(
    monthStart: _s(j['month_start']),
    nextMonthStart: _s(j['next_month_start']),
    upcomingEnd: _s(j['upcoming_end']),
  );
}

class DashboardViewer {
  const DashboardViewer({
    required this.userId,
    required this.organizationRoleCode,
    required this.isAdmin,
    required this.allProjects,
    required this.accessibleProjectCount,
  });

  final String userId;
  final String organizationRoleCode;
  final bool isAdmin;
  final bool allProjects;
  final int accessibleProjectCount;

  factory DashboardViewer.fromJson(Map<String, dynamic> j) => DashboardViewer(
    userId: _s(j['user_id']),
    organizationRoleCode: _s(j['organization_role_code']),
    isAdmin: j['is_admin'] as bool? ?? false,
    allProjects: j['all_projects'] as bool? ?? false,
    accessibleProjectCount: _i(j['accessible_project_count']),
  );
}

class OnboardingStep {
  const OnboardingStep({required this.key, required this.done, this.detail});

  /// customer | catalog | employee | team | first_offer | convert
  final String key;
  final bool done;
  final String? detail;

  factory OnboardingStep.fromJson(Map<String, dynamic> j) =>
      OnboardingStep(key: _s(j['key']), done: j['done'] as bool? ?? false, detail: j['detail'] as String?);
}

class DashboardOnboarding {
  const DashboardOnboarding({required this.steps, required this.doneCount, required this.total});
  final List<OnboardingStep> steps;
  final int doneCount;
  final int total;

  factory DashboardOnboarding.fromJson(Map<String, dynamic> j) => DashboardOnboarding(
    steps: _list(j['steps'], OnboardingStep.fromJson),
    doneCount: _i(j['done_count']),
    total: _i(j['total']),
  );
}

// ---------- Gündem ----------

class AttentionRecord {
  const AttentionRecord({
    required this.ref,
    required this.label,
    this.projectName,
    this.amount,
    this.date,
    this.days,
    this.pct,
  });

  final DashRef ref;

  /// Kaydın KENDİ metni (kalem adı, belge no · başlık, teklif no · müşteri);
  /// proje adı ve gün sayısı ayrı alanlardadır.
  final String label;
  final String? projectName;
  final MoneyAmount? amount;
  final String? date;
  final int? days;
  final double? pct;

  factory AttentionRecord.fromJson(Map<String, dynamic> j) => AttentionRecord(
    ref: DashRef.fromJson(_m(j['ref'])),
    label: _s(j['label']),
    projectName: j['project_name'] as String?,
    amount: _mn(j['amount']) == null ? null : MoneyAmount.fromJson(_m(j['amount'])),
    date: j['date'] as String?,
    days: _in(j['days']),
    pct: _dn(j['pct']),
  );
}

class AttentionGroup {
  const AttentionGroup({
    required this.code,
    required this.module,
    required this.lane,
    required this.severity,
    required this.count,
    required this.amounts,
    this.oldestDays,
    required this.items,
  });

  final String code;
  final String module;

  /// "mine" | "watching"
  final String lane;

  /// "danger" | "action" | "info"
  final String severity;
  final int count;
  final List<MoneyAmount> amounts;
  final int? oldestDays;

  /// En acil ilk 3 kayıt.
  final List<AttentionRecord> items;

  factory AttentionGroup.fromJson(Map<String, dynamic> j) => AttentionGroup(
    code: _s(j['code']),
    module: _s(j['module']),
    lane: _s(j['lane']),
    severity: _s(j['severity']),
    count: _i(j['count']),
    amounts: _list(j['amounts'], MoneyAmount.fromJson),
    oldestDays: _in(j['oldest_days']),
    items: _list(j['items'], AttentionRecord.fromJson),
  );
}

class UpcomingItem {
  const UpcomingItem({
    required this.kind,
    required this.date,
    required this.ref,
    required this.title,
    this.projectName,
    this.amount,
  });

  /// plan_item_due | offer_expiry | po_delivery | milestone_end | project_end | my_task_due
  final String kind;
  final String date;
  final DashRef ref;
  final String title;
  final String? projectName;
  final MoneyAmount? amount;

  factory UpcomingItem.fromJson(Map<String, dynamic> j) => UpcomingItem(
    kind: _s(j['kind']),
    date: _s(j['date']),
    ref: DashRef.fromJson(_m(j['ref'])),
    title: _s(j['title']),
    projectName: j['project_name'] as String?,
    amount: _mn(j['amount']) == null ? null : MoneyAmount.fromJson(_m(j['amount'])),
  );
}

class DashboardAgenda {
  const DashboardAgenda({
    required this.groups,
    required this.upcoming,
    required this.mineCount,
    required this.mineDangerCount,
    required this.watchingCount,
  });

  final List<AttentionGroup> groups;
  final List<UpcomingItem> upcoming;
  final int mineCount;
  final int mineDangerCount;
  final int watchingCount;

  factory DashboardAgenda.fromJson(Map<String, dynamic> j) => DashboardAgenda(
    groups: _list(j['groups'], AttentionGroup.fromJson),
    upcoming: _list(j['upcoming'], UpcomingItem.fromJson),
    mineCount: _i(j['mine_count']),
    mineDangerCount: _i(j['mine_danger_count']),
    watchingCount: _i(j['watching_count']),
  );
}

// ---------- Bölümler ----------

class DashProjectCounts {
  const DashProjectCounts({
    required this.planned,
    required this.active,
    required this.paused,
    required this.completed,
    required this.cancelled,
    required this.total,
  });

  final int planned, active, paused, completed, cancelled, total;

  factory DashProjectCounts.fromJson(Map<String, dynamic> j) => DashProjectCounts(
    planned: _i(j['planned']),
    active: _i(j['active']),
    paused: _i(j['paused']),
    completed: _i(j['completed']),
    cancelled: _i(j['cancelled']),
    total: _i(j['total']),
  );
}

class DashProjectRow {
  const DashProjectRow({
    required this.ref,
    required this.projectNo,
    required this.name,
    required this.status,
    required this.customerName,
    this.startDate,
    this.endDate,
    this.daysToEnd,
    this.timeProgressPct,
    this.taskProgressPct,
    this.overdueTaskCount,
    this.collectionPct,
    this.currentValue,
    required this.flags,
  });

  final DashRef ref;
  final String projectNo;
  final String name;
  final String status;
  final String customerName;
  final String? startDate;
  final String? endDate;
  final int? daysToEnd;
  final double? timeProgressPct;

  /// projects.tasks.read yoksa null.
  final double? taskProgressPct;
  final int? overdueTaskCount;

  /// projects.finance.read yoksa null.
  final double? collectionPct;
  final MoneyAmount? currentValue;
  final List<String> flags;

  factory DashProjectRow.fromJson(Map<String, dynamic> j) => DashProjectRow(
    ref: DashRef.fromJson(_m(j['ref'])),
    projectNo: _s(j['project_no']),
    name: _s(j['name']),
    status: _s(j['status']),
    customerName: _s(j['customer_name']),
    startDate: j['start_date'] as String?,
    endDate: j['end_date'] as String?,
    daysToEnd: _in(j['days_to_end']),
    timeProgressPct: _dn(j['time_progress_pct']),
    taskProgressPct: _dn(j['task_progress_pct']),
    overdueTaskCount: _in(j['overdue_task_count']),
    collectionPct: _dn(j['collection_pct']),
    currentValue: _mn(j['current_value']) == null ? null : MoneyAmount.fromJson(_m(j['current_value'])),
    flags: [for (final f in (j['flags'] as List<dynamic>? ?? const [])) f as String],
  );
}

class DashProjects {
  const DashProjects({
    required this.counts,
    required this.pastEndDate,
    required this.endingWithin30d,
    required this.top,
  });
  final DashProjectCounts counts;
  final int pastEndDate;
  final int endingWithin30d;
  final List<DashProjectRow> top;

  factory DashProjects.fromJson(Map<String, dynamic> j) => DashProjects(
    counts: DashProjectCounts.fromJson(_m(j['counts'])),
    pastEndDate: _i(j['past_end_date']),
    endingWithin30d: _i(j['ending_within_30d']),
    top: _list(j['top'], DashProjectRow.fromJson),
  );
}

class DashFinanceMonth {
  const DashFinanceMonth({
    required this.collections,
    required this.expenses,
    required this.subcontractPayments,
    required this.outflows,
    required this.netCash,
  });

  final double collections, expenses, subcontractPayments, outflows, netCash;

  factory DashFinanceMonth.fromJson(Map<String, dynamic> j) => DashFinanceMonth(
    collections: _d(j['collections']),
    expenses: _d(j['expenses']),
    subcontractPayments: _d(j['subcontract_payments']),
    outflows: _d(j['outflows']),
    netCash: _d(j['net_cash']),
  );
}

class DashFinanceTrend {
  const DashFinanceTrend({required this.month, required this.collections, required this.outflows, required this.net});

  /// "2026-04"
  final String month;
  final double collections, outflows, net;

  factory DashFinanceTrend.fromJson(Map<String, dynamic> j) => DashFinanceTrend(
    month: _s(j['month']),
    collections: _d(j['collections']),
    outflows: _d(j['outflows']),
    net: _d(j['net']),
  );
}

class DashFinanceCurrency {
  const DashFinanceCurrency({
    required this.currency,
    required this.portfolioValue,
    required this.collectedTotal,
    required this.openReceivable,
    this.collectionPct,
    required this.realizedCost,
    required this.cashBalance,
    required this.month,
    required this.overduePlan,
    required this.overdueSalesInvoices,
    required this.trend6m,
  });

  final String currency;
  final double portfolioValue, collectedTotal, openReceivable, realizedCost, cashBalance;
  final double? collectionPct;
  final DashFinanceMonth month;
  final CountAmount overduePlan;
  final CountAmount overdueSalesInvoices;

  /// Tam 6 ay, en eski önce.
  final List<DashFinanceTrend> trend6m;

  factory DashFinanceCurrency.fromJson(Map<String, dynamic> j) => DashFinanceCurrency(
    currency: _s(j['currency']),
    portfolioValue: _d(j['portfolio_value']),
    collectedTotal: _d(j['collected_total']),
    openReceivable: _d(j['open_receivable']),
    collectionPct: _dn(j['collection_pct']),
    realizedCost: _d(j['realized_cost']),
    cashBalance: _d(j['cash_balance']),
    month: DashFinanceMonth.fromJson(_m(j['month'])),
    overduePlan: CountAmount.fromJson(_m(j['overdue_plan'])),
    overdueSalesInvoices: CountAmount.fromJson(_m(j['overdue_sales_invoices'])),
    trend6m: _list(j['trend_6m'], DashFinanceTrend.fromJson),
  );
}

class DashFinance {
  const DashFinance({required this.byCurrency});
  final List<DashFinanceCurrency> byCurrency;

  factory DashFinance.fromJson(Map<String, dynamic> j) =>
      DashFinance(byCurrency: _list(j['by_currency'], DashFinanceCurrency.fromJson));
}

class DashChangeOrderCurrency {
  const DashChangeOrderCurrency({
    required this.currency,
    required this.awaitingCustomer,
    required this.draft,
    required this.approvedNetThisMonth,
  });

  final String currency;
  final CountAmount awaitingCustomer;
  final CountAmount draft;
  final double approvedNetThisMonth;

  factory DashChangeOrderCurrency.fromJson(Map<String, dynamic> j) => DashChangeOrderCurrency(
    currency: _s(j['currency']),
    awaitingCustomer: CountAmount.fromJson(_m(j['awaiting_customer'])),
    draft: CountAmount.fromJson(_m(j['draft'])),
    approvedNetThisMonth: _d(j['approved_net_this_month']),
  );
}

class DashChangeOrders {
  const DashChangeOrders({required this.byCurrency});
  final List<DashChangeOrderCurrency> byCurrency;

  factory DashChangeOrders.fromJson(Map<String, dynamic> j) =>
      DashChangeOrders(byCurrency: _list(j['by_currency'], DashChangeOrderCurrency.fromJson));
}

class DashOfferCurrency {
  const DashOfferCurrency({
    required this.currency,
    required this.draft,
    required this.awaitingCustomer,
    required this.accepted90d,
    required this.rejected90d,
  });

  final String currency;
  final CountAmount draft, awaitingCustomer, accepted90d, rejected90d;

  factory DashOfferCurrency.fromJson(Map<String, dynamic> j) => DashOfferCurrency(
    currency: _s(j['currency']),
    draft: CountAmount.fromJson(_m(j['draft'])),
    awaitingCustomer: CountAmount.fromJson(_m(j['awaiting_customer'])),
    accepted90d: CountAmount.fromJson(_m(j['accepted_90d'])),
    rejected90d: CountAmount.fromJson(_m(j['rejected_90d'])),
  );
}

class DashOffers {
  const DashOffers({
    required this.totalActive,
    required this.byCurrency,
    required this.expiringWithin7d,
    required this.expiredAwaiting,
    required this.viewedByCustomer7d,
    required this.acceptedNotConverted,
    this.conversionRate90dPct,
  });

  final int totalActive;
  final List<DashOfferCurrency> byCurrency;
  final int expiringWithin7d, expiredAwaiting, viewedByCustomer7d, acceptedNotConverted;
  final double? conversionRate90dPct;

  factory DashOffers.fromJson(Map<String, dynamic> j) => DashOffers(
    totalActive: _i(j['total_active']),
    byCurrency: _list(j['by_currency'], DashOfferCurrency.fromJson),
    expiringWithin7d: _i(j['expiring_within_7d']),
    expiredAwaiting: _i(j['expired_awaiting']),
    viewedByCustomer7d: _i(j['viewed_by_customer_7d']),
    acceptedNotConverted: _i(j['accepted_not_converted']),
    conversionRate90dPct: _dn(j['conversion_rate_90d_pct']),
  );
}

class DashCurrencyCountAmount {
  const DashCurrencyCountAmount({required this.currency, required this.count, required this.amount});
  final String currency;
  final int count;
  final double amount;

  factory DashCurrencyCountAmount.fromJson(Map<String, dynamic> j) =>
      DashCurrencyCountAmount(currency: _s(j['currency']), count: _i(j['count']), amount: _d(j['amount']));
}

class DashProcurement {
  const DashProcurement({
    required this.prDraft,
    required this.prSubmitted,
    required this.rfqIssued,
    required this.rfqAwaitingAward,
    required this.rfqPastDueNoQuote,
    required this.poDraft,
    required this.poApprovedOpen,
    required this.poLateDelivery,
    required this.approvedThisMonth,
  });

  final int prDraft, prSubmitted;
  final int rfqIssued, rfqAwaitingAward, rfqPastDueNoQuote;
  final int poDraft, poApprovedOpen, poLateDelivery;
  final List<DashCurrencyCountAmount> approvedThisMonth;

  factory DashProcurement.fromJson(Map<String, dynamic> j) {
    final pr = _m(j['purchase_requests']);
    final rfq = _m(j['rfqs']);
    final po = _m(j['purchase_orders']);
    return DashProcurement(
      prDraft: _i(pr['draft']),
      prSubmitted: _i(pr['submitted']),
      rfqIssued: _i(rfq['issued']),
      rfqAwaitingAward: _i(rfq['awaiting_award']),
      rfqPastDueNoQuote: _i(rfq['past_due_no_quote']),
      poDraft: _i(po['draft']),
      poApprovedOpen: _i(po['approved_open']),
      poLateDelivery: _i(po['late_delivery']),
      approvedThisMonth: _list(j['approved_this_month'], DashCurrencyCountAmount.fromJson),
    );
  }
}

class DashSubcontractCurrency {
  const DashSubcontractCurrency({required this.currency, required this.currentValue, this.paidToDate, this.paidPct});
  final String currency;
  final double currentValue;

  /// projects.subcontract_payments.read yoksa null.
  final double? paidToDate;
  final double? paidPct;

  factory DashSubcontractCurrency.fromJson(Map<String, dynamic> j) => DashSubcontractCurrency(
    currency: _s(j['currency']),
    currentValue: _d(j['current_value']),
    paidToDate: _dn(j['paid_to_date']),
    paidPct: _dn(j['paid_pct']),
  );
}

class DashSubcontractClaims {
  const DashSubcontractClaims({required this.submitted, this.certifiedUnpaid});
  final CountAmounts submitted;

  /// projects.subcontract_payments.read yoksa null.
  final CountAmounts? certifiedUnpaid;

  factory DashSubcontractClaims.fromJson(Map<String, dynamic> j) => DashSubcontractClaims(
    submitted: CountAmounts.fromJson(_m(j['submitted'])),
    certifiedUnpaid: _mn(j['certified_unpaid']) == null ? null : CountAmounts.fromJson(_m(j['certified_unpaid'])),
  );
}

class DashSubcontracts {
  const DashSubcontracts({
    required this.activeCount,
    required this.byCurrency,
    this.claims,
    required this.changeOrdersSubmitted,
  });

  final int activeCount;
  final List<DashSubcontractCurrency> byCurrency;

  /// projects.subcontract_claims.read yoksa null.
  final DashSubcontractClaims? claims;
  final CountAmounts changeOrdersSubmitted;

  factory DashSubcontracts.fromJson(Map<String, dynamic> j) => DashSubcontracts(
    activeCount: _i(j['active_count']),
    byCurrency: _list(j['by_currency'], DashSubcontractCurrency.fromJson),
    claims: _mn(j['claims']) == null ? null : DashSubcontractClaims.fromJson(_m(j['claims'])),
    changeOrdersSubmitted: CountAmounts.fromJson(_m(j['change_orders_submitted'])),
  );
}

class DashBudgetCounts {
  const DashBudgetCounts({
    required this.none,
    required this.draft,
    required this.baselined,
    required this.openProjects,
  });
  final int none, draft, baselined, openProjects;

  factory DashBudgetCounts.fromJson(Map<String, dynamic> j) => DashBudgetCounts(
    none: _i(j['none']),
    draft: _i(j['draft']),
    baselined: _i(j['baselined']),
    openProjects: _i(j['open_projects']),
  );
}

class DashOverBudgetWorst {
  const DashOverBudgetWorst({required this.ref, required this.projectName, required this.overrunPct});
  final DashRef ref;
  final String projectName;
  final double overrunPct;

  factory DashOverBudgetWorst.fromJson(Map<String, dynamic> j) => DashOverBudgetWorst(
    ref: DashRef.fromJson(_m(j['ref'])),
    projectName: _s(j['project_name']),
    overrunPct: _d(j['overrun_pct']),
  );
}

class DashOverBudget {
  const DashOverBudget({required this.count, this.worst});
  final int count;
  final DashOverBudgetWorst? worst;

  factory DashOverBudget.fromJson(Map<String, dynamic> j) => DashOverBudget(
    count: _i(j['count']),
    worst: _mn(j['worst']) == null ? null : DashOverBudgetWorst.fromJson(_m(j['worst'])),
  );
}

class DashCostControl {
  const DashCostControl({this.budgets, this.pendingAdjustments, this.committedActive, this.overBudget});

  /// projects.budget.read yoksa null.
  final DashBudgetCounts? budgets;
  final CountAmounts? pendingAdjustments;

  /// projects.cost_control.read yoksa null (varsa en az []).
  final List<MoneyAmount>? committedActive;
  final DashOverBudget? overBudget;

  factory DashCostControl.fromJson(Map<String, dynamic> j) => DashCostControl(
    budgets: _mn(j['budgets']) == null ? null : DashBudgetCounts.fromJson(_m(j['budgets'])),
    pendingAdjustments: _mn(j['pending_adjustments']) == null
        ? null
        : CountAmounts.fromJson(_m(j['pending_adjustments'])),
    committedActive: j['committed_active'] == null ? null : _list(j['committed_active'], MoneyAmount.fromJson),
    overBudget: _mn(j['over_budget']) == null ? null : DashOverBudget.fromJson(_m(j['over_budget'])),
  );
}

class DashContracts {
  const DashContracts({
    required this.draft,
    required this.active,
    required this.completed,
    required this.cancelled,
    required this.terminated,
    required this.activeProjectsWithoutContract,
    required this.pastPlannedCompletion,
  });

  final int draft, active, completed, cancelled, terminated;
  final int activeProjectsWithoutContract, pastPlannedCompletion;

  factory DashContracts.fromJson(Map<String, dynamic> j) {
    final c = _m(j['counts']);
    return DashContracts(
      draft: _i(c['draft']),
      active: _i(c['active']),
      completed: _i(c['completed']),
      cancelled: _i(c['cancelled']),
      terminated: _i(c['terminated']),
      activeProjectsWithoutContract: _i(j['active_projects_without_contract']),
      pastPlannedCompletion: _i(j['past_planned_completion']),
    );
  }
}

class DashMyTask {
  const DashMyTask({
    required this.ref,
    required this.title,
    required this.projectName,
    this.dueDate,
    this.daysOverdue,
    required this.priority,
    required this.status,
  });

  final DashRef ref;
  final String title;
  final String projectName;
  final String? dueDate;
  final int? daysOverdue;
  final String priority;
  final String status;

  factory DashMyTask.fromJson(Map<String, dynamic> j) => DashMyTask(
    ref: DashRef.fromJson(_m(j['ref'])),
    title: _s(j['title']),
    projectName: _s(j['project_name']),
    dueDate: j['due_date'] as String?,
    daysOverdue: _in(j['days_overdue']),
    priority: _s(j['priority']),
    status: _s(j['status']),
  );
}

class DashMyTasks {
  const DashMyTasks({
    required this.linkedEmployee,
    required this.open,
    required this.overdue,
    required this.dueToday,
    required this.items,
  });

  final bool linkedEmployee;
  final int open, overdue, dueToday;
  final List<DashMyTask> items;

  factory DashMyTasks.fromJson(Map<String, dynamic> j) => DashMyTasks(
    linkedEmployee: j['linked_employee'] as bool? ?? false,
    open: _i(j['open']),
    overdue: _i(j['overdue']),
    dueToday: _i(j['due_today']),
    items: _list(j['items'], DashMyTask.fromJson),
  );
}

class DashTeamTasks {
  const DashTeamTasks({
    required this.open,
    required this.overdue,
    required this.dueToday,
    required this.unassigned,
    required this.completed7d,
  });

  final int open, overdue, dueToday, unassigned, completed7d;

  factory DashTeamTasks.fromJson(Map<String, dynamic> j) => DashTeamTasks(
    open: _i(j['open']),
    overdue: _i(j['overdue']),
    dueToday: _i(j['due_today']),
    unassigned: _i(j['unassigned']),
    completed7d: _i(j['completed_7d']),
  );
}

class DashTasks {
  const DashTasks({required this.mine, required this.team});
  final DashMyTasks mine;
  final DashTeamTasks team;

  factory DashTasks.fromJson(Map<String, dynamic> j) =>
      DashTasks(mine: DashMyTasks.fromJson(_m(j['mine'])), team: DashTeamTasks.fromJson(_m(j['team'])));
}

class DashOperations {
  const DashOperations({
    required this.activeCrew,
    required this.milestonesDue7d,
    required this.milestonesOverdue,
    required this.photos7d,
  });
  final int activeCrew, milestonesDue7d, milestonesOverdue, photos7d;

  factory DashOperations.fromJson(Map<String, dynamic> j) {
    final ms = _m(j['milestones']);
    return DashOperations(
      activeCrew: _i(j['active_crew']),
      milestonesDue7d: _i(ms['due_7d']),
      milestonesOverdue: _i(ms['overdue']),
      photos7d: _i(j['photos_7d']),
    );
  }
}

/// Firma geneli (spec D15).
class DashAttendance {
  const DashAttendance({
    required this.date,
    required this.scope,
    required this.activeEmployees,
    required this.present,
    required this.halfDay,
    required this.absent,
    required this.onLeave,
    required this.notRecorded,
    required this.onSite,
    required this.monthWorkHours,
  });

  final String date;
  final String scope;
  final int activeEmployees, present, halfDay, absent, onLeave, notRecorded, onSite;
  final double monthWorkHours;

  factory DashAttendance.fromJson(Map<String, dynamic> j) => DashAttendance(
    date: _s(j['date']),
    scope: _s(j['scope']),
    activeEmployees: _i(j['active_employees']),
    present: _i(j['present']),
    halfDay: _i(j['half_day']),
    absent: _i(j['absent']),
    onLeave: _i(j['on_leave']),
    notRecorded: _i(j['not_recorded']),
    onSite: _i(j['on_site']),
    monthWorkHours: _d(j['month_work_hours']),
  );
}

/// Maaş/yevmiye ASLA (spec D14).
class DashEmployees {
  const DashEmployees({
    required this.active,
    required this.inactive,
    required this.withUserAccount,
    required this.newThisMonth,
  });
  final int active, inactive, withUserAccount, newThisMonth;

  factory DashEmployees.fromJson(Map<String, dynamic> j) => DashEmployees(
    active: _i(j['active']),
    inactive: _i(j['inactive']),
    withUserAccount: _i(j['with_user_account']),
    newThisMonth: _i(j['new_this_month']),
  );
}

class DashCustomers {
  const DashCustomers({required this.active, required this.newThisMonth, required this.withActiveProjects});
  final int active, newThisMonth, withActiveProjects;

  factory DashCustomers.fromJson(Map<String, dynamic> j) => DashCustomers(
    active: _i(j['active']),
    newThisMonth: _i(j['new_this_month']),
    withActiveProjects: _i(j['with_active_projects']),
  );
}

class DashPriceMaxIncrease {
  const DashPriceMaxIncrease({required this.ref, required this.productName, required this.changePercent});
  final DashRef ref;
  final String productName;
  final double changePercent;

  factory DashPriceMaxIncrease.fromJson(Map<String, dynamic> j) => DashPriceMaxIncrease(
    ref: DashRef.fromJson(_m(j['ref'])),
    productName: _s(j['product_name']),
    changePercent: _d(j['change_percent']),
  );
}

class DashPriceSource {
  const DashPriceSource({
    required this.source,
    this.lastSyncedAt,
    required this.lastStatus,
    required this.autoSync,
    this.daysSinceSync,
  });

  /// "ulas" | "demirprofil"
  final String source;
  final String? lastSyncedAt;

  /// "never" | "success" | "failed"
  final String lastStatus;
  final bool autoSync;
  final int? daysSinceSync;

  factory DashPriceSource.fromJson(Map<String, dynamic> j) => DashPriceSource(
    source: _s(j['source']),
    lastSyncedAt: j['last_synced_at'] as String?,
    lastStatus: _s(j['last_status']),
    autoSync: j['auto_sync'] as bool? ?? false,
    daysSinceSync: _in(j['days_since_sync']),
  );
}

/// Kâr oranı / tedarikçi fiyatı ASLA (spec D14).
class DashProducts {
  const DashProducts({
    required this.total,
    required this.manual,
    required this.ulas,
    required this.demirProfil,
    required this.increasedCount,
    required this.decreasedCount,
    required this.productsIncreased,
    this.avgIncreasePercent,
    this.maxIncrease,
    required this.priceSources,
  });

  final int total;
  final int manual, ulas, demirProfil;
  final int increasedCount, decreasedCount, productsIncreased;
  final double? avgIncreasePercent;
  final DashPriceMaxIncrease? maxIncrease;
  final List<DashPriceSource> priceSources;

  factory DashProducts.fromJson(Map<String, dynamic> j) {
    final bySource = _m(j['by_source']);
    final pc = _m(j['price_changes_30d']);
    return DashProducts(
      total: _i(j['total']),
      manual: _i(bySource['manual']),
      ulas: _i(bySource['ulas']),
      demirProfil: _i(bySource['demirprofil']),
      increasedCount: _i(pc['increased_count']),
      decreasedCount: _i(pc['decreased_count']),
      productsIncreased: _i(pc['products_increased']),
      avgIncreasePercent: _dn(pc['avg_increase_percent']),
      maxIncrease: _mn(pc['max_increase']) == null ? null : DashPriceMaxIncrease.fromJson(_m(pc['max_increase'])),
      priceSources: _list(j['price_sources'], DashPriceSource.fromJson),
    );
  }
}

class DashCalculations {
  const DashCalculations({
    required this.groups,
    required this.categories,
    this.usedInOfferLines30d,
    this.recipeItemsUnlinked,
  });
  final int groups, categories;
  final int? usedInOfferLines30d;
  final int? recipeItemsUnlinked;

  factory DashCalculations.fromJson(Map<String, dynamic> j) => DashCalculations(
    groups: _i(j['groups']),
    categories: _i(j['categories']),
    usedInOfferLines30d: _in(j['used_in_offer_lines_30d']),
    recipeItemsUnlinked: _in(j['recipe_items_unlinked']),
  );
}

class DashSuppliers {
  const DashSuppliers({required this.active, required this.inactive, this.orderedThisMonth});
  final int active, inactive;
  final int? orderedThisMonth;

  factory DashSuppliers.fromJson(Map<String, dynamic> j) => DashSuppliers(
    active: _i(j['active']),
    inactive: _i(j['inactive']),
    orderedThisMonth: _in(j['ordered_this_month']),
  );
}

class DashCostCodes {
  const DashCostCodes({required this.active, required this.inactive, this.expensesWithoutCodeMonth});
  final int active, inactive;
  final int? expensesWithoutCodeMonth;

  factory DashCostCodes.fromJson(Map<String, dynamic> j) => DashCostCodes(
    active: _i(j['active']),
    inactive: _i(j['inactive']),
    expensesWithoutCodeMonth: _in(j['expenses_without_code_month']),
  );
}

class DashUserByRole {
  const DashUserByRole({required this.code, required this.name, required this.count});
  final String code;
  final String name;
  final int count;

  factory DashUserByRole.fromJson(Map<String, dynamic> j) =>
      DashUserByRole(code: _s(j['code']), name: _s(j['name']), count: _i(j['count']));
}

class DashUsers {
  const DashUsers({
    required this.active,
    required this.inactive,
    required this.neverLoggedIn,
    required this.restrictedWithoutProject,
    required this.withoutEmployeeLink,
    required this.byRole,
    this.withPersonalOverrides,
  });

  final int active, inactive, neverLoggedIn, restrictedWithoutProject, withoutEmployeeLink;
  final List<DashUserByRole> byRole;
  final int? withPersonalOverrides;

  factory DashUsers.fromJson(Map<String, dynamic> j) => DashUsers(
    active: _i(j['active']),
    inactive: _i(j['inactive']),
    neverLoggedIn: _i(j['never_logged_in']),
    restrictedWithoutProject: _i(j['restricted_without_project']),
    withoutEmployeeLink: _i(j['without_employee_link']),
    byRole: _list(j['by_role'], DashUserByRole.fromJson),
    withPersonalOverrides: _in(j['with_personal_overrides']),
  );
}

class DashNotificationEntry {
  const DashNotificationEntry({
    required this.id,
    required this.type,
    required this.title,
    required this.body,
    this.actionTarget,
    required this.createdAt,
    this.readAt,
  });

  final String id, type, title, body, createdAt;
  final String? actionTarget;
  final String? readAt;

  factory DashNotificationEntry.fromJson(Map<String, dynamic> j) => DashNotificationEntry(
    id: _s(j['id']),
    type: _s(j['type']),
    title: _s(j['title']),
    body: _s(j['body']),
    actionTarget: j['action_target'] as String?,
    createdAt: _s(j['created_at']),
    readAt: j['read_at'] as String?,
  );
}

class DashNotifications {
  const DashNotifications({required this.unread, required this.latest});
  final int unread;
  final List<DashNotificationEntry> latest;

  factory DashNotifications.fromJson(Map<String, dynamic> j) =>
      DashNotifications(unread: _i(j['unread']), latest: _list(j['latest'], DashNotificationEntry.fromJson));
}

/// Tutar/metadata ASLA taşımaz.
class DashActivityItem {
  const DashActivityItem({
    required this.source,
    required this.eventType,
    required this.ref,
    this.projectNo,
    this.projectName,
    this.offerNo,
    this.userName,
    required this.createdAt,
  });

  /// "project" | "offer"
  final String source;
  final String eventType;
  final DashRef ref;
  final String? projectNo, projectName, offerNo, userName;
  final String createdAt;

  factory DashActivityItem.fromJson(Map<String, dynamic> j) => DashActivityItem(
    source: _s(j['source']),
    eventType: _s(j['event_type']),
    ref: DashRef.fromJson(_m(j['ref'])),
    projectNo: j['project_no'] as String?,
    projectName: j['project_name'] as String?,
    offerNo: j['offer_no'] as String?,
    userName: j['user_name'] as String?,
    createdAt: _s(j['created_at']),
  );
}

class DashActivity {
  const DashActivity({required this.items});
  final List<DashActivityItem> items;

  factory DashActivity.fromJson(Map<String, dynamic> j) =>
      DashActivity(items: _list(j['items'], DashActivityItem.fromJson));
}

/// Anahtarı OLMAYAN bölüm null'dır (izin yok ya da hesaplanamadı --
/// ikincisi `Dashboard.sectionErrors`'ta görünür).
class DashboardSections {
  const DashboardSections({
    required this.keys,
    this.projects,
    this.finance,
    this.changeOrders,
    this.offers,
    this.procurement,
    this.subcontracts,
    this.costControl,
    this.contracts,
    this.tasks,
    this.operations,
    this.attendance,
    this.employees,
    this.customers,
    this.products,
    this.calculations,
    this.suppliers,
    this.costCodes,
    this.users,
    this.notifications,
    this.activity,
  });

  /// Yanıtta GERÇEKTEN bulunan bölüm anahtarları.
  final Set<String> keys;
  final DashProjects? projects;
  final DashFinance? finance;
  final DashChangeOrders? changeOrders;
  final DashOffers? offers;
  final DashProcurement? procurement;
  final DashSubcontracts? subcontracts;
  final DashCostControl? costControl;
  final DashContracts? contracts;
  final DashTasks? tasks;
  final DashOperations? operations;
  final DashAttendance? attendance;
  final DashEmployees? employees;
  final DashCustomers? customers;
  final DashProducts? products;
  final DashCalculations? calculations;
  final DashSuppliers? suppliers;
  final DashCostCodes? costCodes;
  final DashUsers? users;
  final DashNotifications? notifications;
  final DashActivity? activity;

  bool has(String key) => keys.contains(key);

  factory DashboardSections.fromJson(Map<String, dynamic> j) {
    T? part<T>(String key, T Function(Map<String, dynamic>) parse) {
      final raw = _mn(j[key]);
      return raw == null ? null : parse(raw);
    }

    return DashboardSections(
      keys: {
        for (final e in j.entries)
          if (e.value != null) e.key,
      },
      projects: part('projects', DashProjects.fromJson),
      finance: part('finance', DashFinance.fromJson),
      changeOrders: part('change_orders', DashChangeOrders.fromJson),
      offers: part('offers', DashOffers.fromJson),
      procurement: part('procurement', DashProcurement.fromJson),
      subcontracts: part('subcontracts', DashSubcontracts.fromJson),
      costControl: part('cost_control', DashCostControl.fromJson),
      contracts: part('contracts', DashContracts.fromJson),
      tasks: part('tasks', DashTasks.fromJson),
      operations: part('operations', DashOperations.fromJson),
      attendance: part('attendance', DashAttendance.fromJson),
      employees: part('employees', DashEmployees.fromJson),
      customers: part('customers', DashCustomers.fromJson),
      products: part('products', DashProducts.fromJson),
      calculations: part('calculations', DashCalculations.fromJson),
      suppliers: part('suppliers', DashSuppliers.fromJson),
      costCodes: part('cost_codes', DashCostCodes.fromJson),
      users: part('users', DashUsers.fromJson),
      notifications: part('notifications', DashNotifications.fromJson),
      activity: part('activity', DashActivity.fromJson),
    );
  }
}

class Dashboard {
  const Dashboard({
    required this.generatedAt,
    required this.today,
    required this.timezone,
    required this.isWorkday,
    required this.period,
    required this.primaryCurrency,
    required this.viewer,
    this.onboarding,
    required this.agenda,
    required this.sections,
    required this.sectionErrors,
  });

  /// RFC3339, "+03:00" ofsetli.
  final String generatedAt;

  /// İstanbul takvim günü ("2026-09-28") -- ana sayfada TEK "bugün"
  /// kaynağı; cihaz saati kullanılmaz (spec D6/D20).
  final String today;
  final String timezone;
  final bool isWorkday;
  final DashboardPeriod period;
  final String primaryCurrency;
  final DashboardViewer viewer;
  final DashboardOnboarding? onboarding;
  final DashboardAgenda agenda;
  final DashboardSections sections;

  /// İzni olan ama o an hesaplanamayan bölüm anahtarları.
  final Set<String> sectionErrors;

  factory Dashboard.fromJson(Map<String, dynamic> j) => Dashboard(
    generatedAt: _s(j['generated_at']),
    today: _s(j['today']),
    timezone: _s(j['timezone']),
    isWorkday: j['is_workday'] as bool? ?? true,
    period: DashboardPeriod.fromJson(_m(j['period'])),
    primaryCurrency: j['primary_currency'] as String? ?? 'TRY',
    viewer: DashboardViewer.fromJson(_m(j['viewer'])),
    onboarding: _mn(j['onboarding']) == null ? null : DashboardOnboarding.fromJson(_m(j['onboarding'])),
    agenda: DashboardAgenda.fromJson(_m(j['agenda'])),
    sections: DashboardSections.fromJson(_m(j['sections'])),
    sectionErrors: _m(j['section_errors']).keys.toSet(),
  );
}

/// GET /dashboard/project-options satırı -- HİÇBİR para alanı yok (spec
/// D16; `GET /projects` bilinçli olarak kullanılmaz).
class ProjectOption {
  const ProjectOption({
    required this.id,
    required this.projectNo,
    required this.name,
    required this.customerName,
    required this.currency,
    required this.status,
  });

  final String id, projectNo, name, customerName, currency, status;

  factory ProjectOption.fromJson(Map<String, dynamic> j) => ProjectOption(
    id: _s(j['id']),
    projectNo: _s(j['project_no']),
    name: _s(j['name']),
    customerName: _s(j['customer_name']),
    currency: j['currency'] as String? ?? 'TRY',
    status: _s(j['status']),
  );
}
