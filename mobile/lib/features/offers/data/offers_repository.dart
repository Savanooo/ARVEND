import '../../../core/api/api_client.dart';
import '../domain/offer.dart';

class OffersRepository {
  OffersRepository(this._client);
  final ApiClient _client;

  Future<({List<Offer> offers, int total})> list({
    String filter = '',
    int page = 1,
    int limit = 50,
    String? customerId,
  }) async {
    final json = await _client.get<Map<String, dynamic>>('/offers/', query: {
      if (filter.isNotEmpty) 'filter': filter,
      if (customerId != null && customerId.isNotEmpty) 'customer_id': customerId,
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

  Future<OfferRevision> getRevision(String offerId, String revisionId) async {
    final json = await _client.get<Map<String, dynamic>>('/offers/$offerId/revisions/$revisionId');
    return OfferRevision.fromJson(json);
  }

  Map<String, dynamic> _offerBody({
    String? customerId,
    String customerName = '',
    String customerPhone = '',
    String customerEmail = '',
    String customerAddress = '',
    String? validUntil,
    String notes = '',
    double? vatRate,
    required List<OfferItem> items,
    required bool includeInternalPricing,
  }) =>
      {
        'customer_id': customerId,
        'customer_name': customerName,
        'customer_phone': customerPhone,
        'customer_email': customerEmail,
        'customer_address': customerAddress,
        'valid_until': validUntil,
        'notes': notes,
        'vat_rate': vatRate,
        'items': items.map((e) => e.toJson(includeInternalPricing: includeInternalPricing)).toList(),
      };

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
    bool includeInternalPricing = false,
  }) async {
    final json = await _client.post<Map<String, dynamic>>(
      '/offers/',
      data: _offerBody(
        customerId: customerId,
        customerName: customerName,
        customerPhone: customerPhone,
        customerEmail: customerEmail,
        customerAddress: customerAddress,
        validUntil: validUntil,
        notes: notes,
        vatRate: vatRate,
        items: items,
        includeInternalPricing: includeInternalPricing,
      ),
    );
    return Offer.fromJson(json);
  }

  /// PUT /offers/{id} — yalnızca status=taslak iken (backend ErrOfferNotEditable).
  Future<Offer> update(
    String id, {
    String? customerId,
    String customerName = '',
    String customerPhone = '',
    String customerEmail = '',
    String customerAddress = '',
    String? validUntil,
    String notes = '',
    double? vatRate,
    required List<OfferItem> items,
    bool includeInternalPricing = false,
  }) async {
    final json = await _client.put<Map<String, dynamic>>(
      '/offers/$id',
      data: _offerBody(
        customerId: customerId,
        customerName: customerName,
        customerPhone: customerPhone,
        customerEmail: customerEmail,
        customerAddress: customerAddress,
        validUntil: validUntil,
        notes: notes,
        vatRate: vatRate,
        items: items,
        includeInternalPricing: includeInternalPricing,
      ),
    );
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

  /// Bir teklif zaten projeye dönüştürülmüş mü? 404 => dönüştürülmemiş (null).
  /// Var olan projenin id'sini döner ki "Projeyi Görüntüle" doğrudan ona
  /// gidebilsin -- yalnızca bool dönmek (eski `hasProject`) hedefi kaybettirirdi.
  Future<String?> linkedProjectId(String offerId) async {
    try {
      final json = await _client.get<Map<String, dynamic>>('/offers/$offerId/project');
      return json['id'] as String?;
    } on Object {
      return null;
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

  /// Güncel revizyon için yeni bir paylaşım linki oluşturur. [expiresIn]:
  /// '' (süresiz) | '7d' | '30d' -- backend sözleşmesiyle birebir.
  Future<ShareLink> createShareLink(String offerId, {String expiresIn = ''}) async {
    final json = await _client.post<Map<String, dynamic>>(
      '/offers/$offerId/share-links',
      data: {'expires_in': expiresIn},
    );
    return ShareLink.fromJson(json);
  }

  Future<List<ShareLink>> shareLinks(String offerId) async {
    final json = await _client.get<Map<String, dynamic>>('/offers/$offerId/share-links');
    return (json['share_links'] as List).cast<Map<String, dynamic>>().map(ShareLink.fromJson).toList();
  }

  Future<void> revokeShareLink(String offerId, String linkId) =>
      _client.delete<void>('/offers/$offerId/share-links/$linkId');

  /// `to`/`subject`/`message` boş bırakılırsa backend varsayılanları
  /// kullanır: alıcı = teklifin kayıtlı müşteri e-postası, konu/gövde
  /// hazır Türkçe şablon + paylaşım linki (bkz. OfferService.SendOfferEmail).
  Future<void> sendEmail(String offerId, {String to = '', String subject = '', String message = ''}) =>
      _client.post<void>('/offers/$offerId/send-email', data: {
        'to': to,
        'subject': subject,
        'message': message,
      });
}
