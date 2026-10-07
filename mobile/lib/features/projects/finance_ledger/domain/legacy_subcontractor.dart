import '../../../../core/widgets/status_badge.dart';

/// "Taşeron Ödemeleri" defteri -- backend `project_subcontractors` +
/// `project_subcontractor_payments` (Faz 6'dan kalma, HÂLÂ CANLI legacy
/// sistem; bkz. docs/subcontracts.md §0). Web'de proje Finans sekmesindeki
/// "Taşeronlar" bölümü (`SubcontractorsSection`). Sprint 5'in taşeron
/// SÖZLEŞMELERİ (`/subcontracts`, Operasyon > Taşeronlar) ile KARIŞTIRILMAZ:
/// burada tek bir sözleşme bedeli ve ona yapılan GERÇEK ödemeler tutulur;
/// ödemeler finans özetindeki gerçekleşen maliyete (`subcontractor_paid`)
/// girer.
class LegacySubcontractor {
  const LegacySubcontractor({
    required this.id,
    required this.name,
    required this.companyName,
    required this.workDescription,
    required this.contractAmount,
    required this.paidAmount,
    required this.remainingAmount,
    required this.currency,
    required this.status,
    this.phone = '',
    this.email = '',
    this.notes = '',
    this.startDate,
    this.endDate,
    this.costCodeId,
  });

  final String id;
  final String name;
  final String companyName;
  final String workDescription;
  final double contractAmount;

  /// İptal edilmemiş ödemelerin toplamı -- SUNUCU hesaplar.
  final double paidAmount;
  final double remainingAmount;
  final String currency;

  /// `planned | active | completed | cancelled`.
  final String status;
  final String phone;
  final String email;
  final String notes;

  /// "YYYY-MM-DD" ya da null. Formda gösterilmez ama düzenlemede GERİ
  /// gönderilir: `PUT /subcontractors/{id}` tüm alanları yazar, eksik alan
  /// silinirdi (bkz. [FinanceLedgerRepository.updateSubcontractor]).
  final String? startDate;
  final String? endDate;
  final String? costCodeId;

  factory LegacySubcontractor.fromJson(Map<String, dynamic> json) => LegacySubcontractor(
        id: json['id'] as String,
        name: json['name'] as String? ?? '',
        companyName: json['company_name'] as String? ?? '',
        workDescription: json['work_description'] as String? ?? '',
        contractAmount: (json['contract_amount'] as num?)?.toDouble() ?? 0,
        paidAmount: (json['paid_amount'] as num?)?.toDouble() ?? 0,
        remainingAmount: (json['remaining_amount'] as num?)?.toDouble() ?? 0,
        currency: json['currency'] as String? ?? 'TRY',
        status: json['status'] as String? ?? 'active',
        phone: json['phone'] as String? ?? '',
        email: json['email'] as String? ?? '',
        notes: json['notes'] as String? ?? '',
        startDate: json['start_date'] as String?,
        endDate: json['end_date'] as String?,
        costCodeId: json['cost_code_id'] as String?,
      );
}

/// Legacy taşerona yapılmış tek bir ödeme (`GET /subcontractor-payments`).
class LegacySubcontractorPayment {
  const LegacySubcontractorPayment({
    required this.id,
    required this.subcontractorId,
    required this.amount,
    required this.currency,
    required this.paidDate,
    required this.description,
    this.voidedAt,
    this.voidReason = '',
  });

  final String id;
  final String subcontractorId;
  final double amount;
  final String currency;

  /// "YYYY-MM-DD".
  final String paidDate;
  final String description;
  final String? voidedAt;
  final String voidReason;

  bool get isVoided => voidedAt != null;

  factory LegacySubcontractorPayment.fromJson(Map<String, dynamic> json) => LegacySubcontractorPayment(
        id: json['id'] as String,
        subcontractorId: json['subcontractor_id'] as String? ?? '',
        amount: (json['amount'] as num?)?.toDouble() ?? 0,
        currency: json['currency'] as String? ?? 'TRY',
        paidDate: json['paid_date'] as String? ?? '',
        description: json['description'] as String? ?? '',
        voidedAt: json['voided_at'] as String?,
        voidReason: json['void_reason'] as String? ?? '',
      );
}

/// Web `SUBCONTRACTOR_STATUS` etiketleri. "Devam Ediyor" altın yerine mavi
/// (info): uygulamanın renk kuralında altın marka vurgusuna ayrılmıştır
/// (Planlama ekranıyla aynı karar).
const kLegacySubcontractorStatus = <String, (String, StatusTone)>{
  'planned': ('Planlandı', StatusTone.muted),
  'active': ('Devam Ediyor', StatusTone.info),
  'completed': ('Tamamlandı', StatusTone.success),
  'cancelled': ('İptal', StatusTone.danger),
};
