import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'domain/price_change.dart';
import 'presentation/price_changes_screen.dart';
import 'presentation/price_sources_screen.dart';
import 'presentation/product_detail_screen.dart';
import 'presentation/product_form_screen.dart';
import 'presentation/products_paths.dart';
import 'presentation/products_screen.dart';

export 'presentation/products_paths.dart' show ProductsPaths, ProductsPermissions;

/// Ürünler modülünün rotaları -- "Diğer" dalının (`/diger`) ALTINA
/// bağlanır (göreli yollar; bkz. app_router.dart'taki `/diger` GoRoute'unun
/// `routes:` listesi). Entegrasyon adımı:
///
/// ```dart
/// GoRoute(path: '/diger', builder: ..., routes: [..., ...productsRoutes]),
/// ```
///
/// Sonuç yollar: /diger/urunler, /diger/urunler/yeni,
/// /diger/urunler/kaynaklar, /diger/urunler/zamlar(?period=&source=&…),
/// /diger/urunler/:id, /diger/urunler/:id/duzenle. Statik alt yollar
/// (yeni/kaynaklar/zamlar) `:id`'den ÖNCE tanımlıdır.
///
/// Her ekran kendi izin kapısını çağırır (`canAccess`, fail-closed):
/// okuma products.read, ekle/düzenle products.manage -- rota elle açılsa
/// bile izinsiz kullanıcı açıklama görür, istek atılmaz.
final List<RouteBase> productsRoutes = [
  GoRoute(
    path: 'urunler',
    builder: (context, state) => const ProductsScreen(),
    routes: [
      GoRoute(path: 'yeni', builder: (context, state) => const ProductFormScreen()),
      GoRoute(path: 'kaynaklar', builder: (context, state) => const PriceSourcesScreen()),
      GoRoute(
        path: 'zamlar',
        // Web /admin/urunler/zamlar ile aynı sorgu parametreleri (period,
        // from, to, source, reason, direction, category, q, sort,
        // event_from/event_to/event_reason/event_source).
        builder: (context, state) =>
            PriceChangesScreen(initialParams: ZamlarParams.fromQuery(state.uri.queryParameters)),
      ),
      GoRoute(
        path: ':id',
        builder: (context, state) => ProductDetailScreen(productId: state.pathParameters['id']!),
        routes: [
          GoRoute(
            path: 'duzenle',
            builder: (context, state) => ProductFormScreen(productId: state.pathParameters['id']!),
          ),
        ],
      ),
    ],
  ),
];

/// "Diğer" menüsü öğesi: (etiket, ikon, mutlak rota, gereken izin).
/// Kayıtta `user.canAccess(permission)` (KATI) ile süzülmeli. Kayıt tipi
/// yapısaldır -- diğer modüllerin (`suppliersMenuEntries`,
/// `costCodesMenuEntries`, …) aynı alanlı listeleriyle birleşir. Menüde
/// yalnızca ana giriş vardır (web menüsüyle aynı; ikon ana sayfadaki
/// "Ürünler & Zam" kartıyla aynı): Zam Geçmişi ve Fiyat Kaynakları
/// Ürünler ekranından açılır ([productsShortcutEntries]).
const List<({String label, IconData icon, String route, String permission})> productsMenuEntries = [
  (
    label: 'Ürünler',
    icon: Icons.inventory_2_outlined,
    route: ProductsPaths.list,
    permission: ProductsPermissions.read,
  ),
];

/// Ürünler ekranının içinden açılan alt ekranlar (menüde ayrı öğe DEĞİL;
/// ana sayfa kartları/bildirimler bu rotalara doğrudan gidebilir).
const List<({String label, IconData icon, String route, String permission})> productsShortcutEntries = [
  (
    label: 'Zam Geçmişi',
    icon: Icons.trending_up,
    route: ProductsPaths.priceChanges,
    permission: ProductsPermissions.read,
  ),
  (
    label: 'Fiyat Kaynakları',
    icon: Icons.cloud_sync_outlined,
    route: ProductsPaths.sources,
    permission: ProductsPermissions.read,
  ),
];
