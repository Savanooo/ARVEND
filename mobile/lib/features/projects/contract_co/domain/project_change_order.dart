/// Proje Ek İşleri (Change Order) -- projenin GELİR tarafı; taşeron
/// değişiklik emirleri (`domain/subcontract.dart`, MALİYET tarafı) İLE
/// KARIŞTIRILMAMALI. backend `changeOrderResponse`
/// (project_change_order_handler.go) ile birebir; `projects/domain/
/// project.dart`'taki dar `ChangeOrder` özet sınıfının tam karşılığı.
///
/// Durum makinesi (domain/project_change_order.go):
///
///     draft -> sent -> {approved, rejected}   (karar MÜŞTERİNİN: paylaşım linkinden
///                                              ya da telefon/yazılı yanıtı ekip kaydeder)
///     draft -> cancelled
///     sent  -> cancelled
///     sent, rejected -> superseded             (Revize Et: yeni taslak açılır)
///
/// approved FİNALDİR (düzenlenemez/iptal edilemez/revize edilemez) --
/// geri almak için yeni bir eksiltme oluşturulur. Tutarlar HER ZAMAN
/// pozitiftir; işaret yalnızca `changeType`'tan gelir. Toplamlar
/// (subtotal/vat/grand_total/line_total) sunucuda hesaplanır, burada
/// YENİDEN hesaplanmaz.
class ProjectChangeOrder {
  const ProjectChangeOrder({
    required this.id,
    required this.projectId,
    required this.sequenceNo,
    required this.changeOrderNo,
    required this.changeType,
    required this.title,
    required this.status,
    required this.currency,
    this.description = '',
    this.subtotal = 0,
    this.vatRate = 0,
    this.vatAmount = 0,
    this.grandTotal = 0,
    this.internalNotes = '',
    this.customerNotes = '',
    this.createdAt = '',
    this.updatedAt = '',
    this.sentAt,
    this.respondedAt,
    this.approvedAt,
    this.rejectedAt,
    this.cancelledAt,
    this.supersedesChangeOrderId,
    this.activeShareToken,
    this.items = const [],
    this.profitability,
    this.decisionRecordedBy,
    this.decisionRecordedByName = '',
    this.decisionNote = '',
  });

  static const typeAddition = 'addition';
  static const typeDeduction = 'deduction';

  static const statusDraft = 'draft';
  static const statusSent = 'sent';
  static const statusApproved = 'approved';
  static const statusRejected = 'rejected';
  static const statusCancelled = 'cancelled';
  static const statusSuperseded = 'superseded';

  final String id;
  final String projectId;
  final int sequenceNo;

  /// "EK-003" -- sunucu `sequence_no`'dan türetir.
  final String changeOrderNo;
  final String changeType;
  final String title;
  final String description;
  final String status;
  final double subtotal;
  final double vatRate;
  final double vatAmount;
  final double grandTotal;
  final String currency;

  /// Yalnızca ekip görür -- müşteri paylaşım sayfası bunu ASLA almaz.
  final String internalNotes;
  final String customerNotes;
  final String createdAt;
  final String updatedAt;
  final String? sentAt;
  final String? respondedAt;
  final String? approvedAt;
  final String? rejectedAt;
  final String? cancelledAt;

  /// Bu kaydın yerini aldığı ESKİ ek iş (Revize Et ile açılan taslakta dolu).
  final String? supersedesChangeOrderId;

  /// Yalnızca `sent` iken ve aktif bir paylaşım linki varken dolu.
  final String? activeShareToken;

  /// Yalnızca tekil detay ucu (GET .../change-orders/{id}) doldurur; liste
  /// ucu kalem TAŞIMAZ.
  final List<ProjectChangeOrderItem> items;

  /// Yalnızca LİSTE ucu doldurur (detay ucu hesaplamaz) -- detay ekranı
  /// bunu listedeki aynı kayıttan alır.
  final ChangeOrderProfitability? profitability;

  /// Müşteri kararını ekip kaydettiyse (telefon/yazılı onay) kim; müşteri
  /// kendi linkinden yanıt verdiyse null. Ne zaman: `respondedAt`.
  final String? decisionRecordedBy;
  final String decisionRecordedByName;

  /// Kararla birlikte yazılan dahili not ("telefonla onay"). Müşteri
  /// paylaşım sayfası bunu görmez.
  final String decisionNote;

  bool get decisionRecordedByStaff => decisionRecordedBy != null;

  factory ProjectChangeOrder.fromJson(Map<String, dynamic> json) => ProjectChangeOrder(
        id: json['id'] as String,
        projectId: json['project_id'] as String? ?? '',
        sequenceNo: (json['sequence_no'] as num?)?.toInt() ?? 0,
        changeOrderNo: json['change_order_no'] as String? ?? '',
        changeType: json['change_type'] as String? ?? typeAddition,
        title: json['title'] as String? ?? '',
        description: json['description'] as String? ?? '',
        status: json['status'] as String? ?? statusDraft,
        subtotal: _num(json['subtotal']),
        vatRate: _num(json['vat_rate']),
        vatAmount: _num(json['vat_amount']),
        grandTotal: _num(json['grand_total']),
        currency: json['currency'] as String? ?? 'TRY',
        internalNotes: json['internal_notes'] as String? ?? '',
        customerNotes: json['customer_notes'] as String? ?? '',
        createdAt: json['created_at'] as String? ?? '',
        updatedAt: json['updated_at'] as String? ?? '',
        sentAt: _str(json['sent_at']),
        respondedAt: _str(json['responded_at']),
        approvedAt: _str(json['approved_at']),
        rejectedAt: _str(json['rejected_at']),
        cancelledAt: _str(json['cancelled_at']),
        supersedesChangeOrderId: _str(json['supersedes_change_order_id']),
        activeShareToken: _str(json['active_share_token']),
        items: (json['items'] as List? ?? const [])
            .cast<Map<String, dynamic>>()
            .map(ProjectChangeOrderItem.fromJson)
            .toList(),
        profitability: json['profitability'] is Map<String, dynamic>
            ? ChangeOrderProfitability.fromJson(json['profitability'] as Map<String, dynamic>)
            : null,
        decisionRecordedBy: _str(json['decision_recorded_by']),
        decisionRecordedByName: json['decision_recorded_by_name'] as String? ?? '',
        decisionNote: json['decision_note'] as String? ?? '',
      );

  /// Listeden gelen kârlılığı detaya ekler (detay ucu hesaplamaz).
  ProjectChangeOrder withProfitability(ChangeOrderProfitability? value) => value == null
      ? this
      : ProjectChangeOrder(
          id: id,
          projectId: projectId,
          sequenceNo: sequenceNo,
          changeOrderNo: changeOrderNo,
          changeType: changeType,
          title: title,
          description: description,
          status: status,
          subtotal: subtotal,
          vatRate: vatRate,
          vatAmount: vatAmount,
          grandTotal: grandTotal,
          currency: currency,
          internalNotes: internalNotes,
          customerNotes: customerNotes,
          createdAt: createdAt,
          updatedAt: updatedAt,
          sentAt: sentAt,
          respondedAt: respondedAt,
          approvedAt: approvedAt,
          rejectedAt: rejectedAt,
          cancelledAt: cancelledAt,
          supersedesChangeOrderId: supersedesChangeOrderId,
          activeShareToken: activeShareToken,
          items: items,
          profitability: value,
          decisionRecordedBy: decisionRecordedBy,
          decisionRecordedByName: decisionRecordedByName,
          decisionNote: decisionNote,
        );

  bool get isAddition => changeType != typeDeduction;

  /// Proje bedeline etkisi, YALNIZCA görüntüleme için işaretli
  /// (web `formatSignedMoney(deduction ? -grand_total : grand_total)`).
  double get signedTotal => isAddition ? grandTotal : -grandTotal;

  String get typeLabel => kChangeOrderTypeLabels[changeType] ?? changeType;

  bool get isEditable => status == statusDraft;
  bool get canSend => status == statusDraft;
  bool get canCancel => status == statusDraft || status == statusSent;

  /// domain `IsRevisable`: yalnızca müşteriye ulaşmış ya da reddedilmiş.
  bool get canRevise => status == statusSent || status == statusRejected;

  /// Web yalnızca `sent` iken "Mail Gönder"/"Linki Kopyala" gösterir.
  bool get canEmail => status == statusSent;
  bool get hasShareLink => status == statusSent && (activeShareToken?.isNotEmpty ?? false);

  /// Müşteri kararı (linkten ya da ekibin kaydıyla) yalnızca gönderilmiş
  /// bir ek işe verilebilir -- backend applyChangeOrderDecision ile aynı.
  bool get canRecordDecision => status == statusSent;

  static double _num(Object? v) => (v as num?)?.toDouble() ?? 0;
  static String? _str(Object? v) {
    final s = v as String?;
    return (s == null || s.isEmpty) ? null : s;
  }
}

class ProjectChangeOrderItem {
  const ProjectChangeOrderItem({
    required this.id,
    required this.description,
    required this.quantity,
    required this.unit,
    required this.unitPrice,
    required this.lineTotal,
    this.productId,
    this.sortOrder = 0,
    this.estimatedUnitCost,
    this.estimatedCost,
  });

  final String id;
  final String? productId;
  final String description;
  final double quantity;
  final String unit;
  final double unitPrice;
  final double lineTotal;
  final int sortOrder;

  /// Dahili tahmini maliyet -- mobil formda düzenlenmez ama düzenleme
  /// sırasında KORUNUR (PUT kalemleri tümden değiştirir; gönderilmezse
  /// sessizce silinirdi).
  final double? estimatedUnitCost;
  final double? estimatedCost;

  factory ProjectChangeOrderItem.fromJson(Map<String, dynamic> json) => ProjectChangeOrderItem(
        id: json['id'] as String? ?? '',
        productId: json['product_id'] as String?,
        description: json['description'] as String? ?? '',
        quantity: (json['quantity'] as num?)?.toDouble() ?? 0,
        unit: json['unit'] as String? ?? '',
        unitPrice: (json['unit_price'] as num?)?.toDouble() ?? 0,
        lineTotal: (json['line_total'] as num?)?.toDouble() ?? 0,
        sortOrder: (json['sort_order'] as num?)?.toInt() ?? 0,
        estimatedUnitCost: (json['estimated_unit_cost'] as num?)?.toDouble(),
        estimatedCost: (json['estimated_cost'] as num?)?.toDouble(),
      );
}

/// TEK bir ek işin dahili gelir/maliyet/kâr görünümü -- proje toplamına
/// zaten giren, `change_order_id` ile etiketlenmiş kayıtların süzülmüş
/// hali (ayrı bir para akışı DEĞİL). Tümü sunucu hesabıdır.
class ChangeOrderProfitability {
  const ChangeOrderProfitability({
    required this.revenueEffect,
    required this.realizedCost,
    required this.committedCost,
    required this.realizedProfit,
    required this.estimatedProfit,
    required this.realizedMarginPercent,
    required this.estimatedMarginPercent,
  });

  final double revenueEffect;
  final double realizedCost;
  final double committedCost;
  final double realizedProfit;
  final double estimatedProfit;
  final double realizedMarginPercent;
  final double estimatedMarginPercent;

  factory ChangeOrderProfitability.fromJson(Map<String, dynamic> json) => ChangeOrderProfitability(
        revenueEffect: (json['revenue_effect'] as num?)?.toDouble() ?? 0,
        realizedCost: (json['realized_cost'] as num?)?.toDouble() ?? 0,
        committedCost: (json['committed_cost'] as num?)?.toDouble() ?? 0,
        realizedProfit: (json['realized_profit'] as num?)?.toDouble() ?? 0,
        estimatedProfit: (json['estimated_profit'] as num?)?.toDouble() ?? 0,
        realizedMarginPercent: (json['realized_margin_percent'] as num?)?.toDouble() ?? 0,
        estimatedMarginPercent: (json['estimated_margin_percent'] as num?)?.toDouble() ?? 0,
      );
}

/// Kalem gövdesi -- teklif kalemleriyle aynı dört alan (açıklama, miktar,
/// birim, birim fiyat); `productId`/`estimatedUnitCost` yalnızca mevcut
/// bir kalemden KORUNARAK taşınır.
class ChangeOrderItemInput {
  const ChangeOrderItemInput({
    required this.description,
    required this.quantity,
    required this.unit,
    required this.unitPrice,
    this.productId,
    this.estimatedUnitCost,
  });

  final String? productId;
  final String description;
  final double quantity;
  final String unit;
  final double unitPrice;
  final double? estimatedUnitCost;

  Map<String, dynamic> toJson() => {
        'product_id': productId,
        'description': description,
        'quantity': quantity,
        'unit': unit,
        'unit_price': unitPrice,
        if (estimatedUnitCost != null) 'estimated_unit_cost': estimatedUnitCost,
      };
}

/// `POST/PUT /projects/{id}/change-orders[/{coId}]` gövdesi (backend
/// `changeOrderRequest`). PUT kalemleri TÜMDEN değiştirir.
class ChangeOrderInput {
  const ChangeOrderInput({
    required this.changeType,
    required this.title,
    required this.vatRate,
    required this.items,
    this.description = '',
    this.customerNotes = '',
    this.internalNotes = '',
  });

  final String changeType;
  final String title;
  final String description;
  final double vatRate;
  final String customerNotes;
  final String internalNotes;
  final List<ChangeOrderItemInput> items;

  Map<String, dynamic> toJson() => {
        'change_type': changeType,
        'title': title,
        'description': description,
        'vat_rate': vatRate,
        'customer_notes': customerNotes,
        'internal_notes': internalNotes,
        'items': [for (final i in items) i.toJson()],
      };
}

/// `POST .../change-orders/{coId}/send-email` gövdesi. Konu/mesaj boşsa
/// sunucu varsayılanı kullanır ve paylaşım linkini mesajın sonuna ekler.
class ChangeOrderEmailInput {
  const ChangeOrderEmailInput({required this.to, this.subject = '', this.message = ''});

  final String to;
  final String subject;
  final String message;

  Map<String, dynamic> toJson() => {'to': to, 'subject': subject, 'message': message};
}

/// `GET /projects/{id}/financial-summary`'nin sözleşme-değeri kırılımı
/// (Faz 8): ana sözleşme (ASLA değişmez) + onaylı ek iş/eksiltmeler =
/// güncel proje bedeli; onay bekleyenler yalnızca bilgi amaçlı
/// "potansiyel" değerdir, güncel bedelle KARIŞTIRILMAZ.
class ContractValueSummary {
  const ContractValueSummary({
    required this.baseContractAmount,
    required this.approvedAdditions,
    required this.approvedDeductions,
    required this.currentContractValue,
    required this.pendingAdditions,
    required this.pendingDeductions,
    required this.potentialContractValue,
    required this.currency,
  });

  final double baseContractAmount;
  final double approvedAdditions;
  final double approvedDeductions;
  final double currentContractValue;
  final double pendingAdditions;
  final double pendingDeductions;
  final double potentialContractValue;
  final String currency;

  bool get hasPending => pendingAdditions > 0 || pendingDeductions > 0;

  /// Onay bekleyen net etki -- web `pending_additions - pending_deductions`
  /// ile aynı (yalnızca görüntüleme).
  double get pendingNet => pendingAdditions - pendingDeductions;

  factory ContractValueSummary.fromJson(Map<String, dynamic> json) {
    double n(String key) => (json[key] as num?)?.toDouble() ?? 0;
    return ContractValueSummary(
      baseContractAmount: n('base_contract_amount'),
      approvedAdditions: n('approved_additions'),
      approvedDeductions: n('approved_deductions'),
      currentContractValue: n('current_contract_value'),
      pendingAdditions: n('pending_additions'),
      pendingDeductions: n('pending_deductions'),
      potentialContractValue: n('potential_contract_value'),
      currency: json['currency'] as String? ?? 'TRY',
    );
  }
}

/// Ek işe ait proje olayı (`GET /projects/{id}/events`, `change_order_*`
/// tipleri). Backend'de ek iş e-posta günlüğünü listeleyen bir uç YOK --
/// gönderilen/başarısız e-postalar bu olaylardan (alıcıyla) okunur.
class ChangeOrderEvent {
  const ChangeOrderEvent({
    required this.id,
    required this.eventType,
    required this.createdAt,
    this.changeOrderIds = const {},
    this.recipient,
    this.newChangeOrderId,
    this.source,
    this.note,
  });

  final String id;
  final String eventType;
  final String createdAt;

  /// Olayın ilgili olduğu ek iş(ler): `change_order_id`; revizyon olayında
  /// hem eski hem yeni kayıt.
  final Set<String> changeOrderIds;

  /// Yalnızca e-posta olaylarında.
  final String? recipient;

  /// Yalnızca revizyon (`change_order_superseded`) olayında: açılan YENİ
  /// taslak. Aynı olay eski kayıtta "revize edildi", yenide "revizyon
  /// olarak oluşturuldu" diye okunur.
  final String? newChangeOrderId;

  /// Onay/red olayında `staff` = müşteri kararını ekip kaydetti (metadata
  /// `source`); müşterinin kendi linkinden gelen kararda null.
  final String? source;

  /// Ekibin kaydettiği karardaki not.
  final String? note;

  static const prefix = 'change_order_';
  static const sourceStaff = 'staff';

  factory ChangeOrderEvent.fromJson(Map<String, dynamic> json) {
    final meta = json['metadata'] is Map<String, dynamic> ? json['metadata'] as Map<String, dynamic> : const {};
    final ids = <String>{
      for (final key in const ['change_order_id', 'old_change_order_id', 'new_change_order_id'])
        if (meta[key] is String && (meta[key] as String).isNotEmpty) meta[key] as String,
    };
    final recipient = meta['recipient'];
    final newId = meta['new_change_order_id'];
    final source = meta['source'];
    final note = meta['note'];
    return ChangeOrderEvent(
      id: json['id'] as String? ?? '',
      eventType: json['event_type'] as String? ?? '',
      createdAt: json['created_at'] as String? ?? '',
      changeOrderIds: ids,
      recipient: recipient is String && recipient.isNotEmpty ? recipient : null,
      newChangeOrderId: newId is String && newId.isNotEmpty ? newId : null,
      source: source is String && source.isNotEmpty ? source : null,
      note: note is String && note.isNotEmpty ? note : null,
    );
  }

  bool get isView => eventType == 'change_order_viewed';
  bool get isStaffDecision => source == sourceStaff;
}

/// Web `CHANGE_ORDER_TYPE_LABELS` ile aynı.
const kChangeOrderTypeLabels = <String, String>{
  ProjectChangeOrder.typeAddition: 'Ek İş',
  ProjectChangeOrder.typeDeduction: 'Eksiltme',
};
