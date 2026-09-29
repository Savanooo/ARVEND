import '../../../../core/api/api_client.dart';
import '../../../../core/errors/api_exception.dart';
import '../domain/budget.dart';

/// Proje bütçesi + maliyet kontrolü uçları (backend router.go, Sprint 2) --
/// web `CostControlSections.tsx` ile AYNI çağrılar:
///
/// budget.read:        GET  /projects/{id}/wbs | /budget | /budget/lines | /budget/adjustments
/// budget.manage:      POST /wbs, PUT/DELETE /wbs/{nodeId} (DELETE = arşivle)
///                     POST /budget, POST /budget/baseline
///                     POST /budget/lines, PUT/DELETE /budget/lines/{lineId}
///                     POST /budget/adjustments, POST .../{adjId}/approve|reject
/// cost_control.read:  GET  /commitments | /forecasts | /cost-control
/// cost_control.manage:POST /commitments, POST /commitments/{cId}/void
///                     PUT  /budget/lines/{lineId}/forecast
///
/// Ek olarak (salt seçici/kırılım için): GET /organization/cost-codes
/// (organization.cost_codes.read) ve GET /projects/{id}/expenses
/// (projects.finance.read).
class BudgetRepository {
  BudgetRepository(this._client);
  final ApiClient _client;

  String _p(String projectId) => '/projects/$projectId';

  // ---------- WBS ----------

  Future<List<WbsNode>> wbsNodes(String projectId) async {
    final json = await _client.get<Map<String, dynamic>>('${_p(projectId)}/wbs');
    return (json['wbs_nodes'] as List? ?? const []).cast<Map<String, dynamic>>().map(WbsNode.fromJson).toList();
  }

  Future<WbsNode> createWbsNode(String projectId, WbsNodeInput input) async {
    final json = await _client.post<Map<String, dynamic>>('${_p(projectId)}/wbs', data: input.toJson());
    return WbsNode.fromJson(json);
  }

  Future<WbsNode> updateWbsNode(String projectId, String nodeId, WbsNodeInput input) async {
    final json = await _client.put<Map<String, dynamic>>('${_p(projectId)}/wbs/$nodeId', data: input.toJson());
    return WbsNode.fromJson(json);
  }

  /// HARD DELETE DEĞİL -- `is_active=false` (bağlı bütçe kalemleri etkilenmez).
  Future<void> archiveWbsNode(String projectId, String nodeId) => _client.delete<void>('${_p(projectId)}/wbs/$nodeId');

  // ---------- Bütçe ----------

  /// Bütçesi olmayan projede backend 404 döner -- bu geçerli bir durumdur
  /// ("Bütçe Oluştur" CTA'sı), null'a çevrilir. Diğer hatalar aynen fırlar.
  Future<ProjectBudget?> budget(String projectId) async {
    try {
      final json = await _client.get<Map<String, dynamic>>('${_p(projectId)}/budget');
      return ProjectBudget.fromJson(json);
    } on ApiException catch (e) {
      if (e.kind == ApiErrorKind.notFound) return null;
      rethrow;
    }
  }

  Future<ProjectBudget> createBudget(String projectId) async {
    final json = await _client.post<Map<String, dynamic>>('${_p(projectId)}/budget');
    return ProjectBudget.fromJson(json);
  }

  /// TEK YÖNLÜ geçiş (draft -> baselined); geri alma ucu YOK.
  Future<ProjectBudget> baselineBudget(String projectId) async {
    final json = await _client.post<Map<String, dynamic>>('${_p(projectId)}/budget/baseline');
    return ProjectBudget.fromJson(json);
  }

  /// Bütçe yoksa 404 -> boş liste.
  Future<List<BudgetLine>> budgetLines(String projectId) async {
    try {
      final json = await _client.get<Map<String, dynamic>>('${_p(projectId)}/budget/lines');
      return (json['budget_lines'] as List? ?? const []).cast<Map<String, dynamic>>().map(BudgetLine.fromJson).toList();
    } on ApiException catch (e) {
      if (e.kind == ApiErrorKind.notFound) return const [];
      rethrow;
    }
  }

  Future<BudgetLine> createBudgetLine(String projectId, BudgetLineInput input) async {
    final json = await _client.post<Map<String, dynamic>>('${_p(projectId)}/budget/lines', data: input.toJson());
    return BudgetLine.fromJson(json);
  }

  Future<BudgetLine> updateBudgetLine(String projectId, String lineId, BudgetLineInput input) async {
    final json = await _client.put<Map<String, dynamic>>('${_p(projectId)}/budget/lines/$lineId', data: input.toJson());
    return BudgetLine.fromJson(json);
  }

  /// Yalnızca TASLAK bütçede (baseline sonrası 409).
  Future<void> deleteBudgetLine(String projectId, String lineId) =>
      _client.delete<void>('${_p(projectId)}/budget/lines/$lineId');

  // ---------- Revizyonlar ----------

  Future<List<BudgetAdjustment>> adjustments(String projectId) async {
    final json = await _client.get<Map<String, dynamic>>('${_p(projectId)}/budget/adjustments');
    return (json['adjustments'] as List? ?? const [])
        .cast<Map<String, dynamic>>()
        .map(BudgetAdjustment.fromJson)
        .toList();
  }

  Future<BudgetAdjustment> createAdjustment(
    String projectId, {
    required String budgetLineId,
    required double amount,
    required String reason,
  }) async {
    final json = await _client.post<Map<String, dynamic>>(
      '${_p(projectId)}/budget/adjustments',
      data: {'budget_line_id': budgetLineId, 'amount': amount, 'reason': reason},
    );
    return BudgetAdjustment.fromJson(json);
  }

  Future<BudgetAdjustment> approveAdjustment(String projectId, String adjustmentId) async {
    final json = await _client.post<Map<String, dynamic>>('${_p(projectId)}/budget/adjustments/$adjustmentId/approve');
    return BudgetAdjustment.fromJson(json);
  }

  Future<BudgetAdjustment> rejectAdjustment(String projectId, String adjustmentId) async {
    final json = await _client.post<Map<String, dynamic>>('${_p(projectId)}/budget/adjustments/$adjustmentId/reject');
    return BudgetAdjustment.fromJson(json);
  }

  // ---------- Taahhütler ----------

  Future<List<Commitment>> commitments(String projectId) async {
    final json = await _client.get<Map<String, dynamic>>('${_p(projectId)}/commitments');
    return (json['commitments'] as List? ?? const []).cast<Map<String, dynamic>>().map(Commitment.fromJson).toList();
  }

  Future<Commitment> createCommitment(String projectId, ManualCommitmentInput input) async {
    final json = await _client.post<Map<String, dynamic>>('${_p(projectId)}/commitments', data: input.toJson());
    return Commitment.fromJson(json);
  }

  Future<Commitment> voidCommitment(String projectId, String commitmentId, {required String reason}) async {
    final json = await _client.post<Map<String, dynamic>>(
      '${_p(projectId)}/commitments/$commitmentId/void',
      data: {'reason': reason},
    );
    return Commitment.fromJson(json);
  }

  // ---------- Tahmin (ETC) ----------

  Future<List<CostForecast>> forecasts(String projectId) async {
    final json = await _client.get<Map<String, dynamic>>('${_p(projectId)}/forecasts');
    return (json['forecasts'] as List? ?? const []).cast<Map<String, dynamic>>().map(CostForecast.fromJson).toList();
  }

  Future<CostForecast> upsertForecast(
    String projectId,
    String budgetLineId, {
    required double etcAmount,
    String note = '',
  }) async {
    final json = await _client.put<Map<String, dynamic>>(
      '${_p(projectId)}/budget/lines/$budgetLineId/forecast',
      data: {'etc_amount': etcAmount, 'note': note},
    );
    return CostForecast.fromJson(json);
  }

  // ---------- Maliyet Kontrolü özeti + kırılım ----------

  /// Bütçesiz projede de 200 (`has_budget=false`).
  Future<CostControlData> costControl(String projectId) async {
    final json = await _client.get<Map<String, dynamic>>('${_p(projectId)}/cost-control');
    final summary = CostControlSummary.fromJson(json['summary'] as Map<String, dynamic>);
    final lines = (json['lines'] as List? ?? const [])
        .cast<Map<String, dynamic>>()
        .map(CostControlLine.fromJson)
        .toList();
    return (summary: summary, lines: lines);
  }

  // ---------- Seçici / kırılım kaynakları ----------

  Future<List<OrgCostCode>> costCodes() async {
    final json = await _client.get<Map<String, dynamic>>('/organization/cost-codes');
    return (json['cost_codes'] as List? ?? const []).cast<Map<String, dynamic>>().map(OrgCostCode.fromJson).toList();
  }

  Future<List<ActualExpense>> expenses(String projectId) async {
    final json = await _client.get<Map<String, dynamic>>('${_p(projectId)}/expenses');
    return (json['expenses'] as List? ?? const []).cast<Map<String, dynamic>>().map(ActualExpense.fromJson).toList();
  }
}
