import 'package:intl/intl.dart';

import 'price_format.dart';
import 'product.dart';

/// Tedarikçi fiyat kaynakları (Ulaş, Demir Profil) -- backend
/// `price_source_handler.go` yanıt tipleri ve web `lib/price-sources.ts`'in
/// saf yardımcılarının BİREBİR karşılığı (aynı metinler, aynı kurallar).

const kUlasSource = 'ulas';
const kDemirProfilSource = 'demirprofil';

/// GET /price-sources başarısız olursa da seçeneklerde görünen kaynaklar
/// (backend kayıt defterindeki sırayla).
const kKnownPriceSources = [kUlasSource, kDemirProfilSource];

/// Son bir senkronun sayıları: total = listedeki tekil ürün = created +
/// updated + unchanged; missing = firmanın listede artık bulunmayan
/// (SİLİNMEYEN) kaynak ürünleri.
class PriceSyncCounts {
  const PriceSyncCounts({
    required this.total,
    required this.created,
    required this.updated,
    required this.unchanged,
    required this.missing,
  });

  final int total;
  final int created;
  final int updated;
  final int unchanged;
  final int missing;

  static const zero = PriceSyncCounts(total: 0, created: 0, updated: 0, unchanged: 0, missing: 0);

  factory PriceSyncCounts.fromJson(Map<String, dynamic>? json) => json == null
      ? zero
      : PriceSyncCounts(
          total: _int(json['total']),
          created: _int(json['created']),
          updated: _int(json['updated']),
          unchanged: _int(json['unchanged']),
          missing: _int(json['missing']),
        );
}

class PriceSourceCategoryMarkup {
  const PriceSourceCategoryMarkup({required this.category, required this.markupPercent});
  final String category;
  final double markupPercent;

  factory PriceSourceCategoryMarkup.fromJson(Map<String, dynamic> json) => PriceSourceCategoryMarkup(
    category: json['category'] as String? ?? '',
    markupPercent: (json['markup_percent'] as num?)?.toDouble() ?? 0,
  );

  Map<String, dynamic> toJson() => {'category': category, 'markup_percent': markupPercent};
}

class PriceSourceCategory {
  const PriceSourceCategory({required this.category, required this.productCount});
  final String category;
  final int productCount;

  factory PriceSourceCategory.fromJson(Map<String, dynamic> json) =>
      PriceSourceCategory(category: json['category'] as String? ?? '', productCount: _int(json['product_count']));
}

/// Son başarılı senkronda satış fiyatı artan/azalan ürünler;
/// avgIncreasePercent artış yoksa null.
class PriceSyncChanges {
  const PriceSyncChanges({required this.increased, required this.decreased, this.avgIncreasePercent});
  final int increased;
  final int decreased;
  final double? avgIncreasePercent;

  factory PriceSyncChanges.fromJson(Map<String, dynamic> json) => PriceSyncChanges(
    increased: _int(json['increased']),
    decreased: _int(json['decreased']),
    avgIncreasePercent: (json['avg_increase_percent'] as num?)?.toDouble(),
  );
}

abstract final class PriceSyncStatus {
  static const never = 'never';
  static const success = 'success';
  static const failed = 'failed';
}

/// GET /products/price-sources -> `{sources: [...]}` -- her zaman iki
/// kaynak, bu sırayla: "ulas", "demirprofil".
class PriceSource {
  const PriceSource({
    required this.source,
    required this.name,
    required this.siteUrl,
    required this.vatNote,
    required this.listLabel,
    required this.attribution,
    required this.autoSync,
    required this.lastStatus,
    required this.lastError,
    required this.lastResult,
    required this.categories,
    required this.productCount,
    required this.missingCount,
    this.markupPercent,
    this.categoryMarkups,
    this.lastSyncedAt,
    this.updatedAt,
    this.lastChanges,
  });

  final String source;

  /// Tam ad ("Demir Profil (Omega Çelik)"); kısa ad için bkz. [sourceLabels].
  final String name;
  final String siteUrl;

  /// Listedeki fiyatların KDV/kapsam esası.
  final String vatNote;

  /// Son başarılı senkronun liste dönemi ("Eylül 2026"; Ulaş'ta "").
  final String listLabel;

  /// Kaynak gösterimi zorunluysa gösterilecek metin ("Kaynak:
  /// demirprofil.com.tr — Eylül 2026 listesi"); zorunlu değilse "".
  final String attribution;

  /// products.manage yoksa ikisi de null (oranı görmek maliyeti görmektir).
  final double? markupPercent;
  final List<PriceSourceCategoryMarkup>? categoryMarkups;
  final bool autoSync;

  /// Son BAŞARILI senkron (RFC3339); başarısız denemede değişmez.
  final String? lastSyncedAt;
  final String lastStatus;

  /// Son başarısız denemenin kısa, sabit Türkçe açıklaması.
  final String lastError;

  /// Son BAŞARILI senkronun sayıları.
  final PriceSyncCounts lastResult;
  final List<PriceSourceCategory> categories;
  final int productCount;
  final int missingCount;
  final String? updatedAt;

  /// Hiç başarılı senkron yoksa null.
  final PriceSyncChanges? lastChanges;

  factory PriceSource.fromJson(Map<String, dynamic> json) => PriceSource(
    source: json['source'] as String? ?? '',
    name: json['name'] as String? ?? '',
    siteUrl: json['site_url'] as String? ?? '',
    vatNote: json['vat_note'] as String? ?? '',
    listLabel: json['list_label'] as String? ?? '',
    attribution: json['attribution'] as String? ?? '',
    markupPercent: (json['markup_percent'] as num?)?.toDouble(),
    categoryMarkups: (json['category_markups'] as List?)
        ?.cast<Map<String, dynamic>>()
        .map(PriceSourceCategoryMarkup.fromJson)
        .toList(),
    autoSync: json['auto_sync'] as bool? ?? false,
    lastSyncedAt: json['last_synced_at'] as String?,
    lastStatus: json['last_status'] as String? ?? PriceSyncStatus.never,
    lastError: json['last_error'] as String? ?? '',
    lastResult: PriceSyncCounts.fromJson(json['last_result'] as Map<String, dynamic>?),
    categories: ((json['categories'] as List?) ?? const [])
        .cast<Map<String, dynamic>>()
        .map(PriceSourceCategory.fromJson)
        .toList(),
    productCount: _int(json['product_count']),
    missingCount: _int(json['missing_count']),
    updatedAt: json['updated_at'] as String?,
    lastChanges: json['last_changes'] == null
        ? null
        : PriceSyncChanges.fromJson(json['last_changes'] as Map<String, dynamic>),
  );
}

/// POST /products/price-sources/{source}/sync yanıtı.
class PriceSyncResult {
  const PriceSyncResult({
    required this.source,
    required this.counts,
    required this.syncedAt,
    required this.listLabel,
  });

  final String source;
  final PriceSyncCounts counts;
  final String syncedAt;

  /// İndirilen listenin dönemi ("Eylül 2026"; Ulaş'ta "").
  final String listLabel;

  factory PriceSyncResult.fromJson(Map<String, dynamic> json) => PriceSyncResult(
    source: json['source'] as String? ?? '',
    counts: PriceSyncCounts.fromJson(json),
    syncedAt: json['synced_at'] as String? ?? '',
    listLabel: json['list_label'] as String? ?? '',
  );
}

/// PUT /products/price-sources/{source} yanıtı. recomputed = yeni oranlarla
/// satış fiyatı DEĞİŞEN ürün sayısı.
class PriceSourceUpdateResult {
  const PriceSourceUpdateResult({required this.priceSource, required this.recomputed});
  final PriceSource priceSource;
  final int recomputed;

  factory PriceSourceUpdateResult.fromJson(Map<String, dynamic> json) => PriceSourceUpdateResult(
    priceSource: PriceSource.fromJson(json['price_source'] as Map<String, dynamic>),
    recomputed: _int(json['recomputed']),
  );
}

int _int(Object? v) => (v as num?)?.toInt() ?? 0;

// ---------- Adlar ----------

/// Bir kaynağın metinlerde kullanılan adları. Türkçe ek ünlü uyumuna ve son
/// sese bağlıdır ("Ulaş'tan", "Demir Profil'den"), bu yüzden bilinen
/// kaynaklar için elle yazılır.
class SourceLabels {
  const SourceLabels({required this.short, required this.ablative, required this.dative});

  /// Rozet ve cümle içi kısa ad ("Demir Profil").
  final String short;

  /// Ayrılma hâli: "Ulaş'tan Güncelle".
  final String ablative;

  /// Yönelme hâli: "Ulaş'a ulaşılamadı".
  final String dative;
}

const _knownSourceLabels = {
  kUlasSource: SourceLabels(short: 'Ulaş', ablative: "Ulaş'tan", dative: "Ulaş'a"),
  kDemirProfilSource: SourceLabels(short: 'Demir Profil', ablative: "Demir Profil'den", dative: "Demir Profil'e"),
};

/// Kaynağın adları. Backend'e sonradan eklenen, burada tanımı olmayan bir
/// kaynakta ek uyumu tahmin edilmez: "X kaynağından" kalıbı kullanılır.
SourceLabels sourceLabels(String source, [String? apiName]) {
  final known = _knownSourceLabels[source];
  if (known != null) return known;
  final name = (apiName != null && apiName.isNotEmpty) ? apiName : (source.isNotEmpty ? source : 'Tedarikçi');
  return SourceLabels(short: name, ablative: '$name kaynağından', dative: '$name kaynağına');
}

/// "https://www.demirprofil.com.tr" -> "demirprofil.com.tr".
String siteHost(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.host.isEmpty) return url;
  return uri.host.replaceFirst(RegExp(r'^www\.'), '');
}

/// Kaynağın sitesi yalnızca https ise bağlantı olur (adres backend'in sabit
/// kayıt defterinden gelir; yine de).
bool isSafeSiteUrl(String url) => url.startsWith('https://');

/// GET /price-sources alınamadığında Demir Profil'in kaynak gösterimi.
const kDemirProfilFallbackAttribution = 'Kaynak: demirprofil.com.tr';

/// Kaynağın zorunlu kaynak gösterimi (Demir Profil'in kullanım koşulu kaynak
/// ve liste ayının belirtilmesini istiyor); zorunlu değilse "". Kaynak
/// bilgisi alınamadıysa Demir Profil fiyatları yine kaynaksız kalmasın.
String sourceAttribution(String source, PriceSource? ps) {
  if (ps != null) return ps.attribution;
  return source == kDemirProfilSource ? kDemirProfilFallbackAttribution : '';
}

/// Bir ekranda fiyatı gösterilen kaynakların kaynak gösterimleri (tekrarsız,
/// boşlar atılır). sources: GET /price-sources yanıtı; alınamadıysa null.
List<String> attributionsFor(Iterable<String?> codes, List<PriceSource>? sources) {
  final out = <String>{};
  for (final code in codes) {
    if (code == null || code.isEmpty) continue;
    final text = sourceAttribution(code, findPriceSource(sources, code));
    if (text.isNotEmpty) out.add(text);
  }
  return out.toList();
}

PriceSource? findPriceSource(List<PriceSource>? sources, String code) {
  if (sources == null || code.isEmpty) return null;
  for (final s in sources) {
    if (s.source == code) return s;
  }
  return null;
}

/// Ürün, kaynağın son BAŞARILI senkronunda listede görülmedi mi? Backend
/// missing_count kuralıyla aynı: hiç başarılı senkron yoksa hiçbir ürün
/// "listede yok" sayılmaz.
bool isMissingFromSource(Product product, PriceSource? ps) {
  final lastSynced = ps?.lastSyncedAt;
  if (ps == null || lastSynced == null || product.source != ps.source) return false;
  final seen = product.sourceSyncedAt == null ? null : DateTime.tryParse(product.sourceSyncedAt!);
  if (seen == null) return true;
  final last = DateTime.tryParse(lastSynced);
  if (last == null) return false;
  return seen.isBefore(last);
}

/// Ürünün tedarikçi listesiyle bağı (web EditProductForm `sourceLink`):
/// - linked: kaynak ürünü, son listede var (ya da henüz hiç senkron yok);
///   backend kaynak satırlarını (ad, birim) ile eşleştirdiğinden bu iki
///   alan KİLİTLİDİR.
/// - missing: kaynak ürünü ama son listede yok -- ad/birim düzenlenebilir.
/// - none: elle eklenen ürün.
enum ProductSourceLink { none, linked, missing }

ProductSourceLink sourceLinkOf(Product product, PriceSource? ps) {
  if (product.isManual) return ProductSourceLink.none;
  // Fiyat kaynağı alınamadıysa missing=false: kilit güvenli tarafta kalır.
  return isMissingFromSource(product, ps) ? ProductSourceLink.missing : ProductSourceLink.linked;
}

// ---------- Kâr oranı ----------

/// backend domain.MaxPriceSourceMarkup ile aynı.
const kMaxMarkupPercent = 1000;

/// Ayar formundaki örnek hesabın tedarikçi fiyatı.
const kExampleSourcePrice = 500.0;

class MarkupParse {
  const MarkupParse.ok(double this.value) : error = null;
  const MarkupParse.fail(String this.error) : value = null;
  final double? value;
  final String? error;
  bool get ok => value != null;
}

/// Kullanıcının yazdığı kâr oranını okur: "15", "12,5" (Türkçe ondalık
/// virgül), "12.5", "%15" kabul edilir. 0-1000 arası, en fazla iki
/// ondalık. Binlik ayırıcı KABUL EDİLMEZ ("1.000" üç ondalıklı sayı sayılıp
/// reddedilir) -- web parseMarkupInput ile aynı kural.
MarkupParse parseMarkupInput(String raw) {
  final s = raw.trim().replaceFirst(RegExp(r'^%\s*'), '').replaceFirst(RegExp(r'\s*%$'), '');
  if (s.isEmpty) return const MarkupParse.fail('Kâr oranı gir.');
  if (s.startsWith('-')) return const MarkupParse.fail('Kâr oranı 0 ile $kMaxMarkupPercent arasında olmalı.');
  final m = RegExp(r'^(\d+)(?:[.,](\d+))?$').firstMatch(s);
  if (m == null) return const MarkupParse.fail('Geçerli bir sayı gir (ör. 15 veya 12,5).');
  if ((m.group(2) ?? '').length > 2) {
    return const MarkupParse.fail('En fazla iki ondalık basamak girilebilir (binlik ayırıcı kullanma).');
  }
  final value = double.parse(s.replaceFirst(',', '.'));
  if (!value.isFinite || value > kMaxMarkupPercent) {
    return const MarkupParse.fail('Kâr oranı 0 ile $kMaxMarkupPercent arasında olmalı.');
  }
  return MarkupParse.ok(value);
}

final _markupInputFormat = NumberFormat.decimalPattern('tr_TR')
  ..minimumFractionDigits = 0
  ..maximumFractionDigits = 2
  ..turnOffGrouping();

/// Oranı forma yazılacak biçimde döndürür: 15 -> "15", 12.5 -> "12,5".
String formatMarkupInput(double value) => _markupInputFormat.format(value);

/// Satış fiyatı = tedarikçi fiyatı × (1 + oran/100), 2 ondalığa yarım
/// yukarı -- backend domain.ApplyMarkup ile aynı sonuç. Float hatası olmasın
/// diye kuruş ve baz puan tamsayılarıyla hesaplanır (500 × 1,15 float'ta
/// 574,999…'dur).
double applyMarkup(double sourcePrice, double markupPercent) {
  final cents = (sourcePrice * 100).round();
  final basisPoints = (markupPercent * 100).round();
  final scaled = cents * (10000 + basisPoints);
  return ((scaled + 5000) ~/ 10000) / 100;
}

// ---------- Mesajlar ----------

/// "toplam 628 · 3 yeni · 12 güncellenen · 613 değişmeyen · 0 listede artık yok"
String summarizeSyncCounts(PriceSyncCounts c) => [
  'toplam ${c.total}',
  '${c.created} yeni',
  '${c.updated} güncellenen',
  '${c.unchanged} değişmeyen',
  '${c.missing} listede artık yok',
].join(' · ');

/// "Demir Profil listesi (Eylül 2026) güncellendi: toplam … ."
String syncSuccessMessage(PriceSyncResult res, SourceLabels labels) {
  final period = res.listLabel.isNotEmpty ? ' (${res.listLabel})' : '';
  return '${labels.short} listesi$period güncellendi: ${summarizeSyncCounts(res.counts)}.';
}

/// backend domain.ErrPriceListTooShort -- 502 ama kaynağa ulaşılamamış
/// değil; sayılar kartın last_error'ında görünür.
const kPriceListTooShortError = 'tedarikçi fiyat listesi beklenenden çok kısa geldi; fiyatlar değiştirilmedi';

/// Senkron (POST .../sync) hatasının kullanıcıya gösterilecek metni.
String priceSyncErrorMessage(int? status, String message, SourceLabels labels) {
  if (status == 409) return 'Güncelleme zaten sürüyor. Biraz sonra tekrar dene.';
  if (status == 502 && message == kPriceListTooShortError) {
    return '${labels.short} listesi beklenenden çok kısa geldi (yarım ya da bozuk liste olabilir). '
        'Fiyatlar değiştirilmedi; lütfen daha sonra tekrar dene.';
  }
  if (status == 502) {
    return '${labels.dative} ulaşılamadı; fiyat listesi alınamadı. Ürünlerde hiçbir değişiklik yapılmadı, '
        'lütfen daha sonra tekrar dene.';
  }
  return message.isNotEmpty ? message : 'Bağlantı hatası';
}

/// Başarısız senkrondan sonra kartın durum alanı sunucudan yenilensin mi?
/// Backend indirme hatasını (502) ve uygulama hatasını (500/400) "failed"
/// olarak kaydeder; 409'da başka senkron sürüyordur, status yoksa backend'e
/// hiç ulaşılamamıştır.
bool syncErrorUpdatesStatus(int? status) => status != null && status != 409;

/// Kartın "son güncellemede kaç ürüne zam geldi" satırı; hiç başarılı
/// senkron yoksa null.
String? lastChangesMessage(PriceSyncChanges? lc) {
  if (lc == null) return null;
  if (lc.increased == 0 && lc.decreased == 0) return 'Son güncellemede fiyatı değişen ürün olmadı.';
  if (lc.increased == 0) return 'Son güncellemede zam gelen ürün olmadı; ${lc.decreased} ürünün fiyatı düştü.';
  final avg = lc.avgIncreasePercent == null ? '' : ' (ort. ${formatPricePercent(lc.avgIncreasePercent!)})';
  final down = lc.decreased > 0 ? '; ${lc.decreased} ürünün fiyatı düştü' : '';
  return 'Son güncellemede ${lc.increased} ürüne zam geldi$avg$down.';
}

/// Metni cümle sonu işaretiyle bitirir (backend hata metinleri noktasızdır).
String asSentence(String text) {
  final t = text.trim();
  if (t.isEmpty) return t;
  return RegExp(r'[.!?…]$').hasMatch(t) ? t : '$t.';
}

/// Kâr oranı kaydından sonraki bildirim.
String settingsSavedMessage(int recomputed, String? lastSyncedAt, String sourceName) {
  if (recomputed > 0) return 'Ayarlar kaydedildi · $recomputed ürünün fiyatı yeniden hesaplandı.';
  if (lastSyncedAt == null) {
    return 'Ayarlar kaydedildi. Henüz $sourceName fiyatı bilinen ürün yok; yeni oranlar ilk '
        '$sourceName güncellemesinde uygulanır.';
  }
  return 'Ayarlar kaydedildi · fiyatı değişen ürün olmadı.';
}

// ---------- Kâr oranı ayar formu ----------

class CategoryMarkupRow {
  const CategoryMarkupRow({required this.category, required this.productCount, required this.markup});
  final String category;
  final int productCount;

  /// Kullanıcının yazdığı oran; "" = varsayılan oran.
  final String markup;
}

/// Türkçe alfabe sırası (ç, ğ, ı, ö, ş, ü doğru yerde; I/İ doğru küçülür)
/// -- web `localeCompare(..., "tr")` karşılığı, yalnızca sıralama için.
int compareTr(String a, String b) {
  const alphabet = 'abcçdefgğhıijklmnoöprsştuüvwxyz';
  String lower(String s) => s.replaceAll('I', 'ı').replaceAll('İ', 'i').toLowerCase();
  final la = lower(a);
  final lb = lower(b);
  final n = la.length < lb.length ? la.length : lb.length;
  for (var i = 0; i < n; i++) {
    final ca = la[i];
    final cb = lb[i];
    if (ca == cb) continue;
    final ia = alphabet.indexOf(ca);
    final ib = alphabet.indexOf(cb);
    if (ia >= 0 && ib >= 0) return ia.compareTo(ib);
    // Harf dışı karakterler (rakam, boşluk, noktalama) harflerden önce.
    if (ia >= 0) return 1;
    if (ib >= 0) return -1;
    return ca.compareTo(cb);
  }
  return la.length.compareTo(lb.length);
}

/// Formun kategori satırları: firmanın bu kaynaktan gelen ürünlerindeki
/// kategoriler + ürünü kalmamış ama oranı kayıtlı kategoriler (PUT tam
/// durumdur -- listede olmasalar kaydet'te SESSİZCE silinirlerdi).
List<CategoryMarkupRow> categoryMarkupRows(PriceSource ps) {
  final overrides = {for (final m in ps.categoryMarkups ?? const <PriceSourceCategoryMarkup>[]) m.category: m.markupPercent};
  final rows = [
    for (final c in ps.categories)
      CategoryMarkupRow(
        category: c.category,
        productCount: c.productCount,
        markup: overrides[c.category] == null ? '' : formatMarkupInput(overrides[c.category]!),
      ),
  ];
  final listed = {for (final c in ps.categories) c.category};
  for (final m in ps.categoryMarkups ?? const <PriceSourceCategoryMarkup>[]) {
    if (!listed.contains(m.category)) {
      rows.add(CategoryMarkupRow(category: m.category, productCount: 0, markup: formatMarkupInput(m.markupPercent)));
    }
  }
  rows.sort((a, b) => compareTr(a.category, b.category));
  return rows;
}

/// PUT /products/price-sources/{source} gövdesi -- backend gövdeyi TAM
/// durum sayar: üç alan da her zaman gönderilir.
class PriceSourceSettingsBody {
  const PriceSourceSettingsBody({required this.markupPercent, required this.autoSync, required this.categoryMarkups});
  final double markupPercent;
  final bool autoSync;
  final List<PriceSourceCategoryMarkup> categoryMarkups;

  Map<String, dynamic> toJson() => {
    'markup_percent': markupPercent,
    'auto_sync': autoSync,
    'category_markups': [for (final m in categoryMarkups) m.toJson()],
  };
}

class SettingsBuild {
  const SettingsBuild.ok(PriceSourceSettingsBody this.body) : markupError = null, rowErrors = const {};
  const SettingsBuild.fail({this.markupError, this.rowErrors = const {}}) : body = null;
  final PriceSourceSettingsBody? body;
  final String? markupError;
  final Map<String, String> rowErrors;
  bool get ok => body != null;
}

/// Formu PUT gövdesine çevirir; oranı boş bırakılan kategoriler
/// category_markups'a girmez (= varsayılan oran).
SettingsBuild buildSettingsBody({
  required String markup,
  required bool autoSync,
  required List<CategoryMarkupRow> rows,
}) {
  final parsed = parseMarkupInput(markup);
  final rowErrors = <String, String>{};
  final categoryMarkups = <PriceSourceCategoryMarkup>[];
  for (final row in rows) {
    if (row.markup.trim().isEmpty) continue;
    final p = parseMarkupInput(row.markup);
    if (p.ok) {
      categoryMarkups.add(PriceSourceCategoryMarkup(category: row.category, markupPercent: p.value!));
    } else {
      rowErrors[row.category] = p.error!;
    }
  }
  if (!parsed.ok || rowErrors.isNotEmpty) {
    return SettingsBuild.fail(markupError: parsed.ok ? null : parsed.error, rowErrors: rowErrors);
  }
  return SettingsBuild.ok(
    PriceSourceSettingsBody(markupPercent: parsed.value!, autoSync: autoSync, categoryMarkups: categoryMarkups),
  );
}
