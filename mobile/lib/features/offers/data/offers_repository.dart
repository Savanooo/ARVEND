import 'dart:typed_data';

import '../../../core/api/api_client.dart';
import '../domain/offer.dart';

/// `GET /offers/` sayfası: bu sayfanın satırları + filtrenin gerçek toplamı
/// + durum sekmesi sayaçları.
class OfferListPage {
  const OfferListPage({required this.offers, required this.total, required this.statusCounts});

  static const pageSize = 50;

  final List<Offer> offers;
  final int total;
  final Map<String, int> statusCounts;
}

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

  /// Teklifler ekranının sayfalı listesi: durum sekmesi ve arama SUNUCUDA
  /// uygulanır (backend `GET /offers/?status=&q=&page=&limit=`). Eskiden
  /// yalnızca ilk 50 teklif çekilip cihazda süzülüyordu -- 51. ve sonraki
  /// teklifler hiçbir filtrede görünmüyordu. `statusCounts`, aynı arama
  /// kapsamında her durumdaki GERÇEK teklif sayısıdır (sekme sayaçları).
  Future<OfferListPage> page({
    bool passive = false,
    String status = '',
    String q = '',
    int page = 1,
    int limit = OfferListPage.pageSize,
  }) async {
    final json = await _client.get<Map<String, dynamic>>('/offers/', query: {
      if (passive) 'filter': 'pasif',
      if (status.isNotEmpty) 'status': status,
      if (q.isNotEmpty) 'q': q,
      'page': page,
      'limit': limit,
    });
    final offers = (json['offers'] as List? ?? const []).cast<Map<String, dynamic>>().map(Offer.fromJson).toList();
    final counts = <String, int>{
      for (final e in (json['status_counts'] as Map<String, dynamic>? ?? const {}).entries)
        e.key: (e.value as num?)?.toInt() ?? 0,
    };
    return OfferListPage(offers: offers, total: (json['total'] as num?)?.toInt() ?? offers.length, statusCounts: counts);
  }

  Future<Offer> get(String id) async {
    final json = await _client.get<Map<String, dynamic>>('/offers/$id');
    return Offer.fromJson(json);
  }

  /// GET /offers/defaults (offers.create) -- firma teklif varsayılanları.
  Future<OfferDefaults> defaults() async {
    final json = await _client.get<Map<String, dynamic>>('/offers/defaults');
    return OfferDefaults.fromJson(json);
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

  /// Web'deki "Projeye Dönüştür" formuyla aynı alanlar. Boş ad/tip
  /// gönderilirse backend varsayılanı kullanır ("Müşteri - TeklifNo");
  /// tarihler 'YYYY-MM-DD' ya da null.
  Future<Map<String, dynamic>> convertToProject(
    String offerId, {
    String name = '',
    String projectType = '',
    String? startDate,
    String? endDate,
    String description = '',
  }) =>
      _client.post<Map<String, dynamic>>('/projects/from-offer/$offerId', data: {
        'name': name,
        'project_type': projectType,
        'start_date': startDate,
        'end_date': endDate,
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
  /// `GET /offers/{id}/pdf` (offers.read) -- teklifin güncel revizyonunun
  /// PDF'i. ApiClient üzerinden alınır: oturum çerezi ve 401 -> yenile ->
  /// tekrar dene akışı geçerlidir.
  Future<Uint8List> pdfBytes(String offerId) => _client.getBytes('/offers/$offerId/pdf');

  Future<void> sendEmail(String offerId, {String to = '', String subject = '', String message = ''}) =>
      _client.post<void>('/offers/$offerId/send-email', data: {
        'to': to,
        'subject': subject,
        'message': message,
      });
}
