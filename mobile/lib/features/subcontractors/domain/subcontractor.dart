import '../../suppliers/domain/supplier.dart';

/// Taşeronlar (backend migration 0069): taşeron kartı firmanın tedarikçi
/// kataloğundaki kayıttır (`is_subcontractor`). Projedeki basit taşeron
/// kaydı karta bağlanır; proje dışı ödemeler kartın kendisine yazılır.

/// Para birimi başına tutar.
class MoneyTotal {
  const MoneyTotal({required this.currency, required this.amount});

  final String currency;
  final double amount;

  factory MoneyTotal.fromJson(Map<String, dynamic> json) => MoneyTotal(
        currency: json['currency'] as String? ?? 'TRY',
        amount: (json['amount'] as num?)?.toDouble() ?? 0,
      );

  static List<MoneyTotal> listFrom(Object? raw) =>
      (raw as List? ?? const []).cast<Map<String, dynamic>>().map(MoneyTotal.fromJson).toList();
}

/// "Taşeronlar" listesinin satırı. [paidTotals] yalnızca finans okuyabilene
/// dolu gelir.
class SubcontractorCard {
  const SubcontractorCard({required this.supplier, this.paidTotals = const []});

  final OrganizationSupplier supplier;
  final List<MoneyTotal> paidTotals;

  String get id => supplier.id;
  String get name => supplier.legalName;
  bool get isActive => supplier.isActive;

  /// İkinci satır: branş · telefon · firma.
  String get subtitle => [supplier.specialty, supplier.phone, supplier.tradeName]
      .where((v) => v.isNotEmpty)
      .join(' · ');

  factory SubcontractorCard.fromJson(Map<String, dynamic> json) => SubcontractorCard(
        supplier: OrganizationSupplier.fromJson(json),
        paidTotals: MoneyTotal.listFrom(json['paid_totals']),
      );
}

/// GET /subcontractors yanıtı.
class SubcontractorCardsPage {
  const SubcontractorCardsPage({required this.cards, required this.canSeeTotals});

  final List<SubcontractorCard> cards;
  final bool canSeeTotals;

  factory SubcontractorCardsPage.fromJson(Map<String, dynamic> json) => SubcontractorCardsPage(
        cards: (json['subcontractors'] as List? ?? const [])
            .cast<Map<String, dynamic>>()
            .map(SubcontractorCard.fromJson)
            .toList(),
        canSeeTotals: json['can_see_totals'] as bool? ?? false,
      );
}

/// Taşeronun bir projedeki işi: projedeki basit taşeron kaydı ("simple") ya
/// da sözleşmeli taşeronluk ("contract").
class SubcontractorEngagement {
  const SubcontractorEngagement({
    required this.kind,
    required this.id,
    required this.projectId,
    required this.projectName,
    required this.projectNo,
    required this.projectStatus,
    required this.title,
    required this.status,
    required this.currency,
    required this.contractAmount,
    required this.paidAmount,
    required this.remainingAmount,
  });

  final String kind;
  final String id;
  final String projectId;
  final String projectName;
  final String projectNo;
  final String projectStatus;
  final String title;
  final String status;
  final String currency;
  final double contractAmount;
  final double paidAmount;
  final double remainingAmount;

  bool get isSimple => kind == 'simple';

  String get projectLabel => projectNo.isEmpty ? projectName : '$projectNo · $projectName';

  factory SubcontractorEngagement.fromJson(Map<String, dynamic> json) => SubcontractorEngagement(
        kind: json['kind'] as String? ?? 'simple',
        id: json['id'] as String,
        projectId: json['project_id'] as String? ?? '',
        projectName: json['project_name'] as String? ?? '',
        projectNo: json['project_no'] as String? ?? '',
        projectStatus: json['project_status'] as String? ?? '',
        title: json['title'] as String? ?? '',
        status: json['status'] as String? ?? '',
        currency: json['currency'] as String? ?? 'TRY',
        contractAmount: (json['contract_amount'] as num?)?.toDouble() ?? 0,
        paidAmount: (json['paid_amount'] as num?)?.toDouble() ?? 0,
        remainingAmount: (json['remaining_amount'] as num?)?.toDouble() ?? 0,
      );
}

/// Taşerona yapılan bir ödeme: "simple" (projedeki basit taşeron ödemesi),
/// "contract" (sözleşmeli taşeron ödemesi) ya da "direct" (proje dışı).
class SubcontractorLedgerPayment {
  const SubcontractorLedgerPayment({
    required this.source,
    required this.id,
    required this.projectId,
    required this.projectName,
    required this.projectNo,
    required this.engagementId,
    required this.amount,
    required this.currency,
    required this.paidDate,
    required this.description,
    required this.voidedAt,
    required this.voidReason,
  });

  final String source;
  final String id;
  final String? projectId;
  final String projectName;
  final String projectNo;
  final String? engagementId;
  final double amount;
  final String currency;
  final String paidDate;
  final String description;
  final String? voidedAt;
  final String voidReason;

  bool get isDirect => source == 'direct';
  bool get isVoided => voidedAt != null;

  String get projectLabel =>
      isDirect ? 'Proje dışı' : (projectNo.isEmpty ? projectName : '$projectNo · $projectName');

  factory SubcontractorLedgerPayment.fromJson(Map<String, dynamic> json) => SubcontractorLedgerPayment(
        source: json['source'] as String? ?? 'direct',
        id: json['id'] as String,
        projectId: json['project_id'] as String?,
        projectName: json['project_name'] as String? ?? '',
        projectNo: json['project_no'] as String? ?? '',
        engagementId: json['engagement_id'] as String?,
        amount: (json['amount'] as num?)?.toDouble() ?? 0,
        currency: json['currency'] as String? ?? 'TRY',
        paidDate: json['paid_date'] as String? ?? '',
        description: json['description'] as String? ?? '',
        voidedAt: json['voided_at'] as String?,
        voidReason: json['void_reason'] as String? ?? '',
      );
}

/// GET /subcontractors/{id}/ledger -- kart, projelerdeki işleri ve bütün
/// ödemeleri (iptaller dahil), para birimi başına ödenen toplam.
class SubcontractorLedger {
  const SubcontractorLedger({
    required this.card,
    required this.engagements,
    required this.payments,
    required this.paidTotals,
  });

  final OrganizationSupplier card;
  final List<SubcontractorEngagement> engagements;
  final List<SubcontractorLedgerPayment> payments;
  final List<MoneyTotal> paidTotals;

  factory SubcontractorLedger.fromJson(Map<String, dynamic> json) => SubcontractorLedger(
        card: OrganizationSupplier.fromJson(json['subcontractor'] as Map<String, dynamic>),
        engagements: (json['engagements'] as List? ?? const [])
            .cast<Map<String, dynamic>>()
            .map(SubcontractorEngagement.fromJson)
            .toList(),
        payments: (json['payments'] as List? ?? const [])
            .cast<Map<String, dynamic>>()
            .map(SubcontractorLedgerPayment.fromJson)
            .toList(),
        paidTotals: MoneyTotal.listFrom(json['paid_totals']),
      );
}
