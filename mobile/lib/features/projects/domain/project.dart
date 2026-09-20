/// backend `projectResponse` (bkz. mobile/API_CONTRACT.md#projects).
/// Finans alanları YALNIZCA liste uçlarında dolu gelir; tekil GET'te
/// (`omitempty` + backend'in bilinçli tasarımı) hepsi null'dur - detay
/// ekranı bu yüzden ayrıca `GET /financial-summary` çağırmalı.
class Project {
  final String id;
  final String projectNo;
  final String name;
  final String projectType;
  final String? customerId;
  final String customerName;
  final String customerPhone;
  final String customerEmail;
  final double contractAmount;
  final String currency;
  final String status;
  final String? startDate;
  final String? endDate;
  final String description;
  final String createdAt;

  final double? currentContractValue;
  final double? collectedAmount;
  final double? remainingReceivable;

  const Project({
    required this.id,
    required this.projectNo,
    required this.name,
    required this.projectType,
    this.customerId,
    required this.customerName,
    required this.customerPhone,
    required this.customerEmail,
    required this.contractAmount,
    required this.currency,
    required this.status,
    required this.startDate,
    required this.endDate,
    required this.description,
    required this.createdAt,
    this.currentContractValue,
    this.collectedAmount,
    this.remainingReceivable,
  });

  factory Project.fromJson(Map<String, dynamic> json) => Project(
        id: json['id'] as String,
        projectNo: json['project_no'] as String,
        name: json['name'] as String,
        projectType: json['project_type'] as String? ?? '',
        customerId: json['customer_id'] as String?,
        customerName: json['customer_name'] as String? ?? '',
        customerPhone: json['customer_phone'] as String? ?? '',
        customerEmail: json['customer_email'] as String? ?? '',
        contractAmount: (json['contract_amount'] as num).toDouble(),
        currency: json['currency'] as String? ?? 'TRY',
        status: json['status'] as String,
        startDate: json['start_date'] as String?,
        endDate: json['end_date'] as String?,
        description: json['description'] as String? ?? '',
        createdAt: json['created_at'] as String? ?? '',
        currentContractValue: (json['current_contract_value'] as num?)?.toDouble(),
        collectedAmount: (json['collected_amount'] as num?)?.toDouble(),
        remainingReceivable: (json['remaining_receivable'] as num?)?.toDouble(),
      );
}

/// `GET /projects/{id}/financial-summary` - her zaman tam dolu, 21 alan.
/// Yalnızca UI'da kullanılan alt küme tutuluyor (bkz. API_CONTRACT.md).
class FinancialSummary {
  final double currentContractValue;
  final double collectedAmount;
  final double remainingReceivable;
  final double totalExpenses;
  final double subcontractorPaid;
  final double subcontractorRemaining;
  final double realizedCost;
  final double committedCost;
  final double realizedGrossProfit;
  final double estimatedGrossProfit;
  final double realizedMarginPercent;
  final double estimatedMarginPercent;
  final String currency;

  const FinancialSummary({
    required this.currentContractValue,
    required this.collectedAmount,
    required this.remainingReceivable,
    required this.totalExpenses,
    required this.subcontractorPaid,
    required this.subcontractorRemaining,
    required this.realizedCost,
    required this.committedCost,
    required this.realizedGrossProfit,
    required this.estimatedGrossProfit,
    required this.realizedMarginPercent,
    required this.estimatedMarginPercent,
    required this.currency,
  });

  factory FinancialSummary.fromJson(Map<String, dynamic> json) => FinancialSummary(
        currentContractValue: (json['current_contract_value'] as num).toDouble(),
        collectedAmount: (json['collected_amount'] as num).toDouble(),
        remainingReceivable: (json['remaining_receivable'] as num).toDouble(),
        totalExpenses: (json['total_expenses'] as num).toDouble(),
        subcontractorPaid: (json['subcontractor_paid'] as num).toDouble(),
        subcontractorRemaining: (json['subcontractor_remaining'] as num).toDouble(),
        realizedCost: (json['realized_cost'] as num).toDouble(),
        committedCost: (json['committed_cost'] as num).toDouble(),
        realizedGrossProfit: (json['realized_gross_profit'] as num).toDouble(),
        estimatedGrossProfit: (json['estimated_gross_profit'] as num).toDouble(),
        realizedMarginPercent: (json['realized_margin_percent'] as num?)?.toDouble() ?? 0,
        estimatedMarginPercent: (json['estimated_margin_percent'] as num?)?.toDouble() ?? 0,
        currency: json['currency'] as String? ?? 'TRY',
      );
}

class Expense {
  final String id;
  final String category;
  final String description;
  final double amount;
  final String currency;
  final String expenseDate;
  final String supplierName;
  final String invoiceNo;
  final String notes;
  final String? voidedAt;
  final String voidReason;
  final String createdAt;

  const Expense({
    required this.id,
    required this.category,
    required this.description,
    required this.amount,
    required this.currency,
    required this.expenseDate,
    required this.supplierName,
    required this.invoiceNo,
    required this.notes,
    required this.voidedAt,
    required this.voidReason,
    required this.createdAt,
  });

  bool get isVoided => voidedAt != null;

  factory Expense.fromJson(Map<String, dynamic> json) => Expense(
        id: json['id'] as String,
        category: json['category'] as String,
        description: json['description'] as String? ?? '',
        amount: (json['amount'] as num).toDouble(),
        currency: json['currency'] as String? ?? 'TRY',
        expenseDate: json['expense_date'] as String? ?? '',
        supplierName: json['supplier_name'] as String? ?? '',
        invoiceNo: json['invoice_no'] as String? ?? '',
        notes: json['notes'] as String? ?? '',
        voidedAt: json['voided_at'] as String?,
        voidReason: json['void_reason'] as String? ?? '',
        createdAt: json['created_at'] as String? ?? '',
      );
}

/// `/projects/{id}/collections` (Tahsilat). Var olan `payment_plan_item_id`
/// bağı opsiyoneldir (backend serbest kayda izin verir) — mobil şimdilik
/// yalnızca serbest tahsilat oluşturur (ödeme planına bağlama yok).
class Collection {
  final String id;
  final String? paymentPlanItemId;
  final double amount;
  final String currency;
  final String receivedDate;
  final String paymentMethod;
  final String description;
  final String referenceNo;
  final String? voidedAt;
  final String voidReason;
  final String createdAt;

  const Collection({
    required this.id,
    required this.paymentPlanItemId,
    required this.amount,
    required this.currency,
    required this.receivedDate,
    required this.paymentMethod,
    required this.description,
    required this.referenceNo,
    required this.voidedAt,
    required this.voidReason,
    required this.createdAt,
  });

  bool get isVoided => voidedAt != null;

  factory Collection.fromJson(Map<String, dynamic> json) => Collection(
        id: json['id'] as String,
        paymentPlanItemId: json['payment_plan_item_id'] as String?,
        amount: (json['amount'] as num).toDouble(),
        currency: json['currency'] as String? ?? 'TRY',
        receivedDate: json['received_date'] as String? ?? '',
        paymentMethod: json['payment_method'] as String? ?? '',
        description: json['description'] as String? ?? '',
        referenceNo: json['reference_no'] as String? ?? '',
        voidedAt: json['voided_at'] as String?,
        voidReason: json['void_reason'] as String? ?? '',
        createdAt: json['created_at'] as String? ?? '',
      );
}

const expenseCategories = {
  'material': 'Malzeme',
  'personnel': 'Personel',
  'transport': 'Nakliye',
  'accommodation': 'Konaklama',
  'food': 'Yemek',
  'equipment': 'Ekipman',
  'other': 'Diğer',
};

/// `/projects/{id}/tasks` - bkz. mobile/API_CONTRACT.md#operations.
class ProjectTask {
  final String id;
  final String? scheduleItemId;
  final String title;
  final String description;
  final String? assignedEmployeeId;
  final String assignedName;
  final String priority;
  final String status;
  final String? dueDate;
  final String? completedAt;
  final bool isOverdue;

  const ProjectTask({
    required this.id,
    required this.scheduleItemId,
    required this.title,
    required this.description,
    required this.assignedEmployeeId,
    required this.assignedName,
    required this.priority,
    required this.status,
    required this.dueDate,
    required this.completedAt,
    required this.isOverdue,
  });

  factory ProjectTask.fromJson(Map<String, dynamic> json) => ProjectTask(
        id: json['id'] as String,
        scheduleItemId: json['schedule_item_id'] as String?,
        title: json['title'] as String,
        description: json['description'] as String? ?? '',
        assignedEmployeeId: json['assigned_employee_id'] as String?,
        assignedName: json['assigned_name'] as String? ?? '',
        priority: json['priority'] as String,
        status: json['status'] as String,
        dueDate: json['due_date'] as String?,
        completedAt: json['completed_at'] as String?,
        isOverdue: json['is_overdue'] as bool? ?? false,
      );

  static const statusTodo = 'todo';
  static const statusInProgress = 'in_progress';
  static const statusCompleted = 'completed';
  static const statusCancelled = 'cancelled';

  static const priorityLow = 'low';
  static const priorityNormal = 'normal';
  static const priorityHigh = 'high';
  static const priorityUrgent = 'urgent';

  /// Backend'de görev durumları için sabit bir GEÇİŞ GRAFİĞİ YOKTUR --
  /// `UpdateTask` herhangi bir geçerli durumu (`ValidTaskStatus`) herhangi
  /// bir mevcut durumdan kabul eder (bkz. backend Phase 1 doğrulaması:
  /// `completed_at`, SQL'de durumla TUTARLI şekilde otomatik ayarlanır/
  /// temizlenir -- `completed`'dan `todo`'ya dönmek `completed_at`'i NULL'a
  /// döner, yani "yeniden aç" backend'de zaten bedava). Bu yüzden mobil
  /// KENDİ ikinci bir durum makinesi İCAT ETMEZ -- düzenleme ekranında
  /// dört durum da HER ZAMAN seçilebilir.
}

class ProjectPhoto {
  final String id;
  final String originalName;
  final String mimeType;
  final int sizeBytes;
  final String stage;
  final String description;
  final String createdAt;

  const ProjectPhoto({
    required this.id,
    required this.originalName,
    required this.mimeType,
    required this.sizeBytes,
    required this.stage,
    required this.description,
    required this.createdAt,
  });

  factory ProjectPhoto.fromJson(Map<String, dynamic> json) => ProjectPhoto(
        id: json['id'] as String,
        originalName: json['original_name'] as String? ?? '',
        mimeType: json['mime_type'] as String? ?? '',
        sizeBytes: (json['size_bytes'] as num?)?.toInt() ?? 0,
        stage: json['stage'] as String? ?? 'progress',
        description: json['description'] as String? ?? '',
        createdAt: json['created_at'] as String? ?? '',
      );
}

class ProjectFile {
  final String id;
  final String originalName;
  final String mimeType;
  final int sizeBytes;
  final String category;
  final String description;
  final String createdAt;

  const ProjectFile({
    required this.id,
    required this.originalName,
    required this.mimeType,
    required this.sizeBytes,
    required this.category,
    required this.description,
    required this.createdAt,
  });

  factory ProjectFile.fromJson(Map<String, dynamic> json) => ProjectFile(
        id: json['id'] as String,
        originalName: json['original_name'] as String? ?? '',
        mimeType: json['mime_type'] as String? ?? '',
        sizeBytes: (json['size_bytes'] as num?)?.toInt() ?? 0,
        category: json['category'] as String? ?? 'other',
        description: json['description'] as String? ?? '',
        createdAt: json['created_at'] as String? ?? '',
      );
}

/// Backend `0025_create_project_operations.up.sql` CHECK kısıtlarıyla
/// BİREBİR (photos.stage / files.category) -- yeni bir sözlük İCAT EDİLMEZ.
const kPhotoStages = ['before', 'progress', 'after'];
const kFileCategories = ['contract', 'drawing', 'invoice', 'report', 'other'];

/// Backend AppConfig.maxUploadBytes ile AYNI sınırı (25 MiB) yalnızca daha
/// hızlı geri bildirim için istemci tarafında ön-kontrol eder -- gerçek
/// sınır her zaman backend'de (`ErrFileTooLarge`).
bool exceedsMaxUploadBytes(int sizeBytes, int maxUploadBytes) => sizeBytes > maxUploadBytes;

/// Proje saha notu - GET/POST /projects/{id}/notes
/// (backend noteResponse: id, content, created_by_name, created_at).
class ProjectNote {
  final String id;
  final String content;
  final String createdByName;
  final String createdAt;

  const ProjectNote({
    required this.id,
    required this.content,
    required this.createdByName,
    required this.createdAt,
  });

  factory ProjectNote.fromJson(Map<String, dynamic> json) => ProjectNote(
        id: json['id'] as String,
        content: json['content'] as String? ?? '',
        createdByName: json['created_by_name'] as String? ?? '',
        createdAt: json['created_at'] as String? ?? '',
      );
}


/// Sprint 2 — WBS + Maliyet Kodları + Proje Bütçesi + Maliyet Kontrolü.
/// `GET /projects/{id}/cost-control` — özet+kırılım TEK istekte (N+1 yok).
/// Mobil bu sprintte YALNIZCA OKUMA amaçlıdır (bkz. docs/cost-control.md
/// "Mobile" bölümü) — düzenleme/onay/taahhüt/tahmin uçları mobilde YOKTUR.
class CostControlSummary {
  final String currency;
  final double contractValue;
  final double originalBudget;
  final double approvedAdjustments;
  final double revisedBudget;
  final double committedCost;
  final double actualCost;
  final double etc;
  final double eac;
  final double variance;
  final double forecastProfit;
  final double forecastMarginPercent;
  final bool hasBudget;

  const CostControlSummary({
    required this.currency,
    required this.contractValue,
    required this.originalBudget,
    required this.approvedAdjustments,
    required this.revisedBudget,
    required this.committedCost,
    required this.actualCost,
    required this.etc,
    required this.eac,
    required this.variance,
    required this.forecastProfit,
    required this.forecastMarginPercent,
    required this.hasBudget,
  });

  factory CostControlSummary.fromJson(Map<String, dynamic> json) => CostControlSummary(
        currency: json['currency'] as String? ?? 'TRY',
        contractValue: (json['contract_value'] as num?)?.toDouble() ?? 0,
        originalBudget: (json['original_budget'] as num?)?.toDouble() ?? 0,
        approvedAdjustments: (json['approved_adjustments'] as num?)?.toDouble() ?? 0,
        revisedBudget: (json['revised_budget'] as num?)?.toDouble() ?? 0,
        committedCost: (json['committed_cost'] as num?)?.toDouble() ?? 0,
        actualCost: (json['actual_cost'] as num?)?.toDouble() ?? 0,
        etc: (json['etc'] as num?)?.toDouble() ?? 0,
        eac: (json['eac'] as num?)?.toDouble() ?? 0,
        variance: (json['variance'] as num?)?.toDouble() ?? 0,
        forecastProfit: (json['forecast_profit'] as num?)?.toDouble() ?? 0,
        forecastMarginPercent: (json['forecast_margin_percent'] as num?)?.toDouble() ?? 0,
        hasBudget: json['has_budget'] as bool? ?? false,
      );
}

/// "Maliyet Kontrolü" kırılım tablosunun tek bir satırı. isUnbudgeted=true
/// ise bu satırın bir bütçe kalemi YOKTUR — yalnızca o maliyet koduna
/// doğrudan bağlı (bütçe kalemine bağlanmamış) taahhüt/gider vardır.
class CostControlLine {
  final String? budgetLineId;
  final String wbsCode;
  final String wbsName;
  final String costCodeId;
  final String costCodeCode;
  final String costCodeName;
  final String description;
  final double originalBudget;
  final double approvedAdjustments;
  final double revisedBudget;
  final double committedCost;
  final double actualCost;
  final double etc;
  final double eac;
  final double variance;
  final bool isUnbudgeted;

  const CostControlLine({
    required this.budgetLineId,
    required this.wbsCode,
    required this.wbsName,
    required this.costCodeId,
    required this.costCodeCode,
    required this.costCodeName,
    required this.description,
    required this.originalBudget,
    required this.approvedAdjustments,
    required this.revisedBudget,
    required this.committedCost,
    required this.actualCost,
    required this.etc,
    required this.eac,
    required this.variance,
    required this.isUnbudgeted,
  });

  factory CostControlLine.fromJson(Map<String, dynamic> json) => CostControlLine(
        budgetLineId: json['budget_line_id'] as String?,
        wbsCode: json['wbs_code'] as String? ?? '',
        wbsName: json['wbs_name'] as String? ?? '',
        costCodeId: json['cost_code_id'] as String? ?? '',
        costCodeCode: json['cost_code_code'] as String? ?? '',
        costCodeName: json['cost_code_name'] as String? ?? '',
        description: json['description'] as String? ?? '',
        originalBudget: (json['original_budget'] as num?)?.toDouble() ?? 0,
        approvedAdjustments: (json['approved_adjustments'] as num?)?.toDouble() ?? 0,
        revisedBudget: (json['revised_budget'] as num?)?.toDouble() ?? 0,
        committedCost: (json['committed_cost'] as num?)?.toDouble() ?? 0,
        actualCost: (json['actual_cost'] as num?)?.toDouble() ?? 0,
        etc: (json['etc'] as num?)?.toDouble() ?? 0,
        eac: (json['eac'] as num?)?.toDouble() ?? 0,
        variance: (json['variance'] as num?)?.toDouble() ?? 0,
        isUnbudgeted: json['is_unbudgeted'] as bool? ?? false,
      );
}

/// Sprint 3 — Ek İş (Change Order), mobilde YALNIZCA OKUMA (bkz.
/// docs/contracts.md "Mobil"). Web'in tam DTO'sundan (`ChangeOrder` -
/// lib/types.ts) bilinçli olarak dar bir alt küme -- kalemler/kârlılık/
/// dahili notlar salt-okunur özet için gereksiz (CostControlLine'ın aynı
/// minimalizmi).
class ChangeOrder {
  final String id;
  final String changeOrderNo;
  final String changeType;
  final String title;
  final String status;
  final double grandTotal;
  final String currency;
  final String createdAt;
  final String? sentAt;
  final String? approvedAt;
  final String? rejectedAt;
  final String? cancelledAt;

  const ChangeOrder({
    required this.id,
    required this.changeOrderNo,
    required this.changeType,
    required this.title,
    required this.status,
    required this.grandTotal,
    required this.currency,
    required this.createdAt,
    this.sentAt,
    this.approvedAt,
    this.rejectedAt,
    this.cancelledAt,
  });

  factory ChangeOrder.fromJson(Map<String, dynamic> json) => ChangeOrder(
        id: json['id'] as String,
        changeOrderNo: json['change_order_no'] as String,
        changeType: json['change_type'] as String,
        title: json['title'] as String? ?? '',
        status: json['status'] as String,
        grandTotal: (json['grand_total'] as num?)?.toDouble() ?? 0,
        currency: json['currency'] as String? ?? 'TRY',
        createdAt: json['created_at'] as String? ?? '',
        sentAt: json['sent_at'] as String?,
        approvedAt: json['approved_at'] as String?,
        rejectedAt: json['rejected_at'] as String?,
        cancelledAt: json['cancelled_at'] as String?,
      );
}

/// `GET /projects/{id}/operations-summary` -- Faz 7'den beri backend'de
/// VAR olan ama mobilde şimdiye kadar HİÇ tüketilmeyen bir uç. Tüm alanlar
/// backend-hesaplıdır (bkz. `CountProjectTaskStats` SQL) -- mobil bunları
/// görev listesinden yeniden TOPLAMAZ.
class ProjectOperationsSummary {
  final int activeMemberCount;
  final int totalTaskCount;
  final int openTaskCount;
  final int overdueTaskCount;
  final int completedTaskCount;
  final double taskCompletionRatio;

  const ProjectOperationsSummary({
    required this.activeMemberCount,
    required this.totalTaskCount,
    required this.openTaskCount,
    required this.overdueTaskCount,
    required this.completedTaskCount,
    required this.taskCompletionRatio,
  });

  factory ProjectOperationsSummary.fromJson(Map<String, dynamic> json) => ProjectOperationsSummary(
        activeMemberCount: (json['active_member_count'] as num?)?.toInt() ?? 0,
        totalTaskCount: (json['total_task_count'] as num?)?.toInt() ?? 0,
        openTaskCount: (json['open_task_count'] as num?)?.toInt() ?? 0,
        overdueTaskCount: (json['overdue_task_count'] as num?)?.toInt() ?? 0,
        completedTaskCount: (json['completed_task_count'] as num?)?.toInt() ?? 0,
        taskCompletionRatio: (json['task_completion_ratio'] as num?)?.toDouble() ?? 0,
      );
}
