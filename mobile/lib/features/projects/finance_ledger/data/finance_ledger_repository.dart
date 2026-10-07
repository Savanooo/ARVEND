import '../../../../core/api/api_client.dart';
import '../domain/legacy_subcontractor.dart';

/// Proje Finans defterinin tahsilat/masraf dışındaki uçları. Hepsi
/// `projPerm` -- izin + proje üyeliği SUNUCUDA denetlenir:
///
/// Taşeron Ödemeleri (legacy, `projects.finance.read` / `.manage`):
/// - GET  /projects/{id}/subcontractors                      -> `{subcontractors}`
/// - GET  /projects/{id}/subcontractor-payments              -> `{payments}`
/// - POST /projects/{id}/subcontractors                      -> `{name, company_name,
///   work_description, contract_amount, currency}` (201; kapalı projede 409)
/// - POST /projects/{id}/subcontractors/{subId}/payments      -> `{amount, currency,
///   paid_date, description, idempotency_key}` (201; anahtar TAŞERON başına)
/// - PUT  /projects/{id}/subcontractors/{subId}               -> tüm alanlar (TAM
///   yazma: gönderilmeyen alan silinir; sözleşme bedeli > 0, durum geçerli olmalı)
/// - POST /projects/{id}/subcontractor-payments/{payId}/void  -> `{reason}`
///
/// Tahsilat/masraf iptali (`POST .../collections|expenses/{id}/void
/// {reason}`) ProjectsRepository'dedir (`voidCollection` / `voidExpense`).
class FinanceLedgerRepository {
  FinanceLedgerRepository(this._client);
  final ApiClient _client;

  String _p(String projectId) => '/projects/${Uri.encodeComponent(projectId)}';

  Future<List<LegacySubcontractor>> subcontractors(String projectId) async {
    final json = await _client.get<Map<String, dynamic>>('${_p(projectId)}/subcontractors');
    return (json['subcontractors'] as List? ?? const [])
        .cast<Map<String, dynamic>>()
        .map(LegacySubcontractor.fromJson)
        .toList();
  }

  Future<List<LegacySubcontractorPayment>> subcontractorPayments(String projectId) async {
    final json = await _client.get<Map<String, dynamic>>('${_p(projectId)}/subcontractor-payments');
    return (json['payments'] as List? ?? const [])
        .cast<Map<String, dynamic>>()
        .map(LegacySubcontractorPayment.fromJson)
        .toList();
  }

  Future<LegacySubcontractor> createSubcontractor(
    String projectId, {
    required String name,
    required double contractAmount,
    required String currency,
    String companyName = '',
    String workDescription = '',
  }) async {
    final json = await _client.post<Map<String, dynamic>>('${_p(projectId)}/subcontractors', data: {
      'name': name,
      'company_name': companyName,
      'work_description': workDescription,
      'contract_amount': contractAmount,
      'currency': currency,
    });
    return LegacySubcontractor.fromJson(json);
  }

  /// Legacy taşeron kaydını düzeltir (ad, firma, yapılan iş, sözleşme
  /// bedeli). Sunucu kaydı TAMAMEN yeniden yazar -- formda olmayan telefon/
  /// e-posta/tarih/durum/not/maliyet kodu [existing]'den aynen geri
  /// gönderilir, yoksa sessizce silinirdi. Para birimi sunucuda değişmez.
  Future<LegacySubcontractor> updateSubcontractor(
    String projectId,
    LegacySubcontractor existing, {
    required String name,
    required String companyName,
    required String workDescription,
    required double contractAmount,
  }) async {
    final json = await _client.put<Map<String, dynamic>>(
      '${_p(projectId)}/subcontractors/${Uri.encodeComponent(existing.id)}',
      data: {
        'name': name,
        'company_name': companyName,
        'work_description': workDescription,
        'contract_amount': contractAmount,
        'currency': existing.currency,
        'phone': existing.phone,
        'email': existing.email,
        'start_date': existing.startDate,
        'end_date': existing.endDate,
        'status': existing.status,
        'notes': existing.notes,
        'cost_code_id': existing.costCodeId ?? '',
      },
    );
    return LegacySubcontractor.fromJson(json);
  }

  /// Ödemeyi iptal eder (kayıt silinmez; ödenen tutardan ve gerçekleşen
  /// maliyetten düşer).
  Future<void> voidSubcontractorPayment(String projectId, String paymentId, {String reason = ''}) => _client.post<void>(
        '${_p(projectId)}/subcontractor-payments/${Uri.encodeComponent(paymentId)}/void',
        data: {'reason': reason},
      );

  Future<LegacySubcontractorPayment> createSubcontractorPayment(
    String projectId,
    String subcontractorId, {
    required double amount,
    required String currency,
    required String paidDate,
    required String idempotencyKey,
    String description = '',
  }) async {
    final json = await _client.post<Map<String, dynamic>>(
      '${_p(projectId)}/subcontractors/${Uri.encodeComponent(subcontractorId)}/payments',
      data: {
        'amount': amount,
        'currency': currency,
        'paid_date': paidDate,
        'description': description,
        'idempotency_key': idempotencyKey,
      },
    );
    return LegacySubcontractorPayment.fromJson(json);
  }
}
