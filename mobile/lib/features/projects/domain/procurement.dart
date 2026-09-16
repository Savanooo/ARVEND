/// Sprint 4 — Satın Alma (Procurement Foundation), mobilde YALNIZCA OKUMA
/// (bkz. docs/procurement.md §11 "mobile read-first"). RFQ/teklif
/// karşılaştırma/tedarikçi yönetimi/PO onay-iptal-kapatma mobilde YOKTUR --
/// yalnızca Talep (PurchaseRequest) ve Sipariş (PurchaseOrder) listeleri +
/// detayları.
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
