import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'domain/supplier.dart';
import 'presentation/supplier_detail_screen.dart';
import 'presentation/suppliers_screen.dart';
import 'suppliers_paths.dart';

export 'suppliers_paths.dart';

/// "Diğer" dalının (`/diger`) ALTINA kaydedilecek rotalar -- yollar
/// GÖRELİDİR: `tedarikciler` -> `/diger/tedarikciler`,
/// `tedarikciler/:id` -> `/diger/tedarikciler/:id` (detay, listenin
/// çocuğu; derin bağlantıda geri tuşu listeye döner). Kayıt, app_router.dart
/// içinde `/diger` GoRoute'unun `routes:` listesine `...suppliersRoutes`
/// eklenerek yapılır. Ekranlar izni KENDİLERİ denetler (okuma izni yoksa
/// API çağırmadan "yetkin yok" gösterir), rota düzeyinde ek bir guard
/// gerekmez.
final List<RouteBase> suppliersRoutes = [
  GoRoute(
    path: 'tedarikciler',
    builder: (context, state) => const SuppliersScreen(),
    routes: [
      GoRoute(
        path: ':id',
        builder: (context, state) => SupplierDetailScreen(supplierId: state.pathParameters['id']!),
      ),
    ],
  ),
];

/// Diğer menüsü öğesi: (etiket, ikon, mutlak rota, gereken izin). Kayıt
/// sırasında öğe `ref.watch(authControllerProvider).valueOrNull
/// .canAccess(permission)` ile süzülmeli (KATI, fail-closed). İkon ana
/// sayfadaki Tedarikçiler kartıyla (dashboard_registry.dart) aynıdır.
/// Kayıt (record) tipi yapısaldır: diğer modüllerin aynı alanlı
/// tanımlarıyla tek listede birleşir.
const List<({String label, IconData icon, String route, String permission})> suppliersMenuEntries = [
  (
    label: 'Tedarikçiler',
    icon: Icons.local_shipping_outlined,
    route: kSuppliersPath,
    permission: kSuppliersReadPermission,
  ),
];
