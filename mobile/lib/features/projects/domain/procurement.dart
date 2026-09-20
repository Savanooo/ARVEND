/// Sprint 4 — Satın Alma (Procurement Foundation). Bir sonraki modül ile
/// (P3) tüm zincir mobile taşındı: Talep (PurchaseRequest) -> RFQ -> Teklif
/// (Quotation) -> Karşılaştırma -> Ödül (Award) -> Sipariş (PurchaseOrder).
/// Zincirin HİÇBİR adımı otomatik değildir -- her geçiş backend'de AYRI,
/// bağımsız bir aksiyon olarak doğrulanır (bkz. Phase 1 doğrulaması):
/// PR onayı RFQ oluşturmaz, RFQ Award PO oluşturmaz, PO onayı ZORUNLU
/// ayrı bir adımdır. Mobil bunların hiçbirini otomatikleştirmez.
class PurchaseRequest {
  final String id;
  final String prNo;
  final String title;
  final String description;
  final String? neededBy;
  final String status;
  final double estimatedTotal;
  final String? requestedBy;
  final String? submittedAt;
  final String? approvedAt;
  final String? approvedBy;
  final String? rejectedAt;
  final String? rejectedBy;
  final String rejectionReason;
  final String? cancelledAt;
  final String? cancelledBy;
  final String cancelReason;
  final String createdAt;
  final String updatedAt;

  const PurchaseRequest({
    required this.id,
    required this.prNo,
    required this.title,
    required this.description,
    required this.neededBy,
    required this.status,
    required this.estimatedTotal,
    required this.requestedBy,
    required this.submittedAt,
    required this.approvedAt,
    required this.approvedBy,
    required this.rejectedAt,
    required this.rejectedBy,
    required this.rejectionReason,
    required this.cancelledAt,
    required this.cancelledBy,
    required this.cancelReason,
    required this.createdAt,
    required this.updatedAt,
  });

  factory PurchaseRequest.fromJson(Map<String, dynamic> json) => PurchaseRequest(
        id: json['id'] as String,
        prNo: json['pr_no'] as String,
        title: json['title'] as String? ?? '',
        description: json['description'] as String? ?? '',
        neededBy: json['needed_by'] as String?,
        status: json['status'] as String,
        estimatedTotal: (json['estimated_total'] as num?)?.toDouble() ?? 0,
        requestedBy: json['requested_by'] as String?,
        submittedAt: json['submitted_at'] as String?,
        approvedAt: json['approved_at'] as String?,
        approvedBy: json['approved_by'] as String?,
        rejectedAt: json['rejected_at'] as String?,
        rejectedBy: json['rejected_by'] as String?,
        rejectionReason: json['rejection_reason'] as String? ?? '',
        cancelledAt: json['cancelled_at'] as String?,
        cancelledBy: json['cancelled_by'] as String?,
        cancelReason: json['cancel_reason'] as String? ?? '',
        createdAt: json['created_at'] as String? ?? '',
        updatedAt: json['updated_at'] as String? ?? '',
      );

  static const statusDraft = 'draft';
  static const statusSubmitted = 'submitted';
  static const statusApproved = 'approved';
  static const statusRejected = 'rejected';
  static const statusCancelled = 'cancelled';

  /// Yalnızca UX görünürlüğü -- backend HER geçişi kendi durum-korumalı
  /// SQL'iyle bağımsız olarak reddeder (bkz.
  /// project_purchase_request_service.go). Cancel, Withdraw İLE AYNI
  /// (`manage`) izin grubundadır -- Approve/Reject İLE KARIŞTIRILMAMALI.
  bool get isEditable => status == statusDraft;
  bool get canSubmit => status == statusDraft;
  bool get canWithdraw => status == statusSubmitted;
  bool get canCancel => status == statusDraft || status == statusSubmitted || status == statusApproved;
  bool get canApprove => status == statusSubmitted;
  bool get canReject => status == statusSubmitted;
}

class PurchaseRequestItem {
  final String id;
  final String? wbsNodeId;
  final String? costCodeId;
  final String? budgetLineId;
  final String description;
  final double quantity;
  final String unit;
  final double? estimatedUnitCost;
  final double estimatedTotal;
  final String notes;
  final int sortOrder;

  const PurchaseRequestItem({
    required this.id,
    required this.wbsNodeId,
    required this.costCodeId,
    required this.budgetLineId,
    required this.description,
    required this.quantity,
    required this.unit,
    required this.estimatedUnitCost,
    required this.estimatedTotal,
    required this.notes,
    required this.sortOrder,
  });

  factory PurchaseRequestItem.fromJson(Map<String, dynamic> json) => PurchaseRequestItem(
        id: json['id'] as String,
        wbsNodeId: json['wbs_node_id'] as String?,
        costCodeId: json['cost_code_id'] as String?,
        budgetLineId: json['budget_line_id'] as String?,
        description: json['description'] as String? ?? '',
        quantity: (json['quantity'] as num?)?.toDouble() ?? 0,
        unit: json['unit'] as String? ?? '',
        estimatedUnitCost: (json['estimated_unit_cost'] as num?)?.toDouble(),
        estimatedTotal: (json['estimated_total'] as num?)?.toDouble() ?? 0,
        notes: json['notes'] as String? ?? '',
        sortOrder: (json['sort_order'] as num?)?.toInt() ?? 0,
      );
}

class PurchaseOrder {
  final String id;
  final String poNo;
  final String supplierId;
  final String? supplierCode;
  final String? supplierName;
  final String? sourceRfqId;
  final String? sourceQuotationId;
  final String currency;
  final String status;
  final String issueDate;
  final String? expectedDeliveryDate;
  final String paymentTerms;
  final String deliveryAddress;
  final String notes;
  final double subtotal;
  final double taxRate;
  final double tax;
  final double total;
  final String? approvedAt;
  final String? approvedBy;
  final String? cancelledAt;
  final String? cancelledBy;
  final String cancelReason;
  final String? closedAt;
  final String? closedBy;
  final String createdAt;
  final String updatedAt;

  const PurchaseOrder({
    required this.id,
    required this.poNo,
    required this.supplierId,
    required this.supplierCode,
    required this.supplierName,
    required this.sourceRfqId,
    required this.sourceQuotationId,
    required this.currency,
    required this.status,
    required this.issueDate,
    required this.expectedDeliveryDate,
    required this.paymentTerms,
    required this.deliveryAddress,
    required this.notes,
    required this.subtotal,
    required this.taxRate,
    required this.tax,
    required this.total,
    required this.approvedAt,
    required this.approvedBy,
    required this.cancelledAt,
    required this.cancelledBy,
    required this.cancelReason,
    required this.closedAt,
    required this.closedBy,
    required this.createdAt,
    required this.updatedAt,
  });

  factory PurchaseOrder.fromJson(Map<String, dynamic> json) => PurchaseOrder(
        id: json['id'] as String,
        poNo: json['po_no'] as String,
        supplierId: json['supplier_id'] as String? ?? '',
        supplierCode: json['supplier_code'] as String?,
        supplierName: json['supplier_name'] as String?,
        sourceRfqId: json['source_rfq_id'] as String?,
        sourceQuotationId: json['source_quotation_id'] as String?,
        currency: json['currency'] as String? ?? 'TRY',
        status: json['status'] as String,
        issueDate: json['issue_date'] as String? ?? '',
        expectedDeliveryDate: json['expected_delivery_date'] as String?,
        paymentTerms: json['payment_terms'] as String? ?? '',
        deliveryAddress: json['delivery_address'] as String? ?? '',
        notes: json['notes'] as String? ?? '',
        subtotal: (json['subtotal'] as num?)?.toDouble() ?? 0,
        taxRate: (json['tax_rate'] as num?)?.toDouble() ?? 0,
        tax: (json['tax'] as num?)?.toDouble() ?? 0,
        total: (json['total'] as num?)?.toDouble() ?? 0,
        approvedAt: json['approved_at'] as String?,
        approvedBy: json['approved_by'] as String?,
        cancelledAt: json['cancelled_at'] as String?,
        cancelledBy: json['cancelled_by'] as String?,
        cancelReason: json['cancel_reason'] as String? ?? '',
        closedAt: json['closed_at'] as String?,
        closedBy: json['closed_by'] as String?,
        createdAt: json['created_at'] as String? ?? '',
        updatedAt: json['updated_at'] as String? ?? '',
      );

  static const statusDraft = 'draft';
  static const statusApproved = 'approved';
  static const statusCancelled = 'cancelled';
  static const statusClosed = 'closed';

  /// PO'da AYRI bir "issued" durumu YOK -- Approve, Sipariş için tek
  /// yayınlama-eşdeğeri aksiyondur (bkz. Phase 1 doğrulaması). Cancel,
  /// PR/RFQ'nun aksine `approve` izin grubundadır (`manage` DEĞİL) --
  /// çünkü onaylı bir PO'yu iptal etmek commitment voidler.
  bool get isEditable => status == statusDraft;
  bool get canApprove => status == statusDraft;
  bool get canCancel => status == statusDraft || status == statusApproved;
  bool get canClose => status == statusApproved;
}

/// PO kalemindeki `cost_code_id`, PR kaleminden farklı olarak nullable
/// DEĞİLDİR (backend domain'i öyle tanımlıyor -- bkz. Go handler DTO'su).
class PurchaseOrderItem {
  final String id;
  final String? wbsNodeId;
  final String costCodeId;
  final String? budgetLineId;
  final String description;
  final double quantity;
  final String unit;
  final double unitPrice;
  final double lineTotal;
  final int sortOrder;

  const PurchaseOrderItem({
    required this.id,
    required this.wbsNodeId,
    required this.costCodeId,
    required this.budgetLineId,
    required this.description,
    required this.quantity,
    required this.unit,
    required this.unitPrice,
    required this.lineTotal,
    required this.sortOrder,
  });

  factory PurchaseOrderItem.fromJson(Map<String, dynamic> json) => PurchaseOrderItem(
        id: json['id'] as String,
        wbsNodeId: json['wbs_node_id'] as String?,
        costCodeId: json['cost_code_id'] as String? ?? '',
        budgetLineId: json['budget_line_id'] as String?,
        description: json['description'] as String? ?? '',
        quantity: (json['quantity'] as num?)?.toDouble() ?? 0,
        unit: json['unit'] as String? ?? '',
        unitPrice: (json['unit_price'] as num?)?.toDouble() ?? 0,
        lineTotal: (json['line_total'] as num?)?.toDouble() ?? 0,
        sortOrder: (json['sort_order'] as num?)?.toInt() ?? 0,
      );
}

/// P3 — RFQ (Request for Quotation). `source_pr_item_id`den farklı olarak
/// `purchaseRequestId` OPSİYONELDİR -- bir RFQ ya onaylı bir PR'dan (kalemler
/// SNAPSHOT KOPYALANIR) ya da kendi bağımsız kalem listesiyle oluşturulur
/// (bkz. Phase 1 doğrulaması). Durum makinesi: draft -> issued ->
/// {closed (ödülsüz) | closed+awarded_quotation_id (Award)}; {draft,
/// issued} -> cancelled. "awarded" DİYE AYRI bir durum YOK -- Award da
/// nihai durumu `closed` yapar, kazananı `awardedQuotationId` alanında
/// tutar.
class RFQ {
  final String id;
  final String rfqNo;
  final String? purchaseRequestId;
  final String title;
  final String issueDate;
  final String? dueDate;
  final String status;
  final String notes;
  final String? awardedQuotationId;
  final String? awardedAt;
  final String? awardedBy;
  final String awardNotes;
  final String createdAt;
  final String updatedAt;

  const RFQ({
    required this.id,
    required this.rfqNo,
    required this.purchaseRequestId,
    required this.title,
    required this.issueDate,
    required this.dueDate,
    required this.status,
    required this.notes,
    required this.awardedQuotationId,
    required this.awardedAt,
    required this.awardedBy,
    required this.awardNotes,
    required this.createdAt,
    required this.updatedAt,
  });

  factory RFQ.fromJson(Map<String, dynamic> json) => RFQ(
        id: json['id'] as String,
        rfqNo: json['rfq_no'] as String? ?? '',
        purchaseRequestId: json['purchase_request_id'] as String?,
        title: json['title'] as String? ?? '',
        issueDate: json['issue_date'] as String? ?? '',
        dueDate: json['due_date'] as String?,
        status: json['status'] as String,
        notes: json['notes'] as String? ?? '',
        awardedQuotationId: json['awarded_quotation_id'] as String?,
        awardedAt: json['awarded_at'] as String?,
        awardedBy: json['awarded_by'] as String?,
        awardNotes: json['award_notes'] as String? ?? '',
        createdAt: json['created_at'] as String? ?? '',
        updatedAt: json['updated_at'] as String? ?? '',
      );

  static const statusDraft = 'draft';
  static const statusIssued = 'issued';
  static const statusClosed = 'closed';
  static const statusCancelled = 'cancelled';

  bool get isAwarded => awardedQuotationId != null;
  bool get isEditable => status == statusDraft;
  bool get canIssue => status == statusDraft;
  bool get canClose => status == statusIssued;
  bool get canAward => status == statusIssued;
  bool get canCancel => status == statusDraft || status == statusIssued;
}

class RFQItem {
  final String id;
  final String? sourcePrItemId;
  final String? wbsNodeId;
  final String? costCodeId;
  final String? budgetLineId;
  final String description;
  final double quantity;
  final String unit;
  final int sortOrder;

  const RFQItem({
    required this.id,
    required this.sourcePrItemId,
    required this.wbsNodeId,
    required this.costCodeId,
    required this.budgetLineId,
    required this.description,
    required this.quantity,
    required this.unit,
    required this.sortOrder,
  });

  factory RFQItem.fromJson(Map<String, dynamic> json) => RFQItem(
        id: json['id'] as String,
        sourcePrItemId: json['source_pr_item_id'] as String?,
        wbsNodeId: json['wbs_node_id'] as String?,
        costCodeId: json['cost_code_id'] as String?,
        budgetLineId: json['budget_line_id'] as String?,
        description: json['description'] as String? ?? '',
        quantity: (json['quantity'] as num?)?.toDouble() ?? 0,
        unit: json['unit'] as String? ?? '',
        sortOrder: (json['sort_order'] as num?)?.toInt() ?? 0,
      );
}

/// RFQ'ya davet edilen bir tedarikçi + yanıt durumu (`invited`/`responded`
/// gibi -- backend'in ürettiği ham string OLDUĞU GİBİ gösterilir, mobil
/// kendi enum'unu İCAT ETMEZ).
class RFQSupplier {
  final String id;
  final String supplierId;
  final String supplierCode;
  final String supplierName;
  final String invitedAt;
  final String responseStatus;

  const RFQSupplier({
    required this.id,
    required this.supplierId,
    required this.supplierCode,
    required this.supplierName,
    required this.invitedAt,
    required this.responseStatus,
  });

  factory RFQSupplier.fromJson(Map<String, dynamic> json) => RFQSupplier(
        id: json['id'] as String,
        supplierId: json['supplier_id'] as String? ?? '',
        supplierCode: json['supplier_code'] as String? ?? '',
        supplierName: json['supplier_name'] as String? ?? '',
        invitedAt: json['invited_at'] as String? ?? '',
        responseStatus: json['response_status'] as String? ?? '',
      );
}

/// `SupplierQuotation` -- Phase 1'de doğrulandı: KASITLI OLARAK kendi
/// `status` alanı YOKTUR (backend yorumu: "kazanan" bilgisi TEK doğruluk
/// kaynağı olarak yalnızca `RFQ.awardedQuotationId`de tutulur). Bu yüzden
/// bir teklifin "kazandı mı" sorusu her zaman `quotation.id ==
/// rfq.awardedQuotationId` karşılaştırmasıyla, ÇAĞIRAN tarafından
/// belirlenir -- burada bir `isAwarded` alanı/getter'ı YOK çünkü RFQ
/// bağlamı olmadan anlamsızdır. `currency`/`subtotal`/`tax`/`total`
/// TAMAMEN backend-hesaplıdır, mobil bunları ASLA yeniden hesaplamaz.
class Quotation {
  final String id;
  final String rfqId;
  final String supplierId;
  final String? supplierCode;
  final String? supplierName;
  final String quotationNumber;
  final String quotationDate;
  final String? validUntil;
  final String currency;
  final double subtotal;
  final double discount;
  final double taxRate;
  final double tax;
  final double total;
  final int? deliveryDays;
  final String paymentTerms;
  final String notes;
  final String createdAt;
  final String updatedAt;

  const Quotation({
    required this.id,
    required this.rfqId,
    required this.supplierId,
    required this.supplierCode,
    required this.supplierName,
    required this.quotationNumber,
    required this.quotationDate,
    required this.validUntil,
    required this.currency,
    required this.subtotal,
    required this.discount,
    required this.taxRate,
    required this.tax,
    required this.total,
    required this.deliveryDays,
    required this.paymentTerms,
    required this.notes,
    required this.createdAt,
    required this.updatedAt,
  });

  factory Quotation.fromJson(Map<String, dynamic> json) => Quotation(
        id: json['id'] as String,
        rfqId: json['rfq_id'] as String? ?? '',
        supplierId: json['supplier_id'] as String? ?? '',
        supplierCode: json['supplier_code'] as String?,
        supplierName: json['supplier_name'] as String?,
        quotationNumber: json['quotation_number'] as String? ?? '',
        quotationDate: json['quotation_date'] as String? ?? '',
        validUntil: json['valid_until'] as String?,
        currency: json['currency'] as String? ?? 'TRY',
        subtotal: (json['subtotal'] as num?)?.toDouble() ?? 0,
        discount: (json['discount'] as num?)?.toDouble() ?? 0,
        taxRate: (json['tax_rate'] as num?)?.toDouble() ?? 0,
        tax: (json['tax'] as num?)?.toDouble() ?? 0,
        total: (json['total'] as num?)?.toDouble() ?? 0,
        deliveryDays: (json['delivery_days'] as num?)?.toInt(),
        paymentTerms: json['payment_terms'] as String? ?? '',
        notes: json['notes'] as String? ?? '',
        createdAt: json['created_at'] as String? ?? '',
        updatedAt: json['updated_at'] as String? ?? '',
      );
}

class QuotationItem {
  final String id;
  final String rfqItemId;
  final double quantity;
  final double unitPrice;
  final double lineTotal;
  final String notes;

  const QuotationItem({
    required this.id,
    required this.rfqItemId,
    required this.quantity,
    required this.unitPrice,
    required this.lineTotal,
    required this.notes,
  });

  factory QuotationItem.fromJson(Map<String, dynamic> json) => QuotationItem(
        id: json['id'] as String,
        rfqItemId: json['rfq_item_id'] as String? ?? '',
        quantity: (json['quantity'] as num?)?.toDouble() ?? 0,
        unitPrice: (json['unit_price'] as num?)?.toDouble() ?? 0,
        lineTotal: (json['line_total'] as num?)?.toDouble() ?? 0,
        notes: json['notes'] as String? ?? '',
      );
}

/// `GET /rfqs/{id}/comparison` -- backend BİLİNÇLİ OLARAK bir "en düşük"/
/// "kazanan" alanı DÖNMEZ (Phase 1'de doğrulandı: `BidComparisonCell`'de
/// böyle bir alan yok). Mobil bu ham karşılaştırma verisini OLDUĞU GİBİ
/// gösterir -- hangi tedarikçinin en ucuz olduğuna dair kendi rozetini/
/// önerisini İCAT ETMEZ; karar Award aksiyonuyla İNSAN tarafından verilir.
class BidComparisonCell {
  final String supplierId;
  final double quantity;
  final double unitPrice;
  final double lineTotal;
  final String notes;

  const BidComparisonCell({
    required this.supplierId,
    required this.quantity,
    required this.unitPrice,
    required this.lineTotal,
    required this.notes,
  });

  factory BidComparisonCell.fromJson(Map<String, dynamic> json) => BidComparisonCell(
        supplierId: json['supplier_id'] as String? ?? '',
        quantity: (json['quantity'] as num?)?.toDouble() ?? 0,
        unitPrice: (json['unit_price'] as num?)?.toDouble() ?? 0,
        lineTotal: (json['line_total'] as num?)?.toDouble() ?? 0,
        notes: json['notes'] as String? ?? '',
      );
}

class BidComparisonRow {
  final RFQItem item;
  final Map<String, BidComparisonCell> cells;

  const BidComparisonRow({required this.item, required this.cells});

  factory BidComparisonRow.fromJson(Map<String, dynamic> json) => BidComparisonRow(
        item: RFQItem.fromJson(json['item'] as Map<String, dynamic>),
        cells: (json['cells'] as Map<String, dynamic>? ?? {}).map(
          (k, v) => MapEntry(k, BidComparisonCell.fromJson(v as Map<String, dynamic>)),
        ),
      );
}

/// `project_commitments` satırının mobildeki MİNİMAL okuma izdüşümü --
/// yalnızca PO detayında "bu sipariş maliyet kontrolüne ne taahhüt etti"
/// göstermek için (bkz. Phase 1: PO onayı KALEM-başına, onay-sonrası
/// DEĞİŞMEZ bir commitment oluşturur -- Taşeron'un void-yeniden-senkronize
/// modelinden BİLİNÇLİ OLARAK FARKLI).
class Commitment {
  final String id;
  final String? budgetLineId;
  final String costCodeId;
  final String costCodeCode;
  final String costCodeName;
  final String sourceType;
  final String description;
  final double committedAmount;
  final String currency;
  final String status;
  final String committedAt;
  final String? voidedAt;
  final String voidReason;

  const Commitment({
    required this.id,
    required this.budgetLineId,
    required this.costCodeId,
    required this.costCodeCode,
    required this.costCodeName,
    required this.sourceType,
    required this.description,
    required this.committedAmount,
    required this.currency,
    required this.status,
    required this.committedAt,
    required this.voidedAt,
    required this.voidReason,
  });

  bool get isVoided => voidedAt != null;

  factory Commitment.fromJson(Map<String, dynamic> json) => Commitment(
        id: json['id'] as String,
        budgetLineId: json['budget_line_id'] as String?,
        costCodeId: json['cost_code_id'] as String? ?? '',
        costCodeCode: json['cost_code_code'] as String? ?? '',
        costCodeName: json['cost_code_name'] as String? ?? '',
        sourceType: json['source_type'] as String? ?? '',
        description: json['description'] as String? ?? '',
        committedAmount: (json['committed_amount'] as num?)?.toDouble() ?? 0,
        currency: json['currency'] as String? ?? 'TRY',
        status: json['status'] as String? ?? '',
        committedAt: json['committed_at'] as String? ?? '',
        voidedAt: json['voided_at'] as String?,
        voidReason: json['void_reason'] as String? ?? '',
      );
}
