/// Sprint 5 — Taşeron Yönetimi (yeni modül, `project_subcontracts`). Faz
/// 8'den kalma legacy `project_subcontractors`/`/subcontractors` uçlarıyla
/// KARIŞTIRILMAMALI — o basit taşeron+ödeme defteri mobilde YOK, bilinçli
/// olarak bu modülün üzerine yeni mobil işlevsellik kurulmuyor (bkz. backend
/// docs/subcontracts.md "Legacy Taşeron Sistemi"). Değişiklik emirleri
/// (subcontract change orders) mobilde YALNIZCA OKUMA bile değil, HENÜZ HİÇ
/// YOK — onay iş akışı web'de kalıyor (SOV/hakediş/ödeme kadar sık
/// kullanılmayan, daha karmaşık bir akış).
class Subcontract {
  final String id;
  final String subcontractNo;
  final String supplierId;
  final String? supplierCode;
  final String? supplierName;
  final String title;
  final String scopeSummary;
  final double originalAmount;
  final String currency;
  final String status;
  final String? effectiveDate;
  final String? startDate;
  final String? plannedCompletionDate;
  final double? retentionPercent;
  final double? advanceAmount;
  final String paymentTerms;
  final String notes;
  final String? activatedAt;
  final String? completedAt;
  final String? cancelledAt;
  final String cancelReason;
  final String? terminatedAt;
  final String terminationReason;
  final String createdAt;

  const Subcontract({
    required this.id,
    required this.subcontractNo,
    required this.supplierId,
    required this.supplierCode,
    required this.supplierName,
    required this.title,
    required this.scopeSummary,
    required this.originalAmount,
    required this.currency,
    required this.status,
    required this.effectiveDate,
    required this.startDate,
    required this.plannedCompletionDate,
    required this.retentionPercent,
    required this.advanceAmount,
    required this.paymentTerms,
    required this.notes,
    required this.activatedAt,
    required this.completedAt,
    required this.cancelledAt,
    required this.cancelReason,
    required this.terminatedAt,
    required this.terminationReason,
    required this.createdAt,
  });

  factory Subcontract.fromJson(Map<String, dynamic> json) => Subcontract(
        id: json['id'] as String,
        subcontractNo: json['subcontract_no'] as String,
        supplierId: json['supplier_id'] as String? ?? '',
        supplierCode: json['supplier_code'] as String?,
        supplierName: json['supplier_name'] as String?,
        title: json['title'] as String? ?? '',
        scopeSummary: json['scope_summary'] as String? ?? '',
        originalAmount: (json['original_amount'] as num?)?.toDouble() ?? 0,
        currency: json['currency'] as String? ?? 'TRY',
        status: json['status'] as String,
        effectiveDate: json['effective_date'] as String?,
        startDate: json['start_date'] as String?,
        plannedCompletionDate: json['planned_completion_date'] as String?,
        retentionPercent: (json['retention_percent'] as num?)?.toDouble(),
        advanceAmount: (json['advance_amount'] as num?)?.toDouble(),
        paymentTerms: json['payment_terms'] as String? ?? '',
        notes: json['notes'] as String? ?? '',
        activatedAt: json['activated_at'] as String?,
        completedAt: json['completed_at'] as String?,
        cancelledAt: json['cancelled_at'] as String?,
        cancelReason: json['cancel_reason'] as String? ?? '',
        terminatedAt: json['terminated_at'] as String?,
        terminationReason: json['termination_reason'] as String? ?? '',
        createdAt: json['created_at'] as String? ?? '',
      );
}

class SubcontractItem {
  final String id;
  final String costCodeId;
  final String description;
  final double? quantity;
  final String unit;
  final double? unitPrice;
  final double originalAmount;
  final int sortOrder;

  const SubcontractItem({
    required this.id,
    required this.costCodeId,
    required this.description,
    required this.quantity,
    required this.unit,
    required this.unitPrice,
    required this.originalAmount,
    required this.sortOrder,
  });

  factory SubcontractItem.fromJson(Map<String, dynamic> json) => SubcontractItem(
        id: json['id'] as String,
        costCodeId: json['cost_code_id'] as String? ?? '',
        description: json['description'] as String? ?? '',
        quantity: (json['quantity'] as num?)?.toDouble(),
        unit: json['unit'] as String? ?? '',
        unitPrice: (json['unit_price'] as num?)?.toDouble(),
        originalAmount: (json['original_amount'] as num?)?.toDouble() ?? 0,
        sortOrder: (json['sort_order'] as num?)?.toInt() ?? 0,
      );
}

/// `GET /subcontracts/{id}`'nin `current_value` alt nesnesi -- backend
/// HER ZAMAN otoriter, burada HİÇBİR rakam yeniden hesaplanmaz. paid_to_date/
/// remaining_payable Sprint 5 follow-up (migration 0039); certified_to_date/
/// remaining_commitment ile KASITLI OLARAK AYRI eksenler (sertifikasyon
/// ödeme DEĞİLDİR) -- bkz. backend service yorumu.
class SubcontractValue {
  final double originalAmount;
  final double approvedAdditions;
  final double approvedDeductions;
  final double pendingAdditions;
  final double pendingDeductions;
  final double currentValue;
  final double certifiedToDate;
  final double remainingCommitment;
  final double paidToDate;
  final double remainingPayable;

  const SubcontractValue({
    required this.originalAmount,
    required this.approvedAdditions,
    required this.approvedDeductions,
    required this.pendingAdditions,
    required this.pendingDeductions,
    required this.currentValue,
    required this.certifiedToDate,
    required this.remainingCommitment,
    required this.paidToDate,
    required this.remainingPayable,
  });

  factory SubcontractValue.fromJson(Map<String, dynamic> json) => SubcontractValue(
        originalAmount: (json['original_amount'] as num?)?.toDouble() ?? 0,
        approvedAdditions: (json['approved_additions'] as num?)?.toDouble() ?? 0,
        approvedDeductions: (json['approved_deductions'] as num?)?.toDouble() ?? 0,
        pendingAdditions: (json['pending_additions'] as num?)?.toDouble() ?? 0,
        pendingDeductions: (json['pending_deductions'] as num?)?.toDouble() ?? 0,
        currentValue: (json['current_value'] as num?)?.toDouble() ?? 0,
        certifiedToDate: (json['certified_to_date'] as num?)?.toDouble() ?? 0,
        remainingCommitment: (json['remaining_commitment'] as num?)?.toDouble() ?? 0,
        paidToDate: (json['paid_to_date'] as num?)?.toDouble() ?? 0,
        remainingPayable: (json['remaining_payable'] as num?)?.toDouble() ?? 0,
      );
}

/// `/subcontracts/{id}/payments` -- GERÇEK nakit çıkışı (bkz. migration
/// 0039). Sertifikasyon (ProgressClaim) İLE KARIŞTIRILMAMALI.
class SubcontractPayment {
  final String id;
  final String? progressClaimId;
  final double amount;
  final String currency;
  final String paidDate;
  final String paymentMethod;
  final String referenceNo;
  final String description;
  final String? voidedAt;
  final String voidReason;
  final String createdAt;

  const SubcontractPayment({
    required this.id,
    required this.progressClaimId,
    required this.amount,
    required this.currency,
    required this.paidDate,
    required this.paymentMethod,
    required this.referenceNo,
    required this.description,
    required this.voidedAt,
    required this.voidReason,
    required this.createdAt,
  });

  bool get isVoided => voidedAt != null;

  factory SubcontractPayment.fromJson(Map<String, dynamic> json) => SubcontractPayment(
        id: json['id'] as String,
        progressClaimId: json['progress_claim_id'] as String?,
        amount: (json['amount'] as num).toDouble(),
        currency: json['currency'] as String? ?? 'TRY',
        paidDate: json['paid_date'] as String? ?? '',
        paymentMethod: json['payment_method'] as String? ?? '',
        referenceNo: json['reference_no'] as String? ?? '',
        description: json['description'] as String? ?? '',
        voidedAt: json['voided_at'] as String?,
        voidReason: json['void_reason'] as String? ?? '',
        createdAt: json['created_at'] as String? ?? '',
      );
}

/// `/subcontract-progress-claims` (Hakediş) -- mobilde YALNIZCA OKUMA
/// (Değişiklik Emirleri İLE AYNI ilke: sertifikasyon onay iş akışı web'de
/// kalır). netPayable bir YÜKÜMLÜLÜKTÜR, GERÇEKTEN ödendiği anlamına
/// GELMEZ -- bkz. SubcontractPayment.
class ProgressClaim {
  final String id;
  final String claimNumber;
  final String periodEnd;
  final String status;
  final double grossWorkAmount;
  final double retentionAmount;
  final double netPayable;
  final String? certifiedAt;
  final String createdAt;

  const ProgressClaim({
    required this.id,
    required this.claimNumber,
    required this.periodEnd,
    required this.status,
    required this.grossWorkAmount,
    required this.retentionAmount,
    required this.netPayable,
    required this.certifiedAt,
    required this.createdAt,
  });

  factory ProgressClaim.fromJson(Map<String, dynamic> json) => ProgressClaim(
        id: json['id'] as String,
        claimNumber: json['claim_number'] as String,
        periodEnd: json['period_end'] as String? ?? '',
        status: json['status'] as String,
        grossWorkAmount: (json['gross_work_amount'] as num?)?.toDouble() ?? 0,
        retentionAmount: (json['retention_amount'] as num?)?.toDouble() ?? 0,
        netPayable: (json['net_payable'] as num?)?.toDouble() ?? 0,
        certifiedAt: json['certified_at'] as String?,
        createdAt: json['created_at'] as String? ?? '',
      );
}
