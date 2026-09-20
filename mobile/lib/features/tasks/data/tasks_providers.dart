import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../projects/data/projects_providers.dart';
import '../../projects/domain/project.dart';

typedef ProjectTaskWithProject = (ProjectTask task, String projectId, String projectName);

/// GET /api/v1/tasks/mine — sunucu tarafında org + proje erişimi ile
/// filtrelenir. Eski O(N) proje döngüsü kaldırıldı. `status`, backend'in
/// desteklediği ham modlardan biridir: "open" (varsayılan, todo+in_progress),
/// "all", veya somut bir durum ("todo"/"in_progress"/"completed"/
/// "cancelled") -- mobil bunun ÜSTÜNE ikinci bir filtre kelime kümesi
/// İCAT ETMEZ.
final myTasksProvider = FutureProvider.autoDispose.family<List<ProjectTaskWithProject>, String>((ref, status) async {
  final repo = ref.watch(projectsRepositoryProvider);
  final rows = await repo.myTasks(status: status);
  return [
    for (final row in rows) (row.$1, row.$2, row.$3),
  ];
});
