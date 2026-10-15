/// Stok Takibi (backend migration 0072): projelerden bağımsız depolar,
/// malzeme kartları, parti/SKT ve fişler (giriş, çıkış, aktarım, fire,
/// sayım, iptal). Çıkıştaki proje yalnızca bilgidir; fiş kaydedildikten
/// sonra değişmez, yanlış fiş iptal fişiyle geri alınır.
library;

const kInventoryRead = 'inventory.read';
const kInventoryManage = 'inventory.manage';
const kInventoryAdjust = 'inventory.adjust';

const kDocReceipt = 'receipt';
const kDocIssue = 'issue';
const kDocTransfer = 'transfer';
const kDocWaste = 'waste';
const kDocCount = 'count';
const kDocReversal = 'reversal';

/// Fiş türü -> etiket.
const kInventoryDocLabels = <String, String>{
  kDocReceipt: 'Giriş',
  kDocIssue: 'Çıkış',
  kDocTransfer: 'Aktarım',
  kDocWaste: 'Fire',
  kDocCount: 'Sayım',
  kDocReversal: 'İptal',
};

/// Fire nedenleri (backend CHECK ile aynı).
const kWasteReasons = <String, String>{
  'damaged': 'Hasar / kırık',
  'expired': 'SKT geçti',
  'cutting': 'Kesim / artık',
  'lost': 'Kayıp / çalıntı',
  'other': 'Diğer',
};

/// SKT davranışı.
const kExpiryPolicyWarn = 'warn';
const kExpiryPolicyBlock = 'block';

double _d(Object? v) => (v as num?)?.toDouble() ?? 0;
double? _dn(Object? v) => (v as num?)?.toDouble();
List<T> _list<T>(Object? raw, T Function(Map<String, dynamic>) f) =>
    (raw as List? ?? const []).cast<Map<String, dynamic>>().map(f).toList();

/// "12,5 kg" -- gereksiz sıfırlar atılır.
String formatQty(double v, [String unit = '']) {
  var s = v.toStringAsFixed(3);
  s = s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  s = s.replaceAll('.', ',');
  return unit.isEmpty ? s : '$s $unit';
}

class InventoryWarehouse {
  const InventoryWarehouse({
    required this.id,
    required this.name,
    this.address = '',
    this.notes = '',
    this.isActive = true,
    this.itemCount = 0,
  });

  final String id;
  final String name;
  final String address;
  final String notes;
  final bool isActive;
  final int itemCount;

  factory InventoryWarehouse.fromJson(Map<String, dynamic> j) => InventoryWarehouse(
        id: j['id'] as String,
        name: j['name'] as String? ?? '',
        address: j['address'] as String? ?? '',
        notes: j['notes'] as String? ?? '',
        isActive: j['is_active'] as bool? ?? true,
        itemCount: (j['item_count'] as num?)?.toInt() ?? 0,
      );
}

class InventoryItem {
  const InventoryItem({
    required this.id,
    required this.code,
    required this.name,
    this.barcode = '',
    this.unit = 'adet',
    this.category = '',
    this.productId,
    this.minStock,
    this.trackExpiry = false,
    this.shelfLifeMonths,
    this.expiryPolicy = kExpiryPolicyWarn,
    this.expiryAlertDays = 30,
    this.notes = '',
    this.isActive = true,
    this.quantity = 0,
    this.nearestExpiry,
    this.expiredQuantity = 0,
    this.expiringQuantity = 0,
    this.belowMin = false,
    this.avgUnitCost,
    this.stockValue,
  });

  final String id;
  final String code;
  final String name;
  final String barcode;
  final String unit;
  final String category;
  final String? productId;
  final double? minStock;
  final bool trackExpiry;
  final int? shelfLifeMonths;
  final String expiryPolicy;
  final int expiryAlertDays;
  final String notes;
  final bool isActive;
  final double quantity;

  /// YYYY-AA-GG.
  final String? nearestExpiry;
  final double expiredQuantity;
  final double expiringQuantity;
  final bool belowMin;

  /// Yalnızca inventory.manage sahibine gelir.
  final double? avgUnitCost;
  final double? stockValue;

  bool get blocksExpired => expiryPolicy == kExpiryPolicyBlock;

  factory InventoryItem.fromJson(Map<String, dynamic> j) => InventoryItem(
        id: j['id'] as String,
        code: j['code'] as String? ?? '',
        name: j['name'] as String? ?? '',
        barcode: j['barcode'] as String? ?? '',
        unit: j['unit'] as String? ?? 'adet',
        category: j['category'] as String? ?? '',
        productId: j['product_id'] as String?,
        minStock: _dn(j['min_stock']),
        trackExpiry: j['track_expiry'] as bool? ?? false,
        shelfLifeMonths: (j['shelf_life_months'] as num?)?.toInt(),
        expiryPolicy: j['expiry_policy'] as String? ?? kExpiryPolicyWarn,
        expiryAlertDays: (j['expiry_alert_days'] as num?)?.toInt() ?? 30,
        notes: j['notes'] as String? ?? '',
        isActive: j['is_active'] as bool? ?? true,
        quantity: _d(j['quantity']),
        nearestExpiry: j['nearest_expiry'] as String?,
        expiredQuantity: _d(j['expired_quantity']),
        expiringQuantity: _d(j['expiring_quantity']),
        belowMin: j['below_min'] as bool? ?? false,
        avgUnitCost: _dn(j['avg_unit_cost']),
        stockValue: _dn(j['stock_value']),
      );
}

/// GET /inventory/items yanıtı.
class InventoryItemsPage {
  const InventoryItemsPage({required this.items, required this.canSeeValues});

  final List<InventoryItem> items;
  final bool canSeeValues;

  factory InventoryItemsPage.fromJson(Map<String, dynamic> j) => InventoryItemsPage(
        items: _list(j['items'], InventoryItem.fromJson),
        canSeeValues: j['can_see_values'] as bool? ?? false,
      );
}

/// Depo + parti bakiyesi.
class InventoryBalance {
  const InventoryBalance({
    required this.warehouseId,
    required this.warehouseName,
    required this.lotId,
    required this.lotNo,
    required this.expiryDate,
    required this.productionDate,
    required this.quantity,
  });

  final String warehouseId;
  final String warehouseName;
  final String? lotId;
  final String lotNo;
  final String? expiryDate;
  final String? productionDate;
  final double quantity;

  factory InventoryBalance.fromJson(Map<String, dynamic> j) => InventoryBalance(
        warehouseId: j['warehouse_id'] as String? ?? '',
        warehouseName: j['warehouse_name'] as String? ?? '',
        lotId: j['lot_id'] as String?,
        lotNo: j['lot_no'] as String? ?? '',
        expiryDate: j['expiry_date'] as String?,
        productionDate: j['production_date'] as String?,
        quantity: _d(j['quantity']),
      );
}

/// Sayım ekranının satırı (GET /inventory/warehouses/{id}/balances).
class WarehouseBalance {
  const WarehouseBalance({
    required this.itemId,
    required this.itemCode,
    required this.itemName,
    required this.unit,
    required this.lotId,
    required this.lotNo,
    required this.expiryDate,
    required this.quantity,
  });

  final String itemId;
  final String itemCode;
  final String itemName;
  final String unit;
  final String? lotId;
  final String lotNo;
  final String? expiryDate;
  final double quantity;

  String get key => '$itemId|${lotId ?? ''}';

  factory WarehouseBalance.fromJson(Map<String, dynamic> j) => WarehouseBalance(
        itemId: j['item_id'] as String,
        itemCode: j['item_code'] as String? ?? '',
        itemName: j['item_name'] as String? ?? '',
        unit: j['unit'] as String? ?? '',
        lotId: j['lot_id'] as String?,
        lotNo: j['lot_no'] as String? ?? '',
        expiryDate: j['expiry_date'] as String?,
        quantity: _d(j['quantity']),
      );
}

class InventoryDocumentSummary {
  const InventoryDocumentSummary({
    required this.id,
    required this.docNo,
    required this.docType,
    required this.docDate,
    required this.status,
    this.counterparty = '',
    this.referenceNo = '',
    this.reason = '',
    this.warehouseName = '',
    this.targetWarehouseName = '',
    this.projectName = '',
    this.createdByName = '',
    this.itemCount = 0,
    this.firstItemName = '',
    this.isReversal = false,
  });

  final String id;
  final String docNo;
  final String docType;
  final String docDate;
  final String status;
  final String counterparty;
  final String referenceNo;
  final String reason;
  final String warehouseName;
  final String targetWarehouseName;
  final String projectName;
  final String createdByName;
  final int itemCount;
  final String firstItemName;
  final bool isReversal;

  bool get isReversed => status == 'reversed';
  String get typeLabel => kInventoryDocLabels[docType] ?? docType;

  /// "Kutu Profil +2 kalem".
  String get itemsLabel => itemCount > 1 ? '$firstItemName +${itemCount - 1} kalem' : firstItemName;

  factory InventoryDocumentSummary.fromJson(Map<String, dynamic> j) => InventoryDocumentSummary(
        id: j['id'] as String,
        docNo: j['doc_no'] as String? ?? '',
        docType: j['doc_type'] as String? ?? '',
        docDate: j['doc_date'] as String? ?? '',
        status: j['status'] as String? ?? 'posted',
        counterparty: j['counterparty'] as String? ?? '',
        referenceNo: j['reference_no'] as String? ?? '',
        reason: j['reason'] as String? ?? '',
        warehouseName: j['warehouse_name'] as String? ?? '',
        targetWarehouseName: j['target_warehouse_name'] as String? ?? '',
        projectName: j['project_name'] as String? ?? '',
        createdByName: j['created_by_name'] as String? ?? '',
        itemCount: (j['item_count'] as num?)?.toInt() ?? 0,
        firstItemName: j['first_item_name'] as String? ?? '',
        isReversal: j['is_reversal'] as bool? ?? false,
      );
}

class InventoryLine {
  const InventoryLine({
    required this.lineNo,
    required this.itemId,
    required this.itemCode,
    required this.itemName,
    required this.unit,
    required this.warehouseId,
    required this.warehouseName,
    required this.lotId,
    required this.lotNo,
    required this.expiryDate,
    required this.quantity,
    this.unitCost,
  });

  final int lineNo;
  final String itemId;
  final String itemCode;
  final String itemName;
  final String unit;
  final String warehouseId;
  final String warehouseName;
  final String? lotId;
  final String lotNo;
  final String? expiryDate;

  /// İşaretli: + giriş, − çıkış.
  final double quantity;
  final double? unitCost;

  factory InventoryLine.fromJson(Map<String, dynamic> j) => InventoryLine(
        lineNo: (j['line_no'] as num?)?.toInt() ?? 0,
        itemId: j['item_id'] as String? ?? '',
        itemCode: j['item_code'] as String? ?? '',
        itemName: j['item_name'] as String? ?? '',
        unit: j['unit'] as String? ?? '',
        warehouseId: j['warehouse_id'] as String? ?? '',
        warehouseName: j['warehouse_name'] as String? ?? '',
        lotId: j['lot_id'] as String?,
        lotNo: j['lot_no'] as String? ?? '',
        expiryDate: j['expiry_date'] as String?,
        quantity: _d(j['quantity']),
        unitCost: _dn(j['unit_cost']),
      );
}

class InventoryDocument {
  const InventoryDocument({
    required this.summary,
    required this.warehouseId,
    this.targetWarehouseId,
    this.projectId,
    this.projectNo = '',
    this.supplierName = '',
    this.note = '',
    this.hasAttachment = false,
    this.attachmentName = '',
    this.attachmentMime = '',
    this.reversalOfId,
    this.reversalOfNo = '',
    this.reversedByDocId,
    this.reversedByDocNo = '',
    this.reversedAt,
    this.reversedByName = '',
    this.reverseReason = '',
    this.lines = const [],
    this.warnings = const [],
  });

  final InventoryDocumentSummary summary;
  final String warehouseId;
  final String? targetWarehouseId;
  final String? projectId;
  final String projectNo;
  final String supplierName;
  final String note;
  final bool hasAttachment;
  final String attachmentName;
  final String attachmentMime;
  final String? reversalOfId;
  final String reversalOfNo;
  final String? reversedByDocId;
  final String reversedByDocNo;
  final String? reversedAt;
  final String reversedByName;
  final String reverseReason;
  final List<InventoryLine> lines;

  /// Kaydı engellemeyen notlar (ör. SKT'si geçmiş parti kullanıldı).
  final List<String> warnings;

  String get id => summary.id;
  bool get canReverse => !summary.isReversed && summary.docType != kDocReversal;

  factory InventoryDocument.fromJson(Map<String, dynamic> j) => InventoryDocument(
        summary: InventoryDocumentSummary.fromJson(j),
        warehouseId: j['warehouse_id'] as String? ?? '',
        targetWarehouseId: j['target_warehouse_id'] as String?,
        projectId: j['project_id'] as String?,
        projectNo: j['project_no'] as String? ?? '',
        supplierName: j['supplier_name'] as String? ?? '',
        note: j['note'] as String? ?? '',
        hasAttachment: j['has_attachment'] as bool? ?? false,
        attachmentName: j['attachment_name'] as String? ?? '',
        attachmentMime: j['attachment_mime'] as String? ?? '',
        reversalOfId: j['reversal_of_id'] as String?,
        reversalOfNo: j['reversal_of_no'] as String? ?? '',
        reversedByDocId: j['reversed_by_doc_id'] as String?,
        reversedByDocNo: j['reversed_by_doc_no'] as String? ?? '',
        reversedAt: j['reversed_at'] as String?,
        reversedByName: j['reversed_by_name'] as String? ?? '',
        reverseReason: j['reverse_reason'] as String? ?? '',
        lines: _list(j['lines'], InventoryLine.fromJson),
        warnings: (j['warnings'] as List? ?? const []).cast<String>(),
      );
}

/// GET /inventory/items/{id}.
class InventoryItemDetail {
  const InventoryItemDetail({
    required this.item,
    required this.balances,
    required this.documents,
    required this.canSeeValues,
  });

  final InventoryItem item;
  final List<InventoryBalance> balances;
  final List<InventoryDocumentSummary> documents;
  final bool canSeeValues;

  factory InventoryItemDetail.fromJson(Map<String, dynamic> j) => InventoryItemDetail(
        item: InventoryItem.fromJson(j['item'] as Map<String, dynamic>),
        balances: _list(j['balances'], InventoryBalance.fromJson),
        documents: _list(j['documents'], InventoryDocumentSummary.fromJson),
        canSeeValues: j['can_see_values'] as bool? ?? false,
      );
}

class InventorySummary {
  const InventorySummary({
    this.itemCount = 0,
    this.stockValue,
    this.expiredLotCount = 0,
    this.expiringLotCount = 0,
    this.belowMinCount = 0,
  });

  final int itemCount;
  final double? stockValue;
  final int expiredLotCount;
  final int expiringLotCount;
  final int belowMinCount;

  bool get hasAlerts => expiredLotCount + expiringLotCount + belowMinCount > 0;

  factory InventorySummary.fromJson(Map<String, dynamic> j) => InventorySummary(
        itemCount: (j['item_count'] as num?)?.toInt() ?? 0,
        stockValue: _dn(j['stock_value']),
        expiredLotCount: (j['expired_lot_count'] as num?)?.toInt() ?? 0,
        expiringLotCount: (j['expiring_lot_count'] as num?)?.toInt() ?? 0,
        belowMinCount: (j['below_min_count'] as num?)?.toInt() ?? 0,
      );
}

/// Fiş satırı girdisi (formdan POST gövdesine).
class InventoryLineDraft {
  InventoryLineDraft({
    required this.item,
    this.quantity = 0,
    this.countedQuantity,
    this.unitCost,
    this.lotId,
    this.lotLabel = '',
    this.lotNo = '',
    this.expiryDate,
    this.productionDate,
    this.systemQuantity,
  });

  final InventoryItem item;
  double quantity;
  double? countedQuantity;
  double? unitCost;
  String? lotId;

  /// Seçilen partinin görünen adı (çıkış/sayım).
  String lotLabel;
  String lotNo;

  /// YYYY-AA-GG.
  String? expiryDate;
  String? productionDate;

  /// Sayımda sistemdeki miktar (bilgi).
  double? systemQuantity;

  Map<String, dynamic> toJson(String docType) => {
        'item_id': item.id,
        if (docType == kDocCount) 'counted_quantity': countedQuantity else 'quantity': quantity,
        if (docType == kDocReceipt && unitCost != null) 'unit_cost': unitCost,
        if (lotId != null && lotId!.isNotEmpty) 'lot_id': lotId,
        if (lotNo.trim().isNotEmpty) 'lot_no': lotNo.trim(),
        if (expiryDate != null) 'expiry_date': expiryDate,
        if (productionDate != null) 'production_date': productionDate,
      };
}
