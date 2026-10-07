import '../../../../core/widgets/status_badge.dart';
import '../../domain/procurement.dart' show Commitment;
import '../../domain/project.dart' show CostControlLine, CostControlSummary;

export '../../domain/procurement.dart' show Commitment;
export '../../domain/project.dart' show CostControlLine, CostControlSummary;
export '../../domain/subcontract.dart' show OrgCostCode;

// ---------------------------------------------------------------------------
// Bütçe & Maliyet Kontrolü (Sprint 2, bkz. docs/cost-control.md) -- mobilin
// web "Maliyet Kontrolü" sekmesiyle (CostControlSections.tsx) aynı yönetim
// yüzeyi. Backend TÜM hesapları (revize/taahhüt/gerçekleşen/ETC/EAC/varyans/
// tahmini kâr) OTORİTER olarak yapar; buradaki tipler yalnızca API
// yanıtlarının şeklidir, hiçbir türetilmiş rakam burada yeniden
// HESAPLANMAZ.
// ---------------------------------------------------------------------------

/// İzin kodları -- backend router.go ile BİREBİR:
/// - `budget.read`: GET wbs, budget, budget/lines, budget/adjustments
/// - `budget.manage`: WBS ekle/düzenle/arşivle, bütçe oluştur/baseline,
///   kalem ekle/düzenle/sil, revizyon oluştur/onayla/reddet
/// - `cost_control.read`: GET commitments, forecasts, cost-control
/// - `cost_control.manage`: manuel taahhüt oluştur/iptal, kalem tahmini (ETC)
/// Hepsi proje-kapsamlıdır (projPerm: izin + proje üyeliği).
const kBudgetReadPermission = 'projects.budget.read';
const kBudgetManagePermission = 'projects.budget.manage';
const kCostControlReadPermission = 'projects.cost_control.read';
const kCostControlManagePermission = 'projects.cost_control.manage';

/// "Gerçekleşen" kırılımı masraf kayıtlarından gelir (`GET /expenses`,
/// `projects.finance.read`) -- ayrı bir gerçekleşen-maliyet defteri YOKTUR.
const kFinanceReadPermission = 'projects.finance.read';

/// `GET /organization/cost-codes` (kalem/taahhüt formundaki seçici).
const kCostCodesReadPermission = 'organization.cost_codes.read';

/// `GET /projects/{id}/cost-control` yanıtı (özet + kırılım tablosu) --
/// `projects_repository.dart` `costControl()` ile aynı şekil.
typedef CostControlData = ({CostControlSummary summary, List<CostControlLine> lines});

// ---------- Durum sözlükleri (web lib/types.ts + lib/status.ts ile aynı etiketler) ----------

abstract final class BudgetStatusRegistry {
  static const budget = {'draft': ('Taslak', StatusTone.muted), 'baselined': ('Baseline Alındı', StatusTone.success)};

  static const adjustment = {
    'draft': ('Taslak', StatusTone.muted),
    'approved': ('Onaylandı', StatusTone.success),
    'rejected': ('Reddedildi', StatusTone.danger),
  };

  /// Web'de "active" gold tonludur; mobilde gold yalnızca marka vurgusudur
  /// (bkz. StatusTone yorumu), diğer "aktif" durumlarla tutarlı olarak info.
  static const commitment = {'active': ('Aktif', StatusTone.info), 'voided': ('İptal Edildi', StatusTone.danger)};
}

/// Taahhüt kaynağı (`project_commitments.source_type`). Satın alma ve
/// taşeron taahhütleri KENDİ belgelerinin yaşam döngüsüyle oluşur/iptal
/// olur (bkz. docs/cost-control.md §5).
const kCommitmentSourceLabels = {
  'manual': 'Manuel',
  'purchase_order': 'Satın Alma Siparişi',
  'subcontract': 'Taşeron Sözleşmesi',
};

String commitmentSourceLabel(String sourceType) => kCommitmentSourceLabels[sourceType] ?? sourceType;

/// Yalnızca manuel taahhütler bu ekrandan iptal edilebilir; satın alma/
/// taşeron kaynaklı taahhütler kendi belgesinin iptal/fesih akışıyla
/// geçersiz kılınır (aksi halde belge "onaylı" dururken taahhüdü sessizce
/// düşerdi).
bool canVoidCommitmentHere(Commitment c) => c.status == 'active' && c.sourceType == 'manual';

// ---------- WBS ----------

/// backend `wbsNodeResponse`. Arşivlenmiş düğümler de döner (ağaç korunur,
/// istemcide soluk gösterilir); parent DEĞİŞTİRİLEMEZ (yalnız ad/kod/sıra).
class WbsNode {
  const WbsNode({
    required this.id,
    this.parentId,
    required this.code,
    required this.name,
    this.sortOrder = 0,
    this.isActive = true,
  });

  final String id;
  final String? parentId;
  final String code;
  final String name;
  final int sortOrder;
  final bool isActive;

  String get label => '$code — $name';

  factory WbsNode.fromJson(Map<String, dynamic> json) => WbsNode(
    id: json['id'] as String,
    parentId: json['parent_id'] as String?,
    code: json['code'] as String? ?? '',
    name: json['name'] as String? ?? '',
    sortOrder: (json['sort_order'] as num?)?.toInt() ?? 0,
    isActive: json['is_active'] as bool? ?? true,
  );
}

/// Ağacın düz, girintili sırası: her düğüm derinliğiyle birlikte, kardeşler
/// web ile aynı sırada (sort_order, sonra kod).
typedef WbsTreeEntry = ({WbsNode node, int depth});

/// Web `WBSTab` ile aynı gruplama: parent_id'ye göre, kökler önce. Üstü
/// listede olmayan (ör. başka sayfada/bozuk) düğüm KAYBOLMAZ, kök sayılır;
/// döngüye karşı her düğüm en fazla bir kez yazılır.
List<WbsTreeEntry> flattenWbsTree(List<WbsNode> nodes) {
  final ids = {for (final n in nodes) n.id};
  final byParent = <String?, List<WbsNode>>{};
  for (final n in nodes) {
    final key = (n.parentId != null && ids.contains(n.parentId)) ? n.parentId : null;
    byParent.putIfAbsent(key, () => []).add(n);
  }
  for (final list in byParent.values) {
    list.sort((a, b) {
      final bySort = a.sortOrder.compareTo(b.sortOrder);
      return bySort != 0 ? bySort : a.code.compareTo(b.code);
    });
  }
  final out = <WbsTreeEntry>[];
  final seen = <String>{};
  void walk(String? parent, int depth) {
    for (final n in byParent[parent] ?? const <WbsNode>[]) {
      if (!seen.add(n.id)) continue;
      out.add((node: n, depth: depth));
      walk(n.id, depth + 1);
    }
  }

  walk(null, 0);
  // Döngüdeki (kökü olmayan) düğümler de görünür kalsın.
  for (final n in nodes) {
    if (seen.add(n.id)) out.add((node: n, depth: 0));
  }
  return out;
}

/// POST/PUT gövdesi `{parent_id, code, name, sort_order}` -- parent_id
/// yalnızca oluştururken anlamlıdır (backend güncellemede okumaz).
class WbsNodeInput {
  const WbsNodeInput({this.parentId, required this.code, required this.name, this.sortOrder = 0});

  final String? parentId;
  final String code;
  final String name;
  final int sortOrder;

  Map<String, dynamic> toJson() => {'parent_id': parentId ?? '', 'code': code, 'name': name, 'sort_order': sortOrder};
}

// ---------- Bütçe ----------

/// backend `projectBudgetResponse`. Bir projede EN FAZLA bir bütçe vardır;
/// yoksa `GET /budget` 404 döner (repository bunu null'a çevirir).
class ProjectBudget {
  const ProjectBudget({
    required this.id,
    required this.currency,
    required this.status,
    this.version = 1,
    this.baselinedAt,
  });

  final String id;
  final String currency;
  final String status;
  final int version;
  final String? baselinedAt;

  bool get isDraft => status == 'draft';
  bool get isBaselined => status == 'baselined';

  factory ProjectBudget.fromJson(Map<String, dynamic> json) => ProjectBudget(
    id: json['id'] as String,
    currency: json['currency'] as String? ?? 'TRY',
    status: json['status'] as String? ?? 'draft',
    version: (json['version'] as num?)?.toInt() ?? 1,
    baselinedAt: json['baselined_at'] as String?,
  );
}

/// backend `budgetLineResponse` (WBS/maliyet kodu adları dahil).
class BudgetLine {
  const BudgetLine({
    required this.id,
    this.wbsNodeId,
    this.wbsCode = '',
    this.wbsName = '',
    required this.costCodeId,
    this.costCodeCode = '',
    this.costCodeName = '',
    required this.description,
    this.quantity,
    this.unit = '',
    this.unitCost,
    required this.originalAmount,
    this.notes = '',
  });

  final String id;
  final String? wbsNodeId;
  final String wbsCode;
  final String wbsName;
  final String costCodeId;
  final String costCodeCode;
  final String costCodeName;
  final String description;
  final double? quantity;
  final String unit;
  final double? unitCost;
  final double originalAmount;
  final String notes;

  String get costCodeLabel =>
      costCodeName.isEmpty ? costCodeCode : (costCodeCode.isEmpty ? costCodeName : '$costCodeCode — $costCodeName');

  factory BudgetLine.fromJson(Map<String, dynamic> json) => BudgetLine(
    id: json['id'] as String,
    wbsNodeId: json['wbs_node_id'] as String?,
    wbsCode: json['wbs_code'] as String? ?? '',
    wbsName: json['wbs_name'] as String? ?? '',
    costCodeId: json['cost_code_id'] as String? ?? '',
    costCodeCode: json['cost_code_code'] as String? ?? '',
    costCodeName: json['cost_code_name'] as String? ?? '',
    description: json['description'] as String? ?? '',
    quantity: (json['quantity'] as num?)?.toDouble(),
    unit: json['unit'] as String? ?? '',
    unitCost: (json['unit_cost'] as num?)?.toDouble(),
    originalAmount: (json['original_amount'] as num?)?.toDouble() ?? 0,
    notes: json['notes'] as String? ?? '',
  );
}

/// POST/PUT `/budget/lines` gövdesi -- web ile aynı alanlar. Miktar VE birim
/// fiyatın ikisi de verilirse tutarı BACKEND hesaplar (istemcinin
/// gönderdiği `original_amount` yok sayılır, bkz. computeLineAmount).
/// Notlar web formunda yok; düzenlemede mevcut not KORUNSUN diye taşınır.
class BudgetLineInput {
  const BudgetLineInput({
    this.wbsNodeId,
    required this.costCodeId,
    required this.description,
    this.quantity,
    this.unit = '',
    this.unitCost,
    this.originalAmount = 0,
    this.notes = '',
  });

  final String? wbsNodeId;
  final String costCodeId;
  final String description;
  final double? quantity;
  final String unit;
  final double? unitCost;
  final double originalAmount;
  final String notes;

  bool get amountComputedByServer => quantity != null && unitCost != null;

  Map<String, dynamic> toJson() => {
    'wbs_node_id': wbsNodeId ?? '',
    'cost_code_id': costCodeId,
    'description': description,
    'quantity': quantity,
    'unit': unit,
    'unit_cost': unitCost,
    'original_amount': originalAmount,
    'notes': notes,
  };
}

// ---------- Bütçe Revizyonları ----------

/// backend `budgetAdjustmentResponse`. YALNIZCA `approved` olanlar revize
/// bütçeyi etkiler; `draft` = onay bekliyor.
class BudgetAdjustment {
  const BudgetAdjustment({
    required this.id,
    required this.budgetLineId,
    required this.amount,
    required this.reason,
    required this.status,
    this.approvedAt,
    this.createdAt = '',
  });

  final String id;
  final String budgetLineId;
  final double amount;
  final String reason;
  final String status;
  final String? approvedAt;
  final String createdAt;

  bool get isPending => status == 'draft';

  factory BudgetAdjustment.fromJson(Map<String, dynamic> json) => BudgetAdjustment(
    id: json['id'] as String,
    budgetLineId: json['budget_line_id'] as String? ?? '',
    amount: (json['amount'] as num?)?.toDouble() ?? 0,
    reason: json['reason'] as String? ?? '',
    status: json['status'] as String? ?? 'draft',
    approvedAt: json['approved_at'] as String?,
    createdAt: json['created_at'] as String? ?? '',
  );
}

// ---------- Tahmin (ETC) ----------

/// backend `forecastResponse` -- kullanıcının BİLİNÇLİ girdiği manuel ETC.
/// Kayıt yoksa backend varsayılanı (Revize − Gerçekleşen, en az 0) kullanır.
class CostForecast {
  const CostForecast({required this.budgetLineId, required this.etcAmount, this.note = '', this.updatedAt = ''});

  final String budgetLineId;
  final double etcAmount;
  final String note;
  final String updatedAt;

  factory CostForecast.fromJson(Map<String, dynamic> json) => CostForecast(
    budgetLineId: json['budget_line_id'] as String? ?? '',
    etcAmount: (json['etc_amount'] as num?)?.toDouble() ?? 0,
    note: json['note'] as String? ?? '',
    updatedAt: json['updated_at'] as String? ?? '',
  );
}

// ---------- Manuel Taahhüt ----------

/// POST `/commitments` gövdesi. Bütçe kalemi seçilirse maliyet kodu O
/// kalemin kodu olarak gönderilir (web ile aynı); `idempotency_key` formun
/// ömrü boyunca sabittir -- çift dokunuş ikinci bir taahhüt YAZMAZ.
class ManualCommitmentInput {
  const ManualCommitmentInput({
    required this.costCodeId,
    this.budgetLineId,
    required this.description,
    required this.amount,
    required this.committedAt,
    required this.idempotencyKey,
  });

  final String costCodeId;
  final String? budgetLineId;
  final String description;
  final double amount;

  /// "YYYY-MM-DD".
  final String committedAt;
  final String idempotencyKey;

  Map<String, dynamic> toJson() => {
    'cost_code_id': costCodeId,
    'budget_line_id': budgetLineId ?? '',
    'description': description,
    'committed_amount': amount,
    'committed_at': committedAt,
    'idempotency_key': idempotencyKey,
  };
}

// ---------- Gerçekleşen (masrafların maliyet koduna göre kırılımı) ----------

/// `GET /projects/{id}/expenses` satırının maliyet kırılımı için gereken alt
/// kümesi (backend `expenseResponse`). Ayrı bir gerçekleşen defteri DEĞİL.
class ActualExpense {
  const ActualExpense({
    required this.id,
    required this.description,
    required this.amount,
    this.currency = 'TRY',
    this.expenseDate = '',
    this.costCodeId,
    this.budgetLineId,
    this.voidedAt,
    this.approvalStatus = 'approved',
  });

  final String id;
  final String description;
  final double amount;
  final String currency;
  final String expenseDate;
  final String? costCodeId;
  final String? budgetLineId;
  final String? voidedAt;

  /// Masraf onayı (backend migration 0060); alan gelmezse `approved`.
  final String approvalStatus;

  bool get isVoided => voidedAt != null;

  /// Gerçekleşen maliyete girer mi: yalnızca onaylı ve iptal edilmemiş
  /// (backend actual_cost ile aynı kural).
  bool get countsAsActual => !isVoided && approvalStatus == 'approved';

  /// Onay bekleyen (iptal edilmemiş) masraf.
  bool get isPending => !isVoided && approvalStatus == 'pending';

  factory ActualExpense.fromJson(Map<String, dynamic> json) => ActualExpense(
    id: json['id'] as String,
    description: json['description'] as String? ?? '',
    amount: (json['amount'] as num?)?.toDouble() ?? 0,
    currency: json['currency'] as String? ?? 'TRY',
    expenseDate: json['expense_date'] as String? ?? '',
    costCodeId: json['cost_code_id'] as String?,
    budgetLineId: json['budget_line_id'] as String?,
    voidedAt: json['voided_at'] as String?,
    approvalStatus: json['approval_status'] as String? ?? 'approved',
  );
}

// ---------- Varyans vurgusu ----------

/// Varyans = Revize − EAC (backend). Negatif = bütçe aşımı.
bool isOverBudget(double variance) => variance < 0;

/// Maliyet kırılımında "yalnızca aşanlar" süzmesi -- sıra backend'inki.
List<CostControlLine> overBudgetLines(List<CostControlLine> lines) => [
  for (final l in lines)
    if (isOverBudget(l.variance)) l,
];

// ---------- Türkçe ondalık giriş ----------

/// Para/miktar alanlarının üst sınırı (numeric(18,2) taşmasına düşmeden,
/// ürün fiyatıyla aynı gerçekçi tavan).
const kMaxBudgetAmount = 999999999999.99;

/// Türkçe sayı girişi: "1.234.567,89", "1234,5", "1234.5", "12.50" kabul
/// edilir. Virgül ondalık ayırıcıdır; virgülsüz yazımda noktalar üçlü
/// gruplar hâlindeyse ("1.234", "1.250.000") binlik ayırıcı sayılır, değilse
/// ("12.5") ondalık nokta. [maxFractionDigits] aşılırsa hata döner.
/// Boş girdi `(value: null, error: null)` -- zorunluluk çağıranın kararı.
({double? value, String? error}) parseTrDecimal(
  String raw, {
  int maxFractionDigits = 2,
  bool allowNegative = false,
  double max = kMaxBudgetAmount,
}) {
  var s = raw.trim().replaceAll(' ', '').replaceAll(' ', '').replaceAll('−', '-');
  if (s.isEmpty) return (value: null, error: null);
  var negative = false;
  if (s.startsWith('-')) {
    if (!allowNegative) return (value: null, error: 'Negatif değer girilemez.');
    negative = true;
    s = s.substring(1);
  }
  String normalized;
  final grouped = RegExp(r'^\d{1,3}(\.\d{3})+(,\d+)?$');
  if (grouped.hasMatch(s)) {
    normalized = s.replaceAll('.', '').replaceAll(',', '.');
  } else if (RegExp(r'^\d+,\d+$').hasMatch(s) || RegExp(r'^\d+$').hasMatch(s)) {
    normalized = s.replaceAll(',', '.');
  } else if (RegExp(r'^\d+\.\d+$').hasMatch(s)) {
    normalized = s;
  } else {
    return (value: null, error: 'Geçerli bir sayı gir (ör. 1.250 veya 1250,50).');
  }
  final dot = normalized.indexOf('.');
  if (dot >= 0 && normalized.length - dot - 1 > maxFractionDigits) {
    return (value: null, error: 'En fazla $maxFractionDigits ondalık basamak girilebilir.');
  }
  final value = double.parse(normalized);
  if (value > max) return (value: null, error: 'Değer çok büyük.');
  return (value: negative ? -value : value, error: null);
}

/// Mevcut bir değeri form alanına yazmak için: gruplama YOK, ondalık virgül,
/// gereksiz sıfırlar atılır (1250000.5 -> "1250000,5", 12.0 -> "12").
String formatTrDecimalInput(double? value, {int maxFractionDigits = 2}) {
  if (value == null) return '';
  var text = value.toStringAsFixed(maxFractionDigits);
  if (text.contains('.')) {
    text = text.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  }
  return text.replaceAll('.', ',');
}

/// "YYYY-MM-DD" (taahhüt tarihi gövdesi).
String isoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
