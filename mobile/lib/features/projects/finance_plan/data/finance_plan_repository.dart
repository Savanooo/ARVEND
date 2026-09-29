import '../../../../core/api/api_client.dart';
import '../domain/payment_plan.dart';
import '../domain/project_invoice.dart';

/// Proje Finans grubunun ödeme planı + fatura uçları (backend router.go,
/// `/projects/{id}` altı; web `projeler/[id]/FinanceSections.tsx` ile aynı
/// çağrılar). Okuma `projects.finance.read`, yazma `projects.finance.manage`
/// + proje üyeliği ister (`projPerm`, sunucuda her istekte doğrulanır).
///
/// Ödeme planı:
/// - GET    /payment-plan              -> `{items: [...], planned_total}`
/// - POST   /payment-plan              -> kalem (201)
/// - PUT    /payment-plan/{itemId}     -> kalem (TAM güncelleme)
/// - DELETE /payment-plan/{itemId}     -> kalemi İPTAL eder (satır silinmez)
///
/// Faturalar:
/// - GET  /invoices                    -> `{invoices: [...]}`
/// - POST /invoices                    -> fatura (201)
/// - PUT  /invoices/{invoiceId}/status -> `{status}` (fatura alanlarını
///   düzenleyen bir uç YOK)
///
/// Tamamlanmış/iptal edilmiş projede oluşturma/güncelleme 409 döner
/// ("tamamlanmış veya iptal edilmiş projede yeni finans hareketi
/// oluşturulamaz").
class FinancePlanRepository {
  FinancePlanRepository(this._client);
  final ApiClient _client;

  String _base(String projectId) => '/projects/$projectId';

  Future<PaymentPlan> paymentPlan(String projectId) async {
    final json = await _client.get<Map<String, dynamic>>('${_base(projectId)}/payment-plan');
    return PaymentPlan.fromJson(json);
  }

  Future<PaymentPlanItem> createPlanItem(String projectId, PaymentPlanItemInput input) async {
    final json = await _client.post<Map<String, dynamic>>('${_base(projectId)}/payment-plan', data: input.toJson());
    return PaymentPlanItem.fromJson(json);
  }

  Future<PaymentPlanItem> updatePlanItem(String projectId, String itemId, PaymentPlanItemInput input) async {
    final json = await _client.put<Map<String, dynamic>>(
      '${_base(projectId)}/payment-plan/$itemId',
      data: input.toJson(),
    );
    return PaymentPlanItem.fromJson(json);
  }

  Future<void> cancelPlanItem(String projectId, String itemId) =>
      _client.delete<void>('${_base(projectId)}/payment-plan/$itemId');

  Future<List<ProjectInvoice>> invoices(String projectId) async {
    final json = await _client.get<Map<String, dynamic>>('${_base(projectId)}/invoices');
    return (json['invoices'] as List? ?? const [])
        .cast<Map<String, dynamic>>()
        .map(ProjectInvoice.fromJson)
        .toList();
  }

  Future<ProjectInvoice> createInvoice(String projectId, InvoiceInput input) async {
    final json = await _client.post<Map<String, dynamic>>('${_base(projectId)}/invoices', data: input.toJson());
    return ProjectInvoice.fromJson(json);
  }

  Future<ProjectInvoice> updateInvoiceStatus(String projectId, String invoiceId, String status) async {
    final json = await _client.put<Map<String, dynamic>>(
      '${_base(projectId)}/invoices/$invoiceId/status',
      data: {'status': status},
    );
    return ProjectInvoice.fromJson(json);
  }
}
