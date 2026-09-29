import 'package:go_router/go_router.dart';

import 'presentation/project_activity_screen.dart';

export 'data/project_activity_providers.dart' show projectActivityProvider;

/// `/projeler/:id/aktivite` -- proje Aktivite Geçmişi (tam ekran).
String projectActivityPath(String projectId) => '/projeler/${Uri.encodeComponent(projectId)}/aktivite';

/// Proje detayının (`/projeler/:id`) `routes:` listesine eklenecek ALT rota
/// (göreli). Ekran izni kendisi denetler (oturum yüklenirken istek yok,
/// 403'te "yetkin yok").
final List<RouteBase> projectActivityRoutes = [
  GoRoute(
    path: 'aktivite',
    builder: (context, state) => ProjectActivityScreen(projectId: state.pathParameters['id']!),
  ),
];
