/// bkz. mobile/API_CONTRACT.md#offers — offerItemResponse / internal_pricing.
class OfferItem {
  final String id;
  final String? productId;
  final String productName;
  final double quantity;
  final double unitPrice;
  final double lineTotal;
  final String unit;
  final String? sectionLabel;
  final String? calcCategoryId;
  final Object? calcSnapshot;

  /// Personel-only; yalnızca `offers.internal_pricing.read` izni olan
  /// yanıtlarda dolar. Müşteri/paylaşım yanıtında asla gelmez.
  final double? internalSubcontractCost;
  final String? pricingMode; // "markup" | "manual" | null
  final double? markupPercent;
  final double? expectedProfit;
  final double? effectiveMarkupPercent;

  const OfferItem({
    required this.id,
    required this.productId,
    required this.productName,
    required this.quantity,
    required this.unitPrice,
    required this.lineTotal,
    required this.unit,
    required this.sectionLabel,
    required this.calcCategoryId,
    required this.calcSnapshot,
    this.internalSubcontractCost,
    this.pricingMode,
    this.markupPercent,
    this.expectedProfit,
    this.effectiveMarkupPercent,
  });

  static const pricingModeMarkup = 'markup';
  static const pricingModeManual = 'manual';

  bool get hasInternalPricing =>
      internalSubcontractCost != null ||
      (pricingMode != null && pricingMode!.isNotEmpty);

  factory OfferItem.fromJson(Map<String, dynamic> json) {
    final ip = json['internal_pricing'] as Map<String, dynamic>?;
    return OfferItem(
      id: json['id'] as String? ?? '',
      productId: json['product_id'] as String?,
      productName: json['product_name'] as String? ?? '',
      quantity: (json['quantity'] as num).toDouble(),
      unitPrice: (json['unit_price'] as num).toDouble(),
      lineTotal: (json['line_total'] as num?)?.toDouble() ?? 0,
      unit: json['unit'] as String? ?? '',
      sectionLabel: json['section_label'] as String?,
      calcCategoryId: json['calc_category_id'] as String?,
      calcSnapshot: json['calc_snapshot'],
      internalSubcontractCost: (ip?['cost'] as num?)?.toDouble(),
      pricingMode: ip?['pricing_mode'] as String?,
      markupPercent: (ip?['markup_percent'] as num?)?.toDouble(),
      expectedProfit: (ip?['expected_profit'] as num?)?.toDouble(),
      effectiveMarkupPercent: (ip?['effective_markup_percent'] as num?)?.toDouble(),
    );
  }

  /// Create/Update isteği gövdesi. [includeInternalPricing] false ise iç
  /// fiyat alanları GÖNDERİLMEZ (izin yokken sessizce temizlenmesi için
  /// backend'e boş alan yollamak yerine hiç yollamamak daha net).
  Map<String, dynamic> toJson({bool includeInternalPricing = false}) {
    final map = <String, dynamic>{
      'product_id': productId,
      'product_name': productName,
      'quantity': quantity,
      'unit_price': unitPrice,
      'unit': unit,
      'section_label': sectionLabel,
      'calc_category_id': calcCategoryId,
      'calc_snapshot': calcSnapshot,
    };
    if (includeInternalPricing && hasInternalPricing) {
      map['internal_subcontract_cost'] = internalSubcontractCost;
      map['pricing_mode'] = pricingMode;
      map['markup_percent'] = pricingMode == pricingModeMarkup ? markupPercent : null;
    }
    return map;
  }
}

/// Markup modunda istemci önizlemesi — sunucu otoriterdir; bu yalnızca UX.
double? previewMarkupUnitPrice(double cost, double markupPercent) {
  if (cost < 0) return null;
  return _round2(cost * (1 + markupPercent / 100));
}

double _round2(double v) => (v * 100).roundToDouble() / 100.0;

/// backend `offerResponse` — `currency` yok, her zaman TRY.
class Offer {
  final String id;
  final String offerNo;
  final int revisionNo;
  final String? customerId;
  final String customerName;
  final String customerPhone;
  final String customerEmail;
  final String customerAddress;
  final String offerDate;
  final String? validUntil;
  final double subtotal;
  final double vatRate;
  final double vatAmount;
  final double grandTotal;
  final String notes;
  final String status;
  final bool isPassive;
  final List<OfferItem> items;

  const Offer({
    required this.id,
    required this.offerNo,
    required this.revisionNo,
    required this.customerId,
    required this.customerName,
    required this.customerPhone,
    required this.customerEmail,
    required this.customerAddress,
    required this.offerDate,
    required this.validUntil,
    required this.subtotal,
    required this.vatRate,
    required this.vatAmount,
    required this.grandTotal,
    required this.notes,
    required this.status,
    required this.isPassive,
    required this.items,
  });

  static const statusTaslak = 'taslak';
  static const statusGonderildi = 'gönderildi';
  static const statusKabulEdildi = 'kabul edildi';
  static const statusReddedildi = 'reddedildi';

  bool get isEditable => status == statusTaslak && !isPassive;

  bool get canRevise =>
      !isPassive && (status == statusGonderildi || status == statusReddedildi);

  /// PDF dosya adı -- backend `offerPDFFilename` ile AYNI kural (sunucunun
  /// Content-Disposition'ı `ApiClient.getBytes`'tan okunamıyor): Türkçe
  /// harfler ASCII'ye, izin dışı karakter dizileri "-"ye çevrilir;
  /// revizyonda "-R2" eklenir. "TKL/2026 Çatı-0042" R2 ->
  /// "Teklif-TKL-2026-Cati-0042-R2.pdf".
  String get pdfFilename {
    const fold = {
      'ç': 'c', 'Ç': 'C', 'ğ': 'g', 'Ğ': 'G', 'ı': 'i', 'İ': 'I',
      'ö': 'o', 'Ö': 'O', 'ş': 's', 'Ş': 'S', 'ü': 'u', 'Ü': 'U',
    };
    var no = offerNo.split('').map((c) => fold[c] ?? c).join();
    no = no.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
    if (no.isEmpty) no = 'teklif';
    if (revisionNo > 0) no = '$no-R$revisionNo';
    return 'Teklif-$no.pdf';
  }

  factory Offer.fromJson(Map<String, dynamic> json) => Offer(
        id: json['id'] as String,
        offerNo: json['offer_no'] as String,
        revisionNo: json['revision_no'] as int? ?? 0,
        customerId: json['customer_id'] as String?,
        customerName: json['customer_name'] as String? ?? '',
        customerPhone: json['customer_phone'] as String? ?? '',
        customerEmail: json['customer_email'] as String? ?? '',
        customerAddress: json['customer_address'] as String? ?? '',
        offerDate: json['offer_date'] as String? ?? '',
        validUntil: json['valid_until'] as String?,
        subtotal: (json['subtotal'] as num?)?.toDouble() ?? 0,
        vatRate: (json['vat_rate'] as num?)?.toDouble() ?? 0,
        vatAmount: (json['vat_amount'] as num?)?.toDouble() ?? 0,
        grandTotal: (json['grand_total'] as num?)?.toDouble() ?? 0,
        notes: json['notes'] as String? ?? '',
        status: json['status'] as String,
        isPassive: json['is_passive'] as bool? ?? false,
        items: (json['items'] as List<dynamic>? ?? [])
            .cast<Map<String, dynamic>>()
            .map(OfferItem.fromJson)
            .toList(),
      );
}

class OfferRevision {
  final String id;
  final String offerId;
  final int revisionNo;
  final String? customerId;
  final String customerName;
  final String customerPhone;
  final String customerEmail;
  final String customerAddress;
  final String? validUntil;
  final double subtotal;
  final double vatRate;
  final double vatAmount;
  final double grandTotal;
  final String currency;
  final String notes;
  final String status;
  final String createdAt;
  final List<OfferItem> items;

  const OfferRevision({
    required this.id,
    required this.offerId,
    required this.revisionNo,
    required this.customerId,
    required this.customerName,
    required this.customerPhone,
    required this.customerEmail,
    required this.customerAddress,
    required this.validUntil,
    required this.subtotal,
    required this.vatRate,
    required this.vatAmount,
    required this.grandTotal,
    required this.currency,
    required this.notes,
    required this.status,
    required this.createdAt,
    required this.items,
  });

  factory OfferRevision.fromJson(Map<String, dynamic> json) => OfferRevision(
        id: json['id'] as String,
        offerId: json['offer_id'] as String? ?? '',
        revisionNo: json['revision_no'] as int? ?? 0,
        customerId: json['customer_id'] as String?,
        customerName: json['customer_name'] as String? ?? '',
        customerPhone: json['customer_phone'] as String? ?? '',
        customerEmail: json['customer_email'] as String? ?? '',
        customerAddress: json['customer_address'] as String? ?? '',
        validUntil: json['valid_until'] as String?,
        subtotal: (json['subtotal'] as num?)?.toDouble() ?? 0,
        vatRate: (json['vat_rate'] as num?)?.toDouble() ?? 0,
        vatAmount: (json['vat_amount'] as num?)?.toDouble() ?? 0,
        grandTotal: (json['grand_total'] as num?)?.toDouble() ?? 0,
        currency: json['currency'] as String? ?? 'TRY',
        notes: json['notes'] as String? ?? '',
        status: json['status'] as String,
        createdAt: json['created_at'] as String? ?? '',
        items: (json['items'] as List<dynamic>? ?? [])
            .cast<Map<String, dynamic>>()
            .map(OfferItem.fromJson)
            .toList(),
      );
}

/// İzin kodları — backend/internal/domain/authorization.go ile birebir.
const kPermOffersInternalPricingRead = 'offers.internal_pricing.read';
const kPermOffersInternalPricingManage = 'offers.internal_pricing.manage';
const kPermOffersUpdate = 'offers.update';
const kPermOffersDelete = 'offers.delete';

/// Teklif → proje dönüştürme, /projects/from-offer/{offerId} üzerinden
/// bu izni ister (offers.* eksenine değil, projects.create'e bağlı).
const kPermProjectsCreate = 'projects.create';

const kOfferStatuses = ['taslak', 'gönderildi', 'kabul edildi', 'reddedildi'];

/// backend `shareLinkResponse` — müşteri sayfasına (`/paylas/{token}`)
/// erişimi sağlayan, revizyona bağlı paylaşım linki. `token` dışında hiçbir
/// hassas/iç veri taşımaz.
class ShareLink {
  final String id;
  final String offerId;
  final String revisionId;
  final String token;
  final String createdAt;
  final String? expiresAt;
  final String? revokedAt;
  final bool isActive;

  const ShareLink({
    required this.id,
    required this.offerId,
    required this.revisionId,
    required this.token,
    required this.createdAt,
    required this.expiresAt,
    required this.revokedAt,
    required this.isActive,
  });

  factory ShareLink.fromJson(Map<String, dynamic> json) => ShareLink(
        id: json['id'] as String? ?? '',
        offerId: json['offer_id'] as String? ?? '',
        revisionId: json['revision_id'] as String? ?? '',
        token: json['token'] as String? ?? '',
        createdAt: json['created_at'] as String? ?? '',
        expiresAt: json['expires_at'] as String?,
        revokedAt: json['revoked_at'] as String?,
        isActive: json['is_active'] as bool? ?? false,
      );
}
