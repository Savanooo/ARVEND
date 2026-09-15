import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../projects/data/projects_providers.dart';
import '../../projects/domain/project.dart';

typedef ProjectTaskWithProject = (ProjectTask task, String projectId, String projectName);

/// GERÇEK BACKEND GAP: `/api/v1/projects/{id}/tasks` dışında hiçbir
/// cross-project görev ucu yok (bkz. API_CONTRACT.md ve
/// MOBILE_BACKEND_GAPS.md). Bu provider, açık projelerin görevlerini TEK
/// TEK çekip client-side birleştirir - gerçek bir "görevlerim" sorgusunun
/// (assignee/pagination/sort) YERİNE GEÇMEZ, yalnızca en iyi yaklaşıklamadır.
/// Maliyeti sınırlamak için yalnızca `active`+`planned` projeler taranır.
final myTasksProvider = FutureProvider.autoDispose<List<ProjectTaskWithProject>>((ref) async {
  final repo = ref.watch(projectsRepositoryProvider);
  final active = await repo.list(status: 'active', limit: 200);
  final planned = await repo.list(status: 'planned', limit: 200);
  final projects = [...active.projects, ...planned.projects];

  final results = <ProjectTaskWithProject>[];
  for (final project in projects) {
    final tasks = await repo.tasks(project.id);
    for (final task in tasks) {
      if (task.status == 'todo' || task.status == 'in_progress') {
        results.add((task, project.id, project.name));
      }
    }
  }
  results.sort((a, b) {
    final aOverdue = a.$1.isOverdue ? 0 : 1;
    final bOverdue = b.$1.isOverdue ? 0 : 1;
    if (aOverdue != bOverdue) return aOverdue - bOverdue;
    final aDue = a.$1.dueDate ?? '9999-99-99';
    final bDue = b.$1.dueDate ?? '9999-99-99';
    return aDue.compareTo(bDue);
  });
  return results;
});
