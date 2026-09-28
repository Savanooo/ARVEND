import 'package:go_router/go_router.dart';

import 'presentation/project_edit_screen.dart';

/// "Proje bilgilerini düzenle" rotası -- `/projeler/:id` rotasının
/// `routes:` listesine ALT rota olarak eklenir (relative path `duzenle`),
/// tam yol `/projeler/:id/duzenle`. Proje detayındaki "Düzenle" aksiyonu
/// (yalnızca `projects.update` ile görünür) buraya `context.push` eder.
final List<RouteBase> projectEditRoutes = [
  GoRoute(
    path: 'duzenle',
    builder: (context, state) => ProjectEditScreen(projectId: state.pathParameters['id']!),
  ),
];

/// Proje detayından düzenleme ekranına giden tam yol.
String projectEditLocation(String projectId) => '/projeler/$projectId/duzenle';
