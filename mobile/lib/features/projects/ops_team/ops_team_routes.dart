import 'package:go_router/go_router.dart';

import 'presentation/ops_team_screens.dart';
import 'presentation/schedule_item_detail_screen.dart';
import 'presentation/schedule_item_form_screen.dart';

export 'ops_team_paths.dart';
export 'ops_team_sections.dart';

/// Proje detayının (`/projeler/:id`) `routes:` listesine eklenecek ALT
/// rotalar -- yollar GÖRELİDİR:
///
/// - `planlama`                    -> `/projeler/:id/planlama` (iş programı)
/// - `planlama/yeni`               -> yeni aşama
/// - `planlama/:itemId`            -> aşama detayı + durum aksiyonları
/// - `planlama/:itemId/duzenle`    -> aşamayı düzenle
/// - `ekip`                        -> proje ekibi (personel roster'ı)
/// - `erisim`                      -> proje erişimi (uygulama kullanıcıları)
///
/// Kayıt: app_router.dart'ta `/projeler/:id` GoRoute'unun `routes:`
/// listesine `...opsTeamRoutes`. Ekranlar izni KENDİLERİ denetler (okuma
/// izni yoksa API çağırmadan "yetkin yok" gösterir, 403'te çökmez).
final List<RouteBase> opsTeamRoutes = [
  GoRoute(
    path: 'planlama',
    builder: (context, state) => ProjectScheduleScreen(projectId: state.pathParameters['id']!),
    routes: [
      // 'yeni' statik segmenti ':itemId'den ÖNCE -- aksi halde "yeni" bir
      // aşama kimliği sanılırdı.
      GoRoute(
        path: 'yeni',
        builder: (context, state) => ScheduleItemFormScreen(projectId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: ':itemId',
        builder: (context, state) => ScheduleItemDetailScreen(
          projectId: state.pathParameters['id']!,
          itemId: state.pathParameters['itemId']!,
        ),
        routes: [
          GoRoute(
            path: 'duzenle',
            builder: (context, state) => ScheduleItemFormScreen(
              projectId: state.pathParameters['id']!,
              itemId: state.pathParameters['itemId'],
            ),
          ),
        ],
      ),
    ],
  ),
  GoRoute(
    path: 'ekip',
    builder: (context, state) => ProjectTeamScreen(projectId: state.pathParameters['id']!),
  ),
  GoRoute(
    path: 'erisim',
    builder: (context, state) => ProjectAccessScreen(projectId: state.pathParameters['id']!),
  ),
];
