import '../../../core/api/api_client.dart';
import '../domain/offer.dart';

class OffersRepository {
  OffersRepository(this._client);
  final ApiClient _client;

  Future<({List<Offer> offers, int total})> list({String filter = '', int page = 1, int limit = 50}) async {
    final json = await _client.get<Map<String, dynamic>>('/offers/', query: {
      if (filter.isNotEmpty) 'filter': filter,
      'page': page,
      'limit': limit,
    });
    final list = (json['offers'] as List).cast<Map<String, dynamic>>().map(Offer.fromJson).toList();
    return (offers: list, total: json['total'] as int? ?? list.length);
  }

  Future<Offer> get(String id) async {
    final json = await _client.get<Map<String, dynamic>>('/offers/$id');
    return Offer.fromJson(json);
  }

  Future<List<OfferRevision>> revisions(String id) async {
    final json = await _client.get<Map<String, dynamic>>('/offers/$id/revisions');
    return (json['revisions'] as List).cast<Map<String, dynamic>>().map(OfferRevision.fromJson).toList();
  }

  Future<Offer> create({
    String? customerId,
    String customerName = '',
    String customerPhone = '',
    String customerEmail = '',
    String customerAddress = '',
    String? validUntil,
    String notes = '',
    double? vatRate,
    required List<OfferItem> items,
  }) async {
    final json = await _client.post<Map<String, dynamic>>('/offers/', data: {
      'customer_id': customerId,
      'customer_name': customerName,
      'customer_phone': customerPhone,
      'customer_email': customerEmail,
      'customer_address': customerAddress,
      'valid_until': validUntil,
      'notes': notes,
      'vat_rate': vatRate,
      'items': items.map((e) => e.toJson()).toList(),
    });
    return Offer.fromJson(json);
  }

  Future<Offer> updateStatus(String id, String status) async {
    final json = await _client.put<Map<String, dynamic>>('/offers/$id/status', data: {'status': status});
    return Offer.fromJson(json);
  }

  Future<Offer> revise(String id) async {
    final json = await _client.post<Map<String, dynamic>>('/offers/$id/revise');
    return Offer.fromJson(json);
  }

  Future<void> delete(String id) => _client.delete<void>('/offers/$id');

  /// Bir teklif zaten projeye dönüştürülmüş mü? 404 => hayır.
  Future<bool> hasProject(String offerId) async {
    try {
      await _client.get<Map<String, dynamic>>('/offers/$offerId/project');
      return true;
    } on Object {
      return false;
    }
  }

  Future<Map<String, dynamic>> convertToProject(String offerId, {String name = '', String description = ''}) =>
      _client.post<Map<String, dynamic>>('/projects/from-offer/$offerId', data: {
        'name': name,
        'project_type': '',
        'start_date': null,
        'end_date': null,
        'description': description,
      });
}
