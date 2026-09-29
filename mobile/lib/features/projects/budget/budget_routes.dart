import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../domain/project.dart' show Project;
import 'budget_paths.dart';
import 'domain/budget.dart';
import 'presentation/actual_cost_screen.dart';
import 'presentation/budget_adjustments_screen.dart';
import 'presentation/budget_cost_control_screen.dart';
import 'presentation/budget_cost_control_tab.dart';
import 'presentation/budget_line_form_screen.dart';
import 'presentation/budget_screen.dart';
import 'presentation/commitment_form_screen.dart';
import 'presentation/commitments_screen.dart';
import 'presentation/forecast_screen.dart';
import 'presentation/wbs_screen.dart';

export 'budget_paths.dart';
export 'presentation/budget_cost_control_tab.dart' show BudgetCostControlTab;

/// Proje detayı rotasının (`/projeler/:id`) `routes:` listesine eklenecek
/// GÖRELİ alt rotalar (`...budgetRoutes`). Tam yollar:
///
/// - `/projeler/:id/maliyet`                                        Maliyet Kontrolü (tam ekran merkez)
/// - `/projeler/:id/maliyet/butce`                                  Bütçe (kalemler, baseline)
/// - `/projeler/:id/maliyet/butce/kalemler/yeni`                    Yeni bütçe kalemi
/// - `/projeler/:id/maliyet/butce/kalemler/:lineId/duzenle`         Bütçe kalemini düzenle
/// - `/projeler/:id/maliyet/wbs`                                    WBS ağacı
/// - `/projeler/:id/maliyet/revizyonlar`                            Bütçe revizyonları
/// - `/projeler/:id/maliyet/taahhutler`                             Taahhütler
/// - `/projeler/:id/maliyet/taahhutler/yeni`                        Yeni manuel taahhüt
/// - `/projeler/:id/maliyet/tahmin`                                 Tahmin (ETC)
/// - `/projeler/:id/maliyet/gerceklesen`                            Gerçekleşen (masraf kırılımı)
///
/// Rota düzeyinde guard YOK: her ekran veri çekmeden önce kendi iznini
/// (router.go ile aynı kod, fail-open `UserCan.can`) denetler ve izinsizse
/// açıklama gösterir; 403 yanıtı da çökme değil "yetkin yok" görünümüdür.
final List<RouteBase> budgetRoutes = [
  GoRoute(
    path: 'maliyet',
    builder: (context, state) => BudgetCostControlScreen(projectId: state.pathParameters['id']!),
    routes: [
      GoRoute(
        path: 'butce',
        builder: (context, state) => BudgetScreen(projectId: state.pathParameters['id']!),
        routes: [
          GoRoute(
            path: 'kalemler/yeni',
            builder: (context, state) => BudgetLineFormScreen(projectId: state.pathParameters['id']!),
          ),
          GoRoute(
            path: 'kalemler/:lineId/duzenle',
            builder: (context, state) =>
                BudgetLineFormScreen(projectId: state.pathParameters['id']!, lineId: state.pathParameters['lineId']),
          ),
        ],
      ),
      GoRoute(
        path: 'wbs',
        builder: (context, state) => WbsScreen(projectId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: 'revizyonlar',
        builder: (context, state) => BudgetAdjustmentsScreen(projectId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: 'taahhutler',
        builder: (context, state) => CommitmentsScreen(projectId: state.pathParameters['id']!),
        routes: [
          GoRoute(
            path: 'yeni',
            builder: (context, state) => CommitmentFormScreen(projectId: state.pathParameters['id']!),
          ),
        ],
      ),
      GoRoute(
        path: 'tahmin',
        builder: (context, state) => ForecastScreen(projectId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: 'gerceklesen',
        builder: (context, state) => ActualCostScreen(projectId: state.pathParameters['id']!),
      ),
    ],
  ),
];

/// Entegrasyon tanımı (diğer proje gruplarının `ProjectSectionEntry`
/// kayıtlarıyla aynı alan adları + `anyOfPermissions`/`replaces`):
///
/// - Grup "Finans" (`?grup=finans`), alt görünüm `maliyet` -- mevcut
///   "Maliyet Kontrolü" segmenti. Salt-okunur `_CostControlTab`'ın YERİNİ
///   alır (onun özet + kalem listesini de kapsar).
/// - Görünürlük: `anyOfPermissions`'tan HERHANGİ biri (`_failOpen` /
///   `UserCan.can`). Finans grubunun kendi görünürlük koşuluna da
///   `projects.budget.read` eklenmeli (bütçe izni olup maliyet kontrolü
///   izni olmayan özel rol sekmeyi görebilsin). `permission` birincil
///   izindir (tek izin bekleyen listeler için).
/// - `builder`: grubun `Expanded` alanına konur; kendi RefreshIndicator +
///   ListView'ını taşır (üst dolgu 0). `route`: aynı gövdenin tam ekranı.
typedef BudgetSectionEntry = ({
  String group,
  String alt,
  String label,
  String permission,
  List<String> anyOfPermissions,
  IconData icon,
  String replaces,
  String Function(String projectId) route,
  Widget Function(String projectId, Project project) builder,
});

final List<BudgetSectionEntry> budgetSections = [
  (
    group: 'finans',
    alt: 'maliyet',
    label: 'Maliyet Kontrolü',
    permission: kCostControlReadPermission,
    anyOfPermissions: const [kCostControlReadPermission, kBudgetReadPermission],
    icon: Icons.account_balance_wallet_outlined,
    replaces: '_CostControlTab',
    route: costControlPath,
    builder: (projectId, project) => BudgetCostControlTab(projectId: projectId, project: project),
  ),
];
