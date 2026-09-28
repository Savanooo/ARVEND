import 'price_format.dart';
import 'price_source.dart';
import 'product.dart';

/// Zam Geçmişi -- backend `price_change_handler.go` yanıt tipleri ve web
/// `lib/price-changes.ts`'in saf yardımcılarının karşılığı. Uçlar:
/// GET /products/price-changes ve /price-changes/summary (products.read).

/// GET /products/price-changes satırı. Fiyatlar satış fiyatıdır.
class PriceChange {
  const PriceChange({
    required this.id,
    required this.productId,
    required this.productName,
    required this.unit,
    required this.category,
    required this.reason,
    required this.note,
    required this.oldPrice,
    required this.newPrice,
    required this.changeAmount,
    required this.changedAt,
    this.source,
    this.changePercent,
    this.oldSourcePrice,
    this.newSourcePrice,
  });

  final String id;
  final String productId;
  final String productName;
  final String unit;

  /// Ürünün ŞİMDİKİ kategorisi.
  final String category;

  /// Tedarikçi kodu; elle düzenlemede null.
  final String? source;
  final String reason;
  final String note;
  final double oldPrice;
  final double newPrice;
  final double changeAmount;

  /// 2 ondalık; eski fiyat 0 ise null.
  final double? changePercent;

  /// RFC3339Nano (mikrosaniye).
  final String changedAt;

  /// Tedarikçi fiyatları: products.manage yoksa ya da kaydedilmemişse null.
  final double? oldSourcePrice;
  final double? newSourcePrice;

  factory PriceChange.fromJson(Map<String, dynamic> json) => PriceChange(
    id: json['id'] as String? ?? '',
    productId: json['product_id'] as String? ?? '',
    productName: json['product_name'] as String? ?? '',
    unit: json['unit'] as String? ?? '',
    category: json['category'] as String? ?? '',
    source: _nonEmpty(json['source'] as String?),
    reason: json['reason'] as String? ?? '',
    note: json['note'] as String? ?? '',
    oldPrice: _double(json['old_price']),
    newPrice: _double(json['new_price']),
    changeAmount: _double(json['change_amount']),
    changePercent: (json['change_percent'] as num?)?.toDouble(),
    changedAt: json['changed_at'] as String? ?? '',
    oldSourcePrice: (json['old_source_price'] as num?)?.toDouble(),
    newSourcePrice: (json['new_source_price'] as num?)?.toDouble(),
  );
}

class PriceChangeList {
  const PriceChangeList({required this.changes, required this.total, required this.page, required this.limit});
  final List<PriceChange> changes;
  final int total;
  final int page;
  final int limit;

  factory PriceChangeList.fromJson(Map<String, dynamic> json) => PriceChangeList(
    changes: ((json['changes'] as List?) ?? const []).cast<Map<String, dynamic>>().map(PriceChange.fromJson).toList(),
    total: _int(json['total']),
    page: _int(json['page']),
    limit: _int(json['limit']),
  );
}

/// Özetin bir olayı: tek bir senkron ya da kâr oranı güncellemesi; elle
/// düzenlemeler İstanbul günü başına.
class PriceChangeEvent {
  const PriceChangeEvent({
    required this.changedAt,
    required this.from,
    required this.to,
    required this.reason,
    required this.changeCount,
    required this.increased,
    required this.decreased,
    this.source,
    this.avgChangePercent,
    this.maxIncreasePercent,
  });

  final String changedAt;

  /// Olayın satırlarını getirmek için liste ucuna AYNEN verilecek aralık
  /// (RFC3339Nano, ikisi de dahil) -- reason, source ve direction=all ile.
  final String from;
  final String to;
  final String? source;
  final String reason;
  final int changeCount;
  final int increased;
  final int decreased;
  final double? avgChangePercent;
  final double? maxIncreasePercent;

  factory PriceChangeEvent.fromJson(Map<String, dynamic> json) => PriceChangeEvent(
    changedAt: json['changed_at'] as String? ?? '',
    from: json['from'] as String? ?? '',
    to: json['to'] as String? ?? '',
    source: _nonEmpty(json['source'] as String?),
    reason: json['reason'] as String? ?? '',
    changeCount: _int(json['change_count']),
    increased: _int(json['increased']),
    decreased: _int(json['decreased']),
    avgChangePercent: (json['avg_change_percent'] as num?)?.toDouble(),
    maxIncreasePercent: (json['max_increase_percent'] as num?)?.toDouble(),
  );
}

class PriceChangeMaxIncrease {
  const PriceChangeMaxIncrease({required this.productId, required this.productName, required this.changePercent});
  final String productId;
  final String productName;
  final double changePercent;

  factory PriceChangeMaxIncrease.fromJson(Map<String, dynamic> json) => PriceChangeMaxIncrease(
    productId: json['product_id'] as String? ?? '',
    productName: json['product_name'] as String? ?? '',
    changePercent: _double(json['change_percent']),
  );
}

/// GET /products/price-changes/summary.
class PriceChangeSummary {
  const PriceChangeSummary({
    required this.increasedCount,
    required this.decreasedCount,
    required this.productsIncreased,
    required this.events,
    this.avgIncreasePercent,
    this.maxIncrease,
  });

  final int increasedCount;
  final int decreasedCount;

  /// Zam gelen TEKİL ürün sayısı.
  final int productsIncreased;
  final double? avgIncreasePercent;
  final PriceChangeMaxIncrease? maxIncrease;

  /// En yeni önce, en fazla [kMaxPriceChangeEvents].
  final List<PriceChangeEvent> events;

  factory PriceChangeSummary.fromJson(Map<String, dynamic> json) => PriceChangeSummary(
    increasedCount: _int(json['increased_count']),
    decreasedCount: _int(json['decreased_count']),
    productsIncreased: _int(json['products_increased']),
    avgIncreasePercent: (json['avg_increase_percent'] as num?)?.toDouble(),
    maxIncrease: json['max_increase'] == null
        ? null
        : PriceChangeMaxIncrease.fromJson(json['max_increase'] as Map<String, dynamic>),
    events: ((json['events'] as List?) ?? const []).cast<Map<String, dynamic>>().map(PriceChangeEvent.fromJson).toList(),
  );
}

String? _nonEmpty(String? s) => (s == null || s.isEmpty) ? null : s;
int _int(Object? v) => (v as num?)?.toInt() ?? 0;
double _double(Object? v) => (v as num?)?.toDouble() ?? 0;

/// Liste sayfa boyutu (backend en fazla 200).
const kPriceChangesPageSize = 50;

/// Backend en fazla bu kadar olay döner (maxPriceChangeEvents).
const kMaxPriceChangeEvents = 1000;

/// Backend: 100 karakterden uzun arama/kategori 400 döner.
const kMaxFilterText = 100;

// ---------- Dönem ----------

abstract final class PeriodKey {
  static const days7 = '7';
  static const days30 = '30';
  static const days90 = '90';
  static const year = 'yil';
  static const custom = 'ozel';
  static const values = [days7, days30, days90, year, custom];
}

const kDefaultPeriod = PeriodKey.days30;

const kPeriodOptions = <(String, String)>[
  (PeriodKey.days7, 'Son 7 gün'),
  (PeriodKey.days30, 'Son 30 gün'),
  (PeriodKey.days90, 'Son 90 gün'),
  (PeriodKey.year, 'Bu yıl'),
  (PeriodKey.custom, 'Özel aralık'),
];

class ResolvedPeriod {
  const ResolvedPeriod({required this.from, required this.to, required this.label, this.error});

  /// İstanbul günleri, ikisi de DAHİL (backend YYYY-AA-GG'yi böyle okur).
  final String from;
  final String to;
  final String label;

  /// Özel aralık geçersizse varsayılan döneme dönülür ve bu açıklama gösterilir.
  final String? error;
}

ResolvedPeriod _presetPeriod(String period, String today) {
  if (period == PeriodKey.year) {
    return ResolvedPeriod(from: '${today.substring(0, 4)}-01-01', to: today, label: 'Bu yıl');
  }
  final days = int.tryParse(period) ?? 30;
  // "Son 7 gün" = bugün + önceki 6 gün.
  return ResolvedPeriod(from: addDays(today, -(days - 1)), to: today, label: 'Son $days gün');
}

/// Seçili dönemin gün aralığı. today: İstanbul'un bugünü. Özel aralıkta
/// bitiş boşsa bugün kullanılır.
ResolvedPeriod resolvePeriod(ZamlarParams p, String today) {
  if (p.period != PeriodKey.custom) return _presetPeriod(p.period, today);
  final to = p.to.isEmpty ? today : p.to;
  final fallback = _presetPeriod(kDefaultPeriod, today);
  ResolvedPeriod withError(String e) => ResolvedPeriod(from: fallback.from, to: fallback.to, label: fallback.label, error: e);
  if (p.from.isEmpty) return withError('Özel aralık için başlangıç tarihi seç; son 30 gün gösteriliyor.');
  if (!isValidDay(p.from) || !isValidDay(to)) return withError('Tarih geçersiz; son 30 gün gösteriliyor.');
  if (p.from.compareTo(to) > 0) {
    return withError('Başlangıç tarihi bitiş tarihinden sonra olamaz; son 30 gün gösteriliyor.');
  }
  return ResolvedPeriod(from: p.from, to: to, label: 'Özel aralık');
}

// ---------- Filtreler ----------

abstract final class DirectionFilter {
  static const up = 'up';
  static const down = 'down';
  static const all = 'all';
}

const kDirectionOptions = <(String, String)>[
  (DirectionFilter.up, 'Zam'),
  (DirectionFilter.down, 'İndirim'),
  (DirectionFilter.all, 'Tümü'),
];

/// "all" dahil neden filtresi.
const kReasonAll = 'all';

const kReasonOptions = <(String, String)>[
  (PriceChangeReason.supplier, 'Tedarikçi fiyatı'),
  (PriceChangeReason.markup, 'Kâr oranı'),
  (PriceChangeReason.manual, 'Elle düzenleme'),
  (kReasonAll, 'Tümü'),
];

abstract final class SortKey {
  static const newest = 'newest';
  static const largestIncrease = 'largest_increase';
  static const largestDecrease = 'largest_decrease';
}

const kSortOptions = <(String, String)>[
  (SortKey.newest, 'En yeni'),
  (SortKey.largestIncrease, 'En yüksek zam'),
  (SortKey.largestDecrease, 'En yüksek indirim'),
];

String _labelOf(List<(String, String)> options, String value) {
  for (final o in options) {
    if (o.$1 == value) return o.$2;
  }
  return value;
}

String directionLabel(String v) => _labelOf(kDirectionOptions, v);
String reasonOptionLabel(String v) => _labelOf(kReasonOptions, v);
String sortLabel(String v) => _labelOf(kSortOptions, v);

/// Özetteki bir olayın satırları: liste bu kapsamda olayın from/to, reason
/// ve source'unu kullanır (backend sözleşmesi); dönem, kaynak ve neden
/// seçimleri özet ile zaman çizelgesi için geçerli kalır.
class EventScope {
  const EventScope({required this.from, required this.to, required this.reason, required this.source});
  final String from;
  final String to;
  final String reason;

  /// "" = kaynağı olmayan olay (elle düzenleme).
  final String source;

  @override
  bool operator ==(Object other) =>
      other is EventScope && other.from == from && other.to == to && other.reason == reason && other.source == source;

  @override
  int get hashCode => Object.hash(from, to, reason, source);
}

/// Zam Geçmişi ekranının durumu -- web ZamlarParams'ın karşılığı (sayfa
/// numarası yok: mobilde liste "daha fazla" ile sayfa sayfa büyür).
class ZamlarParams {
  const ZamlarParams({
    this.period = kDefaultPeriod,
    this.from = '',
    this.to = '',
    this.source = '',
    this.reason = PriceChangeReason.supplier,
    this.direction = DirectionFilter.up,
    this.category = '',
    this.q = '',
    this.sort = SortKey.newest,
    this.event,
  });

  final String period;

  /// Yalnızca period "ozel" iken (YYYY-AA-GG).
  final String from;
  final String to;

  /// Özet, zaman çizelgesi ve liste için; "" = tüm kaynaklar.
  final String source;
  final String reason;

  /// Yalnızca liste için.
  final String direction;
  final String category;
  final String q;
  final String sort;
  final EventScope? event;

  static const defaults = ZamlarParams();

  ZamlarParams copyWith({
    String? period,
    String? from,
    String? to,
    String? source,
    String? reason,
    String? direction,
    String? category,
    String? q,
    String? sort,
    EventScope? event,
    bool clearEvent = false,
  }) => ZamlarParams(
    period: period ?? this.period,
    from: from ?? this.from,
    to: to ?? this.to,
    source: source ?? this.source,
    reason: reason ?? this.reason,
    direction: direction ?? this.direction,
    category: category ?? this.category,
    q: q ?? this.q,
    sort: sort ?? this.sort,
    event: clearEvent ? null : (event ?? this.event),
  );

  /// Varsayılandan farklı liste filtresi sayısı (Filtrele düğmesinin rozeti).
  /// Olay seçimi yönü kendiliğinden "tümü" yapar (bkz. selectEvent); bu,
  /// kullanıcının seçtiği bir filtre sayılmaz -- olay kutusu zaten görünür.
  int get activeFilterCount => [
    source.isNotEmpty,
    reason != defaults.reason,
    direction != defaults.direction && !(event != null && direction == DirectionFilter.all),
    category.isNotEmpty,
    q.isNotEmpty,
    sort != defaults.sort,
  ].where((b) => b).length;

  /// Rota sorgusu (web URL parametreleriyle aynı adlar); varsayılanlar yazılmaz.
  Map<String, String> toQuery() {
    const d = defaults;
    return {
      if (period != d.period) 'period': period,
      if (period == PeriodKey.custom && from.isNotEmpty) 'from': from,
      if (period == PeriodKey.custom && to.isNotEmpty) 'to': to,
      if (source.isNotEmpty) 'source': source,
      if (reason != d.reason) 'reason': reason,
      if (direction != d.direction) 'direction': direction,
      if (category.isNotEmpty) 'category': category,
      if (q.isNotEmpty) 'q': q,
      if (sort != d.sort) 'sort': sort,
      if (event != null) ...{
        'event_from': event!.from,
        'event_to': event!.to,
        'event_reason': event!.reason,
        if (event!.source.isNotEmpty) 'event_source': event!.source,
      },
    };
  }

  /// Rota sorgusunu okur; bilinmeyen/bozuk değerler varsayılana döner.
  factory ZamlarParams.fromQuery(Map<String, String> sp) {
    String first(String k) => (sp[k] ?? '').trim();
    String oneOf(String value, List<String> allowed, String fallback) => allowed.contains(value) ? value : fallback;
    final period = oneOf(first('period'), PeriodKey.values, kDefaultPeriod);
    final eventFrom = first('event_from');
    final eventTo = first('event_to');
    final eventReason = first('event_reason');
    final event = rfc3339Re.hasMatch(eventFrom) && rfc3339Re.hasMatch(eventTo) && PriceChangeReason.values.contains(eventReason)
        ? EventScope(from: eventFrom, to: eventTo, reason: eventReason, source: _parseSource(first('event_source')))
        : null;
    return ZamlarParams(
      period: period,
      from: period == PeriodKey.custom ? first('from') : '',
      to: period == PeriodKey.custom ? first('to') : '',
      source: _parseSource(first('source')),
      reason: oneOf(first('reason'), [...PriceChangeReason.values, kReasonAll], defaults.reason),
      direction: oneOf(first('direction'), [DirectionFilter.up, DirectionFilter.down, DirectionFilter.all], defaults.direction),
      category: cleanFilterText(first('category')),
      q: cleanFilterText(first('q')),
      sort: oneOf(first('sort'), [SortKey.newest, SortKey.largestIncrease, SortKey.largestDecrease], defaults.sort),
      event: event,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ZamlarParams &&
      other.period == period &&
      other.from == from &&
      other.to == to &&
      other.source == source &&
      other.reason == reason &&
      other.direction == direction &&
      other.category == category &&
      other.q == q &&
      other.sort == sort &&
      other.event == event;

  @override
  int get hashCode => Object.hash(period, from, to, source, reason, direction, category, q, sort, event);
}

/// Kaynak kodu biçimi; hangi kodların geçerli olduğuna backend karar verir.
final _sourceCodeRe = RegExp(r'^[a-z][a-z0-9_]{0,31}$');

String _parseSource(String raw) => _sourceCodeRe.hasMatch(raw) ? raw : '';

/// Gruplar: saniyeye kadar tarih-saat, kesirli saniye, saat dilimi.
final rfc3339Re = RegExp(r'^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(\.\d{1,9})?(Z|[+-]\d{2}:\d{2})$');

/// RFC3339(Nano) -> Unix mikrosaniye; bozuksa null (Dart DateTime ilk 6
/// kesirli basamağı okur -- olay aralıkları mikrosaniye hassasiyetindedir).
int? _toMicros(String iso) {
  if (!rfc3339Re.hasMatch(iso)) return null;
  return DateTime.tryParse(iso)?.microsecondsSinceEpoch;
}

/// Arama/kategori metni: NUL baytı ve 100 karakterden uzunu backend'de 400.
String cleanFilterText(String raw) {
  final s = raw.replaceAll('\u0000', '').trim();
  final runes = s.runes.toList();
  return runes.length > kMaxFilterText ? String.fromCharCodes(runes.take(kMaxFilterText)).trim() : s;
}

/// Liste ucunun sorgu anahtarı (sayfa hariç -- sayfalar sağlayıcıda birikir).
typedef PriceChangesQuery = ({
  String from,
  String to,
  String reason,
  String source,
  String direction,
  String category,
  String q,
  String sort,
});

/// Özet ucunun sorgu anahtarı: dönem + kaynak + neden.
typedef PriceChangeSummaryQuery = ({String from, String to, String reason, String source});

/// Liste sorgusu. Olay seçiliyse aralık, neden ve kaynak olayınkidir.
PriceChangesQuery listQueryOf(ZamlarParams p, ResolvedPeriod range) {
  final scope = p.event ?? EventScope(from: range.from, to: range.to, reason: p.reason, source: p.source);
  return (
    from: scope.from,
    to: scope.to,
    reason: scope.reason,
    source: scope.source,
    direction: p.direction,
    category: p.category,
    q: p.q,
    sort: p.sort,
  );
}

PriceChangeSummaryQuery summaryQueryOf(ZamlarParams p, ResolvedPeriod range) =>
    (from: range.from, to: range.to, reason: p.reason, source: p.source);

Map<String, String> priceChangesQueryParams(PriceChangesQuery q, {required int page, required int limit}) => {
  'from': q.from,
  'to': q.to,
  'reason': q.reason,
  if (q.source.isNotEmpty) 'source': q.source,
  'direction': q.direction,
  if (q.category.isNotEmpty) 'category': q.category,
  if (q.q.isNotEmpty) 'q': q.q,
  'sort': q.sort,
  'page': '$page',
  'limit': '$limit',
};

Map<String, String> summaryQueryParams(PriceChangeSummaryQuery q) => {
  'from': q.from,
  'to': q.to,
  'reason': q.reason,
  if (q.source.isNotEmpty) 'source': q.source,
};

EventScope eventScopeOf(PriceChangeEvent ev) =>
    EventScope(from: ev.from, to: ev.to, reason: ev.reason, source: ev.source ?? '');

/// Zaman çizelgesindeki olay, listede seçili kapsamın içinde mi (aynı neden
/// ve kaynak, aralığı kapsamın içinde)?
bool isSelectedEvent(EventScope? scope, PriceChangeEvent ev) {
  if (scope == null) return false;
  final other = eventScopeOf(ev);
  if (scope.reason != other.reason || scope.source != other.source) return false;
  final sf = _toMicros(scope.from), st = _toMicros(scope.to), of = _toMicros(other.from), ot = _toMicros(other.to);
  if (sf == null || st == null || of == null || ot == null) return false;
  return sf <= of && ot <= st;
}

/// Bir olaya dokunulunca: liste olayın TÜM satırlarını gösterir (yön
/// "tümü", kategori/arama temizlenir); dönem, kaynak, neden ve sıralama
/// korunur.
ZamlarParams selectEvent(ZamlarParams p, PriceChangeEvent ev) =>
    p.copyWith(event: eventScopeOf(ev), direction: DirectionFilter.all, category: '', q: '');

/// Olay kapsamını kaldırır; yön varsayılana (zam) döner.
ZamlarParams clearEvent(ZamlarParams p) => p.copyWith(clearEvent: true, direction: ZamlarParams.defaults.direction);

/// Dönem değişimi: filtreler korunur, olay sıfırlanır (olayın koyduğu
/// "tümü" yönü de varsayılana döner). Özel aralık verilen günlerle başlar.
ZamlarParams changePeriod(ZamlarParams p, String period, {String from = '', String to = ''}) {
  final custom = period == PeriodKey.custom;
  return p.copyWith(
    period: period,
    from: custom ? from : '',
    to: custom ? to : '',
    direction: p.event != null ? ZamlarParams.defaults.direction : p.direction,
    clearEvent: true,
  );
}

/// Filtre formundan yeni parametreler. Seçili olay, özetin bağlamı (kaynak,
/// neden) değişmedikçe korunur -- yön, kategori, arama ve sıralama olayın
/// satırları içinde uygulanır.
ZamlarParams applyFilters(
  ZamlarParams p, {
  required String source,
  required String reason,
  required String direction,
  required String category,
  required String q,
  required String sort,
}) {
  final sameContext = source == p.source && reason == p.reason;
  return ZamlarParams(
    period: p.period,
    from: p.from,
    to: p.to,
    source: source,
    reason: reason,
    direction: direction,
    category: cleanFilterText(category),
    q: cleanFilterText(q),
    sort: sort,
    event: sameContext ? p.event : null,
  );
}

/// Bir senkronun tedarikçi satırları: backend last_synced_at'i saniyeye
/// kırparak döndürür, satırlar ise mikrosaniyeli yazılır -- kapsam o
/// saniyenin tamamıdır. Zaman bozuksa null.
EventScope? syncEventScope(String source, String syncedAt) {
  final m = rfc3339Re.firstMatch(syncedAt);
  if (m == null || _toMicros(syncedAt) == null) return null;
  if (m.group(2) != null) {
    return EventScope(from: syncedAt, to: syncedAt, reason: PriceChangeReason.supplier, source: source);
  }
  return EventScope(
    from: '${m.group(1)}${m.group(3)}',
    to: '${m.group(1)}.999999${m.group(3)}',
    reason: PriceChangeReason.supplier,
    source: source,
  );
}

/// Fiyat kaynağı kartındaki "Zam Geçmişi" bağlantısı (web
/// sourceHistoryHref): dönem son başarılı senkronu kapsar; senkron fiyat
/// değiştirdiyse liste doğrudan o senkronun satırlarını gösterir.
ZamlarParams sourceHistoryParams(PriceSource ps, String today) {
  final base = ZamlarParams(source: ps.source);
  final scope = ps.lastSyncedAt == null ? null : syncEventScope(ps.source, ps.lastSyncedAt!);
  if (scope == null) return base;
  final syncDay = istanbulDay(DateTime.parse(scope.from));
  final inDefault = syncDay.compareTo(_presetPeriod(kDefaultPeriod, today).from) >= 0;
  final period = inDefault ? base : base.copyWith(period: PeriodKey.custom, from: syncDay, to: '');
  final lc = ps.lastChanges;
  if (lc == null || lc.increased + lc.decreased == 0) return period;
  return period.copyWith(direction: DirectionFilter.all, event: scope);
}

// ---------- Görüntüleme ----------

enum ChangeTone { up, down, flat }

/// Fiyat artışı (zam) "up", düşüş (indirim) "down".
ChangeTone changeTone(double oldPrice, double newPrice) {
  if (newPrice > oldPrice) return ChangeTone.up;
  if (newPrice < oldPrice) return ChangeTone.down;
  return ChangeTone.flat;
}

ChangeTone _toneOfPercent(double? pct) =>
    pct == null || pct == 0 ? ChangeTone.flat : (pct > 0 ? ChangeTone.up : ChangeTone.down);

/// "↑ %3,25" / "↓ %2,1" / "%0"; yüzde tanımsızsa (eski fiyat 0) "—". Ok
/// fiyatın yönünden gelir: %0'a yuvarlanan zam "↑ <%0,01" yazılır.
String formatChangePercent(double? pct, [ChangeTone? tone]) {
  if (pct == null) return '—';
  final t = tone ?? _toneOfPercent(pct);
  final abs = pct.abs();
  final value = t != ChangeTone.flat && (abs * 100).round() == 0 ? '<${formatPricePercent(0.01)}' : formatPricePercent(abs);
  return switch (t) {
    ChangeTone.up => '↑ $value',
    ChangeTone.down => '↓ $value',
    ChangeTone.flat => value,
  };
}

/// Zaman çizelgesindeki ortalama değişimin yönü.
ChangeTone eventAvgTone(PriceChangeEvent ev) {
  final avg = ev.avgChangePercent;
  if (avg != null && avg != 0) return avg > 0 ? ChangeTone.up : ChangeTone.down;
  if (ev.increased > 0 && ev.decreased == 0) return ChangeTone.up;
  if (ev.decreased > 0 && ev.increased == 0) return ChangeTone.down;
  return ChangeTone.flat;
}

/// (yeni - eski) / eski × 100, 2 ondalığa sıfırdan uzağa yuvarlanmış --
/// backend changePercent ile aynı; eski fiyat 0 ise null.
double? changePercentOf(double oldPrice, double newPrice) {
  final oldCents = (oldPrice * 100).round();
  if (oldCents <= 0) return null;
  final diff = (newPrice * 100).round() - oldCents;
  final bp = diff.sign * ((diff.abs() * 10000 * 2 + oldCents) ~/ (2 * oldCents));
  return bp / 100;
}

/// Satırın nedeni: "Tedarikçi zammı" / "Tedarikçi indirimi" / "Kâr oranı" / "Elle".
String reasonLabel(String reason, double oldPrice, double newPrice) {
  switch (reason) {
    case PriceChangeReason.supplier:
      return switch (changeTone(oldPrice, newPrice)) {
        ChangeTone.up => 'Tedarikçi zammı',
        ChangeTone.down => 'Tedarikçi indirimi',
        ChangeTone.flat => 'Tedarikçi fiyatı',
      };
    case PriceChangeReason.markup:
      return 'Kâr oranı';
    case PriceChangeReason.manual:
      return 'Elle';
    default:
      return reason;
  }
}

/// Zaman çizelgesindeki olayın türü.
String eventReasonLabel(String reason) => switch (reason) {
  PriceChangeReason.supplier => 'Tedarikçi fiyat listesi',
  PriceChangeReason.markup => 'Kâr oranı güncellemesi',
  PriceChangeReason.manual => 'Elle düzenleme',
  _ => reason,
};

/// Özet kartlarının bağlamı: neden filtresinin açıklaması.
String reasonFilterLabel(String reason) => switch (reason) {
  PriceChangeReason.supplier => 'Tedarikçi fiyatı değişiklikleri',
  PriceChangeReason.markup => 'Kâr oranı değişiklikleri',
  PriceChangeReason.manual => 'Elle düzenlemeler',
  _ => 'Tüm fiyat değişiklikleri',
};

/// Olayın zamanı: senkron/kâr oranı olayı bir andır ("27 Eylül 2026
/// 00:05"); elle düzenlemeler gün başına, yalnızca gün yazılır.
String eventTimeLabel(PriceChangeEvent ev) =>
    ev.reason == PriceChangeReason.manual ? formatInstantDay(ev.changedAt) : formatSyncTime(ev.changedAt);

/// Seçili olayın başlığı: "27 Eylül 2026 00:05 · Demir Profil · Tedarikçi fiyat listesi".
String eventScopeLabel(EventScope scope) {
  final when = scope.reason == PriceChangeReason.manual ? formatInstantDay(scope.from) : formatSyncTime(scope.from);
  return [
    when,
    if (scope.source.isNotEmpty) sourceLabels(scope.source).short,
    eventReasonLabel(scope.reason),
  ].join(' · ');
}

/// "120 ürüne zam · 5 ürüne indirim" (elle düzenleme gününde değişiklik sayılır).
String eventCountsText(PriceChangeEvent ev) {
  final manual = ev.reason == PriceChangeReason.manual;
  final parts = [
    if (ev.increased > 0) manual ? '${ev.increased} fiyat artışı' : '${ev.increased} ürüne zam',
    if (ev.decreased > 0) manual ? '${ev.decreased} fiyat düşüşü' : '${ev.decreased} ürüne indirim',
  ];
  if (parts.isEmpty) parts.add('${ev.changeCount} değişiklik');
  return parts.join(' · ');
}

/// Liste başlığı yöne göre.
String changesTitle(String direction) => switch (direction) {
  DirectionFilter.down => 'İndirim Gelen Ürünler',
  DirectionFilter.all => 'Fiyatı Değişen Ürünler',
  _ => 'Zam Gelen Ürünler',
};

/// Boş liste metni.
String changesEmptyText(String direction) => switch (direction) {
  DirectionFilter.up => 'Bu filtrelerle zam gelen ürün yok.',
  DirectionFilter.down => 'Bu filtrelerle indirim gelen ürün yok.',
  _ => 'Bu filtrelerle fiyatı değişen ürün yok.',
};

/// Tedarikçi fiyatı bu satırda gösterilsin mi? Backend bunları yalnızca
/// products.manage sahibine döndürür; elle düzenlemelerde kayıt yoktur.
bool hasSourcePrices(double? oldSourcePrice, double? newSourcePrice) => oldSourcePrice != null && newSourcePrice != null;
