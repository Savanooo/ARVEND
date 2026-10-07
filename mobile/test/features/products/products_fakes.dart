import 'dart:convert';

import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:arvend/core/auth/auth_controller.dart';
import 'package:arvend/core/errors/api_exception.dart';
import 'package:arvend/core/theme/app_theme.dart';
import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/products/data/products_providers.dart';
import 'package:arvend/features/products/data/products_repository.dart';
import 'package:arvend/features/products/domain/price_change.dart';
import 'package:arvend/features/products/domain/price_source.dart';
import 'package:arvend/features/products/domain/product.dart';
import 'package:arvend/features/products/products_routes.dart';

/// Ürünler modülü testlerinin ortak sahte verisi + ağsız sahte depo +
/// test iskeleti. Veri backend yanıt şekliyle (JSON) yazılır ve gerçek
/// `fromJson`'lardan geçer -- sahte depo da backend gibi davranır:
/// tedarikçi fiyatı ve kâr oranları yalnızca `manage: true` iken döner.

/// Sabit "şimdi": 2026-09-28 12:00 İstanbul.
final kTestNow = DateTime.utc(2026, 9, 28, 9);

const kUlasSyncedAt = '2026-09-27T00:05:12+03:00';
const kDemirSyncedAt = '2026-09-21T00:05:40+03:00';
const kUlasEventAt = '2026-09-27T00:05:12.482113+03:00';
const kDemirEventAt = '2026-09-21T00:05:40.123456+03:00';

// ---------- Kullanıcılar ----------

User testUser(Set<String> permissions, {UserRole role = UserRole.kullanici}) => User(
  id: 'u1',
  organizationId: 'org1',
  username: 'test',
  fullName: 'Test Kullanıcı',
  role: role,
  isActive: true,
  mustChangePassword: false,
  onboardingCompleted: true,
  onboardingStep: 'completed',
  organizationName: 'Deneme Magaza',
  organizationRoleCode: 'owner',
  organizationRoleName: 'Sahip',
  permissions: permissions,
);

final ownerUser = testUser({'products.read', 'products.manage', 'offers.read', 'customers.read'}, role: UserRole.admin);
final readOnlyUser = testUser({'products.read', 'offers.read'});
final noAccessUser = testUser({'offers.read'});

class FakeAuth extends AuthController {
  FakeAuth(this._user);
  final User _user;

  @override
  Future<User?> build() async => _user;
}

// ---------- JSON fixture'ları ----------

Map<String, dynamic> productJson({
  required String id,
  required String name,
  String unit = 'adet',
  double unitPrice = 100,
  String description = '',
  String category = '',
  String source = '',
  String? sourceSyncedAt,
  double? sourcePrice,
}) => {
  'id': id,
  'name': name,
  'unit': unit,
  'unit_price': unitPrice,
  'description': description,
  'category': category,
  'source': source,
  'source_synced_at': sourceSyncedAt,
  'source_price': sourcePrice,
};

List<Map<String, dynamic>> catalogJson() => [
  productJson(
    id: 'p1',
    name: 'Kutu Profil 40x40x2 mm',
    unit: 'm',
    unitPrice: 115,
    category: 'Kutu Profil',
    source: kDemirProfilSource,
    sourceSyncedAt: kDemirSyncedAt,
    sourcePrice: 100,
  ),
  productJson(
    id: 'p2',
    name: 'Saten İç Cephe Boyası 2,5 Lt Beyaz',
    unitPrice: 575,
    category: 'Boya',
    source: kUlasSource,
    // Son başarılı Ulaş senkronundan ÖNCE görülmüş -> "Ulaş listesinde yok".
    sourceSyncedAt: '2026-09-12T00:05:00+03:00',
    sourcePrice: 500,
  ),
  productJson(
    id: 'p3',
    name: 'Alçı Levha 12,5 mm',
    unit: 'm²',
    unitPrice: 185.5,
    category: 'Alçı',
    description: 'Standart beyaz alçı levha, 120x250 cm',
  ),
  productJson(
    id: 'p4',
    name: 'Sandviç Panel 40 mm Çatı',
    unit: 'm²',
    unitPrice: 690,
    category: 'Panel',
    source: kDemirProfilSource,
    sourceSyncedAt: kDemirSyncedAt,
    sourcePrice: 613.33,
  ),
];

Map<String, dynamic> ulasSourceJson() => {
  'source': kUlasSource,
  'name': 'Ulaş',
  'site_url': 'https://ulas.com.tr',
  'vat_note': 'KDV durumu listede belirtilmiyor',
  'list_label': '',
  'attribution': '',
  'markup_percent': 15,
  'category_markups': [
    {'category': 'Boya', 'markup_percent': 20},
  ],
  'auto_sync': false,
  'last_synced_at': kUlasSyncedAt,
  'last_status': 'success',
  'last_error': '',
  'last_result': {'total': 628, 'created': 3, 'updated': 12, 'unchanged': 613, 'missing': 1},
  'categories': [
    {'category': 'Boya', 'product_count': 120},
    {'category': 'Yapı Kimyasalları', 'product_count': 208},
    {'category': 'Hırdavat', 'product_count': 300},
  ],
  'product_count': 628,
  'missing_count': 1,
  'updated_at': kUlasSyncedAt,
  'last_changes': {'increased': 12, 'decreased': 2, 'avg_increase_percent': 2.91},
};

Map<String, dynamic> demirSourceJson() => {
  'source': kDemirProfilSource,
  'name': 'Demir Profil (Omega Çelik)',
  'site_url': 'https://www.demirprofil.com.tr',
  'vat_note': 'KDV hariç, toptan liste fiyatı; kesim ve nakliye hariç',
  'list_label': 'Eylül 2026',
  'attribution': 'Kaynak: demirprofil.com.tr — Eylül 2026 listesi',
  'markup_percent': 12.5,
  'category_markups': <Map<String, dynamic>>[],
  'auto_sync': true,
  'last_synced_at': kDemirSyncedAt,
  'last_status': 'failed',
  'last_error': 'Demir Profil sayfası indirilemedi (HTTP 503)',
  'last_result': {'total': 3022, 'created': 0, 'updated': 46, 'unchanged': 2976, 'missing': 0},
  'categories': [
    {'category': 'Kutu Profil', 'product_count': 900},
    {'category': 'Sac', 'product_count': 2002},
    {'category': 'Panel', 'product_count': 120},
  ],
  'product_count': 3022,
  'missing_count': 0,
  'updated_at': kDemirSyncedAt,
  'last_changes': {'increased': 45, 'decreased': 1, 'avg_increase_percent': 1.8},
};

List<Map<String, dynamic>> historyJson() => [
  {
    'old_price': 110,
    'new_price': 115,
    'note': 'Demir Profil fiyat listesi (Eylül 2026)',
    'changed_at': '2026-09-21T00:05:40+03:00',
    'reason': 'supplier',
    'source': kDemirProfilSource,
    'old_source_price': 97.78,
    'new_source_price': 100,
  },
  {
    'old_price': 105,
    'new_price': 110,
    'note': 'Demir Profil kâr oranı güncellendi',
    'changed_at': '2026-09-10T14:20:00+03:00',
    'reason': 'markup',
    'source': kDemirProfilSource,
    'old_source_price': 97.78,
    'new_source_price': 97.78,
  },
  {
    'old_price': 108,
    'new_price': 105,
    'note': '',
    'changed_at': '2026-09-02T10:45:00+03:00',
    'reason': 'manual',
    'source': null,
    'old_source_price': null,
    'new_source_price': null,
  },
];

Map<String, dynamic> summaryJson() => {
  'increased_count': 58,
  'decreased_count': 3,
  'products_increased': 57,
  'avg_increase_percent': 2.12,
  'max_increase': {'product_id': 'p2', 'product_name': 'Saten İç Cephe Boyası 2,5 Lt Beyaz', 'change_percent': 8.7},
  'events': [
    {
      'changed_at': kUlasEventAt,
      'from': kUlasEventAt,
      'to': kUlasEventAt,
      'source': kUlasSource,
      'reason': 'supplier',
      'change_count': 14,
      'increased': 12,
      'decreased': 2,
      'avg_change_percent': 2.91,
      'max_increase_percent': 8.7,
    },
    {
      'changed_at': kDemirEventAt,
      'from': kDemirEventAt,
      'to': kDemirEventAt,
      'source': kDemirProfilSource,
      'reason': 'supplier',
      'change_count': 46,
      'increased': 45,
      'decreased': 1,
      'avg_change_percent': 1.8,
      'max_increase_percent': 4.55,
    },
    {
      'changed_at': '2026-09-02T00:00:00+03:00',
      'from': '2026-09-02T00:00:00+03:00',
      'to': '2026-09-02T23:59:59.999999+03:00',
      'source': null,
      'reason': 'manual',
      'change_count': 2,
      'increased': 1,
      'decreased': 1,
      'avg_change_percent': null,
      'max_increase_percent': null,
    },
  ],
};

List<Map<String, dynamic>> changesJson() => [
  {
    'id': 'c1',
    'product_id': 'p2',
    'product_name': 'Saten İç Cephe Boyası 2,5 Lt Beyaz',
    'unit': 'adet',
    'category': 'Boya',
    'source': kUlasSource,
    'reason': 'supplier',
    'note': 'Ulaş fiyat listesi',
    'old_price': 529,
    'new_price': 575,
    'change_amount': 46,
    'change_percent': 8.7,
    'changed_at': kUlasEventAt,
    'old_source_price': 460,
    'new_source_price': 500,
  },
  {
    'id': 'c2',
    'product_id': 'p1',
    'product_name': 'Kutu Profil 40x40x2 mm',
    'unit': 'm',
    'category': 'Kutu Profil',
    'source': kDemirProfilSource,
    'reason': 'supplier',
    'note': 'Demir Profil fiyat listesi (Eylül 2026)',
    'old_price': 110,
    'new_price': 115,
    'change_amount': 5,
    'change_percent': 4.55,
    'changed_at': kDemirEventAt,
    'old_source_price': 97.78,
    'new_source_price': 100,
  },
  {
    'id': 'c3',
    'product_id': 'p4',
    'product_name': 'Sandviç Panel 40 mm Çatı',
    'unit': 'm²',
    'category': 'Panel',
    'source': kDemirProfilSource,
    'reason': 'supplier',
    'note': 'Demir Profil fiyat listesi (Eylül 2026)',
    'old_price': 690,
    'new_price': 675.2,
    'change_amount': -14.8,
    'change_percent': -2.14,
    'changed_at': kDemirEventAt,
    'old_source_price': 613.33,
    'new_source_price': 600.18,
  },
];

// ---------- Sahte depo ----------

/// Ağsız sahte depo: backend gibi davranır (tedarikçi fiyatı/kâr oranı
/// yalnızca `manage: true` ise döner) ve yapılan çağrıları kaydeder.
class FakeProductsRepository implements ProductsRepository {
  FakeProductsRepository({
    this.manage = true,
    List<Map<String, dynamic>>? catalog,
    this.sourcesError,
    this.listError,
    this.syncError,
    this.historyByProduct,
  }) : catalog = catalog ?? catalogJson();

  /// Backend'in `canManageProducts` kararı (kullanıcının izninden bağımsız
  /// tutulabilir: istemcinin fail-closed davranışını sınamak için).
  final bool manage;
  final List<Map<String, dynamic>> catalog;
  Object? sourcesError;
  Object? listError;
  Object? syncError;
  final Map<String, List<Map<String, dynamic>>>? historyByProduct;

  final listCalls = <({String q, int page, int limit})>[];
  final priceChangeCalls = <({PriceChangesQuery query, int page})>[];
  final summaryCalls = <PriceChangeSummaryQuery>[];
  final created = <ProductInput>[];
  final updated = <({String id, ProductInput input})>[];
  final syncCalls = <String>[];
  final settingsCalls = <({String source, Map<String, dynamic> body})>[];
  int sourcesCalls = 0;

  int get totalCalls =>
      listCalls.length +
      priceChangeCalls.length +
      summaryCalls.length +
      created.length +
      updated.length +
      syncCalls.length +
      settingsCalls.length +
      sourcesCalls;

  Map<String, dynamic> _visible(Map<String, dynamic> p) => manage ? p : {...p, 'source_price': null};

  @override
  Future<ProductPage> list({String q = '', int page = 1, int limit = kProductsPageSize}) async {
    listCalls.add((q: q, page: page, limit: limit));
    if (listError != null) throw listError!;
    final matching = [
      for (final p in catalog)
        if (q.isEmpty || (p['name'] as String).toLowerCase().contains(q.toLowerCase())) _visible(p),
    ];
    final start = (page - 1) * limit;
    final slice = start >= matching.length ? const <Map<String, dynamic>>[] : matching.sublist(start, (start + limit).clamp(0, matching.length));
    return ProductPage.fromJson({'products': slice, 'total': matching.length});
  }

  @override
  Future<ProductPage> suggest(String q, {int limit = kProductSuggestionLimit, CancelToken? cancelToken}) =>
      list(q: q, limit: limit);

  @override
  Future<Product> get(String id) async {
    for (final p in catalog) {
      if (p['id'] == id) return Product.fromJson(_visible(p));
    }
    throw const ApiException(statusCode: 404, message: 'ürün bulunamadı', kind: ApiErrorKind.notFound);
  }

  @override
  Future<List<PriceHistoryEntry>> priceHistory(String id) async {
    final rows = historyByProduct?[id] ?? (id == 'p1' ? historyJson() : const <Map<String, dynamic>>[]);
    return [
      for (final r in rows)
        PriceHistoryEntry.fromJson(manage ? r : {...r, 'old_source_price': null, 'new_source_price': null}),
    ];
  }

  @override
  Future<Product> create(ProductInput input) async {
    created.add(input);
    return Product.fromJson(productJson(id: 'new', name: input.name, unit: input.unit, unitPrice: input.unitPrice));
  }

  @override
  Future<Product> update(String id, ProductInput input) async {
    updated.add((id: id, input: input));
    return Product.fromJson(productJson(id: id, name: input.name, unit: input.unit, unitPrice: input.unitPrice));
  }

  @override
  Future<List<PriceSource>> priceSources() async {
    sourcesCalls++;
    if (sourcesError != null) throw sourcesError!;
    Map<String, dynamic> hide(Map<String, dynamic> s) =>
        manage ? s : {...s, 'markup_percent': null, 'category_markups': null};
    return [PriceSource.fromJson(hide(ulasSourceJson())), PriceSource.fromJson(hide(demirSourceJson()))];
  }

  @override
  Future<PriceSyncResult> syncPriceSource(String source) async {
    syncCalls.add(source);
    if (syncError != null) throw syncError!;
    return PriceSyncResult.fromJson({
      'source': source,
      'total': 630,
      'created': 2,
      'updated': 14,
      'unchanged': 614,
      'missing': 1,
      'synced_at': '2026-09-28T12:00:00+03:00',
      'list_label': source == kDemirProfilSource ? 'Eylül 2026' : '',
    });
  }

  @override
  Future<PriceSourceUpdateResult> updatePriceSource(String source, PriceSourceSettingsBody body) async {
    settingsCalls.add((source: source, body: jsonDecode(jsonEncode(body.toJson())) as Map<String, dynamic>));
    final base = source == kUlasSource ? ulasSourceJson() : demirSourceJson();
    return PriceSourceUpdateResult.fromJson({'price_source': base, 'recomputed': 5});
  }

  @override
  Future<PriceChangeList> priceChanges(PriceChangesQuery query, {int page = 1, int limit = kPriceChangesPageSize}) async {
    priceChangeCalls.add((query: query, page: page));
    final rows = [
      for (final c in changesJson())
        if ((query.source.isEmpty || c['source'] == query.source) &&
            (query.direction == 'all' ||
                (query.direction == 'up' && (c['change_amount'] as num) > 0) ||
                (query.direction == 'down' && (c['change_amount'] as num) < 0)))
          manage ? c : {...c, 'old_source_price': null, 'new_source_price': null},
    ];
    return PriceChangeList.fromJson({'changes': page == 1 ? rows : const [], 'total': rows.length, 'page': page, 'limit': limit});
  }

  @override
  Future<PriceChangeSummary> priceChangeSummary(PriceChangeSummaryQuery query) async {
    summaryCalls.add(query);
    return PriceChangeSummary.fromJson(summaryJson());
  }
}

const forbidden = ApiException(statusCode: 403, message: 'bu işlem için yetkiniz yok', kind: ApiErrorKind.forbidden);

// ---------- İskelet ----------

/// Uygulama teması; açık `TextStyle` taşıyan AppBar başlığı ve dolu düğme
/// yazısına aile adı verilir. Temadaki bu stiller fontFamily taşımadığı için
/// cihazda platform yazı tipiyle çizilir, test motorunda ise kutu glifine
/// düşer (bkz. dashboard_golden_test.dart) -- golden'da okunabilsinler diye.
ThemeData productsTestTheme() {
  final theme = AppTheme.light();
  final elevated = theme.elevatedButtonTheme.style;
  return theme.copyWith(
    appBarTheme: theme.appBarTheme.copyWith(
      titleTextStyle: theme.appBarTheme.titleTextStyle?.copyWith(fontFamily: 'Inter'),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: elevated?.copyWith(
        textStyle: WidgetStatePropertyAll(
          (elevated.textStyle?.resolve(const {}) ?? const TextStyle()).copyWith(fontFamily: 'Inter'),
        ),
      ),
    ),
    snackBarTheme: theme.snackBarTheme.copyWith(
      contentTextStyle: theme.snackBarTheme.contentTextStyle?.copyWith(fontFamily: 'Inter'),
    ),
  );
}

/// `/diger` altına bağlanmış gerçek `productsRoutes` ile uygulama iskeleti.
Widget productsHarness({
  required User user,
  required FakeProductsRepository repo,
  required String location,
}) {
  final router = GoRouter(
    initialLocation: location,
    routes: [
      GoRoute(
        path: '/diger',
        builder: (_, _) => const Scaffold(body: Center(child: Text('DİĞER MENÜSÜ'))),
        routes: productsRoutes,
      ),
    ],
  );
  return ProviderScope(
    overrides: [
      authControllerProvider.overrideWith(() => FakeAuth(user)),
      productsRepositoryProvider.overrideWithValue(repo),
      productsClockProvider.overrideWithValue(() => kTestNow),
    ],
    child: MaterialApp.router(
      debugShowCheckedModeBanner: false,
      theme: productsTestTheme(),
      locale: const Locale('tr', 'TR'),
      supportedLocales: const [Locale('tr', 'TR')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      routerConfig: router,
    ),
  );
}

/// Uygulama fontlarını (Inter + MaterialIcons) yükler -- golden'larda metin
/// kutu olarak çizilmesin.
Future<void> loadAppFonts() async {
  final manifest = json.decode(await rootBundle.loadString('FontManifest.json')) as List<dynamic>;
  for (final family in manifest.cast<Map<String, dynamic>>()) {
    final loader = FontLoader(family['family'] as String);
    for (final font in (family['fonts'] as List).cast<Map<String, dynamic>>()) {
      loader.addFont(rootBundle.load(font['asset'] as String));
    }
    await loader.load();
  }
}
