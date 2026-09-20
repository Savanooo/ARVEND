import 'package:dio/dio.dart';

import '../../../core/api/api_client.dart';
import '../domain/procurement.dart';
import '../domain/project.dart';
import '../domain/subcontract.dart';

class ProjectsRepository {
  ProjectsRepository(this._client);
  final ApiClient _client;

  Future<({List<Project> projects, int total})> list({
    String? status,
    String? q,
    int page = 1,
    int limit = 50,
  }) async {
    final json = await _client.get<Map<String, dynamic>>('/projects', query: {
      if (status != null && status.isNotEmpty) 'status': status,
      if (q != null && q.isNotEmpty) 'q': q,
      'page': page,
      'limit': limit,
    });
    final list = (json['projects'] as List).cast<Map<String, dynamic>>().map(Project.fromJson).toList();
    return (projects: list, total: json['total'] as int? ?? list.length);
  }

  Future<Project> get(String id) async {
    final json = await _client.get<Map<String, dynamic>>('/projects/$id');
    return Project.fromJson(json);
  }

  Future<FinancialSummary> financialSummary(String id) async {
    final json = await _client.get<Map<String, dynamic>>('/projects/$id/financial-summary');
    return FinancialSummary.fromJson(json);
  }

  Future<List<Expense>> expenses(String projectId) async {
    final json = await _client.get<Map<String, dynamic>>('/projects/$projectId/expenses');
    return (json['expenses'] as List).cast<Map<String, dynamic>>().map(Expense.fromJson).toList();
  }

  Future<Expense> createExpense(
    String projectId, {
    required String category,
    required String description,
    required double amount,
    String currency = '',
    String? expenseDate,
    String supplierName = '',
    String invoiceNo = '',
    String notes = '',
    String changeOrderId = '',
  }) async {
    final json = await _client.post<Map<String, dynamic>>('/projects/$projectId/expenses', data: {
      'category': category,
      'description': description,
      'amount': amount,
      'currency': currency,
      'expense_date': expenseDate ?? '',
      'supplier_name': supplierName,
      'invoice_no': invoiceNo,
      'notes': notes,
      'idempotency_key': '${DateTime.now().microsecondsSinceEpoch}',
      'change_order_id': changeOrderId,
    });
    return Expense.fromJson(json);
  }

  Future<void> voidExpense(String projectId, String expenseId, {String reason = ''}) => _client
      .post<void>('/projects/$projectId/expenses/$expenseId/void', data: {'reason': reason});

  Future<List<Collection>> collections(String projectId) async {
    final json = await _client.get<Map<String, dynamic>>('/projects/$projectId/collections');
    return (json['collections'] as List).cast<Map<String, dynamic>>().map(Collection.fromJson).toList();
  }

  Future<Collection> createCollection(
    String projectId, {
    required double amount,
    required String receivedDate,
    String paymentMethod = '',
    String description = '',
    String referenceNo = '',
  }) async {
    final json = await _client.post<Map<String, dynamic>>('/projects/$projectId/collections', data: {
      'amount': amount,
      'received_date': receivedDate,
      'payment_method': paymentMethod,
      'description': description,
      'reference_no': referenceNo,
      'idempotency_key': '${DateTime.now().microsecondsSinceEpoch}',
    });
    return Collection.fromJson(json);
  }

  Future<void> voidCollection(String projectId, String collectionId, {String reason = ''}) => _client
      .post<void>('/projects/$projectId/collections/$collectionId/void', data: {'reason': reason});

  Future<List<ProjectTask>> tasks(String projectId) async {
    final json = await _client.get<Map<String, dynamic>>('/projects/$projectId/tasks');
    return (json['tasks'] as List).cast<Map<String, dynamic>>().map(ProjectTask.fromJson).toList();
  }

  /// GET /tasks/mine — org+proje erişimindeki görevler (tek sorgu; O(N) döngü yok).
  Future<List<(ProjectTask, String, String)>> myTasks({String status = 'open'}) async {
    final json = await _client.get<Map<String, dynamic>>(
      '/tasks/mine',
      query: {'status': status},
    );
    final list = (json['tasks'] as List).cast<Map<String, dynamic>>();
    return [
      for (final m in list)
        (
          ProjectTask.fromJson(m),
          m['project_id'] as String? ?? '',
          m['project_name'] as String? ?? '',
        ),
    ];
  }

  Future<ProjectTask> completeTask(String projectId, String taskId) async {
    final json = await _client.post<Map<String, dynamic>>('/projects/$projectId/tasks/$taskId/complete');
    return ProjectTask.fromJson(json);
  }

  Future<ProjectTask> createTask(
    String projectId, {
    required String title,
    String description = '',
    String? assignedEmployeeId,
    String priority = 'normal',
    String? dueDate,
  }) async {
    final json = await _client.post<Map<String, dynamic>>('/projects/$projectId/tasks', data: {
      'title': title,
      'description': description,
      'schedule_item_id': null,
      'assigned_employee_id': assignedEmployeeId,
      'priority': priority,
      'status': 'todo',
      'due_date': dueDate,
    });
    return ProjectTask.fromJson(json);
  }

  Future<List<ProjectPhoto>> photos(String projectId) async {
    final json = await _client.get<Map<String, dynamic>>('/projects/$projectId/photos');
    return (json['photos'] as List).cast<Map<String, dynamic>>().map(ProjectPhoto.fromJson).toList();
  }

  Future<List<ProjectFile>> files(String projectId) async {
    final json = await _client.get<Map<String, dynamic>>('/projects/$projectId/files');
    return (json['files'] as List).cast<Map<String, dynamic>>().map(ProjectFile.fromJson).toList();
  }



  Future<List<ProjectNote>> notes(String projectId) async {
    final json = await _client.get<Map<String, dynamic>>('/projects/$projectId/notes');
    return (json['notes'] as List).cast<Map<String, dynamic>>().map(ProjectNote.fromJson).toList();
  }

  Future<ProjectNote> createNote(String projectId, {required String content}) async {
    final json = await _client.post<Map<String, dynamic>>(
      '/projects/$projectId/notes',
      data: {'content': content},
    );
    return ProjectNote.fromJson(json);
  }

  String photoContentUrl(String projectId, String photoId) =>
      '${_client.dio.options.baseUrl}/projects/$projectId/photos/$photoId/content';

  /// bkz. API_CONTRACT.md#operations - multipart alan adı HER İKİ uç için de
  /// `file`; boyut ön-kontrolü (25 MiB) çağıran tarafta (UI) yapılır ki
  /// limiti aşan bir istek hiç gönderilmeye çalışılmasın.
  Future<ProjectPhoto> uploadPhoto(
    String projectId, {
    required String filePath,
    required String fileName,
    String stage = 'progress',
    String description = '',
    void Function(int sent, int total)? onSendProgress,
  }) async {
    final form = FormData.fromMap({
      'file': await MultipartFile.fromFile(filePath, filename: fileName),
      'stage': stage,
      'description': description,
    });
    final json = await _client.upload<Map<String, dynamic>>(
      '/projects/$projectId/photos',
      form,
      onSendProgress: onSendProgress,
    );
    return ProjectPhoto.fromJson(json);
  }

  Future<ProjectFile> uploadFile(
    String projectId, {
    required String filePath,
    required String fileName,
    String category = 'other',
    String description = '',
    void Function(int sent, int total)? onSendProgress,
  }) async {
    final form = FormData.fromMap({
      'file': await MultipartFile.fromFile(filePath, filename: fileName),
      'category': category,
      'description': description,
    });
    final json = await _client.upload<Map<String, dynamic>>(
      '/projects/$projectId/files',
      form,
      onSendProgress: onSendProgress,
    );
    return ProjectFile.fromJson(json);
  }

  Future<List<Map<String, dynamic>>> events(String projectId) async {
    final json = await _client.get<Map<String, dynamic>>('/projects/$projectId/events');
    return (json['events'] as List).cast<Map<String, dynamic>>();
  }

  /// Sprint 2 — Maliyet Kontrolü, mobilde YALNIZCA OKUMA (bkz. docs/cost-
  /// control.md "Mobile"). TEK istekte özet+kırılım döner (N+1 yok) --
  /// bütçesiz bir projede bile 200 döner (has_budget=false ile).
  Future<({CostControlSummary summary, List<CostControlLine> lines})> costControl(String projectId) async {
    final json = await _client.get<Map<String, dynamic>>('/projects/$projectId/cost-control');
    final summary = CostControlSummary.fromJson(json['summary'] as Map<String, dynamic>);
    final lines = (json['lines'] as List).cast<Map<String, dynamic>>().map(CostControlLine.fromJson).toList();
    return (summary: summary, lines: lines);
  }

  /// Sprint 3 — Ek İşler, mobilde YALNIZCA OKUMA (bkz. docs/contracts.md
  /// "Mobil"). Web ile AYNI uç, izin de AYNI (projects.finance.read) --
  /// backend'de bu sprint için ayrı bir mobil izin tanımlanmadı.
  Future<List<ChangeOrder>> changeOrders(String projectId) async {
    final json = await _client.get<Map<String, dynamic>>('/projects/$projectId/change-orders');
    return (json['change_orders'] as List).cast<Map<String, dynamic>>().map(ChangeOrder.fromJson).toList();
  }

  /// Sprint 4 — Satın Alma, mobilde YALNIZCA OKUMA (bkz. domain/procurement.dart
  /// dosya başı notu). İzin: projects.procurement.read (Ek İşler'in aksine bu
  /// sprint için AYRI, yeni bir izin -- web ile AYNI uç ve AYNI izin).
  Future<List<PurchaseRequest>> purchaseRequests(String projectId) async {
    final json = await _client.get<Map<String, dynamic>>('/projects/$projectId/purchase-requests');
    return (json['purchase_requests'] as List).cast<Map<String, dynamic>>().map(PurchaseRequest.fromJson).toList();
  }

  Future<({PurchaseRequest request, List<PurchaseRequestItem> items})> purchaseRequestDetail(
      String projectId, String prId) async {
    final json = await _client.get<Map<String, dynamic>>('/projects/$projectId/purchase-requests/$prId');
    final request = PurchaseRequest.fromJson(json['purchase_request'] as Map<String, dynamic>);
    final items =
        (json['items'] as List).cast<Map<String, dynamic>>().map(PurchaseRequestItem.fromJson).toList();
    return (request: request, items: items);
  }

  Future<List<PurchaseOrder>> purchaseOrders(String projectId) async {
    final json = await _client.get<Map<String, dynamic>>('/projects/$projectId/purchase-orders');
    return (json['purchase_orders'] as List).cast<Map<String, dynamic>>().map(PurchaseOrder.fromJson).toList();
  }

  /// `commitments` alanı kasıtlı olarak yoksayılır -- maliyet-kontrolü
  /// detayı web-first bir kapsam (bkz. Sprint 4 spec'i).
  Future<({PurchaseOrder order, List<PurchaseOrderItem> items})> purchaseOrderDetail(
      String projectId, String poId) async {
    final json = await _client.get<Map<String, dynamic>>('/projects/$projectId/purchase-orders/$poId');
    final order = PurchaseOrder.fromJson(json['purchase_order'] as Map<String, dynamic>);
    final items = (json['items'] as List).cast<Map<String, dynamic>>().map(PurchaseOrderItem.fromJson).toList();
    return (order: order, items: items);
  }

  /// Sprint 5 — Taşeron Yönetimi (yeni modül). `/subcontracts` -- legacy
  /// `/subcontractors` İLE KARIŞTIRILMAMALI (bkz. domain/subcontract.dart
  /// dosya başı notu).
  Future<List<Subcontract>> subcontracts(String projectId) async {
    final json = await _client.get<Map<String, dynamic>>('/projects/$projectId/subcontracts');
    return (json['subcontracts'] as List).cast<Map<String, dynamic>>().map(Subcontract.fromJson).toList();
  }

  Future<({Subcontract subcontract, List<SubcontractItem> items, SubcontractValue value})> subcontractDetail(
      String projectId, String subcontractId) async {
    final json = await _client.get<Map<String, dynamic>>('/projects/$projectId/subcontracts/$subcontractId');
    final subcontract = Subcontract.fromJson(json['subcontract'] as Map<String, dynamic>);
    final items = (json['items'] as List).cast<Map<String, dynamic>>().map(SubcontractItem.fromJson).toList();
    final value = SubcontractValue.fromJson(json['current_value'] as Map<String, dynamic>);
    return (subcontract: subcontract, items: items, value: value);
  }

  Future<List<SubcontractPayment>> subcontractPayments(String projectId, String subcontractId) async {
    final json = await _client.get<Map<String, dynamic>>('/projects/$projectId/subcontracts/$subcontractId/payments');
    return (json['payments'] as List).cast<Map<String, dynamic>>().map(SubcontractPayment.fromJson).toList();
  }

  Future<SubcontractPayment> createSubcontractPayment(
    String projectId,
    String subcontractId, {
    required double amount,
    required String paidDate,
    String paymentMethod = '',
    String referenceNo = '',
    String description = '',
    String? progressClaimId,
  }) async {
    final json = await _client.post<Map<String, dynamic>>(
      '/projects/$projectId/subcontracts/$subcontractId/payments',
      data: {
        'amount': amount,
        'paid_date': paidDate,
        'payment_method': paymentMethod,
        'reference_no': referenceNo,
        'description': description,
        'progress_claim_id': progressClaimId,
        'idempotency_key': '${DateTime.now().microsecondsSinceEpoch}',
      },
    );
    return SubcontractPayment.fromJson(json);
  }

  Future<void> voidSubcontractPayment(String projectId, String paymentId, {String reason = ''}) => _client
      .post<void>('/projects/$projectId/subcontract-payments/$paymentId/void', data: {'reason': reason});

  Future<List<ProgressClaim>> subcontractProgressClaims(String projectId, String subcontractId) async {
    final json =
        await _client.get<Map<String, dynamic>>('/projects/$projectId/subcontracts/$subcontractId/progress-claims');
    return (json['progress_claims'] as List).cast<Map<String, dynamic>>().map(ProgressClaim.fromJson).toList();
  }

  /// Sprint 4 tedarikçi kataloğu (organizasyon-seviyeli, proje-bağımsız) --
  /// mobilde tek kullanım yeri: Taşeron Sözleşmesi'nde tedarikçi seçimi
  /// (bkz. domain/subcontract.dart `Supplier` yorumu). Filtre YOK -- backend
  /// TÜM tedarikçileri (aktif+pasif) döner, aktiflik istemci tarafında
  /// süzülür (yeni bir backend sorgu parametresi İCAT EDİLMEDİ).
  Future<List<Supplier>> suppliers() async {
    final json = await _client.get<Map<String, dynamic>>('/organization/suppliers');
    return (json['suppliers'] as List).cast<Map<String, dynamic>>().map(Supplier.fromJson).toList();
  }

  /// Organizasyon-seviyeli maliyet kodu kataloğu -- SOV kalemi girişinde
  /// zorunlu `cost_code_id` seçimi için (bkz. `OrgCostCode` yorumu).
  Future<List<OrgCostCode>> costCodes() async {
    final json = await _client.get<Map<String, dynamic>>('/organization/cost-codes');
    return (json['cost_codes'] as List).cast<Map<String, dynamic>>().map(OrgCostCode.fromJson).toList();
  }

  Map<String, dynamic> _subcontractBody({
    required String supplierId,
    required String title,
    String scopeSummary = '',
    String? effectiveDate,
    String? startDate,
    String? plannedCompletionDate,
    double? retentionPercent,
    double? advanceAmount,
    String paymentTerms = '',
    String notes = '',
    required List<SubcontractItem> items,
  }) =>
      {
        'supplier_id': supplierId,
        'title': title,
        'scope_summary': scopeSummary,
        'effective_date': effectiveDate,
        'start_date': startDate,
        'planned_completion_date': plannedCompletionDate,
        'retention_percent': retentionPercent,
        'advance_amount': advanceAmount,
        'payment_terms': paymentTerms,
        'notes': notes,
        'items': items.map((i) => i.toJson()).toList(),
      };

  /// Backend ≥1 SOV kalemi ZORUNLU kılar (`items` boşsa 409) -- bkz. backend
  /// service `ErrSubcontractItemsRequired`.
  Future<Subcontract> createSubcontract(
    String projectId, {
    required String supplierId,
    required String title,
    String scopeSummary = '',
    String? effectiveDate,
    String? startDate,
    String? plannedCompletionDate,
    double? retentionPercent,
    double? advanceAmount,
    String paymentTerms = '',
    String notes = '',
    required List<SubcontractItem> items,
  }) async {
    final json = await _client.post<Map<String, dynamic>>(
      '/projects/$projectId/subcontracts',
      data: _subcontractBody(
        supplierId: supplierId, title: title, scopeSummary: scopeSummary, effectiveDate: effectiveDate,
        startDate: startDate, plannedCompletionDate: plannedCompletionDate, retentionPercent: retentionPercent,
        advanceAmount: advanceAmount, paymentTerms: paymentTerms, notes: notes, items: items,
      ),
    );
    return Subcontract.fromJson(json);
  }

  /// Backend YALNIZCA `draft` durumundayken kabul eder (bkz.
  /// `ErrSubcontractNotEditable`) VE kalem listesini TAMAMEN yeniden yazar --
  /// çağıran taraf DEĞİŞMEYEN mevcut kalemleri de `items` içinde
  /// göndermelidir (bkz. `SubcontractItem.toJson` yorumu).
  Future<Subcontract> updateSubcontract(
    String projectId,
    String subcontractId, {
    required String supplierId,
    required String title,
    String scopeSummary = '',
    String? effectiveDate,
    String? startDate,
    String? plannedCompletionDate,
    double? retentionPercent,
    double? advanceAmount,
    String paymentTerms = '',
    String notes = '',
    required List<SubcontractItem> items,
  }) async {
    final json = await _client.put<Map<String, dynamic>>(
      '/projects/$projectId/subcontracts/$subcontractId',
      data: _subcontractBody(
        supplierId: supplierId, title: title, scopeSummary: scopeSummary, effectiveDate: effectiveDate,
        startDate: startDate, plannedCompletionDate: plannedCompletionDate, retentionPercent: retentionPercent,
        advanceAmount: advanceAmount, paymentTerms: paymentTerms, notes: notes, items: items,
      ),
    );
    return Subcontract.fromJson(json);
  }

  Future<Subcontract> activateSubcontract(String projectId, String subcontractId) async {
    final json = await _client.post<Map<String, dynamic>>('/projects/$projectId/subcontracts/$subcontractId/activate');
    return Subcontract.fromJson(json);
  }

  /// Tamamlanma commitment'a DOKUNMAZ (bkz. backend service yorumu) --
  /// yalnızca durum geçişi.
  Future<Subcontract> completeSubcontract(String projectId, String subcontractId) async {
    final json = await _client.post<Map<String, dynamic>>('/projects/$projectId/subcontracts/$subcontractId/complete');
    return Subcontract.fromJson(json);
  }

  /// Backend YALNIZCA `draft`tan kabul eder -- `active`ten iptal DEĞİL,
  /// FESİH (`terminateSubcontract`) kullanılır.
  Future<Subcontract> cancelSubcontract(String projectId, String subcontractId, {required String reason}) async {
    final json = await _client.post<Map<String, dynamic>>(
      '/projects/$projectId/subcontracts/$subcontractId/cancel',
      data: {'reason': reason},
    );
    return Subcontract.fromJson(json);
  }

  /// Backend YALNIZCA `active`ten kabul eder -- sertifikalı (hakediş
  /// edilmiş) taahhüt KORUNUR, kalanı serbest bırakılır (bkz. backend
  /// service yorumu).
  Future<Subcontract> terminateSubcontract(String projectId, String subcontractId, {required String reason}) async {
    final json = await _client.post<Map<String, dynamic>>(
      '/projects/$projectId/subcontracts/$subcontractId/terminate',
      data: {'reason': reason},
    );
    return Subcontract.fromJson(json);
  }
}
