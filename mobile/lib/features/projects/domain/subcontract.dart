/// Sprint 5 — Taşeron Yönetimi (yeni modül, `project_subcontracts`). Faz
/// 8'den kalma legacy `project_subcontractors`/`/subcontractors` uçlarıyla
/// KARIŞTIRILMAMALI — o basit taşeron+ödeme defteri mobilde YOK, bilinçli
/// olarak bu modülün üzerine yeni mobil işlevsellik kurulmuyor (bkz. backend
/// docs/subcontracts.md "Legacy Taşeron Sistemi"). `subcontract_change_orders`
/// (bu dosyanın altında `SubcontractChangeOrder`) Sprint-3'ün MÜŞTERİ tarafı
/// `project_change_orders`/"Ek İşler" İLE DE KARIŞTIRILMAMALI -- o TAMAMEN
/// ayrı bir gelir-tarafı modülüdür (`ChangeOrder`, project.dart'ta), bu ise
/// maliyet-tarafı, tek bir taşeron sözleşmesine bağlı bir değişiklik emridir.
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

  static const statusDraft = 'draft';
  static const statusActive = 'active';
  static const statusCompleted = 'completed';
  static const statusCancelled = 'cancelled';
  static const statusTerminated = 'terminated';

  /// Durum makinesi backend-authoritative'tir (bkz.
  /// `ProjectService.UpdateSubcontractDraft`/`Activate`/`Complete`/`Cancel`/
  /// `TerminateSubcontract` -- her biri kendi durum-korumalı SQL'iyle
  /// çalışır). Bu getter'lar YALNIZCA UI görünürlüğü içindir; sunucu HER
  /// durumda bağımsız olarak reddeder.
  bool get isEditable => status == statusDraft;
  bool get canActivate => status == statusDraft;
  bool get canCancel => status == statusDraft;
  bool get canComplete => status == statusActive;
  bool get canTerminate => status == statusActive;
}

class SubcontractItem {
  final String id;
  final String? wbsNodeId;
  final String costCodeId;
  final String? budgetLineId;
  final String description;
  final double? quantity;
  final String unit;
  final double? unitPrice;
  final double originalAmount;
  final int sortOrder;

  const SubcontractItem({
    required this.id,
    required this.wbsNodeId,
    required this.costCodeId,
    required this.budgetLineId,
    required this.description,
    required this.quantity,
    required this.unit,
    required this.unitPrice,
    required this.originalAmount,
    required this.sortOrder,
  });

  factory SubcontractItem.fromJson(Map<String, dynamic> json) => SubcontractItem(
        id: json['id'] as String,
        wbsNodeId: json['wbs_node_id'] as String?,
        costCodeId: json['cost_code_id'] as String? ?? '',
        budgetLineId: json['budget_line_id'] as String?,
        description: json['description'] as String? ?? '',
        quantity: (json['quantity'] as num?)?.toDouble(),
        unit: json['unit'] as String? ?? '',
        unitPrice: (json['unit_price'] as num?)?.toDouble(),
        originalAmount: (json['original_amount'] as num?)?.toDouble() ?? 0,
        sortOrder: (json['sort_order'] as num?)?.toInt() ?? 0,
      );

  /// `POST/PUT /subcontracts` -- backend Update HER ZAMAN kalemleri TAMAMEN
  /// yeniden yazar (sil-yeniden-oluştur, bkz. backend insertSubcontractItems)
  /// -- bu yüzden mevcut kalemler (wbsNodeId/budgetLineId dahil) edit'te
  /// OLDUĞU GİBİ geri gönderilmezse sessizce KAYBOLUR. `id`/`sortOrder`
  /// istekte YOK -- backend bunları kendi üretir/sıralar.
  Map<String, dynamic> toJson() => {
        'wbs_node_id': wbsNodeId ?? '',
        'cost_code_id': costCodeId,
        'budget_line_id': budgetLineId ?? '',
        'description': description,
        'quantity': quantity,
        'unit': unit,
        'unit_price': unitPrice,
        'original_amount': originalAmount,
      };
}

/// Sprint 4 tedarikçi kataloğunun (`organization_suppliers`) mobildeki
/// MİNİMAL okuma izdüşümü -- yalnızca Taşeron Sözleşmesi'nde bir tedarikçi
/// SEÇMEK için (bkz. backend docs/subcontracts.md "Supplier Seçimi").
/// Tedarikçi CRUD'u bilinçli olarak mobile YOK (web'de kalır).
class Supplier {
  final String id;
  final String code;
  final String legalName;
  final String tradeName;
  final bool isActive;

  const Supplier({
    required this.id,
    required this.code,
    required this.legalName,
    required this.tradeName,
    required this.isActive,
  });

  String get displayName => tradeName.isNotEmpty ? tradeName : legalName;

  factory Supplier.fromJson(Map<String, dynamic> json) => Supplier(
        id: json['id'] as String,
        code: json['code'] as String? ?? '',
        legalName: json['legal_name'] as String? ?? '',
        tradeName: json['trade_name'] as String? ?? '',
        isActive: json['is_active'] as bool? ?? false,
      );
}

/// Organizasyon-seviyeli maliyet kodu kataloğunun mobildeki MİNİMAL okuma
/// izdüşümü -- yalnızca SOV kalemi girişinde bir maliyet kodu SEÇMEK için.
/// Bütçe/WBS'e bağlı DEĞİLDİR (bkz. `CostControlLine`) -- bütçesiz bir
/// projede bile taşeron SOV kalemi girilebilmesi için gereklidir.
class OrgCostCode {
  final String id;
  final String code;
  final String name;
  final bool isActive;

  const OrgCostCode({
    required this.id,
    required this.code,
    required this.name,
    required this.isActive,
  });

  factory OrgCostCode.fromJson(Map<String, dynamic> json) => OrgCostCode(
        id: json['id'] as String,
        code: json['code'] as String? ?? '',
        name: json['name'] as String? ?? '',
        isActive: json['is_active'] as bool? ?? false,
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

/// `/subcontract-progress-claims` (Hakediş) -- P2: artık salt-okunur değil,
/// create/edit/submit/certify/reject/cancel destekleniyor (bkz.
/// project_subcontract_progress_claim_service.go). `netPayable` bir
/// YÜKÜMLÜLÜKTÜR, GERÇEKTEN ödendiği anlamına GELMEZ -- bkz.
/// `SubcontractPayment`. Durum makinesi: draft -> submitted -> {certified,
/// rejected}; {draft, submitted} -> cancelled. `certified` TERMİNALDİR --
/// hiçbir aksiyon onu geri döndüremez, düzeltme YENİ bir hakedişle yapılır.
class ProgressClaim {
  final String id;
  final String subcontractId;
  final String claimNumber;
  final String? periodStart;
  final String periodEnd;
  final String status;
  final double grossWorkAmount;
  final double retentionPercentSnapshot;
  final double retentionAmount;
  final double advanceRecoveryAmount;
  final double otherDeductions;
  final double previousCertifiedAmount;
  final double currentCertifiedAmount;
  final double netPayable;
  final String? submittedAt;
  final String? certifiedAt;
  final String? rejectedAt;
  final String rejectionReason;
  final String? cancelledAt;
  final String notes;
  final String createdAt;
  final String updatedAt;

  const ProgressClaim({
    required this.id,
    required this.subcontractId,
    required this.claimNumber,
    required this.periodStart,
    required this.periodEnd,
    required this.status,
    required this.grossWorkAmount,
    required this.retentionPercentSnapshot,
    required this.retentionAmount,
    required this.advanceRecoveryAmount,
    required this.otherDeductions,
    required this.previousCertifiedAmount,
    required this.currentCertifiedAmount,
    required this.netPayable,
    required this.submittedAt,
    required this.certifiedAt,
    required this.rejectedAt,
    required this.rejectionReason,
    required this.cancelledAt,
    required this.notes,
    required this.createdAt,
    required this.updatedAt,
  });

  factory ProgressClaim.fromJson(Map<String, dynamic> json) => ProgressClaim(
        id: json['id'] as String,
        subcontractId: json['subcontract_id'] as String? ?? '',
        claimNumber: json['claim_number'] as String,
        periodStart: json['period_start'] as String?,
        periodEnd: json['period_end'] as String? ?? '',
        status: json['status'] as String,
        grossWorkAmount: (json['gross_work_amount'] as num?)?.toDouble() ?? 0,
        retentionPercentSnapshot: (json['retention_percent_snapshot'] as num?)?.toDouble() ?? 0,
        retentionAmount: (json['retention_amount'] as num?)?.toDouble() ?? 0,
        advanceRecoveryAmount: (json['advance_recovery_amount'] as num?)?.toDouble() ?? 0,
        otherDeductions: (json['other_deductions'] as num?)?.toDouble() ?? 0,
        previousCertifiedAmount: (json['previous_certified_amount'] as num?)?.toDouble() ?? 0,
        currentCertifiedAmount: (json['current_certified_amount'] as num?)?.toDouble() ?? 0,
        netPayable: (json['net_payable'] as num?)?.toDouble() ?? 0,
        submittedAt: json['submitted_at'] as String?,
        certifiedAt: json['certified_at'] as String?,
        rejectedAt: json['rejected_at'] as String?,
        rejectionReason: json['rejection_reason'] as String? ?? '',
        cancelledAt: json['cancelled_at'] as String?,
        notes: json['notes'] as String? ?? '',
        createdAt: json['created_at'] as String? ?? '',
        updatedAt: json['updated_at'] as String? ?? '',
      );

  static const statusDraft = 'draft';
  static const statusSubmitted = 'submitted';
  static const statusCertified = 'certified';
  static const statusRejected = 'rejected';
  static const statusCancelled = 'cancelled';

  /// Yalnızca UX görünürlüğü -- backend HER geçişi kendi durum-korumalı
  /// SQL'iyle bağımsız olarak reddeder (bkz.
  /// project_subcontract_progress_claim_service.go).
  bool get isEditable => status == statusDraft;
  bool get canSubmit => status == statusDraft;
  bool get canCertify => status == statusSubmitted;
  bool get canReject => status == statusSubmitted;
  bool get canCancel => status == statusDraft || status == statusSubmitted;
}

/// Bir hakedişin tek bir SOV kalemine karşılık gelen satırı. `scheduledValue`/
/// `previousProgressAmount`/`cumulativeProgressAmount` backend-hesaplıdır
/// (snapshot/running-total) -- mobil bunları ASLA yeniden hesaplamaz, yalnızca
/// GÖSTERİR. `progressPercent`/`remainingAmount` backend'in KENDİSİ de canlı
/// hesaplayıp response'a koyduğu (persist edilmeyen) türetilmiş alanlardır --
/// mobil bunları backend'den OLDUĞU GİBİ okur, kendi formülünü İCAT ETMEZ.
class ProgressClaimItem {
  final String id;
  final String subcontractItemId;
  final String itemDescription;
  final String itemUnit;
  final double scheduledValue;
  final double previousProgressAmount;
  final double currentProgressAmount;
  final double cumulativeProgressAmount;
  final double progressPercent;
  final double remainingAmount;
  final int sortOrder;

  const ProgressClaimItem({
    required this.id,
    required this.subcontractItemId,
    required this.itemDescription,
    required this.itemUnit,
    required this.scheduledValue,
    required this.previousProgressAmount,
    required this.currentProgressAmount,
    required this.cumulativeProgressAmount,
    required this.progressPercent,
    required this.remainingAmount,
    required this.sortOrder,
  });

  factory ProgressClaimItem.fromJson(Map<String, dynamic> json) => ProgressClaimItem(
        id: json['id'] as String,
        subcontractItemId: json['subcontract_item_id'] as String? ?? '',
        itemDescription: json['item_description'] as String? ?? '',
        itemUnit: json['item_unit'] as String? ?? '',
        scheduledValue: (json['scheduled_value'] as num?)?.toDouble() ?? 0,
        previousProgressAmount: (json['previous_progress_amount'] as num?)?.toDouble() ?? 0,
        currentProgressAmount: (json['current_progress_amount'] as num?)?.toDouble() ?? 0,
        cumulativeProgressAmount: (json['cumulative_progress_amount'] as num?)?.toDouble() ?? 0,
        progressPercent: (json['progress_percent'] as num?)?.toDouble() ?? 0,
        remainingAmount: (json['remaining_amount'] as num?)?.toDouble() ?? 0,
        sortOrder: (json['sort_order'] as num?)?.toInt() ?? 0,
      );

  /// İstek gövdesinde YALNIZCA bu iki alan var -- `scheduled_value`/
  /// `previous_progress_amount`/`cumulative_progress_amount`/`progress_percent`/
  /// `remaining_amount` backend tarafından türetilir, hiçbiri gönderilmez.
  Map<String, dynamic> toJson() => {
        'subcontract_item_id': subcontractItemId,
        'current_progress_amount': currentProgressAmount,
      };
}

/// `subcontract_change_orders` (Sprint 5, MALİYET tarafı) -- P2 ile mobile
/// eklendi. Sprint-3'ün `ChangeOrder` (GELİR tarafı, "Ek İşler") İLE
/// KARIŞTIRILMAMALI, bkz. dosya başı yorumu. `signedAmount`, backend'in
/// KENDİSİ hesaplayıp DÖNMEDİĞİ bir alan -- API yalnızca `amount` (her zaman
/// pozitif) + `changeType` döner, işaret burada YALNIZCA GÖRÜNTÜLEME için
/// türetilir (backend'in domain.SubcontractChangeOrder.SignedEffect() metodu
/// VAR ama hiçbir handler/service tarafından ÇAĞRILMIYOR -- bkz. Phase 1
/// bulgusu). Durum makinesi: draft -> submitted -> {approved, rejected};
/// {draft, submitted} -> cancelled. Onay, ana sözleşmenin commitment'ını
/// YENİDEN SENKRONİZE eder (bkz. syncSubcontractCommitments) -- bu yüzden
/// yalnızca `subcontracts.approve` iznine sahip kullanıcılar onaylayabilir.
class SubcontractChangeOrder {
  final String id;
  final String subcontractId;
  final String number;
  final String title;
  final String description;
  final String changeType;
  final double amount;
  final String status;
  final String reason;
  final String? requestedAt;
  final String? approvedAt;
  final String? rejectedAt;
  final String rejectionReason;
  final String? cancelledAt;
  final String createdAt;
  final String updatedAt;

  const SubcontractChangeOrder({
    required this.id,
    required this.subcontractId,
    required this.number,
    required this.title,
    required this.description,
    required this.changeType,
    required this.amount,
    required this.status,
    required this.reason,
    required this.requestedAt,
    required this.approvedAt,
    required this.rejectedAt,
    required this.rejectionReason,
    required this.cancelledAt,
    required this.createdAt,
    required this.updatedAt,
  });

  factory SubcontractChangeOrder.fromJson(Map<String, dynamic> json) => SubcontractChangeOrder(
        id: json['id'] as String,
        subcontractId: json['subcontract_id'] as String? ?? '',
        number: json['number'] as String? ?? '',
        title: json['title'] as String? ?? '',
        description: json['description'] as String? ?? '',
        changeType: json['change_type'] as String? ?? typeAddition,
        amount: (json['amount'] as num?)?.toDouble() ?? 0,
        status: json['status'] as String,
        reason: json['reason'] as String? ?? '',
        requestedAt: json['requested_at'] as String?,
        approvedAt: json['approved_at'] as String?,
        rejectedAt: json['rejected_at'] as String?,
        rejectionReason: json['rejection_reason'] as String? ?? '',
        cancelledAt: json['cancelled_at'] as String?,
        createdAt: json['created_at'] as String? ?? '',
        updatedAt: json['updated_at'] as String? ?? '',
      );

  static const typeAddition = 'addition';
  static const typeDeduction = 'deduction';

  static const statusDraft = 'draft';
  static const statusSubmitted = 'submitted';
  static const statusApproved = 'approved';
  static const statusRejected = 'rejected';
  static const statusCancelled = 'cancelled';

  double get signedAmount => changeType == typeDeduction ? -amount : amount;

  bool get isEditable => status == statusDraft;
  bool get canSubmit => status == statusDraft;
  bool get canApprove => status == statusSubmitted;
  bool get canReject => status == statusSubmitted;
  bool get canCancel => status == statusDraft || status == statusSubmitted;
}

/// Ana sözleşmenin SOV'unu (`SubcontractItem`) taklit eden değişiklik emri
/// kalemi -- her kalem kendi cost_code_id/budget_line_id/wbs_node_id'sine
/// sahiptir (Sprint 5 P1'deki gibi mobil bir WBS/bütçe seçici SUNMAZ, ikisi
/// de opsiyonel boş bırakılır).
class SubcontractChangeOrderItem {
  final String id;
  final String? wbsNodeId;
  final String costCodeId;
  final String? budgetLineId;
  final String description;
  final double amount;
  final int sortOrder;

  const SubcontractChangeOrderItem({
    required this.id,
    required this.wbsNodeId,
    required this.costCodeId,
    required this.budgetLineId,
    required this.description,
    required this.amount,
    required this.sortOrder,
  });

  factory SubcontractChangeOrderItem.fromJson(Map<String, dynamic> json) => SubcontractChangeOrderItem(
        id: json['id'] as String,
        wbsNodeId: json['wbs_node_id'] as String?,
        costCodeId: json['cost_code_id'] as String? ?? '',
        budgetLineId: json['budget_line_id'] as String?,
        description: json['description'] as String? ?? '',
        amount: (json['amount'] as num?)?.toDouble() ?? 0,
        sortOrder: (json['sort_order'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'wbs_node_id': wbsNodeId ?? '',
        'cost_code_id': costCodeId,
        'budget_line_id': budgetLineId ?? '',
        'description': description,
        'amount': amount,
      };
}
