import '../../../../core/api/api_client.dart';
import '../domain/offer_history.dart';

/// Teklif geçmişi uçları (backend router.go `/offers` okuma grubu,
/// `offers.read`) -- web teklif detayındaki `ActivityTimeline` ile AYNI
/// çağrılar:
/// - GET /offers/{id}/events      -> `{events: [...]}` (created_at ASC)
/// - GET /offers/{id}/email-logs  -> `{email_logs: [...]}` (sent_at DESC)
/// - GET /offers/{id}/revisions   -> `{revisions: [...]}` (yalnızca
///   `id` -> `revision_no` eşlemesi için okunur)
class OfferHistoryRepository {
  OfferHistoryRepository(this._client);
  final ApiClient _client;

  String _offer(String offerId) => '/offers/${Uri.encodeComponent(offerId)}';

  Future<List<OfferEvent>> events(String offerId) async {
    final json = await _client.get<Map<String, dynamic>>('${_offer(offerId)}/events');
    return (json['events'] as List? ?? const []).cast<Map<String, dynamic>>().map(OfferEvent.fromJson).toList();
  }

  Future<List<OfferEmailLog>> emailLogs(String offerId) async {
    final json = await _client.get<Map<String, dynamic>>('${_offer(offerId)}/email-logs');
    return (json['email_logs'] as List? ?? const [])
        .cast<Map<String, dynamic>>()
        .map(OfferEmailLog.fromJson)
        .toList();
  }

  Future<Map<String, int>> revisionNumbers(String offerId) async {
    final json = await _client.get<Map<String, dynamic>>('${_offer(offerId)}/revisions');
    return {
      for (final r in (json['revisions'] as List? ?? const []).cast<Map<String, dynamic>>())
        r['id'] as String: (r['revision_no'] as num).toInt(),
    };
  }

  /// Üç isteği paralel atar (hepsi aynı izin: `offers.read`).
  Future<OfferHistory> history(String offerId) async {
    final results = await Future.wait<Object>([
      events(offerId),
      emailLogs(offerId),
      revisionNumbers(offerId),
    ]);
    return OfferHistory(
      events: results[0] as List<OfferEvent>,
      emailLogs: results[1] as List<OfferEmailLog>,
      revisionNoById: results[2] as Map<String, int>,
    );
  }
}
