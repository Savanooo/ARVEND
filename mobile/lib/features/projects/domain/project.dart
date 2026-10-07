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

  /// Web "Müşteri Bilgileri" / "Genel" karşılıkları (tekil GET'te dolu).
  final String customerAddress;

  /// Dahili notlar (müşteri görmez) -- `PUT /projects/{id}` ile yazılır.
  final String internalNotes;

  /// Projenin doğduğu teklif (tekliften dönüşüm) -- yoksa null/boş.
  final String? sourceOfferId;
  final String sourceOfferNo;
  final int? sourceRevisionNo;

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
    this.customerAddress = '',
    this.internalNotes = '',
    this.sourceOfferId,
    this.sourceOfferNo = '',
    this.sourceRevisionNo,
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
        customerAddress: json['customer_address'] as String? ?? '',
        internalNotes: json['internal_notes'] as String? ?? '',
        sourceOfferId: _nonEmptyId(json['source_offer_id'] as String?),
        sourceOfferNo: json['source_offer_no'] as String? ?? '',
        sourceRevisionNo: (json['source_revision_no'] as num?)?.toInt(),
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

  /// Yukarıdaki bedel ve kârlar KDV DAHİL. KDV hariç karşılıklar sunucuda
  /// hesaplanır (web ile aynı rakam); [contractVatKnown] false ise proje
  /// tekliften açılmamıştır, KDV bilinmez ve net kârlar KDV dahille aynıdır.
  final bool contractVatKnown;
  final double contractVatAmount;
  final double currentContractValueNet;
  final double realizedGrossProfitNet;
  final double realizedMarginPercentNet;

  /// Onaylı masrafların içindeki KDV (KDV oranı girilmiş olanlar) ve ondan
  /// türeyen KDV hariç maliyetler -- sunucu hesaplar. Eski sunucuda alan
  /// yok: KDV 0, maliyetler KDV dahille aynı.
  final double expenseVatTotal;
  final double realizedCostNet;
  final double committedCostNet;

  /// "Tahmini" bölümünün TEK kaynağı -- seçimi sunucu yapar:
  /// `budget` = Maliyet Kontrolü EAC (+ eski taşeron), `commitments` =
  /// taahhüt bazlı. Web de aynısını gösterir.
  final String forecastBasis;
  final double forecastCost;
  final double forecastCostNet;
  final double forecastProfit;
  final double forecastProfitNet;
  final double forecastMarginPercent;
  final double forecastMarginPercentNet;

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
    this.contractVatKnown = false,
    this.contractVatAmount = 0,
    double? currentContractValueNet,
    double? realizedGrossProfitNet,
    double? realizedMarginPercentNet,
    this.expenseVatTotal = 0,
    double? realizedCostNet,
    double? committedCostNet,
    this.forecastBasis = 'commitments',
    double? forecastCost,
    double? forecastCostNet,
    double? forecastProfit,
    double? forecastProfitNet,
    double? forecastMarginPercent,
    double? forecastMarginPercentNet,
  })  : currentContractValueNet = currentContractValueNet ?? currentContractValue,
        realizedGrossProfitNet = realizedGrossProfitNet ?? realizedGrossProfit,
        realizedMarginPercentNet = realizedMarginPercentNet ?? realizedMarginPercent,
        realizedCostNet = realizedCostNet ?? realizedCost,
        committedCostNet = committedCostNet ?? committedCost,
        forecastCost = forecastCost ?? committedCost,
        forecastCostNet = forecastCostNet ?? forecastCost ?? committedCost,
        forecastProfit = forecastProfit ?? estimatedGrossProfit,
        forecastProfitNet = forecastProfitNet ?? estimatedGrossProfit,
        forecastMarginPercent = forecastMarginPercent ?? estimatedMarginPercent,
        forecastMarginPercentNet = forecastMarginPercentNet ?? estimatedMarginPercent;

  bool get forecastFromBudget => forecastBasis == 'budget';

  /// "Maliyet (KDV hariç)" satırı yalnızca KDV dahilden farklıysa gösterilir
  /// (masraflarda KDV girilmemişse aynı rakamı iki kez yazmanın anlamı yok).
  bool get realizedCostNetDiffers => (realizedCost - realizedCostNet).abs() >= 0.005;
  bool get forecastCostNetDiffers => (forecastCost - forecastCostNet).abs() >= 0.005;

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
        // Yeni alanlar eski sunucuda yok: yoksa KDV dahil değerlere düşülür.
        contractVatKnown: json['contract_vat_known'] as bool? ?? false,
        contractVatAmount: (json['contract_vat_amount'] as num?)?.toDouble() ?? 0,
        currentContractValueNet: (json['current_contract_value_net'] as num?)?.toDouble(),
        realizedGrossProfitNet: (json['realized_gross_profit_net'] as num?)?.toDouble(),
        realizedMarginPercentNet: (json['realized_margin_percent_net'] as num?)?.toDouble(),
        expenseVatTotal: (json['expense_vat_total'] as num?)?.toDouble() ?? 0,
        realizedCostNet: (json['realized_cost_net'] as num?)?.toDouble(),
        committedCostNet: (json['committed_cost_net'] as num?)?.toDouble(),
        forecastBasis: json['forecast_basis'] as String? ?? 'commitments',
        forecastCost: (json['forecast_cost'] as num?)?.toDouble(),
        forecastCostNet: (json['forecast_cost_net'] as num?)?.toDouble(),
        forecastProfit: (json['forecast_profit'] as num?)?.toDouble(),
        forecastProfitNet: (json['forecast_profit_net'] as num?)?.toDouble(),
        forecastMarginPercent: (json['forecast_margin_percent'] as num?)?.toDouble(),
        forecastMarginPercentNet: (json['forecast_margin_percent_net'] as num?)?.toDouble(),
      );
}

/// Masraf onay durumları (backend migration 0060). Her masraf `pending`
/// başlar; para toplamlarına yalnızca `approved` (ve iptal edilmemiş) girer.
const kExpensePending = 'pending';
const kExpenseApproved = 'approved';
const kExpenseRejected = 'rejected';

/// Masraf onaylama/reddetme izni (backend domain.PermProjectsExpensesApprove).
/// Migration 0066'dan beri varsayılan olarak yalnızca Sahip + Yönetici.
const kExpenseApprovePermission = 'projects.expenses.approve';

/// Masraf girme izni (backend domain.PermProjectsExpensesCreate, migration
/// 0066): varsayılan olarak HERKES. Finans yönetme izni olmadan girilen
/// masraf yalnızca temel alanları taşır; kişi yalnızca kendi bekleyen/
/// reddedilen masrafını düzeltir/geri çeker ve "Masraflarım"da yalnızca
/// kendi masraflarını görür.
const kExpenseCreatePermission = 'projects.expenses.create';

/// Masraf formunda sunulan KDV oranları (%); "Belirtilmedi" ayrıca (null).
/// Sunucu 0-100 arası her oranı kabul eder.
const kExpenseVatRates = <double>[0, 1, 10, 20];

class Expense {
  final String id;

  /// Masrafın projesi (backend 0066'dan beri her satırda; "Masraflarım"
  /// projeler arası listeler). Eski sunucuda boş.
  final String projectId;
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

  /// Opsiyonel bağlar (web ExpensesSection): müşteri ek işi, maliyet kodu,
  /// bütçe kalemi (seçilince maliyet kodu ondan gelir, sunucu da uygular).
  final String? changeOrderId;
  final String? costCodeId;
  final String? budgetLineId;

  /// `pending|approved|rejected`. Alan gelmezse (onay akışından önceki
  /// sunucu) `approved` -- o sunucu her masrafı zaten sayıyordu.
  final String approvalStatus;
  final String? decidedAt;

  /// Ret gerekçesi (onayda boş).
  final String decisionNote;

  /// KDV (backend migration 0065): [amount] ödenen tutardır (oran varsa KDV
  /// dahil). [vatRate] null = belirtilmedi; o zaman [vatAmount]/[netAmount]
  /// da null (bilinmeyen KDV sıfır sayılmaz). Tutarları sunucu hesaplar.
  /// Alan gelmezse (eski sunucu) hepsi null.
  final double? vatRate;
  final double? vatAmount;
  final double? netAmount;

  /// Masrafı giren ve iptal eden (backend 0066). Onaylayıcı kendi
  /// masrafında Onayla/Reddet görmez (Sahip hariç); giren kişi kendi
  /// bekleyen/reddedilen masrafını düzeltir. İptal eden giren kişiyse
  /// masraf "geri çekildi". Eski sunucuda null.
  final String? createdBy;
  final String? voidedBy;

  const Expense({
    required this.id,
    this.projectId = '',
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
    this.changeOrderId,
    this.costCodeId,
    this.budgetLineId,
    this.approvalStatus = kExpenseApproved,
    this.decidedAt,
    this.decisionNote = '',
    this.vatRate,
    this.vatAmount,
    this.netAmount,
    this.createdBy,
    this.voidedBy,
  });

  bool get isVoided => voidedAt != null;

  /// [userId] bu masrafı girdi mi (oturum bilinmiyorsa ya da sunucu alanı
  /// göndermiyorsa hayır).
  bool isCreatedBy(String? userId) => userId != null && userId.isNotEmpty && createdBy == userId;

  /// Giren kişi kendisi geri çekti (iptal eden = giren).
  bool get isWithdrawn => isVoided && createdBy != null && voidedBy == createdBy;
  bool get isApproved => approvalStatus == kExpenseApproved;
  bool get isRejected => approvalStatus == kExpenseRejected;

  /// Onay bekleyen (iptal edilmemiş) masraf -- Onayla/Reddet yalnızca bunda.
  bool get isPending => !isVoided && approvalStatus == kExpensePending;

  /// Para toplamlarına girer mi (backend toplamlarıyla aynı kural).
  bool get countsInTotals => !isVoided && isApproved;

  factory Expense.fromJson(Map<String, dynamic> json) => Expense(
        id: json['id'] as String,
        projectId: json['project_id'] as String? ?? '',
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
        changeOrderId: _nonEmptyId(json['change_order_id'] as String?),
        costCodeId: _nonEmptyId(json['cost_code_id'] as String?),
        budgetLineId: _nonEmptyId(json['budget_line_id'] as String?),
        approvalStatus: json['approval_status'] as String? ?? kExpenseApproved,
        decidedAt: json['decided_at'] as String?,
        decisionNote: json['decision_note'] as String? ?? '',
        vatRate: (json['vat_rate'] as num?)?.toDouble(),
        vatAmount: (json['vat_amount'] as num?)?.toDouble(),
        netAmount: (json['net_amount'] as num?)?.toDouble(),
        createdBy: _nonEmptyId(json['created_by'] as String?),
        voidedBy: _nonEmptyId(json['voided_by'] as String?),
      );
}

String? _nonEmptyId(String? v) => (v == null || v.isEmpty) ? null : v;

/// `/projects/{id}/collections` (Tahsilat). `payment_plan_item_id` bağı
/// opsiyoneldir (backend serbest kayda izin verir); 1.4.0+5'ten beri tahsilat
/// formu açık bir ödeme planı kalemine bağlanabilir (web CollectionsSection)
/// -- kalemin "Tahsil Edilen"i bu bağdan hesaplanır.
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

  /// Yalnızca global görev listelerinde (/tasks/mine, /tasks/team): görevin
  /// projesi tamamlandı/iptal edildi mi. Kapalı projenin görevi sunucuda
  /// "gecikmiş" sayılmaz; ekran "Proje kapalı" diye işaretler. Proje
  /// içindeki listelerde alan gelmez (false).
  final bool projectClosed;
  final String? projectStatus;

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
    this.projectClosed = false,
    this.projectStatus,
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
        projectClosed: json['project_closed'] as bool? ?? false,
        projectStatus: json['project_status'] as String?,
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

/// Görev/plan formunun "kime" seçicisi (GET /projects/{id}/assignees):
/// projenin firmasındaki aktif personel, ücretsiz. `hasAccount` false ise
/// kişinin uygulama hesabı yoktur ve atama bildirimi kimseye ulaşmaz.
/// `hasAccount` true iken `hasProjectAccess` false ise kişi projeyi
/// göremez: backend ona görev/plan atamayı reddeder (400) -- bildirim alıp
/// açınca 403 görmesin diye.
class Assignee {
  const Assignee({
    required this.id,
    required this.fullName,
    this.position = '',
    this.hasAccount = false,
    this.hasProjectAccess = true,
  });

  final String id;
  final String fullName;
  final String position;
  final bool hasAccount;
  final bool hasProjectAccess;

  /// Hesabı var ama projeyi göremiyor -- atanamaz.
  bool get lacksProjectAccess => hasAccount && !hasProjectAccess;

  factory Assignee.fromJson(Map<String, dynamic> json) => Assignee(
        id: json['id'] as String,
        fullName: json['full_name'] as String? ?? '',
        position: json['position'] as String? ?? '',
        hasAccount: json['has_account'] as bool? ?? false,
        // Alan yoksa (eski sunucu) erişim bilinmiyor: uyarma, engelleme.
        hasProjectAccess: json['has_project_access'] as bool? ?? true,
      );
}

/// Göreve yazılan bilgi notu (GET/POST /projects/{id}/tasks/{taskId}/updates).
/// `authorName` yazıldığı anki addır; durum değişikliği yoksa
/// `statusFrom`/`statusTo` boş.
class TaskUpdate {
  const TaskUpdate({
    required this.id,
    required this.authorName,
    required this.body,
    required this.statusFrom,
    required this.statusTo,
    required this.createdAt,
  });

  final String id;
  final String authorName;
  final String body;
  final String statusFrom;
  final String statusTo;
  final String createdAt;

  bool get changesStatus => statusTo.isNotEmpty;

  factory TaskUpdate.fromJson(Map<String, dynamic> json) => TaskUpdate(
        id: json['id'] as String,
        authorName: json['author_name'] as String? ?? '',
        body: json['body'] as String? ?? '',
        statusFrom: json['status_from'] as String? ?? '',
        statusTo: json['status_to'] as String? ?? '',
        createdAt: json['created_at'] as String? ?? '',
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

/// Backend `0025_create_project_operations.up.sql` CHECK kısıtlarıyla
/// BİREBİR (photos.stage / files.category) -- yeni bir sözlük İCAT EDİLMEZ.
const kPhotoStages = ['before', 'progress', 'after'];
const kFileCategories = ['contract', 'drawing', 'invoice', 'report', 'other'];

/// Fotoğrafları iş sırasına dizer: önce -> süreç -> sonra (tanınmayan
/// aşama en sonda). Backend aşamayı ALFABETİK sıralıyor ("after" <
/// "before" < "progress"), düz ızgarada "sonra" fotoğrafları başta
/// görünüyordu. Aynı aşama içinde backend'in tarih sırası (çekim/yükleme
/// anı, yeniden eskiye) korunur -- çekim anı istemciye gelmediği için
/// burada yeniden hesaplanmaz.
List<ProjectPhoto> sortPhotosByStage(List<ProjectPhoto> photos) {
  int rank(String stage) {
    final i = kPhotoStages.indexOf(stage);
    return i < 0 ? kPhotoStages.length : i;
  }

  final indexed = [for (var i = 0; i < photos.length; i++) (i, photos[i])];
  // Dart'ın sort'u kararlı değil: eşitlikte özgün sıra belirleyicidir.
  indexed.sort((a, b) {
    final byStage = rank(a.$2.stage).compareTo(rank(b.$2.stage));
    return byStage != 0 ? byStage : a.$1.compareTo(b.$1);
  });
  return [for (final e in indexed) e.$2];
}

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
