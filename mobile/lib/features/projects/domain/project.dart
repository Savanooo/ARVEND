/// backend `projectResponse` (bkz. mobile/API_CONTRACT.md#projects).
/// Finans alanları YALNIZCA liste uçlarında dolu gelir; tekil GET'te
/// (`omitempty` + backend'in bilinçli tasarımı) hepsi null'dur - detay
/// ekranı bu yüzden ayrıca `GET /financial-summary` çağırmalı.
class Project {
  final String id;
  final String projectNo;
  final String name;
  final String projectType;
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
