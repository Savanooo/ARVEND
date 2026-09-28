import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'cost_codes_paths.dart';
import 'domain/cost_code.dart';
import 'presentation/cost_code_detail_screen.dart';
import 'presentation/cost_codes_screen.dart';

export 'cost_codes_paths.dart';

/// "Diğer" dalının (`/diger`) ALTINA kaydedilecek rotalar -- yollar
/// GÖRELİDİR: `maliyet-kodlari` -> `/diger/maliyet-kodlari`,
/// `maliyet-kodlari/:id` -> `/diger/maliyet-kodlari/:id` (detay, listenin
/// çocuğu). Kayıt, app_router.dart içinde `/diger` GoRoute'unun `routes:`
/// listesine `...costCodesRoutes` eklenerek yapılır. Ekranlar izni
/// KENDİLERİ denetler (okuma izni yoksa API çağırmadan "yetkin yok"
/// gösterir).
final List<RouteBase> costCodesRoutes = [
  GoRoute(
    path: 'maliyet-kodlari',
    builder: (context, state) => const CostCodesScreen(),
    routes: [
      GoRoute(
        path: ':id',
        builder: (context, state) => CostCodeDetailScreen(costCodeId: state.pathParameters['id']!),
      ),
    ],
  ),
];

/// Diğer menüsü öğesi: (etiket, ikon, mutlak rota, gereken izin). Kayıtta
/// `canAccess(permission)` (KATI) ile süzülmeli. İkon ana sayfadaki Maliyet
/// Kodları kartıyla (dashboard_registry.dart) aynıdır. Kayıt tipi
/// yapısaldır: `suppliersMenuEntries` ile aynı tip.
const List<({String label, IconData icon, String route, String permission})> costCodesMenuEntries = [
  (
    label: 'Maliyet Kodları',
    icon: Icons.sell_outlined,
    route: kCostCodesPath,
    permission: kCostCodesReadPermission,
  ),
];
