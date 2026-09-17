import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../projects/data/projects_providers.dart';
import '../../projects/domain/project.dart';

typedef ProjectTaskWithProject = (ProjectTask task, String projectId, String projectName);

/// GET /api/v1/tasks/mine — sunucu tarafında org + proje erişimi ile filtrelenir.
/// Eski O(N) proje döngüsü kaldırıldı.
final myTasksProvider = FutureProvider.autoDispose<List<ProjectTaskWithProject>>((ref) async {
  final repo = ref.watch(projectsRepositoryProvider);
  final rows = await repo.myTasks(status: 'open');
  return [
    for (final row in rows) (row.$1, row.$2, row.$3),
  ];
});
