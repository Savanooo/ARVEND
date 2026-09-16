import 'package:dio/dio.dart';

import '../../../core/api/api_client.dart';
import '../domain/project.dart';

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

  Future<List<ProjectTask>> tasks(String projectId) async {
    final json = await _client.get<Map<String, dynamic>>('/projects/$projectId/tasks');
    return (json['tasks'] as List).cast<Map<String, dynamic>>().map(ProjectTask.fromJson).toList();
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
}
