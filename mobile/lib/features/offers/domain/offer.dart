/// bkz. mobile/API_CONTRACT.md#offers - offerItemResponse.
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
  });

  factory OfferItem.fromJson(Map<String, dynamic> json) => OfferItem(
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
      );

  Map<String, dynamic> toJson() => {
        'product_id': productId,
        'product_name': productName,
        'quantity': quantity,
        'unit_price': unitPrice,
        'unit': unit,
        'section_label': sectionLabel,
        'calc_category_id': calcCategoryId,
        'calc_snapshot': calcSnapshot,
      };
}

/// backend `offerResponse` — `currency` bu şekilde YOK, her zaman TRY
/// (bkz. API_CONTRACT.md).
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
  final int revisionNo;
  final double grandTotal;
  final String currency;
  final String status;
  final String createdAt;
  final List<OfferItem> items;

  const OfferRevision({
    required this.id,
    required this.revisionNo,
    required this.grandTotal,
    required this.currency,
    required this.status,
    required this.createdAt,
    required this.items,
  });

  factory OfferRevision.fromJson(Map<String, dynamic> json) => OfferRevision(
        id: json['id'] as String,
        revisionNo: json['revision_no'] as int? ?? 0,
        grandTotal: (json['grand_total'] as num?)?.toDouble() ?? 0,
        currency: json['currency'] as String? ?? 'TRY',
        status: json['status'] as String,
        createdAt: json['created_at'] as String? ?? '',
        items: (json['items'] as List<dynamic>? ?? [])
            .cast<Map<String, dynamic>>()
            .map(OfferItem.fromJson)
            .toList(),
      );
}

const kOfferStatuses = ['taslak', 'gönderildi', 'kabul edildi', 'reddedildi'];
