import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/widgets/app_page_scaffold.dart';
import '../data/projects_providers.dart';
import '../ops_team/domain/ops_permissions.dart';
import 'presentation/daily_report_screen.dart';
import 'presentation/daily_reports_tab.dart';

export 'daily_report_paths.dart';

/// Proje detayının (`/projeler/:id`) `routes:` listesine eklenecek ALT
/// rotalar -- yollar GÖRELİDİR:
///
/// - `gunluk-rapor`        -> raporlar (bugün + geçmiş)
/// - `gunluk-rapor/:date`  -> günün raporu (YYYY-AA-GG; bildirim hedefi)
final List<RouteBase> dailyReportRoutes = [
  GoRoute(
    path: 'gunluk-rapor',
    builder: (context, state) => DailyReportsScreen(projectId: state.pathParameters['id']!),
    routes: [
      GoRoute(
        path: ':date',
        builder: (context, state) => DailyReportScreen(
          projectId: state.pathParameters['id']!,
          date: state.pathParameters['date']!,
        ),
      ),
    ],
  ),
];

/// `/projeler/:id/gunluk-rapor` -- gövde proje detayındaki alt görünümle
/// aynı widget.
class DailyReportsScreen extends ConsumerWidget {
  const DailyReportsScreen({super.key, required this.projectId});

  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(projectDetailProvider(projectId)).valueOrNull?.status;
    return AppPageScaffold(
      title: const Text('Günlük Rapor'),
      body: DailyReportsTab(projectId: projectId, locked: status == null ? null : isProjectLocked(status)),
    );
  }
}
