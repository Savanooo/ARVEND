import '../../../../core/widgets/status_badge.dart';

/// Ödeme planı kalemi -- backend `paymentPlanItemResponse`
/// (`GET /projects/{id}/payment-plan`) ile birebir.
///
/// Durum SUNUCUDA türetilir: saklanan yalnızca `pending`/`cancelled`'dır;
/// `partial`/`paid`/`overdue` okuma anında tahsilat toplamı ve vade
/// tarihinden (İstanbul takvim günüyle) hesaplanır (bkz. backend
/// `domain.EffectivePlanItemStatus`). Mobil bunu YENİDEN hesaplamaz.
class PaymentPlanItem {
  const PaymentPlanItem({
    required this.id,
    required this.sortOrder,
    required this.name,
    required this.percentage,
    required this.plannedAmount,
    required this.collectedAmount,
    required this.remainingAmount,
    required this.dueDate,
    required this.status,
    this.notes = '',
  });

  final String id;
  final int sortOrder;
  final String name;

  /// Doluysa tutar ana sözleşme bedeli (`contract_amount`) üzerinden
  /// SUNUCUDA hesaplanmıştır.
  final double? percentage;
  final double plannedAmount;

  /// Bu kaleme bağlı, iptal edilmemiş tahsilatların toplamı (sunucu).
  final double collectedAmount;

  /// `max(planned - collected, 0)` -- sunucu hesaplar.
  final double remainingAmount;

  /// "YYYY-MM-DD" ya da null.
  final String? dueDate;
  final String status;
  final String notes;

  factory PaymentPlanItem.fromJson(Map<String, dynamic> json) => PaymentPlanItem(
        id: json['id'] as String,
        sortOrder: (json['sort_order'] as num?)?.toInt() ?? 0,
        name: json['name'] as String? ?? '',
        percentage: (json['percentage'] as num?)?.toDouble(),
        plannedAmount: (json['planned_amount'] as num?)?.toDouble() ?? 0,
        collectedAmount: (json['collected_amount'] as num?)?.toDouble() ?? 0,
        remainingAmount: (json['remaining_amount'] as num?)?.toDouble() ?? 0,
        dueDate: _nonEmpty(json['due_date'] as String?),
        status: json['status'] as String? ?? kPlanItemPending,
        notes: json['notes'] as String? ?? '',
      );

  bool get isCancelled => status == kPlanItemCancelled;
  bool get isOverdue => status == kPlanItemOverdue;
  bool get isPaid => status == kPlanItemPaid;

  /// Tahsilat beklenen kalem (vade uyarısı yalnızca bunlarda anlamlı).
  bool get isOpen => status == kPlanItemPending || status == kPlanItemPartial || status == kPlanItemOverdue;

  /// İlerleme çubuğu için oran (0-100) -- yalnızca ÇİZİM içindir; tutarlar
  /// sunucunun verdiği değerlerdir.
  double get collectedPercent {
    if (plannedAmount <= 0) return 0;
    return (collectedAmount / plannedAmount * 100).clamp(0, 100).toDouble();
  }
}

/// `GET /projects/{id}/payment-plan` yanıtının tamamı.
class PaymentPlan {
  const PaymentPlan({required this.items, required this.plannedTotal});

  /// Sunucu sırası: `sort_order`, sonra oluşturulma. İptal edilenler de
  /// listededir (web ile aynı).
  final List<PaymentPlanItem> items;

  /// Sunucunun numeric toplamı -- iptal edilen kalemler HARİÇ (bkz. backend
  /// `GetPaymentPlanTotal`). Float toplamı yerine her zaman bu gösterilir.
  final double plannedTotal;

  factory PaymentPlan.fromJson(Map<String, dynamic> json) => PaymentPlan(
        items: (json['items'] as List? ?? const [])
            .cast<Map<String, dynamic>>()
            .map(PaymentPlanItem.fromJson)
            .toList(),
        plannedTotal: (json['planned_total'] as num?)?.toDouble() ?? 0,
      );

  List<PaymentPlanItem> get activeItems => [for (final i in items) if (!i.isCancelled) i];

  /// Planın tahsil edilen kısmı: iptal edilmemiş kalemlerde sunucunun
  /// verdiği `collected_amount` değerlerinin toplamı (plan toplamı ile aynı
  /// kapsam). Plana bağlanmamış tahsilatlar burada YOKTUR -- onlar
  /// Tahsilatlar listesinde ve finans özetindedir.
  double get collectedTotal => activeItems.fold(0, (sum, i) => sum + i.collectedAmount);

  /// İptal edilmemiş kalemlerin sunucu `remaining_amount` toplamı.
  double get remainingTotal => activeItems.fold(0, (sum, i) => sum + i.remainingAmount);

  /// Özet çubuğu için oran (0-100), yalnızca çizim.
  double get collectedPercent {
    if (plannedTotal <= 0) return 0;
    return (collectedTotal / plannedTotal * 100).clamp(0, 100).toDouble();
  }

  int countByStatus(String status) => items.where((i) => i.status == status).length;

  /// Vadesi yaklaşan/gecikmiş açık kalemler vade sırasıyla (vadesiz olanlar
  /// sonda) -- Finans sekmesindeki özet kartı için.
  List<PaymentPlanItem> openItemsByDueDate() {
    final open = [for (final i in items) if (i.isOpen) i];
    open.sort((a, b) {
      final ad = a.dueDate;
      final bd = b.dueDate;
      if (ad == null && bd == null) return a.sortOrder.compareTo(b.sortOrder);
      if (ad == null) return 1;
      if (bd == null) return -1;
      final c = ad.compareTo(bd);
      return c != 0 ? c : a.sortOrder.compareTo(b.sortOrder);
    });
    return open;
  }
}

/// `POST /projects/{id}/payment-plan` ve `PUT .../payment-plan/{itemId}`
/// gövdesi -- backend `paymentPlanItemRequest` ile birebir. PUT TAM
/// güncellemedir: `sort_order`, `notes`, `due_date` her seferinde yazılır
/// (düzenlemede mevcut değerler aynen geri gönderilmeli).
///
/// Yüzde ile tutar birbirini dışlar (web formu gibi): yüzde verilirse tutar
/// SUNUCUDA ana sözleşme bedelinden hesaplanır ve `planned_amount`
/// gönderilmez.
class PaymentPlanItemInput {
  const PaymentPlanItemInput({
    required this.name,
    this.percentage,
    this.plannedAmount,
    this.dueDate,
    required this.sortOrder,
    this.notes = '',
  }) : assert(percentage != null || plannedAmount != null);

  final String name;
  final double? percentage;
  final double? plannedAmount;

  /// "YYYY-MM-DD" ya da null (vadesiz).
  final String? dueDate;
  final int sortOrder;
  final String notes;

  Map<String, dynamic> toJson() => {
        'name': name.trim(),
        if (percentage != null) 'percentage': percentage else 'planned_amount': plannedAmount,
        'due_date': dueDate,
        'sort_order': sortOrder,
        'notes': notes.trim(),
      };
}

const kPlanItemPending = 'pending';
const kPlanItemPartial = 'partial';
const kPlanItemPaid = 'paid';
const kPlanItemOverdue = 'overdue';
const kPlanItemCancelled = 'cancelled';

/// Web `PLAN_ITEM_STATUS` (lib/status.ts) ile aynı etiketler ve tonlar.
const Map<String, (String, StatusTone)> kPlanItemStatuses = {
  kPlanItemPending: ('Bekliyor', StatusTone.muted),
  kPlanItemPartial: ('Kısmi Tahsil', StatusTone.gold),
  kPlanItemPaid: ('Tahsil Edildi', StatusTone.success),
  kPlanItemOverdue: ('Gecikti', StatusTone.danger),
  kPlanItemCancelled: ('İptal', StatusTone.muted),
};

String planItemStatusLabel(String status) => kPlanItemStatuses[status]?.$1 ?? status;

String? _nonEmpty(String? v) => (v == null || v.isEmpty) ? null : v;
